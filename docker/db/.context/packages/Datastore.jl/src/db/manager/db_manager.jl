export db_manager

function db_list_actions()
    return Dict{String,Function}(
        "Add"    => db_add,
        "Modify" => db_modify,
        "Remove" => db_remove,
    )
end
function db_manager(
    db::DataBase{DB},
    ; 
) where {DB<:AbstractDatabase}
    # Check if password exist in environment variable and prompt user if not found
    password, connection = db_auth(db.host, db.port, db.user, db.name)
    # Prompt user
    list       = db_list_actions()
    descs,funs = collect(keys(list)),collect(values(list))
    while true
        status = funs[request("What to do ?:",RadioMenu(descs))](connection)
        if [false,true][request("Something else ?",RadioMenu(["Yes", "No"], pagesize=2))]
            break
        end
    end
    return nothing
end