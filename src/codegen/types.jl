# Code Generation - Julia IR to Wasm instructions
# Maps Julia SSA statements to WebAssembly bytecode

export compile_function, compile_module, FunctionRegistry

# ============================================================================
# Struct Type Registry
# ============================================================================

"""
Maps Julia struct types to their WasmGC representation.

parity(class_info.dart:199 ClassInfo): a type's struct, its fields and its inherited prefix.
"""
struct StructInfo
    julia_type::Type  # DataType or UnionAll for parametric types
    wasm_type_idx::UInt32
    field_names::Vector{Symbol}
    field_types::Vector{Type}  # Can include Union types
    # 0 = raw internal representation, 1 = Top/value prefix, 2 = Object prefix.
    field_offset::UInt32
end

"""
    wasm_field_idx(info::StructInfo, julia_field_idx::Int) -> UInt32

Convert a Julia 1-based field index to the Wasm 0-based field index,
accounting for the representation's inherited prefix.

parity(translator.dart:194 fieldIndex): a field's wasm index after the inherited prefix.
"""
wasm_field_idx(info::StructInfo, julia_field_idx::Int)::UInt32 = UInt32(julia_field_idx - 1 + info.field_offset)

# (B4/U2 — dart2wasm parity: the `UnionInfo` tagged-union descriptor + the whole
# {typeId,tag,value} wrapper scheme are DELETED. A Union value is a boxed AnyRef
# discriminated by classId — no per-union wrapper type, no tag, no descriptor.)

# The compiled module is ONE immutable closed world, so it has one world age.
# Baking the host's `get_world_counter()` made the binary depend on how many
# methods the compiling process had defined (probe diffs of +55 between two
# trees). dart has no world ages; Julia's are projected onto this single value:
# a binding visible at compile time is visible in the module.
# parity(quarantine: Julia bindings and code instances carry world-age bounds; dart has no
# world ages, so the closed module projects every bound onto one age.)
const WASM_WORLD_AGE = UInt64(1)
# parity(quarantine: a Julia world-age bound projected onto the module's one age, see WASM_WORLD_AGE.)
wasm_world_bound(host_bound::Integer, host_world::Integer, lower::Bool)::Int64 =
    lower ? (host_bound <= host_world ? Int64(WASM_WORLD_AGE) : Int64(WASM_WORLD_AGE) + 1) :
            (host_bound >= host_world ? typemax(Int64) : Int64(0))

"""
Registry for struct and array type mappings within a module.

parity(translator.dart:96 Translator): the translator's per-compile type state — classInfo
(:186), the array type caches (:231), and the constant map (constants.dart:154 constantInfo).
"""
mutable struct TypeRegistry
    structs::Union{Nothing, Dict{Type, StructInfo}}  # DataType or UnionAll for parametric types
    arrays::Union{Nothing, Dict{Type, UInt32}}  # Element type -> array type index
    string_array_idx::Union{Nothing, UInt32}  # Index of i8 array type for strings
    string_struct_idx::Union{Nothing, UInt32} # parity(class_info.dart:31 FieldIndex.stringArray): the CLASSED string {classId, data} <: $JlBase
    # (B4/U2: the `unions` tagged-union-wrapper registry is DELETED — a Union value is a boxed
    # AnyRef classId box, no {typeId,tag,value} wrapper, so no per-union registry is needed.)
    numeric_boxes::Union{Nothing, Dict{WasmValType, UInt32}}  # box types for numeric→externref returns
    # Type constant globals — each unique Type value gets a unique Wasm global
    # so that ref.eq distinguishes different Types (e.g., Int64 !== String)
    type_constant_globals::Union{Nothing, Dict{Type, UInt32}}  # Type value -> Wasm global index
    # TypeName constant globals — each unique TypeName gets a unique Wasm global
    # so that t.name === s.name identity comparison works via ref.eq
    typename_constant_globals::Union{Nothing, Dict{Core.TypeName, UInt32}}  # TypeName -> Wasm global index
    # DFS type ID assignment for runtime dispatch
    type_ids::Union{Nothing, Dict{Type, Int32}}  # Concrete type -> unique DFS integer ID
    type_ranges::Union{Nothing, Dict{Type, Tuple{Int32, Int32}}}  # Abstract/concrete type -> [low, high] DFS range
    # dart class_info.dart: Top carries classId; Object extends it with the
    # lazily-assigned mutable identity-hash slot. Primitive value boxes remain
    # direct Top descendants and therefore do not carry identity state.
    base_struct_idx::Union{Nothing, UInt32}    # $JlTop = {classId:i32}
    object_struct_idx::Union{Nothing, UInt32}  # $JlObject <: Top = {classId, identityHash}
    identity_counter_global::Union{Nothing, UInt32}
    # BoxedNothing struct type and singleton global
    nothing_box_idx::Union{Nothing, UInt32}   # Struct type: (struct (field $typeId i32))
    nothing_global_idx::Union{Nothing, UInt32}  # Singleton global holding BoxedNothing instance
    # Type lookup table — typeId (i32) → DataType struct ref
    type_lookup_array_idx::Union{Nothing, UInt32}  # Array type: (array (mut (ref null $JlDataType)))
    type_lookup_global::Union{Nothing, UInt32}  # Global holding the lookup array
    type_lookup_table_size::Int32  # Table size at creation time (guards late-arriving types)
    # $JlType hierarchy struct type indices
    jl_type_idx::Union{Nothing, UInt32}       # $JlType = (struct (field $kind i32))
    jl_datatype_idx::Union{Nothing, UInt32}   # $JlDataType (sub $JlType) — most Julia types
    jl_union_idx::Union{Nothing, UInt32}      # $JlUnion (sub $JlType) — flat union of types
    jl_unionall_idx::Union{Nothing, UInt32}   # $JlUnionAll (sub $JlType) — type constructor
    jl_typevar_idx::Union{Nothing, UInt32}    # $JlTypeVar (sub $JlType) — bound variable
    jl_typename_idx::Union{Nothing, UInt32}   # $JlTypeName — identity token
    jl_svec_idx::Union{Nothing, UInt32}       # $JlSVec = heterogeneous (array (mut anyref))
    # Exact utf8proc category/text-width table helper, shared by all Unicode calls.
    unicode_property_func_idx::Union{Nothing, UInt32}
    # The runtime egal function (`get_egal_function!`, dart's `identical` member intrinsic).
    egal_func_idx::Union{Nothing, UInt32}
    # utf8proc case-record table helper, shared by the case-mapping/predicate calls.
    unicode_case_func_idx::Union{Nothing, UInt32}
    # F3 (dev/HISTORY.md#closures-and-dynamic-dispatch): specialized Core.Box struct types, keyed by contents WASM type.
    # Distinct from numeric_boxes — the contents field is MUTABLE (written via struct.set), so a
    # Box{i64} is a different struct than the immutable {typeId,value} numeric box.
    box_types::Union{Nothing, Dict{WasmValType, UInt32}}
    # F3 L2 cross-function glue: closure type → the WASM contents type of the Core.Box it captures.
    # Populated by a pre-pass over an enclosing fn's IR (populate_box_field_types!); consulted by
    # register_closure_type! to type the captured-box field as a typed Box{contents} (else anyref).
    box_contents_types::Union{Nothing, Dict{Type, WasmValType}}
    # THE ensureConstant funnel's registry (dart constants.dart:154 constantInfo — ONE
    # constantInfo map for ALL constant kinds). Keyed by the VALUE (isequal/hash);
    # IMMUTABLE constants only — a mutable constant (Vector/Dict) has per-object
    # identity that structural keying would wrongly merge.
    constant_globals::Union{Nothing, Dict{Any, UInt32}}
    # Closed-world mutable bindings retain object identity too, but must never be
    # structurally deduplicated. IdDict keys by host identity; nullable mutable
    # storage is published once by module start, then all reads share the object.
    mutable_constant_globals::Union{Nothing, IdDict{Any, Tuple{UInt32, UInt32}}}
    module_init_functions::Union{Nothing, Vector{UInt32}}
    # census F3 (dart constants.dart:872 visitStringConstant): interned string-constant globals —
    # every use of an equal short string literal reads ONE deduplicated global
    # (code size + `===` identity like dart). Keyed by the String or Symbol value, so
    # `"a"` and `:a` are two constants of two classes.
    string_constant_globals::Union{Nothing, Dict{Union{String,Symbol}, UInt32}}
    # LAZY constants (dart constants.dart:2108 _createLazyConstant): long strings get an
    # uninitialized global + a pre-created init function; use = global.get + br_on_non_null
    # + call init. Keyed by value → (global_idx, init_fn_idx).
    lazy_string_globals::Union{Nothing, Dict{String, Tuple{UInt32, UInt32}}}
    # (dart ClosureLayouter, closures.dart:209): the closure-base struct idx
    # {classId, identityHash, context anyref, vtable, functionType}, per-max-arity vtable struct
    # idxs, and per-
    # closure-body vtable GLOBAL idxs (immutable, one per compiled closure function).
    closure_base_idx::Union{Nothing, UInt32}
    closure_vtable_struct_idxs::Union{Nothing, Dict{Int, UInt32}}      # max_arity -> vtable struct
    closure_vtable_globals::Union{Nothing, Dict{Any, UInt32}}          # closure body key -> global
    # step5 THE CLASS-DAG (dart class_info.dart:420 _createStructForClass): synthetic {classId:i32}
    # wasm structs per ABSTRACT Julia type, each sub its parent's synthetic; concrete
    # structs subtype their nearest abstract parent instead of flat $JlBase.
    abstract_struct_idxs::Union{Nothing, Dict{Type, UInt32}}
    # MemoryRef{T} -> its single-value struct {classId, identityHash, mem, off0}
    # (register_memoryref_box!, structs.jl)
    memoryref_box_idxs::Union{Nothing, Dict{Type, UInt32}}
end

# parity(translator.dart:470 Translator): the constructor that starts a compile with every
# per-compile type and constant map empty.
TypeRegistry()::TypeRegistry = TypeRegistry(
    Dict{Type, StructInfo}(), Dict{Type, UInt32}(), nothing, nothing,
    Dict{WasmValType, UInt32}(),
    Dict{Type, UInt32}(), Dict{Core.TypeName, UInt32}(),
    Dict{Type, Int32}(), Dict{Type, Tuple{Int32, Int32}}(),
    nothing, nothing, nothing, nothing, nothing, nothing, nothing, Int32(0),
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing,  # unicode_property_func_idx
    nothing,  # egal_func_idx
    nothing,  # unicode_case_func_idx
    Dict{WasmValType, UInt32}(),  # box_types (F3)
    Dict{Type, WasmValType}(),    # box_contents_types (F3 L2)
    Dict{Any, UInt32}(),          # constant_globals (ensureConstant)
    IdDict{Any, Tuple{UInt32, UInt32}}(), # mutable_constant_globals: value => (global,type)
    UInt32[],                    # module_init_functions
    Dict{Union{String,Symbol}, UInt32}(),  # string_constant_globals (census F3)
    Dict{String, Tuple{UInt32, UInt32}}(),  # lazy_string_globals
    nothing, Dict{Int, UInt32}(), Dict{Any, UInt32}(),  # closure layouter
    Dict{Type, UInt32}(),                               # step5 class-DAG synthetics
    Dict{Type, UInt32}()                                # MemoryRef single-value structs
)

# TRUE-INT-002: Dict-free constructor for WASM self-hosting.
# All Dict fields are nothing — safe for MVP Int64 arithmetic where
# no struct/array/union type registration is needed.
TypeRegistry(::Val{:minimal})::TypeRegistry = TypeRegistry(
    nothing, nothing, nothing, nothing,  # structs, arrays, string_array_idx, string_struct_idx
    nothing, nothing,            # unions, numeric_boxes
    nothing, nothing,            # type_constant_globals, typename_constant_globals
    nothing, nothing,            # type_ids, type_ranges
    nothing, nothing, nothing, nothing, nothing,
    nothing, nothing, nothing, nothing, nothing, nothing, nothing,
    nothing,  # unicode_property_func_idx
    nothing,  # egal_func_idx
    nothing,  # unicode_case_func_idx
    nothing,  # box_types (F3)
    nothing,  # box_contents_types (F3 L2)
    nothing,  # constant_globals
    nothing,  # mutable_constant_globals
    nothing,  # module_init_functions
    nothing,  # string_constant_globals (census F3)
    nothing,  # lazy_string_globals
    nothing, nothing, nothing,  # closure layouter
    nothing,                    # step5 class-DAG synthetics
    nothing                     # MemoryRef single-value structs
)

