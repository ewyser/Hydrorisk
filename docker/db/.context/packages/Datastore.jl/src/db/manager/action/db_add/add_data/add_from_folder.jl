function cpc_from_folder(connection::String, path::String, files::Vector{String}, user::Dict; ISO_8601::String = "yyyy-mm-ddTHH:MM:SS")
    # Load assimilation mapping for CPC from DB
    mapping = LibPQ.Connection(connection) do conn
        res = LibPQ.execute(conn,
            "SELECT json FROM metadata.catalogs WHERE name = 'assimilation_catalog' LIMIT 1;")
        df = DataFrames.DataFrame(res)
        isempty(df) && error("assimilation_catalog not found in metadata.catalogs")
        JSON3.read(df[1, :json])["folder"]["CPC"]
    end
    
    # Extract dates & times
    n  = length(files)
    df = DataFrame(
        file          = Vector{String}(undef, n),
        startdatetime = Vector{DateTime}(undef, n),
        enddatetime   = Vector{DateTime}(undef, n),
    )
    
    # Parse timestamps from filename (CPC{YY}{DDD}{HHMM}{q}_{dur}.{ver}.h5)
    for (i, file) in enumerate(files)
        stem   = splitext(splitext(basename(file))[1])[1]  # e.g. "CPC2417718309_00005"
        parts  = split(stem, '_')
        header = parts[1]           # e.g. "CPC2417718309"
        dur_m  = parse(Int, parts[2])  # e.g. 5 (minutes)
        yy     = parse(Int, header[4:5])
        doy    = parse(Int, header[6:8])
        hhmm   = header[9:12]          # end-time HHMM
        year   = 2000 + yy
        date   = Date(year, 1, 1) + Day(doy - 1)
        hh     = parse(Int, hhmm[1:2])
        mm     = parse(Int, hhmm[3:4])
        enddatetime   = DateTime(date, Time(hh, mm, 0))
        startdatetime = enddatetime - Minute(dur_m)
        df.file[i]          = file
        df.startdatetime[i] = startdatetime
        df.enddatetime[i]   = enddatetime
    end
    sort!(df, :startdatetime)

    # Extract projection from first file (shared across all files)
    proj = h5open(joinpath(path, df.file[1]),"r") do h5file   
        w         = attrs(h5file[join(mapping["structure"]["attrs_coords"], "/")])
        projdef   = w["projdef"]
        if occursin("somerc", projdef) && occursin("2600000", projdef)
            srid = 2056   # CH1903+/LV95
        elseif occursin("somerc", projdef) && occursin("600000", projdef)
            srid = 21781  # CH1903/LV03
        else
            srid = 0
        end

        corners   = Dict()
        gdal.createcoordtrans(gdal.importEPSG(4326), gdal.importPROJ4(projdef)) do transform
            for (label, lon_key, lat_key) in [
                ("LL", "LL_lon", "LL_lat"),
                ("LR", "LR_lon", "LR_lat"),
                ("UL", "UL_lon", "UL_lat"),
                ("UR", "UR_lon", "UR_lat"),
            ]
                pt = gdal.fromWKT("POINT ($(w[lat_key]) $(w[lon_key]))")
                gdal.transform!(pt, transform)
                corners[label] = (gdal.getx(pt, 0), gdal.gety(pt, 0))
            end
        end

        x0 = corners["UL"][1]
        y0 = corners["UL"][2]
        nx = w["xsize"]
        ny = w["ysize"]
        dx = (corners["UR"][1] - corners["UL"][1])/nx
        dy = (corners["LL"][2] - corners["UL"][2])/ny

        return (;
            proj4 = projdef,
            srid  = srid,
            nx    = nx,
            ny    = ny,
            dx    = dx,
            dy    = dy,
            x0    = x0,
            y0    = y0,
        )
    end




    # Prepare table name based on category and datetime range
    user_id = user["id"]

    # ── Pre-read all HDF5 files in parallel ───────────────────────────────
    nfiles    = nrow(df)
    data_arr  = Vector{Matrix{Float32}}(undef, nfiles)
    ts_arr    = Vector{Vector{String}}(undef, nfiles)

    # Pre-format timestamps (avoids repeated formatting in the hot loop)
    for k in 1:nfiles
        ts_arr[k] = [Dates.format(df.startdatetime[k], ISO_8601), Dates.format(df.enddatetime[k], ISO_8601)]
    end

    # Parallel HDF5 reads (open in "r" — no write lock needed)
    Threads.@threads for k in 1:nfiles
        h5open(joinpath(path, df.file[k]), "r") do src
            data_arr[k] = permutedims(Array(src[join(mapping["structure"]["data"], "/")]))
        end
    end
    names = String[]
    Threads.@threads for k in 1:nfiles
        h5open(joinpath(path, df.file[k]), "r") do src
            push!(names, attrs(src["dataset1"]["what"])["prodname"])
            data_arr[k] = permutedims(Array(src[join(mapping["structure"]["data"], "/")]))
        end
    end
    name = "$(first(unique(names)))_$(Dates.format(df.startdatetime[1], "yyyymmddHHMMSS"))_$(Dates.format(df.startdatetime[end], "yyyymmddHHMMSS"))"

    # ── Sequential DB push ────────────────────────────────────────────────
    LibPQ.Connection(connection) do conn
        table, rid = db_initialize_table(conn, proj, name, user_id; category=mapping["category"], format="raster", input=true)
        for k in 1:nfiles
            @info "Pushing band $k of $nfiles to DB..."
            db_push_band_to_table!(conn, table, rid, data_arr[k], proj.ny, ts_arr[k])
        end
        # Store full band timestamp list in metadata.dataset for temporal extent auto-fill
        # Shape: [{"start": "yyyy-mm-ddTHH:MM:SS", "end": "yyyy-mm-ddTHH:MM:SS"}, ...]
        timestamps_json = JSON3.write([Dict("start" => ts[1], "end" => ts[2]) for ts in ts_arr])
        LibPQ.execute(conn,
            "UPDATE metadata.dataset SET timestamps = \$1::jsonb WHERE data_table = \$2;",
            (timestamps_json, table))
        # Track upload stats — sum all file sizes in the folder
        total_bytes = sum(filesize(joinpath(path, df.file[k])) for k in 1:nfiles; init=Int64(0))
        stats_id = LibPQ.execute(conn, """
            INSERT INTO core.stats (user_id, upload_bytes, upload_count, last_upload)
            VALUES (\$1, \$2, 1, NOW())
            ON CONFLICT (user_id) DO UPDATE SET
                upload_bytes = core.stats.upload_bytes + EXCLUDED.upload_bytes,
                upload_count = core.stats.upload_count + 1,
                last_upload  = NOW()
            RETURNING id;
        """, (user_id, total_bytes))[1, 1]
        stats_hash = bytes2hex(sha256(string(stats_id)))
        LibPQ.execute(conn, "UPDATE core.stats SET id_hash = \$1 WHERE id = \$2 AND id_hash IS NULL;", (stats_hash, stats_id))
    end
    msg = "✅ Done! - Folder '$(basename(path))' imported successfully as '$name' in category '$(mapping["category"])'."
    @info msg
    return Dict(
        "msg"      => msg,
        "path"     => path,
        "category" => mapping["category"],
        "table"    => name,
    )
