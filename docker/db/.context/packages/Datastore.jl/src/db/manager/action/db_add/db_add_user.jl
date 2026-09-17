export db_add_user

function db_add_user(
    connection::String
    ;
)
    try
        println("👤 Enter details to create a new user.")
        name = get_name()
        out  = db_get_user(connection; identifier = Dict("name" => name,))
        if haskey(out,"user")
            println("User with name '$(name)' already exists.")
            return out
        else
            user = Dict{String,Any}(
                "name"       => name,
                "email"      => get_email(),
                "role"       => get_role(),
                "password"   => get_password(),
            )
            println("👤 Adding user to database...")
            LibPQ.Connection(connection) do conn
                LibPQ.execute(conn, "BEGIN;")
                try
                    # Insert user into core.users table
                    sql = """
                        INSERT INTO core.users (name, email, password_hash, created_at, role) 
                        VALUES (\$1, \$2, \$3, NOW(), \$4)
                        RETURNING *;
                    """
                    result = DataFrame(LibPQ.execute(conn, sql, (user["name"], user["email"], user["password"], user["role"])))
                    user   = Dict(k => result[1, k] for k in names(result))
                    # Update id_hash with the hash of the generated id
                    LibPQ.execute(conn, "UPDATE core.users SET id_hash = \$1 WHERE id = \$2;", (bytes2hex(sha256(string(user["id"]))), user["id"]))
                    # Generate unique token and insert into core.tokens table
                    token = getoken()
                    sql = """
                        INSERT INTO core.tokens (user_id, token_hash, created_at)
                        VALUES (\$1, \$2, \$3)
                        RETURNING id; 
                    """
                    id = LibPQ.execute(conn, sql, (user["id"], bytes2hex(sha256(token)), user["created_at"]))[1,1]
                    id_hash = bytes2hex(sha256(string(id)))
                    LibPQ.execute(conn, "UPDATE core.tokens SET id_hash = \$1 WHERE id = \$2;", (id_hash, id))
                    # Initialise stats row for the new user
                    stats_id = LibPQ.execute(conn, """
                        INSERT INTO core.stats (user_id, upload_bytes, upload_count)
                        VALUES (\$1, 0, 0)
                        RETURNING id;
                    """, (user["id"],))[1, 1]
                    stats_hash = bytes2hex(sha256(string(stats_id)))
                    LibPQ.execute(conn, "UPDATE core.stats SET id_hash = \$1 WHERE id = \$2;", (stats_hash, stats_id))
                    LibPQ.execute(conn, "COMMIT;")
                    println("""🔑 IMPORTANT: This is the only time you will see the token. Please save it securely now!
                        - name : $(user["name"])
                        - email: $(user["email"])
                        - role : $(user["role"])
                        - token: $(token)""")
                catch e
                    LibPQ.execute(conn, "ROLLBACK;")
                    rethrow(e)
                end
            end
            return println("✅ User '$(user["name"])' added successfully.")
        end
    catch err
        return println("❌ Error adding user: ", err)
    end
end