# ============================================================================
# Call Compilation
# ============================================================================

"""
    _is_externref_value(val, ctx) -> Bool

Check if a value (Argument or SSAValue) produces externref on the Wasm stack.
Used by numeric intrinsic handlers to detect when unboxing is needed.
parity(quarantine: a JS value WT carries as externref (JSValue, a WasmGlobal); dart's JS interop values are its own classes.)
"""
function _is_externref_value(val::NirNode, ctx::AbstractCompilationContext)::Bool
    if val isa NirArgument
        arg_idx = ctx.is_compiled_closure ? val.n : val.n - 1
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            return julia_to_wasm_type(ctx.arg_types[arg_idx]) === ExternRef
        end
    elseif val isa NirSSA
        if haskey(ctx.ssa_locals, val.id)
            local_idx = ctx.ssa_locals[val.id]
            local_arr_idx = local_idx - ctx.n_params + 1
            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                return ctx.locals[local_arr_idx] === ExternRef
            elseif local_idx < ctx.n_params
                # It's a param slot
                if local_idx + 1 <= length(ctx.arg_types)
                    return julia_to_wasm_type(ctx.arg_types[local_idx + 1]) === ExternRef
                end
            end
        elseif haskey(ctx.phi_locals, val.id)
            local_idx = ctx.phi_locals[val.id]
            local_arr_idx = local_idx - ctx.n_params + 1
            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                return ctx.locals[local_arr_idx] === ExternRef
            end
        end
    end
    return false
end

"""
    _ensure_typeof_scratch_local!(ctx) -> UInt32

Allocate (or return cached) a scratch i32 local for typeof struct lookups.
The local stores the typeId temporarily while the lookup array ref is pushed.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:382 InstructionsBuilder.addLocal)
"""
function _ensure_typeof_scratch_local!(ctx::AbstractCompilationContext)::UInt32
    if ctx.typeof_scratch_local !== nothing
        return ctx.typeof_scratch_local
    end
    # Allocate a new i32 local
    local_idx = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, I32)
    ctx.typeof_scratch_local = local_idx
    return local_idx
end

# Normalise BOTH narrow (sub-32-bit) operands on the stack before an i32 op
# that OBSERVES the full register width (div/rem). WasmTarget defers narrow-int
# normalisation: an i32 register may carry overflow junk above the Julia width
# (e.g. UInt8 0xa5 + 0xff = 0x1a4) which add/sub/mul/and/or don't care about —
# but div_u/rem_u divide the WIDE value (gap: div(0xa5 + x, 0x04)::UInt8 gave
# 0x69, native 0x29). Unsigned → mask to width; signed → sign-extend in
# register. Stack: [a, b] → [norm(a), norm(b)]. No-op for full-width operands.
"""
    _sub_builder(fb, ctx, name, n) -> InstrBuilder

A fragment that consumes the parent's top `n` stack values DECLARES them
(seeded from fb's TRACKED stack; append_builder! settles the contract exactly).
parity(quarantine: WT emits a function through fragment builders merged by append_builder!; dart emits a function into one builder.)
"""
function _sub_builder(fb::InstrBuilder, ctx::AbstractCompilationContext, name::String, n::Int;
                      narrow_to::Union{Nothing, WasmValType}=nothing,
                      seed_types::Union{Nothing, Vector{WasmValType}}=nothing)::InstrBuilder
    local b = _ctx_builder(ctx, name)
    local h = length(fb.v.stack)
    # fullstrict: when the parent's tracking is short, the caller's DECLARED types
    # are the contract (the parent's shortfall surfaces at ITS merge, attributed there)
    if n > 0 && h < n && seed_types !== nothing && length(seed_types) == n
        seed_input!(b, copy(seed_types))
        return b
    end
    if n > 0 && h >= n
        local seeds = WasmValType[fb.v.stack[h - n + i] for i in 1:n]
        seed_input!(b, seeds)
        # fullstrict: a helper that declares its operand WIDTH narrows erased seeds
        # AT ENTRY through the funnel (the erased-operand mismatches in the div/shift/
        # flipsign guards). Deeper-than-top seeds shuffle through a scratch.
        if narrow_to !== nothing
            for k in n:-1:1
                local st = seeds[k]
                if _wt_is_ref(st)
                    if k == n
                        coerce_stack_top!(b, narrow_to, ctx)
                    else
                        # rotate: store the above values, convert, restore
                        local _tmp = UInt32[]
                        for _ in (k+1):n
                            local t2 = UInt32(allocate_local!(ctx, narrow_to))
                            local_set!(b, t2); pushfirst!(_tmp, t2)
                        end
                        coerce_stack_top!(b, narrow_to, ctx)
                        for t2 in _tmp
                            local_get!(b, t2)
                        end
                    end
                    seeds[k] = narrow_to
                end
            end
        end
    end
    return b
end

# parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
function _emit_normalise_narrow_pair!(fb::InstrBuilder, ctx::AbstractCompilationContext,
                                      signed::Bool, julia_width::Int)::InstrBuilder
    julia_width < 32 || return fb
    bld = _sub_builder(fb, ctx, "_emit_normalise_narrow_pair!", 2)
    li = UInt32(allocate_local!(ctx, I32))
    # normalise_narrow! (julia_numeric_tier.jl) classifies width from a Type, not an
    # Int — synthesize a representative one; `normalise_narrow!` only reads its width
    # class (8 vs 16), never its own signedness, so Int8/UInt8 (and Int16/UInt16) are
    # interchangeable here.
    julia_type = julia_width == 8 ? (signed ? Int8 : UInt8) : (signed ? Int16 : UInt16)
    local_set!(bld, li)                              # [a]
    normalise_narrow!(bld, ctx, julia_type, signed)   # [a*]
    local_get!(bld, li)                               # [a*, b]
    normalise_narrow!(bld, ctx, julia_type, signed)   # [a*, b*]
    append_builder!(fb, bld)
    return fb
end

# Emit a catchable throw of a fieldless exception struct (e.g. DivideError):
# stash the instance in the $current_exn global, then `throw` tag 0 — the same
# mechanism explicit Julia `throw(...)` lowers to, so enclosing try_table
# handlers (and JS, for uncaught propagation) see a real exception, not a trap.
"""builder-native (THE implementation): build the error struct, stash, throw.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)"""
function _emit_throw_error_struct!(bld::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(ErrT))::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    info = register_struct_type!(ctx.mod, ctx.type_registry, ErrT)
    info === nothing && error("exception layout is unavailable for $ErrT")
    emit_struct_prefix!(bld, ctx.type_registry, ErrT, info)
    struct_new!(bld, info.wasm_type_idx)   # mod-resolved fields
    emit_throw_value!(bld, ctx.mod)   # typed (exn, trace) tag
    return bld
end

"""Emit Julia's exact `FieldError(type, field)` through the typed exception tag; `field` is
the name, or the operand that holds it at run time.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)"""
function _emit_field_error!(bld::InstrBuilder, ctx::AbstractCompilationContext,
                            @nospecialize(owner_type), field::Union{Symbol,NirNode})::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    info = register_struct_type!(ctx.mod, ctx.type_registry, FieldError)
    info === nothing && error("FieldError layout is unavailable")
    emit_struct_prefix!(bld, ctx.type_registry, FieldError, info)
    fields = ctx.mod.types[info.wasm_type_idx + 1].fields
    emit_value!(bld, NirLiteral(owner_type), ctx, fields[Int(info.field_offset) + 1].valtype;
                from_julia=DataType)
    emit_value!(bld, field isa Symbol ? NirLiteral(field) : field, ctx,
                fields[Int(info.field_offset) + 2].valtype; from_julia=Symbol)
    struct_new!(bld, info.wasm_type_idx)
    emit_throw_value!(bld, ctx.mod)
    return bld
end

"""
    _emit_getfield_runtime_name!(bld, ctx, idx, obj, name, T) -> Bool

`getfield(obj::T, name)` with a Symbol known only at run time, as jl_f_getfield answers it:
the field whose name equals `name`, compared in declaration order (jl_field_index), else
`FieldError(T, name)`. A type with no fields, or a Tuple (its field names are integers),
always throws. The value lands at the statement's type: a concrete statement type is every
field's own; otherwise each field is boxed into anyref by its field type. Where this read
cannot answer as Julia does, the statement rejects with the reason (true): a Module (its
getfield reads a global binding), a registered layout that does not hold Julia's fields in
Julia's order (DataType and TypeName are projections: reading by Julia's order would read
another field), a MemoryRef field (its read unpacks a pair). False, leaving the call to
reject, for a layout that is not a struct or fields of mixed types under a concrete statement
type.
parity(quarantine: jl_f_getfield with a runtime field name (builtins.c, jl_field_index); a dart member is selected statically or by a dynamic invocation forwarder's selector, never by a runtime name.)
"""
function _emit_getfield_runtime_name!(bld::InstrBuilder, ctx::AbstractCompilationContext, idx::Int,
                                      obj::NirNode, name::NirNode, T::DataType)::Bool
    local reject = (why::String) -> begin
        record_unsupported!(ctx, :unsupported_method, "getfield of a $(T) by a name known only at run time: $(why)";
                            idx=idx, detail=ctx.nir[idx].node)
        ctx.last_stmt_was_stub = true
        true
    end
    T === Module && return reject("a Module's getfield reads the global binding of that name, which WT does not look up at run time")
    local names = fieldcount(T) == 0 || T <: Tuple ? () : fieldnames(T)
    if isempty(names)
        local eb = _ctx_builder(ctx, "compile_call.fielderror")
        _emit_field_error!(eb, ctx, T, name)
        append_builder!(bld, eb)
        return true
    end
    is_struct_type(T) || return false
    local info = haskey(ctx.type_registry.structs, T) ? ctx.type_registry.structs[T] :
                 register_struct_type!(ctx.mod, ctx.type_registry, T)
    info === nothing && return false
    Tuple(info.field_names) == names ||
        return reject("WT's layout of $(T) holds $(join(info.field_names, ", ")), not Julia's fields $(join(names, ", ")) in order")
    local mref = findfirst(i -> fieldtype(T, i) <: Core.GenericMemoryRef, eachindex(names))
    mref === nothing || return reject("field $(names[mref]) is a MemoryRef, whose read unpacks a pair")
    local flds = ctx.mod.types[info.wasm_type_idx + 1].fields
    local R = get(ctx.ssa_types, idx, Any)
    local out = if isconcretetype(R)
        all(i -> fieldtype(T, i) === R, eachindex(names)) || return false
        flds[Int(info.field_offset) + 1].valtype
    else
        AnyRef
    end
    local ib = _ctx_builder(ctx, "compile_call.getfield_runtime_name")
    for (i, fname) in enumerate(names)
        append_builder!(ib, compile_string_equal_b(name, NirLiteral(fname), ctx))
        if_!(ib; results=WasmValType[out])
        local wfi = wasm_field_idx(info, i)
        emit_value!(ib, obj, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
        struct_get!(ib, info.wasm_type_idx, wfi, flds[Int(wfi) + 1].valtype)
        out === AnyRef && coerce_stack_top!(ib, AnyRef, ctx; from_julia=fieldtype(T, i))
        else_!(ib)
    end
    _emit_field_error!(ib, ctx, T, name)
    for _ in names
        end_block!(ib)
    end
    append_builder!(bld, ib)
    return true
end

"""Throw exact `BoundsError((varargs...), i)` for a specialized vararg slot.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)"""
function _emit_vararg_bounds_error!(bld::InstrBuilder, ctx::AbstractCompilationContext,
                                    arg_types::Tuple, physical_offset::Integer,
                                    index_local::Integer)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    tuple_type = Tuple{arg_types...}
    tuple_info = haskey(ctx.type_registry.structs, tuple_type) ?
                 ctx.type_registry.structs[tuple_type] :
                 register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
    error_info = register_struct_type!(ctx.mod, ctx.type_registry, BoundsError)
    error_info === nothing && error("BoundsError layout is unavailable")
    emit_struct_prefix!(bld, ctx.type_registry, BoundsError, error_info)
    emit_struct_prefix!(bld, ctx.type_registry, tuple_type, tuple_info)
    for (i, T) in enumerate(arg_types)
        local_get!(bld, physical_offset + i - 1)
    end
    struct_new!(bld, tuple_info.wasm_type_idx)
    coerce_stack_top!(bld, AnyRef, ctx; from_julia=tuple_type)
    local_get!(bld, index_local)
    coerce_stack_top!(bld, AnyRef, ctx; from_julia=Int64)
    struct_new!(bld, error_info.wasm_type_idx)
    emit_throw_value!(bld, ctx.mod)
    return bld
end

"""
    _emit_fpiseq!(b, ctx, t)

Julia's `fpiseq` (`isequal` of two floats of wasm type `t`, runtime_intrinsics.c): the two
values' bits are equal, or both are NaN — so 0.0 and -0.0 differ and any NaN equals any NaN.
parity(intrinsics.dart:1409 StaticIntrinsic.identical): dart's `identical` of two doubles
compares their bits (i64.reinterpret_f64, i64.eq); Julia's rule adds the NaN clause.
"""
function _emit_fpiseq!(b::InstrBuilder, ctx::AbstractCompilationContext, t::WasmValType)::Nothing
    local wide = t === F64
    local la = UInt32(allocate_local!(ctx, t))
    local lb = UInt32(allocate_local!(ctx, t))
    local_set!(b, lb); local_set!(b, la)
    local_get!(b, la); local_get!(b, la); num!(b, wide ? Opcode.F64_NE : Opcode.F32_NE)   # isnan(a)
    local_get!(b, lb); local_get!(b, lb); num!(b, wide ? Opcode.F64_NE : Opcode.F32_NE)   # isnan(b)
    num!(b, Opcode.I32_AND)
    local_get!(b, la); num!(b, wide ? Opcode.I64_REINTERPRET_F64 : Opcode.I32_REINTERPRET_F32)
    local_get!(b, lb); num!(b, wide ? Opcode.I64_REINTERPRET_F64 : Opcode.I32_REINTERPRET_F32)
    num!(b, wide ? Opcode.I64_EQ : Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)
    return nothing
end

"""
    _emit_storage_pointer_offset!(b, ctx, ptr, index, source, step) -> Nothing

The byte offset, as an i32, that `pointerref(ptr, index, align)` / `pointerset(ptr, x, index,
align)` reaches inside the storage object `source` its pointer was traced to
(`_trace_memmove_ptr`). A storage pointer's value is its object's base plus a byte offset --
1 for a String's or Symbol's bytes (`_fc_jl_string_ptr!`: a match at offset 0 is never NULL),
0 for a Memory's -- and add_ptr/sub_ptr compile to arithmetic on that value, so the offset is
`ptr - base + (index - 1) * step`, `step` being the size of the pointer's element type (Julia's
`pointerref` addresses `ptr + (index - 1) * sizeof(T)`). Every pointer load and store arm reads
it here: they computed it apiece, and one ignored `index` while another read a String pointer
by pattern-matching one add_ptr step.
parity(quarantine: Julia's pointer intrinsics; dart has no raw pointers outside dart:ffi, and
WasmArrayExt.copy/fill take an array and an element offset, intrinsics.dart:1255/:1279.)
"""
function _emit_storage_pointer_offset!(b::InstrBuilder, ctx::AbstractCompilationContext,
                                       ptr::NirNode, index, source::NirNode, step::Int)::Nothing
    emit_value!(b, ptr, ctx, I64)
    local src_type = get_ssa_type(ctx, source)
    (src_type === String || src_type === Symbol) && (i64_const!(b, 1); num!(b, Opcode.I64_SUB))
    if index !== nothing && !(nir_const(index) isa Integer && nir_const(index) == 1)
        emit_value!(b, index, ctx, I64)
        i64_const!(b, Int64(1))
        num!(b, Opcode.I64_SUB)
        if step != 1
            i64_const!(b, Int64(step))
            num!(b, Opcode.I64_MUL)
        end
        num!(b, Opcode.I64_ADD)
    end
    num!(b, Opcode.I32_WRAP_I64)
    return nothing
end

# Guard an integer div/rem so Julia-visible error cases THROW (catchable
# DivideError) instead of reaching the wasm instruction's uncatchable trap:
#   * divisor == 0                  → DivideError   (div_s/div_u/rem_s/rem_u trap)
#   * sdiv typemin(width) ÷ -1      → DivideError   (i32/i64.div_s traps at full
#     width; at narrow widths — Int8/Int16 in an i32 register — wasm computes
#     2^(w-1) silently, so the guard is also a *value* soundness fix)
# rem_s(typemin, -1) is defined as 0 in wasm — matches Julia — so `check_overflow`
# is only set for signed div. Stack: [a, b] → [a, b] (operands re-pushed; values
# must already be narrow-normalised).
# parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
function _emit_div_guard!(fb::InstrBuilder, ctx::AbstractCompilationContext, is32::Bool;
                          check_overflow::Bool=false, julia_width::Int=(is32 ? 32 : 64))::InstrBuilder
    lt     = is32 ? I32 : I64
    wconst!(blr, v) = is32 ? i32_const!(blr, v) : i64_const!(blr, v)
    weqz   = is32 ? Opcode.I32_EQZ : Opcode.I64_EQZ
    weq    = is32 ? Opcode.I32_EQ : Opcode.I64_EQ
    la = UInt32(allocate_local!(ctx, lt))
    lb = UInt32(allocate_local!(ctx, lt))
    bld = _sub_builder(fb, ctx, "_emit_div_guard!", 2; narrow_to=(is32 ? I32 : I64))
    local_set!(bld, lb)  # [a]
    local_set!(bld, la)  # []
    # b == 0 → throw DivideError
    local_get!(bld, lb)
    num!(bld, weqz)
    if_!(bld)
    _emit_throw_error_struct!(bld, ctx, DivideError)
    end_block!(bld)
    if check_overflow
        # a == typemin(width) && b == -1 → throw DivideError
        tmin = julia_width >= 64 ? typemin(Int64) : -(Int64(1) << (julia_width - 1))
        local_get!(bld, la)
        wconst!(bld, tmin)
        num!(bld, weq)
        local_get!(bld, lb)
        wconst!(bld, -1)
        num!(bld, weq)
        num!(bld, Opcode.I32_AND)
        if_!(bld)
        _emit_throw_error_struct!(bld, ctx, DivideError)
        end_block!(bld)
    end
    local_get!(bld, la)
    local_get!(bld, lb)
    append_builder!(fb, bld)
    return fb
end

# Emit a Julia-semantics shift. Stack on entry: [value, shift] (same wasm type).
# Julia's shl_int/lshr_int yield 0 and ashr_int yields sign-fill when the shift
# amount ≥ bitwidth, whereas wasm's shifts mask the amount to `mod bitwidth`
# (so e.g. `1 << 64` is 1 in raw wasm but 0 in Julia). We guard:
#   shl/lshr:  (shift < width) ? (value <op> shift) : 0
#   ashr:      value >>s (shift < width ? shift : width-1)   (clamp → sign-fill)
# Bit width of the Julia integer operand being shifted (8/16/32/64). Falls back to
# the wasm register width for non-concrete / non-bitsinteger operand types so the
# guard is a no-op (behaviour unchanged) unless we positively know it's narrow.
# parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
function _julia_int_width(@nospecialize(T), is32::Bool)::Int64
    if T isa Type && isconcretetype(T) && T <: Base.BitInteger
        return sizeof(T) * 8
    end
    return is32 ? 32 : 64
end

# `julia_width` is the Julia operand's bit width (8/16/32/64). It can be NARROWER
# than the wasm representation width (UInt8/UInt16/Int8/Int16 all live in an i32).
# Two corrections are needed when julia_width < wasm width, both for `<<`:
#   * over-shift threshold must be julia_width, not the wasm width — Julia yields 0
#     once shift ≥ julia_width (wasm's i32.shl also masks the *amount* mod 32, so a
#     shift of exactly 32/64 would otherwise wrap to a no-op and leak the value); and
#   * the shl result must be truncated to julia_width bits (e.g. `UInt8(1) << 8` is
#     0 in Julia but 256 in a raw i32), since high bits spill into the wide register.
# Right shifts (lshr/ashr) OBSERVE the high bits of the register, so a narrow
# operand must be normalised first: arithmetic on Int8/16/UInt8/16 leaves junk
# above julia_width (e.g. `x+x` for UInt8 0x80 is 0x100 in the i32 register), and
# that junk would shift down into the result. We zero-mask before lshr and
# sign-extend from julia_width before ashr; lshr also honours the julia_width
# over-shift threshold (shr_u of a width-bit value by ≥ width = 0).
# parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
function _emit_shift_guarded!(fb::InstrBuilder, ctx::AbstractCompilationContext, is32::Bool, kind::Symbol;
                              julia_width::Int = (is32 ? 32 : 64), signed_narrow::Bool = false)::InstrBuilder
    wltu   = is32 ? Opcode.I32_LT_U : Opcode.I64_LT_U
    wand   = is32 ? Opcode.I32_AND : Opcode.I64_AND
    width  = is32 ? 32 : 64
    thr    = clamp(julia_width, 1, width)        # over-shift threshold (Julia width)
    narrow = thr < width                          # operand narrower than its wasm reg
    sl     = UInt32(allocate_local!(ctx, is32 ? I32 : I64))
    shop   = kind === :shl  ? (is32 ? Opcode.I32_SHL : Opcode.I64_SHL) :
             kind === :lshr ? (is32 ? Opcode.I32_SHR_U : Opcode.I64_SHR_U) :
                              (is32 ? Opcode.I32_SHR_S : Opcode.I64_SHR_S)
    bld = _sub_builder(fb, ctx, "_emit_shift_guarded!", 2; narrow_to=(is32 ? I32 : I64))
    _lset(op, i) = op === Opcode.LOCAL_SET ? local_set!(bld, i) :
                   op === Opcode.LOCAL_TEE ? local_tee!(bld, i) : local_get!(bld, i)
    _wc(v) = is32 ? i32_const!(bld, Int64(v)) : i64_const!(bld, Int64(v))
    if narrow && (kind === :lshr || (kind === :ashr && is32 && (thr == 8 || thr == 16)))
        # Normalise the value (under the shift amount): stash shift, fix value, restore.
        _lset(Opcode.LOCAL_SET, sl)              # [value]
        if kind === :lshr
            _wc((Int64(1) << thr) - 1)
            num!(bld, wand)                      # zero out junk above julia_width
        else  # ashr: replicate bit thr-1 upward so shr_s sign-fills correctly
            num!(bld, thr == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
        end
        _lset(Opcode.LOCAL_GET, sl)              # [value', shift]
    end
    if kind === :ashr
        # [value, shift] → [value, clamped] → shr_s   (sign-fill semantics unchanged)
        _lset(Opcode.LOCAL_SET, sl)              # [value]
        _lset(Opcode.LOCAL_GET, sl)              # [value, shift]        (a = shift)
        _wc(width - 1)                           # [value, shift, w-1]   (b = w-1)
        _lset(Opcode.LOCAL_GET, sl)              # [value, shift, w-1, shift]
        _wc(width)                               # [..., width]
        num!(bld, wltu)                          # [value, shift, w-1, cond]
        select!(bld, is32 ? I32 : I64)           # [value, cond? shift : w-1]
        num!(bld, shop)                          # [value >>s clamped]
    else
        # [value, shift] → [result] → select(result, 0, shift < thr)
        _lset(Opcode.LOCAL_TEE, sl)              # [value, shift]  (shift saved)
        num!(bld, shop)                          # [result]
        _wc(0)                                   # [result, 0]
        _lset(Opcode.LOCAL_GET, sl)              # [result, 0, shift]
        _wc(thr)                                 # [result, 0, shift, thr]
        num!(bld, wltu)                          # [result, 0, cond]
        select!(bld, is32 ? I32 : I64)           # [cond? result : 0]
        if narrow && (kind === :shl || (kind === :lshr && signed_narrow))
            # P3 (found probing da22976c7cd6): a SIGNED narrow result must be
            # re-sign-extended, not zero-masked — `Int8(-1) << 0` masked to
            # 0xFF read back as 255. extend8_s/16_s ignores the spilled high
            # bits, so it replaces the mask. lshr needs it too: the shifted
            # bits are width-canonical but bit thr-1 can be set (shift 0 of
            # 0x80 → Int8 -128, not 128).
            if signed_narrow && is32 && (thr == 8 || thr == 16)
                num!(bld, thr == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
            elseif kind === :shl
                _wc((Int64(1) << thr) - 1)       # [result, mask]  (2^width - 1)
                num!(bld, wand)                  # [result & mask]  truncate to width
            end
        end
    end
    append_builder!(fb, bld)
    return fb
end

# Narrow an i64 shift AMOUNT to i32 for an i32-represented value, SATURATING any
# out-of-range amount (≥ julia_width, unsigned) to julia_width so the over-shift
# guard maps it to 0. A plain I32_WRAP_I64 drops the amount's high bits, so a huge
# shift like `x << typemin(Int64)` (low 32 bits = 0) would wrap to a no-op and leak
# the unshifted value. Stack: [.., amount_i64] → [.., amount_i32].
# parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
function _emit_wrap_shift_amount_saturating!(fb::InstrBuilder, ctx::AbstractCompilationContext, julia_width::Int)::InstrBuilder
    amt = UInt32(allocate_local!(ctx, I64))
    bld = _sub_builder(fb, ctx, "_emit_wrap_shift_amount_saturating!", 1)
    local_tee!(bld, amt)                         # [amount]
    i64_const!(bld, Int64(julia_width))          # [amount, jw]
    local_get!(bld, amt)                         # [amount, jw, amount]
    i64_const!(bld, Int64(julia_width))          # [amount, jw, amount, jw]
    num!(bld, Opcode.I64_LT_U)                   # [amount, jw, cond]   cond = amount <u jw
    select!(bld, I64)                            # [cond ? amount : jw]
    num!(bld, Opcode.I32_WRAP_I64)               # [amount_i32]
    append_builder!(fb, bld)
    return fb
end

"""
Emit WASM instructions to convert a Char codepoint (on stack) to Julia's raw UInt32 bits.
Julia stores Char as UTF-8 bytes in the high positions of a UInt32:
  ASCII '+' (cp=43): raw=0x2B000000
  2-byte 'é' (cp=233): raw=0xC3A90000
  3-byte '中' (cp=20013): raw=0xE4B8AD00
  4-byte '😀' (cp=128512): raw=0xF09F9880
Assumes codepoint i32 is on top of the stack. Leaves raw bits i32 on stack.
parity(quarantine: a Julia Char is its UTF-8 bytes left-aligned in a UInt32; dart's strings are UTF-16 code units.)
"""
function emit_char_codepoint_to_rawbits(ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder. Consumes [codepoint:i32] from the stack, pushes [rawbits:i32].
    b = InstrBuilder(; func_name="emit_char_codepoint_to_rawbits", mod=ctx.mod)
    seed_input!(b, WasmValType[I32])
    cp_local = UInt32(allocate_local!(ctx, I32))
    result_local = UInt32(allocate_local!(ctx, I32))
    builder_set_local_type!(b, cp_local, I32)
    builder_set_local_type!(b, result_local, I32)

    # Store codepoint
    local_set!(b, cp_local)

    # if (cp < 0x80) — ASCII: result = cp << 24
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x80))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    local_get!(b, cp_local)
    i32_const!(b, Int32(24))
    num!(b, Opcode.I32_SHL)
    local_set!(b, result_local)
    else_!(b)

    # if (cp < 0x800) — 2-byte
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x800))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    # ((0xC0 | (cp >> 6)) << 24) | ((0x80 | (cp & 0x3F)) << 16)
    i32_const!(b, Int32(0xC0))
    local_get!(b, cp_local)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHR_U)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(24))
    num!(b, Opcode.I32_SHL)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)
    else_!(b)

    # if (cp < 0x10000) — 3-byte
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x10000))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    # ((0xE0|(cp>>12))<<24) | ((0x80|((cp>>6)&0x3F))<<16) | ((0x80|(cp&0x3F))<<8)
    i32_const!(b, Int32(0xE0))
    local_get!(b, cp_local)
    i32_const!(b, Int32(12))
    num!(b, Opcode.I32_SHR_U)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(24))
    num!(b, Opcode.I32_SHL)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(8))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)
    else_!(b)

    # 4-byte: ((0xF0|(cp>>18))<<24) | ((0x80|((cp>>12)&0x3F))<<16) | ((0x80|((cp>>6)&0x3F))<<8) | (0x80|(cp&0x3F))
    i32_const!(b, Int32(0xF0))
    local_get!(b, cp_local)
    i32_const!(b, Int32(18))
    num!(b, Opcode.I32_SHR_U)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(24))
    num!(b, Opcode.I32_SHL)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(12))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(8))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    i32_const!(b, Int32(0x80))
    local_get!(b, cp_local)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)

    end_block!(b)  # end 3-byte else (4-byte)
    end_block!(b)  # end 2-byte else
    end_block!(b)  # end ASCII else

    local_get!(b, result_local)
    return builder_code(b)
end

"""
Emit WASM instructions to convert Julia's raw UInt32 Char bits (on stack) to a codepoint.
Reverse of emit_char_codepoint_to_rawbits.
parity(quarantine: a Julia Char is its UTF-8 bytes left-aligned in a UInt32; dart's strings are UTF-16 code units.)
"""
function emit_char_rawbits_to_codepoint(ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder. Consumes [rawbits:i32] from the stack, pushes [codepoint:i32].
    b = InstrBuilder(; func_name="emit_char_rawbits_to_codepoint", mod=ctx.mod)
    seed_input!(b, WasmValType[I32])
    raw_local = UInt32(allocate_local!(ctx, I32))
    result_local = UInt32(allocate_local!(ctx, I32))
    builder_set_local_type!(b, raw_local, I32)
    builder_set_local_type!(b, result_local, I32)

    local_set!(b, raw_local)

    # byte1 = raw >> 24
    local_get!(b, raw_local)
    i32_const!(b, Int32(24))
    num!(b, Opcode.I32_SHR_U)
    local_set!(b, result_local)

    # if byte1 < 0x80 — ASCII
    local_get!(b, result_local)
    i32_const!(b, Int32(0x80))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    # result already = byte1
    else_!(b)

    # if byte1 < 0xE0 — 2-byte
    local_get!(b, result_local)
    i32_const!(b, Int32(0xE0))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    # ((byte1 & 0x1F) << 6) | ((raw >> 16) & 0x3F)
    local_get!(b, result_local)
    i32_const!(b, Int32(0x1F))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHL)
    local_get!(b, raw_local)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)
    else_!(b)

    # if byte1 < 0xF0 — 3-byte
    local_get!(b, result_local)
    i32_const!(b, Int32(0xF0))
    num!(b, Opcode.I32_LT_U)
    if_!(b)
    # ((b1&0xF)<<12) | (((raw>>16)&0x3F)<<6) | ((raw>>8)&0x3F)
    local_get!(b, result_local)
    i32_const!(b, Int32(0x0F))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(12))
    num!(b, Opcode.I32_SHL)
    local_get!(b, raw_local)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    local_get!(b, raw_local)
    i32_const!(b, Int32(8))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)
    else_!(b)

    # 4-byte: ((b1&0x7)<<18) | (((raw>>16)&0x3F)<<12) | (((raw>>8)&0x3F)<<6) | (raw&0x3F)
    local_get!(b, result_local)
    i32_const!(b, Int32(0x07))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(18))
    num!(b, Opcode.I32_SHL)
    local_get!(b, raw_local)
    i32_const!(b, Int32(16))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(12))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    local_get!(b, raw_local)
    i32_const!(b, Int32(8))
    num!(b, Opcode.I32_SHR_U)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    i32_const!(b, Int32(6))
    num!(b, Opcode.I32_SHL)
    num!(b, Opcode.I32_OR)
    local_get!(b, raw_local)
    i32_const!(b, Int32(0x3F))
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    local_set!(b, result_local)

    end_block!(b)  # end 3-byte else (4-byte)
    end_block!(b)  # end 2-byte else
    end_block!(b)  # end ASCII else

    local_get!(b, result_local)
    return builder_code(b)