end

function precip_from_folder(connection::String, path::String, files::Vector{String}, user::Dict; ISO_8601::String = "yyyy-mm-ddTHH:MM:SS", duration_in_minutes::Int=5)
    # Load assimilation mapping for CPC from DB
    mapping = LibPQ.Connection(connection) do conn
        res = LibPQ.execute(conn,
            "SELECT json FROM metadata.catalogs WHERE name = 'assimilation_catalog' LIMIT 1;")
        df = DataFrames.DataFrame(res)
        isempty(df) && error("assimilation_catalog not found in metadata.catalogs")
        JSON3.read(df[1, :json])["folder"]["PRECIP"]
    end
    
    # Parse timestamps from filename (RZC{YY}{DDD}{HHMM}VL.{ver}.h5)
    df = DataFrame(
        file          = Vector{String}(),
        startdatetime = Vector{DateTime}(),
        enddatetime   = Vector{DateTime}(),
    )
    for (i, file) in enumerate(files)
        stem   = split(basename(file),".")  # e.g. "RZC241770737VL.001.h5"
        header = stem[1]           # e.g. "RZC241770737VL"
        yy     = parse(Int, header[4:5])
        doy    = parse(Int, header[6:8])
        hhmm   = header[9:12]          # end-time HHMM
        year   = 2000 + yy
        date   = Date(year, 1, 1) + Day(doy - 1)
        hh     = parse(Int, hhmm[1:2])
        mm     = parse(Int, hhmm[3:4])
        if mm % duration_in_minutes != 0
            @warn "File $file has a timestamp that is not a multiple of $duration_in_minutes minutes. This may indicate an unexpected time step."
        else
            df_tmp = DataFrame(
                file          = [file],
                startdatetime = [DateTime(date, Time(hh, mm, 0)) - Minute(duration_in_minutes)],
                enddatetime   = [DateTime(date, Time(hh, mm, 0))],
            )
            append!(df, df_tmp)
        end
    end
    sort!(df, :startdatetime)
    # Extract projection from first file (shared across all files)
    proj = h5open(joinpath(path, df.file[1]),"r") do h5file   
        w         = attrs(h5file[join(mapping["structure"]["attrs_coords"], "/")])
        projdef   = w["projdef"]
        if occursin("somerc", projdef) && occursin("2600000", projdef)
            srid = 2056   # CH1903+/LV95
        elseif occursin("somerc", projdef) && occursin("600000", projdef)
            srid = 21781  # CH1903/LV03
        else
            srid = 0
        end

        corners   = Dict()
        gdal.createcoordtrans(gdal.importEPSG(4326), gdal.importPROJ4(projdef)) do transform
            for (label, lon_key, lat_key) in [
                ("LL", "LL_lon", "LL_lat"),
                ("LR", "LR_lon", "LR_lat"),
                ("UL", "UL_lon", "UL_lat"),
                ("UR", "UR_lon", "UR_lat"),
            ]
                pt = gdal.fromWKT("POINT ($(w[lat_key]) $(w[lon_key]))")
                gdal.transform!(pt, transform)
                corners[label] = (gdal.getx(pt, 0), gdal.gety(pt, 0))
            end
        end

        x0 = corners["UL"][1]
        y0 = corners["UL"][2]
        nx = w["xsize"]
        ny = w["ysize"]
        dx = (corners["UR"][1] - corners["UL"][1])/nx
        dy = (corners["LL"][2] - corners["UL"][2])/ny

        return (;
            proj4 = projdef,
            srid  = srid,
            nx    = nx,
            ny    = ny,
            dx    = dx,
            dy    = dy,
            x0    = x0,
            y0    = y0,
        )
    end
    # Prepare table name based on category and datetime range
    user_id = user["id"]

    # ── Pre-read all HDF5 files in parallel ───────────────────────────────
    nfiles    = nrow(df)
    data_arr  = Vector{Matrix{Float32}}(undef, nfiles)
    ts_arr    = Vector{Vector{String}}(undef, nfiles)

    # Pre-format timestamps (avoids repeated formatting in the hot loop)
    for k in 1:nfiles
        ts_arr[k] = [Dates.format(df.startdatetime[k], ISO_8601), Dates.format(df.enddatetime[k], ISO_8601)]
    end

    # Parallel HDF5 reads (open in "r" — no write lock needed)
    names = String[]
    Threads.@threads for k in 1:nfiles
        h5open(joinpath(path, df.file[k]), "r") do src
            push!(names, attrs(src["dataset1"]["what"])["prodname"])
            data_arr[k] = permutedims(Array(src[join(mapping["structure"]["data"], "/")]))
        end
    end
    name = "$(first(unique(names)))_$(Dates.format(df.startdatetime[1], "yyyymmddHHMMSS"))_$(Dates.format(df.startdatetime[end], "yyyymmddHHMMSS"))"

    # ── Sequential DB push ────────────────────────────────────────────────
    LibPQ.Connection(connection) do conn
        table, rid = db_initialize_table(conn, proj, name, user_id; category=mapping["category"], format="raster", input=true)
        for k in 1:nfiles
            @info "Pushing band $k of $nfiles to DB..."
            db_push_band_to_table!(conn, table, rid, data_arr[k], proj.ny, ts_arr[k])
        end
        # Store full band timestamp list in metadata.dataset for temporal extent auto-fill
        # Shape: [{"start": "yyyy-mm-ddTHH:MM:SS", "end": "yyyy-mm-ddTHH:MM:SS"}, ...]
        timestamps_json = JSON3.write([Dict("start" => ts[1], "end" => ts[2]) for ts in ts_arr])
        LibPQ.execute(conn,
            "UPDATE metadata.dataset SET timestamps = \$1::jsonb WHERE data_table = \$2;",
            (timestamps_json, table))
        # Track upload stats — sum all file sizes in the folder
        total_bytes = sum(filesize(joinpath(path, df.file[k])) for k in 1:nfiles; init=Int64(0))
        stats_id = LibPQ.execute(conn, """
            INSERT INTO core.stats (user_id, upload_bytes, upload_count, last_upload)
            VALUES (\$1, \$2, 1, NOW())
            ON CONFLICT (user_id) DO UPDATE SET
                upload_bytes = core.stats.upload_bytes + EXCLUDED.upload_bytes,
                upload_count = core.stats.upload_count + 1,
                last_upload  = NOW()
            RETURNING id;
        """, (user_id, total_bytes))[1, 1]
        stats_hash = bytes2hex(sha256(string(stats_id)))
        LibPQ.execute(conn, "UPDATE core.stats SET id_hash = \$1 WHERE id = \$2 AND id_hash IS NULL;", (stats_hash, stats_id))
    end
    msg = "✅ Done! - Folder '$(basename(path))' imported successfully as '$name' in category '$(mapping["category"])'."
    @info msg
    return Dict(
        "msg"      => msg,
        "path"     => path,
        "category" => mapping["category"],
        "table"    => name,
    )
