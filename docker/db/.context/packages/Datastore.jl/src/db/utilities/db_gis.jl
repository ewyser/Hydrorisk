#==========================================================================================================================
create_projection_dict
==========================================================================================================================#
"""
    create_projection_dict(proj4::String, xv::Vector, yv::Vector, xc::Vector, yc::Vector, dx::Float64, dy::Float64; srid::Integer=2056)

Create a dictionary containing projection metadata for a spatial grid.

# Arguments
- `proj4::String`: PROJ.4 string describing the projection.
- `xv::Vector`: Vector of x (longitude/easting) vertex coordinates.
- `yv::Vector`: Vector of y (latitude/northing) vertex coordinates.
- `xc::Vector`: Vector of x cell center coordinates.
- `yc::Vector`: Vector of y cell center coordinates.
- `dx::Float64`: Grid cell size in x direction.
- `dy::Float64`: Grid cell size in y direction.
- `srid::Integer=2056`: Spatial Reference System Identifier (default: 2056).

# Returns
- `Dict`: Dictionary with projection and grid metadata, including proj4, srid, grid size, resolution, coordinates, and bounding box corners (LL, LR, UL, UR).
"""
function create_projection_dict()
    # create projection metadata dictionary
    return [
        "proj4",
        "srid",
        "size",
        "res",
        "xv",
        "yv",
        "xc",
        "yc",
        "LL",
        "LR",
        "UL",
        "UR",
    ]
end
function create_projection_dict(proj4::String, xv::Vector, yv::Vector, xc::Vector, yc::Vector, dx::Float64, dy::Float64; srid::Integer=2056)
    # create projection metadata dictionary
    return Dict(
        "proj4" => proj4,
        "srid"  => srid,
        "size"  => Vector{Int32}([length(xc), length(yc)]),
        "res"   => Vector{Float32}([dx, dy]),
        "xv"    => Vector{Float32}(xv),
        "yv"    => Vector{Float32}(yv),
        "xc"    => Vector{Float32}(xc),
        "yc"    => Vector{Float32}(yc),
        "LL"    => Vector{Float32}([minimum(xv), minimum(yv)]),
        "LR"    => Vector{Float32}([maximum(xv), minimum(yv)]),
        "UL"    => Vector{Float32}([minimum(xv), maximum(yv)]),
        "UR"    => Vector{Float32}([maximum(xv), maximum(yv)]),
    )
end

#==========================================================================================================================
get_extent_proj
==========================================================================================================================#
"""
    get_extent_proj(geojson::Dict, res::Vector=[1.0, 1.0])

Extract projection information from GeoJSON FeatureCollection extent.

Returns the same structure as `get_raster_proj` but from GeoJSON extent data.
The resolution must be provided as it's not stored in the GeoJSON.

Works with any geometry type by extracting bounds from coordinates.

# Arguments
- `geojson::Dict`: GeoJSON FeatureCollection containing extent geometry
- `res::Vector`: Grid resolution [dx, dy] in map units (default: [1.0, 1.0])

# Returns
Dictionary with keys:
- `proj4`: PROJ4 string extracted from CRS
- `size`: Grid dimensions [nx, ny]
- `res`: Resolution [dx, dy]
- `xv`, `yv`: Vertex coordinate vectors
- `xc`, `yc`: Cell center coordinate vectors
- `LL`, `LR`, `UL`, `UR`: Corner coordinates
"""
function get_extent_proj(geojson::Dict, res::Vector=[1.0, 1.0])
    # Flatten coordinates to get all points
    function flatten_coords(c)
        if c isa Vector && length(c) > 0 && c[1] isa Number
            return [c]
        else
            return vcat([flatten_coords(x) for x in c]...)
        end
    end
    # Extract CRS
    crs_name = geojson["crs"]["properties"]["name"]
    # Parse EPSG code from URN format (e.g., "urn:ogc:def:crs:EPSG::2056")
    epsg_code = split(crs_name, ":")[end]
    proj4 = "+proj=somerc +lat_0=46.95240555555556 +lon_0=7.439583333333333 +k_0=1 +x_0=2600000 +y_0=1200000 +ellps=bessel +units=m +no_defs"  # Default Swiss CH1903+/LV95
    
    # Extract bounds - try properties first, otherwise compute from geometry
    feature = geojson["features"][1]

    # Extract bounds from geometry coordinates
    geom = feature["geometry"]
    coords = geom["coordinates"]
    
    all_points = flatten_coords(coords)
    xs = [p[1] for p in all_points]
    ys = [p[2] for p in all_points]
    
    xmin, xmax = minimum(xs), maximum(xs)
    ymin, ymax = minimum(ys), maximum(ys)
        
    return Dict(
        "proj4" => proj4,
        "LL"    => [xmin, ymin],
        "LR"    => [xmax, ymin],
        "UL"    => [xmin, ymax],
        "UR"    => [xmax, ymax],
        "bbox"  => [
            [   
                [   
                    [xmin, ymin],
                    [xmin, ymax],
                    [xmax, ymax],
                    [xmax, ymin],
                    [xmin, ymin]
                ]
            ]
        ]
    )
