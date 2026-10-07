"""
    is_struct_type(T) -> Bool

Whether `T` is laid out as a struct of its own fields: every concrete struct type is,
whatever it subtypes — a Diagonal, a UnitRange, a SubArray, a Complex, a Dual — as every dart
class is a struct of its fields. The exceptions are the types with a dedicated
representation (`has_dedicated_representation`). Until 2026-09-29 every `AbstractArray` and
`Number` subtype was excluded by name and a few re-admitted by name (SparseMatrixCSC, Dual,
and an extension-filled set), so a Diagonal took the Matrix layout `[:ref, :size]` and
`D.diag` was not lowerable, and a Complex was an erased structref in locals.

parity(class_info.dart:539 _generateFields): a class's struct is its fields.
"""
function is_struct_type(@nospecialize(T))::Bool
    T isa DataType || return false
    (isconcretetype(T) && isstructtype(T)) || return false
    return !has_dedicated_representation(T)
end

"""
    has_dedicated_representation(T::DataType) -> Bool

The concrete struct types WT does not lay out by their fields: a Tuple (register_tuple_type!),
an Array (the Vector and Matrix wrappers, register_vector_type! / register_matrix_type!), a
Memory and a MemoryRef (a raw wasm array, and its single-value ref struct), `nothing` (the
null of its type), and `CodeUnits{UInt8,String}` (the String's byte array itself).

parity(quarantine: Julia's Array, Memory and MemoryRef are structs over runtime-managed
storage, and CodeUnits of a String is that String's bytes; dart's List and typed-data classes
are dart classes whose storage its runtime supplies.)
"""
function has_dedicated_representation(T::DataType)::Bool
    return T <: Tuple || T <: Array || T <: Core.GenericMemory || T <: Core.GenericMemoryRef ||
           T === Nothing ||
           is_string_codeunits(T)
end

"""
    register_array_wrapper!(mod, registry, A::DataType) -> StructInfo

The wrapper struct of a concrete Array type: the Vector layout (register_vector_type!) for a
one-dimensional Array, the Matrix layout (register_matrix_type!, an N-tuple of sizes) for any
other. Every route that meets an Array — a value, a signature, a struct, tuple or closure
field — registers it here, so its layout does not depend on which route met it first: a
struct's Matrix field once registered the Matrix with the Vector layout, and a later
`%new(Matrix{Float64}, ref, (2, 2))` pushed a size tuple the field did not hold.

parity(quarantine: Julia's Array is a struct over runtime-managed storage whose size tuple's
length is its rank; dart's List is one-dimensional.)
"""
function register_array_wrapper!(mod::WasmModule, registry::TypeRegistry, A::DataType)::StructInfo
    (A <: Array && isconcretetype(A)) || error("register_array_wrapper!: $A is not a concrete Array type")
    return A <: Vector ? register_vector_type!(mod, registry, A) : register_matrix_type!(mod, registry, A)
end

"""
Check if type is a closure (subtype of Function with captured fields).

parity(quarantine: a Julia closure is an ordinary concrete struct subtyping Function whose
fields are its captures; Kernel closures are FunctionExpression nodes, never classes.)
"""
function is_closure_type(T::Type)::Bool
    # Union{} is bottom type - not a closure
    T === Union{} && return false
    # Must be a subtype of Function
    !(T <: Function) && return false
    # Must be a concrete struct type (fieldcount throws for abstract types)
    isconcretetype(T) && isstructtype(T) || return false
    # Must have fields (captured variables)
    fieldcount(T) == 0 && return false
    return true
end

# parity(quarantine: Julia type slots in IR also hold TypeVar and Vararg objects, which are
# never a closure struct; see is_closure_type(::Type).)
is_closure_type(::Any)::Bool = false

"""
Register a closure type as a WasmGC struct.
formal(dev/formal/ClosureLayout.tla): a closure's context struct lists its captured fields in exactly the program's declared order (never hash-dependent), two distinct closure types never share a struct or vtable-global id, one vtable struct is shared per arity, and the vt_struct annotation used to read a closure's vtable global always matches the shape that global was actually created with
parity(closures.dart:1533 _buildContexts): the context struct of a closure's captured variables.
"""
function register_closure_type!(mod::WasmModule, registry::TypeRegistry, T::DataType)::StructInfo
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Get field information
    field_names = [fieldname(T, i) for i in 1:fieldcount(T)]
    field_types = [fieldtype(T, i) for i in 1:fieldcount(T)]

    # Create WasmGC field types (same logic as register_struct_type)
    # Prepend typeId:i32 as field 0 (universal object layout)
    wasm_fields = FieldType[FieldType(I32, false)]  # typeId, immutable
    for ft in field_types
        if ft <: Array && ft isa DataType && isconcretetype(ft)
            # an Array is its Vector or Matrix wrapper struct
            vec_info = register_array_wrapper!(mod, registry, ft)
            wasm_vt = ConcreteRef(vec_info.wasm_type_idx, true)
        elseif ft <: Vector
            vec_info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(vec_info.wasm_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # a MemoryRef field holds the ref's single-value struct (mem, off0)
            wasm_vt = memoryref_field_type!(mod, registry, ft)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)
        elseif ft === String || ft === Symbol
            str_type_idx = get_string_struct_type!(mod, registry)
            wasm_vt = ConcreteRef(str_type_idx, true)
        else
            wasm_vt = julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, false))  # immutable for closures
    end

    # This is the captured-fields CONTEXT, not the user-visible closure object.
    # Dart contexts are internal structs and do not participate in the Object /
    # Function class hierarchy; the separately allocated closure object does.
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping (field_offset=1 for typeId prefix)
    info = StructInfo(T, type_idx, field_names, field_types, UInt32(1))
    registry.structs[T] = info

    return info
end

