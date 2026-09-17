export db_add_data
"""
    db_add_data(path::String;
        db_conn::String="postgresql://postgres@localhost/hydrorisk-test",
        schema::Union{String,Nothing}=nothing,
        table::Union{String,Nothing}=nothing,
        raster_srid::Int=2056,
        tile_size::String="100x100",
        overwrite::Bool=false)

Import a raster, shapefile, or CSV file into a PostgreSQL/PostGIS database.

# Arguments
- `path::String`: Path to the file to import (raster, shapefile, or CSV).
- `db_conn::String`: PostgreSQL connection string (default: "postgresql://postgres@localhost/hydrorisk-test").
- `schema::Union{String,Nothing}`: Target schema (default: based on file type).
- `table::Union{String,Nothing}`: Target table name (default: derived from file name).
- `raster_srid::Int`: SRID for raster/vector data (default: 2056).
- `tile_size::String`: Tile size for raster import (default: "100x100").
- `overwrite::Bool`: If true, drop the table before import (default: false).

Automatically detects file type and imports accordingly:
- CSV: Creates table and inserts data.
- Shapefile: Uses shp2pgsql and psql.
- Raster: Uses raster2pgsql and psql.
"""
function db_add_data(
    connection::String
    ;
    id::Union{Nothing,Dict}=nothing,
    data::Union{Nothing,String}=nothing,
    category::Union{Nothing,String}=nothing,
    schema::String="data",
    table::Union{Nothing,String}=nothing,
    tile_size::String="100x100",
    overwrite::Bool=false,
    user::Union{Nothing,Dict}=nothing,
    job_id::Union{Nothing,String}=nothing,
)
    # Fetch user from identifier (skip if already provided)
    if isnothing(user)
        out = db_get_user(connection; identifier = id)
        if haskey(out, "error")
            @warn "👤 User not found for the given id hash."
            return out
        else
            user = out["user"]
        end
    end

    if !isnothing(data)
        path = data
    else
        @info "Adding data to database from file:"
        path = readline()
    end

    if isfile(path)
        @info "📄 Detected file path: $path"
        return add_from_file(connection, path, category, schema, tile_size, overwrite, user)
    elseif isdir(path)
        @info "📁 Detected folder: $(basename(path))"
        return add_from_folder(connection, path, category, schema, tile_size, overwrite, user)
    else
        @error "❌ File or folder not found: $path"
        return Dict("error" => "File or folder not found: $path")
    end
end