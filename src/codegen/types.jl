# Code Generation - Julia IR to Wasm instructions
# Maps Julia SSA statements to WebAssembly bytecode

export compile_function, compile_module, compile_handler, FunctionRegistry

# ============================================================================
# Struct Type Registry
# ============================================================================

"""
Maps Julia struct types to their WasmGC representation.
"""
struct StructInfo
    julia_type::Type  # DataType or UnionAll for parametric types
    wasm_type_idx::UInt32
    field_names::Vector{Symbol}
    field_types::Vector{Type}  # Can include Union types
    field_offset::UInt32  # PURE-9024: offset for typeId field (1 if typeId present, 0 otherwise)
end

# PURE-9024: Default field_offset=1 (all structs have typeId at field 0)
StructInfo(julia_type::Type, wasm_type_idx::UInt32, field_names::Vector{Symbol}, field_types::Vector) =
    StructInfo(julia_type, wasm_type_idx, field_names, convert(Vector{Type}, field_types), UInt32(1))

"""
    wasm_field_idx(info::StructInfo, julia_field_idx::Int) -> UInt32

Convert a Julia 1-based field index to the Wasm 0-based field index,
accounting for the typeId field offset (PURE-9024).
"""
wasm_field_idx(info::StructInfo, julia_field_idx::Int) = UInt32(julia_field_idx - 1 + info.field_offset)

"""
Maps Julia Union types to their WasmGC tagged union representation.
Tagged unions are WasmGC structs with {tag: i32, value: anyref}.
The tag identifies which variant the union currently holds.
"""
struct UnionInfo
    julia_type::Union                        # The original Union type
    wasm_type_idx::UInt32                    # Index of the wrapper struct type
    variant_types::Vector{Type}              # Types in the union (ordered)
    tag_map::Dict{Type, Int32}               # Type -> tag value
end

"""
Registry for struct and array type mappings within a module.
"""
mutable struct TypeRegistry
    structs::Union{Nothing, Dict{Type, StructInfo}}  # DataType or UnionAll for parametric types
    arrays::Union{Nothing, Dict{Type, UInt32}}  # Element type -> array type index
    string_array_idx::Union{Nothing, UInt32}  # Index of i8 array type for strings
    unions::Union{Nothing, Dict{Union, UnionInfo}}  # Union type -> tagged union info
    numeric_boxes::Union{Nothing, Dict{WasmValType, UInt32}}  # PURE-325: box types for numeric→externref returns
    # PURE-4151: Type constant globals — each unique Type value gets a unique Wasm global
    # so that ref.eq distinguishes different Types (e.g., Int64 !== String)
    type_constant_globals::Union{Nothing, Dict{Type, UInt32}}  # Type value -> Wasm global index
    # PURE-4149: TypeName constant globals — each unique TypeName gets a unique Wasm global
    # so that t.name === s.name identity comparison works via ref.eq
    typename_constant_globals::Union{Nothing, Dict{Core.TypeName, UInt32}}  # TypeName -> Wasm global index
    # PURE-9025: DFS type ID assignment for runtime dispatch
    type_ids::Union{Nothing, Dict{Type, Int32}}  # Concrete type -> unique DFS integer ID
    type_ranges::Union{Nothing, Dict{Type, Tuple{Int32, Int32}}}  # Abstract/concrete type -> [low, high] DFS range
    # PURE-9026: Base struct type index for typeof(x) extraction
    base_struct_idx::Union{Nothing, UInt32}  # Index of $JlBase = (struct (field i32))
    # PURE-9028: BoxedNothing struct type and singleton global
    nothing_box_idx::Union{Nothing, UInt32}   # Struct type: (struct (field $typeId i32))
    nothing_global_idx::Union{Nothing, UInt32}  # Singleton global holding BoxedNothing instance
    # PURE-9063: Type lookup table — typeId (i32) → DataType struct ref
    type_lookup_array_idx::Union{Nothing, UInt32}  # Array type: (array (mut (ref null $JlDataType)))
    type_lookup_global::Union{Nothing, UInt32}  # Global holding the lookup array
    type_lookup_table_size::Int32  # WBUILD-4000: Table size at creation time (guards late-arriving types)
    # PURE-9063: $JlType hierarchy struct type indices
    jl_type_idx::Union{Nothing, UInt32}       # $JlType = (struct (field $kind i32))
    jl_datatype_idx::Union{Nothing, UInt32}   # $JlDataType (sub $JlType) — most Julia types
    jl_union_idx::Union{Nothing, UInt32}      # $JlUnion (sub $JlType) — flat union of types
    jl_unionall_idx::Union{Nothing, UInt32}   # $JlUnionAll (sub $JlType) — type constructor
    jl_typevar_idx::Union{Nothing, UInt32}    # $JlTypeVar (sub $JlType) — bound variable
    jl_typename_idx::Union{Nothing, UInt32}   # $JlTypeName — identity token
    jl_svec_idx::Union{Nothing, UInt32}       # $JlSVec = (array (mut (ref null $JlType)))
    # PURE-9065: String hash helper function index for Dict{String,...} support
    string_hash_func_idx::Union{Nothing, UInt32}
end

TypeRegistry() = TypeRegistry(
    Dict{Type, StructInfo}(), Dict{Type, UInt32}(), nothing,
    Dict{Union, UnionInfo}(), Dict{WasmValType, UInt32}(),
    Dict{Type, UInt32}(), Dict{Core.TypeName, UInt32}(),
    Dict{Type, Int32}(), Dict{Type, Tuple{Int32, Int32}}(),
    nothing, nothing, nothing, nothing, nothing, Int32(0),
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing  # string_hash_func_idx
)

# TRUE-INT-002: Dict-free constructor for WASM self-hosting.
# All Dict fields are nothing — safe for MVP Int64 arithmetic where
# no struct/array/union type registration is needed.
TypeRegistry(::Val{:minimal}) = TypeRegistry(
    nothing, nothing, nothing,  # structs, arrays, string_array_idx
    nothing, nothing,            # unions, numeric_boxes
    nothing, nothing,            # type_constant_globals, typename_constant_globals
    nothing, nothing,            # type_ids, type_ranges
    nothing, nothing, nothing, nothing, nothing,
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing  # string_hash_func_idx
)

"""
    get_datatype_type_idx(registry::TypeRegistry) → UInt32

Get the WasmGC type index for DataType globals.
Returns \$JlDataType when hierarchy is available, else Julia's DataType struct type.
"""
function get_datatype_type_idx(registry::TypeRegistry)::UInt32
    if registry.jl_datatype_idx !== nothing
        return registry.jl_datatype_idx
    elseif haskey(registry.structs, DataType)
        return registry.structs[DataType].wasm_type_idx
    else
        error("No DataType type index available")
    end
end

# ============================================================================
# PURE-9025: DFS Type ID Assignment
# ============================================================================

"""
    assign_type_ids!(registry::TypeRegistry)

Assign DFS-based type IDs to all registered struct types.
Walks Julia's abstract type hierarchy via DFS, assigning contiguous ID ranges
so that `isa(x, AbstractType)` becomes an O(1) range check:
  `typeId >= low && typeId <= high`.

IDs start at 1 (0 is reserved for unknown/unassigned).
"""
function assign_type_ids!(registry::TypeRegistry)
    # Collect all concrete types from the registry that have typeId (field_offset > 0)
    concrete_types = Set{DataType}()
    for (T, info) in registry.structs
        if T isa DataType && isconcretetype(T) && info.field_offset > 0
            push!(concrete_types, T)
        end
    end

    # Also include primitive numeric types that may need boxing/dispatch
    # PURE-9028: Include Nothing for BoxedNothing typeId
    for T in (Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
              Float16, Float32, Float64, Nothing)
        push!(concrete_types, T)
    end

    isempty(concrete_types) && return

    # Walk supertype chains to collect all relevant abstract types
    # Use base types (without parameters) for abstract types to ensure
    # all subtypes of e.g. AbstractVector are grouped together
    abstract_types = Set{DataType}()
    for T in concrete_types
        S = supertype(T)
        while S !== Any
            # Use the base type for parametric abstract types
            base_S = S isa DataType ? (isempty(S.parameters) ? S : S.name.wrapper) : S
            if base_S isa DataType
                push!(abstract_types, base_S)
            else
                # UnionAll - use the body's base type
                push!(abstract_types, Base.unwrap_unionall(base_S)::DataType)
            end
            S = supertype(S)
        end
    end
    push!(abstract_types, Any)

    # Build parent → children map
    # For each type, find its parent in our collected set (skip intermediate types not in the set)
    all_types = union(concrete_types, abstract_types)
    children = Dict{DataType, Vector{DataType}}()

    for T in all_types
        T === Any && continue
        # Walk up from T's supertype until we find a type in our set
        S = supertype(T)
        parent = Any  # default parent
        while S !== Any
            base_S = S isa DataType ? (isempty(S.parameters) ? S : S.name.wrapper) : S
            resolved_S = base_S isa DataType ? base_S : Base.unwrap_unionall(base_S)::DataType
            if resolved_S in all_types
                parent = resolved_S
                break
            end
            S = supertype(S)
        end
        if !haskey(children, parent)
            children[parent] = DataType[]
        end
        # Avoid duplicate children
        if !(T in children[parent])
            push!(children[parent], T)
        end
    end

    # DFS traverse from Any, assigning IDs
    # Abstract types visit children first, then get [low, high] range
    # Concrete types get a single ID (leaf)
    type_ids = Dict{Type, Int32}()
    type_ranges = Dict{Type, Tuple{Int32, Int32}}()
    counter = Ref(Int32(1))  # Start at 1, reserve 0 for unknown

    function dfs!(node::DataType)
        low = counter[]
        kids = get(children, node, DataType[])
        # Sort children deterministically by type name for reproducible IDs
        sort!(kids, by=T -> string(T))

        if isempty(kids) && isconcretetype(node)
            # Leaf concrete type
            type_ids[node] = counter[]
            type_ranges[node] = (counter[], counter[])
            counter[] += Int32(1)
        else
            # Has children or is abstract: visit children
            for child in kids
                dfs!(child)
            end
            if low == counter[]
                # Abstract type with no registered subtypes - assign a single ID
                type_ranges[node] = (low, low)
                counter[] += Int32(1)
            else
                type_ranges[node] = (low, counter[] - Int32(1))
            end
        end
    end

    dfs!(Any)

    # Store results in registry
    registry.type_ids = type_ids
    registry.type_ranges = type_ranges
