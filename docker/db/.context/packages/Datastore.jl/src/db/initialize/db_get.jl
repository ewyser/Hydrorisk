export load_env!, get_db, add_db, add_db!

"""
    load_env!()

Populate `ENV` from `env/config.toml` in the project root.

Called at the start of `__init__` so it runs on every module load, including
when Julia restores the module from its precompilation cache (where top-level
code would otherwise be skipped).

Keys already present in `ENV` (i.e. set in the shell before starting Julia)
are never overwritten — the file only fills in missing values.

Expected TOML structure:
```toml
[database]
password = "****"
host     = "localhost"
port     = 5432
user     = "postgres"
name     = "hydrorisk"

[server]
api = true
```
"""
function load_env!(path::Union{Nothing,String})
    function _load(file::String)
        cfg = TOML.parsefile(file)
        for (section, key, env_key) in [
            ("database", "password", "PSWD_DB"         ),
            ("database", "host",     "HYDRORISK_DB_HOST"),
            ("database", "port",     "HYDRORISK_DB_PORT"),
            ("database", "user",     "HYDRORISK_DB_USER"),
            ("database", "name",     "HYDRORISK_DB_NAME"),
            ("server",   "api",      "HYDRORISK_API"    ),
        ]
            val = get(get(cfg, section, Dict()), key, nothing)
            if !isnothing(val) && !haskey(ENV, env_key)
                ENV[env_key] = string(val)
            end
        end
    end
    function _warn()
        @warn """No env provided. The directory `env` should contain a 'db-config.toml' file with the following content:
            [database]
            password = "****"
            host     = "localhost"
            port     = 5432
            user     = "postgres"
            name     = "hydrorisk"

            [server]
            api = true
        """
    end

    if isnothing(path)
        # Check if environment variables are already set; if so, skip loading from file
        VARS = [
            "PSWD_DB",
            "HYDRORISK_DB_HOST",
            "HYDRORISK_DB_PORT",
            "HYDRORISK_DB_USER",
            "HYDRORISK_DB_NAME",
            "HYDRORISK_API"
        ]
        missing_vars = String[]
        for var in VARS
            if !haskey(ENV, var)
                push!(missing_vars, var)
            end
        end
        if length(missing_vars) == length(VARS)
            _warn()
            while true
                println("Please enter path/to/env to directory:")
                path = readline()
                if !isdir(path)
                    @warn "Invalid path. Please enter a valid path to env directory."
                else
                    path = path
                    break
                end
            end
        elseif length(missing_vars) > 0
            throw(ErrorException("The following environment variables are missing: $(join(missing_vars, ", "))"))
        else
            return @info "Environment variables already set. Skipping loading from file."
        end
    elseif isa(path,String)
        if !isdir(path)
            throw(ErrorException("❌ Environment directory '$path' not found."))
        end
    end
    file = joinpath(path, "db-config.toml")
    if !isfile(file)
        throw(ErrorException("❌ Environment file '$file' not found. Cannot initialize Datastore."))
    else
        @info "Loading environment variables from '$file'..."
        _load(file)
        return nothing
    end
end

function get_db(; path::Union{String, Nothing} = nothing, dbs::Tuple=("Select 🛢  DB type for Datastore.jl 🌊 v$(get_version()):",[PostgreSQLDatabase, SQLiteDatabase]), )
    # Load environment variables from config.toml
    load_env!(path)
    # Create / Load db as a DataBase object
    db = db_create(dbs[2][1])
    @info "Database linked successfully."
    return db
end

function _write_catalog_to_db(db::DataBase{<:AbstractDatabase}, catalogs::Dict{String,<:Any})
    for (name, catalog) in catalogs
        json_str = JSON3.write(catalog)
        LibPQ.Connection(db.connection) do conn
            LibPQ.execute(conn, "DELETE FROM metadata.catalogs WHERE name = \$1;", (name,))
            result = LibPQ.execute(conn, """
                INSERT INTO metadata.catalogs (name, json)
                VALUES (\$1, \$2)
                RETURNING id;
                """, (name, json_str))
            id = result[1, 1]
            id_hash = bytes2hex(sha256(string(id)))
            LibPQ.execute(conn, "UPDATE metadata.catalogs SET id_hash = \$1 WHERE id = \$2;", (id_hash, id))
        end
    end
    return nothing
end
function add_db(; catalogs::Union{Nothing,Dict{String,<:Any}} = nothing, env::Union{String, Nothing} = nothing)
    db = get_db(; path = env)
    if isa(catalogs, Dict)
        _ = _write_catalog_to_db(db, catalogs)
    end
    return db
end
function add_db!(self::Any; catalogs::Union{Nothing,Dict{String,<:Any}} = nothing, env::Union{String, Nothing} = nothing)
    self.db = get_db(; path = env)
    if isa(catalogs, Dict)
        _ = _write_catalog_to_db(self.db, catalogs)
    end
    return nothing
end