# ── Task-local per-compile state ─────────────────────────────────────────────
# The string/IO/RNG lazy caches below are PER-COMPILE state: each compile task gets its own
# copy, so concurrent compiles (the test suite spawns one task per Phase) can't corrupt each
# other. Struct registration keeps its state on the TypeRegistry (PendingTypes).
# parity(quarantine: a process-wide side channel for one compilation's host-import state (dev/MARCH.md 13.7 makes it per-compilation); dart2wasm keeps such state on its Translator.)
mutable struct TaskLocalRef{T}; key::Symbol; default::T; end
# parity(quarantine: a process-wide side channel for one compilation's host-import state (dev/MARCH.md 13.7 makes it per-compilation); dart2wasm keeps such state on its Translator.)
Base.getindex(r::TaskLocalRef{T}) where {T} = get(task_local_storage(), r.key, r.default)::T
# parity(quarantine: a process-wide side channel for one compilation's host-import state (dev/MARCH.md 13.7 makes it per-compilation); dart2wasm keeps such state on its Translator.)
Base.setindex!(r::TaskLocalRef, v) = (task_local_storage()[r.key] = v)

"""
    begin_pending!(registry, field, key) -> id

Start registering `key` (a Julia type) whose registry entry lives in `registry.<field>`: push a
pending id the entry holds while the fields translate, so a field that reaches `key` again
refers to the pending type instead of registering it twice. Unbounded descent through ever-new
parametric types stops at depth 120, naming the chain.
parity(quarantine: see PendingTypes)
"""
function begin_pending!(registry::TypeRegistry, field::Symbol, @nospecialize(key::Type))::UInt32
    local p = registry.pending
    if length(p.stack) >= 120
        local tail = join((string(p.keys[i]) for i in p.stack[end-7:end]), " → ")
        throw(WasmCompileError(WasmDiagnostic(:unsupported_type, string(key),
            "struct type registration exceeded depth 120 (type-descent, last: … → $(tail) → $(key))",
            nothing, nothing)))
    end
    local id = p.next
    p.next += UInt32(1)
    push!(p.stack, id)
    p.keys[id] = key
    p.low[id] = id
    p.slots[id] = Tuple{Symbol, Type}[(field, key)]
    return id
end

"""
    pending_alias!(registry, idx, field, key) -> Nothing

`registry.<field>[key]` holds `idx` too: if `idx` is still pending, it takes the real index
with it.
parity(quarantine: see PendingTypes)
"""
function pending_alias!(registry::TypeRegistry, idx::UInt32, field::Symbol, @nospecialize(key::Type))::Nothing
    local slots = get(registry.pending.slots, idx, nothing)
    slots === nothing || push!(slots, (field, key))
    return nothing
end

# the type with every pending reference resolved through `real`
# parity(quarantine: see PendingTypes (dev/formal/RecGroup.tla).)
function _resolve_pending(ct::CompositeType, real::Dict{UInt32, UInt32})::CompositeType
    local r(vt) = vt isa ConcreteRef && vt.type_idx >= PENDING_BASE ?
        ConcreteRef(real[vt.type_idx], vt.nullable) : vt
    ct isa FuncType && return FuncType(WasmValType[r(v) for v in ct.params], WasmValType[r(v) for v in ct.results])
    ct isa ArrayType && return ArrayType(FieldType(r(ct.elem.valtype), ct.elem.mutable_))
    local sup = ct.supertype_idx
    return StructType(FieldType[FieldType(r(f.valtype), f.mutable_) for f in ct.fields],
                      sup !== nothing && sup >= PENDING_BASE ? real[sup] : sup)
end

"""
    finish_pending!(mod, registry, id, ct) -> index

The pending type `id` translated to `ct`. Its lowlink is the least lowlink among the pending
types `ct` refers to (Tarjan's search, each reference an edge). A type whose lowlink is its own
id is the root of a strongly connected component: it and every type pending above it are
added at consecutive indices with their pending references resolved, or take the indices of
an equal group already in the section (add_type_group!, dev/formal/TypeIdentity.tla; a type
in no cycle is added as any type is, deduplicated), and their registry entries take the real
indices, which this returns for `id`. Otherwise the type waits for its root and `id` is returned.
formal(dev/formal/RecGroup.tla): Valid, Exact, Minimal — every reference is backward or within
its group, no field loses its type, and a group is exactly a cycle.
parity(pkg/wasm_builder/lib/src/builder/types.dart:240 _RecGroupBuilder._createAllRecursiveGroups):
a recursion group is a strongly connected component, added after every group it refers to.
"""
function finish_pending!(mod::WasmModule, registry::TypeRegistry, id::UInt32, ct::CompositeType)::UInt32
    local p = registry.pending
    local low = p.low[id]
    for r in type_refs(ct)
        r >= PENDING_BASE || continue
        haskey(p.low, r) || error("type registration: $(p.keys[id]) refers to pending type $r that is not being registered")
        low = min(low, p.low[r])
    end
    p.low[id] = low
    p.types[id] = ct
    low == id || return id
    local k = findlast(==(id), p.stack)
    local members = p.stack[k:end]
    resize!(p.stack, k - 1)
    local real = Dict{UInt32, UInt32}()
    if length(members) == 1 && !(id in type_refs(ct))
        real[id] = add_type!(mod, ct)
    else
        local base = UInt32(length(mod.types))
        for (i, m) in enumerate(members)
            real[m] = base + UInt32(i - 1)
        end
        local got = add_type_group!(mod, CompositeType[_resolve_pending(p.types[m], real) for m in members])
        for (i, m) in enumerate(members)
            real[m] = got + UInt32(i - 1)   # an equal group already in the section is that group
        end
    end
    for m in members
        for (field, key) in p.slots[m]
            local d = getfield(registry, field)
            local v = d[key]
            d[key] = v isa StructInfo ?
                StructInfo(v.julia_type, real[m], v.field_names, v.field_types, v.field_offset) : real[m]
        end
        delete!(p.slots, m); delete!(p.types, m); delete!(p.low, m); delete!(p.keys, m)
    end
    return real[id]
end