end

"""
    _compile_call_checked_narrow!(fb, ctx, op, arg_type, is_32bit)

Extracted handler for checked_s{add,sub,mul}_int / checked_u{add,sub,mul}_int
when the JULIA operand width is < 32 bits (Int8/UInt8/Int16/UInt16). The
register-width overflow tricks in `_compile_call_checked_add!`/`_sub!`/
`_compile_call_checked_mul` detect overflow with sign-bit tests at bit 31/63 —
a narrow op can never overflow the wide i32 register, so the flag would stay
false (e.g. `checked_abs(Int8(-128))` used to leak 128 instead of throwing
OverflowError — the `lcm(Int8(-128), 1)` divergent_throw family). Computed in
i32 on normalised inputs; flag = result fails the sign/zero-extend round-trip
at the JULIA width; value = wrapped result. A pure move of the arm that used
to gate the head of the `is_func` ladder (was a combined `if is_32bit &&
_julia_int_width(...) < 32 && (is_func(...) || ...)`, checked before any of
checked_sadd/ssub/smul_int's own branches). `op` is the ALREADY-DISPATCHED
CHECKED_OPS key (R19: a data test against the Symbol the registry looked up
by, not a re-derivation via `is_func`).
parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
"""
function _compile_call_checked_narrow!(fb::InstrBuilder, ctx::AbstractCompilationContext,
                                       op::Symbol, arg_type, is_32bit::Bool, _nc_tt::Type)::Nothing
    local _ncw = _julia_int_width(arg_type, is_32bit)
    local _nc_signed = op === :checked_sadd_int || op === :checked_ssub_int ||
                       op === :checked_smul_int
    local _nc_op = (op === :checked_sadd_int || op === :checked_uadd_int) ? Opcode.I32_ADD :
                   (op === :checked_ssub_int || op === :checked_usub_int) ? Opcode.I32_SUB :
                   Opcode.I32_MUL
    _emit_normalise_narrow_pair!(fb, ctx, _nc_signed, _ncw)
    local _nc_r = UInt32(allocate_local!(ctx, I32))
    local _ncb = _sub_builder(fb, ctx, "compile_call", 2)   # [a*, b*] normalised pair
    num!(_ncb, _nc_op)
    local_set!(_ncb, _nc_r)
    # helper: push wrapped-to-width copy of result
    local _nc_norm! = function ()
        local_get!(_ncb, _nc_r)
        if _nc_signed
            num!(_ncb, _ncw == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
        else
            i32_const!(_ncb, Int64((1 << _ncw) - 1))
            num!(_ncb, Opcode.I32_AND)
        end
    end
    if !haskey(ctx.type_registry.structs, _nc_tt)
        register_tuple_type!(ctx.mod, ctx.type_registry, _nc_tt)
    end
    local _nc_info = ctx.type_registry.structs[_nc_tt]
    emit_struct_prefix!(_ncb, ctx.type_registry, _nc_tt, _nc_info)
    _nc_norm!()                                           # field 1: wrapped value
    _nc_norm!()                                           # flag: wrapped != raw
    local_get!(_ncb, _nc_r)
    num!(_ncb, Opcode.I32_NE)
    struct_new!(_ncb, _nc_info.wasm_type_idx)   # mod-resolved fields
    append_builder!(fb, _ncb)
    return nothing
end

"""
    _compile_call_checked_add!(fbref, ctx, op, is_128bit, is_32bit, idx)

Extracted handler for checked_sadd_int / checked_uadd_int (register-width
path — narrow width routes through `_compile_call_checked_narrow!` instead).
checked_sadd_int(a, b) -> Tuple{T, Bool} (result, overflow_flag). Overflow
detection: ((a ^ result) & (b ^ result)) has sign bit set. `fbref` is a
`Ref{InstrBuilder}` (not a plain `fb`) because the is_128bit branch REPLACES
the builder with a fresh stub-only one — exactly as the original inline `fb =
_ctx_builder(...)` reassignment did (a plain argument can only be appended
to, not swapped out from under the caller). `op` is the ALREADY-DISPATCHED
CHECKED_OPS key — a data test, not a re-derivation via `is_func`.
parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
"""
function _compile_call_checked_add!(fbref::Base.RefValue{InstrBuilder}, ctx::AbstractCompilationContext,
                                    op::Symbol, is_128bit::Bool, is_32bit::Bool, idx::Int, _cadd_tt::Type)::Nothing
    if is_128bit
        local _cadd128 = _ctx_builder(ctx, "compile_call.frag")
        emit_unsupported_stub!(ctx, _cadd128, :unsupported_method,
            "128-bit checked addition (Int128/UInt128)"; idx=idx)
        fbref[] = _cadd128
    else
        is_signed = op === :checked_sadd_int
        local_type = is_32bit ? I32 : I64
        local_a = allocate_local!(ctx, local_type)
        local_b = allocate_local!(ctx, local_type)
        local_result = allocate_local!(ctx, local_type)
        local _caddb = _sub_builder(fbref[], ctx, "compile_call", 2)   # [a, b]

        # Save b, save a, compute a+b, save result
        local_set!(_caddb, local_b)
        local_tee!(_caddb, local_a)
        local_get!(_caddb, local_b)
        num!(_caddb, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
        local_set!(_caddb, local_result)

        local _cadd_info = haskey(ctx.type_registry.structs, _cadd_tt) ?
                           ctx.type_registry.structs[_cadd_tt] :
                           register_tuple_type!(ctx.mod, ctx.type_registry, _cadd_tt)
        emit_struct_prefix!(_caddb, ctx.type_registry, _cadd_tt, _cadd_info)
        # Push result back for tuple field 1
        local_get!(_caddb, local_result)

        # Compute overflow flag
        if is_signed
            # Signed: overflow = ((a ^ result) & (b ^ result)) >> (bits-1)
            local_get!(_caddb, local_a)
            local_get!(_caddb, local_result)
            num!(_caddb, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
            local_get!(_caddb, local_b)
            local_get!(_caddb, local_result)
            num!(_caddb, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
            num!(_caddb, is_32bit ? Opcode.I32_AND : Opcode.I64_AND)
            if is_32bit
                i32_const!(_caddb, 31)
                num!(_caddb, Opcode.I32_SHR_U)
            else
                i64_const!(_caddb, 63)
                num!(_caddb, Opcode.I64_SHR_U)
                num!(_caddb, Opcode.I32_WRAP_I64)
            end
        else
            # Unsigned: overflow = result < a
            local_get!(_caddb, local_result)
            local_get!(_caddb, local_a)
            num!(_caddb, is_32bit ? Opcode.I32_LT_U : Opcode.I64_LT_U)
        end

        struct_new!(_caddb, _cadd_info.wasm_type_idx)   # mod-resolved fields
        append_builder!(fbref[], _caddb)
    end
    return nothing
end

"""
    _compile_call_checked_sub!(fbref, ctx, op, is_128bit, is_32bit, idx)

Extracted handler for checked_ssub_int / checked_usub_int (register-width
path — narrow width routes through `_compile_call_checked_narrow!` instead).
checked_ssub_int(a, b) -> Tuple{T, Bool}. Signed overflow: ((a ^ b) & (a ^
result)) has sign bit set. Same `Ref{InstrBuilder}` reassignment need as
`_compile_call_checked_add!` — see its docstring. `op` is the ALREADY-
DISPATCHED CHECKED_OPS key — a data test, not a re-derivation via `is_func`.
parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
"""
function _compile_call_checked_sub!(fbref::Base.RefValue{InstrBuilder}, ctx::AbstractCompilationContext,
                                    op::Symbol, is_128bit::Bool, is_32bit::Bool, idx::Int, _csub_tt::Type)::Nothing
    if is_128bit
        local _csub128 = _ctx_builder(ctx, "compile_call.frag")
        emit_unsupported_stub!(ctx, _csub128, :unsupported_method,
            "128-bit checked subtraction (Int128/UInt128)"; idx=idx)
        fbref[] = _csub128
    else
        is_signed = op === :checked_ssub_int
        local_type = is_32bit ? I32 : I64
        local_a = allocate_local!(ctx, local_type)
        local_b = allocate_local!(ctx, local_type)
        local_result = allocate_local!(ctx, local_type)
        local _csubb = _sub_builder(fbref[], ctx, "compile_call", 2)   # [a, b]

        # Save b, save a, compute a-b, save result
        local_set!(_csubb, local_b)
        local_tee!(_csubb, local_a)
        local_get!(_csubb, local_b)
        num!(_csubb, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
        local_set!(_csubb, local_result)

        local _csub_info = haskey(ctx.type_registry.structs, _csub_tt) ?
                           ctx.type_registry.structs[_csub_tt] :
                           register_tuple_type!(ctx.mod, ctx.type_registry, _csub_tt)
        emit_struct_prefix!(_csubb, ctx.type_registry, _csub_tt, _csub_info)
        # Push result back for tuple field 1
        local_get!(_csubb, local_result)

        if is_signed
            # Signed: overflow = ((a ^ b) & (a ^ result)) >> (bits-1)
            local_get!(_csubb, local_a)
            local_get!(_csubb, local_b)
            num!(_csubb, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
            local_get!(_csubb, local_a)
            local_get!(_csubb, local_result)
            num!(_csubb, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
            num!(_csubb, is_32bit ? Opcode.I32_AND : Opcode.I64_AND)
            if is_32bit
                i32_const!(_csubb, 31)
                num!(_csubb, Opcode.I32_SHR_U)
            else
                i64_const!(_csubb, 63)
                num!(_csubb, Opcode.I64_SHR_U)
                num!(_csubb, Opcode.I32_WRAP_I64)
            end
        else
            # Unsigned: overflow = a < b
            local_get!(_csubb, local_a)
            local_get!(_csubb, local_b)
            num!(_csubb, is_32bit ? Opcode.I32_LT_U : Opcode.I64_LT_U)
        end

        struct_new!(_csubb, _csub_info.wasm_type_idx)   # mod-resolved fields
        append_builder!(fbref[], _csubb)
    end
    return nothing
end

"""
    _compile_call_checked!(fbref, ctx, op, args, is_128bit, is_32bit, arg_type, idx) -> WasmValType

THE checked-overflow dispatch — CHECKED_OPS's single implementation (all 6
keys forward here). `op` is the Symbol CHECKED_OPS was already keyed and
dispatched on (R19: a data test against that Symbol, never a re-derivation
via `is_func` — the Dict lookup in `emit_julia_numeric!` is the one place op
identity is decided). Narrow Julia widths route through
`_compile_call_checked_narrow!` first (checked BEFORE add/sub/mul dispatch,
exactly as the original combined `if` guard did); mul goes through the
pre-existing `_compile_call_checked_mul` unchanged (its is_128bit branch
stubs on the EXISTING builder, unlike add/sub's fresh-builder discard — a
pre-existing asymmetry, preserved as-is, not unified).
parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
"""
function _compile_call_checked!(fbref::Base.RefValue{InstrBuilder}, ctx::AbstractCompilationContext,
                                op::Symbol, args, is_128bit::Bool, is_32bit::Bool, arg_type, idx::Int)::WasmValType
    # The result is Julia's `Tuple{T, Bool}` for the OPERAND type T — the statement's own
    # inferred type, never a register-width stand-in (Tuple{Int64,Bool} for a UInt64 add
    # carried the wrong classId; the closed-world numbering rejects it).
    local _tt = get(ctx.ssa_types, idx, nothing)
    if !(_tt isa DataType && _tt <: Tuple && length(_tt.parameters) == 2 &&
         _tt.parameters[2] === Bool && _tt.parameters[1] === arg_type)
        _tt = Tuple{arg_type, Bool}
    end
    local _narrow = is_32bit && _julia_int_width(arg_type, is_32bit) < 32
    if _narrow
        _compile_call_checked_narrow!(fbref[], ctx, op, arg_type, is_32bit, _tt)
    elseif op === :checked_smul_int || op === :checked_umul_int
        _compile_call_checked_mul(op, args, fbref[], ctx, is_128bit, is_32bit, _tt)
    elseif op === :checked_sadd_int || op === :checked_uadd_int
        _compile_call_checked_add!(fbref, ctx, op, is_128bit, is_32bit, idx, _tt)
    else
        _compile_call_checked_sub!(fbref, ctx, op, is_128bit, is_32bit, idx, _tt)
    end
    return ConcreteRef(UInt32(ctx.type_registry.structs[_tt].wasm_type_idx), true)
end

"""
    _compile_call_shift!(fb, ctx, args, arg_type, is_32bit, kind) -> WasmValType

THE shift dispatch — SHIFT_OPS's single implementation for `:shl`/`:ashr`/
`:lshr` (128-bit operands are fully handled by THE Int128 registry route
before this is ever reached). Shift-COUNT coercion first (Julia often uses an
Int64/UInt64 amount even for an Int32 value — Wasm requires the amount and
the value to share a type): shl/lshr saturate an oversized i64 amount down to
i32 (a plain wrap would let e.g. `x << typemin(Int64)` alias 0 and leak the
unshifted value); ashr just wraps (its guard clamps the amount anyway). Then
`_emit_shift_guarded!` applies Julia's over-shift/sign-fill semantics.
parity(quarantine: Julia's integer intrinsics: an 8- or 16-bit integer rides in an i32 register with junk above its width, division throws DivideError, a shift of the width or more is 0 or sign-fill; dart's ints are 64-bit and its ~/ calls a runtime function, intrinsics.dart:457.)
"""
function _compile_call_shift!(fb::InstrBuilder, ctx::AbstractCompilationContext, args, arg_type,
                              is_32bit::Bool, kind::Symbol)::WasmValType
    if length(args) >= 2
        # the amount's emitted width is the builder's tracked stack top (a 128-bit
        # amount is a struct and is left to the Int128 route)
        local _cnt = isempty(fb.v.stack) ? nothing : fb.v.stack[end]
        local _want = is_32bit ? I32 : I64
        if _cnt === I32 || _cnt === I64
            if kind !== :ashr && is_32bit && _cnt === I64
                _emit_wrap_shift_amount_saturating!(fb, ctx, _julia_int_width(arg_type, is_32bit))
            else
                coerce_stack_top!(fb, _want, ctx)
            end
        end
    end
    if kind === :shl
        _emit_shift_guarded!(fb, ctx, is_32bit, :shl;
                             julia_width = _julia_int_width(arg_type, is_32bit),
                             signed_narrow = arg_type isa Type && arg_type <: Signed)   # over-shift → 0 + narrow truncation
    elseif kind === :ashr
        _emit_shift_guarded!(fb, ctx, is_32bit, :ashr;
                             julia_width = _julia_int_width(arg_type, is_32bit))   # over-shift → sign-fill; narrow input sign-extended
    else
        _emit_shift_guarded!(fb, ctx, is_32bit, :lshr;
                             julia_width = _julia_int_width(arg_type, is_32bit),
                             signed_narrow = arg_type isa Type && arg_type <: Signed)   # over-shift → 0 (Julia semantics)
    end
    return is_32bit ? I32 : I64
end

"""
    _compile_call_bswap!(fb, ctx, is_128bit, is_32bit, idx) -> WasmValType

Extracted handler for `bswap_int`. WebAssembly has no native bswap —
implemented with bit manipulation. 128-bit is a loud reject (the i64
reversal sequence would run on a struct value → invalid wasm); the reject
already early-returns from `compile_call!` in the original arm (mirrored
here via the nullable-return funnel instead — MISC_OPS's caller returns
immediately on any non-`nothing` result either way, so the observable
control flow is identical).
parity(quarantine: Julia's bswap_int intrinsic has no dart counterpart; dart2wasm's
low-level switch, intrinsics.dart:710-929, has no byte-swap entry.)
"""
function _compile_call_bswap!(fb::InstrBuilder, ctx::AbstractCompilationContext,
                              is_128bit::Bool, is_32bit::Bool, idx::Int)::WasmValType
    # a 128-bit operand is INT128_OPS's (emit_int128_bswap!), consulted before this registry
    is_128bit && error("_compile_call_bswap!: a 128-bit bswap_int reached the misc registry")
    # The swap reverses exactly the value's own bytes: bswap_int returns its operand's type,
    # and a 16-bit value in an i32 register has two bytes, not four.
    local _bsT = get(ctx.ssa_types, idx, nothing)
    if !(_bsT isa DataType && _bsT <: Base.BitInteger)
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "byte-swap of a value whose integer width is unknown ($(repr(_bsT)))"; idx=idx)
        return is_32bit ? I32 : I64
    end
    local _bsbits = 8 * sizeof(_bsT)
    _bsbits == 8 && return I32   # one byte: the swap is the identity
    # Allocate a scratch local to hold the input value (need it 4 times)
    scratch_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, is_32bit ? I32 : I64)
    local _bswb = _sub_builder(fb, ctx, "compile_call", 1)   # consumes the input
    # Store input value
    local_set!(_bswb, scratch_local)
    if _bsbits == 16
        # ((x >> 8) & 0xFF) | ((x & 0xFF) << 8) — the bits above 16 are not part of the value
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(8))
        num!(_bswb, Opcode.I32_SHR_U)
        i32_const!(_bswb, Int64(0xFF))
        num!(_bswb, Opcode.I32_AND)
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(0xFF))
        num!(_bswb, Opcode.I32_AND)
        i32_const!(_bswb, Int64(8))
        num!(_bswb, Opcode.I32_SHL)
        num!(_bswb, Opcode.I32_OR)
    elseif is_32bit
        # i32 bswap: reverse 4 bytes
        # ((x >> 24) & 0xFF) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | (x << 24)
        # Part 1: (x >> 24) & 0xFF — top byte to bottom
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(24))
        num!(_bswb, Opcode.I32_SHR_U)
        i32_const!(_bswb, Int64(0xFF))
        num!(_bswb, Opcode.I32_AND)
        # Part 2: (x >> 8) & 0xFF00
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(8))
        num!(_bswb, Opcode.I32_SHR_U)
        i32_const!(_bswb, Int64(0xFF00))
        num!(_bswb, Opcode.I32_AND)
        num!(_bswb, Opcode.I32_OR)
        # Part 3: (x << 8) & 0xFF0000
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(8))
        num!(_bswb, Opcode.I32_SHL)
        i32_const!(_bswb, Int64(0xFF0000))
        num!(_bswb, Opcode.I32_AND)
        num!(_bswb, Opcode.I32_OR)
        # Part 4: x << 24 — bottom byte to top
        local_get!(_bswb, scratch_local)
        i32_const!(_bswb, Int64(24))
        num!(_bswb, Opcode.I32_SHL)
        num!(_bswb, Opcode.I32_OR)
    else
        # i64 bswap: reverse 8 bytes
        # Same pattern but with 8 byte positions
        local_get!(_bswb, scratch_local)
        i64_const!(_bswb, Int64(56))
        num!(_bswb, Opcode.I64_SHR_U)
        i64_const!(_bswb, Int64(0xFF))
        num!(_bswb, Opcode.I64_AND)
        for (shift, mask) in [(40, 0xFF00), (24, 0xFF0000), (8, 0xFF000000),
                               (-8, 0xFF00000000), (-24, 0xFF0000000000),
                               (-40, 0xFF000000000000)]
            local_get!(_bswb, scratch_local)
            if shift > 0
                i64_const!(_bswb, Int64(shift))
                num!(_bswb, Opcode.I64_SHR_U)
            else
                i64_const!(_bswb, Int64(-shift))
                num!(_bswb, Opcode.I64_SHL)
            end
            i64_const!(_bswb, Int64(mask))
            num!(_bswb, Opcode.I64_AND)
            num!(_bswb, Opcode.I64_OR)
        end
        # Last part: x << 56 (no mask needed)
        local_get!(_bswb, scratch_local)
        i64_const!(_bswb, Int64(56))
        num!(_bswb, Opcode.I64_SHL)
        num!(_bswb, Opcode.I64_OR)
    end
    append_builder!(fb, _bswb)
    return is_32bit ? I32 : I64
end

"""
    _compile_call_checked_mul(op, args, fb, ctx, is_128bit, is_32bit, tuple_type)

Extracted handler for checked_smul_int / checked_umul_int. `op` is the
ALREADY-DISPATCHED CHECKED_OPS key — a data test, not a re-derivation via
`is_func`. Modifies `bytes` in-place.
parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
"""
function _compile_call_checked_mul(op::Symbol, args, fb::InstrBuilder, ctx::AbstractCompilationContext, is_128bit::Bool, is_32bit::Bool, tuple_type::Type)::Nothing
    if is_128bit
        # 128-bit checked mul: not supported. Strict-mode Approach A — loud reject
        # (natively returns a value, so a silent trap would diverge).
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
                               "128-bit checked multiply (Int128/UInt128)")
    else
        is_signed = op === :checked_smul_int
        local_type = is_32bit ? I32 : I64
        local_a = allocate_local!(ctx, local_type)
        local_b = allocate_local!(ctx, local_type)
        local_result = allocate_local!(ctx, local_type)
        bld = _sub_builder(fb, ctx, "_compile_call_checked_mul", 2)   # the operands

        # Save b, save a, compute a*b, save result
        local_set!(bld, local_b)
        local_tee!(bld, local_a)
        local_get!(bld, local_b)
        num!(bld, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
        local_set!(bld, local_result)

        local tuple_info = haskey(ctx.type_registry.structs, tuple_type) ?
                           ctx.type_registry.structs[tuple_type] :
                           register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
        emit_struct_prefix!(bld, ctx.type_registry, tuple_type, tuple_info)
        # Push result back for tuple field 1
        local_get!(bld, local_result)

        # Overflow detection for mul
        if is_signed
            # Signed mul overflow: if a==0: false; if a==-1: b==MIN; else: result/a != b
            # Use if/else chain: a.eqz ? 0 : (a==-1 ? (b==MIN) : (result/a != b))
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_EQZ : Opcode.I64_EQZ)
            if_!(bld; results=WasmValType[I32])  # result type i32
            # a == 0 → no overflow
            i32_const!(bld, 0)
            else_!(bld)
            # Check a == -1
            local_get!(bld, local_a)
            if is_32bit
                i32_const!(bld, -1)
                num!(bld, Opcode.I32_EQ)
            else
                i64_const!(bld, -1)
                num!(bld, Opcode.I64_EQ)
            end
            if_!(bld; results=WasmValType[I32])  # result type i32
            # a == -1 → overflow iff b == MIN_INT
            local_get!(bld, local_b)
            if is_32bit
                i32_const!(bld, typemin(Int32))
                num!(bld, Opcode.I32_EQ)
            else
                i64_const!(bld, typemin(Int64))
                num!(bld, Opcode.I64_EQ)
            end
            else_!(bld)
            # General case: overflow = result / a != b
            local_get!(bld, local_result)
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_DIV_S : Opcode.I64_DIV_S)
            local_get!(bld, local_b)
            num!(bld, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
            end_block!(bld)  # end inner if/else
            end_block!(bld)  # end outer if/else
        else
            # Unsigned mul overflow: if a==0: false; else: result/a != b
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_EQZ : Opcode.I64_EQZ)
            if_!(bld; results=WasmValType[I32])  # result type i32
            i32_const!(bld, 0)
            else_!(bld)
            local_get!(bld, local_result)
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_DIV_U : Opcode.I64_DIV_U)
            local_get!(bld, local_b)
            num!(bld, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
            end_block!(bld)  # end if/else
        end

        struct_new!(bld, tuple_info.wasm_type_idx)   # mod-resolved fields
        append_builder!(fb, bld)
    end
    return nothing
end

"""
    _compile_call_flipsign(args, fb, ctx, is_128bit, is_32bit, arg_type) -> WasmValType

Extracted handler for flipsign_int. Modifies `bytes` in-place; returns the
pushed result's WasmValType (the structref for is_128bit — `struct_rt` was
already computed here for the locals below, so the caller reuses it instead
of a second `get_concrete_wasm_type` call; a plain I32/I64 otherwise).
parity(quarantine: Julia's flipsign_int intrinsic; dart has no counterpart.)
"""
function _compile_call_flipsign(args, fb::InstrBuilder, ctx::AbstractCompilationContext, is_128bit::Bool, is_32bit::Bool, arg_type)::WasmValType
    # flipsign_int(x, y) returns -x if y < 0, otherwise x
    # Formula: (x xor signbit) - signbit where signbit = y >> 63 (all 1s if negative)
    # We need both x and y on stack, but they've been pushed as: [x, y]

    # 128-bit operands are STRUCT refs — never entry-narrow them to a scalar width
    bld = _sub_builder(fb, ctx, "_compile_call_flipsign", 2;
                       narrow_to=(is_128bit ? nothing : (is_32bit ? I32 : I64)))
    if is_128bit
        # For 128-bit, check if y's hi word is negative
        # flipsign_int(x, y) = y < 0 ? -x : x
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
        struct_rt = get_concrete_wasm_type(arg_type, ctx.mod, ctx.type_registry; for_local=true)

        # Pop y struct to local
        y_struct_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, get_concrete_wasm_type(arg_type, ctx.mod, ctx.type_registry; for_local=true))
        local_set!(bld, y_struct_local)

        # Pop x struct to local
        x_struct_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, get_concrete_wasm_type(arg_type, ctx.mod, ctx.type_registry; for_local=true))
        local_set!(bld, x_struct_local)

        # Get y's hi part to check sign
        local_get!(bld, y_struct_local)
        struct_get!(bld, type_idx, 2, I64)  # Field 2 = hi (0=typeId, 1=lo)

        # Check if negative (hi < 0)
        i64_const!(bld, 0)
        num!(bld, Opcode.I64_LT_S)

        # Store condition
        is_neg_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, I32)
        local_set!(bld, is_neg_local)

        # Compute -x using emit_int128_neg
        local_get!(bld, x_struct_local)
        emit_int128_neg!(bld, ctx, arg_type)

        # Store negated x
        neg_x_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, get_concrete_wasm_type(arg_type, ctx.mod, ctx.type_registry; for_local=true))
        local_set!(bld, neg_x_local)

        # Allocate result local
        result_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, get_concrete_wasm_type(arg_type, ctx.mod, ctx.type_registry; for_local=true))

        # if is_neg { result = neg_x } else { result = x }
        local_get!(bld, is_neg_local)
        if_!(bld)  # void

        local_get!(bld, neg_x_local)
        local_set!(bld, result_local)

        else_!(bld)

        local_get!(bld, x_struct_local)
        local_set!(bld, result_local)

        end_block!(bld)

        # Push result
        local_get!(bld, result_local)

    else
        # Pop y to local, check sign, conditionally negate x
        y_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, is_32bit ? I32 : I64)
        local_set!(bld, y_local)

        x_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, is_32bit ? I32 : I64)
        local_set!(bld, x_local)

        # Compute signbit = y >> (bits-1) (arithmetic shift gives all 1s if negative)
        local_get!(bld, y_local)
        if is_32bit
            i32_const!(bld, 31)
            num!(bld, Opcode.I32_SHR_S)
        else
            i64_const!(bld, 63)
            num!(bld, Opcode.I64_SHR_S)
        end

        signbit_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, is_32bit ? I32 : I64)
        local_set!(bld, signbit_local)

        # result = (x xor signbit) - signbit
        local_get!(bld, x_local)
        local_get!(bld, signbit_local)
        num!(bld, is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
        local_get!(bld, signbit_local)
        num!(bld, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
    end
    append_builder!(fb, bld)
    return is_128bit ? struct_rt : (is_32bit ? I32 : I64)
end

# The statement defining an SSA operand, when it is a plain (non-slot) definition.
# parity(code_generator.dart:135 getStaticType): a value's defining node, read once.
function _ssa_def(value, ctx::AbstractCompilationContext)::Union{NirNode,Nothing}
    value isa NirSSA && 1 <= value.id <= length(ctx.nir) || return nothing
    rec = ctx.nir[value.id]
    return rec.slot == 0 ? rec.node : nothing
end

# `getfield(owner, field)` — its (owner, field-literal) when `node` is such a call.
# parity(code_generator.dart:2258 visitInstanceGet): a field read names its receiver and field.
function _getfield_parts(node)::Union{Tuple{NirNode,Any},Nothing}
    (node isa NirCall && _nir_callee_object(node.callee) === Core.getfield &&
     length(node.operands) >= 2) || return nothing
    return (node.operands[1], nir_const(node.operands[2]))
end

# parity(quarantine: Julia's reflection over a TypeName's bindings, answered from the closed world's metadata; a dart library is never reflected over at run time.)
function _trace_field_owner(value::NirNode, field::Symbol, ctx::AbstractCompilationContext)::Union{Nothing, NirNode}
    def = _ssa_def(value, ctx)
    if def isa NirPi
        return _trace_field_owner(def.value, field, ctx)
    end
    parts = _getfield_parts(def)
    parts !== nothing && parts[2] === field && return parts[1]
    return nothing
end

# parity(quarantine: Julia's reflection over a TypeName's bindings, answered from the closed world's metadata; a dart library is never reflected over at run time.)
function _trace_typename_symbol_owner(value::NirNode, ctx::AbstractCompilationContext)::Union{Nothing, NirNode}
    def = _ssa_def(value, ctx)
    parts = _getfield_parts(def)
    if def isa NirPi
        return _trace_typename_symbol_owner(def.value, ctx)
    elseif parts !== nothing
        parts[2] in (:name, :singletonname) && return parts[1]
    elseif def isa NirPhi
        owners = Any[_trace_typename_symbol_owner(v, ctx) for v in def.values
                     if v !== nothing]
        isempty(owners) && return nothing
        any(isnothing, owners) && return nothing
        all(o -> isequal(o, owners[1]), owners) && return owners[1]
    end
    return nothing
end

# parity(quarantine: Julia's reflection over a TypeName's bindings, answered from the closed world's metadata; a dart library is never reflected over at run time.)
function emit_typename_symbol_metadata!(b::InstrBuilder, symbol, owner,
                                        name_field::UInt32, singleton_field::UInt32,
                                        ctx::AbstractCompilationContext)::InstrBuilder
    tn_idx = ctx.type_registry.jl_typename_idx
    str_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    symbol_struct_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
    symbol_data = allocate_local!(ctx, ConcreteRef(UInt32(str_idx), true))
    emit_value!(b, symbol, ctx, ConcreteRef(UInt32(symbol_struct_idx), true))
    struct_get!(b, symbol_struct_idx, UInt32(2), ConcreteRef(UInt32(str_idx), true))
    local_set!(b, symbol_data)
    local_get!(b, symbol_data)
    emit_value!(b, owner, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, UInt32(5),
                ConcreteRef(UInt32(symbol_struct_idx), true))
    struct_get!(b, symbol_struct_idx, UInt32(2), ConcreteRef(UInt32(str_idx), true))
    num!(b, Opcode.REF_EQ)
    if_!(b; results=WasmValType[I32])
    emit_value!(b, owner, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, singleton_field, I32)
    else_!(b)
    emit_value!(b, owner, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, name_field, I32)
    end_block!(b)
    return b
end

# ============================================================================
# `===` / `!==`: ONE egal lowering. Julia's `===` is jl_egal (builtins.c): bit identity for
# primitives, fieldwise egal for immutable structs and tuples, content for String, object
# identity for everything mutable, and a Union/UnionAll compared by its fields. dart2wasm's
# `identical` supplies the shape: a static arm per operand type pair that needs no runtime
# work, else a call to ONE runtime function over the two boxed operands.
#
# An operand reaches these emitters as a PUSHER — a zero-argument function that emits the
# value once, in the wasm type passed beside it — so a compare that reads each operand once
# costs no locals, and one that reads them more than once stores them first.
# ============================================================================

"""Store the value `push` emits (wasm type `w`) in a fresh local; returns its index.

parity(code_generator.dart:676 accept1): an operand evaluated once into a local its
consumer reads."""
function _egal_local!(b::InstrBuilder, alloc::Function, push::Function, w::WasmValType)::Int
    local l = alloc(w)
    push(); local_set!(b, l)
    return l
end

"""
    _emit_bits_egal!(b, mod, registry, alloc, P, p1, p2) -> b

Push `p1 === p2` for two values of the primitive type `P` in their representation (a numeric
register, or the two-limb struct of a 128-bit integer): the bits compare, never an IEEE
compare (`NaN === NaN`, `0.0 !== -0.0`), and a narrow integer compares only its own width —
the bits of an i32 register above `8 * sizeof(P)` are not part of the value.
parity(intrinsics.dart:1409 StaticIntrinsic.identical): the int arm (`i64.eq`) and the
double arm (`i64.reinterpret_f64` of both, then `i64.eq`), per Julia primitive width.
"""
function _emit_bits_egal!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                          alloc::Function, @nospecialize(P), p1::Function, p2::Function)::InstrBuilder
    if P === Int128 || P === UInt128
        local idx = get_int128_type!(mod, registry, P)
        local w = ConcreteRef(UInt32(idx), true)
        local l1, l2 = _egal_local!(b, alloc, p1, w), _egal_local!(b, alloc, p2, w)
        for f in (UInt32(1), UInt32(2))           # lo, hi limbs after the classId
            local_get!(b, l1); struct_get!(b, idx, f, I64)
            local_get!(b, l2); struct_get!(b, idx, f, I64)
            num!(b, Opcode.I64_EQ)
        end
        num!(b, Opcode.I32_AND)
        return b
    end
    local w = julia_to_wasm_type(P)
    local nbits = 8 * sizeof(P)
    if w === F64
        p1(); num!(b, Opcode.I64_REINTERPRET_F64)
        p2(); num!(b, Opcode.I64_REINTERPRET_F64)
        num!(b, Opcode.I64_EQ)
    elseif w === F32
        p1(); num!(b, Opcode.I32_REINTERPRET_F32)
        p2(); num!(b, Opcode.I32_REINTERPRET_F32)
        num!(b, Opcode.I32_EQ)
    elseif w === I64
        p1(); p2(); num!(b, Opcode.I64_EQ)
    elseif w === I32 && nbits >= 32
        p1(); p2(); num!(b, Opcode.I32_EQ)
    elseif w === I32
        p1(); p2(); num!(b, Opcode.I32_XOR)
        i32_const!(b, Int64((1 << nbits) - 1)); num!(b, Opcode.I32_AND)
        num!(b, Opcode.I32_EQZ)
    else
        error("egal: primitive $P has no numeric representation (got $w)")
    end
    return b
end

"""
    _emit_string_egal!(b, mod, registry, alloc, p1, p2) -> b

Push `p1 === p2` for two classed strings of one class (String, or Symbol): the byte arrays
compared by the one string-equality loop. jl_egal compares a String by its length and
bytes; a Symbol is interned by Julia, so for two Symbols content equality is identity.
parity(quarantine: jl_egal compares String by length and bytes, builtins.c
jl_egal__special; dart's `identical` on strings is reference equality.)
"""
function _emit_string_egal!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                            alloc::Function, p1::Function, p2::Function)::InstrBuilder
    local sidx = get_string_struct_type!(mod, registry)
    local aidx = get_string_array_type!(mod, registry)
    local aw = ConcreteRef(UInt32(aidx), true)
    local data(p) = () -> (p(); struct_get!(b, sidx, UInt32(2), aw))
    local la, lb = _egal_local!(b, alloc, data(p1), aw), _egal_local!(b, alloc, data(p2), aw)
    return _emit_string_equal_core!(b, aidx, la, lb, alloc(I32), alloc(I32))
