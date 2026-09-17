export db_default_config

function db_default_config()
    return Dict(
        "host" => "localhost",
        "port" => 5432,
        "user" => "postgres",
        "name" => "hydrorisk",
        "password" => nothing # placeholder password for local development,
    )
end