# parity(class_info.dart:420 _createStructForClass): one wasm struct per class, with its supertype.
function register_struct_type!(mod::WasmModule, registry::TypeRegistry, T::DataType)::Union{Nothing, StructInfo}
    # Already registered, or being registered (its entry holds a pending id)
    haskey(registry.structs, T) && return registry.structs[T]
    # a closure type has one layout, its captured-fields context, whichever registrar reaches it
    # first (a field, tuple, constant or local registered it as a class struct, MARCH 13.17
    # A7S1); erased, it is its closure object (maybe_wrap_closure!)
    is_closure_type(T) && return register_closure_type!(mod, registry, T)
    return _register_struct_type_inner!(mod, registry, T)
end

# parity(pkg/dart2wasm/lib/class_info.dart:420 ClassInfoCollector._createStructForClass)
function _register_struct_type_inner!(mod::WasmModule, registry::TypeRegistry, T::DataType)::Union{Nothing, StructInfo}

    # MemoryRef/Memory should NOT be registered as struct types.
    # They map to array types in WasmGC. Guard against callers that use
    # Julia's isstructtype() (true for MemoryRef) instead of our is_struct_type().
    if T isa DataType && T.name.name in (:MemoryRef, :GenericMemoryRef, :Memory, :GenericMemory)
        return nothing
    end

    # SimpleVector is a variable-length container in Julia (fieldcount=0).
    # Register it as an externref array type so _svec_len and _svec_ref work.
    # SimpleVector elements are Any-typed, mapping to externref in WasmGC.
    if T === Core.SimpleVector
        # When JlType hierarchy is active, reuse the heterogeneous
        # $JlSVec array type. Previously this created a separate
        # (array (mut anyref)) which caused type mismatch: struct.get on $JlDataType.parameters
        # returns (ref null $JlSVec) but the local was typed with a different array type index.
        if registry.jl_svec_idx !== nothing
            arr_idx = registry.jl_svec_idx
        else
            local svec_elem_type = ExternRef
            arr_idx = add_array_type!(mod, svec_elem_type, true)
        end
        # Register as a "struct" with 0 Julia fields but backed by an array type
        info = StructInfo(T, arr_idx, Symbol[], DataType[], UInt32(0))  # SimpleVector is an array type, no typeId
        registry.structs[T] = info
        return info
    end

    # Core.Box is a mutable captured-variable CELL inside Dart's context model,
    # not a user-visible Object allocation. Keep its `{classId, contents}` Top
    # representation and its one-field Julia offset; the closure object owns
    # identity, while all closures sharing this cell observe the same contents.
    if T === Core.Box
        idx = get_box_type!(mod, registry, AnyRef)
        info = StructInfo(T, idx, [:contents], Type[Any], UInt32(1))
        registry.structs[T] = info
        return info
    end

    # Redirect Tuple types to their specialized registration function
    # Tuples have integer field names (1, 2, ...) not symbols
    if T <: Tuple
        return register_tuple_type!(mod, registry, T)
    end

    # parity(class_info.dart:420 _createStructForClass, :539 _generateFields): the class is
    # recorded, then its fields translate — a field reaching it again refers to it (pending
    # until its recursion group is added, finish_pending!).
    local id = begin_pending!(registry, :structs, T)
    registry.structs[T] = StructInfo(T, id, Symbol[fieldname(T, i) for i in 1:fieldcount(T)],
                                     Type[fieldtype(T, i) for i in 1:fieldcount(T)], UInt32(2))
    local wasm_fields = _struct_fields!(mod, registry, T)
    # step5 THE CLASS-DAG: the struct subtypes its nearest abstract parent's synthetic
    # (dart class_info.dart:420 _createStructForClass), created parent-first at registration.
    local _dagp = dag_supertype_idx!(mod, registry, T)
    finish_pending!(mod, registry, id, _dagp === nothing ? StructType(wasm_fields) : StructType(wasm_fields, _dagp))
    return registry.structs[T]
end

