# typeid_registry.jl — Assign unique i32 IDs to all types for WasmGC method tables
#
# At build time, assign a unique Int32 to every Type seen by populate_transitive.
# This flattens the recursive Type object graph into a flat integer namespace.
# dart2wasm does exactly this: classId = i32 integer, dispatch on integer keys.
#
# Usage:
#   registry = TypeIDRegistry()
#   assign_types!(registry, table)  # table is a DictMethodTable
#   id = get_type_id(registry, Int64)
#   typ = get_type(registry, id)

"""
    TypeIDRegistry

Maps Julia Types to unique Int32 identifiers and back.
Built at build time from the set of types seen during populate_transitive.
"""
struct TypeIDRegistry
    type_to_id::Dict{Any, Int32}     # Type → TypeID
    id_to_type::Vector{Any}          # TypeID (1-based index) → Type
    # Statistics
    n_atomic::Int                     # Number of atomic (non-compound) types
    n_compound::Int                   # Number of compound tuple types
end

function TypeIDRegistry()
    TypeIDRegistry(Dict{Any, Int32}(), Any[], 0, 0)
end

"""
    assign_type!(registry, type) → Int32

Assign a TypeID to a type. Returns existing ID if already assigned.
"""
function assign_type!(registry::TypeIDRegistry, @nospecialize(t))
    id = get(registry.type_to_id, t, Int32(-1))
    if id >= 0
        return id
    end
    new_id = Int32(length(registry.id_to_type))
    push!(registry.id_to_type, t)
    registry.type_to_id[t] = new_id
    return new_id
end

"""
    assign_types!(registry, table::DictMethodTable) → TypeIDRegistry

Assign TypeIDs to all types in a DictMethodTable:
- Each method table KEY (call signature) gets a TypeID
- Each component type within compound signatures also gets a TypeID
- Intersection keys also get TypeIDs

Returns the registry for convenience.
"""
function assign_types!(registry::TypeIDRegistry, table)
    n_atomic = 0
    n_compound = 0

    # 1. Assign IDs to all method table keys (call signatures)
    for sig in keys(table.methods)
        assign_type!(registry, sig)
        n_compound += 1

        # Also assign IDs to component types of compound signatures
        if sig isa DataType && sig <: Tuple
            for param in sig.parameters
                assign_type!(registry, param)
                n_atomic += 1
            end
        end
    end

    # 2. Assign IDs to intersection keys
    for (a, b) in keys(table.intersections)
        assign_type!(registry, a)
        assign_type!(registry, b)
    end

    # 3. Assign IDs to common base types that typeinf uses
    common_types = [
        Any, Nothing, Union{}, Bool,
        Int8, Int16, Int32, Int64, Int128,
        UInt8, UInt16, UInt32, UInt64, UInt128,
        Float16, Float32, Float64,
        String, Symbol, Char,
        Tuple, NamedTuple,
        Array, Vector, Matrix,
        Dict, Set, Pair,
        Type, DataType, UnionAll, Union, TypeVar,
        Core.MethodInstance, Core.CodeInfo, Core.CodeInstance,
        Core.Method, Core.MethodTable, Core.SimpleVector,
        Core.Compiler.MethodLookupResult,
        Core.Compiler.InferenceState, Core.Compiler.InferenceResult,
    ]

    for t in common_types
        assign_type!(registry, t)
    end

    # Update stats (mutable struct workaround)
    return TypeIDRegistry(registry.type_to_id, registry.id_to_type, n_atomic, n_compound)
end

"""
    get_type_id(registry, type) → Int32

Look up the TypeID for a type. Returns -1 if not found.
"""
function get_type_id(registry::TypeIDRegistry, @nospecialize(t))::Int32
    return get(registry.type_to_id, t, Int32(-1))
end

"""
    get_type(registry, id) → Type

Look up the Type for a TypeID. Throws on invalid ID.
"""
function get_type(registry::TypeIDRegistry, id::Int32)
    return registry.id_to_type[id + 1]  # 0-based → 1-based
end

"""
    has_type(registry, type) → Bool

Check if a type has been assigned a TypeID.
"""
function has_type(registry::TypeIDRegistry, @nospecialize(t))::Bool
    return haskey(registry.type_to_id, t)
end

"""
    registry_stats(registry) → NamedTuple

Return summary statistics about the registry.
"""
function registry_stats(registry::TypeIDRegistry)
    return (
        total_types = length(registry.id_to_type),
        n_atomic = registry.n_atomic,
        n_compound = registry.n_compound,
    )
end

"""
    build_typeid_registry(table::DictMethodTable) → TypeIDRegistry

Convenience function: build a complete TypeIDRegistry from a DictMethodTable.
"""
function build_typeid_registry(table)
    registry = TypeIDRegistry()
    return assign_types!(registry, table)
end