end

"""Convert the ref on top of the stack (wasm type `w`) to an eqref, for `ref.eq`.

parity(intrinsics.dart:1409 StaticIntrinsic.identical): its operands translated to `eqref`."""
function _to_eqref!(b::InstrBuilder, mod::WasmModule, w::WasmValType)::InstrBuilder
    w === ExternRef && any_convert_extern!(b)
    wasm_subtype(w, EqRef, mod) || ref_cast!(b, EqRef, true)
    return b
end

"""Convert the ref on top of the stack (wasm type `w`) to an anyref, the runtime egal
function's operand type.

parity(translator.dart:1597 convertType): the upcast (and the extern bridge) to the top type."""
function _to_anyref!(b::InstrBuilder, w::WasmValType)::InstrBuilder
    w === ExternRef && any_convert_extern!(b)
    return b
end

"""
    _egal_needs_value_compare(T) -> Bool

True when two distinct heap objects of the concrete type `T` can still be `===`, so identity
alone cannot answer: primitives, String and Symbol, and immutable structs and tuples that are
not singletons. Type objects (`T <: Type`, TypeVar) and SimpleVector are compared by their own
arms of the runtime egal function.
parity(intrinsics.dart:1409 StaticIntrinsic.identical canBeValueType): which classes need an
unboxed comparison; Julia's value classes are its immutable types (builtins.c jl_egal).
"""
function _egal_needs_value_compare(@nospecialize(T))::Bool
    T isa DataType && isconcretetype(T) || return false
    (T <: Type || T === TypeVar || T === Core.SimpleVector) && return false
    Base.issingletontype(T) && return false
    isprimitivetype(T) && return true
    (T === String || T === Symbol) && return true
    return isstructtype(T) && !ismutabletype(T)
end

"""
    _egal_rep(T, mod, registry) -> WasmValType

The wasm type a value of the concrete type `T` is compared in: a primitive's numeric
register (a 128-bit integer's limb struct), the classed string for String and Symbol, the
registered struct of an immutable struct or tuple (registered here, as its first allocation
would register it), and `anyref` for a value compared by identity.
parity(translator.dart:1044 translateType): the storage type of a class's values.
"""
function _egal_rep(@nospecialize(T), mod::WasmModule, registry::TypeRegistry)::WasmValType
    (T === Int128 || T === UInt128) &&
        return ConcreteRef(UInt32(get_int128_type!(mod, registry, T)), true)
    isprimitivetype(T) && return julia_to_wasm_type(T)
    (T === String || T === Symbol) &&
        return ConcreteRef(UInt32(get_string_struct_type!(mod, registry)), true)
    if T isa DataType && isconcretetype(T) && isstructtype(T) && !ismutabletype(T) &&
       !(T <: Type) && !Base.issingletontype(T) && !is_closure_type(T) &&
       (T <: Tuple || is_struct_type(T))
        local info = T <: Tuple ? register_tuple_type!(mod, registry, T) :
                                  register_struct_type!(mod, registry, T)
        info isa StructInfo && info.field_offset > 0 &&
            return ConcreteRef(info.wasm_type_idx, true)
    end
    return AnyRef
end

"""
    _emit_egal_same!(b, mod, registry, alloc, T, p1, w1, p2, w2, seen) -> b

Push `p1 === p2` for two values whose static Julia type is the same `T` (pushed in wasm types
`w1`/`w2`): a singleton is the one instance; a primitive compares bits; String and Symbol
compare content; an immutable struct or tuple compares every field by the same rule (Julia's
`compare_fields`); a mutable object compares identity; anything whose static type does not
decide (abstract, a Union, a type object, a struct type already being expanded in `seen`)
calls the runtime egal function.
parity(intrinsics.dart:1409 StaticIntrinsic.identical): the static arms; the immutable
struct arm is Julia's (builtins.c compare_fields — dart has no immutable value structs).
"""
function _emit_egal_same!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                          alloc::Function, @nospecialize(T), p1::Function, w1::WasmValType,
                          p2::Function, w2::WasmValType, seen::Vector{Any})::InstrBuilder
    local concrete = T isa DataType && isconcretetype(T)
    if concrete && Base.issingletontype(T)
        i32_const!(b, 1)
    elseif concrete && isprimitivetype(T) && !_wt_is_ref(w1) && !_wt_is_ref(w2) ||
           T === Int128 || T === UInt128
        _emit_bits_egal!(b, mod, registry, alloc, T, p1, p2)
    elseif T === String || T === Symbol
        _emit_string_egal!(b, mod, registry, alloc, p1, p2)
    elseif concrete && _egal_needs_value_compare(T) && !isprimitivetype(T) &&
           !any(s -> s === T, seen) && !is_closure_type(T) &&
           haskey(registry.structs, T) && registry.structs[T].field_offset > 0
        _emit_fields_egal!(b, mod, registry, alloc, T, p1, p2, seen)
    elseif concrete && ismutabletype(T) && !(T <: Type)
        p1(); _to_eqref!(b, mod, w1)
        p2(); _to_eqref!(b, mod, w2)
        num!(b, Opcode.REF_EQ)
    else
        (_wt_is_ref(w1) && _wt_is_ref(w2)) ||
            error("egal: a $T value in a numeric $w1/$w2 representation has no class to compare")
        p1(); _to_anyref!(b, w1)
        p2(); _to_anyref!(b, w2)
        call!(b, get_egal_function!(mod, registry), WasmValType[AnyRef, AnyRef], WasmValType[I32])
    end
    return b
end

"""
    _emit_fields_egal!(b, mod, registry, alloc, T, p1, p2, seen) -> b

Push `p1 === p2` for two values of the immutable struct or tuple type `T` (each in any ref
type that casts to `T`'s struct): every field compared by `_emit_egal_same!` at the field's
declared type, all results and-ed. A concrete-typed reference field is null only while
undefined, and two undefined fields are egal while an undefined and a defined one are not.
parity(quarantine: jl_egal compares an immutable struct field by field, builtins.c
compare_fields; dart2wasm has no immutable value structs to compare.)
"""
function _emit_fields_egal!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                            alloc::Function, @nospecialize(T), p1::Function, p2::Function,
                            seen::Vector{Any})::InstrBuilder
    local info = registry.structs[T]
    local sidx = info.wasm_type_idx
    local sref = ConcreteRef(sidx, false)
    local cast(p) = () -> (p(); ref_cast!(b, Int64(sidx), false))
    local s1, s2 = _egal_local!(b, alloc, cast(p1), sref), _egal_local!(b, alloc, cast(p2), sref)
    local fields = mod.types[sidx + 1].fields
    local inner = Any[seen..., T]
    local nf = length(info.field_types)
    nf == 0 && (i32_const!(b, 1); return b)
    for fi in 1:nf
        local FT = info.field_types[fi]
        local widx = wasm_field_idx(info, fi)
        local wf = fields[widx + 1].valtype
        local field(s) = () -> (local_get!(b, s); struct_get!(b, sidx, widx, wf))
        if _wt_is_ref(wf) && FT isa DataType && isconcretetype(FT) && !Base.issingletontype(FT)
            local f1, f2 = _egal_local!(b, alloc, field(s1), wf), _egal_local!(b, alloc, field(s2), wf)
            local_get!(b, f1); ref_is_null!(b); local_get!(b, f2); ref_is_null!(b)
            num!(b, Opcode.I32_OR)
            if_!(b; results=WasmValType[I32])
            local_get!(b, f1); ref_is_null!(b); local_get!(b, f2); ref_is_null!(b)
            num!(b, Opcode.I32_AND)
            else_!(b)
            _emit_egal_same!(b, mod, registry, alloc, FT, () -> local_get!(b, f1), wf,
                             () -> local_get!(b, f2), wf, inner)
            end_block!(b)
        else
            _emit_egal_same!(b, mod, registry, alloc, FT, field(s1), wf, field(s2), wf, inner)
        end
        fi > 1 && num!(b, Opcode.I32_AND)
    end
    return b
end

"""
    _emit_is_nothing!(b, registry, l) -> b

Push whether the anyref in local `l` is `nothing`: a null reference, or a classed value whose
classId is `Nothing`'s (the boxed-nothing singleton, or a boxed `Nothing` register value).
parity(intrinsics.dart:2974 MemberIntrinsic.identical): its null arm (`br_on_null`), with
Julia's `nothing` carried either as null or as the Nothing class.
"""
function _emit_is_nothing!(b::InstrBuilder, registry::TypeRegistry, l::Integer)::InstrBuilder
    local top = registry.base_struct_idx
    local_get!(b, l); ref_is_null!(b)
    if_!(b; results=WasmValType[I32])
    i32_const!(b, 1)
    else_!(b)
    local_get!(b, l); ref_test!(b, Int64(top), false)
    if_!(b; results=WasmValType[I32])
    local_get!(b, l); emit_typeof!(b, top)
    i32_const!(b, Int64(ensure_type_id!(registry, Nothing))); num!(b, Opcode.I32_EQ)
    else_!(b)
    i32_const!(b, 0)
    end_block!(b)
    end_block!(b)
    return b
end

# abstract heap type `eq` as a ref.test immediate (the s33 encoding of 0x6D)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:501 EqHeapType.serialize)
const _HEAP_EQ = Int64(-19)

"""
    get_egal_function!(mod, registry) -> UInt32

The ONE runtime egal function `(anyref, anyref) -> i32`, built once per module on first use.
In order: `nothing` (null, or the Nothing class) against `nothing`; reference identity; type
objects (a Union or UnionAll compared by its two fields, a DataType or TypeVar by identity);
SimpleVector element by element; then two classed values of one classId, compared by that
class's rule (`_emit_egal_class!`) when the class can be equal without being identical. The
closed world is numbered before codegen, so the class list is complete when this is built.
parity(intrinsics.dart:2974 MemberIntrinsic.identical): ref.eq, the null arm, the classId
compare, then one unboxed compare per value class.
"""
function get_egal_function!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.egal_func_idx !== nothing && return registry.egal_func_idx
    local top = registry.base_struct_idx
    local jt = registry.jl_type_idx
    (top === nothing || jt === nothing) &&
        error("the runtime egal function needs the class hierarchy and the JlType hierarchy")
    local params = WasmValType[AnyRef, AnyRef]
    local results = WasmValType[I32]
    local fidx = add_function!(mod, params, results, WasmValType[],
                               UInt8[Opcode.UNREACHABLE, Opcode.END])
    registry.egal_func_idx = fidx
    local b = InstrBuilder(params, results; func_name="jl_egal", mod=mod)
    local extra = WasmValType[]
    local alloc = w -> (push!(extra, w); builder_add_local!(b, w))
    local ret!(emit) = (if_!(b); emit(); return_!(b); end_block!(b))
    local egal_call!() = call!(b, fidx, params, results)

    # nothing: null or the Nothing class, on either side
    local_get!(b, 0); ref_is_null!(b)
    ret!(() -> (local_get!(b, 1); ref_is_null!(b); if_!(b; results=WasmValType[I32]); i32_const!(b, 1); else_!(b);
                _emit_is_nothing!(b, registry, 1); end_block!(b)))
    local_get!(b, 1); ref_is_null!(b)
    ret!(() -> _emit_is_nothing!(b, registry, 0))
    # identity
    local_get!(b, 0); ref_test!(b, _HEAP_EQ, false)
    local_get!(b, 1); ref_test!(b, _HEAP_EQ, false)
    num!(b, Opcode.I32_AND)
    if_!(b)
    local_get!(b, 0); ref_cast!(b, EqRef, true)
    local_get!(b, 1); ref_cast!(b, EqRef, true)
    num!(b, Opcode.REF_EQ)
    ret!(() -> i32_const!(b, 1))
    end_block!(b)
    # type objects: kinds equal, then a Union / UnionAll fieldwise; a DataType and Union{} are
    # canonical objects, so identity (already false) decides them
    local jtr = ConcreteRef(UInt32(jt), true)
    local_get!(b, 0); ref_test!(b, Int64(jt), false)
    if_!(b)
    local_get!(b, 1); ref_test!(b, Int64(jt), false); num!(b, Opcode.I32_EQZ)
    ret!(() -> i32_const!(b, 0))
    local k = alloc(I32)
    local_get!(b, 0); ref_cast!(b, Int64(jt), false); struct_get!(b, jt, UInt32(0), I32)
    local_tee!(b, k)
    local_get!(b, 1); ref_cast!(b, Int64(jt), false); struct_get!(b, jt, UInt32(0), I32)
    num!(b, Opcode.I32_NE)
    ret!(() -> i32_const!(b, 0))
    for (kind, si) in ((JL_TYPE_KIND_UNION, registry.jl_union_idx), (JL_TYPE_KIND_UNIONALL, registry.jl_unionall_idx))
        local_get!(b, k); i32_const!(b, kind); num!(b, Opcode.I32_EQ)
        ret!(() -> begin
            for f in (UInt32(1), UInt32(2))
                local_get!(b, 0); ref_cast!(b, Int64(si), false); struct_get!(b, si, f, jtr)
                local_get!(b, 1); ref_cast!(b, Int64(si), false); struct_get!(b, si, f, jtr)
                egal_call!()
            end
            num!(b, Opcode.I32_AND)
        end)
    end
    i32_const!(b, 0); return_!(b)
    end_block!(b)
    local_get!(b, 1); ref_test!(b, Int64(jt), false)
    ret!(() -> i32_const!(b, 0))
    # SimpleVector: equal length, elements egal
    local sv = registry.jl_svec_idx
    if sv !== nothing
        local svr = ConcreteRef(UInt32(sv), false)
        local_get!(b, 0); ref_test!(b, Int64(sv), false)
        if_!(b)
        local_get!(b, 1); ref_test!(b, Int64(sv), false); num!(b, Opcode.I32_EQZ)
        ret!(() -> i32_const!(b, 0))
        local v1, v2, n, i = alloc(svr), alloc(svr), alloc(I32), alloc(I32)
        local_get!(b, 0); ref_cast!(b, Int64(sv), false); local_set!(b, v1)
        local_get!(b, 1); ref_cast!(b, Int64(sv), false); local_set!(b, v2)
        local_get!(b, v1); array_len!(b); local_tee!(b, n)
        local_get!(b, v2); array_len!(b); num!(b, Opcode.I32_NE)
        ret!(() -> i32_const!(b, 0))
        i32_const!(b, 0); local_set!(b, i)
        local done = block!(b)
        local again = loop!(b)
        local_get!(b, i); local_get!(b, n); num!(b, Opcode.I32_GE_U); br_if!(b, done)
        local_get!(b, v1); local_get!(b, i); array_get!(b, sv, AnyRef)
        local_get!(b, v2); local_get!(b, i); array_get!(b, sv, AnyRef)
        egal_call!(); num!(b, Opcode.I32_EQZ)
        ret!(() -> i32_const!(b, 0))
        local_get!(b, i); i32_const!(b, 1); num!(b, Opcode.I32_ADD); local_set!(b, i)
        br!(b, again)
        end_block!(b)
        end_block!(b)
        i32_const!(b, 1); return_!(b)
        end_block!(b)
        local_get!(b, 1); ref_test!(b, Int64(sv), false)
        ret!(() -> i32_const!(b, 0))
    end
    # classed values: one classId, then that class's rule
    local_get!(b, 0); ref_test!(b, Int64(top), false)
    local_get!(b, 1); ref_test!(b, Int64(top), false)
    num!(b, Opcode.I32_AND); num!(b, Opcode.I32_EQZ)
    ret!(() -> i32_const!(b, 0))
    local cid = alloc(I32)
    local_get!(b, 0); emit_typeof!(b, top); local_tee!(b, cid)
    local_get!(b, 1); emit_typeof!(b, top); num!(b, Opcode.I32_NE)
    ret!(() -> i32_const!(b, 0))
    for (C, id) in ordered_pairs(registry.type_ids, type_order_key)
        (C isa DataType && isconcretetype(C)) || continue
        local single = Base.issingletontype(C) && !(C <: Type)
        (single || _egal_needs_value_compare(C)) || continue
        local_get!(b, cid); i32_const!(b, Int64(id)); num!(b, Opcode.I32_EQ)
        ret!(() -> _emit_egal_class!(b, mod, registry, alloc, C, single))
    end
    i32_const!(b, 0)   # identity classes: ref.eq above already said no
    end_block!(b)
    local slot = fidx - num_imported_funcs(mod) + 1
    mod.functions[slot] = WasmFunction(mod.functions[slot].type_idx, extra, builder_code(b))
    return fidx
end

"""
    get_has_typevar_function!(mod, registry) -> UInt32

The runtime `jl_has_typevar(t, v)`: whether type object or TypeVar `t` mentions TypeVar `v`
free (jltypes.c jl_has_bound_typevars with `v` alone in its environment). A TypeVar is `v`
itself unless an enclosing UnionAll binds `v` (the `shadowed` parameter); a UnionAll's var
bounds and body, a Union's members and a DataType's parameters are walked; anything else
mentions none — Union{}, a value parameter, and so a Vararg parameter, which has no
representation here (its slot is null). Params: t (anyref), v (anyref), shadowed (i32).
parity(quarantine: jl_has_typevar is Julia's C runtime; its walk is ported over WT's type
objects, as the runtime egal function ports jl_egal.)
"""
function get_has_typevar_function!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.has_typevar_func_idx !== nothing && return registry.has_typevar_func_idx
    local jt, dt, un, ua = registry.jl_type_idx, registry.jl_datatype_idx,
                           registry.jl_union_idx, registry.jl_unionall_idx
    local tv, sv = registry.jl_typevar_idx, registry.jl_svec_idx
    local params = WasmValType[AnyRef, AnyRef, I32]
    local results = WasmValType[I32]
    local fidx = add_function!(mod, params, results, WasmValType[],
                               UInt8[Opcode.UNREACHABLE, Opcode.END])
    registry.has_typevar_func_idx = fidx
    local b = InstrBuilder(params, results; func_name="jl_has_typevar", mod=mod)
    local extra = WasmValType[]
    local alloc = w -> (push!(extra, w); builder_add_local!(b, w))
    local ret!(emit) = (if_!(b); emit(); return_!(b); end_block!(b))
    local has!() = call!(b, fidx, params, results)
    local jtr = ConcreteRef(UInt32(jt), true)
    local eq!(l1, l2) = (local_get!(b, l1); ref_cast!(b, EqRef, true);
                         local_get!(b, l2); ref_cast!(b, EqRef, true); num!(b, Opcode.REF_EQ))
    # null (an unrepresented value parameter) mentions nothing
    local_get!(b, 0); ref_is_null!(b)
    ret!(() -> i32_const!(b, 0))
    # a TypeVar is v itself, unless shadowed
    local_get!(b, 0); ref_test!(b, Int64(tv), false)
    ret!(() -> (local_get!(b, 2); num!(b, Opcode.I32_EQZ); eq!(0, 1); num!(b, Opcode.I32_AND)))
    # a value, not a type object, mentions nothing
    local_get!(b, 0); ref_test!(b, Int64(jt), false); num!(b, Opcode.I32_EQZ)
    ret!(() -> i32_const!(b, 0))
    local k = alloc(I32)
    local_get!(b, 0); ref_cast!(b, Int64(jt), false); struct_get!(b, jt, UInt32(0), I32)
    local_set!(b, k)
    # a UnionAll: its var's bounds, then its body, with v shadowed when its var is v
    local_get!(b, k); i32_const!(b, Int64(JL_TYPE_KIND_UNIONALL)); num!(b, Opcode.I32_EQ)
    ret!(() -> begin
        local var = alloc(AnyRef)
        local_get!(b, 0); ref_cast!(b, Int64(ua), false); struct_get!(b, ua, UInt32(1), jtr)
        local_set!(b, var)
        for f in (UInt32(2), UInt32(3))   # lb, ub
            local_get!(b, var); ref_cast!(b, Int64(tv), false); struct_get!(b, tv, f, jtr)
            local_get!(b, 1); local_get!(b, 2); has!()
            ret!(() -> i32_const!(b, 1))
        end
        local_get!(b, 0); ref_cast!(b, Int64(ua), false); struct_get!(b, ua, UInt32(2), jtr)
        local_get!(b, 1)
        local_get!(b, 2); eq!(var, 1); num!(b, Opcode.I32_OR)
        has!()
    end)
    # a Union: either member
    local_get!(b, k); i32_const!(b, Int64(JL_TYPE_KIND_UNION)); num!(b, Opcode.I32_EQ)
    ret!(() -> begin
        local_get!(b, 0); ref_cast!(b, Int64(un), false); struct_get!(b, un, UInt32(1), jtr)
        local_get!(b, 1); local_get!(b, 2); has!()
        ret!(() -> i32_const!(b, 1))
        local_get!(b, 0); ref_cast!(b, Int64(un), false); struct_get!(b, un, UInt32(2), jtr)
        local_get!(b, 1); local_get!(b, 2); has!()
    end)
    # a DataType: any parameter
    local_get!(b, k); i32_const!(b, Int64(JL_TYPE_KIND_DATATYPE)); num!(b, Opcode.I32_EQ)
    ret!(() -> begin
        local ps = alloc(ConcreteRef(UInt32(sv), true))
        local n, i = alloc(I32), alloc(I32)
        local_get!(b, 0); ref_cast!(b, Int64(dt), false)
        struct_get!(b, dt, UInt32(3), ConcreteRef(UInt32(sv), true)); local_tee!(b, ps)
        ref_is_null!(b)
        ret!(() -> i32_const!(b, 0))
        local_get!(b, ps); array_len!(b); local_set!(b, n)
        i32_const!(b, 0); local_set!(b, i)
        local done = block!(b)
        local again = loop!(b)
        local_get!(b, i); local_get!(b, n); num!(b, Opcode.I32_GE_U); br_if!(b, done)
        local_get!(b, ps); local_get!(b, i); array_get!(b, sv, AnyRef)
        local_get!(b, 1); local_get!(b, 2); has!()
        ret!(() -> i32_const!(b, 1))
        local_get!(b, i); i32_const!(b, 1); num!(b, Opcode.I32_ADD); local_set!(b, i)
        br!(b, again)
        end_block!(b)
        end_block!(b)
        i32_const!(b, 0)
    end)
    # Union{}: nothing
    i32_const!(b, 0)
    end_block!(b)
    local slot = fidx - num_imported_funcs(mod) + 1
    mod.functions[slot] = WasmFunction(mod.functions[slot].type_idx, extra, builder_code(b))
    return fidx
end

"""
    _emit_egal_class!(b, mod, registry, alloc, C, single) -> b

Inside the runtime egal function, with both anyref operands (locals 0 and 1) known to carry
class `C`: push their egal. A singleton class is its one instance; a primitive class reads
both boxes' payloads; String/Symbol and immutable structs cast to `C`'s representation and
compare by `_emit_egal_same!`. A value class with no classed representation traps, loudly.
parity(intrinsics.dart:2974 MemberIntrinsic.identical): the per-value-class arm — cast both,
`struct.get` the payload, compare.
"""
function _emit_egal_class!(b::InstrBuilder, mod::WasmModule, registry::TypeRegistry,
                           alloc::Function, @nospecialize(C), single::Bool)::InstrBuilder
    if single
        i32_const!(b, 1)
        return b
    end
    local rep = _egal_rep(C, mod, registry)
    if !_wt_is_ref(rep)
        local box = get_numeric_box_type!(mod, registry, rep)
        local payload(l) = () -> (local_get!(b, l); ref_cast!(b, Int64(box), false);
                                  struct_get!(b, box, UInt32(1), rep))
        return _emit_bits_egal!(b, mod, registry, alloc, C, payload(0), payload(1))
    end
    if !(rep isa ConcreteRef)
        unreachable!(b)   # structural trap: a value class with no classed representation to compare
        return b
    end
    local cast(l) = () -> (local_get!(b, l); ref_cast!(b, Int64(rep.type_idx), true))
    return _emit_egal_same!(b, mod, registry, alloc, C, cast(0), rep, cast(1), rep, Any[])
end

"""
    emit_egal!(b, ctx, x, y) -> b

THE `===` lowering: push `x === y` (i32). Disjoint static types are never egal (Julia's own
`egal_tfunc`); one concrete static type compares by `_emit_egal_same!` in its representation;
`nothing` against a value that may be `nothing` is its null/Nothing-class test; every other
pair boxes both operands and calls the runtime egal function. A value whose static type has
several members but sits in a numeric register no longer records which member it is, so a
compare involving one rejects at its statement.
formal(dev/formal/EgalDispatch.tla): the arm the static types pick answers Julia's `===` for
every pair of values they admit.
parity(intrinsics.dart:1409 StaticIntrinsic.identical): the static arms, else the call to
`identical` over the boxed operands.
"""
function emit_egal!(b::InstrBuilder, ctx::AbstractCompilationContext, x::NirNode, y::NirNode)::InstrBuilder
    local T1 = infer_value_type(x, ctx)
    local T2 = infer_value_type(y, ctx)
    T1 isa Type || (T1 = Any)
    T2 isa Type || (T2 = Any)
    local mod, reg = ctx.mod, ctx.type_registry
    local alloc = w -> allocate_local!(ctx, w)
    local bld = _ctx_builder(ctx, "egal")
    local pusher(v, w, J) = () -> emit_value!(bld, v, ctx, w; from_julia=J)
    local concrete(T) = T isa DataType && isconcretetype(T)
    local lossy = [(v, T) for (v, T) in ((x, T1), (y, T2))
                   if !concrete(T) && !_wt_is_ref(static_wasm_type(v, ctx))]
    if typeintersect(T1, T2) === Union{}
        i32_const!(bld, 0)
    elseif !isempty(lossy)
        local v, T = first(lossy)
        emit_unsupported_stub!(ctx, bld, :unsupported_type,
            "`===` on a $(T) value held in a numeric $(static_wasm_type(v, ctx)) register, " *
            "which does not record which member of $(T) it is")
    elseif T1 === T2 && (T1 === String || T1 === Symbol)
        append_builder!(bld, compile_string_equal_b(x, y, ctx))
    elseif T1 === T2 && concrete(T1) && T1 <: Core.GenericMemoryRef
        # a MemoryRef is an immutable (mem, offset) pair: egal is the same Memory at the same
        # element offset (Julia compares its ptr_or_offset and mem fields)
        emit_memoryref_mem!(bld, ctx, x)
        emit_memoryref_mem!(bld, ctx, y)
        num!(bld, Opcode.REF_EQ)
        emit_memoryref_offset!(bld, ctx, x)
        emit_memoryref_offset!(bld, ctx, y)
        num!(bld, Opcode.I32_EQ)
        num!(bld, Opcode.I32_AND)
    elseif T1 === T2 && concrete(T1)
        local w = _egal_rep(T1, mod, reg)
        _emit_egal_same!(bld, mod, reg, alloc, T1, pusher(x, w, T1), w, pusher(y, w, T1), w, Any[])
    elseif T1 === Nothing || T2 === Nothing
        local other, OT = T1 === Nothing ? (y, T2) : (x, T1)
        local w = static_wasm_type(other, ctx)
        local inner = OT isa Union ? get_nullable_inner_type(OT) : nothing
        if w isa ConcreteRef && inner isa DataType && is_struct_type(inner)
            # Union{Nothing,S} of a struct S: null is the only nothing
            emit_value!(bld, other, ctx, w; from_julia=OT)
            ref_is_null!(bld)
        else
            local l = _egal_local!(bld, alloc, pusher(other, AnyRef, concrete(OT) ? OT : nothing), AnyRef)
            _emit_is_nothing!(bld, reg, l)
        end
    else
        pusher(x, AnyRef, concrete(T1) ? T1 : nothing)()
        pusher(y, AnyRef, concrete(T2) ? T2 : nothing)()
        call!(bld, get_egal_function!(mod, reg), WasmValType[AnyRef, AnyRef], WasmValType[I32])
    end
    append_builder!(b, bld)
    return b