"""
    get_or_create_lazy_string!(mod, registry, s) -> (global_idx, init_fn_idx)

LAZY constants — dart's shape: an uninitialized
(ref null \$JlString) global + an init function that builds the string once, stores
it, and returns it. MUST be called BEFORE function-index assignment (the index-freeze
constraint) — the literal pre-pass in compile.jl does.

parity(constants.dart:2108 _createLazyConstant): a nullable global plus the init function
that fills it.
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
    emit_string_wrap!(b, mod, registry, 0, String)
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

— THE ensureConstant funnel (dart constants.dart:793 ensureConstant, :154: ONE constantInfo
map deduplicating EVERY constant kind). Returns the interned global for `val`, creating
it eagerly (a pure constant-expression initializer) on first use; `nothing` when `val`
is not eager-internable (mutable kinds keep per-object identity; non-constant fields
keep the inline path). IMMUTABLE kinds only.
formal(dev/formal/Constants.tla): two structurally-equal immutable constants intern to exactly one global and a mutable-kind constant never shares one; eagerness is the AND of a constant's children's, so a non-eager child always yields a fresh construction, never a partially-interned global; an unresolvable field either rejects compilation or takes its type's physical default, never a fabricated value; global numbering is a deterministic function of interning order
parity(constants.dart:793 ConstantCreator.ensureConstant): one interned global per constant value.
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
# parity(constants.dart:908 ConstantCreator.visitInstanceConstant): header fields, then each field's constant.
function _const_init_bytes!(init::Vector{UInt8}, mod::WasmModule, registry::TypeRegistry, @nospecialize(val))::Union{UInt32, Nothing}
    T = typeof(val)
    if T === Int128 || T === UInt128
        # parity(constants.dart:622-655 visitIntConstant valueTypeConstants): a boxed
        # numeric constant gets one cached module global. Int128 is a Julia primitive
        # (not isstructtype), so it cannot take the struct path below.
        type_idx = get_int128_type!(mod, registry, T)
        lo = UInt64(val & 0xFFFFFFFFFFFFFFFF)
        hi = UInt64((val >> 64) & 0xFFFFFFFFFFFFFFFF)
        push!(init, Opcode.I32_CONST)
        append!(init, encode_leb128_signed(Int64(ensure_type_id!(registry, T))))
        push!(init, Opcode.I64_CONST)
        append!(init, encode_leb128_signed(reinterpret(Int64, lo)))
        push!(init, Opcode.I64_CONST)
        append!(init, encode_leb128_signed(reinterpret(Int64, hi)))
        push!(init, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
        append!(init, encode_leb128_unsigned(UInt64(type_idx)))
        return type_idx
    end
    (isconcretetype(T) && isstructtype(T) && !ismutabletype(T)) || return nothing
    T <: Type && return nothing                       # Type constants have their own registry
    (T === String || T === Symbol) && return nothing  # the string registry owns these
    info = register_struct_type!(mod, registry, T)
    info === nothing && return nothing
    # LAYOUT GUARD (gate-caught, Statistics corpus): the registrar may skip or
    # transform fields (unions, vectors, Nothing slots) — the funnel emits ONLY
    # when the REGISTERED layout is exactly [typeId, then one slot per Julia
    # field] AND the wasm struct's field list agrees; any other shape → inline path.
    info.field_offset in (1, 2) || return nothing
    length(info.field_names) == fieldcount(T) || return nothing
    local _wst = mod.types[info.wasm_type_idx + 1]
    _wst isa StructType || return nothing
    length(_wst.fields) == fieldcount(T) + Int(info.field_offset) || return nothing
    for k in 1:fieldcount(T)
        local _fw = _wst.fields[k + Int(info.field_offset)].valtype
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
    if info.field_offset == 2
        push!(init, Opcode.I32_CONST)
        append!(init, encode_leb128_signed(Int64(0))) # unassigned identityHash
    end
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

census F3 () — INTERNED string constants, dart's constant→deduplicated-global
architecture (constants.dart:793 ensureConstant; a string constant is eager unless
standalone, :872 visitStringConstant). Every use of an equal short literal reads ONE global,
matching dart's code-size and `===`-identity semantics. A Symbol `s` is its own constant of
its own class (constants.dart:1556 visitSymbolConstant), never the equal String's. Names longer than the
eager threshold return `nothing` (they keep the inline data-segment path — dart
handles those with LAZY init functions, deferred here because init functions
cannot be added during body compilation without shifting function indices).

parity(constants.dart:872 ConstantCreator.visitStringConstant): the interned string constant.
"""
function get_string_constant_global!(mod::WasmModule, registry::TypeRegistry,
                                     s::Union{String,Symbol})::Union{UInt32, Nothing}
    registry.string_constant_globals === nothing && return nothing
    ncodeunits(String(s)) > 64 && return nothing   # eager threshold (dart lazies large constants)
    haskey(registry.string_constant_globals, s) && return registry.string_constant_globals[s]
    struct_idx, init = _string_constant_initializer!(mod, registry, s)
    g = add_global_ref!(mod, struct_idx, false, init; nullable=false)
    registry.string_constant_globals[s] = g
    return g
end

"""Build the canonical classed-string constant expression for a String or Symbol `s`, under
`typeof(s)`'s classId, without adding a global.

parity(constants.dart:872 ConstantCreator.visitStringConstant): its generator — object header,
the byte array, struct.new.
parity(constants.dart:1556 ConstantCreator.visitSymbolConstant): a Symbol's header is its own class's."""
function _string_constant_initializer!(mod::WasmModule, registry::TypeRegistry,
                                       s::Union{String,Symbol})::Tuple{UInt32,Vector{UInt8}}
    struct_idx = get_string_struct_type!(mod, registry)
    arr_idx = get_string_array_type!(mod, registry)
    # constant initializer: classId; unassigned identityHash; byte array; struct.new
    init = UInt8[]
    push!(init, Opcode.I32_CONST)
    append!(init, encode_leb128_signed(Int64(ensure_type_id!(registry, typeof(s)))))
    push!(init, Opcode.I32_CONST)
    append!(init, encode_leb128_signed(Int64(0)))
    bytes = codeunits(String(s))
    for b in bytes
        push!(init, Opcode.I32_CONST)
        append!(init, encode_leb128_signed(Int64(b)))
    end
    push!(init, Opcode.GC_PREFIX, Opcode.ARRAY_NEW_FIXED)
    append!(init, encode_leb128_unsigned(UInt64(arr_idx)))
    append!(init, encode_leb128_unsigned(UInt64(length(bytes))))
    push!(init, Opcode.GC_PREFIX, Opcode.STRUCT_NEW)
    append!(init, encode_leb128_unsigned(UInt64(struct_idx)))
    return struct_idx, init
end

"""
    emit_string_constant_ref!(b, mod, registry, s, scratch)

Push the classed String or Symbol constant `s` (under `typeof(s)`'s class) inside an
init-function body: the interned global when one exists (short names), else built in place
from a passive data segment
(`array.new_data` is not a constant expression, so long strings have no eager global;
dart initialises those lazily, constants.dart:2108 _createLazyConstant). `scratch` is the index of a local of the
string ARRAY type the caller declares only when `used[]` comes back true.

parity(constants.dart:1937 _ConstantAccessor._readDefinedConstant): global.get of an eager constant.
"""
function emit_string_constant_ref!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                                   s::Union{String,Symbol}, scratch::Integer,
                                   used::Base.RefValue{Bool})::InstrBuilder
    local g = get_string_constant_global!(mod, registry, s)
    if g !== nothing
        global_get!(b, g, ConcreteRef(get_string_struct_type!(mod, registry), false))
        return b
    end
    local arr_idx = get_string_array_type!(mod, registry)
    used[] || builder_set_local_type!(b, Int(scratch), ConcreteRef(arr_idx, true))
    used[] = true
    local bytes = Vector{UInt8}(codeunits(String(s)))
    local seg_idx = add_passive_data_segment!(mod, bytes)
    i32_const!(b, 0)
    i32_const!(b, Int64(length(bytes)))
    array_new_data!(b, arr_idx, seg_idx)
    emit_string_wrap!(b, mod, registry, scratch, typeof(s))
    return b
end

"""
    add_string_global!(mod, registry, s; mutable=true) -> UInt32

Add a global initialized with WT's canonical classed Julia `String`
representation. This is the public framework boundary for stateful string
globals; it shares the exact initializer used by interned string constants.
"""
function add_string_global!(mod::WasmModule, registry::TypeRegistry, s::String;
                            mutable::Bool=true)::UInt32
    struct_idx, init = _string_constant_initializer!(mod, registry, s)
    return add_global_ref!(mod, struct_idx, mutable, init; nullable=false)
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
# DFS Type ID Assignment
# ============================================================================

"""
    assign_type_ids!(registry::TypeRegistry)

Assign DFS-based type IDs to all registered struct types.
Walks Julia's abstract type hierarchy via DFS, assigning contiguous ID ranges
so that `isa(x, AbstractType)` becomes an O(1) range check:
  `typeId >= low && typeId <= high`.

IDs start at 1 (0 is reserved for unknown/unassigned).

parity(class_info.dart:864 ClassIdNumbering._number): one DFS numbers the closed world.
"""
function assign_type_ids!(registry::TypeRegistry; extra_concrete_types::Union{Nothing,Set{DataType}}=nothing)::Union{Nothing,Dict{Type,Tuple{Int32,Int32}}}
    # formal(dev/formal/ClassIdDispatch.tla): sorted-children DFS gives nested, sibling-disjoint ranges and a numbering that is a function of the closed world; only the lazy ensure_type_id! path makes ids history-dependent
    # Collect all concrete types from the registry that have typeId (field_offset > 0)
    concrete_types = Set{DataType}()
    for (T, info) in registered_structs(registry)
        if T isa DataType && isconcretetype(T) && info.field_offset > 0
            push!(concrete_types, T)
        end
    end
    # census F2 (): the closed world — IR-reachable types enter the numbering
    # even before (or without) struct registration; their ids/ranges are what isa
    # and the checked cast read, and lazy registration later reuses the same id.
    extra_concrete_types !== nothing && union!(concrete_types, extra_concrete_types)

    # Also include primitive numeric types that may need boxing/dispatch
    # Include Nothing for BoxedNothing typeId
    # parity(class_info.dart:864 ClassIdNumbering._number): String + Symbol are CLASSED now — they join the hierarchy so
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

        if isempty(kids) && (isconcretetype(node) || is_runtime_vararg_tuple_type(node) ||
                             (node <: Tuple && Base.isdispatchtuple(node)))
            # Leaf concrete type — is_runtime_vararg_tuple_type (structs.jl): `Tuple{Vararg{E}}`
            # is Julia-non-concrete (unbounded length) but WT gives it ONE registrable
            # {Object, data, size} representation; a Tuple carrying a `Type{X}` element
            # is `isdispatchtuple` but not `isconcretetype` (Tuple's diagonal rule) — both
            # need a real classId leaf too.
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

parity(translator.dart:186 classInfo): the nullable class lookup; 0 stands for absent.
"""
function get_type_id(registry::TypeRegistry, T::Type)::Int32
    return get(registry.type_ids, T, Int32(0))
end

"""
    memory_element_stride(T) -> Int

Julia's byte stride of a `Memory{T}` element, the unit `MemoryRef.ptr_or_offset` is
counted in: `sizeof(T)` for an isbits element, 8 for a boxed reference slot
(`Base.aligned_sizeof(Any)`). Every lowering that converts between a byte offset and an
element index uses this one rule.

parity(quarantine: Julia's MemoryRef.ptr_or_offset counts a Memory{T} element in bytes —
sizeof(T), or 8 for a boxed slot; dart arrays are indexed by element.)
"""
memory_element_stride(@nospecialize(T))::Int =
    (T isa DataType && isbitstype(T)) ? max(sizeof(T), 1) : 8

"""
    registered_structs(registry::TypeRegistry) -> Vector{Pair{Type,StructInfo}}

