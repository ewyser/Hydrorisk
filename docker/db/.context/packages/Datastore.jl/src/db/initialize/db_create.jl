export db_create
"""
    db_create(; db_name::String="hydrorisk", db_user::String="postgres", db_host::String="localhost", db_port::Int=5432)

Create a new PostgreSQL database and enable PostGIS extensions.

# Keyword Arguments
`db_name::String`: Name of the database to create (default: "hydrorisk").
`db_user::String`: PostgreSQL user (default: "postgres").
`db_host::String`: Host address (default: "localhost").
`db_port::Int`: Port number (default: 5432).

Checks connection, creates the database if it does not exist, enables PostGIS extensions, and grants privileges to the user.
"""
function db_create(
    T::Type{DB}
    ;
) where {DB<:AbstractDatabase}
    env = Dict(
        "host" => get(ENV, "HYDRORISK_DB_HOST", "localhost"),
        "port" => parse(Int, get(ENV, "HYDRORISK_DB_PORT", "5432")),
        "user" => get(ENV, "HYDRORISK_DB_USER", "postgres"),
        "name" => get(ENV, "HYDRORISK_DB_NAME", "hydrorisk"),
        "pswd" => get(ENV, "PSWD_DB", "")
    )
    connect = (;
        admin  = db_connect(env["host"], env["port"], env["user"], "postgres" , env["pswd"]),
        target = db_connect(env["host"], env["port"], env["user"], env["name"], env["pswd"]),
    )
    try
        db_exists = LibPQ.Connection(connect[:admin]) do conn
            res = LibPQ.execute(conn, "SELECT 1 FROM pg_database WHERE datname = \$1;", [env["name"]]) |> DataFrame
            nrow(res) > 0
        end
        if db_exists
            @info "Database '$(env["name"])' already exists. Skipping creation."
        else
            LibPQ.Connection(connect[:admin]) do conn
                # Create database
                println("🧱 Creating new database '$(env["name"])':")
                LibPQ.execute(conn, "CREATE DATABASE \"$(env["name"])\" OWNER \"$(env["user"])\";")
                # Grant privileges
                println("🔒 Granting privileges to user '$(env["user"])'...")
                LibPQ.execute(conn, "GRANT ALL PRIVILEGES ON DATABASE \"$(env["name"])\" TO \"$(env["user"])\";")
                println("""✅ Database setup complete:
                📦 Database: $(env["name"])
                👤 Owner: $(env["user"])
                🌐 Host: $(env["host"])""")
            end
            # Create db structure in the newly created database
            LibPQ.Connection(connect[:target]) do conn
                    # Enable PostGIS and uuid-ossp extensions in the new database
                    println("🧩 Enabling PostGIS extensions in new database: \n + postgis\n + postgis_raster")
                    LibPQ.execute(conn, "CREATE EXTENSION IF NOT EXISTS postgis;")
                    LibPQ.execute(conn, "CREATE EXTENSION IF NOT EXISTS postgis_raster;")
                    order,structure = db_structure()
                    # Create all schemas
                    for schema ∈ keys(structure)
                        LibPQ.execute(conn, "CREATE SCHEMA IF NOT EXISTS $schema;")
                    end
                    # Create all tables
                    for (schema, table) ∈ order
                        columns = structure[schema][table]
                        cols = join([string(col, " ", def) for (col, def) ∈ columns], ", ")
                        LibPQ.execute(conn,"CREATE TABLE IF NOT EXISTS $schema.$table ($cols);")
                    end
                    # Trigger: drop dynamic data table when metadata.dataset row is deleted
                    LibPQ.execute(conn, """
                        CREATE OR REPLACE FUNCTION drop_data_table_on_dataset_delete()
                        RETURNS TRIGGER LANGUAGE plpgsql AS \$\$
                        BEGIN
                            IF OLD.data_table IS NOT NULL THEN
                                EXECUTE format('DROP TABLE IF EXISTS data.%I', OLD.data_table);
                            END IF;
                            RETURN OLD;
                        END;
                        \$\$;
                    """)
                    LibPQ.execute(conn, """
                        DO \$\$ BEGIN
                            IF NOT EXISTS (
                                SELECT FROM pg_trigger
                                WHERE tgname = 'trg_drop_data_table'
                                    AND tgrelid = 'metadata.dataset'::regclass
                            ) THEN
                                CREATE TRIGGER trg_drop_data_table
                                BEFORE DELETE ON metadata.dataset
                                FOR EACH ROW EXECUTE FUNCTION drop_data_table_on_dataset_delete();
                            END IF;
                        END \$\$;
                    """)
                    println("✅ Cleanup trigger active on metadata.dataset")
                end
        end
        return DataBase{T}(
            host       = env["host"],
            port       = env["port"],
            user       = env["user"],
            name       = env["name"],
            password   = env["pswd"],
            connection = connect[:target],
            actions    = db_list_actions,
            tree       = db_structure()[2],
        )
    catch e
        @error "❌ Failed to create database '$(env["name"])'" exception=(e, catch_backtrace())
        rethrow()
    end  
end