end

"""
    _compile_call_isa(args, fb, ctx)

Extracted handler for isa() type checking.
parity(pkg/dart2wasm/lib/code_generator.dart:3159 CodeGenerator.visitIsExpression)
"""
function _compile_call_isa(args, fb::InstrBuilder, ctx::AbstractCompilationContext)::Nothing
    # isa(value, Type) - check if value is of given type
    # Supports both Union{Nothing, T} (via ref.is_null) and tagged unions
    value_arg = args[1]
    type_arg = args[2]

    # Get the type being checked
    check_type = if nir_const(type_arg) isa Type
        nir_const(type_arg)
    elseif type_arg isa NirGlobalRef
        Core.eval(type_arg.mod, type_arg.name)
    else
        nothing
    end

    # Get the type of the value being checked (for detecting tagged unions)
    value_type = get_ssa_type(ctx, value_arg)

    bld = _sub_builder(fb, ctx, "_compile_call_isa", 1)

    # Julia's emit_isa (cgutils.cpp): a value of static type S is a T exactly when it is an
    # S ∩ T. When S <: T every value is; when S ∩ T is empty none is; when S ∩ T is one concrete
    # type C <: T, the test is C's exact one, which WT can make where T's own has none
    # (`isa(x::Union{Nothing,Tuple{Int64,Int64}}, Tuple{Any,Any})`, Base._accumulate1!).
    local isa_isect = check_type      # S ∩ T, Julia's intersected_type
    if check_type isa Type && value_type isa Type
        # Julia folds S <: T only where its subtyping of kinds is sound (jl_is_not_broken_subtype,
        # subtype.c: not a `Type{…}` against a kind, JuliaLang/julia#27078); elsewhere it tests
        local _not_broken = !(check_type in (DataType, Union, UnionAll, Core.TypeofBottom)) ||
                            !(value_type isa DataType && value_type.name === Type.body.name)
        local _known = _not_broken && value_type <: check_type
        local _isect = _known ? value_type : typeintersect(value_type, check_type)
        isa_isect = _isect
        if _known || _isect === Union{}
            drop!(bld)
            i32_const!(bld, _known ? 1 : 0)
            append_builder!(fb, bld)
            return nothing
        end
        if _isect isa DataType && isconcretetype(_isect) && _isect <: check_type
            check_type = _isect
        end
    end
    # a test that meets `Type{…}`, as emit_isa makes it: an intersection `Type{X}` whose values
    # are pointer-unique (jl_pointer_egal) is X's identity (the abstract arm below); elsewhere
    # emit_isa calls jl_isa at run time. Against a kind or `Type` itself jl_isa answers by the
    # value's kind, the test the arms below make; against a type that meets `Type{…}` it tests
    # type equality, which WT has no run-time subtyping for: the isa rejects at its statement
    # emit_isa first swaps the abstract Type{Union{}} for the concrete typeof(Union{})
    isa_isect === Type{Union{}} && (isa_isect = Core.TypeofBottom; check_type = Core.TypeofBottom)
    if isa_isect isa Type && isa_isect !== Any
        if is_pointer_egal_type_type(isa_isect)
            check_type = isa_isect
        elseif check_type isa Type && check_type !== Type && has_intersect_type_not_kind(check_type)
            _isa_reject!(bld, ctx, "isa(x::$(value_type), $(check_type)): Julia tests a type object against " *
                                   "$(isa_isect) by type equality at run time (jl_isa), which WT does not have")
            append_builder!(fb, bld)
            return nothing
        end
    end

    # Check if this is a tagged union check
    # NOTE: The value argument is already on the stack from the loop that pushes all args
    # B4/U2: the tagged-union isa branch (struct.get tag) is RETIRED — a Union value is a
    # boxed AnyRef discriminated by classId, so isa flows through the AnyRef path below
    # (emit_isa_classid! / ref.test on the classId box & struct refs).
    if check_type === Nothing
        # isa(x, Nothing) -> ref.is_null
        # Value is already on stack — check if it's actually a ref type
        local isa_val_wasm = nothing
        if value_arg isa NirSSA
            local isa_local_idx = get(ctx.ssa_locals, value_arg.id, nothing)
            # Fix: isa_local_idx includes n_params, but ctx.locals only has non-param locals
            if isa_local_idx !== nothing
                local local_offset = isa_local_idx - ctx.n_params
                if local_offset >= 0 && local_offset < length(ctx.locals)
                    isa_val_wasm = ctx.locals[local_offset + 1]
                end
            end
        end
        if isa_val_wasm !== nothing && (isa_val_wasm === I64 || isa_val_wasm === I32 || isa_val_wasm === F64 || isa_val_wasm === F32)
            # Numeric value on stack — can never be Nothing. Drop + push false.
            drop!(bld)
            i32_const!(bld, 0)
        else
            ref_is_null!(bld)
        end
    elseif check_type isa DataType && check_type <: Tuple && isconcretetype(check_type) &&
           is_runtime_vararg_tuple_type(value_type) && check_type <: value_type
        # a runtime-length tuple is an NTuple{n,E} for its run-time n (jl_f_tuple): of a
        # concrete tuple type under its static type, it is one exactly when its size is that
        # type's length (its header's class, Tuple{Vararg{E}}, is no value's type)
        local tuple_info = register_vararg_tuple_type!(ctx.mod, ctx.type_registry, value_type)
        local size_info = ctx.type_registry.structs[Tuple{Int64}]
        ref_cast!(bld, Int64(tuple_info.wasm_type_idx), false)
        struct_get!(bld, tuple_info.wasm_type_idx, wasm_field_idx(tuple_info, 2),
                    ConcreteRef(size_info.wasm_type_idx, true))
        struct_get!(bld, size_info.wasm_type_idx, wasm_field_idx(size_info, 1), I64)
        if isempty(check_type.parameters)
            num!(bld, Opcode.I64_EQZ)
        else
            i64_const!(bld, Int64(length(check_type.parameters)))
            num!(bld, Opcode.I64_EQ)
        end
    elseif check_type isa DataType && (check_type <: GenericMemory || check_type === Core.SimpleVector) &&
           check_type in bare_array_partition(ctx.mod, ctx.type_registry, value_type).shared
        # a bare-array class is told only by an array type no other class the value may be
        # is; this one's is another's too (Memory{Int64} and Memory{UInt64})
        _isa_reject!(bld, ctx, "isa(x::$(value_type), $(check_type)): its wasm array type is another class's " *
                               "the value may be, and no test tells them apart")
    elseif check_type !== nothing && isconcretetype(check_type)
        # isa(x, ConcreteType) -> type check
        # Value is already on stack — check if it's actually a ref type
        local isa2_val_wasm = nothing
        local isa2_julia = nothing   # the value's own Julia type, when codegen knows it exactly
        if value_arg isa NirSSA
            # parity(translator.dart:2100 Translator.translateTypeOfLocalVariable): the load (_narrow_generic_local!) delivers the SSA's REFINED
            # type — when the join proved a numeric, the value on stack IS that numeric
            # regardless of the (anyref) local. The refined type drives the fold.
            local _isa2_refined = get(ctx.ssa_types, value_arg.id, Any)
            isconcretetype(_isa2_refined) && (isa2_julia = _isa2_refined)
            if _isa2_refined in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool)
                isa2_val_wasm = julia_to_wasm_type(_isa2_refined)
            else
            local isa2_local_idx = get(ctx.ssa_locals, value_arg.id, nothing)
            # Fix: isa2_local_idx includes n_params, but ctx.locals only has non-param locals
            if isa2_local_idx !== nothing
                local local_offset = isa2_local_idx - ctx.n_params
                if local_offset >= 0 && local_offset < length(ctx.locals)
                    isa2_val_wasm = ctx.locals[local_offset + 1]
                end
            end
            end
        elseif value_arg isa NirArgument
            # Also handle function parameters (not just SSA values)
            # Core.Argument(1) is the function object for non-closures, so
            # actual args start at Argument(2) → arg_types[1].
            local arg_idx_isa = ctx.is_compiled_closure ? value_arg.n : value_arg.n - 1
            if arg_idx_isa >= 1 && arg_idx_isa <= length(ctx.arg_types)
                local _arg_jtype = ctx.arg_types[arg_idx_isa]
                isconcretetype(_arg_jtype) && (isa2_julia = _arg_jtype)
                # Check if this param was promoted to anyref for Union dispatch
                if _arg_jtype isa Union && needs_anyref_boxing(_arg_jtype)
                    isa2_val_wasm = AnyRef
                else
                    isa2_val_wasm = get_concrete_wasm_type(_arg_jtype, ctx.mod, ctx.type_registry)
                end
            end
        end
        if isa2_val_wasm !== nothing && (isa2_val_wasm === I64 || isa2_val_wasm === I32 || isa2_val_wasm === F64 || isa2_val_wasm === F32)
            # An unboxed numeric carries no classId: the answer is Julia's own subtype test
            # of the value's exact type — never "a numeric, so true" (an Int64 is not a Float64).
            if isa2_julia isa Type
                drop!(bld)
                i32_const!(bld, isa2_julia <: check_type ? 1 : 0)
            else
                _isa_reject!(bld, ctx, "isa(x, $(check_type)) of an unboxed $(isa2_val_wasm) value whose Julia type codegen does not know")
            end
        elseif check_type === DataType || check_type === Union || check_type === UnionAll ||
               check_type === TypeVar || check_type === Core.TypeofBottom
            # a type object is no numbered class: its kind answers (a TypeVar is its own struct;
            # a DataType, Union or UnionAll is a $JlType whose $kind names it, and Union and
            # UnionAll share one wasm struct, so no layout or classId test can)
            isa2_val_wasm === ExternRef && any_convert_extern!(bld)
            local _tk_local = allocate_local!(ctx, AnyRef)
            local_set!(bld, _tk_local)
            _emit_isa_type_object_kinds!(bld, ctx, _tk_local, check_type)
        elseif isa2_val_wasm === ExternRef
            # Value is externref (Any-typed field). Need proper type check.
            # For Exception subtypes with DFS typeIds, use typeId comparison
            # instead of ref.test (which can't distinguish structurally identical types
            # due to Wasm type canonicalization).
            local _isa2_check_tid = get_type_id(ctx.type_registry, check_type)
            if _isa2_check_tid > 0 && check_type <: Exception && ctx.type_registry.base_struct_idx !== nothing
                # typeId-based check: extract typeId from exception struct + compare
                any_convert_extern!(bld)
                emit_typeof!(bld, ctx.type_registry.base_struct_idx)
                i32_const!(bld, Int64(_isa2_check_tid))
                num!(bld, Opcode.I32_EQ)
            else
                local target_wasm = get_concrete_wasm_type(check_type, ctx.mod, ctx.type_registry)
                if target_wasm isa ConcreteRef &&
                   is_shared_wasm_type(ctx.type_registry, target_wasm.type_idx, check_type)
                    # a layout several classes share: the layout, then the classId
                    any_convert_extern!(bld)
                    emit_isa_classid!(bld, ctx, target_wasm.type_idx, check_type)
                elseif target_wasm isa ConcreteRef
                    any_convert_extern!(bld)
                    # Use REF_TEST (non-nullable) instead of REF_TEST_NULL.
                    ref_test!(bld, Int64(target_wasm.type_idx), false)
                elseif haskey(ctx.type_registry.numeric_boxes, target_wasm)
                    local box_type_idx = ctx.type_registry.numeric_boxes[target_wasm]
                    # F-ii: route through the SINGLE-SOURCE discriminator (was ref.test of the
                    # box struct, which can't distinguish same-wasm-rep types that share it —
                    # emit_isa_classid! reads the classId field instead).
                    any_convert_extern!(bld)
                    emit_isa_classid!(bld, ctx, box_type_idx, check_type)
                else
                    # Fallback: non-null check for non-concrete wasm types
                    ref_is_null!(bld)
                    num!(bld, Opcode.I32_EQZ)
                end
            end
        elseif isa2_val_wasm === AnyRef || isa2_val_wasm isa ConcreteRef || isa2_val_wasm === StructRef
            # anyref/structref value — use ref.test to check concrete box type.
            # This handles Union{Int32, Float64} where the value is boxed in anyref.
            local target_wasm_isa = get_concrete_wasm_type(check_type, ctx.mod, ctx.type_registry)
            local _ck_box_wasm = julia_to_wasm_type(check_type)
            if check_type <: Core.GenericMemoryRef
                # a MemoryRef held as any value is its single-value struct, classed MemoryRef{T}
                emit_isa_classid!(bld, ctx, register_memoryref_box!(ctx.mod, ctx.type_registry, check_type), check_type)
            elseif (_ck_box_wasm === I32 || _ck_box_wasm === I64 || _ck_box_wasm === F32 || _ck_box_wasm === F64) &&
               !(check_type <: Int128) && !(check_type <: UInt128)
                # Numeric-box rep (Number subtypes AND Char etc.): route through the SINGLE-SOURCE
                # discriminator (was ref.test of the box struct, which same-wasm-rep types share —
                # emit_isa_classid! reads the classId field to distinguish Bool/Int8/Int16/Int32/Char).
                local _box_wasm = _ck_box_wasm
                local _box_idx = get(ctx.type_registry.numeric_boxes, _box_wasm,
                                     get_numeric_box_type!(ctx.mod, ctx.type_registry, _box_wasm))
                emit_isa_classid!(bld, ctx, _box_idx, check_type)
            elseif check_type === String || check_type === Symbol
                # String and Symbol share the classed string layout under their own classes
                # (constants.dart:1556 visitSymbolConstant): isa tests the layout, then the classId
                local _str_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
                emit_isa_classid!(bld, ctx, _str_idx, check_type)
            elseif target_wasm_isa isa ConcreteRef
                # Struct type: test against the concrete struct type.
                # When multiple Julia types share the same WasmGC type index
                # (due to identical field layouts), ref.test can't distinguish them.
                # Use typeId field comparison: save value → ref.test layout → if match,
                # reload → ref.cast → struct.get typeId → compare with target's ID.
                if is_shared_wasm_type(ctx.type_registry, target_wasm_isa.type_idx, check_type)
                    local _tid = ensure_type_id!(ctx.type_registry, check_type)
                    # Also ensure all types sharing this index get IDs
                    for (_ot, _oi) in registered_structs(ctx.type_registry)
                        if _oi.wasm_type_idx == target_wasm_isa.type_idx && _ot !== check_type
                            ensure_type_id!(ctx.type_registry, _ot)
                        end
                    end
                    # Allocate temp anyref local for saving the value
                    local _tmp_idx = UInt32(length(ctx.locals) + ctx.n_params)
                    push!(ctx.locals, AnyRef)
                    # Emit: local.tee $tmp → ref.test → if (i32) → reload+cast+typeId check → else 0 → end
                    local_tee!(bld, _tmp_idx)
                    ref_test!(bld, Int64(target_wasm_isa.type_idx), false)
                    if_!(bld; results=WasmValType[I32])  # result type i32
                    # Inside if-true: reload, cast, get typeId, compare
                    local_get!(bld, _tmp_idx)
                    ref_cast!(bld, Int64(target_wasm_isa.type_idx), false)
                    struct_get!(bld, target_wasm_isa.type_idx, UInt32(0), I32)  # field 0 = typeId
                    i32_const!(bld, Int64(_tid))
                    num!(bld, Opcode.I32_EQ)
                    else_!(bld)
                    i32_const!(bld, 0)  # false
                    end_block!(bld)
                else
                    ref_test!(bld, Int64(target_wasm_isa.type_idx), false)
                end
            else
                _isa_reject!(bld, ctx, "isa(x, $(check_type)): $(check_type) has no runtime test for a $(isa2_val_wasm) value")
            end
        elseif value_type isa Union && Nothing <: value_type && Base.typesplit(value_type, Nothing) <: check_type
            # x::Union{Nothing, S} with S <: T: isa(x, T) is exactly "x is not the null nothing"
            ref_is_null!(bld)
            num!(bld, Opcode.I32_EQZ)  # negate: 1->0, 0->1
        else
            _isa_reject!(bld, ctx, "isa(x::$(value_type), $(check_type)) has no runtime test for a $(something(isa2_val_wasm, "stack")) value")
        end
    elseif check_type !== nothing && !isconcretetype(check_type)
        # Abstract type check (e.g. Integer, AbstractFloat, Number, Real)
        # Determine value's WASM local type and local index for re-loading
        local isa3_val_wasm = nothing
        local isa3_julia = nothing   # the value's own Julia type, when codegen knows it exactly
        if value_arg isa NirSSA
            # the load delivers the SSA's REFINED type (translator.dart:2100): a proven
            # numeric is on the stack unboxed whatever its local's type
            local _refined3 = get(ctx.ssa_types, value_arg.id, Any)
            isconcretetype(_refined3) && (isa3_julia = _refined3)
            if _refined3 in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool)
                isa3_val_wasm = julia_to_wasm_type(_refined3)
            else
                local _idx3 = get(ctx.ssa_locals, value_arg.id, nothing)
                if _idx3 !== nothing
                    local _off3 = _idx3 - ctx.n_params
                    if _off3 >= 0 && _off3 < length(ctx.locals)
                        isa3_val_wasm = ctx.locals[_off3 + 1]
                    end
                end
            end
        elseif value_arg isa NirArgument
            # Also detect param type for Argument values
            local _arg_idx3 = ctx.is_compiled_closure ? value_arg.n : value_arg.n - 1
            if _arg_idx3 >= 1 && _arg_idx3 <= length(ctx.arg_types)
                isconcretetype(ctx.arg_types[_arg_idx3]) && (isa3_julia = ctx.arg_types[_arg_idx3])
                isa3_val_wasm = get_concrete_wasm_type(ctx.arg_types[_arg_idx3], ctx.mod, ctx.type_registry)
            end
        end
        if isa3_val_wasm === ExternRef
            # an externref holds a boxed Julia value: test it as the anyref it is
            any_convert_extern!(bld)
            isa3_val_wasm = AnyRef
        end
        if isa3_val_wasm !== nothing && (isa3_val_wasm === I64 || isa3_val_wasm === I32 || isa3_val_wasm === F64 || isa3_val_wasm === F32)
            # An unboxed numeric: Julia's own subtype test of the value's exact type (an
            # I64 local holds an Int64 OR a UInt64 — the wasm type alone cannot answer)
            if isa3_julia isa Type
                drop!(bld)
                i32_const!(bld, isa3_julia <: check_type ? 1 : 0)
            else
                _isa_reject!(bld, ctx, "isa(x, $(check_type)) of an unboxed $(isa3_val_wasm) value whose Julia type codegen does not know")
            end
        elseif (isa3_val_wasm === AnyRef || isa3_val_wasm isa ConcreteRef || isa3_val_wasm === StructRef) &&
               ctx.type_registry.base_struct_idx !== nothing
            # classId membership for anyref/structref polymorphic values: the exact
            # closed-world set of concrete classes <: check_type (Julia's subtyping is
            # the ground truth; a DFS range keyed by the base could not answer
            # `AbstractVector`, and a parametric abstract's extras were never
            # recorded), compressed to dart's range window when contiguous.
            local _ids = concrete_class_ids(ctx.type_registry, check_type)
            if is_pointer_egal_type_type(check_type)
                # `Type{X}`: X's one type object, by identity (cgutils.cpp emit_isa's
                # pointer comparison); a value that is not a type object is not X
                local _tg = get_type_constant_global!(ctx.mod, ctx.type_registry, check_type.parameters[1])
                local _jt = ctx.type_registry.jl_type_idx
                local _tl = allocate_local!(ctx, AnyRef)
                local_tee!(bld, _tl)
                ref_test!(bld, Int64(_jt), false)
                if_!(bld; results=WasmValType[I32])
                local_get!(bld, _tl)
                ref_cast!(bld, Int64(_jt), false)
                global_get!(bld, _tg, ctx.mod.globals[Int(_tg) + 1].valtype)
                num!(bld, Opcode.REF_EQ)
                else_!(bld)
                i32_const!(bld, 0)
                end_block!(bld)
            elseif !isempty(_ids)
                local _base_idx = ctx.type_registry.base_struct_idx
                # Guard against JlType hierarchy refs.
                # emit_typeof! does ref.cast (ref $JlBase) which traps on $JlType
                # hierarchy structs ($JlDataType, $JlUnion, etc.) since they don't
                # inherit from $JlBase. Use ref.test first; if not $JlBase, return false.
                local _isa_guard_local = allocate_local!(ctx, AnyRef)
                local_tee!(bld, _isa_guard_local)
                ref_test!(bld, Int64(_base_idx), false)  # ref.test (ref $JlBase)
                num!(bld, Opcode.I32_EQZ)
                # if (not $JlBase) { its type-object kind } else { dfs range check }
                if_!(bld; results=WasmValType[I32])  # i32 result type
                _emit_isa_type_object_kinds!(bld, ctx, _isa_guard_local, check_type)
                else_!(bld)
                local_get!(bld, _isa_guard_local)
                emit_typeof!(bld, _base_idx)
                emit_classid_membership!(bld, ctx, _ids)
                end_block!(bld)
            else
                # no class of the closed world — which numbers every class a value can have
                # (assign_type_ids!) — is a subtype: Julia's answer for every possible value.
                # A type object (DataType, Union, …) is not a numbered class; test its kind.
                local _isa_guard_local = allocate_local!(ctx, AnyRef)
                local_set!(bld, _isa_guard_local)
                _emit_isa_type_object_kinds!(bld, ctx, _isa_guard_local, check_type)
            end
        else
            _isa_reject!(bld, ctx, "isa(x, $(check_type)) has no runtime test for a $(something(isa3_val_wasm, "stack")) value")
        end
    else
        # `isa(x, T)` with a runtime `T`: no closed-world constant to test against
        _isa_reject!(bld, ctx, "isa(x, T) with a runtime type T")
    end
    append_builder!(fb, bld)
    return nothing
end

"""
    is_pointer_egal_type_type(T) -> Bool

Whether `T` is a `Type{X}` whose values are one pointer, so `isa(x, T)` is `x === X`: Julia's
own answer (jl_pointer_egal, datatype.c), asked of `Type{X}` as emit_isa asks it.
parity(quarantine: Julia type objects are values compared by type equality; dart's type test
is a class test.)
"""
is_pointer_egal_type_type(@nospecialize(T))::Bool =
    T isa DataType && T.name === Type.body.name && ccall(:jl_pointer_egal, Cint, (Any,), T) != 0

"""
    has_intersect_type_not_kind(T) -> Bool

Whether `T` meets `Type{…}` other than through a kind (Julia's jl_has_intersect_type_not_kind,
subtype.c): its values include type objects tested by type equality, which emit_isa leaves to
jl_isa at run time.
parity(quarantine: Julia type objects are values compared by type equality; dart's type test
is a class test.)
"""
has_intersect_type_not_kind(@nospecialize(T))::Bool = ccall(:jl_has_intersect_type_not_kind, Cint, (Any,), T) != 0

"""A located rejection of an `isa` codegen cannot answer — never a constant false. The
statement's operands are on `bld`; the trap after the recorded diagnostic makes the rest
of the fragment unreachable.
parity(quarantine: an `isa` with no runtime test in WT's representation — a runtime type,
or a value representation that carries no class — which Julia answers and WT must refuse
rather than guess.)"""
function _isa_reject!(bld::InstrBuilder, ctx::AbstractCompilationContext, construct::String)::Nothing
    record_unsupported!(ctx, :unsupported_method, construct)
    unreachable!(bld)
    ctx.last_stmt_was_stub = true
    return nothing
end

"""The i32 answer to `isa(x, check_type)` for a value in `local_idx` that is not a numbered
class (not `\$JlBase`): a Julia type object, whose kind — DataType, Union, UnionAll,
TypeVar — is its own wasm struct, or a `Memory`, which is a bare wasm array. OR of
`ref.test` over the representations of the kinds and closed-world Memory classes that are
subtypes of `check_type`; `0` when none is. When a Memory class under `check_type` shares
its wasm array with one that is not (`Memory{Int64}`/`Memory{UInt64}` under
`AbstractVector{Int64}`), no test can tell them apart and the `isa` rejects.
parity(quarantine: Julia's type objects and Memory are values; WT represents a type
object's kind as its own struct under \$JlType and a Memory as a wasm array, outside the
numbered class hierarchy.)"""
function _emit_isa_type_object_kinds!(bld::InstrBuilder, ctx::AbstractCompilationContext,
                                      local_idx::Integer, @nospecialize(check_type))::Nothing
    reg = ctx.type_registry
    kinds = UInt32[]   # the bare-array representations (Memory, SimpleVector) under check_type
    outside = UInt32[]
    for (C, arr) in bare_array_partition(ctx.mod, reg, nothing).all
        C <: check_type ? (arr in kinds || push!(kinds, arr)) : push!(outside, arr)
    end
    if any(in(outside), kinds)
        _isa_reject!(bld, ctx, "isa(x, $(check_type)) cannot tell a Memory under it from one that is not: both are the same wasm array")
        return nothing
    end
    # a type object: a TypeVar is its own struct; a DataType, Union, UnionAll or Union{} is a
    # $JlType whose $kind names it (Union and UnionAll share one wasm struct)
    local codes = Int32[code for (K, code) in ((DataType, JL_TYPE_KIND_DATATYPE),
                        (Union, JL_TYPE_KIND_UNION), (UnionAll, JL_TYPE_KIND_UNIONALL),
                        (Core.TypeofBottom, JL_TYPE_KIND_BOTTOM)) if K <: check_type]
    local tv, jt = reg.jl_typevar_idx, reg.jl_type_idx
    local_get!(bld, UInt32(local_idx))
    ref_test!(bld, Int64(tv), false)
    if_!(bld; results=WasmValType[I32])
    i32_const!(bld, TypeVar <: check_type ? 1 : 0)
    else_!(bld)
    local_get!(bld, UInt32(local_idx))
    ref_test!(bld, Int64(jt), false)
    if_!(bld; results=WasmValType[I32])
    if isempty(codes)
        i32_const!(bld, 0)
    else
        local k = allocate_local!(ctx, I32)
        local_get!(bld, UInt32(local_idx))
        ref_cast!(bld, Int64(jt), false)
        struct_get!(bld, jt, UInt32(0), I32)
        local_set!(bld, k)
        for (i, code) in enumerate(codes)
            local_get!(bld, k); i32_const!(bld, Int64(code)); num!(bld, Opcode.I32_EQ)
            i > 1 && num!(bld, Opcode.I32_OR)
        end
    end
    else_!(bld)
    if isempty(kinds)
        i32_const!(bld, 0)
    else
        for (i, idx) in enumerate(kinds)
            local_get!(bld, UInt32(local_idx))
            ref_test!(bld, Int64(idx), false)
            i > 1 && num!(bld, Opcode.I32_OR)
        end
    end
    end_block!(bld)
    end_block!(bld)
    return nothing
end