end

#==========================================================================================================================
get_srid
==========================================================================================================================#
function get_srid(path::AbstractString)
    function WKT_to_dict(wkt::AbstractString)
        dict = Dict{String,Any}()
        # Extract top-level type (e.g., PROJCS, GEOGCS)
        m = match(r"^(\w+)\[", wkt)
        if m !== nothing
            dict["type"] = m.captures[1]
        end
        # Extract all AUTHORITY/ID codes — handles both WKT1 (AUTHORITY["EPSG","XXXX"]) and WKT2 (ID["EPSG",XXXX])
        authorities = [parse(Int, m.captures[1]) for m in eachmatch(r"(?:AUTHORITY|ID)\[\"EPSG\",\"?(\d+)\"?\]", wkt)]
        if !isempty(authorities)
            dict["epsg"] = authorities[end]  # Usually the last one is the main code
        end
        # Optionally extract the name
        m = match(r"^\w+\[\"([^\"]+)\"", wkt)
        if m !== nothing
            dict["name"] = m.captures[1]
        end
        return dict
    end
    # Primary: read the .prj sidecar for OGC WKT1/WKT2 files with embedded AUTHORITY/ID tags
    prj_path = splitext(path)[1] * ".prj"
    if isfile(prj_path)
        wkt = read(prj_path, String)
        if !isempty(wkt)
            dict = WKT_to_dict(wkt)
            haskey(dict, "epsg") && return dict["epsg"]
        end
    end
    # Fallback: let GDAL open the file and auto-identify the CRS (handles bare ESRI WKT)
    srid = try
        gdal.read(path) do dataset
            epsg = WKT_to_dict(gdal.getproj(dataset))["epsg"]
            if epsg isa String
                return parse(Int, epsg)
            elseif epsg isa Integer
                return epsg
            else
                return nothing
            end
        end
    catch
        return nothing
    end
    if isnothing(srid)
        println("⚠️ Could not detect SRID for '$(basename(path))' (got $srid) — geometry will be stored without projection. Re-upload with correct projection metadata.")
    else
        println("📐 Detected SRID: $srid")
    end
    return srid
end
#==========================================================================================================================
get_geometry_type
==========================================================================================================================#
function get_geometry_type(file_path::String)
    ext = lowercase(splitext(file_path)[2][2:end])
    if ext ∈ ["tif", "tiff"]  # raster 
        return "RASTER"
    elseif ext ∈ ["shp"]  # vector
        try
            return gdal.read(file_path) do dataset
                layer = gdal.getlayer(dataset, 0)
                geom  = string(gdal.getgeomtype(layer))
                return uppercase(geom)
            end
        catch
            return "UNKNOWN"
        end
    elseif ext ∈ ["csv"]
        return "TABLE"
    else
        return "UNKNOWN"
    end
end