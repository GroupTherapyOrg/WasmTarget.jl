# ============================================================================
# Julia's `#undef` beside `nothing` in a slot of the any hierarchy
# ============================================================================
# Julia's `nothing` is an object (jl_nothing) and `#undef` is NULL. WT's `nothing` is the wasm
# null at every nullable reference of the any hierarchy (dev/formal/Coercion.tla NothingIsNull),
# dart's null, so a slot that can hold both — a pointer slot whose type admits Nothing, held in an
# abstract reference of the any hierarchy — marks `#undef` with the module's one undefined value:
# an allocation and an unset fill it, a read tests it and throws UndefRefError, and isassigned and
# isdefined compare against it (dev/formal/Undef.tla).

"""
    undef_slot(julia_type, wasm_type) -> Bool

Whether a slot of `julia_type`, held in `wasm_type` (a value type, or a packed storage type,
which holds no reference), marks `#undef` with the undefined value
(undef_value_global!): Julia stores it as a pointer (it is not allocated inline, so `undef`
leaves it NULL) and its type admits `nothing`, and its wasm type is an abstract reference of
the any hierarchy (anyref, eqref, structref), which holds the undefined value beside the null.
Any other reference slot's null is `#undef` alone (its type admits no `nothing`), or is the
conflation MARCH 13.17 records (a `Union{Nothing,S}` slot held as S's nullable reference).
formal(dev/formal/Undef.tla): after every sequence of stores, unsets, isassigned and reads WT
answers Julia's; `#undef` and `nothing` are two representations, `nothing` the null.
parity(quarantine: dart has no uninitialized slot a nullable type can see: its late lowering
marks a non-nullable late field unset by null and a nullable one by a separate isSet field
(pkg/front_end/lib/src/kernel/late_lowering.dart:513 IsSetEncoding; target.dart:565
supportsLateLoweringSentinel => false), and its arrays are always filled; Julia's `#undef`
differs from `nothing`, which is dart's null in WT.)
"""
function undef_slot(@nospecialize(julia_type), @nospecialize(wasm_type))::Bool
    (wasm_type === AnyRef || wasm_type === EqRef || wasm_type === StructRef) || return false
    julia_type isa Type || return false
    Base.allocatedinline(julia_type) && return false
    return Nothing <: julia_type
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
    emit_undef_value!(b, mod, registry) -> b

Push the undefined value (undef_value_global!): Julia's `#undef` in a slot undef_slot admits.
parity(quarantine: as undef_slot.)
"""
emit_undef_value!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry)::InstrBuilder =
    global_get!(b, undef_value_global!(mod, registry))

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
    emit_undef_read_check!(b, ctx, w) -> b

`[ref w] -> [ref w]`: a read of a slot undef_slot admits throws Julia's UndefRefError when the
slot holds the undefined value (null_pointer_check, Julia's cgutils.cpp), and leaves the value
otherwise.
parity(quarantine: as undef_slot.)
"""
function emit_undef_read_check!(b::InstrBuilder, ctx::AbstractCompilationContext, w::WasmValType)::InstrBuilder
    local v = UInt32(allocate_local!(ctx, w))
    local_tee!(b, v)
    emit_is_undef!(b, ctx.mod, ctx.type_registry, x -> allocate_local!(ctx, x))
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
    emit_undef_value!(b, ctx.mod, ctx.type_registry)
    local_get!(b, n)
    array_fill!(b, arr_type_idx)
    local_get!(b, a)
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
its registered layout `info`: a field `new` may leave unset (field_may_be_undef) that holds
`nothing` too (undef_slot) throws UndefRefError when it holds the undefined value, as Julia's
getfield checks such a field (null_pointer_check).
parity(quarantine: as undef_slot.)
"""
function _emit_field_undef_check!(b::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(T),
                                  @nospecialize(field), k::Integer, info::StructInfo)::InstrBuilder
    (T isa DataType && isstructtype(T)) || return b
    local i = field isa Integer ? Int(field) : field isa Symbol ? Base.fieldindex(T, field, false) : 0
    field_may_be_undef(T, i) || return b
    local def = ctx.mod.types[Int(info.wasm_type_idx) + 1]
    def isa StructType || return b
    local w = def.fields[Int(wasm_field_idx(info, k)) + 1].valtype
    undef_slot(fieldtype(T, i), w) && emit_undef_read_check!(b, ctx, w)
    return b
end
