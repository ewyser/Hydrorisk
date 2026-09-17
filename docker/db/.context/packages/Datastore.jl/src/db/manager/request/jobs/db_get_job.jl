export db_get_job, db_get_tasks

function db_get_job(connection::String; hash::Union{Nothing,String}=nothing, id::Union{Nothing,Integer}=nothing)
    LibPQ.Connection(connection) do conn
        if !isnothing(hash)
            query = LibPQ.execute(conn, 
                """
                SELECT * FROM processing.jobs WHERE id_hash = \$1
                """,
                (hash,)
            )
        elseif !isnothing(id)
            query = LibPQ.execute(conn, 
                """
                SELECT * FROM processing.jobs WHERE id = \$1
                """,
                (id,)
            )
        end
        return DataFrame(query)
    end    
end

function db_get_tasks(connection::String; hash::Union{Nothing,String}=nothing, id::Union{Nothing,Integer}=nothing)
    LibPQ.Connection(connection) do conn
        if !isnothing(hash)
            query = LibPQ.execute(conn, 
                """
                SELECT * FROM processing.tasks WHERE job_id_hash = \$1
                """,
                (hash,)
            )
        elseif !isnothing(id)
            query = LibPQ.execute(conn, 
                """
                SELECT * FROM processing.tasks WHERE job_id = \$1
                """,
                (id,)
            )
        end
        return DataFrame(query)
    end    
end