# WASMTARGET dynamic dispatch (typeId switch). When a `dynamic` :call to a generic
# function can't resolve to a single specialization (an abstract/Any arg), instead
# of emitting `unreachable`, dispatch at runtime over the compiled specializations:
# read the dispatch arg's typeId (every struct carries an i32 typeId in field 0) and
# call the matching specialization. Surfaced by Markdown.plain/show recursing over
# heterogeneous AST nodes (md"…" rendering) and any `Any[…]`-of-structs + g(elt).
# Returns the bytes (result left in the inferred SSA wasm type), or nothing if the
# call doesn't qualify (caller then falls back to the `unreachable` stub).
# formal(dev/formal/ClassIdSwitch.tla): the call runs the specialization Julia selects, traps
# where Julia has none, and rejects a candidate class no test tells apart.
# parity(quarantine: WT dispatches a dynamic call inline over the classes that reach it; dart's dynamic dispatcher reads the classId and calls through its dispatch table, dynamic_dispatchers.dart:178 (dev/MARCH.md 13.7).)
function _try_inline_typeid_dispatch(ctx::AbstractCompilationContext, called_func,
                                     args, call_arg_types, idx::Int)::Union{Nothing, InstrBuilder}
    (ctx.func_registry === nothing || ctx.type_registry.base_struct_idx === nothing) && return nothing
    n = length(args)
    # Dispatch position = the single abstract/Any arg in the call's inferred types.
    absp = Int[p for p in 1:n if !(call_arg_types[p] isa DataType && isconcretetype(call_arg_types[p]))]
    length(absp) == 1 || return nothing      # multi-arg dispatch unsupported (v0)
    dpos = absp[1]
    # Candidate specializations: matching arity, matching every NON-dispatch arg to
    # this call site (so candidates from OTHER call sites — e.g. a different io type —
    # don't pollute the switch), differing on the dispatch arg.
    cands = FunctionInfo[]
    for (ref, infos) in ctx.func_registry.by_ref
        ref === called_func || continue
        for info in infos
            length(info.arg_types) == n || continue
            all(j -> j == dpos || info.arg_types[j] == call_arg_types[j], 1:n) || continue
            push!(cands, info)
        end
    end
    length(cands) < 2 && return nothing
    # Each candidate's dispatch type must carry a classId (a concrete struct, a boxed
    # numeric, the classed String/Symbol — every $JlTop subtype; emit_typeof! reads the
    # header) and have a concrete wasm representation for the callee's parameter: a
    # ConcreteRef the branch casts to, or a numeric the branch unboxes through the funnel.
    # Every wasm type here is read off the callee's declared signature (dart
    # BaseFunction.type), which is how its arguments and result cross: a MemoryRef
    # parameter is its single-value struct, not its bare Memory.
    branches = Tuple{Int32, WasmValType, FunctionInfo}[]
    for c in cands
        Tc = c.arg_types[dpos]
        (Tc isa DataType && isconcretetype(Tc) &&
         (isstructtype(Tc) || isprimitivetype(Tc))) || return nothing
        length(_function_type(ctx.mod, c.wasm_idx).params) == n || return nothing
        # a bare-array class (a Memory, a SimpleVector) is told apart only by an array type
        # no other class shares (emit_class_id!); a call with a candidate whose array type is
        # shared has no switch, and rejects at its statement where the switch would trap
        (Tc <: GenericMemory || Tc === Core.SimpleVector) &&
            Tc in bare_array_partition(ctx.mod, ctx.type_registry, call_arg_types[dpos]).shared && return nothing
        cw = _function_type(ctx.mod, c.wasm_idx).params[dpos]
        (cw isa ConcreteRef || cw in (I32, I64, F32, F64)) || return nothing
        tid = ensure_type_id!(ctx.type_registry, Tc)
        tid > 0 || return nothing
        push!(branches, (tid, cw, c))
    end

    isempty(branches) && return nothing
    result_julia = get(ctx.ssa_types, idx, Any)
    result_wasm = (result_julia isa Type && result_julia !== Nothing && result_julia !== Union{}) ?
        get_concrete_wasm_type(result_julia, ctx.mod, ctx.type_registry) : nothing

    # value-coercion helper: from-wasm on stack → to-wasm. (Emits into InstrBuilder cb.)
    coerce! = (cb, from, to, from_julia) -> begin
        from === to && return
        if to === AnyRef || to === EqRef
            if from === I32 || from === I64 || from === F32 || from === F64
                # Box numerics into the canonical {classId, value} box via THE single emitter —
                # the Any-int/float rep WT consumers unbox via `ref.cast (ref $box); struct.get 1`.
                emit_classid_box!(cb, ctx, from, from_julia)
            elseif from === ExternRef
                any_convert_extern!(cb)
            end  # ConcreteRef/StructRef already anyref-compatible
        elseif to isa ConcreteRef && (from isa ConcreteRef || from === StructRef || from === AnyRef || from === EqRef)
            ref_cast!(cb, Int64(to.type_idx), true)
        end
    end
    bld = _ctx_builder(ctx, "_try_inline_typeid_dispatch")
    # Compile every arg into a local (reused across branches).
    arg_locals = Int[]
    for (j, arg) in enumerate(args)
        if j == dpos
            emit_value!(bld, arg, ctx, AnyRef;
                        from_julia=(call_arg_types[j] isa Type && isconcretetype(call_arg_types[j])) ? call_arg_types[j] : nothing)
            aw = AnyRef
        else
            # the candidates agree on this argument's type, so on its wasm type
            aw = _function_type(ctx.mod, cands[1].wasm_idx).params[j]
            emit_value!(bld, arg, ctx, aw;
                        from_julia=(call_arg_types[j] isa Type && isconcretetype(call_arg_types[j])) ? call_arg_types[j] : nothing)
        end
        l = length(ctx.locals) + ctx.n_params; push!(ctx.locals, aw)
        local_set!(bld, l)
        push!(arg_locals, l)
    end
    # Read dispatch typeId into a local.
    local_get!(bld, arg_locals[dpos])
    emit_class_id!(bld, ctx, call_arg_types[dpos])
    tid_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I32)
    local_set!(bld, tid_local)

    emit_branch = (eb, tid, cw, c) -> begin
        for (j, l) in enumerate(arg_locals)
            local_get!(eb, l)
            if j == dpos
                # the row's class is proven: narrow the erased operand to the callee's
                # parameter (a concrete ref, or the unboxed numeric) through the funnel
                coerce_stack_top!(eb, cw, ctx; from_julia=c.arg_types[dpos])
            end
        end
        call!(eb, c.wasm_idx, WasmValType[], WasmValType[])
        rj = c.return_type
        local _c_results = _function_type(ctx.mod, c.wasm_idx).results
        rw = isempty(_c_results) ? nothing : _c_results[1]
        if result_wasm === nothing
            rw !== nothing && drop!(eb)
        elseif rw === nothing
            rj === Union{} || error("value-producing dynamic dispatch selected a void target")
            unreachable!(eb)  # structural trap: a bottom target never reaches the value merge
        else
            coerce!(eb, rw, result_wasm, rj)
        end
    end
    # Guarded if-chain over all branches; final else = unreachable (no method).
    nb = length(branches)
    for (tid, cw, c) in branches
        local_get!(bld, tid_local)
        i32_const!(bld, Int64(tid))
        num!(bld, Opcode.I32_EQ)
        if_!(bld; results=result_wasm === nothing ? WasmValType[] : WasmValType[result_wasm])
        local _bbr_b = _ctx_builder(ctx, "_try_inline_typeid_dispatch.branch")
        emit_branch(_bbr_b, tid, cw, c)
        append_builder!(bld, _bbr_b)   # typed merge
        else_!(bld)
    end
    unreachable!(bld)  # structural trap (dart-legit dead path)
    for _ in 1:nb; end_block!(bld); end
    # Heuristic-safe tail: land result in a scratch local, end with local.get.
    if result_wasm !== nothing
        rl = length(ctx.locals) + ctx.n_params; push!(ctx.locals, result_wasm)
        local_set!(bld, rl)
        local_get!(bld, rl)
    end
    return bld
end

"""
The closed world's answer to Julia's check_world_bounded for a TypeName: its bound range from
the TypeName's compile-time metadata, or nothing.
parity(quarantine: Julia's reflection over a TypeName's bindings, answered from the closed
world's metadata; a dart library is never reflected over at run time.)
"""
function emit_closed_world_type_bounds!(b::InstrBuilder, tn, ctx::AbstractCompilationContext)::InstrBuilder
    tn_idx = ctx.type_registry.jl_typename_idx
    range_info = haskey(ctx.type_registry.structs, UnitRange{Int64}) ?
                 ctx.type_registry.structs[UnitRange{Int64}] :
                 register_struct_type!(ctx.mod, ctx.type_registry, UnitRange{Int64})
    emit_value!(b, tn, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, UInt32(8), I32)
    if_!(b; results=WasmValType[AnyRef])
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, UnitRange{Int64})))
    i32_const!(b, 0) # ordinary immutable Object identity slot
    emit_value!(b, tn, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, UInt32(9), I64)
    emit_value!(b, tn, ctx, ConcreteRef(UInt32(tn_idx), true))
    struct_get!(b, tn_idx, UInt32(10), I64)
    struct_new!(b, range_info.wasm_type_idx, WasmValType[I32, I32, I64, I64])
    else_!(b)
    ref_null!(b, AnyRef)
    end_block!(b)
    return b
end

# parity(quarantine: Julia's reflection over a TypeName's bindings, answered from the closed world's metadata; a dart library is never reflected over at run time.)
function emit_closed_world_isvisible!(b::InstrBuilder, symbol, parent, from, owner,
                                      ctx::AbstractCompilationContext)::InstrBuilder
    module_info = ctx.type_registry.structs[Module]
    module_ref = ConcreteRef(module_info.wasm_type_idx, false)
    parent_local = allocate_local!(ctx, module_ref)
    from_local = allocate_local!(ctx, module_ref)
    emit_value!(b, parent, ctx, module_ref); local_set!(b, parent_local)
    emit_value!(b, from, ctx, module_ref); local_set!(b, from_local)

    local_get!(b, parent_local); local_get!(b, from_local); num!(b, Opcode.REF_EQ)
    if_!(b; results=WasmValType[I32])
    # Same module means the same binding, provided it is not deprecated.
    emit_typename_symbol_metadata!(b, symbol, owner, UInt32(11), UInt32(12), ctx)
    num!(b, Opcode.I32_EQZ)
    else_!(b)
    main_global = get_module_constant_global!(ctx.mod, ctx.type_registry, Main)
    local_get!(b, from_local); global_get!(b, main_global, module_ref)
    num!(b, Opcode.REF_EQ)
    if_!(b; results=WasmValType[I32])
    emit_typename_symbol_metadata!(b, symbol, owner, UInt32(13), UInt32(14), ctx)
    else_!(b)
    unreachable!(b)  # structural trap: visibility from this runtime Module was not collected
    end_block!(b)
    end_block!(b)
    return b
end

# parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)
function _emit_typeerror_throw!(b::InstrBuilder, got::NirNode, target::Type, idx::Int,
                                ctx::AbstractCompilationContext; func::Symbol=:typeassert)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    local info = register_struct_type!(ctx.mod, ctx.type_registry, TypeError)
    local def = ctx.mod.types[Int(info.wasm_type_idx) + 1]
    def isa StructType || error("TypeError did not register as a Wasm struct")
    emit_struct_prefix!(b, ctx.type_registry, TypeError, info)
    local values = NirNode[NirLiteral(func), NirLiteral(""), NirLiteral(target), got]
    for i in 1:4
        local expected = def.fields[wasm_field_idx(info, i) + 1].valtype
        local source_type = i == 4 ? get_ssa_type(ctx, got) : fieldtype(TypeError, i)
        emit_value!(b, values[i], ctx, expected;
                    from_julia=(source_type isa Type ? source_type : fieldtype(TypeError, i)))
    end
    struct_new!(b, info.wasm_type_idx)
    emit_throw_value!(b, ctx.mod)
    return b
end

"""
The callee's module-qualified name for a diagnostic — the object's own home, so the name
is the same whichever module the IR reached it through (`getglobal` is `Core.getglobal`
even when the IR names it `Base.getglobal`).
parity(target.dart:719 DiagnosticReporter.report): a located diagnostic names its target.
"""
_callee_label(f)::String = f isa GlobalRef ? string(f.mod, ".", f.name) :
    (f isa Function || f isa Core.Builtin) ? string(parentmodule(f), ".", nameof(f)) : string(f)