end

"""
    get_type_id(registry::TypeRegistry, T::Type) -> Int32

Return the DFS type ID for a concrete type, or 0 if not assigned.
"""
function get_type_id(registry::TypeRegistry, T::Type)::Int32
    return get(registry.type_ids, T, Int32(0))
end

"""
    is_shared_wasm_type(registry, wasm_type_idx, T) -> Bool

Check if another Julia type in the registry shares the same WasmGC type index.
When types share an index, ref.test can't distinguish them and typeId-based
dispatch is needed.
"""
function is_shared_wasm_type(registry::TypeRegistry, wasm_type_idx::UInt32, T::Type)::Bool
    registry.structs === nothing && return false
    for (other_type, other_info) in registry.structs
        if other_info.wasm_type_idx == wasm_type_idx && other_type !== T
            return true
        end
    end
    return false
end

"""
    ensure_type_id!(registry, T) -> Int32

Get or assign a unique typeId for type T. If T doesn't have one yet,
assign the next available ID. Returns the typeId.
"""
function ensure_type_id!(registry::TypeRegistry, T::Type)::Int32
    existing = get_type_id(registry, T)
    existing > 0 && return existing
    # Assign next available ID (find max + 1)
    registry.type_ids === nothing && (registry.type_ids = Dict{Type, Int32}())
    max_id = Int32(0)
    for (_, id) in registry.type_ids
        max_id = max(max_id, id)
    end
    new_id = max_id + Int32(1)
    registry.type_ids[T] = new_id
    return new_id
end

"""
    get_type_range(registry::TypeRegistry, T::Type) -> Union{Tuple{Int32, Int32}, Nothing}

Return the DFS [low, high] range for an abstract type, or nothing if not assigned.
"""
function get_type_range(registry::TypeRegistry, T::Type)::Union{Tuple{Int32, Int32}, Nothing}
    return get(registry.type_ranges, T, nothing)
end

"""
    serialize_type_ids(registry::TypeRegistry) -> Dict{String, Any}

Serialize the type ID table to a Dict suitable for JSON output.
"""
function serialize_type_ids(registry::TypeRegistry)::Dict{String, Any}
    result = Dict{String, Any}()
    ids = Dict{String, Int32}()
    for (T, id) in registry.type_ids
        ids[string(T)] = id
    end
    result["type_ids"] = ids

    ranges = Dict{String, Any}()
    for (T, (low, high)) in registry.type_ranges
        ranges[string(T)] = Dict("low" => low, "high" => high)
    end
    result["type_ranges"] = ranges
    return result
end

"""
    serialize_type_registry(registry::TypeRegistry) -> Dict{String, Any}

Serialize the full type registry to a Dict suitable for JSON output.
Includes type_ids, type_ranges, structs, and arrays.
"""
function serialize_type_registry(registry::TypeRegistry)::Dict{String, Any}
    result = serialize_type_ids(registry)

    # Struct types
    structs = Dict{String, Any}[]
    for (T, info) in sort(collect(registry.structs), by=x->x[2].wasm_type_idx)
        push!(structs, Dict{String, Any}(
            "julia_type" => string(T),
            "wasm_type_idx" => Int(info.wasm_type_idx),
            "field_names" => [string(f) for f in info.field_names],
            "field_types" => [string(f) for f in info.field_types],
            "field_offset" => Int(info.field_offset),
        ))
    end
    result["structs"] = structs

    # Array types
    arrays = Dict{String, Int}()
    for (T, idx) in registry.arrays
        arrays[string(T)] = Int(idx)
    end
    result["arrays"] = arrays

    return result
end

"""
    emit_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, T::Type)

Emit `i32.const <typeId>` bytecode for type T.
Uses the DFS-assigned type ID, or 0 if T has no assigned ID.
"""
function emit_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, T::Type)
    # E2E-001: Use ensure_type_id! so that types registered after assign_type_ids!()
    # (e.g., types appearing only in isa checks or struct constants) still get unique
    # typeIds that match between struct construction and isa dispatch.
    id = ensure_type_id!(registry, T)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(Int64(id)))
end

"""
    emit_box_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, wasm_type::WasmValType)

PURE-9028: Emit `i32.const <typeId>` for a boxed primitive value.
Maps WasmValType → default Julia type → DFS typeId.
Used at boxing sites where only the Wasm type is known.
"""
function emit_box_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, wasm_type::WasmValType)
    julia_type = if wasm_type === I32
        Int32
    elseif wasm_type === I64
        Int64
    elseif wasm_type === F32
        Float32
    elseif wasm_type === F64
        Float64
    else
        Any
    end
    emit_type_id!(bytes, registry, julia_type)
end

"""
PURE-9028: Box an i32 value as ref.i31 (zero-allocation boxing for small integers).
Expects an i32 on the Wasm stack. Produces (ref i31) which is a subtype of anyref.
Use for Bool, Int8, UInt8, Int16, UInt16 — values that always fit in 31 bits.
"""
function emit_box_i31!(bytes::Vector{UInt8})
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.REF_I31)
end

"""
PURE-9028: Unbox a ref.i31 value to i32 (signed extension).
Expects (ref null i31) on the Wasm stack. Produces i32.
"""
function emit_unbox_i31_s!(bytes::Vector{UInt8})
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.I31_GET_S)
end

"""
PURE-9028: Unbox a ref.i31 value to i32 (unsigned extension).
Expects (ref null i31) on the Wasm stack. Produces i32.
Use for UInt8, UInt16, Bool (non-negative values).
"""
function emit_unbox_i31_u!(bytes::Vector{UInt8})
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.I31_GET_U)
end

"""
PURE-9028: Check if a Julia type should use ref.i31 for boxing (fits in 31 bits).
"""
function should_use_i31(T::Type)::Bool
    T === Bool || T === Int8 || T === UInt8 || T === Int16 || T === UInt16
end

"""
    get_base_struct_type!(mod::WasmModule, registry::TypeRegistry) -> UInt32

Get or create the base struct type \$JlBase = (struct (field i32)).
All other struct types should be subtypes of this, enabling typeof(x) via
struct.get \$JlBase 0 on any struct reference.
"""
function get_base_struct_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.base_struct_idx !== nothing
        return registry.base_struct_idx
    end
    # Create $JlBase = (struct (field i32)) — no supertype, non-final
    base_type = StructType([FieldType(I32, false)], nothing)
    idx = add_type!(mod, base_type)
    registry.base_struct_idx = idx
    return idx
end

"""
    emit_typeof!(bytes::Vector{UInt8}, base_idx::UInt32)

Emit bytecode to extract typeId (field 0) from a struct reference on the stack.
Assumes the value on top of the stack is a struct ref (or anyref that can be cast).
Result: i32 typeId on the stack.
"""
function emit_typeof!(bytes::Vector{UInt8}, base_idx::UInt32)
    # ref.cast (ref $JlBase) — cast anyref/structref to base struct ref
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.REF_CAST)  # ref.cast non-null: immediate is just the heap type index
    append!(bytes, encode_leb128_signed(Int64(base_idx)))
    # struct.get $JlBase 0 — extract typeId field
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(base_idx))
    append!(bytes, encode_leb128_unsigned(UInt32(0)))
