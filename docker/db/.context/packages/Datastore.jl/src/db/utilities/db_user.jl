function get_name()
    while true
        println("Enter user name:")
        name = readline()
        if isempty(strip(name))
            println("Name cannot be empty. Please enter a valid name.")
        else
            return name
        end
    end
end
function get_email()
    while true
        println("Enter user email:")
        email = readline()
        # Basic email regex: contains @ and . after @
        if occursin(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email)
            return email
        else
            println("Invalid email format. Please enter a valid email address.")
        end
    end
end
function get_password()
    while true
        password = String(read(Base.getpass("Enter password: ")))
        if length(password) < 8
            println("Password must be at least 8 characters.")
            continue
        end
        confirm = String(read(Base.getpass("Confirm password: ")))
        if password != confirm
            println("Passwords do not match. Try again.")
        else
            println("Password set successfully.")
            return bytes2hex(sha256(password))
        end
    end
end
function get_role(;roles=["su", "analyst", "user", "viewer"])
    return roles[request("Select user role:", RadioMenu(roles))]
end
function user_exists(conn, username)
    stmt = LibPQ.execute(conn, "SELECT 1 FROM core.users WHERE name = \$1 LIMIT 1;", (username,))
    return !isempty(stmt)
end
function getoken(;len=32)
    return join(rand(['A':'Z'; 'a':'z'; '0':'9'], len))
end
