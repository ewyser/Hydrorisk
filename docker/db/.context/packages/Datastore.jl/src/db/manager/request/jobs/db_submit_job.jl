export submit_job_in_db

function submit_job_in_db(user_id::Integer, payload::String, db::DB;
    schema::String="processing", 
    table::String="jobs"
    ) where DB <: AbstractDatabase
    body    = JSON3.read(payload, Dict)
    id_hash = get(get(body, "job", Dict()), "hash", nothing)
    if !isnothing(id_hash)
        exists = LibPQ.Connection(db.connection) do conn
            res = LibPQ.execute(conn,
                "SELECT 1 FROM processing.jobs WHERE id_hash = \$1 LIMIT 1;",
                (id_hash,))
            DataFrames.nrow(DataFrames.DataFrame(res)) > 0
        end
        exists && return jsonresp(Dict("msg" => "Job $id_hash already exists", "status" => 409), status=409)
    end

    LibPQ.Connection(db.connection) do conn
        LibPQ.execute(conn,
            """
            INSERT INTO $(schema).$(table)
                (user_id, id_hash, json, submitted_at, status)
            VALUES
                (\$1, \$2, \$3::jsonb, \$4, \$5);
            """,
            (user_id, id_hash, payload, now(), "submitted")
        )
    end
    return Dict("msg" => "Job $id_hash submitted successfully", "status" => 200)
end