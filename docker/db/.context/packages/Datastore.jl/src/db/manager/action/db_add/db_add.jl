export db_add

function db_add(connection::String)
    function get_list()
        return Dict{String,Function}(
            "Add data to db" => db_add_data,
            "Add user to db" => db_add_user,
        )
    end
    # Prompt user
    list       = get_list()
    descs,funs = collect(keys(list)),collect(values(list))
    return funs[request("What to do ?:",RadioMenu(descs))](connection)
end