end

function inca_from_folder(connection::String, path::String, files::Vector{String}, user::Dict; ISO_8601::String = "yyyy-mm-ddTHH:MM:SS")
    # Load assimilation mapping for INCA from DB
    mapping = LibPQ.Connection(connection) do conn
        res = LibPQ.execute(conn,
            "SELECT json FROM metadata.catalogs WHERE name = 'assimilation_catalog' LIMIT 1;")
        df = DataFrames.DataFrame(res)
        isempty(df) && error("assimilation_catalog not found in metadata.catalogs")
        JSON3.read(df[1, :json],Dict)["folder"]["INCA"]
    end
    # Extract dates & times
    n  = length(files)
    df = DataFrame(
        file     = Vector{String}(undef, n),
        ts_start = Vector{DateTime}(undef, n),
        ts_end   = Vector{DateTime}(undef, n),
    )
    # Parse timestamps from filename (RR_INCA_{YYYY}{MM}{DD}{HHMM}.nc) & created chronologically sorted DataFrame
    for (i, file) in enumerate(files)
        stem   = splitext(basename(file))[1]  # e.g. "RR_INCA_202304011200"
        parts  = split(stem, '_')
        header = parts[3]           # e.g. "202304011200"
        
        year   = parse(Int, header[1:4])
        month  = parse(Int, header[5:6])
        day    = parse(Int, header[7:8])
        hh     = parse(Int, header[9:10])
        mm     = parse(Int, header[11:12])

        df.file[i]     = file
        df.ts_start[i] = DateTime(Date(year, month, day), Time(hh, mm, 0))
        h5open(joinpath(path, file), "r") do src
            df.ts_end[i] = df.ts_start[i] + Second(maximum(src["time"][:]))
        end
    end
    sort!(df, :ts_start)

    # Extract projection from first file (shared across all files)
    proj = h5open(joinpath(path, df.file[1]),"r") do ncfile   
        src,trgt = mapping["projection"]["source"],mapping["projection"]["target"]
        chx,chy  = ncfile["chx"][:], ncfile["chy"][:]
        corners  = Dict()
        gdal.createcoordtrans(gdal.importEPSG(src), gdal.importEPSG(trgt)) do transform
            for (label, x_key, y_key) in [
                ("LL", minimum(chx), minimum(chy)),
                ("LR", maximum(chx), minimum(chy)),
                ("UL", minimum(chx), maximum(chy)),
                ("UR", maximum(chx), maximum(chy)),
            ]
                pt = gdal.fromWKT("POINT ($x_key $y_key)")
                gdal.transform!(pt, transform)
                corners[label] = (gdal.getx(pt, 0), gdal.gety(pt, 0))
            end
        end
        dx = abs(chx[2] - chx[1])
        dy = -abs(chy[2] - chy[1])
        x0 = corners["UL"][1]-0.5*dx
        y0 = corners["UL"][2]-0.5*dy
        nx = length(chx)
        ny = length(chy)
        return (;
            proj4 = gdal.toPROJ4(gdal.importEPSG(trgt)),
            srid  = trgt,
            nx    = nx,
            ny    = ny,
            dx    = dx,
            dy    = dy,
            x0    = x0,
            y0    = y0,
        )
    end

    # Prepare table name based on category
    user_id = user["id"]
    names = Vector{String}(undef, nrow(df))
    for (k,file) in enumerate(df.file)
        @info "Ingesting file $k of $(nrow(df))..."
        data,times = h5open(joinpath(path, file),"r") do ncfile  
            fields = keys(ncfile)
            if "RR" ∈ fields
                mapping["product"] = "RR"
            elseif "RP" ∈ fields
                mapping["product"] = "RP"
            end
            return Array(ncfile[mapping["product"]][:,:,:]),Array(ncfile["time"][:])
        end
        dts  = vcat(diff(times), times[end]-times[end-1])
        name = "$(mapping["product"])_INCA_$(Dates.format(df.ts_start[k], "yyyymmddHHMMSS"))_$(Dates.format(df.ts_end[k], "yyyymmddHHMMSS"))"
        names[k] = name
        # Sequential DB push
        LibPQ.Connection(connection) do conn
            table, rid = db_initialize_table(conn, proj, name, user_id; category=mapping["category"], format="raster", input=true)
            ts_list = Vector{Vector{String}}(undef, length(dts))
            for (b,dt) in enumerate(dts)
                @info "Pushing band $b of $(length(times)) to DB..."
                ts_start = df.ts_start[k] + Second(times[b])
                ts_end   = ts_start + Second(dt)
                ts       = [Dates.format(ts_start, ISO_8601), Dates.format(ts_end, ISO_8601)]
                ts_list[b] = ts
                db_push_band_to_table!(conn, table, rid, reverse(permutedims(data[:,:,b]), dims=1), proj.ny, ts)
            end
            # Store full band timestamp list in metadata.dataset for temporal extent auto-fill
            # Shape: [{"start": "yyyy-mm-ddTHH:MM:SS", "end": "yyyy-mm-ddTHH:MM:SS"}, ...]
            timestamps_json = JSON3.write([Dict("start" => ts[1], "end" => ts[2]) for ts in ts_list])
            LibPQ.execute(conn,
                "UPDATE metadata.dataset SET timestamps = \$1::jsonb WHERE data_table = \$2;",
                (timestamps_json, table))
            # Track upload stats — current file only
            total_bytes = filesize(joinpath(path, file))
            stats_id = LibPQ.execute(conn, """
                INSERT INTO core.stats (user_id, upload_bytes, upload_count, last_upload)
                VALUES (\$1, \$2, 1, NOW())
                ON CONFLICT (user_id) DO UPDATE SET
                    upload_bytes = core.stats.upload_bytes + EXCLUDED.upload_bytes,
                    upload_count = core.stats.upload_count + 1,
                    last_upload  = NOW()
                RETURNING id;
            """, (user_id, total_bytes))[1, 1]
            stats_hash = bytes2hex(sha256(string(stats_id)))
            LibPQ.execute(conn, "UPDATE core.stats SET id_hash = \$1 WHERE id = \$2 AND id_hash IS NULL;", (stats_hash, stats_id))
        end
    end
    msg = "✅ Done! - Folder '$(basename(path))' imported successfully in category '$(mapping["category"])' as: \n+ $(join(names, "\n+ "))."
    @info msg
    return Dict(
        "msg"      => msg,
        "path"     => path,
        "category" => mapping["category"],
        "table"    => join(names, ", "),
    )
