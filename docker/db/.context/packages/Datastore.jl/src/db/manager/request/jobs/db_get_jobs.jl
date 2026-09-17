export db_get_jobs

function db_get_jobs(db::DataBase{T};
    schema::String="processing",
    table::String="jobs",
    statuses::Union{Nothing,Vector{String}}=nothing,
    order_by::Union{Nothing,String}=nothing,
    limit::Union{Nothing,Integer}=nothing,
    ) where {T <: PostgreSQLDatabase}
    LibPQ.Connection(db.connection) do conn
        suffix = (isnothing(order_by) ? "" : " ORDER BY $order_by") * (isnothing(limit) ? "" : " LIMIT $limit")
        query = if isnothing(statuses)
            LibPQ.execute(conn, "SELECT * FROM $(schema).$(table)$(suffix);")
        else
            placeholders = join(["\$$i" for i in eachindex(statuses)], ", ")
            LibPQ.execute(conn, "SELECT * FROM $(schema).$(table) WHERE status IN ($placeholders)$(suffix);", statuses)
        end
        df = DataFrame(query)
        return df
    end
end