"""
    _nullable_field_storage_type!(mod, registry, ft, inner_type) -> WasmValType

The storage type of a struct field typed `ft = Union{Nothing, inner_type}`: the nullable ref
of `inner_type`'s representation — a registered struct/vector/array ref (a struct being
registered right now contributes its pending index, finish_pending!), else the one
translator's answer (for a numeric `inner_type`, its nullable box).

parity(class_info.dart:539 _generateFields): a field's wasm type is `translateTypeOfField`,
i.e. translateStorageType with the field type's nullability (translator.dart:1141).
"""
function _nullable_field_storage_type!(mod::WasmModule, registry::TypeRegistry,
                                       ft::Union, inner_type::Type)::WasmValType
    if inner_type <: Array && inner_type isa DataType
        # Union{Nothing, Vector{T}} - use Vector struct type
        elem_type = eltype(inner_type)
        # the element's struct first (one being registered already holds its pending entry)
        if !haskey(registry.structs, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
            register_struct_type!(mod, registry, elem_type)
        end
        info = register_vector_type!(mod, registry, inner_type)
        return ConcreteRef(info.wasm_type_idx, true)  # nullable
    elseif inner_type <: AbstractVector && inner_type isa DataType
        # Non-Array AbstractVector (BitVector, etc.) — register as struct
        info_av = register_struct_type!(mod, registry, inner_type)
        return info_av !== nothing ? ConcreteRef(info_av.wasm_type_idx, true) : ExternRef
    elseif inner_type <: AbstractVector
        # Union{Nothing, generic AbstractVector} - use raw array
        elem_type = eltype(inner_type)
        # the element's struct first (one being registered already holds its pending entry)
        if !haskey(registry.structs, elem_type) && isconcretetype(elem_type) && isstructtype(elem_type)
            register_struct_type!(mod, registry, elem_type)
        end
        return ConcreteRef(get_array_type!(mod, registry, elem_type), true)  # nullable
    elseif inner_type === String || inner_type === Symbol
        # Union{Nothing, String/Symbol} — nullable string ref
        return ConcreteRef(get_string_struct_type!(mod, registry), true)
    elseif isconcretetype(inner_type) && isstructtype(inner_type)
        # Union{Nothing, SomeStruct} - nullable struct ref
        register_struct_type!(mod, registry, inner_type)
        return ConcreteRef(registry.structs[inner_type].wasm_type_idx, true)  # nullable
    end
    return get_concrete_wasm_type(ft, mod, registry)
end

# parity(class_info.dart:539 _generateFields): the class's field list after the inherited prefix.
function _struct_fields!(mod::WasmModule, registry::TypeRegistry, T::DataType)::Vector{FieldType}
    field_types = [fieldtype(T, i) for i in 1:fieldcount(T)]

    # Create WasmGC field types
    # Prepend the inherited Object prefix.
    wasm_fields = object_prefix_fields()
    for ft in field_types
        # For array fields, use concrete reference to registered array type
        # But for Vector{T}, use the Vector struct type (with ref and size fields)
        # since Vector in Julia 1.11+ is a struct, not a raw array
        #
        # IMPORTANT: Check Memory/MemoryRef BEFORE AbstractVector because
        # Memory <: AbstractVector but should map to raw array, not Vector struct
        if ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # a MemoryRef field holds the ref's single-value struct (mem, off0)
            wasm_vt = memoryref_field_type!(mod, registry, ft)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            array_type_idx = get_array_type!(mod, registry, elem_type)
            wasm_vt = ConcreteRef(array_type_idx, true)  # nullable reference
        elseif ft === Vector{String}
            # Special case: Vector{String} is a struct with array-of-string-refs + size tuple
            # Register as Vector struct type
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: Array && ft isa DataType && isconcretetype(ft)
            # an Array is its Vector or Matrix wrapper struct, not a raw array
            info = register_array_wrapper!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: Array && ft isa DataType
            info = register_vector_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(info.wasm_type_idx, true)
        elseif ft <: AbstractArray && is_struct_type(ft)
            # an array other than Array is a struct of its fields (BitVector, UnitRange, Diagonal, …)
            info_av = register_struct_type!(mod, registry, ft)
            info_av === nothing && error("struct field of type $ft has no struct representation")
            wasm_vt = ConcreteRef(info_av.wasm_type_idx, true)
        elseif ft <: AbstractVector && !(ft isa Union)
            # Abstract/UnionAll vector FIELD (e.g. `content::Vector` in
            # Markdown.Admonition). The concrete runtime value is some Vector{T},
            # which WT represents as a vector-STRUCT (register_vector_type! → a
            # {typeId, data-array, size} struct), NOT a raw array. Vector-structs
            # for different element types are independent struct types with no
            # shared supertype and incompatible (invariant) data-array fields, so
            # the field cannot be any one concrete vector-struct nor a raw array —
            # storing a Vector{MD} struct into a raw-array field mismatches at
            # struct.new. Type it as the universal ref instead (same treatment as
            # an `Any` field): every vector-struct is a subtype, so stores need no
            # cast and reads downcast off the inferred SSA type.
            # (Surfaced by Basic-mathematics Admonition content: `expected (ref
            # null $rawarray), found (ref null $Vector{MD}-struct)` at func 9.)
            # Check !(ft isa Union) because Union{Memory{UInt8}, Memory{UInt16}, ...}
            # would match ft <: AbstractVector but should be handled as a tagged union instead.
            wasm_vt = AnyRef
        elseif ft === String || ft === Symbol
            # Strings and Symbols are WasmGC byte arrays
            str_type_idx = get_string_struct_type!(mod, registry)
            wasm_vt = ConcreteRef(str_type_idx, true)
        elseif ft === Any
            wasm_vt = AnyRef
        elseif ft === Int32 || ft === UInt32 || ft === Bool || ft === Char ||
               ft === Int8 || ft === UInt8 || ft === Int16 || ft === UInt16
            # Standard 32-bit or smaller types
            wasm_vt = I32
        elseif ft === Int64 || ft === UInt64 || ft === Int
            # Standard 64-bit integer types
            wasm_vt = I64
        elseif ft === Float32
            wasm_vt = F32
        elseif ft === Float64
            wasm_vt = F64
        elseif ft === Nothing
            # Nothing is a singleton type — no data, represent as i32 placeholder
            wasm_vt = I32
        elseif ft === Int128 || ft === UInt128
            # 128-bit integers are WasmGC {lo,hi} structs, not wasm
            # primitives. register_tuple_type! already maps Int128/UInt128 tuple
            # ELEMENTS to the int128 struct ref; struct FIELDS must do the same, or
            # a struct holding an Int128 field hits the isprimitivetype size check
            # below and errors ("Primitive type too large for Wasm field: Int128").
            # Surfaced by WasmMakie canvas render structs (turtles/conv1d/conv2d/
            # newton figures), which carry a 128-bit field.
            int128_info = register_int128_type!(mod, registry, ft)
            wasm_vt = ConcreteRef(int128_info.wasm_type_idx, true)
        elseif isprimitivetype(ft)
            # Custom primitive types (e.g., JuliaSyntax.Kind) - map by size
            sz = sizeof(ft)
            if sz <= 4
                wasm_vt = I32
            elseif sz <= 8
                wasm_vt = I64
            else
                error("Primitive type too large for Wasm field: $ft ($sz bytes)")
            end
        elseif ft isa Union
            # Handle Union types for struct fields
            inner_type = get_nullable_inner_type(ft)
            if inner_type !== nothing
                wasm_vt = _nullable_field_storage_type!(mod, registry, ft, inner_type)
            else
                # B4/U2: a union-typed field is a boxed AnyRef discriminated by classId
                # (julia_to_wasm_type(Union)→AnyRef) — the {typeId,tag,value} wrapper is retired.
                wasm_vt = julia_to_wasm_type(ft)
            end
        elseif isconcretetype(ft) && isstructtype(ft)
            # Nested struct type: registered (or pending, when it reaches back here)
            nested_info = register_struct_type!(mod, registry, ft)
            nested_info === nothing && error("struct field of type $ft has no struct representation")
            wasm_vt = ConcreteRef(nested_info.wasm_type_idx, true)
        elseif ft isa UnionAll && isstructtype(ft)
            # Parametric struct type without concrete parameters (e.g., SyntaxGraph)
            # Use AnyRef since we can't know the specific type parameter at compile time
            wasm_vt = AnyRef
        else
            wasm_vt = julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, true))  # mutable by default
    end
    return wasm_fields
