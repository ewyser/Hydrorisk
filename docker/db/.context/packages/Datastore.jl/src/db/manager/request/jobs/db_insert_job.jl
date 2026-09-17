export insert_job_in_db

function insert_job_in_db(job::Any, db::DataBase{T};
    user_id=nothing, config=nothing,
    schema::String="processing", table::String="jobs") where {T <: PostgreSQLDatabase}
    id_hash   = job["info"]["id"]
    jld2_path = job.path
    LibPQ.Connection(db.connection) do conn
        if !isnothing(user_id) && !isnothing(config)
            # Full single INSERT — id_hash generated client-side, no pre-existing row
            LibPQ.execute(conn,
                """
                INSERT INTO $(schema).$(table)
                    (id_hash, user_id, json, created_at, status, jld2_path)
                VALUES
                    (\$1, \$2, \$3::jsonb, \$4, 'pending', \$5);
                """,
                (id_hash, user_id, JSON3.write(config), job["info"]["Ts"], jld2_path)
            )
        else
            # Legacy path: upsert in case a row was pre-created externally
            existing = LibPQ.execute(conn,
                "SELECT 1 FROM $(schema).$(table) WHERE id_hash = \$1 LIMIT 1;",
                (id_hash,)
            )
            if DataFrames.nrow(DataFrames.DataFrame(existing)) > 0
                LibPQ.execute(conn,
                    "UPDATE $(schema).$(table) SET jld2_path = \$1 WHERE id_hash = \$2;",
                    (jld2_path, id_hash)
                )
            else
                LibPQ.execute(conn,
                    """
                    INSERT INTO $(schema).$(table)
                        (id_hash, created_at, status, jld2_path)
                    VALUES
                        (\$1, \$2, \$3, \$4);
                    """,
                    (id_hash, job["info"]["Ts"], "pending", jld2_path)
                )
            end
        end
    end
    return nothing
end
function insert_job_in_db(job::Any, db::Nothing; user_id=nothing, config=nothing,
    schema::String="processing", table::String="jobs")
    return nothing
end