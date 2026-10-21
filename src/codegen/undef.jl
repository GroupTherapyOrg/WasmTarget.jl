# ============================================================================
# Julia's `#undef` in a pointer slot
# ============================================================================
# Julia's `nothing` is an object (jl_nothing) and `#undef` is NULL. WT's `nothing` is the wasm
# null at every nullable reference (dev/formal/Coercion.tla NothingIsNull), dart's null. So a
# pointer slot whose type admits no `nothing` (a String's, a Number's) keeps its null as `#undef`,
# and one whose type admits `nothing` too (Any, a Union with Nothing, any other supertype of
# Nothing) is held in a reference of the any hierarchy and marks `#undef` with the module's one
# undefined value: an allocation and an unset store `#undef`, a read tests it and throws
# UndefRefError, and isassigned and isdefined compare against it (dev/formal/Undef.tla).

"""
    undef_slot(julia_type, wasm_type) -> Bool

Whether a slot of `julia_type`, held in `wasm_type` (a value type, or a packed storage type,
which holds no reference), marks `#undef` with the undefined value (undef_value_global!): Julia
stores it as a pointer (it is not allocated inline, so `undef` leaves it NULL), its type admits
`nothing`, and its wasm type is an abstract reference of the any hierarchy (anyref, eqref,
structref), which holds the undefined value beside the null. Any other reference slot that can
be `#undef` (a Memory element, a field `new` may leave unset) holds no `nothing`, so its null is
`#undef` (undef_slot_storage holds every such slot that admits `nothing` in the any hierarchy); a
field `new` always sets is never `#undef`, and its null, if any, is `nothing`.
formal(dev/formal/Undef.tla): after every sequence of stores, unsets, isassigned and reads WT
answers Julia's; in a slot that holds `nothing` too `#undef` is not the null, and the undefined
value sits only in a slot of the any hierarchy.
parity(quarantine: dart marks an unset late variable by null where its type is non-nullable and,
where it is potentially nullable, by a sentinel (pkg/front_end/lib/src/kernel/late_lowering.dart:522
useSentinel, the useSentinelOrNull strategy, :549; computeIsSetEncoding :560, its
useSentinelOrNull case :570) or a companion isSet field (useIsSetFieldOrNull, which dart2wasm
selects: target.dart:565 supportsLateLoweringSentinel => false). Julia's `#undef` is one fact read
by one rule (C1) wherever a pointer slot holds it: a Memory element, which has no companion field
for an isSet bit to live in, a field `new` may leave unset and a Core.Box's contents. A companion
isSet field per field and per Box beside the elements' mark would be a second encoding of that one
fact, so every slot whose type admits `nothing` marks `#undef` by one value of its own, the
sentinel.)
"""
function undef_slot(@nospecialize(julia_type), @nospecialize(wasm_type))::Bool
    (wasm_type === AnyRef || wasm_type === EqRef || wasm_type === StructRef) || return false
    return pointer_slot_admits_nothing(julia_type)
end

"""
    pointer_slot_admits_nothing(T) -> Bool

Whether a slot of the Julia type `T` is a pointer (not allocated inline: Julia's `undef` leaves
it NULL) whose type admits `nothing` beside `#undef`.
parity(quarantine: as undef_slot.)
"""
pointer_slot_admits_nothing(@nospecialize(T))::Bool =
    pointer_slot(T) && T !== Nothing && is_null_nothing(T)

"""
    pointer_slot(T) -> Bool

Whether a slot of the Julia type `T` can be `#undef`, a pointer Julia's `undef` leaves NULL:
`T` is not allocated inline (its slot is the pointer), or it is allocated inline with a pointer
in it, an immutable struct with a pointer field (Some{String}, Tuple{Int64,String}: not
Base.datatype_pointerfree, its layout's first_ptr >= 0), whose `#undef` is its first pointer
NULL (typed_load's null_pointer_check of extract_first_ptr, cgutils.cpp:2270; jl_field_isdefined
tests layout->first_ptr, datatype.c:2293). WT holds such a struct in its own nullable reference,
which holds no `nothing`, so its null is that `#undef`. A pointer-free inline slot (an isbits
value or an isbits union) is its bits and is never `#undef`, though WT may hold an isbits union
in a nullable box whose null is `nothing`.
parity(quarantine: as undef_slot; dart has no inline struct, so Julia's first_ptr rule decides
which slots can be `#undef`.)
"""
pointer_slot(@nospecialize(T))::Bool =
    T isa Type && (!Base.allocatedinline(T) || (T isa DataType && !Base.datatype_pointerfree(T)))