end


































function add_from_folder(connection::String, path::String, product::Union{Nothing,String}, schema::String, tile_size::String, overwrite::Bool, user::Dict; ISO_8601::String = "yyyy-mm-ddTHH:MM:SS")
    # Load assimilation mapping from DB
    mapping = LibPQ.Connection(connection) do conn
        res = LibPQ.execute(conn,
            "SELECT json FROM metadata.catalogs WHERE name = 'assimilation_catalog' LIMIT 1;")
        df = DataFrames.DataFrame(res)
        isempty(df) && error("assimilation_catalog not found in metadata.catalogs")
        JSON3.read(df[1, :json])["folder"]
    end
    if product ∉ keys(mapping)
        throw(ArgumentError("Unknown product: $product. Available options are: $(join(collect(keys(mapping)), ", "))."))
    end
    # Determine file type based on extension
    dir   = lowercase(basename(splitext(path)[1])) |> x -> replace(x, r"[^a-z0-9_]" => "_")
    files = filter(f -> !startswith(f, "."), readdir(path))
    exts  = String[]
    for file in files
        push!(exts, splitext(file)[2][2:end])
    end
    exts = (unique(exts))

    try 
        if product == "CPC"
            return cpc_from_folder(connection, path, files, user)
        elseif product == "PRECIP"
            return precip_from_folder(connection, path, files, user)
        elseif product == "INCA"
            return inca_from_folder(connection, path, files, user)
        else
            throw(ArgumentError("Unsupported product: $product. Available options are: $(join(collect(keys(mapping)), ", "))."))
        end
    catch e
        @error "Error in add_from_folder" exception=(e, catch_backtrace())
        rethrow(e)
    end
end