end

# PURE-9063: Kind constants for $JlType.$kind field
const JL_TYPE_KIND_DATATYPE  = Int32(0)
const JL_TYPE_KIND_UNION     = Int32(1)
const JL_TYPE_KIND_UNIONALL  = Int32(2)
const JL_TYPE_KIND_TYPEVAR   = Int32(3)

"""
    create_jl_type_hierarchy!(mod::WasmModule, registry::TypeRegistry)

Create the \$JlType hierarchy of WasmGC struct types for runtime type representation.
This is separate from \$JlBase (which is for user struct typeId extraction).

Hierarchy (from §3.2.5):
  \$JlType         = (struct (field \$kind i32))
  \$JlDataType     = (sub \$JlType (struct \$kind, \$name, \$super, \$parameters, \$hash, \$abstract, \$dfs_low, \$dfs_high))
  \$JlUnion        = (sub \$JlType (struct \$kind, \$a, \$b))
  \$JlUnionAll     = (sub \$JlType (struct \$kind, \$body, \$var))
  \$JlTypeVar      = (sub \$JlType (struct \$kind, \$name, \$lb, \$ub))
  \$JlTypeName     = (struct \$name_str, \$module_name_str, \$wrapper)
  \$JlSVec         = (array (mut (ref null \$JlType)))

Must be called early, before type constant globals are created.
"""
function create_jl_type_hierarchy!(mod::WasmModule, registry::TypeRegistry)
    registry.jl_type_idx !== nothing && return  # Already created

    # 1. $JlType base: (struct (field $kind (mut i32)))
    # Mutable so subtypes ($JlUnion, $JlUnionAll, $JlTypeVar) can set different kind values
    jl_type = StructType([FieldType(I32, true)], nothing)
    jl_type_idx = add_type!(mod, jl_type)
    registry.jl_type_idx = jl_type_idx

    # 2. $JlTypeName: (struct (field $name (ref null str), $module_name (ref null str), $wrapper (ref null $JlType)))
    # All fields mutable — populated by start function after struct.new_default
    str_arr_idx = get_string_array_type!(mod, registry)
    jl_typename = StructType([
        FieldType(ConcreteRef(str_arr_idx, true), true),       # name (mut string ref)
        FieldType(ConcreteRef(str_arr_idx, true), true),       # module_name (mut string ref)
        FieldType(ConcreteRef(jl_type_idx, true), true),       # wrapper (mut ref null $JlType)
    ], nothing)
    jl_typename_idx = add_type!(mod, jl_typename)
    registry.jl_typename_idx = jl_typename_idx

    # 3. $JlSVec: (array (mut (ref null $JlType)))
    jl_svec = ArrayType(FieldType(ConcreteRef(jl_type_idx, true), true))
    jl_svec_idx = add_type!(mod, jl_svec)
    registry.jl_svec_idx = jl_svec_idx

    # 4. $JlDataType: (sub $JlType (struct $kind, $name, $super, $parameters, $hash, $abstract, $dfs_low, $dfs_high))
    # All fields mutable because struct.new_default creates zeroed instance, then start function populates
    jl_datatype = StructType([
        FieldType(I32, true),                                    # kind (mut i32) = TYPE_DATATYPE=0 (default)
        FieldType(ConcreteRef(jl_typename_idx, true), true),     # name (mut ref null $JlTypeName)
        FieldType(ConcreteRef(jl_type_idx, true), true),         # super (mut ref null $JlType)
        FieldType(ConcreteRef(jl_svec_idx, true), true),         # parameters (mut ref null $JlSVec)
        FieldType(I32, true),                                    # hash (mut i32)
        FieldType(I32, true),                                    # abstract (mut i32): 1 if abstract, 0 if concrete
        FieldType(I32, true),                                    # dfs_low (mut i32)
        FieldType(I32, true),                                    # dfs_high (mut i32)
    ], jl_type_idx)  # sub $JlType
    jl_datatype_idx = add_type!(mod, jl_datatype)
    registry.jl_datatype_idx = jl_datatype_idx

    # 5. $JlUnion: (sub $JlType (struct $kind, $a, $b))
    jl_union = StructType([
        FieldType(I32, true),                                    # kind (mut i32) = TYPE_UNION=1
        FieldType(ConcreteRef(jl_type_idx, true), true),         # a (mut ref null $JlType)
        FieldType(ConcreteRef(jl_type_idx, true), true),         # b (mut ref null $JlType)
    ], jl_type_idx)
    jl_union_idx = add_type!(mod, jl_union)
    registry.jl_union_idx = jl_union_idx

    # 6. $JlUnionAll: (sub $JlType (struct $kind, $body, $var))
    jl_unionall = StructType([
        FieldType(I32, true),                                    # kind (mut i32) = TYPE_UNIONALL=2
        FieldType(ConcreteRef(jl_type_idx, true), true),         # body (mut ref null $JlType)
        FieldType(ConcreteRef(jl_type_idx, true), true),         # var (mut ref null $JlType) — $JlTypeVar is a subtype
    ], jl_type_idx)
    jl_unionall_idx = add_type!(mod, jl_unionall)
    registry.jl_unionall_idx = jl_unionall_idx

    # 7. $JlTypeVar: (sub $JlType (struct $kind, $name, $lb, $ub))
    jl_typevar = StructType([
        FieldType(I32, true),                                    # kind (mut i32) = TYPE_TYPEVAR=3
        FieldType(ConcreteRef(str_arr_idx, true), true),         # name (mut string ref)
        FieldType(ConcreteRef(jl_type_idx, true), true),         # lb (mut ref null $JlType)
        FieldType(ConcreteRef(jl_type_idx, true), true),         # ub (mut ref null $JlType)
    ], jl_type_idx)
    jl_typevar_idx = add_type!(mod, jl_typevar)
    registry.jl_typevar_idx = jl_typevar_idx

    # PURE-9064: Register Julia type system types as StructInfo entries
    # so that isa(x, Union), getfield(::DataType, :parameters), PiNode narrowing, etc.
    # all work through the existing codegen paths.
    # field_offset=1 because field 0 is always $kind (like typeId for user structs)

    # Union: fields a, b (both ref null $JlType)
    registry.structs[Union] = StructInfo(
        Union, jl_union_idx,
        [:a, :b],
        Type[Any, Any],
        UInt32(1)  # skip kind field
    )

    # DataType: fields name, super, parameters, hash, abstract, dfs_low, dfs_high
    registry.structs[DataType] = StructInfo(
        DataType, jl_datatype_idx,
        [:name, :super, :parameters, :hash, :abstract, :dfs_low, :dfs_high],
        Type[Core.TypeName, DataType, Core.SimpleVector, Int32, Int32, Int32, Int32],
        UInt32(1)  # skip kind field
    )

    # UnionAll: fields body, var
    registry.structs[UnionAll] = StructInfo(
        UnionAll, jl_unionall_idx,
        [:body, :var],
        Type[Any, TypeVar],
        UInt32(1)  # skip kind field
    )

    # TypeVar: fields name, lb, ub
    registry.structs[TypeVar] = StructInfo(
        TypeVar, jl_typevar_idx,
        [:name, :lb, :ub],
        Type[String, Any, Any],
        UInt32(1)  # skip kind field
    )

    # Core.TypeName: fields name, module_name, wrapper (NO kind prefix)
    registry.structs[Core.TypeName] = StructInfo(
        Core.TypeName, jl_typename_idx,
        [:name, :module, :wrapper],
        Type[String, String, Any],
        UInt32(0)  # no kind/typeId prefix
    )
end

"""
    set_struct_supertypes!(mod::WasmModule, base_idx::UInt32)

Post-processing: set all StructType objects in the module to be subtypes of the
base struct type (at base_idx). This enables typeof(x) via struct.get \$JlBase 0
on any struct reference.

Must be called AFTER all types are registered and BEFORE serialization.
"""
function set_struct_supertypes!(mod::WasmModule, base_idx::UInt32; registry::Union{Nothing, TypeRegistry}=nothing)
    # PURE-9063: Collect JlType hierarchy indices to exclude from $JlBase subtyping
    jl_exclude = Set{UInt32}()
    if registry !== nothing
        for idx in (registry.jl_type_idx, registry.jl_typename_idx)
            idx !== nothing && push!(jl_exclude, idx)
        end
    end
    for (i, ct) in enumerate(mod.types)
        ti = UInt32(i - 1)
        if ct isa StructType && ti != base_idx && ct.supertype_idx === nothing && !(ti in jl_exclude)
            # Replace with version that declares base as supertype
            mod.types[i] = StructType(ct.fields, base_idx)
        end
    end
end

# ============================================================================
# Function Registry - for multi-function modules
# ============================================================================

