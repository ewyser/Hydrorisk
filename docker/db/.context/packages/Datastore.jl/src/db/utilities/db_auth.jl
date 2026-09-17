export db_auth

function db_auth(
    host::String        = "localhost",
    port::Int           = 5432,
    user::String        = "postgres",
    name::String        = "hydrorisk"
    ;
    password::Union{Nothing, String}= nothing,
    verbose::Bool                   = false,
)
    if isnothing(password)
        password = get(ENV, "PSWD_DB", nothing)
        if isnothing(password)
            throw(ErrorException("❌ Database password not found in environment variable 'PSWD_DB'."))
        end
        if verbose println("🔐 Database password found in environment variable and connection established.") end
        return password, db_connect(host, port, user, name, password)
    else
        return db_connect(host, port, user, name, password)
    end
end