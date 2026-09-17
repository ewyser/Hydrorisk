export PostgreSQLDatabase, SQLiteDatabase, DataBase, db_init

#==========================================================================================================================
Database Types
==========================================================================================================================#
"""
    PostgreSQLDatabase <: AbstractDatabase

Concrete type for PostgreSQL/PostGIS database configuration.
Used as a parent type or placeholder for concrete database implementations.
"""
struct PostgreSQLDatabase <: AbstractDatabase end

"""
    SQLiteDatabase <: AbstractDatabase

Concrete type for SQLite database configuration.
Used as a parent type or placeholder for concrete SQLite database implementations.
"""
struct SQLiteDatabase <: AbstractDatabase end


"""
    DataBase{T<:AbstractDatabase}

Generic database configuration struct.
Stores connection and metadata for a database, supporting both PostgreSQL and SQLite backends.

# Fields
- `host::Union{Nothing, String}`: Database server hostname
- `port::Union{Nothing, Int}`: Database server port
- `user::Union{Nothing, String}`: Database username
- `name::Union{Nothing, String}`: Database name
- `password::Union{Nothing, String}`: Database password
- `conn::Union{Nothing, NamedTuple}`: Connection string(s) or info (e.g., URI, std)
- `actions::Union{Nothing, Function}`: Function returning available database actions
- `schemas::Union{Nothing, Function}`: Function returning supported data formats

# Example
```julia
db = DataBase{PostgreSQLDatabase}(host="localhost", port=5432, user="postgres", name="hydrorisk")
```
"""
Base.@kwdef struct DataBase{T<:AbstractDatabase} <: AbstractDatabase
    host::String           
    port::Int              
    user::String           
    name::String           
    password::String
    connection::String
    actions::Function      
    tree::Dict{String,Any}
end