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
    structs::Dict{Type, StructInfo}  # DataType or UnionAll for parametric types
    arrays::Dict{Type, UInt32}  # Element type -> array type index
    string_array_idx::Union{Nothing, UInt32}  # Index of i8 array type for strings
    unions::Dict{Union, UnionInfo}  # Union type -> tagged union info
    numeric_boxes::Dict{WasmValType, UInt32}  # PURE-325: box types for numeric→externref returns
    # PURE-4151: Type constant globals — each unique Type value gets a unique Wasm global
    # so that ref.eq distinguishes different Types (e.g., Int64 !== String)
    type_constant_globals::Dict{Type, UInt32}  # Type value -> Wasm global index
    # PURE-4149: TypeName constant globals — each unique TypeName gets a unique Wasm global
    # so that t.name === s.name identity comparison works via ref.eq
    typename_constant_globals::Dict{Core.TypeName, UInt32}  # TypeName -> Wasm global index
    # PURE-9025: DFS type ID assignment for runtime dispatch
    type_ids::Dict{Type, Int32}  # Concrete type -> unique DFS integer ID
    type_ranges::Dict{Type, Tuple{Int32, Int32}}  # Abstract/concrete type -> [low, high] DFS range
    # PURE-9026: Base struct type index for typeof(x) extraction
    base_struct_idx::Union{Nothing, UInt32}  # Index of $JlBase = (struct (field i32))
end

TypeRegistry() = TypeRegistry(Dict{Type, StructInfo}(), Dict{Type, UInt32}(), nothing, Dict{Union, UnionInfo}(), Dict{WasmValType, UInt32}(), Dict{Type, UInt32}(), Dict{Core.TypeName, UInt32}(), Dict{Type, Int32}(), Dict{Type, Tuple{Int32, Int32}}(), nothing)

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
    for T in (Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
              Float16, Float32, Float64)
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
    emit_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, T::Type)

Emit `i32.const <typeId>` bytecode for type T.
Uses the DFS-assigned type ID, or 0 if T has no assigned ID.
"""
function emit_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, T::Type)
    id = get_type_id(registry, T)
    push!(bytes, Opcode.I32_CONST)
    append!(bytes, encode_leb128_signed(Int64(id)))
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
    push!(bytes, Opcode.REF_CAST)  # ref.cast non-null
    push!(bytes, 0x63)  # ref (non-nullable)
    append!(bytes, encode_leb128_unsigned(base_idx))
    # struct.get $JlBase 0 — extract typeId field
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(base_idx))
    append!(bytes, encode_leb128_unsigned(UInt32(0)))
end

"""
    set_struct_supertypes!(mod::WasmModule, base_idx::UInt32)

Post-processing: set all StructType objects in the module to be subtypes of the
base struct type (at base_idx). This enables typeof(x) via struct.get \$JlBase 0
on any struct reference.

Must be called AFTER all types are registered and BEFORE serialization.
"""
function set_struct_supertypes!(mod::WasmModule, base_idx::UInt32)
    for (i, ct) in enumerate(mod.types)
        ti = UInt32(i - 1)
        if ct isa StructType && ti != base_idx && ct.supertype_idx === nothing
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
    functions::Dict{String, FunctionInfo}       # name -> info
    by_ref::Dict{Any, Vector{FunctionInfo}}     # func_ref -> infos (for dispatch)
end

FunctionRegistry() = FunctionRegistry(Dict{String, FunctionInfo}(), Dict{Any, Vector{FunctionInfo}}())

"""
Register a function in the registry.
"""
function register_function!(registry::FunctionRegistry, name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type=Any)
    info = FunctionInfo(name, func_ref, arg_types, wasm_idx, return_type)
    registry.functions[name] = info

    # Also index by function reference for dispatch
    if !haskey(registry.by_ref, func_ref)
        registry.by_ref[func_ref] = FunctionInfo[]
    end
    push!(registry.by_ref[func_ref], info)

    return info
end

"""
Look up a function by name.
"""
function get_function(registry::FunctionRegistry, name::String)::Union{FunctionInfo, Nothing}
    return get(registry.functions, name, nothing)
end

"""
Look up a function by reference and argument types (for dispatch).
"""
function get_function(registry::FunctionRegistry, func_ref, arg_types::Tuple)::Union{FunctionInfo, Nothing}
    infos = get(registry.by_ref, func_ref, nothing)
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
PURE-4151: Get or create a Wasm global for a Type constant value.

Each unique Julia Type (e.g., Int64, String, Number) gets a unique Wasm global
holding a non-null struct instance. This ensures that `ref.eq` correctly
distinguishes different Type objects at runtime.

Without this, all Type values compile to `i32.const 0` and become `ref.null`
when stored in ref-typed locals — making `Int64 === String` return true.

The struct type used is DataType's registered Wasm struct type, so the global
is compatible with function parameters typed as `(ref null \$datatype_struct)`.
Each `struct.new_default` creates a unique allocation → `ref.eq` returns false
for different Types.
"""
function get_type_constant_global!(mod::WasmModule, registry::TypeRegistry, @nospecialize(type_val::Type))::UInt32
    # Return cached global if this Type was already seen
    if haskey(registry.type_constant_globals, type_val)
        return registry.type_constant_globals[type_val]
    end

    # Use DataType's registered struct type so the global is compatible
    # with function parameters that expect (ref null $datatype_struct)
    info = register_struct_type!(mod, registry, DataType)
    dt_type_idx = info.wasm_type_idx

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

    # Register TypeName struct type
    tn_info = register_struct_type!(mod, registry, Core.TypeName)
    tn_type_idx = tn_info.wasm_type_idx

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

