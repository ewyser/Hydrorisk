export db_initialize_table, db_push_band_to_table!

function db_initialize_table(conn, proj::NamedTuple, name::String, user_id::Integer; category::String="timeseries", format::String="raster", input::Bool=false, job_id::Union{Nothing,Integer}=nothing)
    uuid  = uuid4()
    table = "raster_$(replace(string(uuid), "-" => "_"))"
    # Add entry for data.table in metadata.dataset
    LibPQ.execute(conn, """
        INSERT INTO metadata.dataset (
            id_hash, user_id, geom, format, category, name, data_table, srid, table_cols, created_at, input, result, job_id
        ) VALUES (
            '$(string(uuid))',
            '$user_id',
            '$( "RASTER")',
            '$format',
            '$category',
            '$name',
            '$table',
            $(proj.srid),
            ARRAY['rid','rast','start_ts','end_ts']::text[],
            NOW(),
            $input,
            $(! input),
            $(isnothing(job_id) ? "NULL" : job_id)
        );
    """)
    LibPQ.execute(conn, """
        CREATE TABLE IF NOT EXISTS data."$table" (
            rid        SERIAL PRIMARY KEY,
            rast       raster,
            start_ts   TEXT,
            end_ts     TEXT
        );
    """)
    # Geometry reference row — start_ts/end_ts NULL marks it as the template (not a band).
    res = LibPQ.execute(conn, """
        INSERT INTO data."$table" (rast, start_ts, end_ts)
        VALUES (ST_MakeEmptyRaster($(proj.nx), $(proj.ny), $(proj.x0), $(proj.y0), $(proj.dx), $(proj.dy), 0, 0, $(proj.srid)), NULL, NULL)
        RETURNING rid;
    """)
    return table, DataFrames.DataFrame(res)[1, :rid]
end

# One band push — INSERTs a fresh 1-band raster row cloned from the geometry template.
# Each push is O(1): ST_SetValues always operates on a 1-band raster regardless of
# how many bands have been pushed before.  NaN pixels become the nodata sentinel -9999.
function db_push_band_to_table!(conn, table, rid, mat::Matrix, ny::Integer, timestamp::Vector{String})
    ts_start = isempty(timestamp) ? "" : first(timestamp)
    ts_end   = isempty(timestamp) ? "" : last(timestamp)

    # Clone the geometry template row into a new 1-band raster row and capture its rid.
    new_rid = DataFrames.DataFrame(LibPQ.execute(conn, """
        INSERT INTO data."$table" (rast, start_ts, end_ts)
        SELECT ST_AddBand(ST_MakeEmptyRaster(rast), '32BF'::text, 0, -9999), \$1, \$2
        FROM   data."$table"
        WHERE  rid = $rid
        RETURNING rid;
    """, (ts_start, ts_end)))[1, :rid]

    # Stream pixel values in row-chunks.  The target is always a 1-band raster so
    # each ST_SetValues call is O(1) regardless of total band count.
    chunk_size = round(Int, ny/2)
    for row_start in 1:chunk_size:ny
        row_end = min(row_start + chunk_size - 1, ny)
        chunk   = [Float32[isnan(v) ? -9999f0 : v for v in mat[r, :]]
                   for r in row_start:row_end]
        LibPQ.execute(conn, """
            UPDATE data."$table"
            SET rast = ST_SetValues(rast, 1, 1, $row_start, \$1::double precision[][])
            WHERE rid = $new_rid;
        """, (chunk,))
    end
end