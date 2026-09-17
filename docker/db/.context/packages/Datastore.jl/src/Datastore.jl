module Datastore

# Define module location as const
const ROOT = dirname(@__DIR__)
const DIR  = joinpath(ROOT,"src")
const DB   = joinpath(ROOT,"db")

# Include boot file
include(joinpath(DIR,"boot/boot.jl"))

"""
    __init__()

Module initialisation hook — called automatically by Julia when `OsmotiC` is first loaded.

Performs the following steps in order:
1. Creates the local `/db` directory and the job directory if they do not exist.
2. Generates (or refreshes) the export catalog JSON file via `get_export_catalog`.
3. Attempts to connect to the PostgreSQL database using the default configuration
   (`localhost:5432`, database `hydrorisk`, user `postgres`).  
   If the connection fails, a warning is printed and `info.db` is set to `nothing`.
4. On successful connection, upserts the export catalog JSON into `metadata.export_catalog`.
5. Prints the welcome message via `welcome_log`.
"""
function __init__(; clock::Int = 5)
    return welcome_log()
end
function path_to_db_obj()
    return joinpath(info.sys.db,"db.jld2")

end
end