The ONE way to iterate the struct registry. `structs` is a `Dict` keyed by type
object, whose iteration order varies per process; every consumer that picks
"the first type at this wasm index" or assigns an id while walking it would
otherwise emit process-varying bytes (the Dict-constant nondeterminism finding).
The order is (wasm_type_idx, type name) — dart numbers classes once from the
hierarchy (class_info.dart:864) and never depends on hash order.

parity(quarantine: Julia Dict iteration follows address-based hashes of type objects, which
vary per process and architecture; dart Maps iterate in insertion order.)
"""
function registered_structs(registry::TypeRegistry)::Vector{Pair{Type,StructInfo}}
    registry.structs === nothing && return Pair{Type,StructInfo}[]
    return sort!(collect(Pair{Type,StructInfo}, registry.structs);
                 by = p -> (p.second.wasm_type_idx, string(p.first)))
end

"""
    ordered_pairs(dict, keyfn) -> Vector{Pair}

The ONE way to walk any registry dictionary whose keys hash by identity (types,
type names, function objects, constant values): sorted by a key that is a
function of the program, never of the process. Type hashes are address-based,
so a raw walk orders differently per process AND per architecture — the same
function compiled on x64 and aarch64 interned its type-name strings in a
different order. dart numbers and emits everything from the program structure
(class_info.dart:864 ClassIdNumbering._number; constants.dart's map is walked in
insertion order).

parity(quarantine: Julia Dict iteration follows address-based hashes of type, type-name,
function and constant keys, which vary per process and architecture; dart Maps iterate in
insertion order.)
"""
ordered_pairs(dict::AbstractDict, keyfn)::Vector{<:Pair} = sort!(collect(dict); by = p -> keyfn(p.first))

"""A type's program-determined order key: its printed name, then its defining module
(two modules may define a `Foo`), then the wrapper's name for UnionAll bodies.

parity(quarantine: Julia type objects hash by address, so a registry walk needs a
program-derived key; dart Maps iterate in insertion order.)"""
type_order_key(@nospecialize(T))::Tuple{String,String} =
    (string(T), T isa DataType ? string(T.name.module) : (T isa UnionAll ? string(Base.unwrap_unionall(T).name.module) : ""))

# parity(quarantine: the program-derived order key for a Core.TypeName, see type_order_key.)
typename_order_key(tn::Core.TypeName)::Tuple{String,String} = (string(tn.module), string(tn.name))

"""
    is_shared_wasm_type(registry, wasm_type_idx, T) -> Bool

Check if another Julia type in the registry shares the same WasmGC type index.
When types share an index, ref.test can't distinguish them and typeId-based
dispatch is needed. The classed string layout is always shared (String and Symbol own
it), and a struct whose layout equals it field for field gets its index from `add_type!`.
"""
function is_shared_wasm_type(registry::TypeRegistry, wasm_type_idx::UInt32, T::Type)::Bool
    registry.string_struct_idx == wasm_type_idx && return true
    for (other_type, other_info) in registered_structs(registry)
        if other_info.wasm_type_idx == wasm_type_idx && other_type !== T
            return true
        end
    end
    return false
end

"""
    ensure_type_id!(registry, T) -> Int32

Get T's DFS-assigned typeId. Phase 12B: the closed world is numbered exactly ONCE, by
`assign_type_ids!` — `_collect_reachable_ir_types` admits every concrete kind that can
carry a classId before it runs, so every `T` codegen ever asks for is already numbered.
A type reaching here unnumbered is a collector bug (a real, IR-reachable kind the
collector failed to admit), never a reason to allocate a second, order-dependent id.

parity(class_info.dart:205 ClassInfo.classId): the class id, loud when there is none.
"""
function ensure_type_id!(registry::TypeRegistry, T::Type)::Int32
    existing = get_type_id(registry, T)
    existing > 0 && return existing
    error("ensure_type_id!: $T reached codegen unnumbered — _collect_reachable_ir_types " *
          "must admit every concrete kind that can carry a classId before assign_type_ids! runs")
end

"""
    concrete_class_ids(registry, T) -> Vector{Int32}

The exact closed-world answer to `isa(x, T)` for a non-concrete `T`: the class ids of
every numbered concrete type `C` with `C <: T` — Julia's own subtyping is the ground
truth, so a parametric abstract (`AbstractVector` = `AbstractArray{T,1}`) is answered
exactly, where the DFS range keyed by the base `AbstractArray` cannot distinguish it
from a Matrix. `emit_classid_membership!` compresses a contiguous set back to dart's
range window (class_info.dart:831 getConcreteClassIdRange).

parity(class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange): the concrete ids below T.
"""
function concrete_class_ids(registry::TypeRegistry, @nospecialize(T))::Vector{Int32}
    registry.type_ids === nothing && return Int32[]
    ids = Int32[id for (C, id) in ordered_pairs(registry.type_ids, type_order_key) if C isa Type && C <: T]
    return sort!(ids)
end

"""
    get_type_range(registry::TypeRegistry, T::Type) -> Union{Tuple{Int32, Int32}, Nothing}

Return the DFS [low, high] range for an abstract type, or nothing if not assigned.

parity(class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange): one range per type.
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
    for (T, id) in ordered_pairs(registry.type_ids, type_order_key)
        ids[string(T)] = id
    end
    result["type_ids"] = ids

    ranges = Dict{String, Any}()
    for (T, (low, high)) in ordered_pairs(registry.type_ranges, type_order_key)
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
    for (T, info) in registered_structs(registry)
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
    for (T, idx) in ordered_pairs(registry.arrays, type_order_key)
        arrays[string(T)] = Int(idx)
    end
    result["arrays"] = arrays

    return result
end

"""builder-native (THE implementation): push the type's DFS id as i32.
Goes through ensure_type_id! (a pure lookup — Phase 12B: every T here was already
numbered by assign_type_ids!'s one DFS).

parity(code_generator.dart:6070 pushObjectHeaderFields): its i32.const classId."""
function emit_type_id!(b::InstrBuilder, registry::TypeRegistry, @nospecialize(T))::InstrBuilder
    i32_const!(b, Int64(ensure_type_id!(registry, T)))
    return b
end

# census F5: emit_box_type_id! is deleted. The sole classId boxer calls
# emit_type_id! with the proven concrete Julia source type.

# (B4: the i31 boxing helpers emit_box_i31! / emit_unbox_i31_s! / emit_unbox_i31_u! /
# should_use_i31 were DELETED — dart2wasm uses no i31, and B4 routed every former i31 site
# through the single-source emit_classid_box! [classId boxes]. All four were zero-caller.)

"""
    get_base_struct_type!(mod::WasmModule, registry::TypeRegistry) -> UInt32

Get or create the Top struct type `(struct (field classId i32))`.
Every class representation is a subtype of Top, enabling class-id extraction
through field 0. Object descendants additionally subtype `get_object_struct_type!`.

parity(class_info.dart:410 ClassInfoCollector._createStructForClassTop): the #Top struct.
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

parity(class_info.dart:568 objectClass): _generateFields' Object arm, identityHash after classId.
"""
function get_object_struct_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.object_struct_idx !== nothing && return registry.object_struct_idx
    top = get_base_struct_type!(mod, registry)
    fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
    idx = UInt32(add_type!(mod, StructType(fields, top)))
    registry.object_struct_idx = idx
    return idx
end

"""The inherited field prefix of every identity-bearing Julia heap object.

parity(class_info.dart:568 objectClass): Object's fields, classId then identityHash."""
object_prefix_fields()::Vector{FieldType} = FieldType[FieldType(I32, false), FieldType(I32, true)]

"""Emit the allocation prefix shared by every identity-bearing heap object.

parity(code_generator.dart:6070 pushObjectHeaderFields): classId, then the identity hash."""
function emit_object_prefix!(b::InstrBuilder, registry::TypeRegistry, @nospecialize(T))::InstrBuilder
    emit_type_id!(b, registry, T)
    i32_const!(b, 0) # identityHash is assigned lazily by `objectid`
    return b
end

"""Emit exactly the representation prefix declared by `StructInfo`.

parity(code_generator.dart:6070 pushObjectHeaderFields): the header of the struct being built."""
function emit_struct_prefix!(b::InstrBuilder, registry::TypeRegistry,
                             @nospecialize(T), info::StructInfo)::InstrBuilder
    if info.field_offset == 2
        emit_object_prefix!(b, registry, T)
    elseif info.field_offset == 1
        emit_type_id!(b, registry, T)
    elseif info.field_offset != 0
        error("unsupported struct field offset $(info.field_offset) for $T")
    end
    return b
end

"""Return the module-local monotonic source for newly assigned object identities.

parity(quarantine: Julia's objectid is the jl_object_id foreigncall, an address hash with no
wasm counterpart; this counter hands out the lazily assigned identity that dart's
_object_helper library code supplies.)"""
function get_identity_counter_global!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.identity_counter_global !== nothing && return registry.identity_counter_global
    # Zero means "unassigned" in every object slot; assigned identities begin at 1.
    idx = add_global!(mod, I32, true, Int32(0))
    registry.identity_counter_global = idx
    return idx
end

"""Extract classId field 0 from a value through the common object base.

parity(code_generator.dart:6076 loadClassId): struct.get of Top's classId field."""
function emit_typeof!(b::InstrBuilder, base_idx::UInt32)::InstrBuilder
    # ref.cast (ref $JlBase) — cast anyref/structref to base struct ref
    ref_cast!(b, Int64(base_idx), false)  # ref.cast non-null
    # struct.get $JlBase 0 — extract typeId field
    struct_get!(b, base_idx, UInt32(0), I32)
    return b
end

# Kind constants for $JlType.$kind field
const JL_TYPE_KIND_DATATYPE  = Int32(0)