end

"""
Register a Julia tuple type in the Wasm module.
Tuples are represented as WasmGC structs with numbered fields.
Rewrite a Type{X} tuple parameter to X's kind, `typeof(X)` (DataType, Union, UnionAll or
Core.TypeofBottom), so
every spelling of a type-object-carrying tuple shares one registry entry / wasm struct type.
parity(quarantine: Julia inference spells one runtime tuple element as Type{X} or as its
kind; a Dart record's field types have one spelling.)
"""
function _canonical_tuple_type(T::DataType)::Type
    changed = false
    ps = Any[]
    for P in T.parameters
        X = (P isa DataType && P.name === Type.body.name) ? P.parameters[1] : nothing
        if X isa DataType || X isa Union || X isa UnionAll || X === Union{}
            push!(ps, typeof(X))
            changed = true
        else
            push!(ps, P)
        end
    end
    return changed ? Tuple{ps...} : T
end

# parity(quarantine: Julia's Tuple{Vararg{E}} is a tuple type whose length is a runtime value;
# a Dart record type has a static field count.)
is_vararg_tuple_type(@nospecialize(T))::Bool =
    T isa DataType && T <: Tuple && any(p -> typeof(p) === Core.TypeofVararg, T.parameters)

"""
True only for the homogeneous runtime tuple layout this backend represents:
`Tuple{Vararg{E}}` with `E` concrete, or its non-empty narrowing `Tuple{E, …, Vararg{E}}`
(what a `typeassert`/PiNode leaves after `isempty` is ruled out) — the same runtime-length
value, so the same layout (`runtime_vararg_canonical`).

parity(quarantine: Julia's runtime-length Vararg tuple, see is_vararg_tuple_type.)
"""
function is_runtime_vararg_tuple_type(@nospecialize(T))::Bool
    (T isa DataType && T <: Tuple && length(T.parameters) >= 1) || return false
    local v = T.parameters[end]
    typeof(v) === Core.TypeofVararg || return false
    isdefined(v, :T) || return false
    (v.T isa Type && isconcretetype(v.T)) || return false
    for i in 1:length(T.parameters) - 1
        T.parameters[i] === v.T || return false
    end
    return true
end

"""The one layout key for a runtime Vararg tuple type: `Tuple{Vararg{E}}`.

parity(quarantine: Julia's runtime-length Vararg tuple, see is_vararg_tuple_type.)"""
function runtime_vararg_canonical(T::DataType)::DataType
    is_runtime_vararg_tuple_type(T) ||
        error("no homogeneous runtime Vararg tuple representation for $T")
    return Tuple{Vararg{T.parameters[end].T}}
end

# parity(quarantine: Julia's runtime-length Vararg tuple, see is_vararg_tuple_type.)
function vararg_tuple_eltype(T::DataType)::Type
    is_runtime_vararg_tuple_type(T) ||
        error("no homogeneous runtime Vararg tuple representation for $T")
    return T.parameters[end].T
end

"""Register the runtime-length tuple wrapper `{Object, data, size}` (one struct per element
type; a non-empty narrowing of the same layout aliases the canonical entry).

parity(quarantine: Julia's runtime-length Vararg tuple, see is_vararg_tuple_type.)"""
function register_vararg_tuple_type!(mod::WasmModule, registry::TypeRegistry, T::DataType)::StructInfo
    is_runtime_vararg_tuple_type(T) ||
        error("cannot register unsupported runtime Vararg tuple layout $T")
    haskey(registry.structs, T) && return registry.structs[T]
    local C = runtime_vararg_canonical(T)
    if C !== T
        local cinfo = register_vararg_tuple_type!(mod, registry, C)
        registry.structs[T] = cinfo
        return cinfo
    end
    local E = vararg_tuple_eltype(T)
    local size_type = Tuple{Int64}
    local size_info = haskey(registry.structs, size_type) ? registry.structs[size_type] :
                      register_tuple_type!(mod, registry, size_type)
    local data_idx = get_array_type!(mod, registry, E)
    local fields = FieldType[
        FieldType(I32, false),
        FieldType(I32, true),
        FieldType(ConcreteRef(data_idx, true), false),
        FieldType(ConcreteRef(size_info.wasm_type_idx, true), false),
    ]
    local idx = UInt32(add_type!(mod, StructType(fields, get_object_struct_type!(mod, registry))))
    local info = StructInfo(T, idx, [:ref, :size],
                            Type[Array{E,1}, size_type], UInt32(2))
    registry.structs[T] = info
    return info
end

"""
    vararg_tuple_of_struct(registry, idx) -> Union{Nothing, DataType}

The runtime-length tuple type (`Tuple{Vararg{E}}`) whose representation is the wasm struct
`idx`, or nothing: a widening of that representation to a slot of any class rejects
(convert_type!).
parity(quarantine: Julia's runtime-length Vararg tuple, see is_vararg_tuple_type.)
"""
function vararg_tuple_of_struct(registry::TypeRegistry, idx::Integer)::Union{Nothing, DataType}
    for (T, info) in registered_structs(registry)
        (T isa DataType && is_runtime_vararg_tuple_type(T) && info.wasm_type_idx == idx) && return runtime_vararg_canonical(T)
    end
    return nothing
end

