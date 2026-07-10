# Code Generation - Julia IR to Wasm instructions
# Maps Julia SSA statements to WebAssembly bytecode

export compile_function, compile_module, FunctionRegistry

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

# (B4/U2 — dart2wasm parity: the `UnionInfo` tagged-union descriptor + the whole
# {typeId,tag,value} wrapper scheme are DELETED. A Union value is a boxed AnyRef
# discriminated by classId — no per-union wrapper type, no tag, no descriptor.)

"""
Registry for struct and array type mappings within a module.
"""
mutable struct TypeRegistry
    structs::Union{Nothing, Dict{Type, StructInfo}}  # DataType or UnionAll for parametric types
    arrays::Union{Nothing, Dict{Type, UInt32}}  # Element type -> array type index
    string_array_idx::Union{Nothing, UInt32}  # Index of i8 array type for strings
    string_struct_idx::Union{Nothing, UInt32} # parity(M9): the CLASSED string {classId, data} <: $JlBase
    # (B4/U2: the `unions` tagged-union-wrapper registry is DELETED — a Union value is a boxed
    # AnyRef classId box, no {typeId,tag,value} wrapper, so no per-union registry is needed.)
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
    # dart class_info.dart: Top carries classId; Object extends it with the
    # lazily-assigned mutable identity-hash slot. Primitive value boxes remain
    # direct Top descendants and therefore do not carry identity state.
    base_struct_idx::Union{Nothing, UInt32}    # $JlTop = {classId:i32}
    object_struct_idx::Union{Nothing, UInt32}  # $JlObject <: Top = {classId, identityHash}
    identity_counter_global::Union{Nothing, UInt32}
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
    # F3 (dev/F3_LOOP.md): specialized Core.Box struct types, keyed by contents WASM type.
    # Distinct from numeric_boxes — the contents field is MUTABLE (written via struct.set), so a
    # Box{i64} is a different struct than the immutable {typeId,value} numeric box.
    box_types::Union{Nothing, Dict{WasmValType, UInt32}}
    # F3 L2 cross-function glue: closure type → the WASM contents type of the Core.Box it captures.
    # Populated by a pre-pass over an enclosing fn's IR (populate_box_field_types!); consulted by
    # register_closure_type! to type the captured-box field as a typed Box{contents} (else anyref).
    box_contents_types::Union{Nothing, Dict{Type, WasmValType}}
    # march7: THE ensureConstant funnel's registry (dart constants.dart:49 — ONE
    # constantInfo map for ALL constant kinds). Keyed by the VALUE (isequal/hash);
    # IMMUTABLE constants only — a mutable constant (Vector/Dict) has per-object
    # identity that structural keying would wrongly merge.
    constant_globals::Union{Nothing, Dict{Any, UInt32}}
    # census F3 (march5, dart constants.dart:427-443): interned string-constant globals —
    # every use of an equal short string literal reads ONE deduplicated global
    # (code size + `===` identity like dart). Keyed by the string value.
    string_constant_globals::Union{Nothing, Dict{String, UInt32}}
    # march7 LAZY constants (dart constants.dart:445-476/322-339): long strings get an
    # uninitialized global + a pre-created init function; use = global.get + br_on_non_null
    # + call init. Keyed by value → (global_idx, init_fn_idx).
    lazy_string_globals::Union{Nothing, Dict{String, Tuple{UInt32, UInt32}}}
    # march9: post-DFS drift ids — a concrete type numbered AFTER the closed-world DFS
    # (ensure_type_id! max+1) lies outside every abstract's [low,high]; each abstract
    # ancestor records it here so isa checks the range PLUS these (dart's multi-range,
    # code_generator.dart:3862-3883). Makes isa sound INDEPENDENT of numbering order.
    type_extra_ids::Union{Nothing, Dict{Type, Vector{Int32}}}
    # march16 (dart ClosureLayouter, closures.dart:41-118): the closure-base struct idx
    # {classId, context anyref, vtable}, per-max-arity vtable struct idxs, and per-
    # closure-body vtable GLOBAL idxs (immutable, one per compiled closure function).
    closure_base_idx::Union{Nothing, UInt32}
    closure_vtable_struct_idxs::Union{Nothing, Dict{Int, UInt32}}      # max_arity -> vtable struct
    closure_vtable_globals::Union{Nothing, Dict{Any, UInt32}}          # closure body key -> global
    # step5 THE CLASS-DAG (dart class_info.dart:278-330): synthetic {classId:i32}
    # wasm structs per ABSTRACT Julia type, each sub its parent's synthetic; concrete
    # structs subtype their nearest abstract parent instead of flat $JlBase.
    abstract_struct_idxs::Union{Nothing, Dict{Type, UInt32}}
end

TypeRegistry() = TypeRegistry(
    Dict{Type, StructInfo}(), Dict{Type, UInt32}(), nothing, nothing,
    Dict{WasmValType, UInt32}(),
    Dict{Type, UInt32}(), Dict{Core.TypeName, UInt32}(),
    Dict{Type, Int32}(), Dict{Type, Tuple{Int32, Int32}}(),
    nothing, nothing, nothing, nothing, nothing, nothing, nothing, Int32(0),
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing,  # string_hash_func_idx
    Dict{WasmValType, UInt32}(),  # box_types (F3)
    Dict{Type, WasmValType}(),    # box_contents_types (F3 L2)
    Dict{Any, UInt32}(),          # constant_globals (march7 ensureConstant)
    Dict{String, UInt32}(),       # string_constant_globals (census F3)
    Dict{String, Tuple{UInt32, UInt32}}(),  # lazy_string_globals (march7)
    Dict{Type, Vector{Int32}}(),            # type_extra_ids (march9)
    nothing, Dict{Int, UInt32}(), Dict{Any, UInt32}(),  # march16 closure layouter
    Dict{Type, UInt32}()                                # step5 class-DAG synthetics
)

# TRUE-INT-002: Dict-free constructor for WASM self-hosting.
# All Dict fields are nothing — safe for MVP Int64 arithmetic where
# no struct/array/union type registration is needed.
TypeRegistry(::Val{:minimal}) = TypeRegistry(
    nothing, nothing, nothing, nothing,  # structs, arrays, string_array_idx, string_struct_idx
    nothing, nothing,            # unions, numeric_boxes
    nothing, nothing,            # type_constant_globals, typename_constant_globals
    nothing, nothing,            # type_ids, type_ranges
    nothing, nothing, nothing, nothing, nothing,
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing,  # string_hash_func_idx
    nothing,  # box_types (F3)
    nothing,  # box_contents_types (F3 L2)
    nothing,  # constant_globals (march7)
    nothing,  # string_constant_globals (census F3)
    nothing,  # lazy_string_globals (march7)
    nothing,  # type_extra_ids (march9)
    nothing, nothing, nothing,  # march16 closure layouter
    nothing                     # step5 class-DAG synthetics
)