# formal(dev/formal/ConsultChain.tla): every call key reaches exactly one funnel or a loud reject; a declining funnel emits nothing
"""
Compile a function call expression — dart visitor shape; emits INTO the caller's builder.
The interior accumulates into a FRAGMENT builder `fb` (≡ the old `bytes` buffer,
same discard semantics: arms that clear/replace it re-init; exits merge typed). A Julia
`:call` names a builtin or an intrinsic, lowered as dart lowers its intrinsics.
parity(pkg/dart2wasm/lib/intrinsics.dart:1194 Intrinsifier.generateStaticIntrinsic)
"""
function compile_call!(b::InstrBuilder, node::NirCall, idx::Int, ctx::AbstractCompilationContext)::InstrBuilder
    fb = _ctx_builder(ctx, "compile_call.frag")
    set_context!(fb, first(_nir_text(node), 80))   # errors name the call
    # A call may consume values stack-threaded by the enclosing statement fragment.
    # Preserve that tracked input across this second fragment boundary just as
    # compile_statement! preserves the parent builder's input. Without it, Julia
    # 1.13 escaping-closure arithmetic emits valid operand bytes but the validator
    # sees an empty fragment stack and reports a false underflow.
    isempty(b.v.stack) || seed_input!(fb, copy(b.v.stack))
    _boxed_operand_unboxed = false   # FUNCTION-TOP scope (a mid-function init sat in a closed scope — the tail arm read @isdefined=false on every call)
    # The callee the NIR boundary resolved ONCE (frontend/nir.jl): a function object when
    # the IR named it statically — through a global, an SSA alias of one, a `Core.Const`,
    # or a singleton-typed argument — a `GlobalRef` when that global is unbound, else the
    # operand node (a literal callee, or a runtime value).
    func = node.callee
    args = node.operands
    # the callee Julia reached through a binding (every name-keyed call below)
    named = !(func isa NirNode)

    # THE identity-keyed Core/Base builtin funnel (builtins.jl), consulted ONCE
    # on the ONE resolved callee — dart resolves a call's target a single time
    # (`KernelNodes._lookup`, intrinsics.dart:401) and dispatches from that one
    # identity; the historical double consult (raw callee, then resolved) only
    # existed because the `getglobal` TypeName fragment sat between the two.
    # Every self-contained arm that compiles its own operands and independently
    # returns lives behind this funnel (dart's nullable-return entry-funnel
    # shape; formal(dev/formal/ConsultChain.tla)). An entry that historically
    # had several ladder fragments — `getfield`/`getproperty`/`setfield!`/
    # `setproperty!`, `getglobal` — holds them as its OWN guards, in their
    # original relative order, with the raw-identity guards (closure
    # self-capture skip, `:signal` skip) on the exact callee identity that
    # satisfied them.
    let _bl = _try_builtin_lowering!(b, fb, ctx, node, idx, args, func)
        _bl === nothing || return _bl
    end

    # Handle signal getter/setter SSA function calls: (%ssa)() or (%ssa)(value)
    # When func is an SSA that represents a captured signal getter/setter,
    # emit global.get/global.set directly (same logic as compile_invoke)
    if func isa NirSSA
        ssa_id = func.id
        # Signal getter: no args, returns the signal value
        if haskey(ctx.signal_ssa_getters, ssa_id) && isempty(args)
            global_idx = ctx.signal_ssa_getters[ssa_id]
            global_get!(fb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            return append_builder!(b, fb)
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            local _ssgb = _ctx_builder(ctx, "compile_call")
            # Compile the argument (the new value)
            emit_value!(_ssgb, args[1], ctx, ctx.mod.globals[global_idx + 1].valtype)
            # Store to global
            global_set!(_ssgb, global_idx)

            # Inject DOM update calls for this signal (Therapy.jl reactive updates)
            if haskey(ctx.dom_bindings, global_idx)
                # Get global's type for conversion
                global_type = ctx.mod.globals[global_idx + 1].valtype

                for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                    # Push constant arguments (e.g., hydration key)
                    for arg in const_args
                        i32_const!(_ssgb, Int(arg))
                    end
                    # Push the signal value (re-read from global)
                    global_get!(_ssgb, global_idx, global_type)
                    # Convert to f64 for DOM imports (all DOM imports expect f64)
                    emit_convert_to_f64!(_ssgb, global_type)
                    # Call the DOM import function
                    call!(_ssgb, import_idx, WasmValType[], WasmValType[])
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            global_get!(_ssgb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            append_builder!(fb, _ssgb)
            return append_builder!(b, fb)
        end
    end

    # A DYNAMIC function-value call — the callee is a runtime value
    # whose static type is erased or a union containing only Function subtypes. Ride
    # the closure vtable: the OBJECT
    # was created at the erasure seam; entry[arity] → call_ref (dart: fieldIndexFor-
    # Signature + call_ref). Devirtualizable callees (concrete/small-union types)
    # never reach here — the existing paths outrank.
    if is_runtime_ir_value(func)
        local _dfc_t = infer_value_type(func, ctx)
        if is_callable_julia_type(_dfc_t) &&
           emit_dynamic_closure_call!(fb, ctx, func, args, idx) === true
            return append_builder!(b, fb)
        end
    end

    # Determine argument type for opcode selection (do this BEFORE compiling args)
    # — THE shared classification (builtins.jl), so this ladder and the
    # self-contained operator entries read one definition of a call's width.
    arg_type, is_32bit, is_128bit = _call_operand_shape(args, ctx)

    # If arg_type is Any/abstract but the intrinsic expects numeric operands,
    # the code is type-confused (externref being used as numeric). Emit unreachable
    # since we can't convert externref to i64 in Wasm. (See intrinsics_table.jl's
    # NUMERIC_INTRINSIC_ARG_OPS for why this stays a curated int-only Set rather
    # than a raw INTRINSIC_BINOPS/UNOPS membership query.)
    is_numeric_intrinsic = is_numeric_intrinsic_arg(func)
    if is_numeric_intrinsic && (arg_type === Any ||
                                 (!isprimitivetype(arg_type) && !is_128bit && !(arg_type <: Integer)))
        # An Any/externref value used in a numeric intrinsic (boxing / type instability).
        # Loud reject — natively the op runs on the concrete value, so a silent trap diverges.
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "numeric intrinsic on a non-concrete (Any/boxed) operand — type instability"; idx=idx)
        return append_builder!(b, fb)
    end

    # Handle pointer arithmetic intrinsics BEFORE the generic arg pre-push.
    # add_ptr, sub_ptr, and pointerref push their own args (or trace back to string ref),
    # so they must NOT have args pre-pushed by the generic loop below.
    if func === Core.Intrinsics.add_ptr
        emit_value!(fb, args[1], ctx, I64)
        emit_value!(fb, args[2], ctx, I64)
        num!(fb, Opcode.I64_ADD)
        return append_builder!(b, fb)
    elseif func === Core.Intrinsics.sub_ptr
        emit_value!(fb, args[1], ctx, I64)
        emit_value!(fb, args[2], ctx, I64)
        num!(fb, Opcode.I64_SUB)
        return append_builder!(b, fb)
    elseif func === Core.Intrinsics.pointerref
        ptr_arg = length(args) >= 1 ? args[1] : nothing
        # P3 gap 450889a9cb7e: DataType layout-metadata loads
        # (datatype_layoutsize/arrayelem in inlined _unsetindex!) — the layout
        # pointer is compile-time host metadata; fold the whole load.
        local _pr_fold = _try_fold_layout_pointerref(ptr_arg, ctx)
        if _pr_fold !== nothing
            emit_value!(fb, NirLiteral(_pr_fold), ctx, static_wasm_type(NirLiteral(_pr_fold), ctx))
            return append_builder!(b, fb)
        end
        # P3 gap 450889a9cb7e: byte reads through Vector{UInt8} storage pointers
        # (Ryu digit readback). Fake base pointers compile to 0, so the pointer
        # VALUE is the 0-based byte offset.
        local _pr_tp0 = begin
            local _t = ptr_arg !== nothing ? infer_value_type(ptr_arg, ctx) : nothing
            _t isa DataType && _t <: Ptr ? eltype(_t) : nothing
        end
        local _pr_vec = ptr_arg !== nothing ? _trace_memmove_ptr(ptr_arg, ctx) : nothing
        if _pr_vec !== nothing && (_pr_tp0 === UInt8 || _pr_tp0 === Int8 || _pr_tp0 === Nothing || _pr_tp0 === nothing)
            local _pr_arr_t = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
            local _prvb = _ctx_builder(ctx, "compile_call")
            _emit_backing_array!(_prvb, _pr_vec, ctx, _pr_arr_t)
            _emit_storage_pointer_offset!(_prvb, ctx, ptr_arg, length(args) >= 2 ? args[2] : nothing, _pr_vec, 1)
            array_get!(_prvb, _pr_arr_t, I32; signed=false)
            append_builder!(fb, _prvb)
            return append_builder!(b, fb)
        elseif _pr_vec !== nothing && _pr_tp0 isa DataType && isprimitivetype(_pr_tp0) &&
               sizeof(_pr_tp0) in (2, 4, 8)
            # P4-stdlib (SHA transform!): WIDE loads (Ptr{UInt32/UInt64})
            # from Vector{UInt8} storage — the 1-byte fast path above served
            # a single byte here, silently corrupting the message schedule.
            # Assemble the word little-endian from s consecutive bytes.
            local _prw_s = sizeof(_pr_tp0)
            local _prw_arr = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
            local _prw_w64 = _prw_s == 8 || _pr_tp0 === Float64
            # scratch: arr ref + base index
            local _prw_la = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, ConcreteRef(_prw_arr, true))
            local _prw_lb = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            local _prwb = _ctx_builder(ctx, "compile_call")
            _emit_backing_array!(_prwb, _pr_vec, ctx, _prw_arr)
            local_set!(_prwb, _prw_la)
            _emit_storage_pointer_offset!(_prwb, ctx, ptr_arg, length(args) >= 2 ? args[2] : nothing, _pr_vec, _prw_s)
            local_set!(_prwb, _prw_lb)
            for _prw_k in 0:(_prw_s - 1)
                local_get!(_prwb, _prw_la)
                local_get!(_prwb, _prw_lb)
                if _prw_k > 0
                    i32_const!(_prwb, Int64(_prw_k))
                    num!(_prwb, Opcode.I32_ADD)
                end
                array_get!(_prwb, _prw_arr, I32; signed=false)
                if _prw_w64
                    num!(_prwb, Opcode.I64_EXTEND_I32_U)
                    if _prw_k > 0
                        i64_const!(_prwb, Int64(8 * _prw_k))
                        num!(_prwb, Opcode.I64_SHL)
                    end
                    _prw_k > 0 && num!(_prwb, Opcode.I64_OR)
                else
                    if _prw_k > 0
                        i32_const!(_prwb, Int64(8 * _prw_k))
                        num!(_prwb, Opcode.I32_SHL)
                        num!(_prwb, Opcode.I32_OR)
                    end
                end
            end
            if _pr_tp0 === Float64
                num!(_prwb, Opcode.F64_REINTERPRET_I64)
            elseif _pr_tp0 === Float32
                num!(_prwb, Opcode.F32_REINTERPRET_I32)
            end
            append_builder!(fb, _prwb)
            return append_builder!(b, fb)
        end
        # P4-stdlib (Random digest!): CROSS-WIDTH byte reads — Ptr{UInt8}
        # into Vector{UInt32/UInt64/...} storage (SHA reads its u32 state
        # byte-wise). elem = arr[byteoff >> log2(s)]; byte = (elem >>
        # (8*(byteoff & (s-1)))) & 0xFF (little-endian; mirror of the
        # cross-width pointerset).
        local _PRB_WIDE = (Int16, UInt16, Int32, UInt32, Int64, UInt64)
        local _prb_tp = begin
            local _t = ptr_arg !== nothing ? infer_value_type(ptr_arg, ctx) : nothing
            _t isa DataType && _t <: Ptr ? eltype(_t) : nothing
        end
        local _prb_vec = (ptr_arg !== nothing && (_prb_tp === UInt8 || _prb_tp === Int8)) ?
            _trace_memmove_ptr(ptr_arg, ctx; eltypes = _PRB_WIDE) : nothing
        if _prb_vec !== nothing
            local _prb_te = eltype(infer_value_type(_prb_vec, ctx))
            local _prb_s = sizeof(_prb_te)
            local _prb_arr = get_array_type!(ctx.mod, ctx.type_registry, _prb_te)
            local _prb_w64 = _prb_s == 8
            # scratch: byte offset (i32)
            local _prb_lb = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I32)
            local _prbb = _ctx_builder(ctx, "compile_call")
            # byte offset = ptr - base + (i-1)   (pointer target is 1 byte wide)
            _emit_storage_pointer_offset!(_prbb, ctx, ptr_arg, length(args) >= 2 ? args[2] : nothing, _prb_vec, 1)
            local_set!(_prbb, _prb_lb)
            # arr ref
            _emit_backing_array!(_prbb, _prb_vec, ctx, _prb_arr)
            # elem index = b >> log2(s)
            local_get!(_prbb, _prb_lb)
            i32_const!(_prbb, Int64(trailing_zeros(_prb_s)))
            num!(_prbb, Opcode.I32_SHR_U)
            array_get!(_prbb, _prb_arr, I32; signed=(_prb_s <= 2 ? false : nothing))
            # shift = 8 * (b & (s-1))
            local_get!(_prbb, _prb_lb)
            i32_const!(_prbb, Int64(_prb_s - 1))
            num!(_prbb, Opcode.I32_AND)
            i32_const!(_prbb, Int64(3))
            num!(_prbb, Opcode.I32_SHL)
            if _prb_w64
                num!(_prbb, Opcode.I64_EXTEND_I32_U)
                num!(_prbb, Opcode.I64_SHR_U)
                num!(_prbb, Opcode.I32_WRAP_I64)
            else
                num!(_prbb, Opcode.I32_SHR_U)
            end
            i32_const!(_prbb, Int64(0xFF))
            num!(_prbb, Opcode.I32_AND)
            append_builder!(fb, _prbb)
            return append_builder!(b, fb)
        end
        # P4-stdlib (Statistics median/quantile): TYPED loads through
        # Vector{T} storage pointers — sort's radix path reads UInt64 through
        # Ptr{UInt64} into Float64 storage (reinterpret(uinttype(T), v)).
        # The pointer value is the proven storage-relative byte offset;
        # element index = (ptr + (i-1)*sizeof(Te)) >> log2(sizeof(Te));
        # a same-size reinterpret bridges element type vs pointer target.
        local _PRG_PRIMS = (Int8, UInt8, Int16, UInt16, Int32, UInt32,
                            Int64, UInt64, Float32, Float64)
        local _prg_tp = begin
            local _t = ptr_arg !== nothing ? infer_value_type(ptr_arg, ctx) : nothing
            _t isa DataType && _t <: Ptr ? eltype(_t) : nothing
        end
        local _prg_vec = (ptr_arg !== nothing && _prg_tp in _PRG_PRIMS) ?
            _trace_memmove_ptr(ptr_arg, ctx; eltypes = _PRG_PRIMS, allow_ref = true) : nothing
        if _prg_vec !== nothing && begin
                local _t = infer_value_type(_prg_vec, ctx)
                _t isa DataType && _t <: Base.RefValue
            end
            # Pointer into a RefValue{T} box: load is struct.get of field :x
            local _prr_rt = infer_value_type(_prg_vec, ctx)
            local _prr_te = _prr_rt.parameters[1]
            if _prr_te in _PRG_PRIMS && sizeof(_prr_te) == sizeof(_prg_tp)
                if !haskey(ctx.type_registry.structs, _prr_rt)
                    register_struct_type!(ctx.mod, ctx.type_registry, _prr_rt)
                end
                local _prr_info = ctx.type_registry.structs[_prr_rt]
                local _prrb = _ctx_builder(ctx, "compile_call")
                emit_value!(_prrb, _prg_vec, ctx,
                            ConcreteRef(UInt32(_prr_info.wasm_type_idx), true))
                ref_cast!(_prrb, Int64(_prr_info.wasm_type_idx), true)
                struct_get!(_prrb, _prr_info.wasm_type_idx, wasm_field_idx(_prr_info, 1), julia_to_wasm_type(_prr_te))
                if _prr_te === Float64 && (_prg_tp === UInt64 || _prg_tp === Int64)
                    num!(_prrb, Opcode.I64_REINTERPRET_F64)
                elseif (_prr_te === UInt64 || _prr_te === Int64) && _prg_tp === Float64
                    num!(_prrb, Opcode.F64_REINTERPRET_I64)
                elseif _prr_te === Float32 && (_prg_tp === UInt32 || _prg_tp === Int32)
                    num!(_prrb, Opcode.I32_REINTERPRET_F32)
                elseif (_prr_te === UInt32 || _prr_te === Int32) && _prg_tp === Float32
                    num!(_prrb, Opcode.F32_REINTERPRET_I32)
                end
                append_builder!(fb, _prrb)
                return append_builder!(b, fb)
            end
        elseif _prg_vec !== nothing
            local _prg_vt = infer_value_type(_prg_vec, ctx)
            local _prg_te = eltype(_prg_vt)
            if sizeof(_prg_te) == sizeof(_prg_tp) && sizeof(_prg_te) in (4, 8)
                local _prg_arr = get_array_type!(ctx.mod, ctx.type_registry, _prg_te)
                local _prgb = _ctx_builder(ctx, "compile_call")
                local _prg_vinfo = ctx.type_registry.structs[_prg_vt]
                emit_value!(_prgb, _prg_vec, ctx,
                            ConcreteRef(UInt32(_prg_vinfo.wasm_type_idx), true))
                struct_get!(_prgb, _prg_vinfo.wasm_type_idx, wasm_field_idx(_prg_vinfo, 1), ConcreteRef(_prg_arr, true))
                ref_cast!(_prgb, Int64(_prg_arr), true)
                _emit_storage_pointer_offset!(_prgb, ctx, ptr_arg, length(args) >= 2 ? args[2] : nothing,
                                              _prg_vec, sizeof(_prg_te))
                i32_const!(_prgb, Int64(trailing_zeros(sizeof(_prg_te))))
                num!(_prgb, Opcode.I32_SHR_U)
                array_get!(_prgb, _prg_arr, julia_to_wasm_type(_prg_te);
                           signed=packed_array_signedness(_prg_te))
                if _prg_te === Float64 && (_prg_tp === UInt64 || _prg_tp === Int64)
                    num!(_prgb, Opcode.I64_REINTERPRET_F64)
                elseif (_prg_te === UInt64 || _prg_te === Int64) && _prg_tp === Float64
                    num!(_prgb, Opcode.F64_REINTERPRET_I64)
                elseif _prg_te === Float32 && (_prg_tp === UInt32 || _prg_tp === Int32)
                    num!(_prgb, Opcode.I32_REINTERPRET_F32)
                elseif (_prg_te === UInt32 || _prg_te === Int32) && _prg_tp === Float32
                    num!(_prgb, Opcode.F32_REINTERPRET_I32)
                end
                append_builder!(fb, _prgb)
                return append_builder!(b, fb)
            end
        end
        let _prub = _ctx_builder(ctx, "compile_call")
            record_unsupported!(ctx, :unsupported_method,
                                "pointerref source cannot be traced to WasmGC storage";
                                idx=idx, detail=node)
            unreachable!(_prub); append_builder!(fb, _prub)  # structural trap after recorded unsupported
        end
        ctx.last_stmt_was_stub = true
        return append_builder!(b, fb)
    elseif func === Core.Intrinsics.pointerset
        # P3 gap 450889a9cb7e: byte writes through Vector{UInt8} storage
        # pointers (Ryu digit emission). pointerset(ptr, value, i, align)
        # returns the original pointer.
        local _ps_ptr = length(args) >= 1 ? args[1] : nothing
        local _ps_vec = _ps_ptr !== nothing ? _trace_memmove_ptr(_ps_ptr, ctx) : nothing
        local _ps_vt = length(args) >= 2 ? infer_value_type(args[2], ctx) : nothing
        if _ps_vec !== nothing && (_ps_vt === UInt8 || _ps_vt === Int8)
            local _ps_arr_t = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
            local _psb = _ctx_builder(ctx, "compile_call")
            _emit_backing_array!(_psb, _ps_vec, ctx, _ps_arr_t)
            _emit_storage_pointer_offset!(_psb, ctx, _ps_ptr, length(args) >= 3 ? args[3] : nothing, _ps_vec, 1)
            emit_value!(_psb, args[2], ctx, I32)
            array_set!(_psb, _ps_arr_t, I32)
            emit_value!(_psb, _ps_ptr, ctx, I64)
            append_builder!(fb, _psb)
            return append_builder!(b, fb)
        end
        # P4-stdlib: TYPED writes through Vector{T} storage pointers —
        # mirror of the typed pointerref path (radix sort scatter phase).
        # pointerset(ptr, value, i, align); same index arithmetic; the value
        # reinterprets from the pointer target type to the element type.
        local _PSG_PRIMS = (Int8, UInt8, Int16, UInt16, Int32, UInt32,
                            Int64, UInt64, Float32, Float64)
        local _psg_tp = begin
            local _t = _ps_ptr !== nothing ? infer_value_type(_ps_ptr, ctx) : nothing
            _t isa DataType && _t <: Ptr ? eltype(_t) : nothing
        end
        local _psg_vec = (_ps_ptr !== nothing && _psg_tp in _PSG_PRIMS) ?
            _trace_memmove_ptr(_ps_ptr, ctx; eltypes = _PSG_PRIMS, allow_ref = true) : nothing
        if _psg_vec !== nothing && length(args) >= 2 && begin
                local _t = infer_value_type(_psg_vec, ctx)
                _t isa DataType && _t <: Base.RefValue
            end
            local _psr_rt = infer_value_type(_psg_vec, ctx)
            local _psr_te = _psr_rt.parameters[1]
            if _psr_te in _PSG_PRIMS && sizeof(_psr_te) == sizeof(_psg_tp)
                if !haskey(ctx.type_registry.structs, _psr_rt)
                    register_struct_type!(ctx.mod, ctx.type_registry, _psr_rt)
                end
                local _psr_info = ctx.type_registry.structs[_psr_rt]
                local _psrb = _ctx_builder(ctx, "compile_call")
                emit_value!(_psrb, _psg_vec, ctx,
                            ConcreteRef(UInt32(_psr_info.wasm_type_idx), true))
                ref_cast!(_psrb, Int64(_psr_info.wasm_type_idx), true)
                emit_value!(_psrb, args[2], ctx, julia_to_wasm_type(_psg_tp))
                if _psr_te === Float64 && (_psg_tp === UInt64 || _psg_tp === Int64)
                    num!(_psrb, Opcode.F64_REINTERPRET_I64)
                elseif (_psr_te === UInt64 || _psr_te === Int64) && _psg_tp === Float64
                    num!(_psrb, Opcode.I64_REINTERPRET_F64)
                elseif _psr_te === Float32 && (_psg_tp === UInt32 || _psg_tp === Int32)
                    num!(_psrb, Opcode.F32_REINTERPRET_I32)
                elseif (_psr_te === UInt32 || _psr_te === Int32) && _psg_tp === Float32
                    num!(_psrb, Opcode.I32_REINTERPRET_F32)
                end
                struct_set!(_psrb, _psr_info.wasm_type_idx, wasm_field_idx(_psr_info, 1), julia_to_wasm_type(_psr_te))
                emit_value!(_psrb, _ps_ptr, ctx, I64)
                append_builder!(fb, _psrb)
                return append_builder!(b, fb)
            end
        elseif _psg_vec !== nothing && length(args) >= 2
            local _psg_vt = infer_value_type(_psg_vec, ctx)
            local _psg_te = eltype(_psg_vt)
            if sizeof(_psg_te) == sizeof(_psg_tp) && sizeof(_psg_te) in (4, 8)
                local _psg_arr = get_array_type!(ctx.mod, ctx.type_registry, _psg_te)
                local _psgb = _ctx_builder(ctx, "compile_call")
                # A Memory/GenericMemory value IS the raw data array (no vector-struct
                # wrapper) — just cast it. A Vector is a {typeId, data-array, size}
                # struct → struct.get field 1 to reach the array. (The old code did an
                # unconditional `structs[_psg_vt]` direct lookup, which both crashed on
                # Memory and was ORDER-DEPENDENT — KeyError when a perturbed compile
                # order left _psg_vt unregistered. Register-or-guard fixes both.)
                local _psg_is_mem = _psg_vt isa DataType &&
                    _psg_vt.name.name in (:Memory, :GenericMemory, :MemoryRef, :GenericMemoryRef)
                if _psg_is_mem
                    # a ref's storage is its Memory; its offset rides the pointer
                    emit_memoryref_mem!(_psgb, ctx, _psg_vec, ConcreteRef(UInt32(_psg_arr), true))
                end
                if !_psg_is_mem
                    if !haskey(ctx.type_registry.structs, _psg_vt)
                        register_struct_type!(ctx.mod, ctx.type_registry, _psg_vt)
                    end
                    local _psg_vinfo = ctx.type_registry.structs[_psg_vt]
                    emit_value!(_psgb, _psg_vec, ctx,
                                ConcreteRef(UInt32(_psg_vinfo.wasm_type_idx), true))
                    struct_get!(_psgb, _psg_vinfo.wasm_type_idx, wasm_field_idx(_psg_vinfo, 1), ConcreteRef(_psg_arr, true))
                end
                ref_cast!(_psgb, Int64(_psg_arr), true)
                _emit_storage_pointer_offset!(_psgb, ctx, _ps_ptr, length(args) >= 3 ? args[3] : nothing,
                                              _psg_vec, sizeof(_psg_te))
                i32_const!(_psgb, Int64(trailing_zeros(sizeof(_psg_te))))
                num!(_psgb, Opcode.I32_SHR_U)
                emit_value!(_psgb, args[2], ctx, julia_to_wasm_type(_psg_tp))
                if _psg_te === Float64 && (_psg_tp === UInt64 || _psg_tp === Int64)
                    num!(_psgb, Opcode.F64_REINTERPRET_I64)
                elseif (_psg_te === UInt64 || _psg_te === Int64) && _psg_tp === Float64
                    num!(_psgb, Opcode.I64_REINTERPRET_F64)
                elseif _psg_te === Float32 && (_psg_tp === UInt32 || _psg_tp === Int32)
                    num!(_psgb, Opcode.F32_REINTERPRET_I32)
                elseif (_psg_te === UInt32 || _psg_te === Int32) && _psg_tp === Float32
                    num!(_psgb, Opcode.I32_REINTERPRET_F32)
                end
                array_set!(_psgb, _psg_arr, julia_to_wasm_type(_psg_te))
                emit_value!(_psgb, _ps_ptr, ctx, I64)
                append_builder!(fb, _psgb)
                return append_builder!(b, fb)
            end
        end
        # P4-stdlib (Random digest!): CROSS-WIDTH store — Ptr{UInt128/64/32/16}
        # into Vector{UInt8} storage (SHA writes the bitlength, and SHA-512 its 128-bit
        # state words, into its byte buffer). Emit little-endian byte-wise array.set stores;
        # a 128-bit value's bytes are its low limb's, then its high limb's.
        local _psw_vec = (_ps_ptr !== nothing && _psg_tp isa DataType &&
                          isprimitivetype(_psg_tp) && sizeof(_psg_tp) in (2, 4, 8, 16)) ?
            _trace_memmove_ptr(_ps_ptr, ctx) : nothing
        if _psw_vec !== nothing && length(args) >= 2
            local _psw_te = eltype(infer_value_type(_psw_vec, ctx))
            if _psw_te === UInt8 || _psw_te === Int8
                local _psw_arr = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
                local _psw_s = sizeof(_psg_tp)
                # scratch locals: array ref, base byte index, value (i64)
                local _psw_la = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, ConcreteRef(_psw_arr, true))
                local _psw_li = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, I32)
                local _psw_lv = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, I64)
                local _pswb = _ctx_builder(ctx, "compile_call")
                # array ref
                _emit_backing_array!(_pswb, _psw_vec, ctx, _psw_arr)
                local_set!(_pswb, _psw_la)
                # base byte index = ptr - base + (i-1)*s
                _emit_storage_pointer_offset!(_pswb, ctx, _ps_ptr, length(args) >= 3 ? args[3] : nothing, _psw_vec, _psw_s)
                local_set!(_pswb, _psw_li)
                # value as i64 (extend 32-bit values); a 128-bit value as its two limbs
                local _psw_lh = _psw_lv
                if _psw_s == 16
                    local _psw_it = get_int128_type!(ctx.mod, ctx.type_registry, _psg_tp)
                    local _psw_lx = allocate_local!(ctx, ConcreteRef(_psw_it, true))
                    _psw_lh = allocate_local!(ctx, I64)
                    emit_value!(_pswb, args[2], ctx, ConcreteRef(_psw_it, true))
                    local_set!(_pswb, _psw_lx)
                    local_get!(_pswb, _psw_lx); struct_get!(_pswb, _psw_it, 2, I64); local_set!(_pswb, _psw_lh)
                    local_get!(_pswb, _psw_lx); struct_get!(_pswb, _psw_it, 1, I64)
                else
                    local _psw_vw = julia_to_wasm_type(_psg_tp)
                    emit_value!(_pswb, args[2], ctx, _psw_vw)
                    _psw_vw === I32 && num!(_pswb, Opcode.I64_EXTEND_I32_U)
                    _psw_vw === F64 && num!(_pswb, Opcode.I64_REINTERPRET_F64)
                end
                local_set!(_pswb, _psw_lv)
                for _psw_k in 0:(_psw_s - 1)
                    local_get!(_pswb, _psw_la)
                    local_get!(_pswb, _psw_li)
                    if _psw_k > 0
                        i32_const!(_pswb, Int64(_psw_k))
                        num!(_pswb, Opcode.I32_ADD)
                    end
                    local_get!(_pswb, _psw_k < 8 ? _psw_lv : _psw_lh)
                    if _psw_k % 8 > 0
                        i64_const!(_pswb, Int64(8 * (_psw_k % 8)))
                        num!(_pswb, Opcode.I64_SHR_U)
                    end
                    num!(_pswb, Opcode.I32_WRAP_I64)
                    array_set!(_pswb, _psw_arr, I32)
                end
                emit_value!(_pswb, _ps_ptr, ctx, I64)
                append_builder!(fb, _pswb)
                return append_builder!(b, fb)
            end
        end
        let _psub = _ctx_builder(ctx, "compile_call")
            record_unsupported!(ctx, :unsupported_method, "un-lowerable pushfirst!/array-mutation call shape"; idx=idx)
            unreachable!(_psub); append_builder!(fb, _psub)
        end
        ctx.last_stmt_was_stub = true
        return append_builder!(b, fb)
    end

    # 128-bit overflow-checked add/sub/mul (the Tuple{T,Bool} intrinsics) has no limb lowering:
    # reject before the arguments are pushed. Division and remainder are INT128_OPS entries.
    if (arg_type === Int128 || arg_type === UInt128) && func isa Core.IntrinsicFunction && nameof(func) in
            (:checked_smul_int, :checked_umul_int, :checked_sadd_int, :checked_uadd_int,
             :checked_ssub_int, :checked_usub_int)
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "128-bit overflow-checked arithmetic (Int128/UInt128)"; idx=idx)
        return append_builder!(b, fb)
    end

    # Push arguments onto the stack (normal case)
    # Skip Type arguments (e.g., first arg of sext_int, zext_int, trunc_int, bitcast)
    # These are compile-time type parameters, not runtime values.
    # Skip arg-pushing for cross-call candidates — the cross-call handler
    # at line ~20714 pushes args with type bridging. Pre-pushing here causes duplicate
    # args on the stack (e.g., setindex! gets 6 args instead of 3).
    # Cross-call candidates are GlobalRef functions found in the func_registry that
    # aren't handled by a specific earlier handler. `===`/`!==`/`isa`/`+`/`-`/`*`
    # and Core._expr never reach this point at all: THE identity-keyed builtin
    # funnel (builtins.jl) claims them, self-contained operands and all, before
    # the ladder above even starts — which is why no `is_equality_comparison`
    # carve-out survives here.
    # Arithmetic over an escaping mutable capture reaches us as a local-backed
    # `getfield(box, :contents)` SSA plus another operand. The numeric fallback
    # below owns that operation and must load the locals; a collected Base method
    # must not suppress both arguments. Keep ordinary arithmetic on the late
    # cross-call route, since a local-less operand may itself be a dynamic call
    # (the megamorphic accumulator) whose dispatch-table lowering must remain intact.
    is_generic_arithmetic = func === (+) || func === (-) || func === (*) ||
                            func === div || func === rem || func === mod
    is_materialized_generic_arithmetic = is_generic_arithmetic && all(args) do a
        !(a isa NirSSA) || haskey(ctx.ssa_locals, a.id) ||
            haskey(ctx.phi_locals, a.id)
    end
    has_box_contents_operand = any(args) do a
        local parts = _getfield_parts(_ssa_def(a, ctx))
        parts !== nothing && parts[2] === :contents
    end
    owns_captured_arithmetic = is_materialized_generic_arithmetic && has_box_contents_operand
    _skip_arg_prepush = false
    if !_skip_arg_prepush && named && ctx.func_registry !== nothing &&
            !is_numeric_intrinsic && !owns_captured_arithmetic
        _called_func = func isa GlobalRef ? nothing : func   # an unbound global names nothing
        if _called_func !== nothing
            _call_arg_types = tuple([infer_value_type(a, ctx) for a in args]...)
            _target = get_function(ctx.func_registry, _called_func, _call_arg_types)
            if _target === nothing && typeof(_called_func) <: Function && isconcretetype(typeof(_called_func))
                _target = get_function(ctx.func_registry, _called_func, (typeof(_called_func), _call_arg_types...))
            end
            # Keep argument ownership aligned with late exact-candidate
            # devirtualization. A proven candidate is a cross-call too, so only
            # its typed call arm may emit the arguments.
            _target === nothing &&
                (_target = get_exact_candidate(ctx.func_registry, _called_func, _call_arg_types))
            _skip_arg_prepush = _target !== nothing
        end
    end
    # THE single callee-identity extraction (the intrinsic's name — every table below is
    # keyed on intrinsic names) — the intrinsics-table route and the quarantine-tier
    # registry route below reuse this SAME local instead of re-deriving it a second time
    # (R19: a data test against `_it_name`, never a fresh `is_func` probe).
    local _it_name = nir_const(func) isa Core.IntrinsicFunction ? nameof(nir_const(func)) : nothing

    for arg in args
        if _skip_arg_prepush
            continue
        end
        # Skip Type args for intrinsics (e.g., sext_int(Int64, x)) — THE shared
        # rule (values.jl), so the self-contained BUILTIN_LOWERINGS entries that
        # emit their own operands classify a Type argument identically.
        _is_type_operand(arg) && continue
        local _ia_ty = emit_call_operand!(fb, ctx, arg)
        # Fix i32/i64 mismatch for numeric intrinsics — driven by the
        # emission's OWN type now (was the get_phi_edge_wasm_type re-guess).
        if is_numeric_intrinsic && !_is_externref_value(arg, ctx)
            _actual_wasm = _ia_ty
            if is_32bit && _actual_wasm === I64
                num!(fb, Opcode.I32_WRAP_I64)
            elseif !is_32bit && !is_128bit && _actual_wasm === I32
                num!(fb, Opcode.I64_EXTEND_I32_S)
            end
        end
        # P4-stdlib (Random hash_seed): unbox ANYREF-housed numeric args —
        # Any-returning callees (e.g. _foldl_impl) box numerics, and
        # Union{Nothing, UInt64}-style SSAs live in AnyRef locals; consuming
        # them raw in i64 arithmetic failed validation. Mirror of the
        # externref unbox below, minus any_convert_extern. Gated on the
        # ACTUAL local type (type-derived guesses say I64 for these unions) —
        # THE shared predicate (values.jl), which `_lower_arith!` reuses.
        # Fires for the GENERIC arithmetic operators (div/rem/mod here; +,-,*
        # own their operands in builtins.jl) too: dynamic call sites with
        # everything typed Any (e.g. `4 - %foldl` in Random.hash_seed) default
        # to the i64 opcodes but consume raw anyref.
        if (is_numeric_intrinsic || is_generic_arithmetic) && _is_boxed_numeric_operand(arg, ctx)
            local _aa_target = is_32bit ? I32 : I64
            emit_classid_unbox!(fb, ctx, _aa_target; nullable=true)
            _boxed_operand_unboxed = true   # function-scoped (the tail rebox keys on this)
        end
        # Unbox externref args for numeric intrinsics.
        # When a param/SSA has Wasm type externref but Julia IR uses it as
        # numeric (UInt32, Int64, etc.), unbox: any_convert_extern → ref.cast → struct.get
        if is_numeric_intrinsic && _is_externref_value(arg, ctx)
            target_wasm = is_32bit ? I32 : I64
            any_convert_extern!(fb)
            emit_classid_unbox!(fb, ctx, target_wasm; nullable=true)
        end
    end

    # For numeric intrinsics, verify the compiled args don't contain externref
    # (this catches cases where Julia type inference says Int64 but actual struct field is Any)
    if is_numeric_intrinsic && length(args) > 0
        # typed channel: a ref-typed emission feeding a numeric intrinsic = boxed/Any operand
        # (was a GC_PREFIX+STRUCT_GET byte probe + LEB decode + SSA-type re-check).
        local _p1_pos = length(fb.v.stack) - length(args) + 1
        local _p1_ty = _p1_pos >= 1 ? fb.v.stack[_p1_pos] : nothing
        if _p1_ty !== nothing && (_p1_ty === ExternRef || _p1_ty === AnyRef)
            local arg1_ssa = args[1]
            if arg1_ssa isa NirSSA && get(ctx.ssa_types, arg1_ssa.id, nothing) === Any
                # numeric intrinsic on an Any-typed (boxed) operand — type instability. Loud reject.
                fb = _ctx_builder(ctx, "compile_call.frag")
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "numeric intrinsic on an Any-typed (boxed) operand — type instability"; idx=idx)
                return append_builder!(b, fb)
            end
        end
    end

    # parity(intrinsics.dart:995 _binaryOperatorMap lookup): THE INTRINSICS TABLE ROUTE — one
    # declarative lookup ahead of the arm chain. Covered (lhsT, rhsT, op) entries
    # emit here via `emit_intrinsic_binop!` (the ONE production caller — see
    # intrinsics_table.jl); the chain below keeps only what the table can't
    # express (128-bit, checked-overflow, unary, ===, conversions) and shrinks
    # with M11. (`_it_name` is already in scope — hoisted above, so there is only ONE
    # extraction site.)
    if _it_name !== nothing && !is_128bit
        # floats classify FIRST (is_32bit is true for Float32 — an INT-width flag)
        local _it_w = arg_type === Float64 ? F64 :
                      arg_type === Float32 ? F32 : (is_32bit ? I32 : I64)
        if haskey(INTRINSIC_BINOPS, (_it_w, _it_w, _it_name))
            # Comparisons and div/rem observe FULL register width — narrow pairs
            # (Int8/Int16 on i32) normalise first (sign-extend for signed/equality/
            # signed-div-rem, mask for unsigned; semantics carried into the table
            # route — same signed/unsigned choice the retired arms used).
            # This is the callers' wrap channel that `emit_intrinsic_binop!`'s
            # contract assumes (operands already at their table types).
            local _dw = _julia_int_width(arg_type, is_32bit)
            if is_32bit && _it_name in (:slt_int, :sle_int, :eq_int, :ne_int,
                                         :sdiv_int, :srem_int, :checked_sdiv_int, :checked_srem_int)
                _emit_normalise_narrow_pair!(fb, ctx, true, _dw)
            elseif is_32bit && _it_name in (:ult_int, :ule_int,
                                             :udiv_int, :urem_int, :checked_udiv_int, :checked_urem_int)
                _emit_normalise_narrow_pair!(fb, ctx, false, _dw)
            end
            local _it_result = emit_intrinsic_binop!(fb, _it_w, _it_w, _it_name, ctx, _dw)
            # (The rebox link): a numeric intrinsic whose SSA LOCAL is
            # ref-typed (the boxed accumulator: Any-joined phi) must REBOX its
            # result — keyed on the REAL local type, never inference (the sink's
            # re-guess said anyref≡anyref while raw i64 sat on the stack).
            local _rbx_li = get(ctx.ssa_locals, idx, nothing)
            if _rbx_li !== nothing
                local _rbx_off = _rbx_li - ctx.n_params
                if _rbx_off >= 0 && _rbx_off < length(ctx.locals) && _wt_is_ref(ctx.locals[_rbx_off + 1]) &&
                   _it_result in (I32, I64, F32, F64)
                    (arg_type isa Type && isconcretetype(arg_type)) ||
                        record_unsupported!(ctx, :unsupported_type,
                            "intrinsic result boxing lacks a concrete Julia source type";
                            idx=idx, detail=node)
                    emit_classid_box!(fb, ctx, _it_result, arg_type)
                end
            end
            return append_builder!(b, fb)
        end
    end

    # parity(intrinsics.dart:1007 _inlineUnaryOperatorMap lookup): THE UNARY INTRINSICS
    # TABLE ROUTE — mirrors the binop route above, right after it (same `_it_name`
    # extraction, same `!is_128bit` guard). Bool routes FIRST, exactly as dart routes
    # `boolType` ahead of any map lookup (intrinsics.dart:438-444): a `not_int` fed a
    # comparison result is logical NOT (`i32.eqz`), structurally different from bitwise
    # NOT (`const -1; xor`) and must never reach the int-typed table entry.
    if _it_name === :not_int && length(args) == 1 && is_boolean_value(args[1], ctx)
        num!(fb, Opcode.I32_EQZ)
        return append_builder!(b, fb)
    elseif _it_name !== nothing && !is_128bit
        local _ut_w = arg_type === Float64 ? F64 :
                      arg_type === Float32 ? F32 : (is_32bit ? I32 : I64)
        local _ut_result = emit_intrinsic_unop!(fb, _ut_w, _it_name)
        if _ut_result !== nothing
            # (The rebox link, mirroring the binop route above.)
            local _rbx_li2 = get(ctx.ssa_locals, idx, nothing)
            if _rbx_li2 !== nothing
                local _rbx_off2 = _rbx_li2 - ctx.n_params
                if _rbx_off2 >= 0 && _rbx_off2 < length(ctx.locals) && _wt_is_ref(ctx.locals[_rbx_off2 + 1]) &&
                   _ut_result in (I32, I64, F32, F64)
                    (arg_type isa Type && isconcretetype(arg_type)) ||
                        record_unsupported!(ctx, :unsupported_type,
                            "intrinsic result boxing lacks a concrete Julia source type";
                            idx=idx, detail=node)
                    emit_classid_box!(fb, ctx, _ut_result, arg_type)
                end
            end
            return append_builder!(b, fb)
        end
    end

    # parity(quarantine: julia_numeric_tier.jl): THE Int128/UInt128 REGISTRY ROUTE —
    # dart2wasm has no 128-bit integer type, so this tier has no dart anchor to sit ahead
    # of; it is reachable only when `is_128bit` (the intrinsics table routes above already
    # consumed every non-128-bit op). Same nullable-return funnel shape as the tables.
    if _it_name !== nothing && is_128bit
        local _it128_result = emit_int128_op!(fb, ctx, _it_name, arg_type, node, idx)
        _it128_result !== nothing && return append_builder!(b, fb)
    end

    # parity(quarantine: julia_numeric_tier.jl): THE Julia-only numeric registries route —
    # checked overflow, mixed-width shifts, muladd/fma/have_fma, bswap/flipsign. No dart
    # anchor for any of these (dart's `int` wraps silently on overflow, is uniformly i64,
    # and dart2wasm has no fma/bswap intrinsic — intrinsics.dart:710-929 has no entries for
    # them). Same nullable-return funnel shape as the Int128 route just above; unlike that
    # route this one is NOT gated on `is_128bit` (checked_sadd_int et al. reject 128-bit
    # operands from INSIDE the registry, exactly as the arms they replace did — shl_int/
    # ashr_int/lshr_int's is_128bit case is already fully consumed by THE Int128 route above
    # and never reaches here).
    if _it_name !== nothing
        local _jnfbref = Ref(fb)
        local _jn_result = emit_julia_numeric!(_jnfbref, ctx, _it_name, args, arg_type,
                                               is_128bit, is_32bit, idx)
        if _jn_result !== nothing
            fb = _jnfbref[]
            return append_builder!(b, fb)
        end
    end

    # parity(quarantine: julia_numeric_tier.jl): THE conversions registry route —
    # sext_int/zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/fpext/fptrunc/bitcast.
    # No dart anchor (dart coerces only through convertType, translator.dart:1597,
    # and the dart:_wasm shims, intrinsics.dart:710-929). Target-type resolution for
    # sext_int/zext_int/trunc_int stays HERE, not in the registry file, so L77's
    # three literal diagnostic messages keep their home; sitofp/uitofp/fptosi/
    # fptoui pass args[1] unresolved exactly as the arms did; bitcast passes the
    # raw type reference and resolves inside `emit_conversion!`. Same nullable-
    # return funnel shape as the routes above; for these ten ops the funnel is
    # EXHAUSTIVE (their calls.jl arms are deleted).
    if _it_name in (:sext_int, :zext_int, :trunc_int, :sitofp, :uitofp, :fptosi,
                    :fptoui, :fpext, :fptrunc, :bitcast)
        local _cv_julia_dst = length(args) >= 1 ? nir_const(args[1]) : nothing
        if _it_name === :sext_int || _it_name === :zext_int || _it_name === :trunc_int
            local _cv_target_ref = _cv_julia_dst
            _cv_julia_dst = _cv_target_ref isa NirGlobalRef && _cv_target_ref.bound ?
                _cv_target_ref.value : _cv_target_ref
            if !(_cv_julia_dst isa Type)
                if _it_name === :sext_int
                    record_unsupported!(ctx, :unsupported_type,
                        "sext_int target is not a defined Julia type"; idx=idx, detail=_cv_target_ref)
                elseif _it_name === :zext_int
                    record_unsupported!(ctx, :unsupported_type,
                        "zext_int target is not a defined Julia type"; idx=idx, detail=_cv_target_ref)
                else
                    record_unsupported!(ctx, :unsupported_type,
                        "trunc_int target is not a defined Julia type"; idx=idx, detail=_cv_target_ref)
                end
            end
        end
        local _cv_julia_src = length(args) >= 2 ? infer_value_type(args[2], ctx) : nothing
        local _cv_src_wide = length(args) >= 2 && get_phi_edge_wasm_type(args[2], ctx) === I64
        local _cv_result = emit_conversion!(fb, ctx, _it_name, _cv_julia_src, _cv_julia_dst, idx;
                                            src_already_wide=_cv_src_wide)
        _cv_result !== nothing && return append_builder!(b, fb)
    end

    # Match intrinsics by name
    # (add_int/sub_int/mul_int: non-128-bit handled by THE intrinsics table route above;
    # 128-bit handled by THE Int128 registry route above.)

    # checked_s{add,sub,mul}_int/checked_u{add,sub,mul}_int (narrow-width AND
    # register-width paths, incl. the 128-bit reject stubs): THE julia_numeric_tier.jl
    # CHECKED_OPS registry route above.

    # sdiv_int/udiv_int/srem_int/urem_int (+ checked_* aliases, I32/I64): THE
    # intrinsics table route above (guard + opcode, same as this arm used to do).

    # bitcast: THE julia_numeric_tier.jl conversions registry route above.

    # neg_int: non-128-bit handled by THE intrinsics table route above; 128-bit handled
    # by THE Int128 registry route above.
    # flipsign_int: THE julia_numeric_tier.jl MISC_OPS registry route above.

    # Comparison operations
    # Ordered comparisons OBSERVE the full register width, so narrow
    # operands must be renormalised first (same policy as div/rem): an Int8 value
    # of -x can sit in the i32 register as 128, and slt_int(128, 0) = false flips
    # checked_abs's overflow test (lcm(Int8(-128), 1) returned 128 instead of
    # throwing). Signed → sign-extend in register; unsigned → mask.
    # slt_int/sle_int/ult_int/ule_int/eq_int/ne_int: non-128-bit handled by THE
    # intrinsics table route above; 128-bit handled by THE Int128 registry route above.

    # ===/!==: THE builtins.jl `_lower_egal!` entry (self-contained operands).
    # and_int/or_int/xor_int/not_int (non-128-bit): THE intrinsics table route above
    # (not_int also has the boolean NOT special case just above it); 128-bit handled
    # by THE Int128 registry route above.

    # Shift operations: shl_int/ashr_int/lshr_int (128-bit handled by THE Int128
    # registry route above; the register-width path is THE julia_numeric_tier.jl
    # SHIFT_OPS registry route above).

    # ctlz_int/cttz_int/ctpop_int: non-128-bit handled by THE intrinsics table route
    # above; 128-bit handled by THE Int128 registry route above.

    # bswap_int (used in Char ↔ codepoint conversion): THE julia_numeric_tier.jl
    # MISC_OPS registry route above.

    # Float operations: muladd_float/fma_float/have_fma: THE julia_numeric_tier.jl
    # FMA_OPS registry route above.

    # Type conversions: sext_int/zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/
    # fpext/fptrunc: THE julia_numeric_tier.jl conversions registry route above.

    # The high-level operator fallback (+ - *) and isa: THE builtins.jl
    # `_lower_operator!` / `_lower_isa!` entries (self-contained operands).

    # throw() - compile to WASM throw instruction
    if func === Core.throw
        # throw(obj): obj as the anyref the tag carries, thrown through the one throw
        length(args) == 1 || error("Core.throw takes one exception, got $(length(args)) operands")
        ensure_exception_tag!(ctx.mod)
        local _thrb = _ctx_builder(ctx, "compile_call")
        begin
            local _throw_val = args[1]
            # a constant exception object (a literal operand)
            local _throw_raw = _throw_val isa NirLiteral ? _throw_val.value : nothing
            if _throw_val isa NirLiteral &&
               isstructtype(typeof(_throw_raw)) &&
               !isa(_throw_raw, Function) && !isa(_throw_raw, Module)
                local _throw_T = typeof(_throw_raw)
                local _throw_has_undef = any(!isdefined(_throw_raw, fn) for fn in fieldnames(_throw_T))
                if _throw_has_undef
                    record_unsupported!(ctx, :value_stub,
                        "constant exception contains undefined fields";
                        idx=idx, detail=_throw_T)
                    unreachable!(_thrb)  # structural trap after recorded unsupported
                    ctx.last_stmt_was_stub = true
                    return append_builder!(fb, _thrb)
                end
            end
            # Constants with undefined fields were rejected above because WasmGC has no
            # equivalent representation.
            local _throw_st = get_ssa_type(ctx, _throw_val)
            emit_value!(_thrb, _throw_val, ctx, AnyRef;
                        from_julia=(_throw_st isa DataType && isconcretetype(_throw_st)) ? _throw_st : nothing)
        end
        emit_throw_value!(_thrb, ctx.mod)   # typed (exn, trace) tag
        append_builder!(fb, _thrb)

    elseif func === Core.throw_methoderror
        fb = _ctx_builder(ctx, "compile_call.frag")   # the operands are the MethodError's own
        _emit_throw_methoderror!(fb, args, ctx)
        ctx.last_stmt_was_stub = true

    # Core._svec_len(sv) — SimpleVector is an externref array in WasmGC.
    # _svec_len returns Int64 = array.len (converted from i32 to i64).
    # Match both GlobalRef(Core, :_svec_len) and the direct builtin function object.
    # Julia's type inference may resolve length(::SimpleVector) to the builtin directly.
    # args[1] (svec array) is already pre-pushed by the generic loop above.
    elseif isdefined(Core, :_svec_len) && nir_const(func) === Core._svec_len && length(args) == 1
        # P4-stdlib: fold against host-constant svecs (padding/typename.names)
        local _svl = _try_host_svec(args[1], ctx)
        if _svl isa Core.SimpleVector
            fb = _ctx_builder(ctx, "compile_call.frag")   # discard pre-pushed placeholder
                i64_const!(fb, Int64(length(_svl)))
        else
                array_len!(fb)
                # array.len returns i32 but Julia expects Int64
                num!(fb, Opcode.I64_EXTEND_I32_U)
        end

    # Core._svec_ref(sv, i) — get element from SimpleVector (externref array).
    # _svec_ref is 1-indexed in Julia, 0-indexed in Wasm → subtract 1.
    # Match both GlobalRef and direct builtin function object (same as _svec_len above).
    # args[1] (svec array) and args[2] (i64 index) are already pre-pushed by
    # the generic loop above — do NOT call compile_value again here (causes double-push,
    # leaving 2 orphaned values on the stack → "values remaining" validation error).
    elseif isdefined(Core, :_svec_ref) && nir_const(func) === Core._svec_ref && length(args) == 2
        # Get element from externref array
        svec_type_info = register_struct_type!(ctx.mod, ctx.type_registry, Core.SimpleVector)
        svec_arr_idx = svec_type_info.wasm_type_idx
        local _svrb = _sub_builder(fb, ctx, "compile_call", 2)   # [svec, i64 idx] on fb
        # Convert i64 Julia index to i32 Wasm index and subtract 1 for 0-indexing
        num!(_svrb, Opcode.I32_WRAP_I64)
        i32_const!(_svrb, 1)  # 1
        num!(_svrb, Opcode.I32_SUB)
        local _svelem = ctx.mod.types[svec_arr_idx + 1].elem.valtype
        array_get!(_svrb, svec_arr_idx, _svelem)
        # Legacy headerless registries used externref; the canonical hierarchy
        # uses AnyRef directly.
        if _svelem === ExternRef
            any_convert_extern!(_svrb)
        end
        append_builder!(fb, _svrb)

    # Core._apply_iterate(Base.iterate, f, container...) — vector splatting.
    # Tuple splatting is resolved by Julia at code_typed time (no _apply_iterate).
    # Only runtime-length containers (Vector) produce this IR node.
    # Handle the common case: binary reduce over a single Vector{T}.
    elseif func === Core._apply_iterate && length(args) >= 3
        # args layout: [Base.iterate, target_func, container1, ...]
        # Clear pre-pushed args (iterate ref, func ref, container ref are on stack)
        fb = _ctx_builder(ctx, "compile_call.frag")
        target_func = args[2]  # The function to apply (e.g., Base.:+)
        container_arg = args[3]  # The container to iterate

        # Get container Julia type
        container_type = infer_value_type(container_arg, ctx)

        # ONE callee resolution, then identity on the resolved OBJECT (L124's rule):
        # the splat target reaches this position under three spellings and a
        # name+module test answers only one of them —
        #   `Tuple(v)`        → GlobalRef(Core, :tuple)
        #   `tuple(v...)`     → GlobalRef(Main, :tuple)   (name matches, module does not)
        #   `Core.tuple(v...)`→ the builtin VALUE, no GlobalRef at all
        # — so the last two used to fall through to the loud reject for a splat the
        # first one lowers.
        target_value = target_func isa NirGlobalRef ?
            (target_func.bound ? target_func.value : nothing) : nir_const(target_func)
        target_is_tuple = target_value === Core.tuple
        target_is_vect = target_value === Base.vect
        target_is_typed_vect = target_value === Base.getindex
        target_is_compose = target_value === (∘)
        prefix_values = length(args) == 4 ? _apply_iterate_svec_values(args[3], ctx) : nothing
        tail_type = length(args) == 4 ? get_ssa_type(ctx, args[4]) : nothing

        # Core.tuple is only directly representable when the iterable is proven
        # empty. A runtime-length Julia tuple needs a genuine variable-tuple
        # representation; never fabricate Tuple{} for a nonempty/unknown input.
        if target_is_tuple
            local result_type = get(ctx.ssa_types, idx, Any)
            if container_type isa DataType && container_type <: Vector &&
               is_runtime_vararg_tuple_type(result_type)
                register_vararg_tuple_type!(ctx.mod, ctx.type_registry, result_type)
                _emit_apply_iterate_vect!(fb, container_arg, container_type, ctx;
                                          result_type=result_type)
            elseif _iterable_proven_empty(container_arg, ctx)
                info = register_tuple_type!(ctx.mod, ctx.type_registry, Tuple{})
                emit_struct_prefix!(fb, ctx.type_registry, Tuple{}, info)
                struct_new!(fb, info.wasm_type_idx)
            else
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "runtime-length Core.tuple materialization requires a variable-tuple representation";
                    idx=idx)
            end
        # `f(t...)` where `t` is a runtime-length Vararg tuple: the callee's own
        # trailing `Vararg{E}` parameter IS this value's representation, so the
        # splat is a direct call. (Never reached for a Vector container — that
        # one still iterates.)
        elseif length(args) == 3 && is_runtime_vararg_tuple_type(container_type)
            _emit_apply_iterate_vararg_call!(fb, target_value, container_arg,
                                             container_type, ctx, idx)
        # Single-container Vector{T} splatting: vector-literal collect (`[v...]`)
        # or a known binary-reduce intrinsic.
        elseif target_is_compose && length(args) == 3 &&
               container_type isa DataType && container_type <: AbstractVector
            _emit_runtime_composition_context!(fb, container_arg, container_type, ctx)
        elseif (target_is_vect || target_is_typed_vect) && prefix_values !== nothing &&
               tail_type isa DataType && tail_type <: Vector
            # `[prefix..., vector...]`: Base.vect receives scalar prefix operands and
            # one runtime-length Vector tail. `T[prefix..., vector...]` lowers via
            # Base.getindex with T as the first svec item; it is a type marker,
            # not a result element.
            local actual_prefix = target_is_typed_vect ? prefix_values[2:end] : prefix_values
            _emit_apply_iterate_vect_prefix!(fb, actual_prefix, args[4],
                                              tail_type, ctx)
        elseif all(a -> begin
                       local T = get_ssa_type(ctx, a)
                       T isa DataType && T <: Vector
                   end, args[3:end])
            local container_args = args[3:end]
            local container_types = DataType[get_ssa_type(ctx, a) for a in container_args]
            elem_type = eltype(container_type)

            if any(T -> eltype(T) !== elem_type, container_types)
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "_apply_iterate containers have different element types"; idx=idx)
            elseif target_is_vect && length(container_args) == 1
                # `[v...]` ⇒ Base.vect(v...) ⇒ a shallow copy of the vector.
                _emit_apply_iterate_vect!(fb, container_arg, container_type, ctx)
            else
                # Resolve target function to a WASM opcode for binary reduce
                reduce_op = _get_binary_reduce_opcode(target_value, elem_type)
                if reduce_op !== nothing
                    # Emit inline reduce loop: acc = v[1]; for i in 2:length(v), acc = op(acc, v[i])
                    _emit_apply_iterate_reduce!(fb, container_args, container_types,
                                                elem_type, reduce_op, target_value, ctx)
                else
                    # Unknown reduce target — can't lower. Loud reject (reduce returns a value natively).
                    emit_unsupported_stub!(ctx, fb, :unsupported_method,
                        "_apply_iterate reduce over an unsupported operator/target"; idx=idx)
                end
            end
        else
            # Multiple containers / non-Vector — not supported. Loud reject (returns a value natively).
            emit_unsupported_stub!(ctx, fb, :unsupported_method,
                "_apply_iterate over multiple containers or a non-Vector iterable"; idx=idx)
        end

    # Core.svec — materialize the real $JlSVec array.
    elseif func === Core.svec
        fb = _ctx_builder(ctx, "compile_call.frag")
        _emit_svec_values!(fb, args, ctx)

    # Core builtins re-exported through Base (isdefined, getfield, setfield!).
    # These builtins share the ordinary typed struct/tuple lowering below.
    elseif named &&
           any(name -> is_builtin_func(func, name), (:isdefined, :getfield, :setfield!))
        # Clear pre-pushed args
        fb = _ctx_builder(ctx, "compile_call.frag")
        # P4-stdlib (Statistics median): getfield on a compile-time CONSTANT
        # receiver (QuoteNode) — e.g. getfield(typename(UInt64), :flags) from
        # inlined isbits-style predicates in sort. Host-evaluate; emit the
        # constant when it has a primitive/string representation. (The :names
        # svec form stays trapped — no constant emission for SimpleVector.)
        local _gfc_done = false
        # getfield(tuple, literal_index[, boundscheck]) is the canonical optimized
        # varargs access shape (including Core.Argument receivers). Route it through
        # the registered tuple layout instead of requiring an SSA+Symbol shape.
        local _gft_index = length(args) >= 2 ?
                           nir_const(args[2]) : nothing
        # the index is a runtime integer: a Symbol is a field name (a Tuple has none, so the
        # name read below throws FieldError), and an index whose type admits other values
        # rejects at its statement rather than casting them to an integer
        if func === Core.getfield && length(args) >= 2 &&
           args[1] isa NirArgument && !ctx.is_compiled_closure &&
           !(_gft_index isa Integer) && get_ssa_type(ctx, args[2]) <: Integer
            local _gft_slot_T = get_ssa_type(ctx, args[1])
            local _gft_fixed = args[1].n - 2
            local _gft_pack_n = length(ctx.arg_types) - _gft_fixed
            if _gft_slot_T isa DataType && _gft_slot_T <: Tuple &&
               _gft_fixed >= 0 && fieldcount(_gft_slot_T) == _gft_pack_n
                local _gft_result_T = get(ctx.ssa_types, idx, Any)
                # A runtime index over heterogeneous tuple fields joins at the
                # value representation LUB. Julia inference reports that join
                # as a Union; WT's single boxed-value channel for such unions is
                # AnyRef, never one arbitrarily selected variant layout.
                local _gft_result_w = _gft_result_T isa Union ? AnyRef :
                    get_concrete_wasm_type(_gft_result_T, ctx.mod, ctx.type_registry)
                local _gft_ib = _ctx_builder(ctx, "compile_call.vararg_dynamic_getfield")
                local _gft_index_local = allocate_local!(ctx, I64)
                emit_value!(_gft_ib, args[2], ctx, I64)
                local_set!(_gft_ib, _gft_index_local)
                local function _emit_case!(i::Int)
                    if i > _gft_pack_n
                        _emit_vararg_bounds_error!(_gft_ib, ctx,
                                                   ctx.arg_types[_gft_fixed + 1:end],
                                                   _gft_fixed,
                                                   _gft_index_local)
                        return
                    end
                    local_get!(_gft_ib, _gft_index_local); i64_const!(_gft_ib, i)
                    num!(_gft_ib, Opcode.I64_EQ)
                    if_!(_gft_ib; results=WasmValType[_gft_result_w])
                    local_get!(_gft_ib, _gft_fixed + i - 1)
                    coerce_stack_top!(_gft_ib, _gft_result_w, ctx;
                                      from_julia=ctx.arg_types[_gft_fixed + i])
                    else_!(_gft_ib)
                    _emit_case!(i + 1)
                    end_block!(_gft_ib)
                end
                _emit_case!(1)
                append_builder!(fb, _gft_ib)
                _gfc_done = true
            end
        end
        if func === Core.getfield && length(args) >= 2 && _gft_index isa Integer
            local _gft_i = Int(_gft_index)
            # Optimized Julia represents a varargs method's entire argument pack
            # as slot `_2::Tuple{...}`, while the closed-world Wasm signature has
            # one physical parameter per specialized vararg. A literal tuple
            # projection is therefore exactly the corresponding parameter read.
            if args[1] isa NirArgument && !ctx.is_compiled_closure &&
               source_slot_type(ctx, args[1].n) !== nothing
                local _gft_slot_T = get_ssa_type(ctx, args[1])
                local _gft_fixed = args[1].n - 2
                local _gft_pack_n = length(ctx.arg_types) - _gft_fixed
                if _gft_slot_T isa DataType && _gft_slot_T <: Tuple &&
                   _gft_fixed >= 0 && fieldcount(_gft_slot_T) == _gft_pack_n &&
                   1 <= _gft_i <= _gft_pack_n
                    local _gft_ib = _ctx_builder(ctx, "compile_call.vararg_getfield")
                    local_get!(_gft_ib, _gft_fixed + _gft_i - 1)
                    append_builder!(fb, _gft_ib)
                    _gfc_done = true
                end
            end
            local _gft_T = infer_value_type(args[1], ctx)
            if !_gfc_done && _gft_T isa DataType && _gft_T <: Tuple && 1 <= _gft_i <= fieldcount(_gft_T)
                local _gft_info = haskey(ctx.type_registry.structs, _gft_T) ?
                                  ctx.type_registry.structs[_gft_T] :
                                  register_tuple_type!(ctx.mod, ctx.type_registry, _gft_T)
                local _gft_wfi = wasm_field_idx(_gft_info, _gft_i)
                local _gft_fields = ctx.mod.types[_gft_info.wasm_type_idx + 1].fields
                local _gft_ft = _gft_fields[Int(_gft_wfi) + 1].valtype
                local _gft_ib = _ctx_builder(ctx, "compile_call.tuple_getfield")
                emit_value!(_gft_ib, args[1], ctx,
                            ConcreteRef(UInt32(_gft_info.wasm_type_idx), true))
                struct_get!(_gft_ib, _gft_info.wasm_type_idx, _gft_wfi, _gft_ft)
                append_builder!(fb, _gft_ib)
                _gfc_done = true
            end
        end
        if func === Core.getfield && length(args) == 2 && nir_quoted(args[1])
            local _gfc_fld = nir_const(args[2])
            if _gfc_fld isa Symbol
                local _gfc_val = isdefined(args[1].value, _gfc_fld) ?
                    getfield(args[1].value, _gfc_fld) : nothing
                if _gfc_val isa Union{Integer, Bool, Char, Float32, Float64, String, Symbol} &&
                   !(_gfc_val isa Union{Int128, UInt128, BigInt})
                    emit_value!(fb, NirLiteral(_gfc_val), ctx, static_wasm_type(NirLiteral(_gfc_val), ctx))
                    _gfc_done = true
                end
            end
        end
        # Constant-receiver getfield yielding a SimpleVector
        # (typename(T).names) — materialize the real $JlSVec array.
        if !_gfc_done && func === Core.getfield && length(args) == 2 && nir_quoted(args[1])
            local _gfc_fld2 = nir_const(args[2])
            if _gfc_fld2 isa Symbol
                local _gfc_v2 = isdefined(args[1].value, _gfc_fld2) ?
                    getfield(args[1].value, _gfc_fld2) : nothing
                if _gfc_v2 isa Core.SimpleVector
                    _emit_svec_values!(fb, NirNode[NirLiteral(v) for v in _gfc_v2], ctx)
                    _gfc_done = true
                end
            end
        end
        # parity(closures.dart:1365 Context): isdefined(%box::Core.Box, :contents) — the shared cell's
        # defined-check = a null test on the anyref contents.
        if !_gfc_done && func === Core.isdefined && length(args) == 2 &&
           args[1] isa NirSSA && nir_const(args[2]) === :contents &&
           get(ctx.ssa_types, args[1].id, Any) === Core.Box
            local _bxd_ib = _ctx_builder(ctx, "compile_call")
            local _bxd_ty = emit_value!(_bxd_ib, args[1], ctx, static_wasm_type(args[1], ctx))  # box intrinsic branches on the operand's type
            local _bxd_idx = _bxd_ty isa ConcreteRef ? _bxd_ty.type_idx :
                             UInt32(get_box_type!(ctx.mod, ctx.type_registry, AnyRef))
            !(_bxd_ty isa ConcreteRef) && ref_cast!(_bxd_ib, Int64(_bxd_idx), false)
            local _bxd_ft = ctx.mod.types[_bxd_idx + 1].fields[2].valtype
            if _wt_is_ref(_bxd_ft)
                struct_get!(_bxd_ib, _bxd_idx, UInt32(1), _bxd_ft)
                ref_is_null!(_bxd_ib)
                num!(_bxd_ib, Opcode.I32_EQZ)
            else
                # a TYPED box (i64 contents etc.) is always defined
                drop!(_bxd_ib)
                i32_const!(_bxd_ib, 1)
            end
            append_builder!(fb, _bxd_ib)
            _gfc_done = true
        end
        # General concrete-struct field definedness. Reference fields use null
        # as Julia's undefined-field state; physical numeric fields are always
        # initialized in Wasm and therefore defined.
        if !_gfc_done && func === Core.isdefined && length(args) == 2 &&
           args[1] isa NirSSA && nir_const(args[2]) isa Symbol
            local _isd_T = get(ctx.ssa_types, args[1].id, Any)
            local _isd_f = nir_const(args[2])
            if _isd_T isa DataType && isstructtype(_isd_T) &&
               _isd_f in fieldnames(_isd_T)
                local _isd_info = haskey(ctx.type_registry.structs, _isd_T) ?
                                  ctx.type_registry.structs[_isd_T] :
                                  register_struct_type!(ctx.mod, ctx.type_registry, _isd_T)
                if _isd_info !== nothing
                    # StructInfo can intentionally be an observable projection
                    # of a Julia runtime object (Core.Binding is one example),
                    # so physical Wasm indices come from its registered names,
                    # never the host struct's full field ordinal.
                    local _isd_i = findfirst(==(_isd_f), _isd_info.field_names)
                    _isd_i === nothing && record_unsupported!(ctx, :unsupported_method,
                        "isdefined field is absent from the registered runtime projection";
                        idx=idx, detail=node, soundness_fatal=true)
                    local _isd_wfi = wasm_field_idx(_isd_info, _isd_i)
                    local _isd_fields = ctx.mod.types[_isd_info.wasm_type_idx + 1].fields
                    local _isd_ft = _isd_fields[Int(_isd_wfi) + 1].valtype
                    local _isd_b = _ctx_builder(ctx, "compile_call.isdefined_field")
                    emit_value!(_isd_b, args[1], ctx,
                                ConcreteRef(UInt32(_isd_info.wasm_type_idx), true))
                    if _wt_is_ref(_isd_ft)
                        struct_get!(_isd_b, _isd_info.wasm_type_idx, _isd_wfi, _isd_ft)
                        ref_is_null!(_isd_b); num!(_isd_b, Opcode.I32_EQZ)
                    else
                        drop!(_isd_b); i32_const!(_isd_b, 1)
                    end
                    append_builder!(fb, _isd_b)
                    _gfc_done = true
                end
            end
        end
        # parity(closures.dart:1365 Context): getfield(closure_value, :boxfield) — the box was born in a
        # callee; read the registered struct field here (the ONE shared cell).
        if !_gfc_done && func === Core.getfield && length(args) == 2 &&
           nir_const(args[2]) isa Symbol
            local _gfb_T = get_ssa_type(ctx, args[1])
            local _gfb_fld = nir_const(args[2])
            if _gfb_T isa DataType && _gfb_fld isa Symbol &&
               !(isstructtype(_gfb_T) && _gfb_fld in fieldnames(_gfb_T))
                local _gfb_ib = _ctx_builder(ctx, "compile_call.fielderror")
                _emit_field_error!(_gfb_ib, ctx, _gfb_T, _gfb_fld)
                append_builder!(fb, _gfb_ib)
                _gfc_done = true
            end
            if !_gfc_done && _gfb_T isa DataType && isstructtype(_gfb_T)
                local _gfb_info = haskey(ctx.type_registry.structs, _gfb_T) ?
                                  ctx.type_registry.structs[_gfb_T] :
                                  register_struct_type!(ctx.mod, ctx.type_registry, _gfb_T)
                if _gfb_info !== nothing
                  local _gfb_fi = findfirst(==(_gfb_fld), _gfb_info.field_names)
                  if _gfb_fi !== nothing
                    # the wasm field index comes from the REGISTERED layout's offset
                    # (1 = classId header present, 0 = headerless) — never hardcoded.
                    local _gfb_wfi = _gfb_fi - 1 + Int(_gfb_info.field_offset)
                    local _gfb_flds = ctx.mod.types[_gfb_info.wasm_type_idx + 1].fields
                    if _gfb_wfi >= 0 && _gfb_wfi < length(_gfb_flds)
                        local _gfb_ib = _ctx_builder(ctx, "compile_call")
                        local _gfb_ft = _gfb_flds[_gfb_wfi + 1].valtype
                        emit_value!(_gfb_ib, args[1], ctx,
                                    ConcreteRef(UInt32(_gfb_info.wasm_type_idx), true))
                        struct_get!(_gfb_ib, _gfb_info.wasm_type_idx, UInt32(_gfb_wfi), _gfb_ft)
                        append_builder!(fb, _gfb_ib)
                        _gfc_done = true
                    end
                  end
                end
            end
        end
        # getfield(x::T, f) with a field name known only at run time: a dispatch candidate of
        # getproperty(x, f::Symbol) over a concrete class (_emit_getfield_runtime_name!)
        if !_gfc_done && func === Core.getfield && length(args) == 2 &&
           !(nir_const(args[2]) isa Symbol) && get_ssa_type(ctx, args[2]) === Symbol
            local _rn_T = get_ssa_type(ctx, args[1])
            _rn_T isa DataType && isconcretetype(_rn_T) &&
                (_gfc_done = _emit_getfield_runtime_name!(fb, ctx, idx, args[1], args[2], _rn_T))
        end
        if !_gfc_done
            record_unsupported!(ctx, :unsupported_method,
                                "$(nameof(func)) call shape not lowerable";
                                idx=idx, detail=node)
            ctx.last_stmt_was_stub = true
        end

    # Cross-function call via GlobalRef (dynamic dispatch when Julia can't specialize)
    # Core._expr never reaches here — THE identity-keyed builtin funnel
    # (builtins.jl) claims it long before this ladder starts.
    elseif named && ctx.func_registry !== nothing
        # The callee by identity (functions.dart:25): an unbound global names nothing, and a
        # call of it rejects below, where Julia throws UndefVarError.
        called_func = func isa GlobalRef ? nothing : func

        if called_func !== nothing
            # Infer argument types BEFORE pushing (need for type checking)
            call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)

            # dynamic-dispatch sites must not pick a same-name
            # overload with an incompatible return (i32 getindex for a ref site)
            _exp_ret_c = get(ctx.ssa_types, idx, nothing)
            target_info = get_function(ctx.func_registry, called_func, call_arg_types;
                                       expected_return=_exp_ret_c isa Type ? _exp_ret_c : nothing)

            # Closure/kwarg functions are registered with self-type prepended
            if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                closure_arg_types = (typeof(called_func), call_arg_types...)
                target_info = get_function(ctx.func_registry, called_func, closure_arg_types;
                                           expected_return=_exp_ret_c isa Type ? _exp_ret_c : nothing)
            end

            # A candidate discovered for closed-world dynamic dispatch is not a
            # normal cross-call target. If later value analysis recovers every
            # erased argument to a concrete Julia type, however, the exact
            # candidate signature is a proof of a monomorphic call. Devirtualize
            # only that exact signature; abstract and subtype-fuzzy sites still
            # go through the typeId selector (or reject loudly).
            if target_info === nothing
                target_info = get_exact_candidate(
                    ctx.func_registry, called_func, call_arg_types;
                    expected_return=_exp_ret_c isa Type ? _exp_ret_c : nothing)
            end

            # WASMTARGET dynamic dispatch: a polymorphic call (exactly one abstract/Any
            # arg, ≥2 concrete-struct candidate specializations) must NOT collapse to a
            # single fuzzy-matched target — get_function would pick ONE method and call
            # it for every runtime type (the shared-layout ref.cast doesn't even trap).
            # Emit a runtime typeId switch over the candidates instead. Returns nothing
            # (falls through) for ordinary monomorphic calls.
            _disp_early = _try_inline_typeid_dispatch(ctx, called_func, args, call_arg_types, idx)
            if _disp_early !== nothing
                return append_builder!(b, _disp_early)   # typed merge
            end

            if target_info !== nothing
                # Push arguments with type checking
                for (arg_idx, arg) in enumerate(args)
                    local _cab = _compile_value_b(arg, ctx)
                    local _cab_merged = false
                    # Check if arg type matches expected param type (the merge happens
                    # AFTER the phantom/numeric-replacement decisions — the pop! surgeries
                    # are gone; we just don't merge a replaced arg)
                    if arg_idx <= length(target_info.arg_types)
                        expected_julia_type = target_info.arg_types[arg_idx]
                        expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                        actual_julia_type = call_arg_types[arg_idx]

                        # Handle Nothing→ref conversion BEFORE type bridging.
                        # compile_value emits i32_const 0 for Nothing,
                        # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                        # otherwise bridging tries any_convert_extern on an i32 value.
                        # NOTE: Type{T} no longer needs this — it now emits global.get (DataType ref).
                        _is_phantom = actual_julia_type === Nothing
                        if _is_phantom && (expected_wasm isa ConcreteRef || expected_wasm === ExternRef || expected_wasm === StructRef || expected_wasm === AnyRef)
                            # the Nothing emission is exactly one i32.const 0 (ir/-kind test)
                            if length(_cab.instrs) == 1 && _cab.instrs[1] isa InstrIR.I32Const
                                if expected_wasm isa ConcreteRef
                                    ref_null!(fb, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                                else
                                    ref_null!(fb, expected_wasm)
                                end
                                _cab_merged = true   # the phantom replaced the arg
                            end
                        end

                        # F8 (twin of the invoke collapse): the bridging chain IS
                        # one convertType call (dart code_generator.dart:879) reading the
                        # tracked emission type off the builder stack; the phantom arm above
                        # already left the expected type there.
                        _cab_merged || (append_builder!(fb, _cab); _cab_merged = true)
                        coerce_stack_top!(fb, expected_wasm, ctx;
                                          from_julia=(actual_julia_type isa Type && isconcretetype(actual_julia_type)) ? actual_julia_type : nothing)
                    end
                end
                # Cross-function call - emit call instruction with target index
                # Arguments already live on `fb`; emit the call and result bridge
                # on that same authoritative builder stack. A detached fragment
                # here used to hide the call's parameter pops from validation.
                local _xcb = fb
                call!(_xcb, target_info.wasm_idx, WasmValType[], WasmValType[])
                # If the callee returns Union{} (Bottom), it always throws.
                # The Wasm func type has no result, so code after is unreachable.
                # Skip type bridge and emit unreachable to prevent stack underflow.
                if target_info.return_type === Union{}
                    unreachable!(_xcb)  # structural trap (dart-legit dead path)
                    ctx.last_stmt_was_stub = true
                # Bridge type gap between function's Wasm return type
                # and the caller's SSA local type. Handles both directions:
                # 1. externref → ConcreteRef: any_convert_extern + ref.cast
                # 2. ConcreteRef → externref: extern_convert_any
                elseif haskey(ctx.ssa_locals, idx)
                    local_idx_val = ctx.ssa_locals[idx]
                    local_arr_idx = local_idx_val - ctx.n_params + 1
                    if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                        target_local_type = ctx.locals[local_arr_idx]
                        ret_wasm = julia_to_wasm_type(target_info.return_type)
                        if target_local_type isa ConcreteRef && ret_wasm === ExternRef
                            # Function returns externref, local expects concrete ref
                            any_convert_extern!(_xcb)
                            ref_cast!(_xcb, Int64(target_local_type.type_idx), true)
                        elseif target_local_type === AnyRef && ret_wasm === ExternRef
                            # Function returns externref, local expects anyref
                            any_convert_extern!(_xcb)
                        elseif target_local_type === ExternRef && ret_wasm !== ExternRef && ret_wasm !== nothing
                            # Function returns concrete/struct/array ref, local expects externref
                            extern_convert_any!(_xcb)
                        elseif target_local_type isa ConcreteRef && (ret_wasm === AnyRef || ret_wasm === StructRef)
                            # CS-004: Function returns anyref/structref, local expects concrete ref.
                            # Insert ref.cast to narrow the type (traps at runtime if wrong type).
                            ref_cast!(_xcb, Int64(target_local_type.type_idx), true)
                        elseif target_local_type === StructRef && ret_wasm === AnyRef
                            # CS-004: Function returns anyref, local expects structref.
                            # Insert ref.cast to narrow anyref → structref.
                            ref_cast!(_xcb, StructRef, true)  # structref heap type
                        elseif (target_local_type === AnyRef || target_local_type === StructRef) &&
                               (ret_wasm === I32 || ret_wasm === I64 || ret_wasm === F32 || ret_wasm === F64)
                            # callee returns a numeric but the SSA local is a
                            # ref class (dynamic Any-typed call site, e.g. getindex on a bond
                            # Vector resolving to an i32-returning overload) — box the RESULT
                            # (on the stack) exactly like the arg path via the one emitter.
                            # The box struct is already a structref subtype — no cast needed for StructRef.
                            local _ret_jt = target_info.return_type
                            (_ret_jt isa Type && isconcretetype(_ret_jt)) ||
                                record_unsupported!(ctx, :unsupported_type,
                                    "cross-call result boxing lacks a concrete Julia source type";
                                    idx=idx, detail=node)
                            emit_classid_box!(_xcb, ctx, ret_wasm, _ret_jt)
                        end
                    end
                end
            else
                # A dynamic ==/!= over two erased operands is Julia's dynamic dispatch on both
                # operands' classes, which the call path below dispatches or rejects.
                local _handled = false
                # parity(translator.dart:1597 Translator.convertType): convert(T, x) where x's REFINED type is already T —
                # identity (dart: no conversion node when types agree). The join can
                # refine an erased Any to T after inference classified the convert.
                if called_func === Base.convert && length(args) == 2 &&
                   length(call_arg_types) == 2 && call_arg_types[1] isa Type &&
                   call_arg_types[1] <: Type && call_arg_types[1] isa DataType &&
                   length(call_arg_types[1].parameters) == 1 &&
                   call_arg_types[2] === call_arg_types[1].parameters[1]
                    fb = _ctx_builder(ctx, "compile_call.frag")  # clear pre-pushed args — identity re-emits the value itself
                    emit_value!(fb, args[2], ctx, static_wasm_type(args[2], ctx))
                    _handled = true
                end
                if !_handled
                # A concrete field-wise constructor is structural, not dynamic
                # dispatch. The closed-world result type and exact field count
                # prove the allocation even when inference erased a field value
                # to Any (for example DimensionMismatch(message_phi)). Route it
                # through THE %new implementation and its physical field contract.
                local _ctor_result = get(ctx.ssa_types, idx, Any)
                if (called_func isa DataType || called_func isa UnionAll) &&
                   _ctor_result isa DataType && isconcretetype(_ctor_result) &&
                   isstructtype(_ctor_result) && !isprimitivetype(_ctor_result) &&
                   called_func === _ctor_result && length(args) == fieldcount(_ctor_result)
                    return compile_new!(b, nir_new(_ctor_result, args), idx, ctx)
                end
                # WASMTARGET dynamic dispatch: before giving up, try an inline typeId
                # switch over the compiled specializations (the dynamic call dispatches
                # on a concrete-struct arg at runtime). Unblocks Markdown.plain/show
                # recursion over heterogeneous AST nodes (md"…" rendering).
                _disp = _try_inline_typeid_dispatch(ctx, called_func, args, call_arg_types, idx)
                if _disp !== nothing
                    fb = _disp   # discard-and-replace: the dispatch builder IS the product
                else
                # No matching signature - likely dead code from Union type branches
                # Emit unreachable instead of error (the branch won't be taken at runtime)
                # Suppress warning for known-safe dynamic dispatch paths where
                # Julia couldn't specialize (arg types contain Any/abstract types).
                # These are dead code branches in WasmGC context (we compile with concrete types).
                _has_abstract = any(t -> t === Any || !isconcretetype(t), call_arg_types)
                @debug "CROSS-CALL UNREACHABLE: $(func) with arg types $(call_arg_types) (in func_$(ctx.func_idx))$((_has_abstract ? " [abstract-suppressed]" : ""))"
                fb = _ctx_builder(ctx, "compile_call.frag")
                if get(ctx.ssa_types, idx, Any) === Union{}
                    # always-throws callee (Category-B parity) — sound silent trap.
                    ctx.last_stmt_was_stub = true
                else
                    # Unresolved dynamic call returning a value = un-lowerable dynamic dispatch
                    # (boxing / type instability — abstract-keyed Dict `dict_with_eltype` lands
                    # here). emit_unsupported_stub!'s must-execute gate loud-rejects only when
                    # definitely executed; dead Union-branch calls stay sound silent traps.
                    emit_unsupported_stub!(ctx, fb, :unsupported_method,
                        "unresolved dynamic call `$(_callee_label(func))` $(call_arg_types) — dynamic dispatch / type instability WT cannot lower"; idx=idx)
                end
                end
                end
            end
        else
            # GlobalRef constructor call: SSA return type reveals the struct being constructed
            ssa_type = ctx.nir[idx].julia_type
            if ssa_type isa DataType && isconcretetype(ssa_type) && !isprimitivetype(ssa_type)
                return compile_new!(b, nir_new(ssa_type, args), idx, ctx)
            end
            error("Unsupported function call: $func (type: $(typeof(func)))")
        end

    # NamedTuple{names}(tuple) - convert tuple to named tuple
    # This pattern appears in keyword argument handling
    # Check: func is UnionAll and func <: NamedTuple
    elseif (nt_ctor = nir_const(func)) isa UnionAll && nt_ctor <: NamedTuple
        # func is NamedTuple{(:name1, :name2, ...)}
        # args[1] should be a tuple with the values
        # The result is a NamedTuple which is a struct with named fields

        # Extract the names from the type
        # NamedTuple{names} has structure: UnionAll(T, NamedTuple{names, T})
        # So func.body is NamedTuple{names, T<:Tuple} and we need to get names from there
        inner_type = nt_ctor.body  # e.g., NamedTuple{(:filename, :first_line), T<:Tuple}

        # Check if inner_type is a DataType (it might be a UnionAll if func is the generic NamedTuple)
        names = nothing
        if inner_type isa DataType && length(inner_type.parameters) >= 1
            names = inner_type.parameters[1]  # Get the first type parameter (the names tuple)
        end

        if names isa Tuple && length(args) == 1
            # Get the tuple argument type to determine value types
            tuple_arg = args[1]
            tuple_type = infer_value_type(tuple_arg, ctx)

            if tuple_type <: Tuple
                # Construct the concrete NamedTuple type
                value_types = tuple_type.parameters
                nt_type = NamedTuple{names, Tuple{value_types...}}

                # Register the NamedTuple type as a struct
                if !haskey(ctx.type_registry.structs, nt_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, nt_type)
                end

                if haskey(ctx.type_registry.structs, nt_type)
                    info = ctx.type_registry.structs[nt_type]

                    # The tuple is already a struct with the same field layout as the NamedTuple
                    # (both are structs with fields in order)
                    # For identical memory layout, we can just ref.cast
                    # But if types differ, we need to extract fields and create new struct

                    # Get tuple type info
                    if haskey(ctx.type_registry.structs, tuple_type)
                        tuple_info = ctx.type_registry.structs[tuple_type]

                        if length(value_types) == length(names)
                            local _ntb = _ctx_builder(ctx, "compile_call")
                            # Compile the tuple argument - this pushes the tuple struct
                            local _nt_src = ConcreteRef(tuple_info.wasm_type_idx, true)
                            emit_value!(_ntb, tuple_arg, ctx, _nt_src)
                            # Create a temporary local to hold the tuple
                            tuple_local = allocate_local!(ctx, _nt_src)
                            local_set!(_ntb, tuple_local)

                            emit_struct_prefix!(_ntb, ctx.type_registry, nt_type, info)

                            # Extract each field from tuple and push for struct.new
                            for (i, (name, vtype)) in enumerate(zip(names, value_types))
                                local_get!(_ntb, tuple_local)
                                struct_get!(_ntb, tuple_info.wasm_type_idx, wasm_field_idx(tuple_info, i), julia_to_wasm_type(vtype))  # account for typeId
                            end

                            # Create the NamedTuple struct
                            struct_new!(_ntb, info.wasm_type_idx)   # mod-resolved fields
                            append_builder!(fb, _ntb)
                        else
                            error("NamedTuple/Tuple field count mismatch: $(length(names)) vs $(length(value_types))")
                        end
                    else
                        error("Tuple type not registered: $tuple_type")
                    end
                else
                    error("Failed to register NamedTuple type: $nt_type")
                end
            else
                error("NamedTuple constructor argument is not a Tuple: $tuple_type")
            end
        else
            error("NamedTuple constructor requires exactly one tuple argument, got $(length(args)) args")
        end

    else
        # GlobalRef constructor call: SSA return type reveals the struct being constructed
        if named
            ssa_type = ctx.nir[idx].julia_type
            if ssa_type isa DataType && isconcretetype(ssa_type) && !isprimitivetype(ssa_type)
                return compile_new!(b, nir_new(ssa_type, args), idx, ctx)
            end
        end
        # Unknown function call — emit unreachable (will trap at runtime)
        @debug "Stubbing unsupported call: $func (will trap at runtime) (in func_$(ctx.func_idx))"
        # Clear pre-pushed args before UNREACHABLE
        local _urb = _ctx_builder(ctx, "compile_call")
        record_unsupported!(ctx, :unsupported_method, "unknown function call (no handler arm)";
                            idx=idx, detail=node)
        unreachable!(_urb)  # structural trap after recorded unsupported
        fb = _urb   # discard-and-replace
        ctx.last_stmt_was_stub = true
    end

    # parity(translator.dart:1597 Translator.convertType): the symmetric RESULT side of the anyref-OPERAND unbox above — a numeric
    # arith result flowing into a ref-typed SSA local boxes through THE one producer (the
    # scalar-replaced Core.Box accumulator cycle: unbox → op → BOX → store; dart convertType).
    # Keyed on the FUNCTION-scoped flag — the old @isdefined-guarded read of a
    # LOOP-scoped variable made this arm silently dead for every call since introduction.
    if (@isdefined _boxed_operand_unboxed) && _boxed_operand_unboxed && !ctx.last_stmt_was_stub
        local _dl = get(ctx.ssa_locals, idx, nothing)
        if _dl !== nothing
            local _doff = _dl - ctx.n_params
            if _doff >= 0 && _doff < length(ctx.locals) && ctx.locals[_doff + 1] === AnyRef
                local _boxed_result_jt = get(ctx.ssa_types, idx, arg_type)
                (_boxed_result_jt isa Type && isconcretetype(_boxed_result_jt)) ||
                    record_unsupported!(ctx, :unsupported_type,
                        "boxed arithmetic result lacks a concrete Julia source type";
                        idx=idx, detail=node)
                emit_classid_box!(fb, ctx, is_32bit ? I32 : I64, _boxed_result_jt)
            end
        end
    end

    return append_builder!(b, fb)
end

"""Prove emptiness from Julia IR without inventing a runtime value.
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)"""
function _iterable_proven_empty(arg::NirNode, ctx)::Bool
    arg isa NirLiteral && return arg.value isa Tuple && isempty(arg.value)
    arg isa NirSSA || return false
    get_ssa_type(ctx, arg) === Tuple{} && return true
    local def = _ssa_def(arg, ctx)
    if def isa NirNew && !isempty(def.operands)
        # a `%new` whose type operand is written down literally, and whose last field
        # operand is the literal dims tuple `(0,)`
        local T = def.type_operand isa NirLiteral ? def.type_operand.value : nothing
        local dims = nir_const(def.operands[end])
        return T isa Type && T <: AbstractVector && dims isa Tuple &&
               length(dims) == 1 && dims[1] == 0
    end
    if def isa NirCall
        local f = _nir_callee_object(def.callee)
        local empty_constructor = f === Core.tuple || f === Base.vect ||
                                  (isdefined(Core, :svec) && f === Core.svec)
        return empty_constructor && isempty(def.operands)
    end
    return false
end

"""Allocate the valid-Julia `_RuntimeComposition{V}` captured context.
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)"""
function _emit_runtime_composition_context!(fb::InstrBuilder, container_arg,
                                            container_type::DataType, ctx)::InstrBuilder
    local CT = _RuntimeComposition{container_type}
    local info = get(ctx.type_registry.structs, CT, nothing)
    info === nothing && error("runtime composition type was not registered: $CT")
    local bld = _ctx_builder(ctx, "_emit_runtime_composition_context!")
    i32_const!(bld, Int64(ensure_type_id!(ctx.type_registry, CT)))
    local field_wasm = ctx.mod.types[Int(info.wasm_type_idx) + 1].fields[Int(info.field_offset) + 1].valtype
    emit_value!(bld, container_arg, ctx, field_wasm)
    struct_new!(bld, info.wasm_type_idx)
    append_builder!(fb, bld)
    return fb
end

"""
Lower `Core._apply_iterate(iterate, f, t)` where `t` is a runtime-length Vararg tuple.

parity(quarantine: Julia varargs — dart has no runtime-length parameter list; every
dart call site names a static arity, so dart2wasm has no `_apply_iterate` counterpart
and nothing here mirrors a dart structure).

There is no iteration to emit. `t`'s representation is the `{Object, data, size}`
struct (`register_vararg_tuple_type!`, structs.jl), and the callee's Vararg
specialization takes exactly that struct as its ONE physical parameter
(`trim_compile_plan`'s packed projection). So the splat IS the call: push `t`, call.

The callee must be in the closed world with that exact packed signature and that exact
return type — `_apply_iterate_vararg_target_mi` (ir.jl) enrolls it when, and only when,
exactly one method answers the open-ended signature. Anything else (a callee with no
Vararg specialization, an arity-overloaded callee, a non-function target) is a loud
reject: `f(t...)` returns a value natively.

There is no result bridge, because none can be needed. The enrolled signature is
derived from THIS container type, so the callee's compiled return type and inference's
answer for the splat statement are one question asked once. A disagreement would mean
the two disagree about what was called — that is the finding, not something to coerce
past.
"""
function _emit_apply_iterate_vararg_call!(fb::InstrBuilder, target_value,
                                          container_arg, container_type::DataType,
                                          ctx, idx::Int)::Nothing
    local bld = _ctx_builder(ctx, "_emit_apply_iterate_vararg_call!")
    local target = (ctx.func_registry === nothing || !(target_value isa Function)) ? nothing :
                   get_function(ctx.func_registry, target_value, (container_type,))
    local want = get(ctx.ssa_types, idx, Any)
    # EXACT signature only. get_function's subtype-tolerant passes exist for
    # overload resolution; here a near-miss would run a body compiled for a
    # different packed layout (a non-empty narrowing's body assumes length >= 1).
    if target === nothing || target.arg_types != (container_type,) ||
       target.return_type !== want
        emit_unsupported_stub!(ctx, bld, :unsupported_method,
            "_apply_iterate over a runtime Vararg tuple whose callee has no compiled " *
            "$(container_type) → $(want) specialization"; idx=idx)
        append_builder!(fb, bld)
        return nothing
    end
    local info = register_vararg_tuple_type!(ctx.mod, ctx.type_registry, container_type)
    emit_value!(bld, container_arg, ctx, ConcreteRef(info.wasm_type_idx, true))
    call!(bld, target.wasm_idx, WasmValType[], WasmValType[])
    if want === Union{}
        # The callee always throws, so its Wasm type has no result and everything
        # after the call is dead: a structural trap on a path Julia proves dead.
        unreachable!(bld)   # structural trap (the callee returns Bottom)
        ctx.last_stmt_was_stub = true
    end
    append_builder!(fb, bld)
    return nothing
end

"""Recover the literal values captured in Core.svec for `_apply_iterate` prefixes.
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)"""
function _apply_iterate_svec_values(arg::NirNode, ctx)::Union{Nothing, Vector{Any}}
    def = _ssa_def(arg, ctx)
    def isa NirCall || return nothing
    (isdefined(Core, :svec) && _nir_callee_object(def.callee) === Core.svec) || return nothing
    return Any[def.operands...]
end

"""Lower `Base.vect(prefix..., tail...)` where `tail` is one `Vector{T}`.
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)"""
function _emit_apply_iterate_vect_prefix!(fb::InstrBuilder, prefix_args,
                                           container_arg, container_type::DataType, ctx)::Union{Nothing, InstrBuilder}
    vec_info = get(ctx.type_registry.structs, container_type, nothing)
    elem_type = eltype(container_type)
    arr_type_idx = get(ctx.type_registry.arrays, elem_type, nothing)
    size_info = get(ctx.type_registry.structs, Tuple{Int64}, nothing)
    bld = _ctx_builder(ctx, "_emit_apply_iterate_vect_prefix!")
    if vec_info === nothing || arr_type_idx === nothing || size_info === nothing
        emit_unsupported_stub!(ctx, bld, :unsupported_method,
                               "apply-iterate vect: vector layout unavailable")
        append_builder!(fb, bld)
        return
    end

    vec_idx = vec_info.wasm_type_idx
    arr_ref = ConcreteRef(arr_type_idx, true)
    size_idx = size_info.wasm_type_idx
    size_ref = ConcreteRef(size_idx, true)
    off = vec_info.field_offset
    n_prefix = length(prefix_args)

    vec_local = allocate_local!(ctx, ConcreteRef(vec_idx, true))
    src_local = allocate_local!(ctx, arr_ref)
    tail_len = allocate_local!(ctx, I32)
    total_len = allocate_local!(ctx, I32)
    dst_local = allocate_local!(ctx, arr_ref)
    src_off_local = allocate_local!(ctx, I32)

    # The SSA producer already carries the canonical registered Vector ref. Do
    # not introduce a downcast here: the local declaration validates the exact
    # producer type and catches any registry disagreement at build time.
    emit_value!(bld, container_arg, ctx, ConcreteRef(vec_idx, true))
    local_set!(bld, vec_local)
    local_get!(bld, vec_local)
    struct_get!(bld, vec_idx, off, arr_ref)
    local_set!(bld, src_local)
    local_get!(bld, vec_local)
    struct_get!(bld, vec_idx, array_offset_field_idx(vec_info), I32)
    local_set!(bld, src_off_local)
    local_get!(bld, vec_local)
    struct_get!(bld, vec_idx, off + 1, size_ref)
    struct_get!(bld, size_idx, size_info.field_offset, I64)
    narrow_length_to_i32!(bld)
    local_tee!(bld, tail_len)
    i32_const!(bld, n_prefix)
    num!(bld, Opcode.I32_ADD)
    local_tee!(bld, total_len)
    array_new_default!(bld, arr_type_idx)
    local_set!(bld, dst_local)

    elem_wasm = ctx.mod.types[arr_type_idx + 1].elem.valtype
    for (i, arg) in enumerate(prefix_args)
        local_get!(bld, dst_local)
        i32_const!(bld, i - 1)
        emit_value!(bld, arg, ctx, elem_wasm)
        array_set!(bld, arr_type_idx, elem_wasm)
    end

    local_get!(bld, dst_local)
    i32_const!(bld, n_prefix)
    local_get!(bld, src_local)
    local_get!(bld, src_off_local)   # the tail's elements start at its :ref offset
    local_get!(bld, tail_len)
    array_copy!(bld, arr_type_idx, arr_type_idx)

    # Vector{T} and its size tuple are ordinary Object descendants.
    emit_struct_prefix!(bld, ctx.type_registry, container_type, vec_info)
    local_get!(bld, dst_local)
    emit_struct_prefix!(bld, ctx.type_registry, Tuple{Int64}, size_info)
    local_get!(bld, total_len)
    widen_length_to_i64!(bld)
    struct_new!(bld, size_idx)
    i32_const!(bld, 0)   # off0 of the fresh array
    struct_new!(bld, vec_idx)
    append_builder!(fb, bld)
end

# ============================================================================
# _apply_iterate helpers (vector splatting)
# ============================================================================

"""
Map a resolved known binary function object to its WASM reduce opcode for the given element type.
Returns nothing if the function is not a known binary reduce operation.
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)
"""
function _get_binary_reduce_opcode(func, elem_type::Type)::Union{UInt8, Nothing}
    local is_add = func === (+) || func === Core.Intrinsics.add_int ||
                   func === Core.Intrinsics.add_float
    local is_mul = func === (*) || func === Core.Intrinsics.mul_int ||
                   func === Core.Intrinsics.mul_float
    if elem_type === Int64 || elem_type === UInt64
        is_add && return Opcode.I64_ADD
        is_mul && return Opcode.I64_MUL
    elseif elem_type === Int32 || elem_type === UInt32
        is_add && return Opcode.I32_ADD
        is_mul && return Opcode.I32_MUL
    elseif elem_type === Float64
        is_add && return Opcode.F64_ADD
        is_mul && return Opcode.F64_MUL
    elseif elem_type === Float32
        is_add && return Opcode.F32_ADD
        is_mul && return Opcode.F32_MUL
    end
    return nothing
end

"""
Emit one reduction over the concatenation of one or more homogeneous vectors.
The first observed element initializes the accumulator; later elements use the
operator. An all-empty input throws a real MethodError with Julia's `(f, (), world)`
payload instead of fabricating an identity value.
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)
"""
function _emit_apply_method_error!(bld::InstrBuilder, target_value,
                                   ctx::AbstractCompilationContext)::InstrBuilder
    ensure_exception_tag!(ctx.mod)
    local error_info = register_struct_type!(ctx.mod, ctx.type_registry, MethodError)
    local args_info = register_tuple_type!(ctx.mod, ctx.type_registry, Tuple{})
    error_info === nothing && error("MethodError layout is unavailable")
    args_info === nothing && error("Tuple{} layout is unavailable")

    # MethodError(f, (), world): all three fields are real Julia values. The
    # closed-world module is compiled at one world snapshot, so the current
    # counter is the dispatch world that produced this lowering.
    emit_struct_prefix!(bld, ctx.type_registry, MethodError, error_info)
    emit_value!(bld, NirLiteral(target_value), ctx, AnyRef; from_julia=typeof(target_value))
    emit_struct_prefix!(bld, ctx.type_registry, Tuple{}, args_info)
    struct_new!(bld, args_info.wasm_type_idx)
    i64_const!(bld, Int64(WASM_WORLD_AGE))
    struct_new!(bld, error_info.wasm_type_idx)
    emit_throw_value!(bld, ctx.mod)
    return bld
end

"""
Julia's `Core.throw_methoderror(f, args...)` (jl_f_throw_methoderror, jl_method_error): throw
`MethodError(f, (args...,), world)`, whose `args` tuple has the type the collector numbered for
it (tuple_runtime_type). When a value's runtime type is known only at run time, WT cannot
build that tuple (MARCH 13.10), and the statement traps, as a dynamic call's class switch traps
where Julia has no method (dev/formal/ClassIdSwitch.tla): never a MethodError that is not
Julia's (dev/AUDIT.md A3S1 carries both traps).
parity(pkg/dart2wasm/lib/code_generator.dart:2955 CodeGenerator.visitThrow)
"""
function _emit_throw_methoderror!(bld::InstrBuilder, args::AbstractVector,
                                  ctx::AbstractCompilationContext)::InstrBuilder
    isempty(args) && error("Core.throw_methoderror takes its function")
    local static(a) = _collector_static_type(a, ctx.slot_types)
    local tuple_type = tuple_runtime_type(args[2:end], ctx.slot_types)
    if tuple_type === nothing
        unreachable!(bld)   # structural trap: Julia has no method for this call (A3S1)
        return bld
    end
    ensure_exception_tag!(ctx.mod)
    local reg = ctx.type_registry
    local error_info = register_struct_type!(ctx.mod, reg, MethodError)
    local args_info = register_tuple_type!(ctx.mod, reg, tuple_type)
    error_info === nothing && error("MethodError layout is unavailable")
    args_info === nothing && error("$(tuple_type) layout is unavailable")
    local err_def = ctx.mod.types[Int(error_info.wasm_type_idx) + 1]
    local tup_def = ctx.mod.types[Int(args_info.wasm_type_idx) + 1]
    emit_struct_prefix!(bld, reg, MethodError, error_info)
    local f_type = static(args[1])
    emit_value!(bld, args[1], ctx, err_def.fields[wasm_field_idx(error_info, 1) + 1].valtype;
                from_julia=(f_type isa DataType && isconcretetype(f_type)) ? f_type : nothing)
    emit_struct_prefix!(bld, reg, tuple_type, args_info)
    for (i, a) in enumerate(args[2:end])
        emit_value!(bld, a, ctx, tup_def.fields[wasm_field_idx(args_info, i) + 1].valtype;
                    from_julia=tuple_type.parameters[i])
    end
    struct_new!(bld, args_info.wasm_type_idx)
    i64_const!(bld, Int64(WASM_WORLD_AGE))
    struct_new!(bld, error_info.wasm_type_idx)
    emit_throw_value!(bld, ctx.mod)
    return bld
end

# parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)
function _emit_apply_iterate_reduce!(fb::InstrBuilder, container_args,
                                      container_types::Vector{DataType}, elem_type::Type,
                                      reduce_op::UInt8, target_value, ctx)::Union{Nothing, InstrBuilder}
    bld = _ctx_builder(ctx, "_emit_apply_iterate_reduce!")
    arr_type_idx = get(ctx.type_registry.arrays, elem_type, nothing)
    if arr_type_idx === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: data array type unregistered")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end

    size_info = get(ctx.type_registry.structs, Tuple{Int64}, nothing)
    if size_info === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: size tuple type unregistered")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end
    size_type_idx = size_info.wasm_type_idx
    elem_wasm_type = julia_to_wasm_type(elem_type)
    acc_local = allocate_local!(ctx, elem_wasm_type)
    has_value = allocate_local!(ctx, I32)
    elem_local = allocate_local!(ctx, elem_wasm_type)
    i32_const!(bld, 0)
    local_set!(bld, has_value)

    for (container_arg, container_type) in zip(container_args, container_types)
        local vec_info = get(ctx.type_registry.structs, container_type, nothing)
        vec_info === nothing && error("registered vector layout missing for $container_type")
        local vec_idx = vec_info.wasm_type_idx
        local vec_local = allocate_local!(ctx, ConcreteRef(vec_idx, true))
        local arr_local = allocate_local!(ctx, ConcreteRef(arr_type_idx, true))
        local len_local = allocate_local!(ctx, I32)
        local i_local = allocate_local!(ctx, I32)
        local off_local = allocate_local!(ctx, I32)

        emit_value!(bld, container_arg, ctx, ConcreteRef(vec_idx, true))
        local_set!(bld, vec_local)
        local_get!(bld, vec_local)
        struct_get!(bld, vec_idx, wasm_field_idx(vec_info, 1), ConcreteRef(arr_type_idx, true))
        local_set!(bld, arr_local)
        local_get!(bld, vec_local)
        struct_get!(bld, vec_idx, array_offset_field_idx(vec_info), I32)
        local_set!(bld, off_local)
        local_get!(bld, vec_local)
        struct_get!(bld, vec_idx, wasm_field_idx(vec_info, 2), ConcreteRef(size_type_idx, true))
        struct_get!(bld, size_type_idx, wasm_field_idx(size_info, 1), I64)
        num!(bld, Opcode.I32_WRAP_I64)
        local_set!(bld, len_local)
        i32_const!(bld, 0)
        local_set!(bld, i_local)

        done_label = block!(bld)
        loop_label = loop!(bld)
        local_get!(bld, i_local)
        local_get!(bld, len_local)
        num!(bld, Opcode.I32_GE_S)
        br_if!(bld, done_label)
        local_get!(bld, arr_local)
        local_get!(bld, off_local)   # element i sits at the :ref offset + i
        local_get!(bld, i_local)
        num!(bld, Opcode.I32_ADD)
        array_get!(bld, arr_type_idx, elem_wasm_type;
                   signed=packed_array_signedness(elem_type))
        local_set!(bld, elem_local)
        local_get!(bld, has_value)
        if_!(bld; results=WasmValType[elem_wasm_type])
        local_get!(bld, acc_local)
        local_get!(bld, elem_local)
        num!(bld, reduce_op)
        else_!(bld)
        local_get!(bld, elem_local)
        end_block!(bld)
        local_set!(bld, acc_local)
        i32_const!(bld, 1)
        local_set!(bld, has_value)
        local_get!(bld, i_local)
        i32_const!(bld, 1)
        num!(bld, Opcode.I32_ADD)
        local_set!(bld, i_local)
        br!(bld, loop_label)
        end_block!(bld)
        end_block!(bld)
    end

    local_get!(bld, has_value)
    num!(bld, Opcode.I32_EQZ)
    if_!(bld)
    _emit_apply_method_error!(bld, target_value, ctx)
    end_block!(bld)
    local_get!(bld, acc_local)
    append_builder!(fb, bld)
end

"""
Emit a shallow copy for _apply_iterate(iterate, Base.vect, vec::Vector{T}) — i.e.
the `[v...]` splat-collect idiom, which for a single Vector argument is exactly
`copy(v)`: a new Vector{T} with the same elements.

Builds the result Object struct from `vec`:
  * classId / identityHash — canonical fresh Object prefix
  * data_array — a fresh array.new_default of the LOGICAL length (read from the
    size tuple, not array.len, since the backing array may carry extra capacity),
    populated via array.copy from the source's :ref offset
  * size_tuple — reused from the source (Tuple{Int64} is immutable → safe to share)
  * off0 — 0, the fresh array's first element (an Array result; a runtime-length tuple
    result has no offset field)

Allocates 5 temporary locals: vec_ref, src_arr, len (i32), new_arr, src_off (i32).
parity(quarantine: Julia's Core._apply_iterate, a call splatting run-time containers; dart has no splatted call.)
"""
function _emit_apply_iterate_vect!(fb::InstrBuilder, container_arg, container_type::DataType, ctx;
                                   result_type::DataType=container_type)::Union{Nothing, InstrBuilder}
    vec_info  = get(ctx.type_registry.structs, container_type, nothing)
    result_info = get(ctx.type_registry.structs, result_type, nothing)
    elem_type = eltype(container_type)
    arr_type_idx = get(ctx.type_registry.arrays, elem_type, nothing)
    size_info = get(ctx.type_registry.structs, Tuple{Int64}, nothing)
    bld = _ctx_builder(ctx, "_emit_apply_iterate_vect!")
    if vec_info === nothing || result_info === nothing || arr_type_idx === nothing || size_info === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: vector layout unavailable")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end
    vec_type_idx = vec_info.wasm_type_idx
    result_type_idx = result_info.wasm_type_idx
    field_offset = vec_info.field_offset           # 1: data array (0 = typeId, 2 = size)
    size_type_idx = size_info.wasm_type_idx
    size_field_offset = size_info.field_offset

    vec_ref_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(vec_type_idx, true))
    src_arr_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(arr_type_idx, true))
    len_local     = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, I32)
    new_arr_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(arr_type_idx, true))
    src_off_local = UInt32(allocate_local!(ctx, I32))

    # vec_ref = container
    emit_value!(bld, container_arg, ctx, ConcreteRef(UInt32(vec_type_idx), true))
    local_set!(bld, vec_ref_local)

    # src_arr = vec_ref.data  (field_offset)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset, ConcreteRef(arr_type_idx, true))
    local_set!(bld, src_arr_local)

    # src_off = vec_ref.off0 (the :ref offset of its first element)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, array_offset_field_idx(vec_info), I32)
    local_set!(bld, src_off_local)

    # len = vec_ref.size[1]  (vec → size tuple → i64 → i32)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset + 1, ConcreteRef(size_type_idx, true))
    struct_get!(bld, size_type_idx, size_field_offset, I64)
    num!(bld, Opcode.I32_WRAP_I64)
    local_set!(bld, len_local)

    # new_arr = array.new_default(arr_type, len)
    local_get!(bld, len_local)
    array_new_default!(bld, arr_type_idx)
    local_set!(bld, new_arr_local)

    # array.copy(new_arr, 0, src_arr, src_off, len)
    local_get!(bld, new_arr_local)
    i32_const!(bld, 0)
    local_get!(bld, src_arr_local)
    local_get!(bld, src_off_local)
    local_get!(bld, len_local)
    array_copy!(bld, arr_type_idx, arr_type_idx)

    # result = struct.new [Object prefix, new_arr, size_tuple(src)]
    emit_struct_prefix!(bld, ctx.type_registry, result_type, result_info)
    local_get!(bld, new_arr_local)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset + 1, ConcreteRef(size_type_idx, true))  # size tuple
    result_type <: Array && i32_const!(bld, 0)   # an Array result's off0: the fresh array's first element
    struct_new!(bld, result_type_idx)
    append_builder!(fb, bld)