"""
Information about a compiled function within a module.
"""
struct FunctionInfo
    name::String
    func_ref::Any           # Original Julia function
    arg_types::Tuple        # Argument types for dispatch
    wasm_idx::UInt32        # Index in the Wasm module
    return_type::Type       # Return type (Nothing means void)
end

"""
Registry for functions within a module, enabling cross-function calls.
"""
mutable struct FunctionRegistry
    functions::Vector{Tuple{String, FunctionInfo}}       # name -> info (linear scan)
    by_ref::Vector{Tuple{Any, Vector{FunctionInfo}}}     # func_ref -> infos (linear scan)
end

FunctionRegistry() = FunctionRegistry(Tuple{String, FunctionInfo}[], Tuple{Any, Vector{FunctionInfo}}[])

"""
    serialize_function_table(registry::FunctionRegistry) -> Vector{Dict{String, Any}}

Serialize the function table to a list of Dicts suitable for JSON output.
Each entry has: name, arg_types, return_type, wasm_idx.
"""
function serialize_function_table(registry::FunctionRegistry)::Vector{Dict{String, Any}}
    entries = Dict{String, Any}[]
    sorted = sort(registry.functions, by=x->x[2].wasm_idx)
    for (name, info) in sorted
        push!(entries, Dict{String, Any}(
            "name" => info.name,
            "arg_types" => [string(T) for T in info.arg_types],
            "return_type" => string(info.return_type),
            "wasm_idx" => Int(info.wasm_idx),
        ))
    end
    return entries
end

"""
Register a function in the registry.
"""
function register_function!(registry::FunctionRegistry, name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type=Any)
    info = FunctionInfo(name, func_ref, arg_types, wasm_idx, return_type)

    # Update or add in functions list (linear scan)
    found = false
    for i in 1:length(registry.functions)
        if registry.functions[i][1] == name
            registry.functions[i] = (name, info)
            found = true
            break
        end
    end
    if !found
        push!(registry.functions, (name, info))
    end

    # Also index by function reference for dispatch (linear scan)
    ref_found = false
    for i in 1:length(registry.by_ref)
        if registry.by_ref[i][1] === func_ref
            push!(registry.by_ref[i][2], info)
            ref_found = true
            break
        end
    end
    if !ref_found
        push!(registry.by_ref, (func_ref, FunctionInfo[info]))
    end

    return info
end

"""
Look up a function by name.
"""
function get_function(registry::FunctionRegistry, name::String)::Union{FunctionInfo, Nothing}
    for (n, info) in registry.functions
        n == name && return info
    end
    return nothing
end

"""
Look up a function by reference and argument types (for dispatch).
"""
function get_function(registry::FunctionRegistry, func_ref, arg_types::Tuple)::Union{FunctionInfo, Nothing}
    infos = nothing
    for (ref, v) in registry.by_ref
        if ref === func_ref
            infos = v
            break
        end
    end
    infos === nothing && return nothing

    # Find matching signature (exact match for now)
    for info in infos
        if info.arg_types == arg_types
            return info
        end
    end

    # Try to find a compatible signature (subtype matching: actual <: registered)
    for info in infos
        if length(info.arg_types) == length(arg_types)
            match = true
            for (expected, actual) in zip(info.arg_types, arg_types)
                if !(actual <: expected)
                    match = false
                    break
                end
            end
            if match
                return info
            end
        end
    end

    # PURE-320: Try reverse subtype match (registered <: actual).
    # This handles cases where infer_value_type returns abstract types (e.g., Type)
    # but the function was registered with concrete types (e.g., Type{SourceFile}).
    for info in infos
        if length(info.arg_types) == length(arg_types)
            match = true
            for (expected, actual) in zip(info.arg_types, arg_types)
                if !(actual <: expected) && !(expected <: actual)
                    match = false
                    break
                end
            end
            if match
                return info
            end
        end
    end

    return nothing
end

"""
Check if a function reference is registered (for by_ref linear scan).
"""
function has_func_ref(registry::FunctionRegistry, func_ref)::Bool
    for (ref, _) in registry.by_ref
        ref === func_ref && return true
    end
    return false
end

"""
Get infos for a function reference (for by_ref linear scan). Returns nothing if not found.
"""
function get_func_ref_infos(registry::FunctionRegistry, func_ref)::Union{Vector{FunctionInfo}, Nothing}
    for (ref, v) in registry.by_ref
        ref === func_ref && return v
    end
    return nothing
end

"""
Compile a constant value to WASM bytecode (for global initializers).
This is a simplified version of compile_value for use in constant expressions.
"""
function compile_const_value(val, mod::WasmModule, registry::TypeRegistry)::Vector{UInt8}
    bytes = UInt8[]

    if val isa Int32
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(val))
    elseif val isa Int64
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(val))
    elseif val isa Float32
        push!(bytes, Opcode.F32_CONST)
        append!(bytes, reinterpret(UInt8, [val]))
    elseif val isa Float64
        push!(bytes, Opcode.F64_CONST)
        append!(bytes, reinterpret(UInt8, [val]))
    elseif val isa Bool
        push!(bytes, Opcode.I32_CONST)
        push!(bytes, val ? 0x01 : 0x00)
    elseif val isa String
        # Strings are compiled as WasmGC arrays of packed i8 (UTF-8 bytes)
        # Get or create string array type
        str_type_idx = get_string_array_type!(mod, registry)

        # Push each UTF-8 byte as i32 (truncated to i8 by array.new_fixed on packed array)
        n_bytes = ncodeunits(val)
        for i in 1:n_bytes
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(codeunit(val, i))))
        end

        # array.new_fixed $type_idx $length
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(str_type_idx))
        append!(bytes, encode_leb128_unsigned(n_bytes))
    elseif val isa Vector{String}
        # Vector{String}: build the WasmGC struct { typeId:i32, data:ref(array), size:ref(tuple) }
        # struct.new pops in field order: typeId first (bottom), data, size (top)
        str_type_idx = get_string_array_type!(mod, registry)
        arr_of_str_type_idx = get_array_type!(mod, registry, String)
        vec_info = register_vector_type!(mod, registry, Vector{String})
        n = length(val)

        # Ensure size tuple type is registered
        if !haskey(registry.structs, Tuple{Int64})
            register_tuple_type!(mod, registry, Tuple{Int64})
        end
        size_tuple_idx = registry.structs[Tuple{Int64}].wasm_type_idx

        # Field 0: typeId = 0
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int32(0)))

        # Field 1: data array — array of string refs
        for s in val
            nb = ncodeunits(s)
            for i in 1:nb
                push!(bytes, Opcode.I32_CONST)
                append!(bytes, encode_leb128_signed(Int32(codeunit(s, i))))
            end
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ARRAY_NEW_FIXED)
            append!(bytes, encode_leb128_unsigned(str_type_idx))
            append!(bytes, encode_leb128_unsigned(nb))
        end
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.ARRAY_NEW_FIXED)
        append!(bytes, encode_leb128_unsigned(arr_of_str_type_idx))
        append!(bytes, encode_leb128_unsigned(n))

        # Field 2: size tuple struct { typeId:i32, dim1:i64 }
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int32(0)))
        push!(bytes, Opcode.I64_CONST)
        append!(bytes, encode_leb128_signed(Int64(n)))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(size_tuple_idx))

        # struct.new Vector{String}
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_NEW)
        append!(bytes, encode_leb128_unsigned(vec_info.wasm_type_idx))
    elseif val === nothing
        # For Nothing type, we use ref.null none (bottom of any hierarchy)
        push!(bytes, Opcode.REF_NULL)
        push!(bytes, 0x71)  # none heap type (NOT 0x6E which is any)
    else
        # For other types, try to push as integer if small enough
        T = typeof(val)
        if isprimitivetype(T) && sizeof(T) <= 4
            int_val = Core.Intrinsics.bitcast(UInt32, val)
            push!(bytes, Opcode.I32_CONST)
            append!(bytes, encode_leb128_signed(Int32(int_val)))
        elseif isprimitivetype(T) && sizeof(T) <= 8
            int_val = Core.Intrinsics.bitcast(UInt64, val)
            push!(bytes, Opcode.I64_CONST)
            append!(bytes, encode_leb128_signed(Int64(int_val)))
        else
            error("Cannot compile constant value of type $(typeof(val)) for global initializer")
        end
    end

    return bytes
end

