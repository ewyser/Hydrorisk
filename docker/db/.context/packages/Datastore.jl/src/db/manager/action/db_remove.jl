export db_delete_job,db_remove_data,db_remove


"""
    db_delete_job(connection::String; user, id_hash) -> Dict

Delete the job identified by `id_hash` from `processing.jobs`, provided it
belongs to the authenticated `user`. Returns a confirmation dict.

# Keyword arguments
- `user::AbstractDict`   : authenticated user dict (must contain `"id"`).
- `id_hash::String`      : unique hash of the job to delete.
"""
function db_delete_job(
    connection::String
    ;
    user::Union{Nothing,Dict}=nothing,
    id_hash::Union{Nothing,String}=nothing,
)
    user_id = user["id"]

    LibPQ.Connection(connection) do conn
        # Fetch the job by id_hash alone
        job_entry = LibPQ.execute(conn,
            "SELECT * FROM processing.jobs WHERE id_hash = \$1 LIMIT 1;",
            (id_hash,)
        )
        df = DataFrame(job_entry)
        if nrow(df) == 0
            error("Job $id_hash not found.")
        end

        job_owner_id = df[1, :user_id]
        if job_owner_id != user_id
            error("Job $id_hash does not belong to user $user_id.")
        end

        # Drop result datasets (data tables + metadata entries) linked to this job
        result_ds = DataFrame(LibPQ.execute(conn,
            """SELECT d.data_table
               FROM metadata.dataset d
               JOIN processing.jobs j ON j.id = d.job_id
               WHERE j.id_hash = \$1 AND d.result = TRUE;""",
            (id_hash,)
        ))
        for row in eachrow(result_ds)
            tbl = row[:data_table]
            LibPQ.execute(conn, "DROP TABLE IF EXISTS data.\"$tbl\" CASCADE;")
            LibPQ.execute(conn,
                "DELETE FROM metadata.dataset WHERE data_table = \$1;",
                (tbl,)
            )
        end

        # tasks are removed automatically via ON DELETE CASCADE on processing.tasks.job_id
        LibPQ.execute(conn,
            "DELETE FROM processing.jobs WHERE id_hash = \$1;",
            (id_hash,)
        )
        return dirname(df[1, :jld2_path]),Dict("msg" => "Job $id_hash deleted.","id_hash" => id_hash,)
    end
end

"""
    db_remove_data(connection::String; user, data_table)

Remove a dataset from the database: drops the PostGIS table and deletes the
`metadata.dataset` entry.

# Keyword arguments
- `user::Union{Dict,Nothing}`: user dict (same shape as `db_list_data`). Used to
  resolve `user_id` for permission checks and for the interactive CLI prompt.
- `data_table::Union{Nothing,String}`: fully-qualified table name to remove
  (e.g. `"data.raster_abc123"`). When `nothing`, an interactive terminal menu
  lets the user select from the available datasets.

# Returns
JSON string with `{"removed" => data_table}` on success.
"""
function db_remove_data(
    connection::String
    ;
    user::Union{Nothing,Dict}       = nothing,
    data_table::Union{Nothing,String} = nothing,
)
    user_id = user !== nothing && haskey(user, "id") ? user["id"] : nothing

    # ── CLI mode: interactive selection ───────────────────────────────────────
    if isnothing(data_table)
        data   = db_list_data(connection; user = user)
        groups = collect(keys(data))
        isempty(groups) && error("No datasets available to remove.")
        group_idx = request("Select category to remove from:", RadioMenu(groups))
        group     = groups[group_idx]
        items     = data[group]
        list      = items isa Vector ? [d["data_table"] for d in items] : collect(keys(items))
        isempty(list) && error("No datasets in category '$group'.")
        idx        = request("Select dataset to remove:", RadioMenu(list))
        data_table = list[idx]
    end

    # ── Remove table + metadata entry ────────────────────────────────────────
    LibPQ.Connection(connection) do conn
        try
            LibPQ.execute(conn, "DROP TABLE IF EXISTS data.$(data_table) CASCADE;")
            LibPQ.execute(conn, "DELETE FROM metadata.dataset WHERE data_table = \$1;", (data_table,))
            println("🗑  Removed $data_table and its metadata entry.")
        catch e
            error("Failed to remove $data_table: $e")
        end
    end

    return JSON3.write(Dict("removed" => data_table))
end

function db_remove(connection::String)
    function db_list_remove()
        return Dict{String,Function}(
            "Remove data from db" => db_remove_data,
        )
    end
    # Prompt user
    list       = db_list_remove()
    descs,funs = collect(keys(list)),collect(values(list))
    return funs[request("What to do ?:",RadioMenu(descs))](connection)
end