"""
    get_or_create_lazy_string!(mod, registry, s) -> (global_idx, init_fn_idx)

march7 LAZY constants — dart's shape (constants.dart:445-464): an uninitialized
(ref null \$JlString) global + an init function that builds the string once, stores
it, and returns it. MUST be called BEFORE function-index assignment (the index-freeze
constraint) — the literal pre-pass in compile.jl does.
"""
function get_or_create_lazy_string!(mod::WasmModule, registry::TypeRegistry, s::String)::Tuple{UInt32, UInt32}
    haskey(registry.lazy_string_globals, s) && return registry.lazy_string_globals[s]
    struct_idx = get_string_struct_type!(mod, registry)
    arr_idx = get_string_array_type!(mod, registry)
    init = vcat(UInt8[Opcode.REF_NULL], encode_leb128_signed(Int64(struct_idx)))
    g = add_global_ref!(mod, struct_idx, true, init)
    bytes = codeunits(s)
    seg_idx = add_passive_data_segment!(mod, Vector{UInt8}(bytes))
    results = WasmValType[ConcreteRef(struct_idx, true)]
    b = InstrBuilder(WasmValType[ConcreteRef(arr_idx, true)], results;
                     func_name="lazy_string_init")
    i32_const!(b, 0)
    i32_const!(b, Int64(length(bytes)))
    array_new_data!(b, arr_idx, seg_idx)
    emit_string_wrap!(b, mod, registry, 0)   # local 0 = the scratch
    global_set_peek = length(b.instrs)
    # store AND return: local.tee via global — global.set then global.get
    global_set!(b, g)
    global_get!(b, g, ConcreteRef(struct_idx, true))
    return_!(b)
    end_block!(b)
    fidx = add_function!(mod, WasmValType[], results, WasmValType[ConcreteRef(arr_idx, true)], builder_code(b))
    registry.lazy_string_globals[s] = (g, fidx)
    return (g, fidx)
end

"""
    ensure_constant_global!(mod, registry, val) -> Union{UInt32, Nothing}

march7 — THE ensureConstant funnel (dart constants.dart:49/427-443: ONE constantInfo
map deduplicating EVERY constant kind). Returns the interned global for `val`, creating
it eagerly (a pure constant-expression initializer) on first use; `nothing` when `val`
is not eager-internable (mutable kinds keep per-object identity; non-constant fields
keep the inline path). IMMUTABLE kinds only.
"""
function ensure_constant_global!(mod::WasmModule, registry::TypeRegistry, @nospecialize(val))::Union{UInt32, Nothing}
    registry.constant_globals === nothing && return nothing
    haskey(registry.constant_globals, val) && return registry.constant_globals[val]
    init = UInt8[]
    info = _const_init_bytes!(init, mod, registry, val)
    info === nothing && return nothing
    g = add_global_ref!(mod, info, false, init; nullable=false)
    registry.constant_globals[val] = g
    return g
end