"""
Get or create an array type for a given element type.
"""
function get_array_type!(mod::WasmModule, registry::TypeRegistry, elem_type::Type)::UInt32
    if haskey(registry.arrays, elem_type)
        return registry.arrays[elem_type]
    end

    # UInt8 arrays share the packed i8 type with String — this ensures array.copy
    # between Vector{UInt8}/Memory{UInt8} and String works (same WasmGC element type).
    # Reading from packed i8 arrays requires ARRAY_GET_U instead of ARRAY_GET.
    if elem_type === UInt8
        type_idx = get_string_array_type!(mod, registry)
        registry.arrays[elem_type] = type_idx
        return type_idx
    end

    # Create the array type
    # Check if element type is currently being registered (self-referential)
    local wasm_elem_type
    if haskey(_registering_types, elem_type)
        reserved_idx = _registering_types[elem_type]
        if reserved_idx >= 0
            # Use concrete reference to the reserved type index
            wasm_elem_type = ConcreteRef(UInt32(reserved_idx), true)
        else
            # Being registered but not self-referential - use get_concrete_wasm_type
            wasm_elem_type = get_concrete_wasm_type(elem_type, mod, registry)
        end
    else
        # Not being registered - use get_concrete_wasm_type for proper type lookup
        wasm_elem_type = get_concrete_wasm_type(elem_type, mod, registry)
    end
    type_idx = add_array_type!(mod, wasm_elem_type, true)  # mutable arrays
    registry.arrays[elem_type] = type_idx
    return type_idx
end

"""
Get or create the string array type (array of packed i8 for UTF-8 bytes).
Mutable to support array.copy for string concatenation.
"""
function get_string_array_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.string_array_idx === nothing
        # Create a packed i8 array type for UTF-8 strings (mutable for array.copy support)
        registry.string_array_idx = add_array_type!(mod, UInt8(0x78), true)
    end
    return registry.string_array_idx
end

"""
    get_or_create_string_hash_func!(mod, registry) → UInt32

PURE-9065: Lazily create a Wasm helper function that computes FNV-1a hash
over a byte array (string). Used by Dict{String,...} to replace the C memhash
foreigncall. Returns the function index.

Signature: (ref null \$str_arr, i64 len, i32 seed) → i64
Algorithm: FNV-1a with offset_basis XOR seed, iterating min(len, array.len) bytes.
"""
function get_or_create_string_hash_func!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.string_hash_func_idx !== nothing
        return registry.string_hash_func_idx
    end

    str_type_idx = get_string_array_type!(mod, registry)

    # Function params: (ref null $str_arr, i64, i32) → (i64)
    params = WasmValType[ConcreteRef(str_type_idx, true), I64, I32]
    results = WasmValType[I64]
    # Extra locals: 0=hash(i64), 1=i(i32), 2=array_len(i32)
    locals = WasmValType[I64, I32, I32]

    body = UInt8[]

    # FNV-1a offset basis: 14695981039346656037 (0xcbf29ce484222325)
    # FNV-1a prime: 1099511628211 (0x00000100000001b3)

    # hash = FNV_OFFSET_BASIS XOR (i64.extend_i32_u seed)
    push!(body, Opcode.I64_CONST)
    append!(body, encode_leb128_signed(Int64(-3750763034362895579)))  # 14695981039346656037 as signed
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(2)))  # param 2 = seed (i32)
    push!(body, Opcode.I64_EXTEND_I32_U)
    push!(body, Opcode.I64_XOR)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # local 0 (offset 3) = hash

    # array_len = array.len(arr)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # param 0 = arr
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_LEN)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # local 2 (offset 5) = array_len

    # Clamp array_len to min(len, array_len)
    # if len < array_len (as unsigned): array_len = i32.wrap(len)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # param 1 = len (i64)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # array_len
    push!(body, Opcode.I64_EXTEND_I32_U)
    push!(body, Opcode.I64_LT_U)
    push!(body, Opcode.IF)
    push!(body, 0x40)  # void block
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # len
    push!(body, Opcode.I32_WRAP_I64)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # array_len = i32(len)
    push!(body, Opcode.END)

    # i = 0
    push!(body, Opcode.I32_CONST)
    push!(body, 0x00)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # local 1 (offset 4) = i

    # block $break
    push!(body, Opcode.BLOCK)
    push!(body, 0x40)  # void

    # loop $continue
    push!(body, Opcode.LOOP)
    push!(body, 0x40)  # void

    # if i >= array_len: br $break (label 1)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # i
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(5)))  # array_len
    push!(body, Opcode.I32_GE_U)
    push!(body, Opcode.BR_IF)
    append!(body, encode_leb128_unsigned(UInt32(1)))  # br to block (break)

    # byte = array.get_u(arr, i)
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # arr
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # i
    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.ARRAY_GET_U)
    append!(body, encode_leb128_unsigned(str_type_idx))

    # hash = (hash XOR byte) * FNV_PRIME
    push!(body, Opcode.I64_EXTEND_I32_U)  # byte → i64
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # hash
    push!(body, Opcode.I64_XOR)
    push!(body, Opcode.I64_CONST)
    append!(body, encode_leb128_signed(Int64(1099511628211)))  # FNV prime
    push!(body, Opcode.I64_MUL)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # hash = result

    # i++
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # i
    push!(body, Opcode.I32_CONST)
    push!(body, 0x01)
    push!(body, Opcode.I32_ADD)
    push!(body, Opcode.LOCAL_SET)
    append!(body, encode_leb128_unsigned(UInt32(4)))  # i = i + 1

    # br $continue (label 0 = loop)
    push!(body, Opcode.BR)
    append!(body, encode_leb128_unsigned(UInt32(0)))  # continue loop

    push!(body, Opcode.END)  # end loop
    push!(body, Opcode.END)  # end block

    # return hash
    push!(body, Opcode.LOCAL_GET)
    append!(body, encode_leb128_unsigned(UInt32(3)))  # hash
    push!(body, Opcode.END)  # end function

    func_idx = add_function!(mod, params, results, locals, body)
    registry.string_hash_func_idx = func_idx
    return func_idx
end

"""
PURE-325: Get or create a box struct type for a numeric Wasm type.
Used when a function returning ExternRef needs to return a numeric value.
The box struct has a single field of the numeric type, allowing the value
to be wrapped as a GC reference and converted to externref.
"""
function get_numeric_box_type!(mod::WasmModule, registry::TypeRegistry, wasm_type::WasmValType)::UInt32
    if haskey(registry.numeric_boxes, wasm_type)
        return registry.numeric_boxes[wasm_type]
    end
    # PURE-9024: Prepend typeId:i32 as field 0 (universal object layout)
    fields = [FieldType(I32, false), FieldType(wasm_type, false)]  # typeId + value
    type_idx = add_struct_type!(mod, fields)
    registry.numeric_boxes[wasm_type] = type_idx
    return type_idx
end

"""
PURE-9028: Get or create the BoxedNothing struct type.
BoxedNothing has only typeId:i32 (no value field) — a singleton type.
"""
function get_nothing_box_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.nothing_box_idx !== nothing
        return registry.nothing_box_idx
    end
    # BoxedNothing: just typeId field (no value)
    fields = [FieldType(I32, false)]
    type_idx = add_struct_type!(mod, fields)
    registry.nothing_box_idx = type_idx
    return type_idx
end

"""
PURE-9028: Get or create a singleton global holding the BoxedNothing instance.
Returns the global index. The global is initialized with struct.new \$BoxedNothing(typeId).
"""
function get_nothing_global!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.nothing_global_idx !== nothing
        return registry.nothing_global_idx
    end
    box_type = get_nothing_box_type!(mod, registry)
    # Create init expr: i32.const <typeId> → struct.new BoxedNothing (without END)
    init_expr = UInt8[]
    emit_type_id!(init_expr, registry, Nothing)
    push!(init_expr, Opcode.GC_PREFIX)
    push!(init_expr, Opcode.STRUCT_NEW)
    append!(init_expr, encode_leb128_unsigned(box_type))
    # Use add_global_ref! which handles non-null concrete ref type + END byte
    global_idx = add_global_ref!(mod, box_type, false, init_expr; nullable=false)
    registry.nothing_global_idx = global_idx
    return global_idx
end

