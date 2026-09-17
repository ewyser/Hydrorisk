function construct_metadata_dict()

end

function db_add_metadata(conn;
    path::Union{Nothing,String}=nothing,
    file::Union{Nothing,String}=nothing,
    format::Union{Nothing,String}=nothing,
    category::Union{Nothing,String}=nothing,
    table::Union{Nothing,String}=nothing,
    col_names::Union{Nothing,Vector{String}}=nothing,
    table_cols::Union{Nothing,Vector{String}}=nothing,
    srid::Union{Nothing,Integer}=nothing,
    geom::Union{Nothing,String}=nothing,
    user_id::Union{Nothing,Integer}=nothing,
    job_id::Union{Nothing,Integer}=nothing
)
    category_sql   = isnothing(category)   ? "NULL" : "'$category'"
    col_names_sql  = isnothing(col_names)  ? "NULL" : "'{$(join(["\"$(c)\"" for c in col_names], ","))}'::text[]"
    table_cols_sql = isnothing(table_cols) ? "NULL" : "'{$(join(["\"$(c)\"" for c in table_cols], ","))}'::text[]"
    srid_sql       = isnothing(srid)       ? "NULL" : string(srid)
    geom_sql       = isnothing(geom)       ? "NULL" : "'$geom'"
    user_id_sql    = isnothing(user_id)    ? "NULL" : string(user_id)
    job_id_sql     = isnothing(job_id)     ? "NULL" : string(job_id)
    meta_sql = """
        INSERT INTO metadata.dataset (
            source, name, format, category, data_table, columns, table_cols, srid, geom, user_id, created_at, input, result, job_id
        ) VALUES (
            '$path',
            '$file',
            '$format',
            $category_sql,
            '$table',
            $col_names_sql,
            $table_cols_sql,
            $srid_sql,
            $geom_sql,
            $user_id_sql,
            NOW(),
            TRUE,
            FALSE,
            $job_id_sql
        )
        RETURNING id;
    """
    id      = LibPQ.execute(conn, meta_sql)[1, 1]
    id_hash = bytes2hex(sha256(string(id)))
    LibPQ.execute(conn, "UPDATE metadata.dataset SET id_hash = \$1 WHERE id = \$2;", (id_hash, id))
end