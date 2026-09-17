export Self

#==========================================================================================================================
Core System Types
==========================================================================================================================#

"""
    Path

Mutable structure storing module directory paths.

Contains paths to key directories within the OsmotiC module:
- `root` - Package root directory
- `src` - Source code directory
- `db` - Database directory
- `lib` - Dictionary tracking included files for documentation generation

All paths are initialized with default values based on module constants `ROOT`, `DIR`, and `DB`.
"""
Base.@kwdef mutable struct Path
	root::String = ROOT
	src::String  = DIR
	db::String   = DB
	plugin::Dict{String,Any} = Dict("dir" => joinpath(ROOT,"gis"), "name" => "osmotic_plugin")
	lib::Dict{String,Any} = Dict{String,Any}()
end

"""
    Self

Main module configuration structure containing all system state.

Central configuration object for the OsmotiC module containing:
- `sys` - Module directory paths (`Path`)
- `wallclock` - Runtime performance metrics (`Runtime`)
- `db` - Database backend configuration (`AbstractDatabase`)

Created during module initialization and available globally as `info`. The `db` field
is initialized to `nothing` and set during `__init__()`.

# Examples
```julia-repl
julia> info.sys.root
"/path/to/OsmotiC.jl"

julia> info.wallclock.simulate
Dict{String, Any}()
```
"""
Base.@kwdef mutable struct Self
	sys      ::Path
	db       ::Union{Nothing,ErrorException,DataBase{<:AbstractDatabase}} = nothing
end