"""
PURE-4151 + PURE-9063: Get or create a Wasm global for a Type constant value.

Each unique Julia Type (e.g., Int64, String, Number) gets a unique Wasm global
holding a struct instance. This ensures that `ref.eq` correctly
distinguishes different Type objects at runtime.

When the JlType hierarchy is available (PURE-9063), globals use \$JlDataType
struct type (kind, name, super, parameters, hash, abstract, dfs_low, dfs_high).
Otherwise falls back to Julia's DataType struct type for backward compatibility.
"""
function get_type_constant_global!(mod::WasmModule, registry::TypeRegistry, @nospecialize(type_val::Type))::UInt32
    # Return cached global if this Type was already seen
    if haskey(registry.type_constant_globals, type_val)
        return registry.type_constant_globals[type_val]
    end

    # PURE-9063: Use $JlDataType when hierarchy is available, else fall back to Julia DataType
    if registry.jl_datatype_idx !== nothing
        dt_type_idx = registry.jl_datatype_idx
    else
        info = register_struct_type!(mod, registry, DataType)
        dt_type_idx = info.wasm_type_idx
    end

    # Create init expression: struct.new_default $dt_type_idx
    # Each struct.new_default creates a unique allocation with all fields zeroed.
    # ref.eq compares pointer identity, so different allocations are distinguishable.
    # Fields are populated later by populate_type_constant_globals!
    init_bytes = UInt8[]
    push!(init_bytes, Opcode.GC_PREFIX)
    push!(init_bytes, Opcode.STRUCT_NEW_DEFAULT)
    append!(init_bytes, encode_leb128_unsigned(dt_type_idx))

    # Create the global (mutable ref — needs patching by init function)
    global_idx = add_global_ref!(mod, dt_type_idx, true, init_bytes; nullable=false)

    # Cache
    registry.type_constant_globals[type_val] = global_idx

    # PURE-4149: Recursively ensure globals exist for the entire type hierarchy.
    # This creates globals for supertypes, TypeNames, and parameter types
    # so that field access works at runtime.
    if type_val isa DataType
        # Ensure TypeName global exists
        get_typename_constant_global!(mod, registry, type_val.name)

        # Ensure supertype global exists (recurse up the hierarchy)
        if type_val.super !== type_val  # Any.super === Any (self-referential)
            get_type_constant_global!(mod, registry, type_val.super)
        end

        # Ensure parameter type globals exist
        for i in 1:length(type_val.parameters)
            p = type_val.parameters[i]
            if p isa DataType
                get_type_constant_global!(mod, registry, p)
            end
        end
    end

    return global_idx
end

"""
    get_typename_constant_global!(mod, registry, tn::Core.TypeName) → UInt32

Get or create a Wasm global for a TypeName value.
Each TypeName gets a unique struct allocation so that `t.name === s.name`
identity comparison works via `ref.eq`.

Fields are populated by `populate_type_constant_globals!` after all globals exist.
"""
function get_typename_constant_global!(mod::WasmModule, registry::TypeRegistry, tn::Core.TypeName)::UInt32
    if haskey(registry.typename_constant_globals, tn)
        return registry.typename_constant_globals[tn]
    end

    # PURE-9063: Use $JlTypeName when hierarchy is available, else fall back to Julia TypeName
    if registry.jl_typename_idx !== nothing
        tn_type_idx = registry.jl_typename_idx
    else
        tn_info = register_struct_type!(mod, registry, Core.TypeName)
        tn_type_idx = tn_info.wasm_type_idx
    end

    # Create with struct.new_default — fields populated later
    init_bytes = UInt8[]
    push!(init_bytes, Opcode.GC_PREFIX)
    push!(init_bytes, Opcode.STRUCT_NEW_DEFAULT)
    append!(init_bytes, encode_leb128_unsigned(tn_type_idx))

    # Mutable global — needs patching by init function
    global_idx = add_global_ref!(mod, tn_type_idx, true, init_bytes; nullable=false)

    registry.typename_constant_globals[tn] = global_idx
    return global_idx
end

"""
    populate_type_constant_globals!(mod, registry)

Create a start function that populates type constant global fields for all
type constant globals. Called at the end of compile_module, after all
Type globals have been created.

PURE-9063: When \$JlType hierarchy is available, populates \$JlDataType fields:
  kind=0, name→\$JlTypeName, super→\$JlType, parameters→\$JlSVec, hash, abstract, dfs_low, dfs_high
And \$JlTypeName fields: name_str, module_name_str, wrapper

Legacy path: populates Julia DataType/TypeName struct fields via wasm_field_idx.
"""
function populate_type_constant_globals!(mod::WasmModule, registry::TypeRegistry)
    # TRUE-INT-002: Guard for Dict-free TypeRegistry (minimal constructor)
    (registry.type_constant_globals === nothing || isempty(registry.type_constant_globals)) && return

    # PURE-9063: Use $JlDataType/$JlTypeName when hierarchy is available
    use_jl_hierarchy = registry.jl_datatype_idx !== nothing

    if use_jl_hierarchy
        _populate_jl_hierarchy!(mod, registry)
    else
        _populate_legacy_types!(mod, registry)
    end
end

"""
PURE-9063: Populate \$JlDataType and \$JlTypeName fields using the JlType hierarchy.
"""
function _populate_jl_hierarchy!(mod::WasmModule, registry::TypeRegistry)
    dt_type_idx = registry.jl_datatype_idx
    tn_type_idx = registry.jl_typename_idx
    svec_idx = registry.jl_svec_idx
    jl_type_idx = registry.jl_type_idx
    str_arr_idx = get_string_array_type!(mod, registry)

    body = UInt8[]

    for (type_val, dt_global_idx) in registry.type_constant_globals
        type_val isa DataType || continue

        # Field 0: kind = TYPE_DATATYPE (0)
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(JL_TYPE_KIND_DATATYPE)))
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(0)))  # field 0 = kind

        # Field 1: name → $JlTypeName ref
        tn = type_val.name
        if haskey(registry.typename_constant_globals, tn)
            tn_global_idx = registry.typename_constant_globals[tn]
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(UInt32(1)))  # field 1 = name
        end

        # Field 2: super → $JlType ref (parent DataType is a subtype of $JlType)
        parent = type_val.super
        if parent !== type_val
            if haskey(registry.type_constant_globals, parent)
                parent_global_idx = registry.type_constant_globals[parent]
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(dt_global_idx))
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(parent_global_idx))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_SET)
                append!(body, encode_leb128_unsigned(dt_type_idx))
                append!(body, encode_leb128_unsigned(UInt32(2)))  # field 2 = super
            end
        else
            # Any.super === Any (self-referential)
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(UInt32(2)))  # field 2 = super
        end

        # Field 3: parameters → $JlSVec (array of ref null $JlType)
        params = type_val.parameters
        nparams = length(params)
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        if nparams == 0
            push!(body, Opcode.I32_CONST)
            push!(body, 0x00)
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_DEFAULT)
            append!(body, encode_leb128_unsigned(svec_idx))
        else
            for i in 1:nparams
                p = params[i]
                if p isa DataType && haskey(registry.type_constant_globals, p)
                    p_global_idx = registry.type_constant_globals[p]
                    push!(body, Opcode.GLOBAL_GET)
                    append!(body, encode_leb128_unsigned(p_global_idx))
                    # $JlDataType is sub $JlType, so ref is already compatible
                else
                    # Unknown parameter type → null ref
                    push!(body, Opcode.REF_NULL)
                    append!(body, encode_leb128_signed(Int64(jl_type_idx)))
                end
            end
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_FIXED)
            append!(body, encode_leb128_unsigned(svec_idx))
            append!(body, encode_leb128_unsigned(UInt32(nparams)))
        end
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(3)))  # field 3 = parameters

        # Field 4: hash → i32 (use Julia's type hash)
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(Int32(hash(type_val) & 0x7FFFFFFF))))
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(4)))  # field 4 = hash

        # Field 5: abstract → i32 (1 if abstract, 0 if concrete)
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(isabstracttype(type_val) ? 1 : 0)))
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(5)))  # field 5 = abstract

        # Fields 6-7: dfs_low, dfs_high → DFS range for isa checks
        if haskey(registry.type_ranges, type_val)
            dfs_low, dfs_high = registry.type_ranges[type_val]
        elseif haskey(registry.type_ids, type_val)
            dfs_id = registry.type_ids[type_val]
            dfs_low = dfs_id
            dfs_high = dfs_id
        else
            dfs_low = Int32(0)
            dfs_high = Int32(0)
        end

        # Field 6: dfs_low
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(dfs_low)))
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(6)))  # field 6 = dfs_low

        # Field 7: dfs_high
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(dfs_high)))
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(UInt32(7)))  # field 7 = dfs_high
    end

    # Populate $JlTypeName fields
    for (tn, tn_global_idx) in registry.typename_constant_globals
        # Field 0: name → string (i8 array)
        name_str = string(tn.name)
        _emit_typename_string_field!(body, tn_global_idx, tn_type_idx, str_arr_idx, UInt32(0), name_str)

        # Field 1: module_name → string (i8 array)
        mod_name = tn.module !== nothing ? string(nameof(tn.module)) : ""
        _emit_typename_string_field!(body, tn_global_idx, tn_type_idx, str_arr_idx, UInt32(1), mod_name)

        # Field 2: wrapper → $JlType ref
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(wrapper_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(tn_type_idx))
            append!(body, encode_leb128_unsigned(UInt32(2)))  # field 2 = wrapper
        end
    end

    # PURE-9063: Populate the type lookup table (typeId → DataType struct ref)
    populate_type_lookup_table!(body, registry)

    isempty(body) && return

    push!(body, Opcode.END)
    func_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], body)
    add_start_function!(mod, func_idx)
end