"""
    undef_slot_storage(T, w) -> WasmValType

The storage type of a slot (a Memory element, a field `new` may leave unset) of the Julia type
`T`, whose own representation is `w`: a pointer slot whose type admits `nothing` is held in the
any hierarchy, eqref for a concrete, array or i31 reference (S's own nullable reference holds the
null and S's objects, never the undefined value), so `#undef` and `nothing` are two values
(undef_slot); any other slot is `w`. A Nothing-admitting pointer slot whose representation is an
abstract reference outside the any hierarchy (an externref, a funcref: a Union{Nothing,Function})
has no place for the undefined value: it keeps `w`, and every allocation, unset, test and read of
its `#undef` rejects at its statement (_undef_unrepresentable!; dev/MARCH.md 13.17, A18E4). A
concrete reference is taken for a struct or array type's (WT holds no Julia value in a typed
function reference: a closure is its context struct), and a function type's would be refused
where the slot's eqref is stored into (the builder's subtype check).
parity(quarantine: as undef_slot.)
"""
function undef_slot_storage(@nospecialize(T), w::Union{WasmValType,PackedType})::Union{WasmValType,PackedType}
    pointer_slot_admits_nothing(T) || return w
    (w === AnyRef || w === EqRef || w === StructRef) && return w
    (w isa ConcreteRef || w === ArrayRef || w === I31Ref) && return EqRef
    (w === ExternRef || w === FuncRef) && return w   # its `#undef` rejects where it is used
    error("a pointer slot of $(T) is held in $(w), which is no reference")
end

"""
    _undef_unrepresentable!(b, ctx, julia_type, w) -> Bool

Whether a slot of `julia_type` held in `w` holds `nothing` and `#undef` where `w`, outside the any
hierarchy (an externref, a funcref), has no undefined value to tell them apart
(undef_slot_storage): the use of its `#undef` then rejects at its statement, a validating trap
after it, and answers true.
parity(quarantine: as undef_slot.)
"""
function _undef_unrepresentable!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(julia_type),
                                 w::Union{WasmValType,PackedType})::Bool
    (pointer_slot_admits_nothing(julia_type) && (w === ExternRef || w === FuncRef)) || return false
    emit_unsupported_stub!(ctx, b, :unsupported_type,
        "a slot of $(julia_type) holds `nothing` and `#undef`, but its representation $(w), a host reference, has no undefined value to tell them apart")
    return true
end

"""
    undef_value_global!(mod, registry) -> global index

The module's one undefined value: an immutable global holding the one object of an empty struct
type, defined on first use and kept on the registry (one compile's). A slot undef_slot admits is
filled with it where Julia leaves NULL, and tested against it by identity (emit_is_undef!).
parity(quarantine: as undef_slot.)
"""
function undef_value_global!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.undef_global === nothing || return registry.undef_global
    local t = add_type!(mod, StructType(FieldType[], nothing))
    registry.undef_struct_idx = t
    registry.undef_global = define_global!(init -> struct_new!(init, t), mod, ConcreteRef(t, false), false)
    return registry.undef_global
end

"""
    emit_undef!(b, ctx, julia_type, w) -> b

Push `#undef` for a slot of `julia_type` held in the reference type `w`: the undefined value
where the slot holds `nothing` too (undef_slot), else `w`'s null.
parity(quarantine: as undef_slot.)
"""
function emit_undef!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(julia_type),
                     w::WasmValType)::InstrBuilder
    _wt_is_ref(w) || error("a slot of $(julia_type) held in $(w) is no reference and has no `#undef`")
    _undef_unrepresentable!(b, ctx, julia_type, w) && return b
    undef_slot(julia_type, w) && return global_get!(b, undef_value_global!(ctx.mod, ctx.type_registry))
    w isa ConcreteRef ? ref_null!(b, Int64(w.type_idx)) : ref_null!(b, w)
    return b
end