# parity(class_info.dart:510 _createStructForRecordClass): a Julia tuple is dart's record.
function register_tuple_type!(mod::WasmModule, registry::TypeRegistry, T::Type{<:Tuple})::Union{Nothing, StructInfo}
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Union of Tuples (e.g., Union{Tuple{Vararg{Int64}}, Tuple{Vararg{Symbol}}})
    # passes `T <: Tuple` but doesn't have `.parameters`. Return nothing so the caller
    # falls through to the StructRef fallback.
    if T isa Union
        return nothing
    end

    # UnionAll tuples (e.g., Tuple{T,T} where T<:Type) don't have
    # .parameters — only DataType does. Return nothing for non-concrete tuples.
    if T isa UnionAll
        return nothing
    end

    if is_vararg_tuple_type(T)
        is_runtime_vararg_tuple_type(T) ||
            error("unsupported Vararg tuple layout $T must not be registered as a fixed tuple")
        return register_vararg_tuple_type!(mod, registry, T)
    end

    # Canonicalize Type{X} elements to X's kind. Inference spells a
    # type-object tuple element as Type{Int32} on one path (Const-widened arg
    # inference in the Core.tuple emitter) and DataType on another (the SSA
    # local's widenconst). Registering both spellings created two distinct wasm
    # structs for the same runtime tuple, and the ref.cast between them trapped
    # at runtime (LazyString error-message paths, gap 6d3a1788a329 layer 2).
    canon = _canonical_tuple_type(T)
    if canon !== T
        info = register_tuple_type!(mod, registry, canon)
        if info !== nothing
            registry.structs[T] = info
            pending_alias!(registry, info.wasm_type_idx, :structs, T)
        end
        return info
    end

    # Get element types
    elem_types = T.parameters
    local fixed = [(i, ft) for (i, ft) in enumerate(elem_types) if typeof(ft) != Core.TypeofVararg]
    local id = begin_pending!(registry, :structs, T)
    registry.structs[T] = StructInfo(T, id, Symbol[Symbol(i) for (i, _) in fixed],
                                     Type[ft isa DataType ? ft : Any for (_, ft) in fixed], UInt32(2))

    # Create WasmGC field types
    # Prepend typeId:i32 as field 0
    wasm_fields = object_prefix_fields()

    for (i, ft) in enumerate(elem_types)
        # Skip Vararg types (used in variadic tuples like Tuple{Int, Vararg{Any}})
        # Note: Vararg is NOT a Type, so we check typeof instead of isa
        if typeof(ft) == Core.TypeofVararg
            # Vararg can't be represented as a fixed struct field - skip
            continue
        end

        # Use concrete types for fields that need specific WASM types
        # This ensures consistency between struct field types and local variable types
        wasm_vt = if ft === String || ft === Symbol
            # String/Symbol fields need concrete string array type (array<i32>)
            type_idx = get_string_struct_type!(mod, registry)
            ConcreteRef(type_idx, true)
        elseif ft isa DataType && ft <: Array && isconcretetype(ft)
            # an Array is its Vector or Matrix wrapper struct, as get_concrete_wasm_type maps it
            info = register_array_wrapper!(mod, registry, ft)
            ConcreteRef(info.wasm_type_idx, true)
        elseif ft isa Type && ft <: Array
            info = register_vector_type!(mod, registry, ft)
            ConcreteRef(info.wasm_type_idx, true)
        elseif ft isa DataType && (ft.name.name === :MemoryRef || ft.name.name === :GenericMemoryRef)
            # a MemoryRef field holds the ref's single-value struct (mem, off0)
            memoryref_field_type!(mod, registry, ft)
        elseif ft isa DataType && (ft.name.name === :Memory || ft.name.name === :GenericMemory)
            # Memory{T} / GenericMemory maps to array type for element T
            elem_type = eltype(ft)
            type_idx = get_array_type!(mod, registry, elem_type)
            ConcreteRef(type_idx, true)
        elseif ft <: Tuple && isconcretetype(ft)
            # Nested tuple - register and use concrete ref
            nested_info = register_tuple_type!(mod, registry, ft)
            if nested_info !== nothing
                ConcreteRef(nested_info.wasm_type_idx, true)
            else
                julia_to_wasm_type(ft)
            end
        elseif ft === Int128 || ft === UInt128
            # 128-bit integers are WasmGC structs — use concrete ref
            int128_info = register_int128_type!(mod, registry, ft)
            ConcreteRef(int128_info.wasm_type_idx, true)
        elseif is_string_codeunits(ft)
            # a String's CodeUnits is the String's byte array, as its values are held
            # (get_concrete_wasm_type); a class struct here trapped building the tuple (A8C4)
            ConcreteRef(get_string_array_type!(mod, registry), true)
        elseif isconcretetype(ft) && isstructtype(ft) && !(ft <: Tuple)
            # Nested struct - register and use concrete ref
            nested_info = register_struct_type!(mod, registry, ft)
            if nested_info !== nothing
                ConcreteRef(nested_info.wasm_type_idx, true)
            else
                julia_to_wasm_type(ft)
            end
        else
            # For primitives and other types, use generic mapping
            julia_to_wasm_type(ft)
        end
        push!(wasm_fields, FieldType(wasm_vt, false))  # Tuples are immutable
    end

    # step5 THE CLASS-DAG: the struct subtypes its nearest abstract parent's
    # synthetic (dart class_info.dart:420 _createStructForClass), created parent-first at registration.
    local _dagp = dag_supertype_idx!(mod, registry, T)
    finish_pending!(mod, registry, id, _dagp === nothing ? StructType(wasm_fields) : StructType(wasm_fields, _dagp))
    return registry.structs[T]
end