"""
Emit bytecode to set a string field on a \$JlTypeName global.
Creates an i8 array from UTF-8 bytes of the string.
"""
function _emit_typename_string_field!(body::Vector{UInt8}, tn_global_idx::UInt32,
                                       tn_type_idx::UInt32, str_arr_idx::UInt32,
                                       field_idx::UInt32, str::String)
    utf8 = Vector{UInt8}(str)
    n = length(utf8)

    push!(body, Opcode.GLOBAL_GET)
    append!(body, encode_leb128_unsigned(tn_global_idx))

    if n == 0
        push!(body, Opcode.I32_CONST)
        push!(body, 0x00)
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.ARRAY_NEW_DEFAULT)
        append!(body, encode_leb128_unsigned(str_arr_idx))
    else
        for b in utf8
            push!(body, Opcode.I32_CONST)
            append!(body, encode_leb128_signed(Int64(b)))
        end
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.ARRAY_NEW_FIXED)
        append!(body, encode_leb128_unsigned(str_arr_idx))
        append!(body, encode_leb128_unsigned(UInt32(n)))
    end

    push!(body, Opcode.GC_PREFIX)
    push!(body, Opcode.STRUCT_SET)
    append!(body, encode_leb128_unsigned(tn_type_idx))
    append!(body, encode_leb128_unsigned(field_idx))
end

"""
Legacy path: Populate Julia DataType/TypeName struct fields.
Used when \$JlType hierarchy is not available.
"""
function _populate_legacy_types!(mod::WasmModule, registry::TypeRegistry)
    dt_info = registry.structs[DataType]
    dt_type_idx = dt_info.wasm_type_idx
    tn_info = registry.structs[Core.TypeName]
    tn_type_idx = tn_info.wasm_type_idx
    svec_info = registry.structs[Core.SimpleVector]
    svec_arr_idx = svec_info.wasm_type_idx

    body = UInt8[]

    for (type_val, dt_global_idx) in registry.type_constant_globals
        type_val isa DataType || continue

        # 1. Set DataType.name → TypeName ref
        tn = type_val.name
        if haskey(registry.typename_constant_globals, tn)
            tn_global_idx = registry.typename_constant_globals[tn]
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 1)))
        end

        # 2. Set DataType.super → parent DataType ref
        parent = type_val.super
        if parent !== type_val
            if haskey(registry.type_constant_globals, parent)
                parent_global_idx = registry.type_constant_globals[parent]
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(dt_global_idx))
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(parent_global_idx))
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_SET)
                append!(body, encode_leb128_unsigned(dt_type_idx))
                append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 2)))
            end
        else
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 2)))
        end

        # 3. Set DataType.parameters → SimpleVector (externref array)
        params = type_val.parameters
        nparams = length(params)
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        if nparams == 0
            push!(body, Opcode.I32_CONST)
            push!(body, 0x00)
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_DEFAULT)
            append!(body, encode_leb128_unsigned(svec_arr_idx))
        else
            for i in 1:nparams
                p = params[i]
                if p isa DataType && haskey(registry.type_constant_globals, p)
                    p_global_idx = registry.type_constant_globals[p]
                    push!(body, Opcode.GLOBAL_GET)
                    append!(body, encode_leb128_unsigned(p_global_idx))
                    push!(body, Opcode.GC_PREFIX)
                    push!(body, Opcode.EXTERN_CONVERT_ANY)
                else
                    push!(body, Opcode.REF_NULL)
                    push!(body, UInt8(ExternRef))
                end
            end
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_FIXED)
            append!(body, encode_leb128_unsigned(svec_arr_idx))
            append!(body, encode_leb128_unsigned(UInt32(nparams)))
        end
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.STRUCT_SET)
        append!(body, encode_leb128_unsigned(dt_type_idx))
        append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 3)))
    end

    # Populate TypeName.wrapper field
    for (tn, tn_global_idx) in registry.typename_constant_globals
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(wrapper_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(tn_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(tn_info, 7)))
        end
    end

    # Populate the type lookup table (typeId → DataType struct ref)
    populate_type_lookup_table!(body, registry)

    isempty(body) && return

    push!(body, Opcode.END)
    func_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], body)
    add_start_function!(mod, func_idx)
end

# ============================================================================
# PURE-9063: Full $JlType Hierarchy — Type Lookup Table
# ============================================================================

"""
    ensure_all_type_globals!(mod::WasmModule, registry::TypeRegistry)

Create DataType globals for ALL types that have DFS type IDs.
This ensures every type (concrete and abstract) has a materialized \$JlDataType
struct that can be returned by typeof(x).

Must be called AFTER assign_type_ids!.
"""
function ensure_all_type_globals!(mod::WasmModule, registry::TypeRegistry)
    # Collect all types that need globals: those with DFS IDs or DFS ranges
    all_typed = Set{Type}()
    for T in keys(registry.type_ids)
        push!(all_typed, T)
    end
    for T in keys(registry.type_ranges)
        push!(all_typed, T)
    end

    # Create DataType globals for each (get_type_constant_global! is idempotent)
    for T in all_typed
        T isa DataType || continue
        get_type_constant_global!(mod, registry, T)
    end
end

"""
    create_type_lookup_table!(mod::WasmModule, registry::TypeRegistry)

Create a WasmGC array that maps typeId (i32 index) → DataType struct ref.
This enables typeof(x) to return a \$JlDataType struct by looking up the typeId.

Must be called AFTER ensure_all_type_globals!.
"""
function create_type_lookup_table!(mod::WasmModule, registry::TypeRegistry)
    isempty(registry.type_constant_globals) && return

    # PURE-9063: Use $JlDataType when hierarchy is available, else Julia DataType struct
    if registry.jl_datatype_idx !== nothing
        dt_type_idx = registry.jl_datatype_idx
    elseif haskey(registry.structs, DataType)
        dt_type_idx = registry.structs[DataType].wasm_type_idx
    else
        return  # No DataType struct registered
    end

    # Create array type: (array (mut (ref null $DataType)))
    arr_type = ArrayType(FieldType(ConcreteRef(dt_type_idx, true), true))
    arr_type_idx = add_type!(mod, arr_type)
    registry.type_lookup_array_idx = arr_type_idx

    # Determine table size: max typeId + 1
    max_id = Int32(0)
    for id in values(registry.type_ids)
        max_id = max(max_id, id)
    end
    # Also check abstract types that have ranges but may not have IDs
    for (_, (_, high)) in registry.type_ranges
        max_id = max(max_id, high)
    end
    table_size = max_id + Int32(1)

    # Create the lookup array global initialized with null refs
    # Init expression: i32.const <size>, array.new_default $arr_type
    init_bytes = UInt8[]
    push!(init_bytes, Opcode.I32_CONST)
    append!(init_bytes, encode_leb128_signed(Int64(table_size)))
    push!(init_bytes, Opcode.GC_PREFIX)
    push!(init_bytes, Opcode.ARRAY_NEW_DEFAULT)
    append!(init_bytes, encode_leb128_unsigned(arr_type_idx))

    global_idx = add_global_ref!(mod, arr_type_idx, true, init_bytes; nullable=false)
    registry.type_lookup_global = global_idx
    registry.type_lookup_table_size = table_size  # WBUILD-4000: record for OOB guard
end

"""
    populate_type_lookup_table!(body::Vector{UInt8}, registry::TypeRegistry)

Emit bytecode into a start function body to populate the type lookup array.
For each type with a DFS ID and a DataType global, emits:
  global.get \$type_table
  i32.const <typeId>
  global.get \$dt_global
  array.set \$arr_type

Must be called from within populate_type_constant_globals! (appended to the body).
"""
function populate_type_lookup_table!(body::Vector{UInt8}, registry::TypeRegistry)
    registry.type_lookup_global === nothing && return
    registry.type_lookup_array_idx === nothing && return

    table_global = registry.type_lookup_global
    arr_type_idx = registry.type_lookup_array_idx

    # WBUILD-4000: Compute table size (must match create_type_lookup_table! sizing).
    # Types registered after create_type_lookup_table! (via ensure_type_id! during body
    # compilation) may have IDs exceeding the table size — skip those to avoid OOB.
    table_size = registry.type_lookup_table_size

    # For each concrete type with a DFS ID and a DataType global, populate the table
    for (T, type_id) in registry.type_ids
        T isa DataType || continue
        haskey(registry.type_constant_globals, T) || continue
        type_id >= table_size && continue  # Skip late-arriving types that exceed table bounds
        dt_global_idx = registry.type_constant_globals[T]

        # global.get $type_table
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(table_global))
        # i32.const <typeId>
        push!(body, Opcode.I32_CONST)
        append!(body, encode_leb128_signed(Int64(type_id)))
        # global.get $dt_global
        push!(body, Opcode.GLOBAL_GET)
        append!(body, encode_leb128_unsigned(dt_global_idx))
        # array.set $arr_type
        push!(body, Opcode.GC_PREFIX)
        push!(body, Opcode.ARRAY_SET)
        append!(body, encode_leb128_unsigned(arr_type_idx))
    end
end

