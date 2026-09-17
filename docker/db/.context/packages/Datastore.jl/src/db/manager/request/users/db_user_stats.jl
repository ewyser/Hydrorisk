export db_user_stats
"""
    db_user_stats(connection; user_id)

Retrieve upload statistics for a given user from `core.stats`.

Returns a `Dict` with keys:
- `"upload_bytes"` — total bytes uploaded (Int)
- `"upload_count"` — number of uploads (Int)
- `"last_upload"`  — ISO timestamp of last upload or `nothing`
"""
function db_user_stats(connection::String; user_id::Union{Nothing,Integer}=nothing)
    if isnothing(user_id)
        return Dict("upload_bytes" => 0, "upload_count" => 0, "last_upload" => nothing)
    end
    LibPQ.Connection(connection) do conn
        result = LibPQ.execute(conn, """
            SELECT upload_bytes, upload_count, last_upload
            FROM core.stats
            WHERE user_id = \$1;
        """, (user_id,)) |> DataFrame
        if nrow(result) == 0
            return Dict("upload_bytes" => 0, "upload_count" => 0, "last_upload" => nothing)
        end
        row = result[1, :]
        return Dict(
            "upload_bytes" => coalesce(row.upload_bytes, 0),
            "upload_count" => coalesce(row.upload_count, 0),
            "last_upload"  => ismissing(row.last_upload) ? nothing : string(row.last_upload),
        )
    end
end