"""
    create_jl_type_hierarchy!(mod::WasmModule, registry::TypeRegistry)

Create the \$JlType hierarchy of WasmGC struct types for runtime type representation.
This is separate from \$JlBase (which is for user struct typeId extraction).

Hierarchy (from §3.2.5):
  \$JlType         = (struct (field \$kind i32))
  \$JlDataType     = (sub \$JlType (struct \$kind, \$name, \$super, \$parameters, \$hash, \$abstract, \$dfs_low, \$dfs_high, \$flags))
  \$JlUnion        = (sub \$JlType (struct \$kind, \$a, \$b))
  \$JlUnionAll     = (sub \$JlType (struct \$kind, \$body, \$var))
  \$JlTypeVar      = (sub \$JlType (struct \$kind, \$name, \$lb, \$ub))
  \$JlModule       = (sub \$JlObject (struct \$classId, \$identityHash, \$name, \$parent))
  \$JlTypeName     = (sub \$JlObject (struct \$classId, \$identityHash,
                                      \$name_str, \$module, \$wrapper,
                                      \$singletonname, \$singleton_defined,
                                      \$singleton_const, \$world_bounded,
                                      \$world_min, \$world_max,
                                      \$name_deprecated, \$singleton_deprecated,
                                      \$name_visible_main, \$singleton_visible_main))
  \$JlSVec         = (array (mut anyref))

Must be called early, before type constant globals are created.
"""
function create_jl_type_hierarchy!(mod::WasmModule, registry::TypeRegistry)::Union{Nothing,StructInfo}
    registry.jl_type_idx !== nothing && return  # Already created

    # 1. $JlType base: (struct (field $kind (mut i32)))
    # Mutable so subtypes ($JlUnion, $JlUnionAll, $JlTypeVar) can set different kind values
    jl_type = StructType([FieldType(I32, true)], nothing)
    jl_type_idx = add_type!(mod, jl_type)
    registry.jl_type_idx = jl_type_idx

    # 2. Modules are interned identity-bearing Objects. A Module is not its
    # printed name: distinct modules with the same name remain distinct refs.
    str_arr_idx = get_string_array_type!(mod, registry)
    object_idx = get_object_struct_type!(mod, registry)
    string_struct_idx = get_string_struct_type!(mod, registry)
    jl_module = StructType([
        FieldType(I32, false),
        FieldType(I32, true),
        FieldType(ConcreteRef(string_struct_idx, true), true),
        FieldType(AnyRef, true),
    ], object_idx)
    jl_module_idx = add_type!(mod, jl_module)
    registry.structs[Module] = StructInfo(
        Module, jl_module_idx, [:name, :parent], Type[Symbol, Module], UInt32(2))

    # 3. $JlTypeName is an ordinary identity-bearing Object. Its Julia-visible
    # fields follow the inherited classId/identityHash prefix.
    # All fields mutable — populated by start function after struct.new_default
    jl_typename = StructType([
        FieldType(I32, false),                                  # classId
        FieldType(I32, true),                                   # identityHash
        FieldType(ConcreteRef(string_struct_idx, true), true),# name (mut Symbol ref)
        FieldType(ConcreteRef(jl_module_idx, true), true),     # module (mut interned Module ref)
        FieldType(ConcreteRef(jl_type_idx, true), true),       # wrapper (mut ref null $JlType)
        FieldType(ConcreteRef(string_struct_idx, true), true),# singletonname (mut Symbol ref)
        FieldType(I32, true),                                  # singleton is defined in module
        FieldType(I32, true),                                  # singleton binding is const
        FieldType(I32, true),                                  # name binding has a bounded valid world range
        FieldType(I64, true),                                  # bounded world range minimum
        FieldType(I64, true),                                  # bounded world range maximum
        FieldType(I32, true),                                  # module/name binding is deprecated
        FieldType(I32, true),                                  # module/singletonname binding is deprecated
        FieldType(I32, true),                                  # module/name binding visible from Main
        FieldType(I32, true),                                  # module/singletonname binding visible from Main
    ], object_idx)
    jl_typename_idx = add_type!(mod, jl_typename)
    registry.jl_typename_idx = jl_typename_idx

    # 3. Core.SimpleVector is heterogeneous in Julia. Type parameter lists are
    # one use, not its representation contract; numeric and other boxed values
    # must coexist with $JlType references without a downcast.
    jl_svec = ArrayType(FieldType(AnyRef, true))
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
        FieldType(I32, true),                                    # Julia DataType flags (UInt16 widened to i32)
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

    # Register Julia type system types as StructInfo entries
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

    # DataType: runtime fields plus Julia's flags metadata used by Base display.
    registry.structs[DataType] = StructInfo(
        DataType, jl_datatype_idx,
        [:name, :super, :parameters, :hash, :abstract, :dfs_low, :dfs_high, :flags],
        Type[Core.TypeName, DataType, Core.SimpleVector, Int32, Int32, Int32, Int32, UInt16],
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

    # Core.TypeName: Object prefix followed by Symbol name, Module, wrapper,
    # singletonname. Keep the StructInfo order identical to the physical suffix.
    registry.structs[Core.TypeName] = StructInfo(
        Core.TypeName, jl_typename_idx,
        [:name, :module, :wrapper, :singletonname, :singleton_defined, :singleton_const,
         :world_bounded, :world_min, :world_max, :name_deprecated,
         :singleton_deprecated, :name_visible_main, :singleton_visible_main],
        Type[Symbol, Module, Any, Symbol, Bool, Bool, Bool, Int64, Int64, Bool, Bool,
             Bool, Bool],
        UInt32(2)
    )
end

# parity(quarantine: a Julia Module is a first-class runtime value — parentmodule, nameof,
# TypeName.module — where a Dart library is never a value.)
function get_module_constant_global!(mod::WasmModule, registry::TypeRegistry,
                                     module_value::Module)::UInt32
    haskey(registry.constant_globals, module_value) &&
        return registry.constant_globals[module_value]
    info = registry.structs[Module]
    string_idx = get_string_struct_type!(mod, registry)
    name_global = get_string_constant_global!(mod, registry, nameof(module_value))
    name_global === nothing && error("Module name exceeds the eager Symbol constant limit")
    b = InstrBuilder(; func_name="get_module_constant_global!")
    i32_const!(b, Int64(ensure_type_id!(registry, Module)))
    i32_const!(b, 0)
    global_get!(b, name_global, ConcreteRef(string_idx, false))
    ref_null!(b, AnyRef)
    struct_new!(b, info.wasm_type_idx,
                WasmValType[I32, I32, ConcreteRef(string_idx, false), AnyRef])
    global_idx = add_global_ref!(mod, info.wasm_type_idx, false, builder_code(b);
                                 nullable=false)
    registry.constant_globals[module_value] = global_idx
    parent = parentmodule(module_value)
    parent === module_value || get_module_constant_global!(mod, registry, parent)
    return global_idx
end

# ============================================================================
# Function Registry - for multi-function modules
# ============================================================================

"""
Information about a compiled function within a module.

parity(functions.dart:25 FunctionCollector._functions): the compiled function a callee maps to.
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
FunctionInfo(name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type)::FunctionInfo =
    FunctionInfo(name, func_ref, arg_types, wasm_idx, return_type, false)

"""Finish the canonical source-vararg tuple projection (a runtime ABI value, not a constant).

parity(quarantine: Julia passes a vararg tail, f(xs...), as a tuple built at the call; dart
calls have a fixed arity.)"""
packed_source_tuple_new!(builder::InstrBuilder, type_idx::Integer)::InstrBuilder =
    struct_new!(builder, type_idx)

"""
Registry for functions within a module, enabling cross-function calls.

parity(functions.dart:25 FunctionCollector._functions / translator.dart:196
staticParamInfo): `by_ref` is the dart-shaped core — callee identity (a Julia
function object, standing in for dart's `Reference`) keyed to its compiled
`FunctionInfo` (dart's `w.BaseFunction` + param ABI). `functions` (name-keyed)
exists only to serve `serialize_function_table` and the Julia-only fallback
`get_function_by_export_name` below — never the identity-keyed lookup path.
"""
mutable struct FunctionRegistry
    functions::Vector{Tuple{String, FunctionInfo}}       # name -> info (linear scan)
    by_ref::Vector{Tuple{Any, Vector{FunctionInfo}}}     # func_ref -> infos (linear scan)
end

# parity(functions.dart:25 FunctionCollector._functions): the collector starts with an empty
# callee-to-function map.
FunctionRegistry()::FunctionRegistry = FunctionRegistry(Tuple{String, FunctionInfo}[], Tuple{Any, Vector{FunctionInfo}}[])

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

parity(functions.dart:90 FunctionCollector.getFunction): the callee's entry in _functions.
"""
function register_function!(registry::FunctionRegistry, name::String, func_ref, arg_types::Tuple, wasm_idx::UInt32, return_type::Type=Any; is_candidate::Bool=false)::FunctionInfo
    # campaign diagnostics: WT_LOG_REGISTRY=1 logs every registration (name,
    # arg types, index) — for hunting call-site/callee signature divergence
    OPTIONS[].log_registry &&
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
Look up a function by name — the sole caller has already lost the func_ref
(a GlobalRef from an anonymous/re-exported module whose `getfield` failed) and
a name string is all that remains to key on.

No dart counterpart and no Julia necessity: dart resolves every callee by `Reference`
identity (functions.dart:25 `FunctionCollector._functions`), and the one case this serves —
`isdefined(func.mod, func.name)` false — is where native Julia throws UndefVarError, so the
name fallback answers a question Julia answers with an error. An invention (dev/CHARTER.md
C2): it stays counted by R32 until it is deleted.
"""
function get_function_by_export_name(registry::FunctionRegistry, name::String)::Union{FunctionInfo, Nothing}
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

parity(functions.dart:25 FunctionCollector._functions / translator.dart:196
staticParamInfo): the func_ref-keyed core — resolves a callee's identity to
its compiled ABI, same shape as dart's `Reference` → `w.BaseFunction` map.
The subtype/reverse-subtype passes below are Julia's dynamic-dispatch
overload resolution filling in for dart's static single-target reference.
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

    # Try reverse subtype match (registered <: actual).
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
Resolve a dispatch-only candidate only when the call site's recovered Julia
types prove the candidate's complete signature exactly. This is the late
devirtualization counterpart to `get_function`: candidates remain invisible
to ordinary/fuzzy cross-call lookup and to abstract sites.

parity(translator.dart:1954 singleTarget): the devirtualized direct target.
"""
function get_exact_candidate(registry::FunctionRegistry, func_ref, arg_types::Tuple;
                             expected_return::Union{Nothing,Type}=nothing)::Union{FunctionInfo,Nothing}
    all(_closed_world_exact_type, arg_types) || return nothing
    infos = get_func_ref_infos(registry, func_ref)
    infos === nothing && return nothing
    _ret_ok(info) = expected_return === nothing || expected_return === Any ||
                    info.return_type === Any ||
                    info.return_type <: expected_return || expected_return <: info.return_type
    for info in infos
        info.is_candidate && info.arg_types == arg_types && _ret_ok(info) && return info
    end
    return nothing
end

"""
Check if a function reference is registered (for by_ref linear scan).

parity(functions.dart:25 FunctionCollector._functions): membership by callee identity.
"""
function has_func_ref(registry::FunctionRegistry, func_ref)::Bool
    for (ref, _) in registry.by_ref
        ref === func_ref && return true
    end
    return false
end

"""
Get infos for a function reference (for by_ref linear scan). Returns nothing if not found.

parity(functions.dart:25 FunctionCollector._functions): lookup by callee identity.
"""
function get_func_ref_infos(registry::FunctionRegistry, func_ref)::Union{Vector{FunctionInfo}, Nothing}
    for (ref, v) in registry.by_ref
        ref === func_ref && return v
    end
    return nothing
end

"""
Get or create an array type for a given element type.

parity(quarantine: Julia's Int8/UInt8/Int16/UInt16 element types have no dart value type;
their arrays use wasm packed i8/i16 storage, which dart reaches only through WasmI8/WasmI16,
translator.dart:344 builtinTypes.)
"""
@inline packed_array_storage(@nospecialize(T))::Union{Nothing,UInt8} =
    T === Int8 || T === UInt8 ? UInt8(0x78) :
    T === Int16 || T === UInt16 ? UInt8(0x77) : nothing

# parity(quarantine: the Julia signedness of a packed i8/i16 element load, see packed_array_storage.)
@inline packed_array_signedness(@nospecialize(T))::Union{Nothing,Bool} =
    T === Int8 || T === Int16 ? true :
    T === UInt8 || T === UInt16 ? false : nothing

# parity(translator.dart:1205 arrayTypeForDartType): one cached array type per element type.
function get_array_type!(mod::WasmModule, registry::TypeRegistry, elem_type::Type)::UInt32
    if haskey(registry.arrays, elem_type)
        return registry.arrays[elem_type]
    end

    # (gap 56af911c52b2): Vector{Union{}} — `map` with an
    # always-throwing closure infers eltype Union{}. Such an array can only
    # ever be EMPTY (Union{} has no values), so the element representation is
    # arbitrary; use Int64 so the JS boundary and accessors have a concrete
    # layout instead of trapping with a type-incompatibility.
    if elem_type === Union{}
        type_idx = get_array_type!(mod, registry, Int64)
        registry.arrays[elem_type] = type_idx
        return type_idx
    end

    # Wasm GC's packed storage is the canonical representation for Julia's 8- and
    # 16-bit integer arrays. UInt8 shares the exact i8 array type with String so
    # array.copy remains type-correct. Loads select get_s/get_u from Julia signedness.
    local packed = packed_array_storage(elem_type)
    if elem_type === UInt8
        type_idx = get_string_array_type!(mod, registry)
        registry.arrays[elem_type] = type_idx
        return type_idx
    elseif packed !== nothing
        type_idx = add_array_type!(mod, packed, true)
        registry.arrays[elem_type] = type_idx
        return type_idx
    end

    # The element's storage type: a self-referential element type being registered right now
    # contributes its reserved recursion-group index; every other element type is the one
    # translator's answer.
    local wasm_elem_type = if haskey(_registering_types, elem_type) && _registering_types[elem_type] >= 0
        ConcreteRef(UInt32(_registering_types[elem_type]), true)
    else
        get_concrete_wasm_type(elem_type, mod, registry)
    end
    type_idx = add_array_type!(mod, wasm_elem_type, true)  # mutable arrays
    registry.arrays[elem_type] = type_idx
    return type_idx
end

"""
Get or create the string array type (array of packed i8 for UTF-8 bytes).
Mutable to support array.copy for string concatenation.

parity(translator.dart:1218 wasmArrayType): the cached mutable i8 array type.
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

parity(class_info.dart:31 FieldIndex.stringArray): the CLASSED string — dart: String IS an Object class. A Julia String value is
`(struct (field i32 classId) (field (mut i32) identityHash) (field (ref null \$strbytes) data))`,
SUBTYPE of \$JlObject,
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

# utf8proc's per-codepoint answers in utf8proc's own two-stage shape: `stage1[cp >> 8]`
# names a deduplicated 256-codepoint block and `stage2[block][cp & 0xff]` a record in a
# deduplicated record table. Both stages are one UInt8 table, stage1 (0x1100 entries)
# first. `record(cp)` is read for every codepoint through the same ccalls Base makes; a
# codepoint past U+10FFFF reads record(0x110000), utf8proc's own answer there.
# parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
function _utf8proc_two_stage_tables(record::Function)::NamedTuple
    order = Vector{Vector{Int32}}()
    records = Dict{Vector{Int32},Int}()
    index!(rec) = get!(records, rec) do
        push!(order, rec)
        length(order) - 1
    end
    blocks = Dict{Vector{UInt8},Int}()
    stage1 = UInt8[]
    stage2 = UInt8[]
    block = Vector{UInt8}(undef, 256)
    for hi in UInt32(0):UInt32(0x10ff)
        for lo in UInt32(0):UInt32(0xff)
            block[lo + 1] = UInt8(index!(record((hi << 8) | lo)))   # InexactError past 256 records
        end
        k = get!(blocks, copy(block)) do
            append!(stage2, block)
            length(blocks)
        end
        push!(stage1, UInt8(k))
    end
    oob = index!(record(UInt32(0x110000)))
    width = length(order[1])
    words = Int32[x for rec in order for x in rec]
    return (stages = vcat(stage1, stage2), records = collect(reinterpret(UInt8, htol.(words))),
            nwords = length(words), width = width, oob = oob)
end

# Per codepoint: utf8proc_category (bits 0-4), utf8proc_charwidth (bits 5-6), and Julia's
# identifier-start/continuation predicates (bits 7-8), packed in one word.
# parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
const _UTF8PROC_PROPERTY_DATA = _utf8proc_two_stage_tables() do cp
    category = ccall(:utf8proc_category, Cint, (UInt32,), cp)
    width = ccall(:utf8proc_charwidth, Cint, (UInt32,), cp)
    id_start = ccall(:jl_id_start_char, Cint, (UInt32,), cp)
    id_char = ccall(:jl_id_char, Cint, (UInt32,), cp)
    (0 <= category <= 31 && 0 <= width <= 3) ||
        error("utf8proc property outside packed table range at U+$(string(cp; base=16))")
    Int32[category | (width << 5) | (id_start << 7) | (id_char << 8)]
end

# Per codepoint, as Base reaches them through the `utf8proc_toupper`/`_tolower`/`_totitle`/
# `_isupper`/`_islower` foreigncalls: [upper - cp, lower - cp, title - cp, isupper, islower].
# parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
const _UTF8PROC_CASE_DATA = _utf8proc_two_stage_tables() do cp
    Int32[ccall(:utf8proc_toupper, Int32, (UInt32,), cp) - Int32(cp),
          ccall(:utf8proc_tolower, Int32, (UInt32,), cp) - Int32(cp),
          ccall(:utf8proc_totitle, Int32, (UInt32,), cp) - Int32(cp),
          ccall(:utf8proc_isupper, Cint, (UInt32,), cp),
          ccall(:utf8proc_islower, Cint, (UInt32,), cp)]
end

"""
    _two_stage_lookup_func!(mod, registry, tables, name) → UInt32

A helper `(i32 cp, i32 field) -> i32` returning field `field` of `cp`'s record in
`tables` (see `_utf8proc_two_stage_tables`), over two lazy module-global arrays built
from passive data segments on first use.
parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
"""
function _two_stage_lookup_func!(mod::WasmModule, registry::TypeRegistry, tables, name::String)::UInt32
    stage_idx = get_array_type!(mod, registry, UInt8)
    rec_idx = get_array_type!(mod, registry, Int32)
    stage_ref = ConcreteRef(stage_idx, true)
    rec_ref = ConcreteRef(rec_idx, true)
    stage_seg = add_passive_data_segment!(mod, tables.stages)
    rec_seg = add_passive_data_segment!(mod, tables.records)
    stage_global = add_global_ref!(mod, stage_idx, true,
        vcat(UInt8[Opcode.REF_NULL], encode_leb128_signed(Int64(stage_idx))))
    rec_global = add_global_ref!(mod, rec_idx, true,
        vcat(UInt8[Opcode.REF_NULL], encode_leb128_signed(Int64(rec_idx))))
    stage_block = add_type!(mod, FuncType(WasmValType[], WasmValType[stage_ref]))
    rec_block = add_type!(mod, FuncType(WasmValType[], WasmValType[rec_ref]))
    # locals: 0 cp, 1 field, 2 the stage table, 3 the record index
    b = InstrBuilder(WasmValType[I32, I32, stage_ref, I32], WasmValType[I32]; func_name=name)
    i32_const!(b, tables.oob); local_set!(b, 3)
    local_get!(b, 0); i32_const!(b, 0x110000); num!(b, Opcode.I32_LT_U)
    if_!(b)
    initialized = block!(b, Int(stage_block); results=WasmValType[stage_ref])
    global_get!(b, stage_global, stage_ref)
    br_on_non_null!(b, initialized)
    i32_const!(b, 0); i32_const!(b, length(tables.stages))
    array_new_data!(b, stage_idx, stage_seg)
    global_set!(b, stage_global)
    global_get!(b, stage_global, stage_ref)
    end_block!(b)
    local_set!(b, 2)
    # record index = stage[0x1100 + (stage[cp >> 8] << 8) + (cp & 0xff)]
    local_get!(b, 2)
    i32_const!(b, 0x1100)
    local_get!(b, 2)
    local_get!(b, 0); i32_const!(b, 8); num!(b, Opcode.I32_SHR_U)
    array_get!(b, stage_idx, I32; signed=false)
    i32_const!(b, 8); num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_ADD)
    local_get!(b, 0); i32_const!(b, 0xff); num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_ADD)
    array_get!(b, stage_idx, I32; signed=false)
    local_set!(b, 3)
    end_block!(b)
    initialized = block!(b, Int(rec_block); results=WasmValType[rec_ref])
    global_get!(b, rec_global, rec_ref)
    br_on_non_null!(b, initialized)
    i32_const!(b, 0); i32_const!(b, tables.nwords)
    array_new_data!(b, rec_idx, rec_seg)
    global_set!(b, rec_global)
    global_get!(b, rec_global, rec_ref)
    end_block!(b)
    local_get!(b, 3); i32_const!(b, tables.width); num!(b, Opcode.I32_MUL)
    local_get!(b, 1); num!(b, Opcode.I32_ADD)
    array_get!(b, rec_idx, I32)
    return_!(b)
    end_block!(b)
    return add_function!(mod, WasmValType[I32, I32], WasmValType[I32],
                         WasmValType[stage_ref, I32], builder_code(b))
end

"""
    get_or_create_unicode_property_func!(mod, registry) → UInt32

The module's `(i32 cp, i32 0) -> i32` lookup of `_UTF8PROC_PROPERTY_DATA`: bits 0–4
`utf8proc_category`, bits 5–6 `utf8proc_charwidth`, bits 7–8 Julia's identifier
start/continuation predicates.
parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
"""
function get_or_create_unicode_property_func!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.unicode_property_func_idx === nothing &&
        (registry.unicode_property_func_idx =
            _two_stage_lookup_func!(mod, registry, _UTF8PROC_PROPERTY_DATA, "unicode_property"))
    return registry.unicode_property_func_idx
end

"""
    get_or_create_unicode_case_func!(mod, registry) → UInt32

The module's `(i32 cp, i32 field) -> i32` lookup of `_UTF8PROC_CASE_DATA`: field 0 upper
delta, 1 lower delta, 2 title delta, 3 isupper, 4 islower.
parity(quarantine: Julia's Char classes and case mapping are libutf8proc/libjulia foreigncalls; the tables are their own answers, read at precompile — target Wasm performs no FFI)
"""
function get_or_create_unicode_case_func!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.unicode_case_func_idx === nothing &&
        (registry.unicode_case_func_idx =
            _two_stage_lookup_func!(mod, registry, _UTF8PROC_CASE_DATA, "unicode_case"))
    return registry.unicode_case_func_idx
end

"""
Get or create a box struct type for a numeric Wasm type.
Used when a function returning ExternRef needs to return a numeric value.
The box struct has a single field of the numeric type, allowing the value
to be wrapped as a GC reference and converted to externref.

parity(translator.dart:374 boxedClasses): one box class per value type.
"""
function get_numeric_box_type!(mod::WasmModule, registry::TypeRegistry, wasm_type::WasmValType)::UInt32
    if haskey(registry.numeric_boxes, wasm_type)
        return registry.numeric_boxes[wasm_type]
    end
    # Prepend typeId:i32 as field 0 (universal object layout)
    fields = [FieldType(I32, false), FieldType(wasm_type, false)]  # typeId + value
    # Declare `sub $JlBase` AT CREATION (dart class_info.dart:420 _createStructForClass — every class
    # struct subtypes its super at definition). This lets the strict builder use
    # the subtype relation DURING emission (a box-typed
    # ref validates where a $JlBase ref is expected — the typed-channel prerequisite).
    base = registry.base_struct_idx
    type_idx = base === nothing ? add_struct_type!(mod, fields) :
               add_type!(mod, StructType(fields, base))
    registry.numeric_boxes[wasm_type] = type_idx
    return type_idx
end

"""
    get_box_type!(mod, registry, contents_wasm_type) -> UInt32

F3 (dev/HISTORY.md#closures-and-dynamic-dispatch): get/create the specialized `Core.Box` struct for a box whose contents have
concrete wasm type `contents_wasm_type` — `(struct (field \$typeId i32) (field \$contents (mut T)))`.
The contents field is MUTABLE (a captured variable is written via `struct.set`), so a `Box{i64}` is
a DIFFERENT struct than the immutable `{typeId,value}` numeric box. Cached in `registry.box_types`
so the enclosing fn's `%new`, the closure's captured-box field, and setfield!/getfield all share ONE
type. dart2wasm-aligned (a typed context-struct field, not a boxed `Any`).

The live capture analysis and Core.Box registration share this constructor.

parity(quarantine: Julia lowering allocates an explicit Core.Box cell for each captured
variable that is reassigned; dart keeps such a variable in its context struct,
closures.dart:1533.)
"""
function get_box_type!(mod::WasmModule, registry::TypeRegistry, contents_wasm_type::WasmValType)::UInt32
    if registry.box_types !== nothing && haskey(registry.box_types, contents_wasm_type)
        return registry.box_types[contents_wasm_type]
    end
    # typeId (i32, immutable) + contents (T, MUTABLE)
    fields = [FieldType(I32, false), FieldType(contents_wasm_type, true)]
    base = get_base_struct_type!(mod, registry)
    type_idx = UInt32(add_type!(mod, StructType(fields, base)))
    registry.box_types === nothing || (registry.box_types[contents_wasm_type] = type_idx)
    return type_idx
end

"""
Get or create the BoxedNothing struct type.
BoxedNothing has only typeId:i32 (no value field) — a singleton type.
"""
function get_nothing_box_type!(mod::WasmModule, registry::TypeRegistry)::UInt32
    if registry.nothing_box_idx !== nothing
        return registry.nothing_box_idx
    end
    # BoxedNothing: just typeId field (no value)
    fields = [FieldType(I32, false)]
    base = get_base_struct_type!(mod, registry)
    type_idx = UInt32(add_type!(mod, StructType(fields, base)))
    registry.nothing_box_idx = type_idx
    return type_idx
end

"""
Get or create a singleton global holding the BoxedNothing instance.
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
Get or create a Wasm global for a Type constant value.

Each unique Julia Type (e.g., Int64, String, Number) gets a unique Wasm global
holding a struct instance. This ensures that `ref.eq` correctly
distinguishes different Type objects at runtime.

Globals use the one \$JlDataType representation established by
`create_jl_type_hierarchy!` before closed-world type collection.
"""
function get_type_constant_global!(mod::WasmModule, registry::TypeRegistry, @nospecialize(type_val::Type))::UInt32
    # Return cached global if this Type was already seen
    if haskey(registry.type_constant_globals, type_val)
        return registry.type_constant_globals[type_val]
    end

    dt_type_idx = registry.jl_datatype_idx
    dt_type_idx === nothing && error("type constants require the canonical JlType hierarchy")

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

    # Recursively ensure globals exist for the entire type hierarchy.
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

parity(quarantine: Core.TypeName is a Julia reflection object compared by identity
(t.name === s.name) whose fields Base reads; dart has no TypeName.)
"""
function get_typename_constant_global!(mod::WasmModule, registry::TypeRegistry, tn::Core.TypeName)::UInt32
    if haskey(registry.typename_constant_globals, tn)
        return registry.typename_constant_globals[tn]
    end

    tn_type_idx = registry.jl_typename_idx
    tn_type_idx === nothing && error("TypeName constants require the canonical JlType hierarchy")

    # Immutable classId must be established at allocation; mutable payload fields
    # begin null and are populated by the start function.
    b = InstrBuilder(; func_name="get_typename_constant_global!")
    str_arr_idx = get_string_array_type!(mod, registry)
    string_idx = get_string_struct_type!(mod, registry)
    jl_type_idx = registry.jl_type_idx
    i32_const!(b, Int64(ensure_type_id!(registry, Core.TypeName)))
    i32_const!(b, 0)
    module_idx = registry.structs[Module].wasm_type_idx
    ref_null!(b, Int64(string_idx), ConcreteRef(string_idx, true))
    ref_null!(b, Int64(module_idx), ConcreteRef(module_idx, true))
    ref_null!(b, Int64(jl_type_idx), ConcreteRef(jl_type_idx, true))
    ref_null!(b, Int64(string_idx), ConcreteRef(string_idx, true))
    i32_const!(b, 0)
    i32_const!(b, 0)
    i32_const!(b, 0)
    i64_const!(b, 0)
    i64_const!(b, 0)
    i32_const!(b, 0)
    i32_const!(b, 0)
    i32_const!(b, 0)
    i32_const!(b, 0)
    struct_new!(b, tn_type_idx,
                WasmValType[I32, I32, ConcreteRef(string_idx, true),
                            ConcreteRef(module_idx, true), ConcreteRef(jl_type_idx, true),
                            ConcreteRef(string_idx, true), I32, I32, I32, I64, I64,
                            I32, I32, I32, I32])
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

When \$JlType hierarchy is available, populates \$JlDataType fields:
  kind=0, name→\$JlTypeName, super→\$JlType, parameters→\$JlSVec, hash, abstract, dfs_low, dfs_high
And \$JlTypeName fields: interned name Symbol, Module identity, wrapper, and binding metadata

"""
function populate_type_constant_globals!(mod::WasmModule, registry::TypeRegistry)::Union{Nothing,WasmModule}
    # TRUE-INT-002: Guard for Dict-free TypeRegistry (minimal constructor)
    (registry.type_constant_globals === nothing || isempty(registry.type_constant_globals)) && return

    registry.jl_datatype_idx === nothing &&
        error("type constant population requires the canonical JlType hierarchy")
    _populate_jl_hierarchy!(mod, registry)
end

"""
Compose every generated closed-world initializer behind the module's single start
entry. Mutable constant globals contain only nullable storage before this runs;
their initializer functions construct exact object snapshots and publish them.

parity(pkg/wasm_builder/lib/src/builder/module.dart:79 ModuleBuilder.startFunction): the one
start function every eager initializer is appended to (globals.dart:183).
"""
function finalize_module_initializers!(mod::WasmModule, registry::TypeRegistry)::Nothing
    funcs = registry.module_init_functions
    (funcs === nothing || isempty(funcs)) && return
    previous_start = mod.start_function
    b = InstrBuilder(; func_name="module_start", mod=mod)
    previous_start === nothing || call!(b, previous_start, WasmValType[], WasmValType[])
    for func_idx in funcs
        call!(b, func_idx, WasmValType[], WasmValType[])
    end
    end_block!(b)
    func_idx = add_function!(mod, WasmValType[], WasmValType[], WasmValType[], builder_code(b))
    add_start_function!(mod, func_idx)
    return
end

"""
Populate \$JlDataType and \$JlTypeName fields using the JlType hierarchy.
"""
function _populate_jl_hierarchy!(mod::WasmModule, registry::TypeRegistry)::Union{Nothing,WasmModule}
    dt_type_idx = registry.jl_datatype_idx
    tn_type_idx = registry.jl_typename_idx
    svec_idx = registry.jl_svec_idx
    jl_type_idx = registry.jl_type_idx
    str_arr_idx = get_string_array_type!(mod, registry)

    # global_get! declares the global's TRUE valtype (the AnyRef lie made
    # this the #1 harvest offender — 96k tracked-type mismatches feeding struct_set!).
    b = InstrBuilder(; func_name="_populate_jl_hierarchy!", mod=mod)
    # local 0: the string-array scratch for Symbol constants built in place (declared
    # only when a name exceeds the eager-interning threshold)
    local _pop_str_scratch = 0
    local _pop_str_used = Ref(false)

    # Close Module ancestry before iterating the constant registry, then wire
    # exact parent identities. Root modules point to themselves.
    for (tn, _) in ordered_pairs(registry.typename_constant_globals, typename_order_key)
        tn.module !== nothing && get_module_constant_global!(mod, registry, tn.module)
    end
    for (value, module_global) in ordered_pairs(registry.constant_globals, v -> v isa Module ? string(v) : "")
        value isa Module || continue
        parent_global = get_module_constant_global!(mod, registry, parentmodule(value))
        module_idx = registry.structs[Module].wasm_type_idx
        global_get!(b, module_global, ConcreteRef(module_idx, false))
        global_get!(b, parent_global, ConcreteRef(module_idx, false))
        struct_set!(b, module_idx, UInt32(3), AnyRef)
    end

    for (type_val, dt_global_idx) in ordered_pairs(registry.type_constant_globals, type_order_key)
        type_val isa DataType || continue

        # Field 0: kind = TYPE_DATATYPE (0)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
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
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
            begin
            local _gvt = mod.globals[Int(tn_global_idx) + 1].valtype
            global_get!(b, tn_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
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
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
                begin
            local _gvt = mod.globals[Int(parent_global_idx) + 1].valtype
            global_get!(b, parent_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
                struct_set!(b, dt_type_idx, UInt32(2), ConcreteRef(jl_type_idx, true))  # field 2 = super
            end
        else
            # Any.super === Any (self-referential)
            begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
            begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
            struct_set!(b, dt_type_idx, UInt32(2), ConcreteRef(jl_type_idx, true))  # field 2 = super
        end

        # Field 3: parameters → $JlSVec (array of ref null $JlType)
        params = type_val.parameters
        nparams = length(params)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
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
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
                    # $JlDataType is sub $JlType, so ref is already compatible
                else
                    # Unknown parameter type → null ref
                    ref_null!(b, Int64(jl_type_idx), ConcreteRef(UInt32(jl_type_idx), true))
                end
            end
            array_new_fixed!(b, svec_idx, UInt32(nparams), AnyRef)
        end
        struct_set!(b, dt_type_idx, UInt32(3), ConcreteRef(svec_idx, true))  # field 3 = parameters

        # Field 4: hash → i32. Julia's DataType.hash is the host's objectid — a
        # function of the host build (it differed between x64 and aarch64 for
        # every type), not of the program; the module's value is the hash of the
        # type's program identity (memhash is platform-independent).
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(Int32(hash(type_order_key(type_val)) & 0x7FFFFFFF)))
        struct_set!(b, dt_type_idx, UInt32(4), I32)  # field 4 = hash

        # Field 5: abstract → i32 (1 if abstract, 0 if concrete)
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
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
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(dfs_low))
        struct_set!(b, dt_type_idx, UInt32(6), I32)  # field 6 = dfs_low

        # Field 7: dfs_high
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)   # anyref-stored type globals narrow at use
        end
        i32_const!(b, Int64(dfs_high))
        struct_set!(b, dt_type_idx, UInt32(7), I32)  # field 7 = dfs_high

        # Field 8: Julia DataType flags (the runtime stores UInt16; Wasm i32).
        begin
            local _gvt = mod.globals[Int(dt_global_idx) + 1].valtype
            global_get!(b, dt_global_idx, _gvt)
            _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)
        end
        i32_const!(b, Int64(getfield(type_val, :flags)))
        struct_set!(b, dt_type_idx, UInt32(8), I32)
    end

    # Populate $JlTypeName fields
    for (tn, tn_global_idx) in ordered_pairs(registry.typename_constant_globals, typename_order_key)
        # Fields 2 and 5 are interned Symbol objects, carrying their exact
        # content-derived metadata across ordinary calls.
        string_idx = get_string_struct_type!(mod, registry)
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        emit_string_constant_ref!(b, mod, registry, tn.name, _pop_str_scratch, _pop_str_used)
        struct_set!(b, tn_type_idx, UInt32(2), ConcreteRef(string_idx, true))

        # Field 3: an interned Module object, never a name-string surrogate.
        if tn.module !== nothing
            module_global = get_module_constant_global!(mod, registry, tn.module)
            module_idx = registry.structs[Module].wasm_type_idx
            global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
            global_get!(b, module_global, ConcreteRef(module_idx, false))
            struct_set!(b, tn_type_idx, UInt32(3), ConcreteRef(module_idx, true))
        end

        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        emit_string_constant_ref!(b, mod, registry, tn.singletonname, _pop_str_scratch, _pop_str_used)
        struct_set!(b, tn_type_idx, UInt32(5), ConcreteRef(string_idx, true))

        # Field 6: whether module.singletonname is a real binding.
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        singleton_defined = tn.module !== nothing &&
                            isdefined(tn.module, tn.singletonname)
        i32_const!(b, singleton_defined ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(6), I32)

        # Field 7: constness of that singleton binding.
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        singleton_const = singleton_defined && isconst(tn.module, tn.singletonname)
        i32_const!(b, singleton_const ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(7), I32)

        # Fields 8–10: the exact answer to Base.check_world_bounded. Julia
        # derives it by walking mutable BindingPartition history; WT captures
        # the result once at its immutable closed-world collection boundary.
        world_bounds = Base.check_world_bounded(tn)
        host_world = Base.get_world_counter()
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        i32_const!(b, world_bounds === nothing ? 0 : 1)
        struct_set!(b, tn_type_idx, UInt32(8), I32)
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        i64_const!(b, world_bounds === nothing ? 0 : wasm_world_bound(first(world_bounds), host_world, true))
        struct_set!(b, tn_type_idx, UInt32(9), I64)
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        i64_const!(b, world_bounds === nothing ? 0 : wasm_world_bound(last(world_bounds), host_world, false))
        struct_set!(b, tn_type_idx, UInt32(10), I64)

        # Fields 11–12: exact deprecation state for either symbol that
        # show_type_name may select. These are immutable module-binding facts in
        # the collected world, not a synthesized answer at the call site.
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        i32_const!(b, (tn.module !== nothing && Base.isdeprecated(tn.module, tn.name)) ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(11), I32)
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        singleton_deprecated = tn.module !== nothing && tn.singletonname !== nothing &&
                               Base.isdeprecated(tn.module, tn.singletonname)
        i32_const!(b, singleton_deprecated ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(12), I32)

        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        name_visible_main = tn.module !== nothing && Base.isvisible(tn.name, tn.module, Main)
        i32_const!(b, name_visible_main ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(13), I32)
        global_get!(b, tn_global_idx, ConcreteRef(tn_type_idx, true))
        singleton_visible_main = tn.module !== nothing && tn.singletonname !== nothing &&
                                 Base.isvisible(tn.singletonname, tn.module, Main)
        i32_const!(b, singleton_visible_main ? 1 : 0)
        struct_set!(b, tn_type_idx, UInt32(14), I32)


        # Field 2: wrapper → $JlType ref
        wrapper = tn.wrapper
        if wrapper isa DataType && haskey(registry.type_constant_globals, wrapper)
            wrapper_global_idx = registry.type_constant_globals[wrapper]
            begin
                local _gvt = mod.globals[Int(tn_global_idx) + 1].valtype
                global_get!(b, tn_global_idx, _gvt)
                _gvt === AnyRef && ref_cast!(b, Int64(tn_type_idx), true)   # the RECEIVER is a TypeName
            end
            begin
                local _gvt = mod.globals[Int(wrapper_global_idx) + 1].valtype
                global_get!(b, wrapper_global_idx, _gvt)
                _gvt === AnyRef && ref_cast!(b, Int64(dt_type_idx), true)
            end
            struct_set!(b, tn_type_idx, UInt32(4), ConcreteRef(jl_type_idx, true))
        end
    end

    # Populate the type lookup table (typeId → DataType struct ref)
    populate_type_lookup_table!(b, registry)

    isempty(builder_code(b)) && return

    end_block!(b)  # function-terminating END
    body = builder_code(b)
    func_idx = add_function!(mod, WasmValType[], WasmValType[],
                             _pop_str_used[] ? WasmValType[ConcreteRef(get_string_array_type!(mod, registry), true)] : WasmValType[],
                             body)
    add_start_function!(mod, func_idx)
end

# ============================================================================
# Full $JlType Hierarchy — Type Lookup Table
# ============================================================================

"""
    ensure_all_type_globals!(mod::WasmModule, registry::TypeRegistry)

Create DataType globals for ALL types that have DFS type IDs.
This ensures every type (concrete and abstract) has a materialized \$JlDataType
struct that can be returned by typeof(x).

Must be called AFTER assign_type_ids!.
"""
function ensure_all_type_globals!(mod::WasmModule, registry::TypeRegistry)::Nothing
    # Collect all types that need globals: those with DFS IDs or DFS ranges
    all_typed = Set{Type}()
    for T in keys(registry.type_ids)
        push!(all_typed, T)
    end
    for T in keys(registry.type_ranges)
        push!(all_typed, T)
    end

    # Create DataType globals for each (get_type_constant_global! is idempotent),
    # in program order — this is where the type-name strings get interned.
    for T in sort!(collect(all_typed); by = type_order_key)
        T isa DataType || continue
        get_type_constant_global!(mod, registry, T)
    end
end

"""
    create_type_lookup_table!(mod::WasmModule, registry::TypeRegistry)

Create a WasmGC array that maps typeId (i32 index) → DataType struct ref.
This enables typeof(x) to return a \$JlDataType struct by looking up the typeId.

Must be called AFTER ensure_all_type_globals!.

parity(quarantine: Julia's `===` on DataTypes is identity, so typeof(x) must return the one
canonical type object for x's classId; dart compares _Type values structurally.)
"""
function create_type_lookup_table!(mod::WasmModule, registry::TypeRegistry)::Union{Nothing,Int32}
    isempty(registry.type_constant_globals) && return

    dt_type_idx = registry.jl_datatype_idx
    dt_type_idx === nothing && error("type lookup table requires the canonical JlType hierarchy")

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
    registry.type_lookup_table_size = table_size  # record for OOB guard
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

parity(quarantine: the canonical typeof table, see create_type_lookup_table!.)
"""
function populate_type_lookup_table!(b::InstrBuilder, registry::TypeRegistry)::InstrBuilder
    registry.type_lookup_global === nothing && return b
    registry.type_lookup_array_idx === nothing && return b

    table_global = registry.type_lookup_global
    arr_type_idx = registry.type_lookup_array_idx

    # Compute table size (must match create_type_lookup_table! sizing).
    # Types registered after create_type_lookup_table! (via ensure_type_id! during body
    # compilation) may have IDs exceeding the table size — skip those to avoid OOB.
    table_size = registry.type_lookup_table_size

    # For each concrete type with a DFS ID and a DataType global, populate the table
    for (T, type_id) in ordered_pairs(registry.type_ids, type_order_key)
        T isa DataType || continue
        haskey(registry.type_constant_globals, T) || continue
        type_id >= table_size && continue  # Skip late-arriving types that exceed table bounds
        dt_global_idx = registry.type_constant_globals[T]

        # The table's declared type + narrow to the array receiver
        global_get!(b, table_global, AnyRef)
        ref_cast!(b, Int64(arr_type_idx), true)
        i32_const!(b, Int64(type_id))
        global_get!(b, dt_global_idx, AnyRef)   # element slot IS anyref
        array_set!(b, arr_type_idx, AnyRef)
    end
    return b
end

"""Resolve a value's classId through the module's canonical type-object table.

parity(quarantine: the canonical typeof table, see create_type_lookup_table!.)"""
function emit_typeof_struct_with_local!(b::InstrBuilder, base_idx::UInt32,
                                         registry::TypeRegistry, temp_local::UInt32)::InstrBuilder
    registry.type_lookup_global === nothing && error("Type lookup table global is unavailable")
    registry.type_lookup_array_idx === nothing && error("Type lookup table array is unavailable")
    # Extract typeId: ref.cast $JlBase + struct.get → i32
    emit_typeof!(b, base_idx)
    # Save typeId to scratch local; look it up in the type table
    local_set!(b, temp_local)
    global_get!(b, registry.type_lookup_global, AnyRef)
    local_get!(b, temp_local)
    array_get!(b, registry.type_lookup_array_idx, AnyRef)
    return b
end

"""
    _resolve_multivariant_union(T, non_nothing, mod, registry; for_local=false) -> WasmValType

THE single resolver for a multi-variant (2+ non-Nothing) Union value's wasm type — dart2wasm
parity with `translator.dart:1044 translateType` (dart has ONE such resolver, called ~14×; WT once
had two drifting copies of the whole type-translation chain — one taking `(mod, registry)`, one
taking a compilation `ctx` — that the "MUST agree" comments warned would silently null-deref on
divergence; both are now this one `for_local`-gated function, P4-types fold). Mirrors dart's two
outcomes: an UNBOXED primitive for a same-category numeric union (dart's unboxed int/double via
`boxedClasses`), else the TOP type AnyRef (dart's `topInfo.nullableType`) — heterogeneous/
incompatible-numeric values live boxed-with-classId behind AnyRef. `for_local=true` (the SSA-local
allocator) applies WT's anyref→externref-for-locals wart on the numeric path (a WT-only
anyref/externref split dart doesn't have; preserved exactly here, retired when that hierarchy
unifies). The nullable (Union{Nothing,T}) case stays caller-side — the two `for_local` branches of
the caller diverge there intentionally (EqRef vs concrete inner ref).

parity(quarantine: a Julia Union{A,B,…} of unrelated types has no dart counterpart — a Dart
static type is one class or its nullable form — so a multi-variant Union's wasm type is
chosen here.)
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
Takes a Julia type `T`, the target `mod`, its `registry`, and a `for_local` keyword
(default `false`); returns the `WasmValType` that represents `T`.

THE single Julia-type → Wasm-type translator (dart2wasm parity: `translateType`
translator.dart:1044 → `translateStorageType(type, {unbox})` :1067 — dart has ONE such
translator, gated by one `unbox` flag; WT had TWO drifting ~200-line copies, this one and
a former `ctx`-taking twin (`julia_to_wasm_type` plus `_concrete` — deleted; every call
site now calls this function directly with `for_local` set true). `for_local`
mirrors dart's `unbox`: `true` is the SSA-local/phi/PhiC/slot allocator (a value about to
occupy a WT-allocated local that has no OTHER fixed representation yet); `false` is every
signature/field/return position where the value already has a fixed representation
established elsewhere (a function parameter's declared type, a struct field's wasm type).
`T` is intentionally unannotated (not typed as a `Type`): `Vararg{T,N}` markers are
`Core.TypeofVararg` instances, which are not subtypes of `Type`, so a `Type`-constrained
signature would MethodError on them before the Vararg case below ever runs.
"""

"""
    derive_nullability(T) -> Bool

tag-run item 2 (dart translator.dart:1068 `type.isPotentiallyNullable`): THE nullability
derivation — a reference is nullable iff the Julia type admits `nothing`
(Union{Nothing,…} / Any / unions containing Nothing). The full non-null flip for plain-T
slots is BLOCKED by struct.new_default (non-defaultable non-null fields) + the type-safe
ref.null default emitters — recorded as the campaign's floor; this function is the
single source consumers migrate onto as those rework.

parity(translator.dart:1068 isPotentiallyNullable): the nullability of a translated type.
"""
derive_nullability(@nospecialize(T))::Bool =
    T === Any || T === Nothing || (T isa Union && Nothing <: T) || !(T isa DataType)

"""
    translate_external_type(T, mod, registry) -> WasmValType

The host-boundary type translator: what a Julia type may become on the parameter or
result of an import/export function signature. `parity(translator.dart:1239
translateExternalType, :1273 translateExternalStorageType)`: dart restricts the
interop boundary to wasm func/extern/array refs, its low-level `WasmArray<T>`
intrinsic, and non-nullable primitive builtins — everything else (ordinary boxed
objects included) widens to the `anyref` top type, so Binaryen's `--closed-world`
mode never has to reason about an internal recursive-group struct ref crossing the
boundary. WT has no Julia-level marker types for most of dart's `dart:_wasm`
intrinsic classes (`WasmFuncRef`/`WasmArrayRef`/`WasmArray<T>` are never spelled as
a Julia parameter type) — the one exception is `JSValue` (`julia_to_wasm_type`'s own
"JS values are held as externref" case), WT's existing Julia-level marker for an
opaque host reference, mirroring dart's `cls == wasmExternRefClass` arm; `AnyRef` is
WT's `anyref`. This is total — it never throws. dart's only throw in this family
(`translateExternalStorageType`'s "Wasm numeric types can't be nullable") fires for
a nullable low-level wasm marker type, which likewise has no Julia-side analogue to
reach it.
"""
function translate_external_type(T, mod::WasmModule, registry::TypeRegistry)::WasmValType
    T === JSValue && return ExternRef
    if !derive_nullability(T) &&
       (T === Bool || T === Char ||
        T === Int8 || T === UInt8 || T === Int16 || T === UInt16 ||
        T === Int32 || T === UInt32 || T === Int64 || T === UInt64 || T === Int ||
        T === Float32 || T === Float64)
        return julia_to_wasm_type(T)
    end
    return AnyRef
end

# parity(translator.dart:1067 translateStorageType): the one Julia-type to wasm-type translator.
function get_concrete_wasm_type(T, mod::WasmModule, registry::TypeRegistry; for_local::Bool=false)::WasmValType
    # Vararg is a type modifier (Core.TypeofVararg), not a proper Julia type — never `<: Type`.
    # Use ExternRef for locals to avoid externref↔anyref mismatches (Any→ExternRef, and
    # cross-calls return ExternRef, so locals holding a vararg tail must be ExternRef too).
    if T isa Core.TypeofVararg
        return ExternRef
    end
    # Union{} (bottom type / TypeofBottom): no runtime value exists of this type. In a
    # signature/field position (for_local=false) that is a genuine bug — throw. The
    # SSA-local allocator (for_local=true) can legitimately type an unreachable dead
    # phi/local edge Union{}; I32 is a harmless placeholder no live value ever occupies.
    if T === Union{}
        for_local && return I32
        throw(ArgumentError("Union{} has no runtime Wasm value type"))
    end
    # Type{X} singleton values (e.g., Type{Int64}) are represented as DataType
    # struct refs via global.get. Only match SINGLETON types (not struct types like Union/DataType).
    # Exclude Union types (e.g., Union{Type{Int64}, Type{Number}}) — these are
    # multi-variant unions that map to AnyRef (via julia_to_wasm_type), not single DataType refs.
    if T <: Type && !(T isa UnionAll) && !(T isa Union) && !isstructtype(T)
        # Use $JlDataType when hierarchy is available
        dt_idx = get_datatype_type_idx(registry)
        return ConcreteRef(dt_idx, true)
    end
    if T === String || T === Symbol
        # parity(class_info.dart:31 FieldIndex.stringArray): the CLASSED string — {classId, data} <: $JlBase (dart: String IS
        # a class). Symbol shares the rep (its name string).
        type_idx = get_string_struct_type!(mod, registry)
        return ConcreteRef(type_idx, true)
    elseif !for_local && is_closure_type(T)
        # Closure types are structs with captured variables. NOT a deliberate asymmetry —
        # a DISCOVERED pre-existing gap between the two former chains, preserved here rather
        # than fixed (out of scope for a byte-identical fold; probe_bytes' string_uppercase
        # caught the attempt to ungate this). The former ctx-taking twin (the for_local=true /
        # SSA-local-phi-slot chain) never checked is_closure_type at all — an
        # unregistered closure reaching the local allocator fell to the `is_struct_type` arm
        # below and got `register_struct_type!`'s generic layout instead of
        # `register_closure_type!`'s Object/vtable-prefixed one. In practice this is FIRST
        # reached in the for_local=false chain (function parameter/return-type registration,
        # compile.jl's arg_types loop) before any closure-typed local is ever allocated, so
        # the gap is believed latent, not live — but that belief is unverified here. Flag for
        # a follow-up: either prove it unreachable for_local=true, or route it through
        # register_closure_type! there too (a real behavior change, not a fold).
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
        # UnionAll tuples (e.g., Tuple{T, T} where T<:Type) lack .parameters — registration
        # would throw. Skip registration and fall through to the abstract StructRef. Gated
        # by for_local: this case came from the ctx (SSA-local) chain only — the
        # mod/registry chain never had it, and ungating changed a pre-existing signature/
        # field-position caller's result for `string_uppercase` (probe_bytes caught it).
        if for_local && T isa UnionAll
            return StructRef
        end
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
    elseif T isa DataType && T.name.name === :CodeUnits && length(T.parameters) >= 2 &&
           T.parameters[1] === UInt8 && T.parameters[2] === String
        # P6-trim: CodeUnits{UInt8,String} ≡ the byte array (identity wrapper).
        type_idx = get_string_array_type!(mod, registry)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :MemoryRef || T.name.name === :GenericMemoryRef)
        # MemoryRef{T} / GenericMemoryRef maps to array type for element T
        # IMPORTANT: Check BEFORE AbstractArray since MemoryRef <: AbstractArray
        elem_type = T.name.name === :GenericMemoryRef ? T.parameters[2] : T.parameters[1]
        type_idx = get_array_type!(mod, registry, elem_type)
        return ConcreteRef(type_idx, true)
    elseif for_local && T isa UnionAll && T <: Base.GenericMemoryRef
        # Bare MemoryRef or constrained MemoryRef{T} where T<:X (UnionAll) — happens when
        # cross-function calls use Vector (no eltype). Extract the element type from the
        # type variable bound when available, else fall back to Any. Gated by for_local:
        # this case came from the ctx (SSA-local) chain only — see the Tuple/UnionAll note
        # above for why ungating it changed a signature/field-position result.
        local memref_elem_type = Any
        if T.var isa TypeVar && T.var.ub !== Any
            memref_elem_type = T.var.ub
        end
        type_idx = get_array_type!(mod, registry, memref_elem_type)
        return ConcreteRef(type_idx, true)
    elseif T isa DataType && (T.name.name === :Memory || T.name.name === :GenericMemory)
        # Memory{T} / GenericMemory maps to array type for element T
        # IMPORTANT: Check BEFORE AbstractArray since Memory <: AbstractArray
        elem_type = T.parameters[2]  # Element type is second parameter for GenericMemory
        type_idx = get_array_type!(mod, registry, elem_type)
        return ConcreteRef(type_idx, true)
    # Exclude Unions (Union{Vector{Int32},Vector{Int64}} <: AbstractArray) —
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
            # Matrix and higher-dim arrays: register as struct — CONCRETE ones. An
            # abstract or UnionAll array type (AbstractVector, AbstractArray,
            # AbstractMatrix{Float64}, …) has no struct of its own; it is the join,
            # anyref (dart's top type for an unresolved class), narrowed at use by
            # the cast machinery. (AbstractVector once reached the matrix registrar
            # here — ndims of the UnionAll is 1 — and every Pi typed by it ref.cast to
            # a bogus struct: `xs[1]::AbstractVector` trapped "illegal cast".)
            (T isa DataType && isconcretetype(T)) || return AnyRef
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
            local _inner_w = get_concrete_wasm_type(inner_type, mod, registry; for_local=for_local)
            if _inner_w isa ConcreteRef
                # Union{Nothing, T} where T is a struct/array ref type.
                # for_local=true (the SSA-local/phi/PhiC/slot allocator): use EqRef (not T's
                # concrete ref) because the Nothing path may produce struct_new of the base
                # tagged struct or ref.null, which is NOT a subtype of ConcreteRef(T). EqRef
                # is the common supertype of all struct/array refs; downstream narrowing casts
                # to the concrete type on read. for_local=false (field/signature position):
                # the value already has a fixed nullable-concrete representation there, so
                # return the derived-nullability ConcreteRef directly.
                for_local && return EqRef
                return ConcreteRef(_inner_w.type_idx, derive_nullability(T))
            end
            if _inner_w === I32 || _inner_w === I64 || _inner_w === F32 || _inner_w === F64
                # parity(translator.dart:1141 translateStorageType): a nullable builtin is its
                # box class, nullable (`int?` = (ref null $BoxedInt)) — `nothing` is the null
                # ref, a value is the classId box; in every position (field, local, element).
                return ConcreteRef(get_numeric_box_type!(mod, registry, _inner_w), true)
            end
            return _inner_w
        else
            # Multi-variant union → THE single resolver (dart2wasm translateType parity).
            # Formerly a copy that "MUST agree" with the former ctx-taking twin's own version;
            # both for_local branches now delegate here so they cannot drift (drift DROPped the
            # value → ref.null → null-deref at runtime, on heterogeneous-tuple / interpolation
            # inputs). `for_local` keeps WT's anyref→externref-for-locals wart on the numeric
            # path when set.
            non_nothing_u = filter(t -> t !== Nothing, Base.uniontypes(T))
            return _resolve_multivariant_union(T, non_nothing_u, mod, registry; for_local=for_local)
        end
    elseif T === Core.SimpleVector
        # Core.SimpleVector maps to $JlSVec array type when JlType hierarchy is active.
        # This ensures field access on DataType.parameters returns the correct type.
        if registry.jl_svec_idx !== nothing
            return ConcreteRef(registry.jl_svec_idx, true)
        end
        return ArrayRef
    elseif T === Core.TypeName
        # Core.TypeName maps to $JlTypeName struct type when hierarchy is active.
        if registry.jl_typename_idx !== nothing
            return ConcreteRef(registry.jl_typename_idx, true)
        end
        return StructRef
    else
        # Standard (non-struct/array) conversion.
        result = julia_to_wasm_type(T)
        # Never return AnyRef for locals — use ExternRef instead. Exception — when the
        # $JlType hierarchy is active, keep AnyRef for Any-typed locals: $JlType struct
        # fields return (ref null $JlType), a subtype of anyref but NOT externref, so
        # locals must align with function params. Signature/field positions (for_local=
        # false) return the raw AnyRef unconditionally, as before this function existed.
        if for_local && result === AnyRef && registry.jl_type_idx === nothing
            return ExternRef
        end
        return result
    end
end



# ═══ THE CLOSURE LAYOUTER (dart ClosureLayouter, closures.dart:209) ═══

"""
    get_closure_base_struct!(mod, registry) -> UInt32

The closure-base Object prefix and callable payload:
`{classId:i32, identityHash:(mut i32), context:anyref, vtable:structref,
  functionType:(ref JlDataType)}`.
This copies current dart ClosureLayouter's Object fields and context/vtable order
including its final runtime function-type field.

parity(closures.dart:365 ClosureLayouter.closureBaseStruct): the #ClosureBase struct.
"""
function get_closure_base_struct!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.closure_base_idx !== nothing && return registry.closure_base_idx
    fields = FieldType[
        FieldType(I32, false),       # classId
        FieldType(I32, true),        # identityHash
        FieldType(AnyRef, false),    # context (the captured-fields struct)
        FieldType(StructRef, false), # vtable (covariant per-arity structs; cast at use)
        FieldType(ConcreteRef(get_datatype_type_idx(registry), false), false), # callable RTI
    ]
    object = get_object_struct_type!(mod, registry)
    idx = UInt32(add_type!(mod, StructType(fields, object)))
    registry.closure_base_idx = idx
    return idx
end

"""
    get_closure_vtable_struct!(mod, registry, max_arity) -> UInt32

Per-max-arity vtable struct: one (ref null func) entry per positional arity
0..max_arity (dart: vtableBaseIndex + posArgCount; named combinations N/A — WT
kwargs are pre-positionalized). The structs form a subtype CHAIN by arity —
vt(n) <: vt(n-1) <: … <: vt(0) — exactly dart's `parentVtableStruct` (closures.dart:
573-578): a vtable built for a type's largest arity is then a subtype of the struct a
dynamic call of any smaller arity casts to, so one vtable serves every arity the
type is called with.

parity(closures.dart:573 parentVtableStruct): each arity's vtable subtypes the previous one.
"""
function get_closure_vtable_struct!(mod::WasmModule, registry::TypeRegistry, max_arity::Int)::UInt32
    d = registry.closure_vtable_struct_idxs
    d === nothing && error("closure layouter unavailable on a minimal registry")
    haskey(d, max_arity) && return d[max_arity]
    max_arity >= 0 || error("closure vtable arity must be non-negative, got $max_arity")
    parent = max_arity == 0 ? nothing : get_closure_vtable_struct!(mod, registry, max_arity - 1)
    # (ref null func) entries — set once at vtable-global creation, read at call_ref
    fields = FieldType[FieldType(UInt8(FuncRef), false) for _ in 0:max_arity]
    idx = UInt32(add_type!(mod, StructType(fields, parent)))
    d[max_arity] = idx
    return idx
end


# ═══ step5: THE CLASS-DAG (dart class_info.dart:420 _createStructForClass) ═══

"""
    ensure_abstract_struct!(mod, registry, A) -> UInt32

The synthetic {classId:i32} struct for an ABSTRACT Julia type, `sub` its parent's
synthetic (recursion roots at \$JlBase = Any). Parents recurse FIRST → their indices
precede the child's (the wasm ordering rule).

parity(class_info.dart:420 _createStructForClass): supertypes first, then the class's struct.
"""
function ensure_abstract_struct!(mod::WasmModule, registry::TypeRegistry, A::Type)::Union{Nothing,UInt32}
    (A === Any || !(A isa DataType)) && return registry.base_struct_idx
    d = registry.abstract_struct_idxs
    d === nothing && return registry.base_struct_idx
    haskey(d, A) && return d[A]
    # Value classes (Julia's Number branch) intentionally remain directly below
    # Top: their second field is their payload, not Object.identityHash. All other
    # abstract class nodes inherit Object's complete field prefix, exactly as
    # dart2wasm copies superclass fields into every class representation.
    local value_branch = A <: Number
    parent_idx = if value_branch
        ensure_abstract_struct!(mod, registry, supertype(A))
    else
        local P = supertype(A)
        P === Any ? get_object_struct_type!(mod, registry) : ensure_abstract_struct!(mod, registry, P)
    end
    fields = value_branch ? FieldType[FieldType(I32, false)] : object_prefix_fields()
    idx = UInt32(add_type!(mod, StructType(fields, parent_idx)))
    d[A] = idx
    return idx
end

"""
    dag_supertype_idx!(mod, registry, T) -> UInt32

The wasm supertype for a CONCRETE type's struct: its nearest abstract parent's
synthetic (the class-DAG), falling back to \$JlBase.

parity(class_info.dart:451 superInfo): bool/num sit under Top, every other class under its super.
"""
function dag_supertype_idx!(mod::WasmModule, registry::TypeRegistry, T::Type)::Union{UInt32, Nothing}
    registry.base_struct_idx === nothing && return nothing   # bare registries (probes)
    (T isa DataType && registry.abstract_struct_idxs !== nothing) || return registry.base_struct_idx
    local P = supertype(T)
    # Primitive/value boxes are Top descendants. Ordinary Julia structs are
    # identity-bearing Object descendants even when Julia reports `Any` as their
    # immediate supertype.
    (P === Any || !(P isa DataType)) && return (T <: Number ? registry.base_struct_idx : get_object_struct_type!(mod, registry))
    return ensure_abstract_struct!(mod, registry, P)
end