"""
    emit_typeof_struct!(bytes::Vector{UInt8}, base_idx::UInt32, registry::TypeRegistry)

Emit bytecode for typeof(x) that returns a DataType struct ref instead of i32.
Expects a struct ref (or anyref) on top of the stack.
Result: (ref null \$DataType) on the stack.

Flow: value → extract typeId → global.get type_table → array.get[typeId]
"""
function emit_typeof_struct!(bytes::Vector{UInt8}, base_idx::UInt32, registry::TypeRegistry)
    registry.type_lookup_global === nothing && error("Type lookup table not created")
    registry.type_lookup_array_idx === nothing && error("Type lookup array type not created")

    # Extract typeId from value (ref.cast $JlBase + struct.get field 0 → i32)
    emit_typeof!(bytes, base_idx)

    # Look up in type table: global.get $table → array.get $arr[typeId]
    # Stack: [typeId:i32]
    # Need: [arr_ref, typeId:i32] for array.get
    # Use a local? No — we can reorder: push table first, then typeId via local.tee is complex.
    # Simpler: the typeId is already on stack. We need to get the table below it.
    # Approach: save typeId to a temp, push table, restore typeId, array.get
    # But we don't have a local here... We can use a pattern that's common in WasmGC:
    # Actually, we just need to structure the stack correctly.
    # After emit_typeof!, stack has: [..., typeId:i32]
    # We need: [..., (ref $arr), typeId:i32]
    # Can't insert below stack top without locals.

    # WORKAROUND: Use a fresh approach — emit table ref first, then typeof
    # This requires restructuring. Instead, we use a convention that the caller
    # provides a scratch local for typeId. But that complicates the API.

    # Better: accept that we need caller to manage stack. Return (needs_local=true, body)
    # OR: just emit global.get BEFORE typeof and use a local.tee in the caller.

    # SIMPLEST: emit the array lookup inline with a known local index convention.
    # The caller (compile_call in calls.jl) will allocate a local and provide its index.
    error("emit_typeof_struct! should not be called directly; use emit_typeof_struct_with_local! instead")
end

"""
    emit_typeof_struct_with_local!(bytes::Vector{UInt8}, base_idx::UInt32,
                                    registry::TypeRegistry, temp_local::UInt32)

Emit bytecode for typeof(x) returning a DataType struct ref.
Uses `temp_local` as scratch space for the typeId.
Expects a struct ref on the stack. Leaves a (ref null \$DataType) on the stack.
"""
function emit_typeof_struct_with_local!(bytes::Vector{UInt8}, base_idx::UInt32,
                                         registry::TypeRegistry, temp_local::UInt32)
    registry.type_lookup_global === nothing && return
    registry.type_lookup_array_idx === nothing && return

    # Extract typeId: ref.cast $JlBase + struct.get → i32
    emit_typeof!(bytes, base_idx)
    # Stack: [typeId:i32]

    # Save typeId to scratch local
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(temp_local))

    # Push type lookup array
    push!(bytes, Opcode.GLOBAL_GET)
    append!(bytes, encode_leb128_unsigned(registry.type_lookup_global))

    # Push typeId back
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(temp_local))

    # array.get $type_lookup_array → (ref null $DataType)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET)
    append!(bytes, encode_leb128_unsigned(registry.type_lookup_array_idx))
end

"""
Get or create an array type that holds string references.
Used for StringDict keys array.
"""
function get_string_ref_array_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    # First ensure string array type exists
    str_type_idx = get_string_array_type!(mod, registry)

    # Create array type for string refs if not exists
    # Key: use Vector{String} as the Julia type marker
    if !haskey(registry.arrays, Vector{String})
        # Element type is (ref null str_type_idx) - ConcreteRef with nullable=true
        str_ref_type = ConcreteRef(str_type_idx, true)
        arr_idx = add_array_type!(mod, str_ref_type, true)
        registry.arrays[Vector{String}] = arr_idx
    end
    return registry.arrays[Vector{String}]
end

"""
Get a concrete Wasm type for a Julia type, using the module and registry.
This is used before CompilationContext is created.
"""
function get_concrete_wasm_type(T::Type, mod::WasmModule, registry::TypeRegistry)::WasmValType
    # Union{} (bottom type) indicates unreachable code - return void/nothing
    if T === Union{}
        # Return a sentinel value that will cause UNREACHABLE to be emitted
        # For now, use i64 as a placeholder (this type won't actually be used)
        return I64
    end
    # PURE-4155: Type{X} singleton values (e.g., Type{Int64}) are represented as DataType
    # struct refs via global.get. Only match SINGLETON types (not struct types like Union/DataType).
    # PURE-4151: Exclude Union types (e.g., Union{Type{Int64}, Type{Number}}) — these are
    # multi-variant unions that map to AnyRef (via julia_to_wasm_type), not single DataType refs.
    if T <: Type && !(T isa UnionAll) && !(T isa Union) && !isstructtype(T)
        # PURE-9063: Use $JlDataType when hierarchy is available
        dt_idx = get_datatype_type_idx(registry)
        return ConcreteRef(dt_idx, true)
    end
    if T === String || T === Symbol
        # Strings and Symbols are WasmGC arrays of bytes
        # Symbol is represented as its name string (byte array)
        type_idx = get_string_array_type!(mod, registry)
        return ConcreteRef(type_idx, true)
    elseif is_closure_type(T)
        # Closure types are structs with captured variables
        if haskey(registry.structs, T)
            info = registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            register_closure_type!(mod, registry, T)
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
        return StructRef
    elseif is_struct_type(T)
        if haskey(registry.structs, T)
            info = registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            register_struct_type!(mod, registry, T)
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
        return StructRef
    elseif T <: Tuple
        if haskey(registry.structs, T)
            info = registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            register_tuple_type!(mod, registry, T)
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
        return StructRef
    elseif T isa DataType && (T.name.name === :MemoryRef || T.name.name === :GenericMemoryRef)
        # MemoryRef{T} / GenericMemoryRef maps to array type for element T
        # IMPORTANT: Check BEFORE AbstractArray since MemoryRef <: AbstractArray
        elem_type = T.name.name === :GenericMemoryRef ? T.parameters[2] : T.parameters[1]
        type_idx = get_array_type!(mod, registry, elem_type)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :Memory || T.name.name === :GenericMemory)
        # Memory{T} / GenericMemory maps to array type for element T
        # IMPORTANT: Check BEFORE AbstractArray since Memory <: AbstractArray
        elem_type = T.parameters[2]  # Element type is second parameter for GenericMemory
        type_idx = get_array_type!(mod, registry, elem_type)
        return ConcreteRef(type_idx, true)
    elseif T <: AbstractArray  # Handles Vector, Matrix, and higher-dim arrays
        # Both Vector and Matrix are stored as structs with (ref, size) fields
        # This allows setfield!(v, :size, ...) for push!/resize! operations
        if T <: Array
            # Julia Vector/Array gets (ref, size) layout
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            else
                info = register_vector_type!(mod, registry, T)
                return ConcreteRef(info.wasm_type_idx, true)
            end
        elseif T <: AbstractVector && T isa DataType
            # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            else
                info = register_struct_type!(mod, registry, T)
                return ConcreteRef(info.wasm_type_idx, true)
            end
        else
            # Matrix and higher-dim arrays: register as struct
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            else
                info = register_matrix_type!(mod, registry, T)
                return ConcreteRef(info.wasm_type_idx, true)
            end
        end
    elseif T === Int128 || T === UInt128
        # 128-bit integers are represented as WasmGC structs with two i64 fields
        if haskey(registry.structs, T)
            info = registry.structs[T]
            return ConcreteRef(info.wasm_type_idx, true)
        else
            info = register_int128_type!(mod, registry, T)
            return ConcreteRef(info.wasm_type_idx, true)
        end
    elseif T isa Union
        # Handle Union types - use the inner type for Union{Nothing, T}
        inner_type = get_nullable_inner_type(T)
        if inner_type !== nothing
            # Union{Nothing, T} -> concrete type of T (nullable reference)
            return get_concrete_wasm_type(inner_type, mod, registry)
        else
            # Multi-variant union - fall back to generic type
            return julia_to_wasm_type(T)
        end
    elseif T === Core.SimpleVector
        # PURE-9064: Core.SimpleVector maps to $JlSVec array type when JlType hierarchy is active.
        # This ensures field access on DataType.parameters returns the correct type.
        if registry.jl_svec_idx !== nothing
            return ConcreteRef(registry.jl_svec_idx, true)
        end
        return ArrayRef
    elseif T === Core.TypeName
        # PURE-9064: Core.TypeName maps to $JlTypeName struct type when hierarchy is active.
        if registry.jl_typename_idx !== nothing
            return ConcreteRef(registry.jl_typename_idx, true)
        end
        return StructRef
    else
        return julia_to_wasm_type(T)
    end
end