"""
    emit_is_undef!(b, mod, registry, alloc) -> b

`[ref] -> [i32]`: whether the reference of the any hierarchy on the stack is the undefined value,
by identity (`ref.eq`, after a test of its struct type: an anyref need not be an eqref), its scratch
declared through `alloc`. The null, `nothing`, is not it.
parity(quarantine: as undef_slot.)
"""
function emit_is_undef!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry, alloc::Function)::InstrBuilder
    local g = undef_value_global!(mod, registry)
    local t = registry.undef_struct_idx::UInt32
    local v = UInt32(alloc(AnyRef))
    local_tee!(b, v)
    ref_test!(b, Int64(t), false)
    if_!(b; results=WasmValType[I32])
    local_get!(b, v); ref_cast!(b, Int64(t), false); global_get!(b, g); ref_eq!(b)
    else_!(b)
    i32_const!(b, 0)
    end_block!(b)
    return b
end

"""
    emit_is_unset!(b, ctx, julia_type, w) -> b

`[ref w] -> [i32]`: whether a slot of `julia_type` held in the reference type `w` holds `#undef`
(isassigned of a Memory element, isdefined of a field `new` may leave unset or a Box's contents,
negated): the undefined value where the slot holds `nothing` too (undef_slot), else the null
(jl_f_memoryref_isassigned and jl_f_isdefined test NULL); never for a slot that is no pointer
(pointer_slot), whose null, if any, is `nothing`. A field `new` always sets is never `#undef`
(isdefined_tfunc answers true for it), so isdefined of it is 1 with no test.
parity(quarantine: as undef_slot.)
"""
function emit_is_unset!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(julia_type),
                        w::WasmValType)::InstrBuilder
    _wt_is_ref(w) || error("a slot of $(julia_type) held in $(w) is no reference and has no `#undef`")
    _undef_unrepresentable!(b, ctx, julia_type, w) && return b
    if !pointer_slot(julia_type)
        drop!(b); i32_const!(b, 0)   # a pointer-free inline slot is always assigned
    elseif undef_slot(julia_type, w)
        emit_is_undef!(b, ctx.mod, ctx.type_registry, x -> allocate_local!(ctx, x))
    else
        ref_is_null!(b)
    end
    return b
end

"""
    emit_undef_read_check!(b, ctx, julia_type, w) -> b

`[ref w] -> [ref w]`: a read of a pointer slot of `julia_type` held in the reference type `w`
throws Julia's UndefRefError when the slot holds `#undef` (emit_is_unset!; null_pointer_check,
cgutils.cpp:1633), and leaves the value otherwise; a slot that is no pointer (pointer_slot) is
read as it is, as Julia checks no pointer-free inline slot.
parity(quarantine: as undef_slot.)
"""
function emit_undef_read_check!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(julia_type),
                                w::WasmValType)::InstrBuilder
    pointer_slot(julia_type) || return b
    _undef_unrepresentable!(b, ctx, julia_type, w) && return b
    local v = UInt32(allocate_local!(ctx, w))
    local_tee!(b, v)
    emit_is_unset!(b, ctx, julia_type, w)
    if_!(b)
    _emit_throw_error_struct!(b, ctx, UndefRefError)
    end_block!(b)
    local_get!(b, v)
    return b
end

"""
    emit_new_slots!(b, ctx, arr_type_idx, elem_type) -> b

`[i32 length] -> [(ref arr)]`: a new array of `length` slots of the Julia element type
`elem_type`, as Julia's allocator leaves them: a slot undef_slot admits holds the undefined value
(`array.fill` after `array.new_default`), any other its type's default (a reference slot's null is
its `#undef`; a number's zero, which an inline element's allocation leaves).
parity(intrinsics.dart:1959 wasmArrayNew): the allocation, `array.new_default`.
"""
function emit_new_slots!(b::InstrBuilder, ctx::AbstractCompilationContext, arr_type_idx::Integer,
                         @nospecialize(elem_type))::InstrBuilder
    local def = ctx.mod.types[Int(arr_type_idx) + 1]
    def isa ArrayType || error("array type $arr_type_idx is no array")
    _undef_unrepresentable!(b, ctx, elem_type, def.elem.valtype) && return b
    if !undef_slot(elem_type, def.elem.valtype)
        array_new_default!(b, arr_type_idx)
        return b
    end
    local n = UInt32(allocate_local!(ctx, I32))
    local a = UInt32(allocate_local!(ctx, ConcreteRef(UInt32(arr_type_idx), false)))
    local_tee!(b, n)
    array_new_default!(b, arr_type_idx)
    local_tee!(b, a)
    i32_const!(b, 0)
    emit_undef!(b, ctx, elem_type, def.elem.valtype)
    local_get!(b, n)
    array_fill!(b, arr_type_idx)
    local_get!(b, a)
    return b
