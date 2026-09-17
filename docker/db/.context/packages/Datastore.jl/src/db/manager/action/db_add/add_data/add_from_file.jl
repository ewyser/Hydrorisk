function add_from_file(connection::String, path::String, category::Union{Nothing,String}, schema::String, tile_size::String, overwrite::Bool, user::Dict)
    # Fetch valid categories from metadata.catalogs
    valid_categories = LibPQ.Connection(connection) do conn
        res = LibPQ.execute(conn,
            "SELECT json FROM metadata.catalogs WHERE name = 'import_catalog' LIMIT 1;")
        df = DataFrames.DataFrame(res)
        isempty(df) ? String[] : collect(keys(JSON3.read(df[1, :json], Dict)))
    end

    # Set category (prompt if not provided)
    if isnothing(category)
        if isempty(valid_categories)
            print("Specify a category to assign to this entry: ")
            category = strip(readline())
            isempty(category) && error("Category is required.")
        else
            category = valid_categories[request("Specify a category:", RadioMenu(valid_categories))]
        end
    else
        if !isempty(valid_categories) && category ∉ valid_categories
            error("Invalid category '$category'. Valid: $(join(sort(valid_categories), ", "))")
        end
    end

    # Determine file type based on extension
    file    = lowercase(basename(splitext(path)[1])) |> x -> replace(x, r"[^a-z0-9_]" => "_")
    ext     = lowercase(splitext(path)[2][2:end])
    format  = db_list_formats()[ext]
    uuid    = uuid4()
    table   = "$(format)_$(replace(string(uuid), "-" => "_"))"
    srid    = get_srid(path)
    geom    = get_geometry_type(path)
    user_id = user["id"]

    # Summarize import parameters
    @info """📂 Schema   : $schema
    📄 Table    :  $file ↦ $table
    📁 File type: $ext ↦ $format)"""

    # Connect to database, and import data
    @info "🧩 Checking PostGIS extensions..."
    LibPQ.Connection(connection) do conn
        LibPQ.execute(conn, "CREATE EXTENSION IF NOT EXISTS postgis;")
        LibPQ.execute(conn, "CREATE EXTENSION IF NOT EXISTS postgis_raster;")
    end

    return LibPQ.Connection(connection) do conn
            LibPQ.execute(conn, "BEGIN;")
            msg = nothing
            try
                LibPQ.execute(conn, "SET search_path TO \"$schema\", public;")
                if overwrite
                    @info "♻️ Overwrite enabled — dropping existing table if present..."
                    LibPQ.execute(conn, "DROP TABLE IF EXISTS \"$schema\".\"$table\" CASCADE;")
                end
                # Import data as data.table based on file type
                col_names = nothing
                if format == "table"
                    @info "📊 Importing CSV table..."
                    df = CSV.read(path, DataFrame)
                    col_defs = String[]
                    for (name, col) in zip(names(df), eachcol(df))
                        clean_name = replace(name, r"[^A-Za-z0-9_]" => "_")
                        type_str = eltype(col) <: AbstractFloat ? "FLOAT8" :
                                eltype(col) <: Integer      ? "INT" :
                                "TEXT"
                        push!(col_defs, "\"$clean_name\" $type_str")
                    end
                    create_sql = "CREATE TABLE IF NOT EXISTS \"$schema\".\"$table\" ($(join(col_defs,",")));"
                    LibPQ.execute(conn, create_sql)
                    for row in eachrow(df)
                        vals = join([row[c] === missing ? "NULL" : "'$(row[c])'" for c in names(df)], ",")
                        sql = "INSERT INTO \"$schema\".\"$table\" VALUES ($vals);"
                        LibPQ.execute(conn, sql)
                    end
                    col_names = names(df)
                else
                    if format == "vector"
                        @info "🗺️ Importing shapefile via shp2pgsql..."
                        if isnothing(srid) || srid <= 0
                            @warn "Could not detect a valid SRID for '$file' (got $srid) — geometry will be stored without projection. Re-upload with a correct .prj file."
                            cmd = `shp2pgsql -I "$path" "$schema.$table"`
                        else
                            cmd = `shp2pgsql -I -s $srid "$path" "$schema.$table"`
                        end
                        psql_cmd = `psql "$(connection)"`
                    elseif format == "raster"
                        @info "🌍 Importing raster via raster2pgsql..."
                        if isnothing(srid) || srid <= 0
                            @warn "Could not detect a valid SRID for '$file' (got $srid) — raster will be stored without projection. Re-upload with correct projection metadata."
                            cmd = `raster2pgsql -I -C -M -t $tile_size "$path" "$schema.$table"`
                        else
                            cmd = `raster2pgsql -s $srid -I -C -M -t $tile_size "$path" "$schema.$table"`
                        end
                        psql_cmd = `psql "$(connection)"`
                    end
                    run(pipeline(cmd, psql_cmd))
                end
                # Resolve actual DB column names for vector/raster (queried once after import)
                table_cols = if format == "table"
                    col_names  # CSV col names == DB col names
                elseif format == "vector"
                    DataFrames.DataFrame(LibPQ.execute(conn, """
                        SELECT column_name FROM information_schema.columns
                        WHERE table_schema = 'data' AND table_name = '$table'
                        ORDER BY ordinal_position;
                    """)).column_name |> Vector{String}
                else  # raster (raster2pgsql schema)
                    ["rid", "rast"]
                end
                # Only insert metadata entry after data import succeeded
                db_add_metadata(conn;
                    file=file,
                    format=format,
                    category=category,
                    table=table,
                    col_names=col_names,
                    table_cols=table_cols,
                    srid=srid,
                    geom=geom,
                    user_id=user_id
                )
                # Grant SELECT on the new data table to the user's personal PG role
                pg_role_res = DataFrames.DataFrame(LibPQ.execute(conn,
                    "SELECT pg_role FROM core.users WHERE id = \$1 LIMIT 1;", (user_id,)))
                if !isempty(pg_role_res) && !ismissing(pg_role_res[1, :pg_role])
                    pg_role = pg_role_res[1, :pg_role]
                    LibPQ.execute(conn, "GRANT SELECT ON data.\"$table\" TO \"$pg_role\";")
                end
                # Track upload stats per user (atomic UPSERT)
                if !isnothing(user_id)
                    file_size = isfile(path) ? filesize(path) : Int64(0)
                    stats_id = LibPQ.execute(conn, """
                        INSERT INTO core.stats (user_id, upload_bytes, upload_count, last_upload)
                        VALUES (\$1, \$2, 1, NOW())
                        ON CONFLICT (user_id) DO UPDATE SET
                            upload_bytes = core.stats.upload_bytes + EXCLUDED.upload_bytes,
                            upload_count = core.stats.upload_count + 1,
                            last_upload  = NOW()
                        RETURNING id;
                    """, (user_id, file_size))[1, 1]
                    stats_hash = bytes2hex(sha256(string(stats_id)))
                    LibPQ.execute(conn, "UPDATE core.stats SET id_hash = \$1 WHERE id = \$2 AND id_hash IS NULL;", (stats_hash, stats_id))
                end
                LibPQ.execute(conn, "COMMIT;")
                msg = "✅ Done ! - File '$file' imported successfully."
                @info msg
            catch e
                LibPQ.execute(conn, "ROLLBACK;")
                msg = "❌ Error ! - File '$file' import failed: $(sprint(showerror, e))"
                @error msg
            end
            return Dict(
                "msg"       => msg,
                "path"      => path,
                "schema"    => schema,
                "table"     => table,
                "file_type" => ext,
            )
        end
end