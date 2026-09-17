export db_connect

function db_connect(
    host::String,
    port::Int,
    user::String,
    name::String,
    password::String
    ;
    root_dbname::String = "postgres"
)
    return "host=$(host) port=$(port) user=$(user) dbname=$(name) password=$(password)"
end