end



# Emit a SimpleVector as its actual WasmGC array representation.
# parity(quarantine: Julia's SimpleVector, a runtime-internal array of values; dart has none.)
function _emit_svec_values!(b::InstrBuilder, values::AbstractVector{<:NirNode},
                            ctx::AbstractCompilationContext)::InstrBuilder
    info = register_struct_type!(ctx.mod, ctx.type_registry, Core.SimpleVector)
    arr_idx = info.wasm_type_idx
    arr_def = ctx.mod.types[arr_idx + 1]
    arr_def isa ArrayType || error("SimpleVector did not register as a Wasm array")
    elem_type = arr_def.elem.valtype
    for value in values
        emit_value!(b, value, ctx, elem_type)   # the funnel reads the value's static Julia type
    end
    array_new_fixed!(b, arr_idx, length(values), elem_type)
    return b
end

# Resolve an IR value to a HOST SimpleVector constant when its definition is
# compile-time evaluable. Consumers may fold length/index operations directly.
# parity(quarantine: Julia's SimpleVector, a runtime-internal array of values; dart has none.)
function _try_host_svec(arg::NirNode, ctx::AbstractCompilationContext)::Union{Nothing, Core.SimpleVector}
    st = _ssa_def(arg, ctx)
    if st isa NirCall || st isa NirInvoke
        a1 = _nir_callee_object(st.callee)
        rest = st.operands
        if a1 === Base.padding && length(rest) == 2 && nir_const(rest[1]) isa Type &&
           nir_const(rest[2]) isa Integer
            return Base.padding(nir_const(rest[1]), Int(nir_const(rest[2])))
        elseif a1 === Core.getfield && length(rest) >= 2 && nir_quoted(rest[1])
            fld = nir_const(rest[2])
            if fld isa Symbol
                v = isdefined(rest[1].value, fld) ? getfield(rest[1].value, fld) : nothing
                v isa Core.SimpleVector && return v
            end
        end
    end
    return nothing
