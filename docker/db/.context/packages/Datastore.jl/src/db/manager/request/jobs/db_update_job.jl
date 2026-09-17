export update_job_in_db!, upsert_task_in_db!, remove_task_in_db!

function update_job_in_db!(id_hash::String, db::DataBase{T}; up::Union{Nothing,Dict} = nothing, schema::String="processing", table::String="jobs",) where {T <: PostgreSQLDatabase}
    try
        if !isnothing(up)
            LibPQ.Connection(db.connection) do conn
                for (k, v) ∈ up
                    LibPQ.execute(conn,
                        """UPDATE $(schema).$(table) SET $k = \$1 WHERE id_hash = \$2;""",
                        (v, id_hash))
                end
            end
            attribute = keys(up)
            return Dict("msg" => "Job '$id_hash' attribute(s) $(join(attribute, ", ")) successfully updated", "status" => 200)
        end
    catch e
        return Dict("msg" => "Failed to update job '$id_hash' in database: $(e)", "status" => 500)
    end
end


function upsert_task_in_db!(id_hash::String, db::DataBase{T};
    name::String,
    status::Union{String,Nothing}       = nothing,
    percent::Union{Real,Nothing}        = nothing,
    step::Union{String,Nothing}         = nothing,
    started_at::Union{String,Nothing}   = nothing,
    completed_at::Union{String,Nothing} = nothing,
    err_msg::Union{String,Nothing}      = nothing,
) where {T <: PostgreSQLDatabase}
    # LibPQ maps `missing` → NULL; `nothing` is serialised as the string "nothing"
    _null(x) = isnothing(x) ? missing : x

    # id_hash = job["info"]["hash"]
    LibPQ.Connection(db.connection) do conn
        # Check if task row already exists for this job + name
        res    = LibPQ.execute(conn,
            """SELECT t.id FROM processing.tasks t
               JOIN processing.jobs j ON j.id = t.job_id
               WHERE j.id_hash = \$1 AND t.name = \$2 LIMIT 1;""",
            (id_hash, name))
        exists = DataFrames.nrow(DataFrames.DataFrame(res)) > 0

        if exists
            fields = String[]
            vals   = Any[]
            for (col, val) in [
                ("status",       _null(status)),
                ("percent",      isnothing(percent) ? missing : Float64(percent)),
                ("step",         _null(step)),
                ("started_at",   _null(started_at)),
                ("completed_at", _null(completed_at)),
                ("err_msg",      _null(err_msg)),
            ]
                ismissing(val) && continue
                push!(vals, val)
                push!(fields, "$col=\$$(length(vals))")
            end
            if !isempty(fields)
                push!(vals, id_hash); push!(vals, name)
                LibPQ.execute(conn,
                    """UPDATE processing.tasks t
                       SET $(join(fields, ", "))
                       FROM processing.jobs j
                       WHERE j.id_hash = \$$(length(vals)-1)
                         AND t.job_id  = j.id
                         AND t.name    = \$$(length(vals));""",
                    vals)
            end
        else
            LibPQ.execute(conn,
                """INSERT INTO processing.tasks
                       (job_id, name, status, percent, step, started_at, completed_at, err_msg)
                   SELECT j.id, \$1, \$2, \$3, \$4, \$5, \$6, \$7
                   FROM processing.jobs j
                   WHERE j.id_hash = \$8;""",
                (name,
                 _null(status),
                 isnothing(percent) ? missing : Float64(percent),
                 _null(step),
                 _null(started_at),
                 _null(completed_at),
                 _null(err_msg),
                 id_hash))
        end
    end
    return nothing
end

function remove_task_in_db!(id_hash::String, db::DataBase{T};
    name::String,
) where {T <: PostgreSQLDatabase}
    try
        LibPQ.Connection(db.connection) do conn
            LibPQ.execute(conn,
            """DELETE FROM processing.tasks t
                USING processing.jobs j
                WHERE j.id_hash = \$1 AND t.job_id = j.id AND t.name = \$2;""",
            (id_hash, name))
        end        
        return Dict("msg" => "Task '$name' for job '$id_hash' successfully removed from database", "status" => 200)
    catch e
        return Dict("msg" => "Failed to remove task '$name' for job '$id_hash' in database: $(e)", "status" => 500)
    end
end