Create a start function that populates DataType and TypeName fields for all
type constant globals. Called at the end of compile_module, after all
Type globals have been created.

Populates:
- DataType.name (field 0) → TypeName global ref
- DataType.super (field 1) → parent DataType global ref
- DataType.parameters (field 2) → SimpleVector (externref array) with parameter types
- TypeName.wrapper (field 6) → DataType global ref as externref
"""
function populate_type_constant_globals!(mod::WasmModule, registry::TypeRegistry)
    isempty(registry.type_constant_globals) && return

    dt_info = registry.structs[DataType]
    dt_type_idx = dt_info.wasm_type_idx
    tn_info = registry.structs[Core.TypeName]
    tn_type_idx = tn_info.wasm_type_idx
    svec_info = registry.structs[Core.SimpleVector]
    svec_arr_idx = svec_info.wasm_type_idx

    body = UInt8[]

    for (type_val, dt_global_idx) in registry.type_constant_globals
        type_val isa DataType || continue

        # 1. Set DataType.name (PURE-9024: field 1, was field 0) → TypeName ref
        tn = type_val.name
        if haskey(registry.typename_constant_globals, tn)
            tn_global_idx = registry.typename_constant_globals[tn]
            # global.get $dt_global → struct on stack
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            # global.get $tn_global → TypeName ref
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            # struct.set $dt_type 1 (PURE-9024: +1 for typeId at field 0)
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 1)))  # field 1 = name
        end

        # 2. Set DataType.super (PURE-9024: field 2, was field 1) → parent DataType ref
        parent = type_val.super
        if parent !== type_val  # Not self-referential (Any.super === Any)
            if haskey(registry.type_constant_globals, parent)
                parent_global_idx = registry.type_constant_globals[parent]
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(dt_global_idx))
                push!(body, Opcode.GLOBAL_GET)
                append!(body, encode_leb128_unsigned(parent_global_idx))
                # struct.set $dt_type 2 (PURE-9024: +1 for typeId) — super field
                push!(body, Opcode.GC_PREFIX)
                push!(body, Opcode.STRUCT_SET)
                append!(body, encode_leb128_unsigned(dt_type_idx))
                append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 2)))  # field 2 = super
            end
        else
            # Any.super === Any → self-reference
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 2)))  # field 2 = super
        end

        # 3. Set DataType.parameters (field 2) → SimpleVector (externref array)
        params = type_val.parameters
        nparams = length(params)
        # Create array.new_fixed with parameter Type refs
        # Each element is externref (Type globals converted via extern_convert_any)
        if nparams == 0
            # Empty array: array.new_default $svec_arr_idx 0
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            push!(body, Opcode.I32_CONST)
            push!(body, 0x00)  # length 0
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_DEFAULT)
            append!(body, encode_leb128_unsigned(svec_arr_idx))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 3)))  # field 3 = parameters
        else
            # Push all parameter elements, then array.new_fixed
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(dt_global_idx))
            for i in 1:nparams
                p = params[i]
                if p isa DataType && haskey(registry.type_constant_globals, p)
                    p_global_idx = registry.type_constant_globals[p]
                    push!(body, Opcode.GLOBAL_GET)
                    append!(body, encode_leb128_unsigned(p_global_idx))
                    # Convert concrete ref to externref for the externref array
                    push!(body, Opcode.GC_PREFIX)
                    push!(body, Opcode.EXTERN_CONVERT_ANY)
                else
                    # Non-DataType parameter (e.g., Int literal for array dims) → null
                    push!(body, Opcode.REF_NULL)
                    push!(body, UInt8(ExternRef))
                end
            end
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.ARRAY_NEW_FIXED)
            append!(body, encode_leb128_unsigned(svec_arr_idx))
            append!(body, encode_leb128_unsigned(UInt32(nparams)))
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(dt_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(dt_info, 3)))  # field 3 = parameters
        end
    end

    # Populate TypeName.wrapper (field 6) → DataType ref as externref
    for (tn, tn_global_idx) in registry.typename_constant_globals
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(tn_global_idx))
            push!(body, Opcode.GLOBAL_GET)
            append!(body, encode_leb128_unsigned(wrapper_global_idx))
            # PURE-9020: TypeName.wrapper is now anyref (abstract Type)
            # Concrete DataType ref is a subtype of anyref — no conversion needed
            # (extern.convert_any would produce externref, wrong for anyref field)
            push!(body, Opcode.GC_PREFIX)
            push!(body, Opcode.STRUCT_SET)
            append!(body, encode_leb128_unsigned(tn_type_idx))
            append!(body, encode_leb128_unsigned(wasm_field_idx(tn_info, 7)))  # field 7 = wrapper (PURE-9024: +1 for typeId)
        end
    end

    isempty(body) && return

    # Add END opcode to terminate the function body
    push!(body, Opcode.END)

    # Create the init function (no params, no returns, no locals)
    func_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], body)

    # Set as start function
    add_start_function!(mod, func_idx)
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
        info = register_struct_type!(mod, registry, DataType)
        return ConcreteRef(info.wasm_type_idx, true)
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
    else
        return julia_to_wasm_type(T)
    end
end

