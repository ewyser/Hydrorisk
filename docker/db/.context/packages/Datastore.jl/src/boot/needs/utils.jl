"""
    tree(sucess, prefix="\\n\\t", level=0, max_level=1) -> Vector{String}

Formats a list of strings into a tree-like structure for display.

# Arguments
- `sucess`: List of strings to format.
- `prefix="\\n\\t"`: String prefix for each line.
- `level=0`: Current tree depth.
- `max_level=1`: Maximum tree depth.

# Returns
- `Vector{String}`: Tree-formatted strings.

# Example
```julia
tree(["boot", "home"])
```
"""
function tree(sucess, prefix="\n\t", level=0, max_level=1)
    if level > max_level
        return nothing
    end
    n,printout = length(sucess),[]
    for (i, name) ∈ enumerate(sucess)
        connector = i == n ? "└── " : "├── "
        push!(printout,prefix*connector*name)
    end
    return printout
end

"""
    trunc_path(full_path::AbstractString; anchor::AbstractString="OsmotiC.jl") -> String

Returns the subpath of `full_path` starting from the directory name `anchor`.

# Arguments
- `full_path`: The full absolute or relative path.
- `anchor`: The folder name from which you want to keep the rest of the path.

# Returns
- `String`: Truncated path string.

# Example
```julia
trunc_path("/Users/user/Documents/OsmotiC.jl/db/job.sqlite", "OsmotiC.jl")
# => "OsmotiC.jl/db/job.sqlite"
```
"""
function trunc_path(full_path::AbstractString; anchor::AbstractString="OsmotiC.jl")
    parts = splitpath(full_path)
    idx = findfirst(==(anchor), parts)
    return isnothing(idx) ? full_path : joinpath(parts[idx:end]...)
end

"""
    get_version() -> String

Return the current project version as a string, as specified in the Julia project file.

# Returns
- `String`: The project version.

# Example
```julia
v = get_version()
println(v)
```
"""
function get_version()
    return string(Pkg.project().version)
end

"""
    welcome_log(; greeting::String="Welcome to OsmotiC 🌊 v\$(get_version())")

Prints a styled welcome message to the console, highlighting "Welcome" and vertical bars in blue and bold.

# Arguments
- `greeting::String`: The greeting message to display at the top.

# Returns
- `Nothing`. Prints the welcome message to the console.

# Example
```julia
welcome_log()
welcome_log(greeting="Hello from OsmotiC!")
```
"""
function welcome_log(; greeting::String="Welcome to Datastore.jl 🛢  v$(get_version())", color = :yellow) 
    printstyled("┌ $greeting\n", color=color, bold=true)
    printstyled("│", color=color, bold=true); println(" Data & Storage framework HPC-ready")
    printstyled("│", color=color, bold=true); println(" Handling DataBase type:")
    printstyled("│", color=color, bold=true); println(" db = get_db(; );")
    printstyled("│", color=color, bold=true); println(" # ...")
    printstyled("└", color=color, bold=true); println(" db_manager(db)\n")
    return nothing
end

function get_now(; format::String="yyyy-mm-dd HH:MM:SS")
    return Dates.format(now(), format)
end

#==========================================================================================================================
shortpath
==========================================================================================================================#
"""
    shortpath(job::String; level::Int=3)
    shortpath(job_list::Vector{String}; level::Int=3)

Shorten file paths to show only the last few directory levels.

Extract the last `level` components from a file path or vector of paths for display purposes. 
Automatically handles Unix (`/`) and Windows (`\\`) path separators. Useful for creating 
concise log messages and displaying job locations without full absolute paths.

The `level` parameter specifies how many directory levels to include (default: 3). For single 
paths, tries progressively shorter paths if errors occur.

Returns a shortened path string or vector of shortened path strings.

# Examples
```julia-repl
julia> shortpath("/Users/manuwyser/Downloads/test-volume-mount/jobs/todo/job1")
"test-volume-mount/jobs/todo/job1"

julia> shortpath(["/long/path/to/job1", "/long/path/to/job2"])
2-element Vector{String}:
 "path/to/job1"
 "path/to/job2"
```
"""
function shortpath(job::String; level::Int=3)
  shortest = nothing
  for level ∈ collect(level:-1:1)
    try
      shortest = joinpath(split(job, Sys.isunix() ? "/" : "\\")[end-(max(1,level-1)):end])
    catch

    end
  end
  return shortest
end
function shortpath(job_list::Vector{String}; level::Int=3)
  return joinpath.([split(job, Sys.isunix() ? "/" : "\\")[end-(max(1,level-1)):end] for job ∈ job_list])
end

#==========================================================================================================================
isjson
==========================================================================================================================#
"""
    isjson(s::String)

Check if a string contains valid JSON.

Attempt to parse the string as JSON. Returns `true` if the string is valid JSON, `false` 
otherwise. Useful for distinguishing between JSON strings and file paths.

# Examples
```julia-repl
julia> isjson("{\"key\": \"value\"}")
true

julia> isjson("/path/to/file.json")
false
```
"""
function isjson(s::String)
  try
      JSON3.read(s)
      return true
  catch err
      return false
  end
end