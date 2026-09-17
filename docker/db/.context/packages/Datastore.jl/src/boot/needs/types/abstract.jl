export AbstractDatabase 

#==========================================================================================================================
Database abstract type
==========================================================================================================================#

"""
    AbstractDatabase

Abstract type for database backends.

Base type for concrete database implementations including `PostgreSQLDatabase` and 
`SQLiteDatabase`. Allows polymorphic handling of different database systems.
"""
abstract type AbstractDatabase end

"""
Convert AbstractDatabase to Dict, excluding sensitive fields by default
"""
function Base.convert(::Type{Dict}, db::T; exclude=[:user, :password]) where {T<:AbstractDatabase}
    result = Dict{String, Any}()
    for field in fieldnames(T)
        if field ∉ exclude
            result[String(field)] = getfield(db, field)
        end
    end
    return result
end