"""
Register a multi-dimensional array type (Matrix, Array{T,3}, etc.) as a WasmGC struct.

Multi-dim arrays are stored as WasmGC structs after the Object header:
- data (reference to flat WasmGC array of element type) — the Memory of Julia's :ref
- size (tuple of dimensions)
- off0 (i32) — the element offset of Julia's :ref in that Memory (array_offset_field_idx)

This matches Julia's internal representation where Matrix{T} has :ref and :size fields; the
:ref MemoryRef is the pair (data, off0), as for Vector.

parity(quarantine: Julia's Array{T,N} is a mutable struct {ref::MemoryRef, size::NTuple{N,Int}}
over a Memory buffer, read and written by field name in Base; the wasm struct copies it.)
"""
function register_matrix_type!(mod::WasmModule, registry::TypeRegistry, T::Type)::StructInfo
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Guard against Union{} (bottom type) - can't create a matrix of it
    if T === Union{}
        error("Cannot register matrix type for Union{} (bottom type)")
    end

    # Get element type and dimensionality
    elem_type = eltype(T)
    N = ndims(T)

    # Create size tuple type
    size_tuple_type = NTuple{N, Int64}
    if !haskey(registry.structs, size_tuple_type)
        register_tuple_type!(mod, registry, size_tuple_type)
    end
    size_struct_info = registry.structs[size_tuple_type]

    # Create/get the data array type
    data_array_idx = get_array_type!(mod, registry, elem_type)

    # Create WasmGC struct with fields:
    # Field 0: typeId (i32, immutable)
    # - Field 1: ref (nullable reference to data array)
    # - Field 2: size (nullable reference to size tuple struct)
    wasm_fields = [
        FieldType(I32, false),  # classId
        FieldType(I32, true),   # identityHash
        FieldType(ConcreteRef(data_array_idx, true), true),  # data array, mutable
        FieldType(ConcreteRef(size_struct_info.wasm_type_idx, true), false),  # size, immutable
        FieldType(I32, true)   # off0, mutable with data (array_offset_field_idx)
    ]

    # Add struct type to module
    # step5 THE CLASS-DAG: the struct subtypes its nearest abstract parent's
    # synthetic (dart class_info.dart:420 _createStructForClass), created parent-first at registration.
    local _dagp = dag_supertype_idx!(mod, registry, T)
    type_idx = _dagp === nothing ? add_struct_type!(mod, wasm_fields) :
               UInt32(add_type!(mod, StructType(wasm_fields, _dagp)))

    # Record the two inherited Object fields.
    field_names = [:ref, :size]  # Julia field names
    field_types_vec = DataType[Array{elem_type, 1}, size_tuple_type]  # Use Vector for ref field type

    info = StructInfo(T, type_idx, field_names, field_types_vec, UInt32(2))
    registry.structs[T] = info

    return info
end

"""
    register_reachable_type!(mod, registry, T)

parity(class_info.dart:666 ClassInfoCollector.collect): the ONE registrar for a
Julia type that codegen will read as a wasm struct — signatures, and field reads
that reach a type before any other site registered it. Each representation has
its own registrar; this picks it. Types without a struct representation are a
no-op.
"""
function register_reachable_type!(mod::WasmModule, registry::TypeRegistry, @nospecialize(T))::Nothing
    T === Union{} && return nothing
    if is_closure_type(T)
        register_closure_type!(mod, registry, T)
    elseif T === Symbol || T === String
        get_string_struct_type!(mod, registry)
    elseif is_struct_type(T)
        register_struct_type!(mod, registry, T)
    elseif T isa DataType && T <: Array && isconcretetype(T)
        register_array_wrapper!(mod, registry, T)
    elseif T <: Vector
        register_vector_type!(mod, registry, T)
    end
    return nothing
end

"""
Register a Vector{T} type as a WasmGC struct with mutable size.

Vectors are stored as WasmGC structs after the Object header:
- ref (reference to WasmGC array of element type) — the Memory of Julia's :ref
- size (mutable Tuple{Int64} tracking logical size)
- off0 (mutable i32) — the element offset of Julia's :ref in that Memory, appended so the
  data and size field indices stay put (array_offset_field_idx)

This matches Julia's internal representation where Vector{T} has :ref and :size fields.
The size field is mutable to support setfield!(v, :size, (n,)) for push!/resize! operations.

parity(quarantine: Julia's Array{T,1} layout {ref::MemoryRef, size::Tuple{Int}}, see
register_matrix_type!.)
"""
function register_vector_type!(mod::WasmModule, registry::TypeRegistry, T::Type)::StructInfo
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Guard against Union{} (bottom type) - can't create a vector of it
    if T === Union{}
        error("Cannot register vector type for Union{} (bottom type)")
    end


    # Get element type
    elem_type = eltype(T)
    size_tuple_type = Tuple{Int64}
    local id = begin_pending!(registry, :structs, T)
    registry.structs[T] = StructInfo(T, id, Symbol[:ref, :size], Type[Array{elem_type, 1}, size_tuple_type], UInt32(2))

    # Create size tuple type (Tuple{Int64} for 1D)
    if !haskey(registry.structs, size_tuple_type)
        register_tuple_type!(mod, registry, size_tuple_type)
    end
    size_struct_info = registry.structs[size_tuple_type]

    # Create/get the data array type
    data_array_idx = get_array_type!(mod, registry, elem_type)

    # Create WasmGC struct with fields:
    # Field 0: typeId (i32, immutable)
    # - Field 1: ref (reference to data array)
    # - Field 2: size (MUTABLE reference to size tuple struct)
    wasm_fields = [
        FieldType(I32, false),  # classId
        FieldType(I32, true),   # identityHash
        FieldType(ConcreteRef(data_array_idx, true), true),  # data array, mutable
        FieldType(ConcreteRef(size_struct_info.wasm_type_idx, true), true),  # size, MUTABLE for setfield!
        FieldType(I32, true)   # off0, mutable with data (array_offset_field_idx)
    ]

    # Add struct type to module
    # step5 THE CLASS-DAG: the struct subtypes its nearest abstract parent's
    # synthetic (dart class_info.dart:420 _createStructForClass), created parent-first at registration.
    local _dagp = dag_supertype_idx!(mod, registry, T)
    finish_pending!(mod, registry, id, _dagp === nothing ? StructType(wasm_fields) : StructType(wasm_fields, _dagp))
    return registry.structs[T]
end