# Recursively build a CONSTANT-EXPRESSION initializer for `val`; returns the struct
# type idx, or nothing when val is not eager-internable. Wasm constant exprs allow
# i32/i64/f32/f64.const, ref.null, global.get(imm), struct.new, array.new_fixed.
function _const_init_bytes!(init::Vector{UInt8}, mod::WasmModule, registry::TypeRegistry, @nospecialize(val))::Union{UInt32, Nothing}
    T = typeof(val)
    (isconcretetype(T) && isstructtype(T) && !ismutabletype(T)) || return nothing
    T <: Type && return nothing                       # Type constants have their own registry
    (T === String || T === Symbol) && return nothing  # the string registry owns these
    info = register_struct_type!(mod, registry, T)
    info === nothing && return nothing
    # LAYOUT GUARD (gate-caught, Statistics corpus): the registrar may skip or
    # transform fields (unions, vectors, Nothing slots) — the funnel emits ONLY
    # when the REGISTERED layout is exactly [typeId, then one slot per Julia
    # field] AND the wasm struct's field list agrees; any other shape → inline path.
    info.field_offset == 1 || return nothing
    length(info.field_names) == fieldcount(T) || return nothing
    local _wst = mod.types[info.wasm_type_idx + 1]
    _wst isa StructType || return nothing
    length(_wst.fields) == fieldcount(T) + 1 || return nothing
    for k in 1:fieldcount(T)
        local _fw = _wst.fields[k + 1].valtype
        local _fv = isdefined(val, k) ? getfield(val, k) : nothing
        _fv === nothing && return nothing
        local _want = _fv isa Int64 || _fv isa UInt64 ? I64 :
                      _fv isa Float64 ? F64 : _fv isa Float32 ? F32 :
                      (_fv isa Integer || _fv isa Bool || _fv isa Char) ? I32 : nothing
        if _want === nothing
            # nested immutable: the registered slot must be a concrete ref
            (_fw isa ConcreteRef) || return nothing
        else
            _fw === _want || return nothing
        end
    end
    # field 0: the typeId
    push!(init, Opcode.I32_CONST)
    append!(init, encode_leb128_signed(Int64(ensure_type_id!(registry, T))))
    # fields: every one must itself be constant-expressible
    for i in 1:fieldcount(T)
        isdefined(val, i) || return nothing
        fv = getfield(val, i)
        FT = typeof(fv)
        if fv isa Int64
            push!(init, Opcode.I64_CONST); append!(init, encode_leb128_signed(fv))
        elseif fv isa UInt64
            push!(init, Opcode.I64_CONST); append!(init, encode_leb128_signed(reinterpret(Int64, fv)))
        elseif fv isa Bool
            push!(init, Opcode.I32_CONST); append!(init, encode_leb128_signed(Int64(fv ? 1 : 0)))
        elseif fv isa Char
            # STACK-003 convention: Julia's LEFT-PACKED UTF-8 bits, NOT the codepoint
            # (gate-caught: DateFormat delimiters interned as codepoints → parse trap)
            push!(init, Opcode.I32_CONST); append!(init, encode_leb128_signed(Int64(reinterpret(Int32, reinterpret(UInt32, fv)))))
        elseif fv isa Int8 || fv isa Int16 || fv isa Int32
            push!(init, Opcode.I32_CONST); append!(init, encode_leb128_signed(Int64(fv)))
        elseif fv isa UInt8 || fv isa UInt16 || fv isa UInt32
            push!(init, Opcode.I32_CONST); append!(init, encode_leb128_signed(Int64(reinterpret(Int32, UInt32(fv)))))
        elseif fv isa Float64
            push!(init, Opcode.F64_CONST)
            append!(init, reinterpret(UInt8, [fv]))
        elseif fv isa Float32
            push!(init, Opcode.F32_CONST)
            append!(init, reinterpret(UInt8, [fv]))
        else
            # nested immutable struct constant: recurse (its bytes inline here)
            _const_init_bytes!(init, mod, registry, fv) === nothing && return nothing
        end
    end
    push!(init, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
    append!(init, encode_leb128_unsigned(UInt64(info.wasm_type_idx)))
    return UInt32(info.wasm_type_idx)
end

"""
    get_string_constant_global!(mod, registry, s) -> Union{UInt32, Nothing}

census F3 (march5) — INTERNED string constants, dart's constant→deduplicated-global
architecture (constants.dart:427-443 ensureConstant; small strings eager via
array_new_fixed, :512-564). Every use of an equal short literal reads ONE global,
matching dart's code-size and `===`-identity semantics. Strings longer than the
eager threshold return `nothing` (they keep the inline data-segment path — dart
handles those with LAZY init functions, deferred here because init functions
cannot be added during body compilation without shifting function indices).
"""
function get_string_constant_global!(mod::WasmModule, registry::TypeRegistry, s::String)::Union{UInt32, Nothing}
    registry.string_constant_globals === nothing && return nothing
    ncodeunits(s) > 64 && return nothing   # eager threshold (dart lazies large constants)
    haskey(registry.string_constant_globals, s) && return registry.string_constant_globals[s]
    struct_idx = get_string_struct_type!(mod, registry)
    arr_idx = get_string_array_type!(mod, registry)
    # constant initializer: classId; unassigned identityHash; byte array; struct.new
    init = UInt8[]
    push!(init, Opcode.I32_CONST)
    append!(init, encode_leb128_signed(Int64(ensure_type_id!(registry, String))))
    push!(init, Opcode.I32_CONST)
    append!(init, encode_leb128_signed(Int64(0)))
    bytes = codeunits(s)
    for b in bytes
        push!(init, Opcode.I32_CONST)
        append!(init, encode_leb128_signed(Int64(b)))
    end
    push!(init, Opcode.GC_PREFIX, Opcode.ARRAY_NEW_FIXED)
    append!(init, encode_leb128_unsigned(UInt64(arr_idx)))
    append!(init, encode_leb128_unsigned(UInt64(length(bytes))))
    push!(init, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
    append!(init, encode_leb128_unsigned(UInt64(struct_idx)))
    g = add_global_ref!(mod, struct_idx, false, init; nullable=false)
    registry.string_constant_globals[s] = g
    return g
end

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
function assign_type_ids!(registry::TypeRegistry; extra_concrete_types::Union{Nothing,Set{DataType}}=nothing)
    # Collect all concrete types from the registry that have typeId (field_offset > 0)
    concrete_types = Set{DataType}()
    for (T, info) in registry.structs
        if T isa DataType && isconcretetype(T) && info.field_offset > 0
            push!(concrete_types, T)
        end
    end
    # census F2 (march5): the closed world — IR-reachable types enter the numbering
    # even before (or without) struct registration; their ids/ranges are what isa
    # and the checked cast read, and lazy registration later reuses the same id.
    extra_concrete_types !== nothing && union!(concrete_types, extra_concrete_types)

    # Also include primitive numeric types that may need boxing/dispatch
    # PURE-9028: Include Nothing for BoxedNothing typeId
    # parity(M9): String + Symbol are CLASSED now — they join the hierarchy so
    # `isa AbstractString` becomes the same dense-range check as everything else.
    for T in (Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
              Float16, Float32, Float64, Nothing, String, Symbol)
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
    # march9: record the drift id on every abstract ancestor — isa checks the DFS
    # range PLUS these extras (dart's multi-range), so numbering order can't break it.
    if registry.type_extra_ids !== nothing && T isa DataType && isconcretetype(T)
        anc = supertype(T)
        while anc !== Any && anc isa DataType
            base = isempty(anc.parameters) ? anc : anc.name.wrapper
            base isa DataType && push!(get!(Vector{Int32}, registry.type_extra_ids, base), new_id)
            anc = supertype(anc)
        end
    end
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

"""builder-native (THE implementation): push the type's DFS id as i32.
E2E-001: uses ensure_type_id! so types registered after assign_type_ids!()
(isa checks / struct constants) still get unique, matching typeIds."""
function emit_type_id!(b::InstrBuilder, registry::TypeRegistry, @nospecialize(T))
    i32_const!(b, Int64(ensure_type_id!(registry, T)))
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_type_id!(bytes::Vector{UInt8}, registry::TypeRegistry, T::Type)
    b = InstrBuilder(; func_name="emit_type_id!")
    emit_type_id!(b, registry, T)
    append!(bytes, builder_code(b))
end

# census F5 (march5): emit_box_type_id! DELETED — zero callers (the docstring's
# "sole caller is emit_classid_box!'s fallback" was stale: that fallback inlines
# emit_type_id! with the width-default type directly, values.jl:513).

# (B4: the i31 boxing helpers emit_box_i31! / emit_unbox_i31_s! / emit_unbox_i31_u! /
# should_use_i31 were DELETED — dart2wasm uses no i31, and B4 routed every former i31 site
# through the single-source emit_classid_box! [classId boxes]. All four were zero-caller.)

"""
    get_base_struct_type!(mod::WasmModule, registry::TypeRegistry) -> UInt32

Get or create the Top struct type `(struct (field classId i32))`.
Every class representation is a subtype of Top, enabling class-id extraction
through field 0. Object descendants additionally subtype `get_object_struct_type!`.
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
    get_object_struct_type!(mod, registry) -> UInt32

Create dart2wasm's Object layout: immutable classId followed by a mutable i32
identity-hash slot. Ordinary heap objects subtype this struct; primitive value
boxes subtype Top directly and use their field 1 for the boxed payload.
"""
function get_object_struct_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.object_struct_idx !== nothing && return registry.object_struct_idx
    top = get_base_struct_type!(mod, registry)
    fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
    idx = UInt32(add_type!(mod, StructType(fields, top)))
    registry.object_struct_idx = idx
    return idx
end

"""Return the module-local monotonic source for newly assigned object identities."""
function get_identity_counter_global!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.identity_counter_global !== nothing && return registry.identity_counter_global
    # Zero means "unassigned" in every object slot; assigned identities begin at 1.
    idx = add_global!(mod, I32, true, Int32(0))
    registry.identity_counter_global = idx
    return idx
end

"""
    emit_typeof!(bytes::Vector{UInt8}, base_idx::UInt32)

Emit bytecode to extract typeId (field 0) from a struct reference on the stack.
Assumes the value on top of the stack is a struct ref (or anyref that can be cast).
Result: i32 typeId on the stack.
"""
function emit_typeof!(b::InstrBuilder, base_idx::UInt32)
    # ref.cast (ref $JlBase) — cast anyref/structref to base struct ref
    ref_cast!(b, Int64(base_idx), false)  # ref.cast non-null
    # struct.get $JlBase 0 — extract typeId field
    struct_get!(b, base_idx, UInt32(0), I32)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_typeof!(bytes::Vector{UInt8}, base_idx::UInt32)
    b = InstrBuilder(; func_name="emit_typeof!")
    seed_input!(b, WasmValType[AnyRef])
    emit_typeof!(b, base_idx)
    append!(bytes, builder_code(b))
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
        # march16: closure VTABLE structs hold funcref fields — they are layout
        # tables, not objects; they can never subtype {classId:i32} (dart's vtable
        # structs subtype their own #Vtable base, not the object base).
        if registry.closure_vtable_struct_idxs !== nothing
            for (_, vti) in registry.closure_vtable_struct_idxs
                push!(jl_exclude, vti)
            end
        end
    end
    for (i, ct) in enumerate(mod.types)
        ti = UInt32(i - 1)
        if ct isa StructType && ti != base_idx && ct.supertype_idx === nothing && !(ti in jl_exclude)
            # step5: per-class re-parenting where a synthetic ALREADY exists (post-body
            # creation would forward-reference — lookup only); else the flat base.
            local _dag_parent = base_idx
            if registry !== nothing && registry.abstract_struct_idxs !== nothing && registry.structs !== nothing
                for (T2, info2) in registry.structs
                    if info2.wasm_type_idx == ti && T2 isa DataType
                        local P2 = supertype(T2)
                        if P2 isa DataType && P2 !== Any && haskey(registry.abstract_struct_idxs, P2) &&
                           registry.abstract_struct_idxs[P2] < ti
                            _dag_parent = registry.abstract_struct_idxs[P2]
                        end
                        break
                    end
                end
            end
            mod.types[i] = StructType(ct.fields, _dag_parent)
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
    is_candidate::Bool      # T1.1 step 2: a dynamic-dispatch CANDIDATE specialization
                            # (discovery-added). The call-site typeId switch finds it via
                            # by_ref, but get_function cross-call resolution SKIPS it — so
                            # registering candidates can't perturb how base functions
                            # compile. Default false (base function).
end
# Back-compat: 5-arg construction is a non-candidate (base) function.
FunctionInfo(name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type) =
    FunctionInfo(name, func_ref, arg_types, wasm_idx, return_type, false)

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
function register_function!(registry::FunctionRegistry, name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type=Any; is_candidate::Bool=false)
    # campaign diagnostics: WT_LOG_REGISTRY=1 logs every registration (name,
    # arg types, index) — for hunting call-site/callee signature divergence
    get(ENV, "WT_LOG_REGISTRY", "") == "1" &&
        println(stderr, "WTREG\t", name, "\t", wasm_idx, "\t", arg_types)
    info = FunctionInfo(name, func_ref, arg_types, wasm_idx, return_type, is_candidate)

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
        (n == name && !info.is_candidate) && return info   # candidates are dispatch-only
    end
    return nothing
end

"""
Registry lookup by FULL signature only (no function identity). Needed for
capturing-closure callees (453393ca4ba4): the call site's closure VALUE is a
different instance than the one registration stored, so identity (`ref ===`)
can never match — but the self-prepended arg_types tuple identifies the entry.
"""
function get_function_by_argtypes(registry::FunctionRegistry, arg_types::Tuple)::Union{FunctionInfo, Nothing}
    for (ref, infos) in registry.by_ref, info in infos
        info.is_candidate && continue                       # candidates are dispatch-only
        info.arg_types == arg_types && return info
    end
    # subtype-tolerant pass (mirrors get_function's compatible-signature pass)
    for (ref, infos) in registry.by_ref, info in infos
        info.is_candidate && continue
        if length(info.arg_types) == length(arg_types)
            ok = true
            for (expected, actual) in zip(info.arg_types, arg_types)
                if !(actual <: expected)
                    ok = false
                    break
                end
            end
            ok && return info
        end
    end
    return nothing
end

"""
Look up a function by reference and argument types (for dispatch).
"""
function get_function(registry::FunctionRegistry, func_ref, arg_types::Tuple;
                      expected_return::Union{Nothing,Type}=nothing)::Union{FunctionInfo, Nothing}
    # 1f6e77980994 family: loose subtype passes could pick the WRONG same-name
    # overload (e.g. getindex(Vector{Bool})::Bool for a Vector{String} site →
    # i32 stored into an anyref local). When the caller knows the expected
    # return type, candidates with incompatible returns are skipped.
    _ret_ok(info) = expected_return === nothing || expected_return === Any ||
                    info.return_type === Any ||
                    info.return_type <: expected_return || expected_return <: info.return_type
    infos = nothing
    for (ref, v) in registry.by_ref
        if ref === func_ref
            infos = v
            break
        end
    end
    infos === nothing && return nothing
    # T1.1 step 2: dynamic-dispatch CANDIDATES are reachable ONLY via the call-site
    # typeId switch (which reads by_ref directly) — never via normal cross-call
    # resolution. Filtering them here keeps base function codegen byte-identical
    # whether or not discovery added candidates (the layer-2 perturbation fix).
    infos = FunctionInfo[i for i in infos if !i.is_candidate]
    isempty(infos) && return nothing

    # Find matching signature (exact match for now). Even exact arg matches are
    # gated on return compatibility: two registered overloads can share loosely
    # inferred arg types while returning different wasm classes (1f6e77980994).
    for info in infos
        if info.arg_types == arg_types && _ret_ok(info)
            return info
        end
    end

    # Try to find a compatible signature (subtype matching: actual <: registered)
    for info in infos
        if length(info.arg_types) == length(arg_types) && _ret_ok(info)
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
        if length(info.arg_types) == length(arg_types) && _ret_ok(info)
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
    b = InstrBuilder(; func_name="compile_const_value")

    if val isa Int32
        i32_const!(b, val)
    elseif val isa Int64
        i64_const!(b, val)
    elseif val isa Float32
        f32_const!(b, val)
    elseif val isa Float64
        f64_const!(b, val)
    elseif val isa Bool
        i32_const!(b, val ? 1 : 0)
    elseif val isa String
        # Strings are compiled as WasmGC arrays of packed i8 (UTF-8 bytes)
        # Get or create string array type
        str_type_idx = get_string_array_type!(mod, registry)

        # Push each UTF-8 byte as i32 (truncated to i8 by array.new_fixed on packed array)
        n_bytes = ncodeunits(val)
        for i in 1:n_bytes
            i32_const!(b, Int32(codeunit(val, i)))
        end

        # array.new_fixed $type_idx $length
        array_new_fixed!(b, str_type_idx, n_bytes, I32)
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
        i32_const!(b, Int32(0))

        # Field 1: data array — array of string refs
        for s in val
            nb = ncodeunits(s)
            for i in 1:nb
                i32_const!(b, Int32(codeunit(s, i)))
            end
            array_new_fixed!(b, str_type_idx, nb, I32)
        end
        array_new_fixed!(b, arr_of_str_type_idx, n, ConcreteRef(str_type_idx, true))

        # Field 2: size tuple struct { typeId:i32, dim1:i64 }
        i32_const!(b, Int32(0))
        i64_const!(b, Int64(n))
        struct_new!(b, size_tuple_idx, WasmValType[I32, I64])

        # struct.new Vector{String}
        struct_new!(b, vec_info.wasm_type_idx, WasmValType[I32, ConcreteRef(arr_of_str_type_idx, true), ConcreteRef(size_tuple_idx, true)])
    elseif val === nothing
        # For Nothing type, we use ref.null none (bottom of any hierarchy)
        ref_null_none!(b)
    else
        # For other types, try to push as integer if small enough
        T = typeof(val)
        if isprimitivetype(T) && sizeof(T) <= 4
            int_val = Core.Intrinsics.bitcast(UInt32, val)
            i32_const!(b, Int32(int_val))
        elseif isprimitivetype(T) && sizeof(T) <= 8
            int_val = Core.Intrinsics.bitcast(UInt64, val)
            i64_const!(b, Int64(int_val))
        else
            error("Cannot compile constant value of type $(typeof(val)) for global initializer")
        end
    end

    return builder_code(b)
end

"""
Get or create an array type for a given element type.
"""
function get_array_type!(mod::WasmModule, registry::TypeRegistry, elem_type::Type)::UInt32
    if haskey(registry.arrays, elem_type)
        return registry.arrays[elem_type]
    end

    # P2-batch26 (gap 56af911c52b2): Vector{Union{}} — `map` with an
    # always-throwing closure infers eltype Union{}. Such an array can only
    # ever be EMPTY (Union{} has no values), so the element representation is
    # arbitrary; use Int64 so the JS boundary and accessors have a concrete
    # layout instead of trapping with a type-incompatibility.
    if elem_type === Union{}
        type_idx = get_array_type!(mod, registry, Int64)
        registry.arrays[elem_type] = type_idx
        return type_idx
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
    get_string_struct_type!(mod, registry) -> UInt32

parity(M9): the CLASSED string — dart: String IS an Object class. A Julia String value is
`(struct (field i32 classId) (field (mut i32) identityHash)
         (field (ref null \$strbytes) data))`, SUBTYPE of \$JlObject,
so strings participate in classed isa (`emit_classid_range_check!`) and the M8 selector
table like every other value. String OPS unwrap `.data` once at entry and work on the
byte array (dart's methods read the class's array field the same way).
"""
function get_string_struct_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.string_struct_idx === nothing
        arr_idx = get_string_array_type!(mod, registry)
        object_idx = get_object_struct_type!(mod, registry)
        st = StructType(FieldType[FieldType(I32, false),
                                  FieldType(I32, true),
                                  FieldType(ConcreteRef(arr_idx, true), true)],
                        object_idx)
        registry.string_struct_idx = add_type!(mod, st)
    end
    return registry.string_struct_idx
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

    # Build the body via the typed InstrBuilder. Locals: params (ref,i64,i32) + extras (i64,i32,i32).
    b = InstrBuilder(WasmValType[ConcreteRef(str_type_idx, true), I64, I32, I64, I32, I32],
                     results; func_name="get_or_create_string_hash_func!")

    # FNV-1a offset basis: 14695981039346656037 (0xcbf29ce484222325)
    # FNV-1a prime: 1099511628211 (0x00000100000001b3)

    # hash = FNV_OFFSET_BASIS XOR (i64.extend_i32_u seed)
    i64_const!(b, Int64(-3750763034362895579))  # 14695981039346656037 as signed
    local_get!(b, UInt32(2))  # param 2 = seed (i32)
    num!(b, Opcode.I64_EXTEND_I32_U)
    num!(b, Opcode.I64_XOR)
    local_set!(b, UInt32(3))  # local 0 (offset 3) = hash

    # array_len = array.len(arr)
    local_get!(b, UInt32(0))  # param 0 = arr
    array_len!(b)
    local_set!(b, UInt32(5))  # local 2 (offset 5) = array_len

    # Clamp array_len to min(len, array_len)
    # if len < array_len (as unsigned): array_len = i32.wrap(len)
    local_get!(b, UInt32(1))  # param 1 = len (i64)
    local_get!(b, UInt32(5))  # array_len
    num!(b, Opcode.I64_EXTEND_I32_U)
    num!(b, Opcode.I64_LT_U)
    if_!(b)  # void block
    local_get!(b, UInt32(1))  # len
    num!(b, Opcode.I32_WRAP_I64)
    local_set!(b, UInt32(5))  # array_len = i32(len)
    end_block!(b)

    # i = 0
    i32_const!(b, 0)
    local_set!(b, UInt32(4))  # local 1 (offset 4) = i

    # block $break
    block!(b)  # void

    # loop $continue
    loop!(b)  # void

    # if i >= array_len: br $break (label 1)
    local_get!(b, UInt32(4))  # i
    local_get!(b, UInt32(5))  # array_len
    num!(b, Opcode.I32_GE_U)
    br_if!(b, UInt32(1))  # br to block (break)

    # byte = array.get_u(arr, i)
    local_get!(b, UInt32(0))  # arr
    local_get!(b, UInt32(4))  # i
    array_get!(b, str_type_idx, I32; signed=false)

    # hash = (hash XOR byte) * FNV_PRIME
    num!(b, Opcode.I64_EXTEND_I32_U)  # byte → i64
    local_get!(b, UInt32(3))  # hash
    num!(b, Opcode.I64_XOR)
    i64_const!(b, Int64(1099511628211))  # FNV prime
    num!(b, Opcode.I64_MUL)
    local_set!(b, UInt32(3))  # hash = result

    # i++
    local_get!(b, UInt32(4))  # i
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, UInt32(4))  # i = i + 1

    # br $continue (label 0 = loop)
    br!(b, UInt32(0))  # continue loop

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # return hash
    local_get!(b, UInt32(3))  # hash
    end_block!(b)  # end function

    body = builder_code(b)
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
    # census F1 (march5): declare `sub $JlBase` AT CREATION (dart class_info.dart:288 —
    # every class struct subtypes its super at definition). The finalization retrofit
    # (set_struct_supertypes!) already made this true in the EMITTED module; creating it
    # true lets the strict builder use the subtype relation DURING emission (a box-typed
    # ref validates where a $JlBase ref is expected — the typed-channel prerequisite).
    base = registry.base_struct_idx
    type_idx = base === nothing ? add_struct_type!(mod, fields) :
               add_type!(mod, StructType(fields, base))
    registry.numeric_boxes[wasm_type] = type_idx
    return type_idx
end

"""
    get_box_type!(mod, registry, contents_wasm_type) -> UInt32

F3 (dev/F3_LOOP.md): get/create the specialized `Core.Box` struct for a box whose contents have
concrete wasm type `contents_wasm_type` — `(struct (field \$typeId i32) (field \$contents (mut T)))`.
The contents field is MUTABLE (a captured variable is written via `struct.set`), so a `Box{i64}` is
a DIFFERENT struct than the immutable `{typeId,value}` numeric box. Cached in `registry.box_types`
so the enclosing fn's `%new`, the closure's captured-box field, and setfield!/getfield all share ONE
type. dart2wasm-aligned (a typed context-struct field, not a boxed `Any`).

L1 — DORMANT (no codegen call sites yet); wired through the live sites in L2.
"""
function get_box_type!(mod::WasmModule, registry::TypeRegistry, contents_wasm_type::WasmValType)::UInt32
    if registry.box_types !== nothing && haskey(registry.box_types, contents_wasm_type)
        return registry.box_types[contents_wasm_type]
    end
    # typeId (i32, immutable) + contents (T, MUTABLE)
    fields = [FieldType(I32, false), FieldType(contents_wasm_type, true)]
    type_idx = add_struct_type!(mod, fields)
    registry.box_types === nothing || (registry.box_types[contents_wasm_type] = type_idx)
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
    b = InstrBuilder(; func_name="get_nothing_global!")
    emit_type_id!(b, registry, Nothing)
    struct_new!(b, box_type, WasmValType[I32])
    init_expr = builder_code(b)
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
    b = InstrBuilder(; func_name="get_type_constant_global!")
    struct_new_default!(b, dt_type_idx)
    init_bytes = builder_code(b)

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
    b = InstrBuilder(; func_name="get_typename_constant_global!")
    struct_new_default!(b, tn_type_idx)
    init_bytes = builder_code(b)

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

    # march17: global_get! declares the global's TRUE valtype (the AnyRef lie made
    # this the #1 harvest offender — 96k tracked-type mismatches feeding struct_set!).
    b = InstrBuilder(; func_name="_populate_jl_hierarchy!", mod=mod)

    for (type_val, dt_global_idx) in registry.type_constant_globals
        type_val isa DataType || continue

        # Field 0: kind = TYPE_DATATYPE (0)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(JL_TYPE_KIND_DATATYPE))
        struct_set!(b, dt_type_idx, UInt32(0), I32)  # field 0 = kind

        # Field 1: name → $JlTypeName ref
        tn = type_val.name
        if haskey(registry.typename_constant_globals, tn)
            tn_global_idx = registry.typename_constant_globals[tn]
            begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
            begin
            local _gvt = mod.globals[Int(tn_global_idx) + 1].valtype
            global_get!(b, tn_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
            struct_set!(b, dt_type_idx, UInt32(1), ConcreteRef(tn_type_idx, true))  # field 1 = name
        end

        # Field 2: super → $JlType ref (parent DataType is a subtype of $JlType)
        parent = type_val.super
        if parent !== type_val
            if haskey(registry.type_constant_globals, parent)
                parent_global_idx = registry.type_constant_globals[parent]
                begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
                begin
            local _gvt = mod.globals[Int(parent_global_idx) + 1].valtype
            global_get!(b, parent_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
                struct_set!(b, dt_type_idx, UInt32(2), ConcreteRef(jl_type_idx, true))  # field 2 = super
            end
        else
            # Any.super === Any (self-referential)
            begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
            begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
            struct_set!(b, dt_type_idx, UInt32(2), ConcreteRef(jl_type_idx, true))  # field 2 = super
        end

        # Field 3: parameters → $JlSVec (array of ref null $JlType)
        params = type_val.parameters
        nparams = length(params)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        if nparams == 0
            i32_const!(b, 0)
            array_new_default!(b, svec_idx)
        else
            for i in 1:nparams
                p = params[i]
                if p isa DataType && haskey(registry.type_constant_globals, p)
                    p_global_idx = registry.type_constant_globals[p]
                    begin
            local _gvt = mod.globals[Int(p_global_idx) + 1].valtype
            global_get!(b, p_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
                    # $JlDataType is sub $JlType, so ref is already compatible
                else
                    # Unknown parameter type → null ref
                    ref_null!(b, Int64(jl_type_idx), ConcreteRef(UInt32(jl_type_idx), true))
                end
            end
            array_new_fixed!(b, svec_idx, UInt32(nparams), ConcreteRef(jl_type_idx, true))
        end
        struct_set!(b, dt_type_idx, UInt32(3), ConcreteRef(svec_idx, true))  # field 3 = parameters

        # Field 4: hash → i32 (use Julia's type hash)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(Int32(hash(type_val) & 0x7FFFFFFF)))
        struct_set!(b, dt_type_idx, UInt32(4), I32)  # field 4 = hash

        # Field 5: abstract → i32 (1 if abstract, 0 if concrete)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(isabstracttype(type_val) ? 1 : 0))
        struct_set!(b, dt_type_idx, UInt32(5), I32)  # field 5 = abstract

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
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(dfs_low))
        struct_set!(b, dt_type_idx, UInt32(6), I32)  # field 6 = dfs_low

        # Field 7: dfs_high
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # march17: anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(dfs_high))
        struct_set!(b, dt_type_idx, UInt32(7), I32)  # field 7 = dfs_high
    end

    # Populate $JlTypeName fields
    for (tn, tn_global_idx) in registry.typename_constant_globals
        # Field 0: name → string (i8 array)
        name_str = string(tn.name)
        _emit_typename_string_field!(b, tn_global_idx, tn_type_idx, str_arr_idx, UInt32(0), name_str)

        # Field 1: module_name → string (i8 array)
        mod_name = tn.module !== nothing ? string(nameof(tn.module)) : ""
        _emit_typename_string_field!(b, tn_global_idx, tn_type_idx, str_arr_idx, UInt32(1), mod_name)

        # Field 2: wrapper → $JlType ref
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            begin
                local _gvt = mod.globals[Int(tn_global_idx) + 1].valtype
                global_get!(b, tn_global_idx, _gvt)
                _gvt === AnyRef && ref_cast!(b, Int64(tn_type_idx), true)   # march17: the RECEIVER is a TypeName
            end
            begin
                local _gvt = mod.globals[Int(wrapper_global_idx) + 1].valtype
                global_get!(b, wrapper_global_idx, _gvt)
                _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)
            end
            struct_set!(b, tn_type_idx, UInt32(2), ConcreteRef(jl_type_idx, true))  # field 2 = wrapper
        end
    end

    # PURE-9063: Populate the type lookup table (typeId → DataType struct ref)
    populate_type_lookup_table!(b, registry)

    isempty(builder_code(b)) && return

    end_block!(b)  # function-terminating END
    body = builder_code(b)
    func_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], body)
    add_start_function!(mod, func_idx)
end

"""
Emit bytecode to set a string field on a \$JlTypeName global.
Creates an i8 array from UTF-8 bytes of the string.
"""
function _emit_typename_string_field!(b::InstrBuilder, tn_global_idx::UInt32,
                                       tn_type_idx::UInt32, str_arr_idx::UInt32,
                                       field_idx::UInt32, str::String)
    utf8 = Vector{UInt8}(str)
    n = length(utf8)

    # march17: declare truth + narrow to the TypeName receiver
    global_get!(b, tn_global_idx, AnyRef)
    ref_cast!(b, Int64(tn_type_idx), true)

    if n == 0
        i32_const!(b, 0)
        array_new_default!(b, str_arr_idx)
    else
        for byt in utf8
            i32_const!(b, Int64(byt))
        end
        array_new_fixed!(b, str_arr_idx, UInt32(n), I32)
    end

    struct_set!(b, tn_type_idx, field_idx, ConcreteRef(str_arr_idx, true))
    return b
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

    b = InstrBuilder(; func_name="_populate_legacy_types!")

    for (type_val, dt_global_idx) in registry.type_constant_globals
        type_val isa DataType || continue

        # 1. Set DataType.name → TypeName ref
        tn = type_val.name
        if haskey(registry.typename_constant_globals, tn)
            tn_global_idx = registry.typename_constant_globals[tn]
            global_get!(b, dt_global_idx, AnyRef)
            global_get!(b, tn_global_idx, AnyRef)
            struct_set!(b, dt_type_idx, wasm_field_idx(dt_info, 1), ConcreteRef(tn_type_idx, true))
        end

        # 2. Set DataType.super → parent DataType ref
        parent = type_val.super
        if parent !== type_val
            if haskey(registry.type_constant_globals, parent)
                parent_global_idx = registry.type_constant_globals[parent]
                global_get!(b, dt_global_idx, AnyRef)
                global_get!(b, parent_global_idx, AnyRef)
                struct_set!(b, dt_type_idx, wasm_field_idx(dt_info, 2), ConcreteRef(dt_type_idx, true))
            end
        else
            global_get!(b, dt_global_idx, AnyRef)
            global_get!(b, dt_global_idx, AnyRef)
            struct_set!(b, dt_type_idx, wasm_field_idx(dt_info, 2), ConcreteRef(dt_type_idx, true))
        end

        # 3. Set DataType.parameters → SimpleVector (externref array)
        params = type_val.parameters
        nparams = length(params)
        global_get!(b, dt_global_idx, AnyRef)
        if nparams == 0
            i32_const!(b, 0)
            array_new_default!(b, svec_arr_idx)
        else
            for i in 1:nparams
                p = params[i]
                if p isa DataType && haskey(registry.type_constant_globals, p)
                    p_global_idx = registry.type_constant_globals[p]
                    global_get!(b, p_global_idx, AnyRef)
                    extern_convert_any!(b)
                else
                    ref_null!(b, ExternRef)
                end
            end
            array_new_fixed!(b, svec_arr_idx, UInt32(nparams), ExternRef)
        end
        struct_set!(b, dt_type_idx, wasm_field_idx(dt_info, 3), ConcreteRef(svec_arr_idx, true))
    end

    # Populate TypeName.wrapper field
    for (tn, tn_global_idx) in registry.typename_constant_globals
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            global_get!(b, tn_global_idx, AnyRef)
            global_get!(b, wrapper_global_idx, AnyRef)
            struct_set!(b, tn_type_idx, wasm_field_idx(tn_info, 7), ConcreteRef(dt_type_idx, true))
        end
    end

    # Populate the type lookup table (typeId → DataType struct ref)
    populate_type_lookup_table!(b, registry)

    isempty(builder_code(b)) && return

    end_block!(b)  # function-terminating END
    body = builder_code(b)
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
    b = InstrBuilder(; func_name="create_type_lookup_table!")
    i32_const!(b, Int64(table_size))
    array_new_default!(b, arr_type_idx)
    init_bytes = builder_code(b)

    global_idx = add_global_ref!(mod, arr_type_idx, true, init_bytes; nullable=false)
    registry.type_lookup_global = global_idx
    registry.type_lookup_table_size = table_size  # WBUILD-4000: record for OOB guard
end

"""
    populate_type_lookup_table!(b::InstrBuilder, registry::TypeRegistry)

Emit into a start-function builder to populate the type lookup array.
For each type with a DFS ID and a DataType global, emits:
  global.get \$type_table
  i32.const <typeId>
  global.get \$dt_global
  array.set \$arr_type

Must be called from within populate_type_constant_globals! (appended to the body).
"""
function populate_type_lookup_table!(b::InstrBuilder, registry::TypeRegistry)
    registry.type_lookup_global === nothing && return b
    registry.type_lookup_array_idx === nothing && return b

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

        # march17: the table's declared type + narrow to the array receiver
        global_get!(b, table_global, AnyRef)
        ref_cast!(b, Int64(arr_type_idx), true)
        i32_const!(b, Int64(type_id))
        global_get!(b, dt_global_idx, AnyRef)   # element slot IS anyref
        array_set!(b, arr_type_idx, AnyRef)
    end
    return b
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
function emit_typeof_struct_with_local!(b::InstrBuilder, base_idx::UInt32,
                                         registry::TypeRegistry, temp_local::UInt32)
    registry.type_lookup_global === nothing && return b
    registry.type_lookup_array_idx === nothing && return b
    # Extract typeId: ref.cast $JlBase + struct.get → i32
    emit_typeof!(b, base_idx)
    # Save typeId to scratch local; look it up in the type table
    local_set!(b, temp_local)
    global_get!(b, registry.type_lookup_global, AnyRef)
    local_get!(b, temp_local)
    array_get!(b, registry.type_lookup_array_idx, AnyRef)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_typeof_struct_with_local!(bytes::Vector{UInt8}, base_idx::UInt32,
                                         registry::TypeRegistry, temp_local::UInt32)
    b = InstrBuilder(; func_name="emit_typeof_struct_with_local!")
    seed_input!(b, WasmValType[AnyRef])
    emit_typeof_struct_with_local!(b, base_idx, registry, temp_local)
    append!(bytes, builder_code(b))
end

"""
Get or create an array type that holds string references.
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
    _resolve_multivariant_union(T, non_nothing, mod, registry; for_local=false) -> WasmValType

THE single resolver for a multi-variant (2+ non-Nothing) Union value's wasm type — dart2wasm
parity with `translator.dart:493 translateType` (dart has ONE such resolver, called ~14×; WT had
TWO drifting copies — get_concrete_wasm_type + julia_to_wasm_type_concrete — that the "MUST agree"
comments warned would silently null-deref on divergence). Mirrors dart's two outcomes: an UNBOXED
primitive for a same-category numeric union (dart's unboxed int/double via `boxedClasses`), else the
TOP type AnyRef (dart's `topInfo.nullableType`) — heterogeneous/incompatible-numeric values live
boxed-with-classId behind AnyRef. `for_local=true` (the SSA-local allocator) applies WT's anyref→
externref-for-locals wart on the numeric path (a WT-only anyref/externref split dart doesn't have;
preserved exactly here, retired when that hierarchy unifies). The nullable (Union{Nothing,T}) case
stays caller-side — the two callers diverge there intentionally (EqRef vs concrete inner ref).
"""
function _resolve_multivariant_union(T::Union, non_nothing, mod::WasmModule, registry::TypeRegistry; for_local::Bool=false)::WasmValType
    all_numeric = !isempty(non_nothing) && all(non_nothing) do t
        wt = julia_to_wasm_type(t)
        wt === I32 || wt === I64 || wt === F32 || wt === F64
    end
    if all_numeric
        # int/float categories don't mix without losing the tag → box behind AnyRef (dart topInfo).
        needs_anyref_boxing(T) && return AnyRef
        # same-category numeric union → widest primitive (dart: unboxed int/double).
        result = julia_to_wasm_type(T)
        for_local && result === AnyRef && registry.jl_type_idx === nothing && return ExternRef
        return result
    end
    # union of Type{T} values → the DataType struct ref (dart: a reified-type value).
    if all(t -> t isa DataType && t <: Type, non_nothing) && registry.jl_datatype_idx !== nothing
        return ConcreteRef(registry.jl_datatype_idx, true)
    end
    # WT reps Memory/MemoryRef as RAW WASM ARRAYS: isstructtype(Memory) is true in Julia,
    # but the union of array-repped variants joins to ArrayRef, never StructRef (1.13-rc1's
    # Memory-width unions — Union{Memory{UInt8},Memory{UInt16},...} — hit this).
    _is_array_repped = t -> t isa DataType && (t.name.name === :Memory || t.name.name === :GenericMemory ||
                                               t.name.name === :MemoryRef || t.name.name === :GenericMemoryRef)
    all(_is_array_repped, non_nothing) && return ArrayRef
    # all-struct union → the common struct supertype.
    is_all_struct = all(non_nothing) do t
        !_is_array_repped(t) &&
        ((isconcretetype(t) && isstructtype(t) && t !== String && t !== Symbol) || t <: Tuple)
    end
    is_all_struct && return StructRef
    # heterogeneous union → the top type (dart topInfo.nullableType); value is a classId box.
    return AnyRef
end

"""
Get a concrete Wasm type for a Julia type, using the module and registry.
This is used before CompilationContext is created.
"""

"""
    derive_nullability(T) -> Bool

tag-run item 2 (dart translator.dart:517 `type.isPotentiallyNullable`): THE nullability
derivation — a reference is nullable iff the Julia type admits `nothing`
(Union{Nothing,…} / Any / unions containing Nothing). The full non-null flip for plain-T
slots is BLOCKED by struct.new_default (non-defaultable non-null fields) + the type-safe
ref.null default emitters — recorded as the campaign's floor; this function is the
single source consumers migrate onto as those rework.
"""
derive_nullability(@nospecialize(T))::Bool =
    T === Any || T === Nothing || (T isa Union && Nothing <: T) || !(T isa DataType)

function get_concrete_wasm_type(T::Type, mod::WasmModule, registry::TypeRegistry)::WasmValType
    # Union{} (bottom type) indicates unreachable code - return void/nothing
    if T === Union{}
        throw(ArgumentError("Union{} has no runtime Wasm value type"))
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
        # parity(M9): the CLASSED string — {classId, data} <: $JlBase (dart: String IS
        # a class). Symbol shares the rep (its name string).
        type_idx = get_string_struct_type!(mod, registry)
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
    elseif T isa DataType && T.name.name === :CodeUnits && length(T.parameters) >= 1 && T.parameters[1] === UInt8
        # P6-trim: CodeUnits{UInt8,String} ≡ the byte array (identity wrapper).
        type_idx = get_string_array_type!(mod, registry)
        return ConcreteRef(type_idx, true)
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
    # P2-batch20: exclude Unions (Union{Vector{Int32},Vector{Int64}} <: AbstractArray) —
    # they must reach the Union branch below, not register as one member's wrapper
    # (gap 5ae13ccb033a).
    elseif !(T isa Union) && T <: AbstractArray  # Handles Vector, Matrix, and higher-dim arrays
        # Both Vector and Matrix are stored as structs with (ref, size) fields
        # This allows setfield!(v, :size, ...) for push!/resize! operations
        if T <: Vector
            # Julia Vector (Array{T,1}) gets (ref, size) layout.
            # P3 gap 3aaa51b9a688: `T <: Array` also caught Matrix — it got
            # the 1-D vector layout (Tuple{Int64} size field) while the
            # constructor built the real NTuple{N,Int64} dims tuple, so every
            # Matrix struct.new failed validation. Matrices route below.
            if haskey(registry.structs, T)
                info = registry.structs[T]
                return ConcreteRef(info.wasm_type_idx, true)
            else
                info = register_vector_type!(mod, registry, T)
                return ConcreteRef(info.wasm_type_idx, true)
            end
        elseif T <: AbstractVector && T isa DataType && !isconcretetype(T) && !isstructtype(T)
            # 1.13-rc1: inference widens Memory-backed values to abstract vector supertypes
            # (DenseVector{UInt8} etc.). Such an SSA can hold EITHER a Vector struct OR a raw
            # Memory array at runtime — the sound wasm join is AnyRef (both subtype it);
            # consumers narrow via the existing cast machinery. (register_struct_type! on a
            # fieldless abstract DataType THROWS "no definite number of fields".)
            return AnyRef
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
            # Union{Nothing, T} → T's concrete rep with DERIVED nullability (item 2:
            # dart's isPotentiallyNullable — true here by construction of the union)
            local _inner_w = get_concrete_wasm_type(inner_type, mod, registry)
            if _inner_w isa ConcreteRef
                return ConcreteRef(_inner_w.type_idx, derive_nullability(T))
            end
            return _inner_w
        else
            # Multi-variant union → THE single resolver (dart2wasm translateType parity).
            # Formerly a copy that "MUST agree" with julia_to_wasm_type_concrete's twin; both
            # now delegate here so they cannot drift (drift DROPped the value → ref.null →
            # null-deref at runtime, on heterogeneous-tuple / interpolation inputs).
            non_nothing_u = filter(t -> t !== Nothing, Base.uniontypes(T))
            return _resolve_multivariant_union(T, non_nothing_u, mod, registry; for_local=false)
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



# ═══ march16: THE CLOSURE LAYOUTER (dart ClosureLayouter, closures.dart:41-118) ═══

"""
    get_closure_base_struct!(mod, registry) -> UInt32

The closure-base struct: {classId:i32, context:anyref, vtable:(ref null struct)}.
dart: class_info.dart FieldIndex closureContext=2/closureVtable=3 (WT drops the
identityHash + runtimeType slots — deferred with the hash-slot and RTI campaigns).
`sub \$JlBase` so closures live in the classId world (typeof/isa discriminate).
"""
function get_closure_base_struct!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.closure_base_idx !== nothing && return registry.closure_base_idx
    fields = FieldType[
        FieldType(I32, false),       # classId
        FieldType(AnyRef, false),    # context (the captured-fields struct)
        FieldType(StructRef, false), # vtable (covariant per-arity structs; cast at use)
    ]
    base = registry.base_struct_idx
    idx = UInt32(add_type!(mod, base === nothing ? StructType(fields) : StructType(fields, base)))
    registry.closure_base_idx = idx
    return idx
end

"""
    get_closure_vtable_struct!(mod, registry, max_arity) -> UInt32

Per-max-arity vtable struct: one (ref null func) entry per positional arity
0..max_arity (dart: vtableBaseIndex + posArgCount; named combinations N/A — WT
kwargs are pre-positionalized).
"""
function get_closure_vtable_struct!(mod::WasmModule, registry::TypeRegistry, max_arity::Int)::UInt32
    d = registry.closure_vtable_struct_idxs
    d === nothing && error("closure layouter unavailable on a minimal registry")
    haskey(d, max_arity) && return d[max_arity]
    # (ref null func) entries — set once at vtable-global creation, read at call_ref
    fields = FieldType[FieldType(UInt8(FuncRef), false) for _ in 0:max_arity]
    idx = UInt32(add_type!(mod, StructType(fields)))
    d[max_arity] = idx
    return idx
end


# ═══ step5: THE CLASS-DAG (dart class_info.dart:278-330) ═══

"""
    ensure_abstract_struct!(mod, registry, A) -> UInt32

The synthetic {classId:i32} struct for an ABSTRACT Julia type, `sub` its parent's
synthetic (recursion roots at \$JlBase = Any). Parents recurse FIRST → their indices
precede the child's (the wasm ordering rule).
"""
function ensure_abstract_struct!(mod::WasmModule, registry::TypeRegistry, A::Type)
    (A === Any || !(A isa DataType)) && return registry.base_struct_idx
    d = registry.abstract_struct_idxs
    d === nothing && return registry.base_struct_idx
    haskey(d, A) && return d[A]
    parent_idx = ensure_abstract_struct!(mod, registry, supertype(A))
    idx = UInt32(add_type!(mod, StructType([FieldType(I32, false)], parent_idx)))
    d[A] = idx
    return idx
end

"""
    dag_supertype_idx!(mod, registry, T) -> UInt32

The wasm supertype for a CONCRETE type's struct: its nearest abstract parent's
synthetic (the class-DAG), falling back to \$JlBase.
"""
function dag_supertype_idx!(mod::WasmModule, registry::TypeRegistry, T::Type)::Union{UInt32, Nothing}
    registry.base_struct_idx === nothing && return nothing   # bare registries (probes)
    (T isa DataType && registry.abstract_struct_idxs !== nothing) || return registry.base_struct_idx
    local P = supertype(T)
    (P === Any || !(P isa DataType)) && return registry.base_struct_idx
    return ensure_abstract_struct!(mod, registry, P)
end
