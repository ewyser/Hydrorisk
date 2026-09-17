export db_list_data

function db_list_data(
    connection::String
    ;
    root_dbname::String = "postgres",
    groupby::Union{String,Nothing} = "category",
    filterval::Union{Any,Nothing} = nothing,
    user::Union{Dict,Nothing} = nothing
)
    return LibPQ.Connection(connection) do conn
        sql = """
            SELECT d.*,
                   j.id_hash AS job_id_hash,
                   COALESCE(j.json -> 'dest' ->> 'prefix', LEFT(j.id_hash, 8)) AS job_prefix,
                   j.status AS job_status
            FROM metadata.dataset d
            LEFT JOIN processing.jobs j ON j.id = d.job_id"""
        where_clauses = String[]
        if filterval !== nothing && groupby !== nothing
            push!(where_clauses, "d.$(groupby) = '$(filterval)'")
        end
        if user !== nothing && haskey(user, "id")
            push!(where_clauses, "d.user_id = $(user["id"])")
        end
        if !isempty(where_clauses)
            sql *= " WHERE " * join(where_clauses, " AND ")
        end
        sql *= groupby !== nothing ? " ORDER BY d.$(groupby), d.created_at;" : " ORDER BY d.created_at;"
        query = LibPQ.execute(conn, sql)
        df = DataFrame(query)
        meta_cols = names(df)
        result = Dict{String, Dict{String, Dict{String, Any}}}()
        for row in eachrow(df)
            key = groupby === nothing ? "all" : string(row[groupby])
            if !haskey(result, key)
                result[key] = Dict{String, Dict{String, Any}}()
            end
            attrs = Dict{String, Any}()
            for col in meta_cols
                attrs[col] = row[col]
            end
            result[key][row.data_table] = attrs
        end
        return Dict{String, Vector}(
            cat => collect(values(get(result, cat, Dict())))
            for cat in keys(result)
        )
    end
end