"""
    register_memoryref_box!(mod, registry, T) -> UInt32

The single-value form of a `MemoryRef{T}` value, for a slot that holds any value (an `Any`
field): `{classId, identityHash, mem, off0}` — the ref's Memory (the raw wasm array) and its
i32 element offset, memoryrefoffset - 1. Immutable after construction, as the MemoryRef is.
parity(class_info.dart:420 ClassInfoCollector._createStructForClass): a class struct under
Object, carrying the fields a typed-data view keeps (typed_data.dart:2441 WasmI8ArrayBase:
_data, _offsetInElements).
"""
function register_memoryref_box!(mod::WasmModule, registry::TypeRegistry, T::DataType)::UInt32
    haskey(registry.memoryref_box_idxs, T) && return registry.memoryref_box_idxs[T]
    T <: Core.GenericMemoryRef && isconcretetype(T) ||
        error("register_memoryref_box!: $T is not a concrete MemoryRef type")
    local id = begin_pending!(registry, :memoryref_box_idxs, T)
    registry.memoryref_box_idxs[T] = id
    data_array_idx = get_array_type!(mod, registry, eltype(T))
    wasm_fields = FieldType[object_prefix_fields()...,
                            FieldType(ConcreteRef(data_array_idx, true), false),  # mem
                            FieldType(I32, false)]                                # off0
    local _dagp = dag_supertype_idx!(mod, registry, T)
    return finish_pending!(mod, registry, id, _dagp === nothing ?
        StructType(wasm_fields, get_object_struct_type!(mod, registry)) : StructType(wasm_fields, _dagp))
end

"""
    memoryref_field_type!(mod, registry, T) -> WasmValType

The wasm type of a struct or closure field declared `MemoryRef{T}`: a reference to the ref's
single-value struct (register_memoryref_box!), which keeps its element offset. A field of a
MemoryRef type that is not concrete has no struct to hold its offset and is rejected.
parity(class_info.dart:420 ClassInfoCollector._createStructForClass): a field of class type
holds a reference to that class's struct.
"""
function memoryref_field_type!(mod::WasmModule, registry::TypeRegistry, @nospecialize(T))::WasmValType
    T isa DataType && isconcretetype(T) ||
        error("a struct field of MemoryRef type $T is not concrete; its element offset has no struct to live in")
    return ConcreteRef(register_memoryref_box!(mod, registry, T), true)
end

"""
    array_offset_field_idx(info) -> UInt32

The wasm field of an Array struct (register_vector_type!, register_matrix_type!) that holds
the element offset off0 of the Array's :ref — memoryrefoffset(a.ref) - 1 — beside the data
array that holds its Memory. It follows the :ref and :size fields.
formal(dev/formal/StorageRef.tla): InBounds, Contents, JuliaOffset — (data, off0, size) stays Julia's (mem, memoryrefoffset - 1, size) through push!, popfirst! and resize!.
parity(sdk/lib/_internal/wasm/common/typed_data.dart:2443 WasmI8ArrayBase._offsetInElements):
the view's element offset, a field beside its _data.
"""
array_offset_field_idx(info::StructInfo)::UInt32 = info.field_offset + UInt32(2)

"""
Register a 128-bit integer type (Int128 or UInt128) as a WasmGC struct.

128-bit integers are stored as WasmGC structs with two i64 fields:
- Field 0: lo (low 64 bits)
- Field 1: hi (high 64 bits)

This is the standard representation used by most WASM compilers for 128-bit integers.

parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one 64-bit value — so
the 128-bit value is a struct of two i64 halves.)
"""
function register_int128_type!(mod::WasmModule, registry::TypeRegistry, T::Type)::StructInfo
    # Already registered?
    haskey(registry.structs, T) && return registry.structs[T]

    # Prepend typeId:i32 as field 0
    # Create WasmGC struct with typeId + two i64 fields (lo, hi)
    wasm_fields = [
        FieldType(I32, false),  # typeId
        FieldType(I64, true),   # lo (low 64 bits), mutable for potential in-place ops
        FieldType(I64, true)    # hi (high 64 bits)
    ]

    # Add struct type to module
    # step5 THE CLASS-DAG: the struct subtypes its nearest abstract parent's
    # synthetic (dart class_info.dart:420 _createStructForClass), created parent-first at registration.
    local _dagp = dag_supertype_idx!(mod, registry, T)
    type_idx = _dagp === nothing ? add_struct_type!(mod, wasm_fields) :
               UInt32(add_type!(mod, StructType(wasm_fields, _dagp)))

    # Record mapping with field info
    field_names = [:lo, :hi]
    field_types_vec = DataType[UInt64, UInt64]  # Both fields are 64-bit

    info = StructInfo(T, type_idx, field_names, field_types_vec, UInt32(1))
    registry.structs[T] = info

    return info
end

"""
Get or create the 128-bit integer struct type.

parity(quarantine: Int128/UInt128, see register_int128_type!.)
"""
function get_int128_type!(mod::WasmModule, registry::TypeRegistry, T::Type)::UInt32
    if haskey(registry.structs, T)
        return registry.structs[T].wasm_type_idx
    else
        info = register_int128_type!(mod, registry, T)
        return info.wasm_type_idx
    end
end

"""
    register_core_ir_types!(mod, registry)

Pre-register Core IR node types as WasmGC structs for self-hosting dispatch.
These types are used in compile_statement's isa chain (ReturnNode, GotoNode, etc.).
Registration order: dependencies first (SlotNumber before NewvarNode).
parity(quarantine: the Julia compiler's own IR types a reflecting program reads; dart has no runtime IR.)
"""
function register_core_ir_types!(mod::WasmModule, registry::TypeRegistry)::Nothing
    for T in (Core.SlotNumber, Core.SSAValue, Core.Argument, Core.GotoNode,
              Core.ReturnNode, Core.UpsilonNode, Core.PiNode, Core.GotoIfNot,
              Core.EnterNode, Core.NewvarNode, Core.PhiNode, Core.PhiCNode, Expr)
        register_struct_type!(mod, registry, T)
    end
end
