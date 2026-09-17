export db_list_formats

function db_list_formats()
    return Dict(
        "tif" => "raster",
        "h5"  => "raster",
        "nc"  => "raster",
        "shp" => "vector",
        "csv" => "table",
    )
end