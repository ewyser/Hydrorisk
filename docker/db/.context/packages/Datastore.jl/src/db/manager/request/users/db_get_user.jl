export db_get_user

function db_get_user(
    connection::String
    ;
    identifier::Union{Nothing,Dict}=nothing
)
    function db_get_user_from_token(connection::String, token::String)
        LibPQ.Connection(connection) do conn
            try
                sql = """
                    SELECT user_id FROM core.tokens WHERE token_hash = \$1
                """
                result = LibPQ.execute(conn, sql, (bytes2hex(sha256(token)),))
                if isempty(result)
                    return Dict(
                        "error"  => true,
                        "msg"    => "🚫  Unauthorized — Token is not assigned to any registered user",
                        "status" => 401,
                    )
                end
                user_id = result[1,1]
                sql = """
                    SELECT * FROM core.users WHERE id = \$1; 
                """
                user = DataFrame(LibPQ.execute(conn, sql, (user_id,)))
                user = Dict( k => user[1, k] for k in names(user))
                return Dict(
                    "msg"    => "✅  Authorized - Welcome, user $(user["name"]) !",
                    "user"   => user,
                    "status" => 200,
                ) 
            catch e
                rethrow(e)
            end
        end
    end
    function db_get_user_from_hash(connection::String, hash::String)
        LibPQ.Connection(connection) do conn
            try
                sql = """
                    SELECT * FROM core.users WHERE id_hash = \$1;
                """
                result = DataFrame(LibPQ.execute(conn, sql, (hash,)))
                if nrow(result) == 0
                    return Dict(
                        "error"  => true,
                        "msg"    => "🚫  User not found for the given id_hash",
                        "status" => 404,
                    )
                end
                user = Dict(k => result[1, k] for k in names(result))
                return Dict(
                    "msg"    => "✅  Authorized - Welcome, user $(user["name"]) !",
                    "user"   => user,
                    "status" => 200,
                ) 
            catch e
                rethrow(e)
            end
        end
    end
    function db_get_user_from_name(connection::String, name::String)
        LibPQ.Connection(connection) do conn
            try
                sql = """
                    SELECT * FROM core.users WHERE name = \$1;
                """
                result = DataFrame(LibPQ.execute(conn, sql, (name,)))
                if nrow(result) == 0
                    return Dict(
                        "error"  => true,
                        "msg"    => "🚫  User not found for the given name",
                        "status" => 404,
                    )
                end
                user = Dict(k => result[1, k] for k in names(result))
                return Dict(
                    "msg"    => "✅  Authorized - Welcome, user $(user["name"]) !",
                    "user"   => user,
                    "status" => 200,
                ) 
            catch e
                rethrow(e)
            end
        end
    end
    function db_get_user_from_id(connection::String, id::String)
        LibPQ.Connection(connection) do conn
            try
                sql = """
                    SELECT * FROM core.users WHERE id = \$1;
                """
                result = DataFrame(LibPQ.execute(conn, sql, (id,)))
                if nrow(result) == 0
                    return Dict(
                        "error"  => true,
                        "msg"    => "🚫  User not found for the given id",
                        "status" => 404,
                    )
                end
                user = Dict(k => result[1, k] for k in names(result))
                return Dict(
                    "msg"    => "✅  Authorized - Welcome, user $(user["name"]) !",
                    "user"   => user,
                    "status" => 200,
                ) 
            catch e
                rethrow(e)
            end
        end
    end
    if isa(identifier,Dict)
        if haskey(identifier, "token")
            return db_get_user_from_token(connection, identifier["token"])
        elseif haskey(identifier, "hash")
            return db_get_user_from_hash(connection, identifier["hash"])
        elseif haskey(identifier, "name")
            return db_get_user_from_name(connection, identifier["name"])
        end
    else
        println("👤 Please provide user id to fetch user:")
        return db_get_user_from_id(connection, readline())
    end
end