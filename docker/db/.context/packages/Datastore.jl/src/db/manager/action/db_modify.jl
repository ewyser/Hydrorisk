export db_modify_user, db_modify

function db_modify_user(
    connection::String,
    ;
    id::Union{Nothing,String}=nothing,
)
    println("📂 Modifying user in database:")
    if isnothing(id)
        users = LibPQ.Connection(connection) do conn
            DataFrame(LibPQ.execute(conn, "SELECT id, name, email, role FROM core.users;"))
        end
        users = Dict(
            row.name => Dict(k => row[k] for k in names(users) if k != "name") for row in eachrow(users)
        )
        menu,msg = RadioMenu(collect(keys(users)), pagesize=2), "👤 Please select `user` to modify user"
        id  = users[collect(keys(users))[request(msg, menu)]]["id"]
    end 

    LibPQ.Connection(connection) do conn
        try
            LibPQ.execute(conn, "BEGIN;")
            # Fetch current user data by id
            result = DataFrame(LibPQ.execute(conn, """
                SELECT * FROM core.users WHERE id = \$1;
            """, (id,)))
            if nrow(result) == 0
                return Dict(
                    "msg"    => "🚫  User not found for the given id",
                    "status" => 404,
                )
            end
            user     = deepcopy(Dict(k => result[1, k] for k in names(result)))
            menu,msg = RadioMenu(["Yes", "No"], pagesize=2), "Regenerate token ?"
            if [true,false][request(msg, menu)]
                menu,msg = RadioMenu(["Yes", "No"], pagesize=2), "Enter manually token ?"
                if [true,false][request(msg, menu)]
                    println("Enter new token:")
                    token = readline()
                else
                    token = getoken()
                end
                sql = """
                    UPDATE core.tokens SET token_hash = \$2, created_at = \$3
                    WHERE user_id = \$1
                """
                LibPQ.execute(conn, sql, (user["id"], bytes2hex(sha256(token)), now()))

                # Warn user about new 
                println("""🔑 IMPORTANT: This is the only time you will see the token. Please save it securely now!
                    - name : $(user["name"])
                    - email: $(user["email"])
                    - role : $(user["role"])
                    - token: $(token)""")
            else
                # Interactive modification of user fields
                action = Dict(
                    "reset name"     => (get_name    ,"name"         ),
                    "reset password" => (get_password,"password_hash"),
                    "change role"    => (get_role    ,"role"         ),
                )
                
                menu ,msg     = RadioMenu(["Yes", "No"], pagesize=2), "Modify something else?"
                descs,actions = collect(keys(action)),collect(values(action))
                while true
                    idx         = request("Choose action:", RadioMenu(descs))
                    fun,field   = first(actions[idx]),last(actions[idx])
                    user[field] = fun()
                    if [false,true][request(msg, menu)]
                        break
                    end
                end

                # Update user data in database
                sql = """
                    UPDATE core.users SET name = \$1, email = \$2, password_hash = \$3, created_at = \$4, role = \$5
                    WHERE id = \$6;
                """
                LibPQ.execute(conn, sql, (user["name"], user["email"], user["password_hash"], user["created_at"], user["role"], id))
            end
            LibPQ.execute(conn, "COMMIT;")

            msg = "✅ User '$(user["name"])' modified successfully."
            println(msg)
            return Dict(
                "msg"    => msg,
                "status" => 200,
            )
        catch e
            LibPQ.execute(conn, "ROLLBACK;")
            rethrow(e)
        end
    end

end

function db_modify(connection::String)
    function get_list()
        return Dict{String,Function}(
            "Modify user in db"   => db_modify_user,
        )
    end
    # Prompt user
    list       = get_list()
    descs,funs = collect(keys(list)),collect(values(list))
    return funs[request("What to do ?:",RadioMenu(descs))](connection)
end