end

"""
    _try_fold_layout_pointerref(ptr_arg, ctx) -> DataTypeLayout | nothing

P3 gap 450889a9cb7e: fold `unsafe_load(convert(Ptr{DataTypeLayout},
dt.layout))` (the datatype_layoutsize / datatype_arrayelem idiom) when `dt`
is a DataType literal — the layout struct is immutable host metadata, fully
known at compile time. Returns the host-loaded DataTypeLayout for literal
materialization, or nothing if the chain doesn't match.
parity(quarantine: a DataType's layout is Julia's host metadata, read through a pointer; dart
has no layout pointers.)
"""
function _try_fold_layout_pointerref(ptr_arg::NirNode, ctx::AbstractCompilationContext)::Union{Nothing, Base.DataTypeLayout}
    cur = ptr_arg
    for _ in 1:4
        cur isa NirSSA || return nothing
        st = ctx.nir[cur.id]
        (st.slot == 0 && st.node isa NirCall) || return nothing
        st = st.node
        cf = st.callee
        if cf === Core.Intrinsics.bitcast && length(st.operands) >= 2
            cur = st.operands[2]
        elseif cf === Core.getfield && length(st.operands) >= 2
            dt = st.operands[1]
            dt = dt isa NirLiteral ? dt.value :
                 dt isa NirGlobalRef ? (dt.bound ? dt.value : nothing) : dt
            fld = nir_const(st.operands[2])
            (dt isa DataType && fld === :layout) || return nothing
            isdefined(dt, :layout) || return nothing
            lay = getfield(dt, :layout)
            lay == C_NULL && return nothing
            return unsafe_load(convert(Ptr{Base.DataTypeLayout}, lay))
        else
            return nothing
        end
    end
    return nothing
end
