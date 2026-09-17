export db_list_jobs

"""
    db_list_jobs(connection::String; user) -> Vector{Dict}

Return all jobs belonging to `user` from `processing.jobs`, ordered by
`created_at` descending. Each item includes the full simulation config under
the `"config"` key so callers can pre-populate a wizard.

# Keyword arguments
- `user::Dict` : authenticated user dict (must contain `"id"`).
"""
function db_list_jobs(
    connection::String
    ;
    user::AbstractDict,
)
    user_id = user["id"]

    rows = LibPQ.Connection(connection) do conn
        result = LibPQ.execute(conn,
            """
            SELECT
                j.id_hash,
                j.status,
                COALESCE(j.submitted_at, j.created_at) AS created_at,
                j.completed_at,
                j.err_msg,
                j.json -> 'dest' ->> 'prefix'   AS prefix,
                j.json                           AS config,
                COALESCE(
                    json_agg(
                        json_build_object(
                            'name',         t.name,
                            'status',       t.status,
                            'percent',      t.percent,
                            'step',         t.step,
                            'started_at',   t.started_at,
                            'completed_at', t.completed_at,
                            'err_msg',      t.err_msg
                        ) ORDER BY CASE t.name
                            WHEN 'prepare' THEN 1
                            WHEN 'execute' THEN 2
                            WHEN 'post'    THEN 3
                            ELSE 4
                        END
                    ) FILTER (WHERE t.id IS NOT NULL),
                    '[]'::json
                ) AS tasks
            FROM processing.jobs j
            LEFT JOIN processing.tasks t ON t.job_id = j.id
            WHERE j.user_id = \$1
            GROUP BY j.id
            ORDER BY COALESCE(j.submitted_at, j.created_at) DESC;
            """,
            (user_id,)
        )
        DataFrame(result)
    end

    return map(eachrow(rows)) do r
        d = Dict{String,Any}()
        for k in names(rows)
            k in ("config", "tasks") && continue
            d[k] = r[k]
        end
        raw = r[:config]
        d["config"] = (isnothing(raw) || ismissing(raw)) ? nothing : JSON3.read(string(raw), Dict)
        raw_tasks = r[:tasks]
        d["tasks"] = (isnothing(raw_tasks) || ismissing(raw_tasks)) ? [] : JSON3.read(string(raw_tasks), Vector{Dict})
        d
    end
end
