# include dependencies
using Revise,Pkg,TOML
using REPL.TerminalMenus
using Dates,CSV,DataFrames,JSON3,JLD2,SQLite,LibPQ,Random
using UUIDs,SHA
using HDF5
import ArchGDAL as gdal

# include types & constants
include(joinpath(DIR,"boot/include.jl"))
success = superInc(["boot/needs/types"]; root=DIR)

# create primitive structs
self = Self(
    sys = Path(),
)

# include utilities
include(joinpath(DIR,"boot/needs/utils.jl"))

# list of directories to include & include .jl files
@info join(superInc(["db"]; root=DIR, lib=self.sys.lib),"\n")