end

"""
    emit_slots_undef_check!(b, ctx, arr_type_idx, elem_type, arr, from, len) -> b

`[] -> []`: each of the `len` slots of the array in local `arr` from index `from` (locals) is read
as Julia's iteration reads it (getindex, null_pointer_check): the first that holds `#undef` throws
UndefRefError (emit_undef_read_check!); a slot that is no reference, or no pointer
(pointer_slot), is never `#undef` and emits nothing. A copy of a Memory's slots into a value (a
splat, `Core.tuple(v...)`, `[v...]`, `[x, v...]`) reads each through it.
parity(quarantine: as undef_slot.)
"""
function emit_slots_undef_check!(b::InstrBuilder, ctx::AbstractCompilationContext, arr_type_idx::Integer,
                                 @nospecialize(elem_type), arr::Integer, from::Integer, len::Integer)::InstrBuilder
    local def = ctx.mod.types[Int(arr_type_idx) + 1]
    def isa ArrayType || error("array type $arr_type_idx is no array")
    local w = def.elem.valtype
    (_wt_is_ref(w) && pointer_slot(elem_type)) || return b
    _undef_unrepresentable!(b, ctx, elem_type, w) && return b
    local i = UInt32(allocate_local!(ctx, I32))
    i32_const!(b, 0); local_set!(b, i)
    local done = block!(b)
    local top = loop!(b)
    local_get!(b, i); local_get!(b, UInt32(len)); num!(b, Opcode.I32_GE_S); br_if!(b, done)
    local_get!(b, UInt32(arr)); local_get!(b, UInt32(from)); local_get!(b, i); num!(b, Opcode.I32_ADD)
    array_get!(b, arr_type_idx)
    emit_undef_read_check!(b, ctx, elem_type, w)
    drop!(b)
    local_get!(b, i); i32_const!(b, 1); num!(b, Opcode.I32_ADD); local_set!(b, i)
    br!(b, top)
    end_block!(b)   # loop
    end_block!(b)   # block
    return b
end

"""
    field_may_be_undef(T, i) -> Bool

Whether field `i` of the struct type `T` can be `#undef`: one of the trailing fields `new` may
leave unset (Julia's `T.name.n_uninitialized`, jl_datatype_t's count of them).
parity(quarantine: as undef_slot.)
"""
field_may_be_undef(@nospecialize(T), i::Integer)::Bool =
    T isa DataType && isstructtype(T) && 1 <= i <= fieldcount(T) && i > fieldcount(T) - T.name.n_uninitialized

"""
    _emit_field_undef_check!(b, ctx, T, field, k, info) -> b

After a read of the field `field` (its name or position) of the struct type `T`, the `k`-th of
its registered layout `info`: a reference field `new` may leave unset (field_may_be_undef) throws
UndefRefError when it holds `#undef` (emit_undef_read_check!), as Julia's getfield checks such a
field (null_pointer_check); any other field is always defined.
parity(quarantine: as undef_slot.)
"""
function _emit_field_undef_check!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(T),
                                  @nospecialize(field), k::Integer, info::StructInfo)::InstrBuilder
    (T isa DataType && isstructtype(T)) || error("a field read of $(T), which is no struct type")
    local i = field isa Integer ? Int(field) : field isa Symbol ? Base.fieldindex(T, field, false) :
              error("a field read of $(T) by $(repr(field)), which names no field")
    1 <= i <= fieldcount(T) || error("a field read of $(T) by $(repr(field)), which names no field")
    field_may_be_undef(T, i) || return b
    local def = ctx.mod.types[Int(info.wasm_type_idx) + 1]
    def isa StructType || error("the layout of $(T) is no struct")
    local w = def.fields[Int(wasm_field_idx(info, k)) + 1].valtype
    _wt_is_ref(w) && emit_undef_read_check!(b, ctx, fieldtype(T, i), w)
    return b
end
