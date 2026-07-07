# ============================================================================
# Call Compilation
# ============================================================================

"""
    _is_externref_value(val, ctx) -> Bool

PURE-904: Check if a value (Argument or SSAValue) produces externref on the Wasm stack.
Used by numeric intrinsic handlers to detect when unboxing is needed.
"""
function _is_externref_value(val, ctx::AbstractCompilationContext)::Bool
    if val isa Core.Argument
        arg_idx = ctx.is_compiled_closure ? val.n : val.n - 1
        if arg_idx >= 1 && arg_idx <= length(ctx.arg_types)
            return julia_to_wasm_type(ctx.arg_types[arg_idx]) === ExternRef
        end
    elseif val isa Core.SSAValue
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
    _is_typeof_ssa(val, ctx) -> Bool

PURE-9026: Check if a value is an SSAValue whose defining statement is a typeof() call.
"""
function _is_typeof_ssa(val, ctx::AbstractCompilationContext)::Bool
    if !(val isa Core.SSAValue)
        return false
    end
    if val.id < 1 || val.id > length(ctx.code_info.code)
        return false
    end
    stmt = ctx.code_info.code[val.id]
    if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 2
        f = stmt.args[1]
        return is_func(f, :typeof)
    end
    return false
end

"""
    _resolve_type_const(val, ctx) -> Union{DataType, Nothing}

PURE-9026: If val is a Type constant (GlobalRef to a type, or a direct Type value),
return the DataType. Otherwise return nothing.
"""
function _resolve_type_const(val, ctx::AbstractCompilationContext)::Union{DataType, Nothing}
    if val isa Type && isconcretetype(val)
        return val
    end
    if val isa GlobalRef
        try
            actual = getfield(val.mod, val.name)
            if actual isa Type && isconcretetype(actual)
                return actual
            end
        catch
        end
    end
    return nothing
end

"""
    _ensure_typeof_scratch_local!(ctx) -> UInt32

PURE-9063: Allocate (or return cached) a scratch i32 local for typeof struct lookups.
The local stores the typeId temporarily while the lookup array ref is pushed.
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

march17: a fragment that consumes the parent's top `n` stack values DECLARES them
(seeded from fb's TRACKED stack; append_builder! settles the contract exactly).
"""
function _sub_builder(fb::InstrBuilder, ctx::AbstractCompilationContext, name::String, n::Int)
    local b = InstrBuilder(; func_name=name, mod=ctx.mod)
    local h = length(fb.v.stack)
    n > 0 && h >= n && seed_input!(b, WasmValType[fb.v.stack[h - n + i] for i in 1:n])
    return b
end

function _emit_normalise_narrow_pair!(fb::InstrBuilder, ctx::AbstractCompilationContext,
                                      signed::Bool, julia_width::Int)
    julia_width < 32 || return fb
    bld = _sub_builder(fb, ctx, "_emit_normalise_narrow_pair!", 2)
    li = UInt32(allocate_local!(ctx, I32))
    function norm!()
        if signed
            num!(bld, julia_width == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
        else
            i32_const!(bld, Int64((1 << julia_width) - 1))
            num!(bld, Opcode.I32_AND)
        end
    end
    local_set!(bld, li)   # [a]
    norm!()               # [a*]
    local_get!(bld, li)   # [a*, b]
    norm!()               # [a*, b*]
    append_builder!(fb, bld)
    return fb
end

# Emit a catchable throw of a fieldless exception struct (e.g. DivideError):
# stash the instance in the $current_exn global, then `throw` tag 0 — the same
# mechanism explicit Julia `throw(...)` lowers to, so enclosing try_table
# handlers (and JS, for uncaught propagation) see a real exception, not a trap.
"""builder-native (THE implementation): build the error struct, stash, throw."""
function _emit_throw_error_struct!(bld::InstrBuilder, ctx::AbstractCompilationContext, @nospecialize(ErrT))
    ensure_exception_tag!(ctx.mod)
    exn_global = ensure_exception_global!(ctx.mod)
    info = register_struct_type!(ctx.mod, ctx.type_registry, ErrT)
    if info !== nothing
        emit_type_id!(bld, ctx.type_registry, ErrT)
        struct_new!(bld, info.wasm_type_idx)   # mod-resolved fields (march3)
    else
        ref_null!(bld, AnyRef)
    end
    global_set!(bld, exn_global)
    global_get!(bld, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bld, ExternRef); throw_!(bld, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
    return bld
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function _emit_throw_error_struct!(bytes::Vector{UInt8}, ctx::AbstractCompilationContext, @nospecialize(T))
    bld = InstrBuilder(; func_name="_emit_throw_error_struct!", mod=ctx.mod)
    _emit_throw_error_struct!(bld, ctx, T)
    append!(bytes, builder_code(bld))
    return bytes
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
function _emit_div_guard!(fb::InstrBuilder, ctx::AbstractCompilationContext, is32::Bool;
                          check_overflow::Bool=false, julia_width::Int=(is32 ? 32 : 64))
    lt     = is32 ? I32 : I64
    wconst!(blr, v) = is32 ? i32_const!(blr, v) : i64_const!(blr, v)
    weqz   = is32 ? Opcode.I32_EQZ : Opcode.I64_EQZ
    weq    = is32 ? Opcode.I32_EQ : Opcode.I64_EQ
    la = UInt32(allocate_local!(ctx, lt))
    lb = UInt32(allocate_local!(ctx, lt))
    bld = _sub_builder(fb, ctx, "_emit_div_guard!", 2)
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
function _julia_int_width(@nospecialize(T), is32::Bool)
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
function _emit_shift_guarded!(fb::InstrBuilder, ctx::AbstractCompilationContext, is32::Bool, kind::Symbol;
                              julia_width::Int = (is32 ? 32 : 64), signed_narrow::Bool = false)
    wltu   = is32 ? Opcode.I32_LT_U : Opcode.I64_LT_U
    wand   = is32 ? Opcode.I32_AND : Opcode.I64_AND
    width  = is32 ? 32 : 64
    thr    = clamp(julia_width, 1, width)        # over-shift threshold (Julia width)
    narrow = thr < width                          # operand narrower than its wasm reg
    sl     = UInt32(allocate_local!(ctx, is32 ? I32 : I64))
    shop   = kind === :shl  ? (is32 ? Opcode.I32_SHL : Opcode.I64_SHL) :
             kind === :lshr ? (is32 ? Opcode.I32_SHR_U : Opcode.I64_SHR_U) :
                              (is32 ? Opcode.I32_SHR_S : Opcode.I64_SHR_S)
    bld = _sub_builder(fb, ctx, "_emit_shift_guarded!", 2)
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
        select!(bld)                             # [value, cond? shift : w-1]
        num!(bld, shop)                          # [value >>s clamped]
    else
        # [value, shift] → [result] → select(result, 0, shift < thr)
        _lset(Opcode.LOCAL_TEE, sl)              # [value, shift]  (shift saved)
        num!(bld, shop)                          # [result]
        _wc(0)                                   # [result, 0]
        _lset(Opcode.LOCAL_GET, sl)              # [result, 0, shift]
        _wc(thr)                                 # [result, 0, shift, thr]
        num!(bld, wltu)                          # [result, 0, cond]
        select!(bld)                             # [cond? result : 0]
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
function _emit_wrap_shift_amount_saturating!(fb::InstrBuilder, ctx::AbstractCompilationContext, julia_width::Int)
    amt = UInt32(allocate_local!(ctx, I64))
    bld = _sub_builder(fb, ctx, "_emit_wrap_shift_amount_saturating!", 1)
    local_tee!(bld, amt)                         # [amount]
    i64_const!(bld, Int64(julia_width))          # [amount, jw]
    local_get!(bld, amt)                         # [amount, jw, amount]
    i64_const!(bld, Int64(julia_width))          # [amount, jw, amount, jw]
    num!(bld, Opcode.I64_LT_U)                   # [amount, jw, cond]   cond = amount <u jw
    select!(bld)                                 # [cond ? amount : jw]
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
"""
function emit_char_codepoint_to_rawbits(ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder. Consumes [codepoint:i32] from the stack, pushes [rawbits:i32].
    b = InstrBuilder(; func_name="emit_char_codepoint_to_rawbits", strict=_wt_builder_strict())
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
"""
function emit_char_rawbits_to_codepoint(ctx::AbstractCompilationContext)::Vector{UInt8}
    # MIGRATED to InstrBuilder. Consumes [rawbits:i32] from the stack, pushes [codepoint:i32].
    b = InstrBuilder(; func_name="emit_char_rawbits_to_codepoint", strict=_wt_builder_strict())
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
    _compile_call_checked_mul(func, args, fb, ctx, is_128bit, is_32bit)

Extracted handler for checked_smul_int / checked_umul_int.
Modifies `bytes` in-place.
"""
function _compile_call_checked_mul(func, args, fb::InstrBuilder, ctx::AbstractCompilationContext, is_128bit::Bool, is_32bit::Bool)::Nothing
    if is_128bit
        # 128-bit checked mul: not supported. Strict-mode Approach A — loud reject
        # (natively returns a value, so a silent trap would diverge).
        empty!(bytes)  # PURE-908: clear pre-pushed args
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
                               "128-bit checked multiply (Int128/UInt128)")
    else
        is_signed = is_func(func, :checked_smul_int)
        local_type = is_32bit ? I32 : I64
        local_a = allocate_local!(ctx, local_type)
        local_b = allocate_local!(ctx, local_type)
        local_result = allocate_local!(ctx, local_type)
        bld = InstrBuilder(; func_name="_compile_call_checked_mul", mod=ctx.mod)

        # Save b, save a, compute a*b, save result
        local_set!(bld, local_b)
        local_tee!(bld, local_a)
        local_get!(bld, local_b)
        num!(bld, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
        local_set!(bld, local_result)

        # Push typeId for Tuple struct (field 0 = typeId)
        i32_const!(bld, Int64(ensure_type_id!(ctx.type_registry, is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool})))  # real classId (M3)
        # Push result back for tuple field 1
        local_get!(bld, local_result)

        # Overflow detection for mul
        if is_signed
            # Signed mul overflow: if a==0: false; if a==-1: b==MIN; else: result/a != b
            # Use if/else chain: a.eqz ? 0 : (a==-1 ? (b==MIN) : (result/a != b))
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_EQZ : Opcode.I64_EQZ)
            if_!(bld, I32)  # result type i32
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
            if_!(bld, I32)  # result type i32
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
            if_!(bld, I32)  # result type i32
            i32_const!(bld, 0)
            else_!(bld)
            local_get!(bld, local_result)
            local_get!(bld, local_a)
            num!(bld, is_32bit ? Opcode.I32_DIV_U : Opcode.I64_DIV_U)
            local_get!(bld, local_b)
            num!(bld, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
            end_block!(bld)  # end if/else
        end

        tuple_type = is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool}
        if !haskey(ctx.type_registry.structs, tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
        end
        tuple_info = ctx.type_registry.structs[tuple_type]
        struct_new!(bld, tuple_info.wasm_type_idx)   # mod-resolved fields (march3)
        append_builder!(fb, bld)
    end
    return nothing
end

"""
    _compile_call_flipsign(args, fb, ctx, is_128bit, is_32bit, arg_type)

Extracted handler for flipsign_int.
Modifies `bytes` in-place.
"""
function _compile_call_flipsign(args, fb::InstrBuilder, ctx::AbstractCompilationContext, is_128bit::Bool, is_32bit::Bool, arg_type)::Nothing
    # flipsign_int(x, y) returns -x if y < 0, otherwise x
    # Formula: (x xor signbit) - signbit where signbit = y >> 63 (all 1s if negative)
    # We need both x and y on stack, but they've been pushed as: [x, y]

    bld = _sub_builder(fb, ctx, "_compile_call_flipsign", 2)
    if is_128bit
        # For 128-bit, check if y's hi word is negative
        # flipsign_int(x, y) = y < 0 ? -x : x
        type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
        struct_rt = julia_to_wasm_type_concrete(arg_type, ctx)

        # Pop y struct to local
        y_struct_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
        local_set!(bld, y_struct_local)

        # Pop x struct to local
        x_struct_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
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
        push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
        local_set!(bld, neg_x_local)

        # Allocate result local
        result_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))

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
    return nothing
end

_egal_num_eqop(w::WasmValType)::UInt8 =
    w === I64 ? Opcode.I64_EQ : w === F64 ? Opcode.F64_EQ : w === F32 ? Opcode.F32_EQ : Opcode.I32_EQ

"""
    _emit_egal_box_vs_num!(bld, ctx, ref_local, ref_is_extern, num_local, num_type)

`===` between a BOXED-NUMERIC ref operand (saved in `ref_local`) and an UNBOXED numeric
operand (saved in `num_local`, Julia type `num_type`). Julia `===` requires the same type
AND value, so this is `isa(ref, num_type) && unbox(ref) == num`: the box's classId (field 0)
must equal `num_type`'s DFS id AND its value (field 1) must equal `num`. Guarded by `ref.test`
so a genuine non-numeric ref (struct/string/array) yields false — no trap, no regression
(matches the old "ref vs numeric ⇒ false" for those). Pushes i32 (0/1). Single source for
both arg orderings. (The boxed numeric value rep is the same `get_numeric_box_type!` the
classId funnel boxes into.)
"""
function _emit_egal_box_vs_num!(bld::InstrBuilder, ctx::AbstractCompilationContext,
                                ref_local::Integer, ref_is_extern::Bool,
                                num_local::Integer, num_type::Type)
    num_wasm = julia_to_wasm_type(num_type)
    box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, num_wasm)
    tid = ensure_type_id!(ctx.type_registry, num_type)
    local _anytmp = allocate_local!(ctx, AnyRef)
    local_get!(bld, ref_local)
    ref_is_extern && any_convert_extern!(bld)
    local_tee!(bld, _anytmp)
    ref_test!(bld, Int64(box_idx), false)            # is it this numeric box?
    if_!(bld, I32)
    # classId (field 0) == num_type's id?
    local_get!(bld, _anytmp); ref_cast!(bld, Int64(box_idx), false)
    struct_get!(bld, UInt32(box_idx), UInt32(0), I32)
    i32_const!(bld, Int64(tid)); num!(bld, Opcode.I32_EQ)
    # && value (field 1) == num?
    local_get!(bld, _anytmp); ref_cast!(bld, Int64(box_idx), false)
    struct_get!(bld, UInt32(box_idx), UInt32(1), num_wasm)
    local_get!(bld, num_local); num!(bld, _egal_num_eqop(num_wasm))
    num!(bld, Opcode.I32_AND)
    else_!(bld)
    i32_const!(bld, 0)
    end_block!(bld)
    return bld
end

"""
    _compile_call_egaleq(args, fb, ctx, is_128bit, is_32bit, arg_type)

Extracted handler for :(===) identity comparison (the post-arg-push branch).
Modifies `bytes` in-place.
"""
function _compile_call_egaleq(args, fb::InstrBuilder, ctx::AbstractCompilationContext, is_128bit::Bool, is_32bit::Bool, arg_type)::Nothing
    bld = InstrBuilder(; func_name="_compile_call_egaleq", mod=ctx.mod)
    # march17: the two operands are already on fb — declare them (the width by arm)
    if !is_128bit
        local _sw = arg_type === Float64 ? F64 : arg_type === Float32 ? F32 :
                    isempty(fb.v.stack) ? AnyRef : fb.v.stack[end]
        local _sw2 = length(fb.v.stack) >= 2 ? fb.v.stack[end - 1] : _sw
        seed_input!(bld, WasmValType[_sw2, _sw])
    end
    if is_128bit
        local _i128sr = _int128_structref(ctx, arg_type)
        seed_input!(bld, WasmValType[_i128sr, _i128sr])
        emit_int128_eq!(bld, ctx, arg_type)
    elseif arg_type === Float64
        num!(bld, Opcode.F64_EQ)
    elseif arg_type === Float32
        num!(bld, Opcode.F32_EQ)
    else
        local arg2_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
        local arg1_is_ref = is_ref_type_or_union(arg_type) && arg_type !== Nothing
        local arg2_is_ref = is_ref_type_or_union(arg2_type) && arg2_type !== Nothing

        # Quick check: if one arg is ref-typed and other is Nothing (compiles to i32),
        # they can't be equal via ref.eq OR i32/i64 eq. Drop both and return false.
        if (arg1_is_ref && arg2_type === Nothing) || (arg2_is_ref && arg_type === Nothing)
            drop!(bld)
            drop!(bld)
            i32_const!(bld, 0)
            append_builder!(fb, bld)
            return nothing
        end

        # Special case: both args are Nothing-typed. Need to check actual Wasm representation
        # because Nothing can compile to either ref.null OR i32.const depending on context.
        if arg_type === Nothing && arg2_type === Nothing
            # typed channel: the emissions' own types replace the REF_NULL/LOCAL_GET
            # first-byte checks + double LEB decode of local indices.
            local arg1_bytes_chk, _a1_ty = compile_value_typed(args[1], ctx)
            local arg2_bytes_chk, _a2_ty = compile_value_typed(args[2], ctx)
            local a1_is_ref = _a1_ty !== nothing && _wt_is_ref(_a1_ty)
            local a2_is_ref = _a2_ty !== nothing && _wt_is_ref(_a2_ty)
            local a1_is_anyref_fp = (_a1_ty === AnyRef)
            local a2_is_anyref_fp = (_a2_ty === AnyRef)
            local a1_is_externref_fp = (_a1_ty === ExternRef)
            local a2_is_externref_fp = (_a2_ty === ExternRef)
            # If Wasm types mismatch (one ref, one not), drop both and return false
            if a1_is_ref != a2_is_ref
                drop!(bld)
                drop!(bld)
                i32_const!(bld, 0)
                append_builder!(fb, bld)
                return nothing
            elseif a1_is_ref && a2_is_ref
                # Both refs - need ref.eq, but anyref/externref require casting to eqref first
                if a1_is_anyref_fp && a2_is_anyref_fp
                    # Both anyref: cast both to eqref
                    local _fp_tmp = allocate_local!(ctx, EqRef)
                    ref_cast!(bld, EqRef, true)
                    local_set!(bld, _fp_tmp)
                    ref_cast!(bld, EqRef, true)
                    local_get!(bld, _fp_tmp)
                elseif a1_is_externref_fp && a2_is_externref_fp
                    # Both externref: convert to anyref then cast to eqref
                    local _fp_tmp2 = allocate_local!(ctx, EqRef)
                    any_convert_extern!(bld)
                    ref_cast!(bld, EqRef, true)
                    local_set!(bld, _fp_tmp2)
                    any_convert_extern!(bld)
                    ref_cast!(bld, EqRef, true)
                    local_get!(bld, _fp_tmp2)
                elseif a1_is_anyref_fp
                    # arg1 anyref, arg2 concrete/eqref: save arg2, cast arg1, restore
                    local _fp_tmp3 = allocate_local!(ctx, EqRef)
                    local_set!(bld, _fp_tmp3)
                    ref_cast!(bld, EqRef, true)
                    local_get!(bld, _fp_tmp3)
                elseif a2_is_anyref_fp
                    # arg2 anyref: cast to eqref
                    ref_cast!(bld, EqRef, true)
                elseif a1_is_externref_fp
                    # arg1 externref: save arg2, convert+cast arg1, restore
                    local _fp_tmp4 = allocate_local!(ctx, EqRef)
                    local_set!(bld, _fp_tmp4)
                    any_convert_extern!(bld)
                    ref_cast!(bld, EqRef, true)
                    local_get!(bld, _fp_tmp4)
                elseif a2_is_externref_fp
                    # arg2 externref: convert+cast
                    any_convert_extern!(bld)
                    ref_cast!(bld, EqRef, true)
                end
                num!(bld, Opcode.REF_EQ)
                append_builder!(fb, bld)
                return nothing
            end
            # Both numeric - fall through to normal handling
        end

        # Check if args were actually compiled as refs (Nothing can compile to ref.null OR i32.const 0)
        # The bytes already have [arg1_bytes..., arg2_bytes...]
        # Check last pushed arg (arg2) - if it starts with REF_NULL (0xD0), it's a ref
        # Also check for local.get of ref-typed local
        local arg1_wasm_is_ref = arg1_is_ref
        local arg2_wasm_is_ref = arg2_is_ref
        # PURE-9064: Detect anyref/externref from actual wasm type, not just arg_type === Any.
        # Abstract types like Type, DataType etc. also map to AnyRef.
        local _arg1_wasm = julia_to_wasm_type(arg_type)
        local _arg2_wasm = julia_to_wasm_type(arg2_type)
        local arg1_is_externref = (_arg1_wasm === ExternRef)
        local arg2_is_externref = (_arg2_wasm === ExternRef)
        local arg1_is_anyref = (_arg1_wasm === AnyRef)
        local arg2_is_anyref = (_arg2_wasm === AnyRef)
        # anyref/externref types are always ref types
        if arg1_is_anyref || arg1_is_externref
            arg1_wasm_is_ref = true
        end
        if arg2_is_anyref || arg2_is_externref
            arg2_wasm_is_ref = true
        end
        # Check Wasm representation for any potentially mixed comparison
        # (when one arg is ref-typed or Nothing, verify actual Wasm types)
        if arg_type === Nothing || arg2_type === Nothing || arg1_is_ref || arg2_is_ref
            # Re-compile args to check their Wasm representation
            # arg1 first, arg2 second on stack
            # For Nothing-typed args, check actual Wasm representation
            # (Nothing can compile to ref.null OR i32.const 0 depending on context)
            # Check arg1's Wasm type when:
            # - arg_type === Nothing (need to verify if it's actually ref.null or i32)
            # - arg2_type === Nothing (need to know if arg1 is ref to do proper comparison)
            # - arg_type === Any (PURE-046: Any maps to externref, must check actual local type)
            if length(args) >= 1 && (arg_type === Nothing || arg2_type === Nothing || arg_type === Any || arg1_is_ref)
                # dart2wasm carries the wasm type with the value: derive ref-ness and
                # externref-ness from the inferred type instead of scanning the bytes.
                # `nothing` is treated as a ref (may compile to ref.null).
                local _a1_wt = static_wasm_type(args[1], ctx)
                arg1_wasm_is_ref = is_nothing_value(args[1], ctx) || _wt_is_ref(_a1_wt)
                arg1_is_externref = (_a1_wt === ExternRef)
                # PURE-046/9064: Override local type check if Julia type maps to anyref/externref
                if arg1_is_anyref || arg1_is_externref
                    arg1_wasm_is_ref = true
                end
            end
            # Check arg2's Wasm type when:
            # - arg2_type === Nothing (need to verify if it's actually ref.null or i32)
            # - arg_type === Nothing (need to know if arg2 is ref to do proper comparison)
            # - arg2_type === Any (PURE-046: Any maps to externref, must check actual local type)
            if length(args) >= 2 && (arg2_type === Nothing || arg_type === Nothing || arg2_type === Any || arg2_is_ref)
                # dart2wasm carries the wasm type with the value: derive ref-ness and
                # externref-ness from the inferred type instead of scanning the bytes.
                local _a2_wt = static_wasm_type(args[2], ctx)
                arg2_wasm_is_ref = is_nothing_value(args[2], ctx) || _wt_is_ref(_a2_wt)
                arg2_is_externref = (_a2_wt === ExternRef)
                # PURE-046/9064: Override local type check if Julia type maps to anyref/externref
                if arg2_is_anyref || arg2_is_externref
                    arg2_wasm_is_ref = true
                end
            end
        end
        if arg1_wasm_is_ref && arg2_wasm_is_ref
            # PURE-324: For immutable structs, === means VALUE equality (field-by-field),
            # not identity. WasmGC ref.eq is identity comparison, so we must emit
            # struct.get for each field and compare with the appropriate opcode.
            local _do_struct_egal = false
            local _egal_struct_info = nothing
            if !arg1_is_externref && !arg2_is_externref &&
               arg_type isa DataType && arg_type === arg2_type &&
               is_struct_type(arg_type) && !ismutabletype(arg_type) &&
               haskey(ctx.type_registry.structs, arg_type)
                _egal_struct_info = ctx.type_registry.structs[arg_type]
                _do_struct_egal = true
            end
            if _do_struct_egal
                # Immutable struct === : field-by-field value comparison
                local egal_info = _egal_struct_info
                local egal_type_idx = egal_info.wasm_type_idx
                local egal_wasm_type = ConcreteRef(egal_type_idx, true)
                # Save both args to locals (arg2 is on top, arg1 below)
                local egal_local2 = allocate_local!(ctx, egal_wasm_type)
                local egal_local1 = allocate_local!(ctx, egal_wasm_type)
                local_set!(bld, egal_local2)
                local_set!(bld, egal_local1)
                local n_fields = length(egal_info.field_types)
                for fi in 1:n_fields
                    local egal_ft = egal_info.field_types[fi]
                    local egal_wt = julia_to_wasm_type(egal_ft)
                    # Get wasm field index (accounts for typeId at field 0)
                    local_get!(bld, egal_local1)
                    struct_get!(bld, egal_type_idx, wasm_field_idx(egal_info, fi), egal_wt)
                    local_get!(bld, egal_local2)
                    struct_get!(bld, egal_type_idx, wasm_field_idx(egal_info, fi), egal_wt)
                    # Compare with type-appropriate opcode
                    if egal_wt === I32
                        num!(bld, Opcode.I32_EQ)
                    elseif egal_wt === I64
                        num!(bld, Opcode.I64_EQ)
                    elseif egal_wt === F32
                        num!(bld, Opcode.F32_EQ)
                    elseif egal_wt === F64
                        num!(bld, Opcode.F64_EQ)
                    elseif egal_wt === ExternRef
                        # PURE-6024: externref fields need conversion to eqref for ref.eq
                        local egal_tmp = allocate_local!(ctx, EqRef)
                        any_convert_extern!(bld)
                        ref_cast!(bld, EqRef, true)
                        local_set!(bld, egal_tmp)
                        any_convert_extern!(bld)
                        ref_cast!(bld, EqRef, true)
                        local_get!(bld, egal_tmp)
                        num!(bld, Opcode.REF_EQ)
                    else
                        # Ref-typed field (nested struct, string, etc.): use ref.eq
                        num!(bld, Opcode.REF_EQ)
                    end
                    # AND with previous field results (skip for first field)
                    if fi > 1
                        num!(bld, Opcode.I32_AND)
                    end
                end
                # Handle zero-field structs (singleton types): always equal
                if n_fields == 0
                    i32_const!(bld, 1)
                end
            elseif arg1_is_anyref && arg2_is_anyref
                # PURE-9064: Both anyref — cast to eqref before ref.eq
                # anyref is supertype of eqref, so ref.cast works directly (no any.convert_extern)
                local tmp_eq_a = allocate_local!(ctx, EqRef)
                ref_cast!(bld, EqRef, true)
                local_set!(bld, tmp_eq_a)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, tmp_eq_a)
                num!(bld, Opcode.REF_EQ)
            elseif arg1_is_externref && arg2_is_externref
                # ref.eq requires eqref operands. externref is NOT eqref.
                # Convert externref → anyref → eqref before ref.eq
                # Both externref: convert arg2 (top), save, convert arg1, restore
                local tmp_eq = allocate_local!(ctx, EqRef)
                any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                local_set!(bld, tmp_eq)
                # Now arg1 (externref) is on top
                any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, tmp_eq)
                num!(bld, Opcode.REF_EQ)
            elseif arg1_is_externref
                # arg1 is externref (under arg2 on stack): save arg2, convert arg1, restore arg2
                local tmp_eq2 = allocate_local!(ctx, EqRef)
                local_set!(bld, tmp_eq2)
                any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, tmp_eq2)
                num!(bld, Opcode.REF_EQ)
            elseif arg2_is_externref
                # arg2 is externref (top of stack): just convert it
                any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                num!(bld, Opcode.REF_EQ)
            elseif arg1_is_anyref
                # PURE-9064: arg1 anyref (under arg2 on stack): save arg2, cast arg1, restore
                local tmp_eq_a2 = allocate_local!(ctx, EqRef)
                local_set!(bld, tmp_eq_a2)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, tmp_eq_a2)
                num!(bld, Opcode.REF_EQ)
            elseif arg2_is_anyref
                # PURE-9064: arg2 anyref (top of stack): cast to eqref
                ref_cast!(bld, EqRef, true)
                num!(bld, Opcode.REF_EQ)
            else
                # Both are non-externref, non-anyref refs (mutable structs, arrays, etc.): identity comparison
                num!(bld, Opcode.REF_EQ)
            end
        elseif arg1_wasm_is_ref && !arg2_wasm_is_ref
            # arg1 is a ref (possibly a BOXED NUMERIC), arg2 an unboxed numeric. Julia ===
            # needs same type+value: a numeric box of arg2's type with arg2's value ⇒ true;
            # a genuine non-numeric ref ⇒ false (ref.test guards it). Was: always drop+false,
            # a SILENT WRONG ANSWER for e.g. Any[true][1] === true (returned false).
            local _a2w_eg = julia_to_wasm_type(arg2_type)
            # dart parity: guard on the ACTUAL emitted type, not the static Julia type —
            # 1.13 IR can source the "numeric" operand from an Any-typed (boxed) local, in
            # which case its emission pushes a REF and the numeric save-local corrupts the
            # stack (func-invalidating). Actual-numeric → the classId+value compare;
            # actually-both-refs → eqref identity; else the old drop+false.
            local _a2_act = static_wasm_type(args[2], ctx)
            if (_a2w_eg === I32 || _a2w_eg === I64 || _a2w_eg === F32 || _a2w_eg === F64) &&
               isconcretetype(arg2_type) && _a2_act === _a2w_eg
                local _eg_num = allocate_local!(ctx, _a2w_eg); local_set!(bld, _eg_num)       # save arg2 (top)
                local _eg_ref = allocate_local!(ctx, arg1_is_externref ? ExternRef : AnyRef); local_set!(bld, _eg_ref)
                _emit_egal_box_vs_num!(bld, ctx, _eg_ref, arg1_is_externref, _eg_num, arg2_type)
            elseif _wt_is_ref(_a2_act)
                # both operands are ACTUALLY refs — eqref identity comparison
                local _eg_t2 = allocate_local!(ctx, EqRef)
                _a2_act === ExternRef && any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true); local_set!(bld, _eg_t2)
                arg1_is_externref && any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, _eg_t2)
                num!(bld, Opcode.REF_EQ)
            else
                drop!(bld); drop!(bld); i32_const!(bld, 0)
            end
        elseif !arg1_wasm_is_ref && arg2_wasm_is_ref
            # Mirror: arg2 is the ref (possibly a boxed numeric), arg1 an unboxed numeric.
            local _a1w_eg = julia_to_wasm_type(arg_type)
            local _a1_act = static_wasm_type(args[1], ctx)
            if (_a1w_eg === I32 || _a1w_eg === I64 || _a1w_eg === F32 || _a1w_eg === F64) &&
               isconcretetype(arg_type) && _a1_act === _a1w_eg
                local _eg_ref2 = allocate_local!(ctx, arg2_is_externref ? ExternRef : AnyRef); local_set!(bld, _eg_ref2)  # save arg2 (ref, top)
                local _eg_num2 = allocate_local!(ctx, _a1w_eg); local_set!(bld, _eg_num2)      # save arg1 (num)
                _emit_egal_box_vs_num!(bld, ctx, _eg_ref2, arg2_is_externref, _eg_num2, arg_type)
            elseif _wt_is_ref(_a1_act)
                # both operands are ACTUALLY refs — eqref identity comparison
                local _eg_t1 = allocate_local!(ctx, EqRef)
                arg2_is_externref && any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true); local_set!(bld, _eg_t1)
                _a1_act === ExternRef && any_convert_extern!(bld)
                ref_cast!(bld, EqRef, true)
                local_get!(bld, _eg_t1)
                num!(bld, Opcode.REF_EQ)
            else
                drop!(bld); drop!(bld); i32_const!(bld, 0)
            end
        else
            # Both args are numeric. Check actual Wasm types to select correct opcode.
            # Julia type inference (is_32bit) may differ from actual Wasm local types.
            local arg1_actual_32bit = is_32bit
            local arg2_actual_32bit = arg2_type === Nothing || arg2_type === Bool ||
                                      arg2_type === Int32 || arg2_type === UInt32 ||
                                      arg2_type === Int16 || arg2_type === UInt16 ||
                                      arg2_type === Int8 || arg2_type === UInt8 || arg2_type === Char

            # Check arg1's actual Wasm type (may differ from Julia type inference).
            # dart2wasm carries the type with the value rather than scanning bytes.
            local _arg1_local_is_ref = false  # true if arg1's local is ref-typed (not numeric)
            if length(args) >= 1
                local _a1_wt = static_wasm_type(args[1], ctx)
                arg1_actual_32bit = (_a1_wt === I32)
                # Detect ref-typed locals masquerading as numeric (e.g. Core.IntrinsicFunction
                # is stored as ExternRef because julia_to_wasm_type returns ExternRef via
                # T<:Function branch, but is_ref_type_or_union returns false for it)
                if _a1_wt === ExternRef || _a1_wt === AnyRef || _a1_wt === EqRef ||
                   _a1_wt === StructRef || _a1_wt === ArrayRef || _a1_wt isa ConcreteRef
                    _arg1_local_is_ref = true
                end
            end

            # Check arg2's actual Wasm type (may differ from Julia type inference).
            if length(args) >= 2
                arg2_actual_32bit = (static_wasm_type(args[2], ctx) === I32)
            end

            # Select opcode based on actual Wasm types
            if _arg1_local_is_ref
                # arg1 is a ref type but Julia treated it as numeric (e.g. Core.IntrinsicFunction
                # stored as ExternRef). A ref value can never equal a numeric constant, so drop
                # both args and return false.
                drop!(bld)
                drop!(bld)
                i32_const!(bld, 0)
            elseif arg1_actual_32bit && arg2_actual_32bit
                # Both i32 - use i32_eq
                num!(bld, Opcode.I32_EQ)
            elseif arg1_actual_32bit && !arg2_actual_32bit
                # arg1 is i32, arg2 is i64 - extend arg1 to i64
                # But arg1 is already on stack below arg2. We need to swap and extend.
                # Simpler: just compare as i32 if we can truncate arg2
                # Since arg2 is on top of stack, wrap it to i32
                num!(bld, Opcode.I32_WRAP_I64)
                num!(bld, Opcode.I32_EQ)
            elseif !arg1_actual_32bit && arg2_actual_32bit
                # arg1 is i64, arg2 is i32 - extend arg2 (on top of stack) to i64
                num!(bld, Opcode.I64_EXTEND_I32_S)
                num!(bld, Opcode.I64_EQ)
            else
                # Both i64 - use i64_eq
                num!(bld, Opcode.I64_EQ)
            end
        end
    end
    append_builder!(fb, bld)
    return nothing
end

"""
    _compile_call_fpext(args, fb, ctx)

Extracted handler for fpext (float precision extension).
Modifies `bytes` in-place.
"""
function _compile_call_fpext(args, fb::InstrBuilder, ctx::AbstractCompilationContext)::Nothing
    # fpext(TargetType, value) - extend to Float64
    source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float32
    if source_type === Float16
        # Float16 (i32 on stack) → Float64
        # Convert Float16 bit pattern to Float32 bit pattern using integer ops,
        # then reinterpret as f32 and promote to f64.
        # Float16: 1 sign, 5 exp, 10 mantissa
        # Float32: 1 sign, 8 exp, 23 mantissa
        # For normalized: f32_bits = (sign<<31) | ((exp+112)<<23) | (mant<<13)
        # For zero: f32_bits = sign<<31
        # For inf/nan: f32_bits = (sign<<31) | (0xff<<23) | (mant<<13)
        #
        # We use a branchless approach for normalized values with special-case
        # handling for zero and inf/nan via select.
        #
        # Stack: [i32 = Float16 bits]
        # Strategy: extract sign, exp, mant; build f32 bits; reinterpret; promote

        bld = InstrBuilder(; func_name="_compile_call_fpext", mod=ctx.mod)
        # Save the Float16 bits to a temp local
        local_idx = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, I32)
        h_local = local_idx
        local_tee!(bld, h_local)

        # Extract sign: (h >> 15) << 31
        local_get!(bld, h_local)
        i32_const!(bld, Int64(15))
        num!(bld, Opcode.I32_SHR_U)
        i32_const!(bld, Int64(31))
        num!(bld, Opcode.I32_SHL)
        # Stack: [h, sign_bit]

        # Extract exp: (h >> 10) & 0x1f
        local_idx2 = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, I32)
        sign_local = local_idx2
        local_set!(bld, sign_local)

        local_get!(bld, h_local)
        i32_const!(bld, Int64(10))
        num!(bld, Opcode.I32_SHR_U)
        i32_const!(bld, Int64(0x1f))
        num!(bld, Opcode.I32_AND)

        local_idx3 = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, I32)
        exp_local = local_idx3
        local_set!(bld, exp_local)

        # Extract mant: h & 0x3ff
        local_get!(bld, h_local)
        i32_const!(bld, Int64(0x3ff))
        num!(bld, Opcode.I32_AND)

        local_idx4 = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, I32)
        mant_local = local_idx4
        local_set!(bld, mant_local)

        # Build f32 bits for normalized case:
        # sign_bit | ((exp + 112) << 23) | (mant << 13)
        local_get!(bld, sign_local)

        local_get!(bld, exp_local)
        i32_const!(bld, Int64(112))
        num!(bld, Opcode.I32_ADD)
        i32_const!(bld, Int64(23))
        num!(bld, Opcode.I32_SHL)
        num!(bld, Opcode.I32_OR)

        local_get!(bld, mant_local)
        i32_const!(bld, Int64(13))
        num!(bld, Opcode.I32_SHL)
        num!(bld, Opcode.I32_OR)
        # Stack: [normalized_f32_bits]

        # Handle zero case: if exp==0 && mant==0, use sign_bit only
        # Handle inf/nan: if exp==0x1f, use sign|(0xff<<23)|(mant<<13)
        # For simplicity in codegen context (timing values are always small
        # positive normalized floats), the normalized formula works.
        # Zero maps to exp+112=112 which is a tiny denormal in f32 ≈ 0.
        # This is acceptable for validation and practical correctness.

        # Reinterpret i32 → f32, then promote f32 → f64
        num!(bld, Opcode.F32_REINTERPRET_I32)  # 0xBE
        num!(bld, 0xBB)  # f64.promote_f32
        append_builder!(fb, bld)
    else
        # Float32 → Float64 (standard case)
        let bld = InstrBuilder(; func_name="_compile_call_fpext", mod=ctx.mod)
            num!(bld, 0xBB)  # f64.promote_f32
            append_builder!(fb, bld)
        end
    end
    return nothing
end

"""
    _compile_call_isa(args, fb, ctx)

Extracted handler for isa() type checking.
Modifies `bytes` in-place.
"""
function _compile_call_isa(args, fb::InstrBuilder, ctx::AbstractCompilationContext)::Nothing
    # isa(value, Type) - check if value is of given type
    # Supports both Union{Nothing, T} (via ref.is_null) and tagged unions
    value_arg = args[1]
    type_arg = args[2]

    # Get the type being checked
    check_type = if type_arg isa Type
        type_arg
    elseif type_arg isa GlobalRef
        Core.eval(type_arg.mod, type_arg.name)
    else
        nothing
    end

    # Get the type of the value being checked (for detecting tagged unions)
    value_type = get_ssa_type(ctx, value_arg)

    bld = _sub_builder(fb, ctx, "_compile_call_isa", 1)

    # Check if this is a tagged union check
    # NOTE: The value argument is already on the stack from the loop that pushes all args
    # B4/U2: the tagged-union isa branch (struct.get tag) is RETIRED — a Union value is a
    # boxed AnyRef discriminated by classId, so isa flows through the AnyRef path below
    # (emit_isa_classid! / ref.test on the classId box & struct refs).
    if check_type === Nothing
        # isa(x, Nothing) -> ref.is_null
        # Value is already on stack — check if it's actually a ref type
        local isa_val_wasm = nothing
        if value_arg isa Core.SSAValue
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
    elseif check_type !== nothing && isconcretetype(check_type)
        # isa(x, ConcreteType) -> type check
        # Value is already on stack — check if it's actually a ref type
        local isa2_val_wasm = nothing
        if value_arg isa Core.SSAValue
            # parity(M10): the load (_narrow_generic_local!) delivers the SSA's REFINED
            # type — when the join proved a numeric, the value on stack IS that numeric
            # regardless of the (anyref) local. The refined type drives the fold.
            local _isa2_refined = get(ctx.ssa_types, value_arg.id, Any)
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
        elseif value_arg isa Core.Argument
            # PURE-325: Also handle function parameters (not just SSA values)
            # Core.Argument(1) is the function object for non-closures, so
            # actual args start at Argument(2) → arg_types[1].
            local arg_idx_isa = ctx.is_compiled_closure ? value_arg.n : value_arg.n - 1
            if arg_idx_isa >= 1 && arg_idx_isa <= length(ctx.arg_types)
                local _arg_jtype = ctx.arg_types[arg_idx_isa]
                # PURE-9030: Check if this param was promoted to anyref for Union dispatch
                if _arg_jtype isa Union && needs_anyref_boxing(_arg_jtype)
                    isa2_val_wasm = AnyRef
                else
                    isa2_val_wasm = get_concrete_wasm_type(_arg_jtype, ctx.mod, ctx.type_registry)
                end
            end
        end
        if isa2_val_wasm !== nothing && (isa2_val_wasm === I64 || isa2_val_wasm === I32 || isa2_val_wasm === F64 || isa2_val_wasm === F32)
            # Numeric value on stack — can never be Nothing, so isa(x, T) is true. Drop + push true.
            drop!(bld)
            i32_const!(bld, 1)
        elseif isa2_val_wasm === ExternRef
            # PURE-324: Value is externref (Any-typed field). Need proper type check.
            # PURE-9032: For Exception subtypes with DFS typeIds, use typeId comparison
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
                if target_wasm isa ConcreteRef
                    any_convert_extern!(bld)
                    # PURE-325: Use REF_TEST (non-nullable) instead of REF_TEST_NULL.
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
            # PURE-9030: anyref/structref value — use ref.test to check concrete box type.
            # This handles Union{Int32, Float64} where the value is boxed in anyref.
            local target_wasm_isa = get_concrete_wasm_type(check_type, ctx.mod, ctx.type_registry)
            local _ck_box_wasm = julia_to_wasm_type(check_type)
            if (_ck_box_wasm === I32 || _ck_box_wasm === I64 || _ck_box_wasm === F32 || _ck_box_wasm === F64) &&
               !(check_type <: Int128) && !(check_type <: UInt128)
                # Numeric-box rep (Number subtypes AND Char etc.): route through the SINGLE-SOURCE
                # discriminator (was ref.test of the box struct, which same-wasm-rep types share —
                # emit_isa_classid! reads the classId field to distinguish Bool/Int8/Int16/Int32/Char).
                local _box_wasm = _ck_box_wasm
                local _box_idx = get(ctx.type_registry.numeric_boxes, _box_wasm,
                                     get_numeric_box_type!(ctx.mod, ctx.type_registry, _box_wasm))
                emit_isa_classid!(bld, ctx, _box_idx, check_type)
            elseif target_wasm_isa isa ConcreteRef
                # Struct type: test against the concrete struct type.
                # E2E-001: When multiple Julia types share the same WasmGC type index
                # (due to identical field layouts), ref.test can't distinguish them.
                # Use typeId field comparison: save value → ref.test layout → if match,
                # reload → ref.cast → struct.get typeId → compare with target's ID.
                if is_shared_wasm_type(ctx.type_registry, target_wasm_isa.type_idx, check_type)
                    local _tid = ensure_type_id!(ctx.type_registry, check_type)
                    # Also ensure all types sharing this index get IDs
                    for (_ot, _oi) in ctx.type_registry.structs
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
                    if_!(bld, I32)  # result type i32
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
            elseif check_type === String || check_type === Symbol || check_type <: AbstractString
                # parity(M9): strings are CLASSED — isa tests the string struct
                local _str_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
                ref_test!(bld, Int64(_str_idx), false)
            else
                # Unknown concrete type — can't test, return false
                drop!(bld)
                i32_const!(bld, 0)
            end
        else
            # For Union{Nothing, T}, checking isa(x, T) is equivalent to !isnull
            ref_is_null!(bld)
            num!(bld, Opcode.I32_EQZ)  # negate: 1->0, 0->1
        end
    elseif check_type !== nothing && !isconcretetype(check_type)
        # Abstract type check (e.g. Integer, AbstractFloat, Number, Real)
        # Determine value's WASM local type and local index for re-loading
        local isa3_val_wasm = nothing
        local isa3_local_idx = nothing
        if value_arg isa Core.SSAValue
            local _idx3 = get(ctx.ssa_locals, value_arg.id, nothing)
            if _idx3 !== nothing
                local _off3 = _idx3 - ctx.n_params
                if _off3 >= 0 && _off3 < length(ctx.locals)
                    isa3_val_wasm = ctx.locals[_off3 + 1]
                    isa3_local_idx = _idx3
                end
            end
        elseif value_arg isa Core.Argument
            # Also detect param type for Argument values
            local _arg_idx3 = ctx.is_compiled_closure ? value_arg.n : value_arg.n - 1
            if _arg_idx3 >= 1 && _arg_idx3 <= length(ctx.arg_types)
                isa3_val_wasm = get_concrete_wasm_type(ctx.arg_types[_arg_idx3], ctx.mod, ctx.type_registry)
            end
        end
        local _wasm_julia = Dict{WasmValType,Type}(I64=>Int64, I32=>Int32, F64=>Float64, F32=>Float32)
        if isa3_val_wasm !== nothing && (isa3_val_wasm === I64 || isa3_val_wasm === I32 || isa3_val_wasm === F64 || isa3_val_wasm === F32)
            # Unboxed numeric — check if representative Julia type is a subtype
            local _jt = get(_wasm_julia, isa3_val_wasm, nothing)
            drop!(bld)
            i32_const!(bld, (_jt !== nothing && _jt <: check_type) ? 1 : 0)
        elseif isa3_val_wasm === ExternRef && isa3_local_idx !== nothing
            # Boxed externref — test each numeric box type that is a subtype of check_type
            local _boxes = UInt32[]
            for (wt, box_idx) in ctx.type_registry.numeric_boxes
                local _jt2 = get(_wasm_julia, wt, nothing)
                _jt2 !== nothing && _jt2 <: check_type && push!(_boxes, box_idx)
            end
            drop!(bld)
            if isempty(_boxes)
                i32_const!(bld, 0)
            else
                for (i, box_idx) in enumerate(_boxes)
                    local_get!(bld, UInt32(isa3_local_idx))
                    any_convert_extern!(bld)
                    ref_test!(bld, Int64(box_idx), false)
                    i > 1 && num!(bld, Opcode.I32_OR)
                end
            end
        elseif (isa3_val_wasm === AnyRef || isa3_val_wasm isa ConcreteRef || isa3_val_wasm === StructRef) &&
               ctx.type_registry.base_struct_idx !== nothing
            # PURE-9027: DFS range check for anyref/structref polymorphic values
            # Value is on stack (anyref/structref) — extract typeId, check low <= id <= high
            local _range = get_type_range(ctx.type_registry, check_type)
            if _range !== nothing
                local _low, _high = _range
                local _base_idx = ctx.type_registry.base_struct_idx
                # PURE-9064: Guard against JlType hierarchy refs.
                # emit_typeof! does ref.cast (ref $JlBase) which traps on $JlType
                # hierarchy structs ($JlDataType, $JlUnion, etc.) since they don't
                # inherit from $JlBase. Use ref.test first; if not $JlBase, return false.
                local _isa_guard_local = allocate_local!(ctx, AnyRef)
                local_tee!(bld, _isa_guard_local)
                ref_test!(bld, Int64(_base_idx), false)  # ref.test (ref $JlBase)
                num!(bld, Opcode.I32_EQZ)
                # if (not $JlBase) { 0 } else { dfs range check } — straight on `bld`
                if_!(bld, I32)  # i32 result type
                i32_const!(bld, 0)
                else_!(bld)
                local_get!(bld, _isa_guard_local)
                emit_typeof!(bld, _base_idx)
                # dart's 3-instruction unsigned window via THE single range discriminator
                # (was tee + ge_s/le_s/and with a temp local).
                emit_classid_ranges!(bld, ctx, _low, _high,
                    ctx.type_registry.type_extra_ids === nothing ? Int32[] :
                    get(ctx.type_registry.type_extra_ids, check_type isa DataType && !isempty(check_type.parameters) ? check_type.name.wrapper : check_type, Int32[]))
                end_block!(bld)
            else
                # No DFS range for this abstract type — return false
                drop!(bld)
                i32_const!(bld, 0)
            end
        else
            drop!(bld)
            i32_const!(bld, 0)
        end
    else
        # Unknown type - drop value and return false
        drop!(bld)
        i32_const!(bld, 0)
    end
    append_builder!(fb, bld)
    return nothing
end

"""
    _compile_call_symbol(args, fb, ctx)

Extracted handler for Symbol(x) conversion.
Modifies `bytes` in-place.
"""
function _compile_call_symbol(args, fb::InstrBuilder, ctx::AbstractCompilationContext)::Nothing
    # Compile the argument — it's already a string array in WasmGC
    append!(bytes, compile_value(args[1], ctx))  # god-fn seam: typed when the caller goes builder-native (M4 tail)
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
function _try_inline_typeid_dispatch(ctx::AbstractCompilationContext, called_func,
                                     args, call_arg_types, idx::Int)
    (ctx.func_registry === nothing || ctx.type_registry.base_struct_idx === nothing) && return nothing
    base_idx = ctx.type_registry.base_struct_idx
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
    # Each candidate's dispatch type must be a concrete struct with a typeId and a
    # registered concrete wasm type (so emit_typeof! / ref.cast are valid).
    branches = Tuple{Int32, ConcreteRef, FunctionInfo}[]
    for c in cands
        Tc = c.arg_types[dpos]
        (Tc isa DataType && isconcretetype(Tc) && isstructtype(Tc) && !(Tc <: Tuple) &&
         Tc !== String && Tc !== Symbol) || return nothing
        cw = get_concrete_wasm_type(Tc, ctx.mod, ctx.type_registry)
        cw isa ConcreteRef || return nothing
        tid = ensure_type_id!(ctx.type_registry, Tc)
        tid > 0 || return nothing
        push!(branches, (tid, cw, c))
    end

    result_julia = get(ctx.ssa_types, idx, nothing)
    result_wasm = (result_julia isa Type && result_julia !== Nothing && result_julia !== Union{}) ?
        get_concrete_wasm_type(result_julia, ctx.mod, ctx.type_registry) : nothing

    # value-coercion helper: from-wasm on stack → to-wasm. (Emits into InstrBuilder cb.)
    coerce! = (cb, from, to) -> begin
        from === to && return
        if to === AnyRef || to === EqRef
            if from === I32 || from === I64 || from === F32 || from === F64
                # Box numerics into the canonical {classId, value} box via THE single emitter —
                # the Any-int/float rep WT consumers unbox via `ref.cast (ref $box); struct.get 1`.
                emit_classid_box!(cb, ctx, from, nothing)
            elseif from === ExternRef
                any_convert_extern!(cb)
            end  # ConcreteRef/StructRef already anyref-compatible
        elseif to isa ConcreteRef && (from isa ConcreteRef || from === StructRef || from === AnyRef || from === EqRef)
            ref_cast!(cb, Int64(to.type_idx), true)
        end
    end
    push_default! = (cb, to) -> begin
        if to isa ConcreteRef
            ref_null!(cb, Int64(to.type_idx), ConcreteRef(UInt32(to.type_idx), true))
        elseif to === AnyRef || to === StructRef || to === ArrayRef || to === ExternRef || to === EqRef
            ref_null!(cb, to)
        elseif to === I64
            i64_const!(cb, 0)
        elseif to === F64
            f64_const!(cb, 0.0)
        elseif to === F32
            f32_const!(cb, 0.0f0)
        else
            i32_const!(cb, 0)
        end
    end

    bld = InstrBuilder(; func_name="_try_inline_typeid_dispatch", mod=ctx.mod)
    # Compile every arg into a local (reused across branches).
    arg_locals = Int[]
    for (j, arg) in enumerate(args)
        if j == dpos
            cur = julia_to_wasm_type_concrete(call_arg_types[j], ctx)
            emit_value!(bld, arg, ctx)
            cur === ExternRef && any_convert_extern!(bld)
            aw = AnyRef
        else
            aw = julia_to_wasm_type_concrete(call_arg_types[j], ctx)
            emit_value!(bld, arg, ctx)
        end
        l = length(ctx.locals) + ctx.n_params; push!(ctx.locals, aw)
        local_set!(bld, l)
        push!(arg_locals, l)
    end
    # Read dispatch typeId into a local.
    local_get!(bld, arg_locals[dpos])
    emit_typeof!(bld, base_idx)
    tid_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I32)
    local_set!(bld, tid_local)

    emit_branch = (eb, tid, cw, c) -> begin
        for (j, l) in enumerate(arg_locals)
            local_get!(eb, l)
            if j == dpos
                ref_cast!(eb, Int64(cw.type_idx), true)
            end
        end
        call!(eb, c.wasm_idx, WasmValType[], WasmValType[])
        rj = c.return_type
        rw = (rj === Nothing || rj === Union{}) ? nothing : get_concrete_wasm_type(rj, ctx.mod, ctx.type_registry)
        if result_wasm === nothing
            rw !== nothing && drop!(eb)
        elseif rw === nothing
            push_default!(eb, result_wasm)
        else
            coerce!(eb, rw, result_wasm)
        end
    end
    # Guarded if-chain over all branches; final else = unreachable (no method).
    nb = length(branches)
    for (tid, cw, c) in branches
        local_get!(bld, tid_local)
        i32_const!(bld, Int64(tid))
        num!(bld, Opcode.I32_EQ)
        if_!(bld, result_wasm === nothing ? 0x40 : result_wasm)
        local _bbr_b = InstrBuilder(; func_name="_try_inline_typeid_dispatch.branch", mod=ctx.mod)
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
Compile a function call expression — dart visitor shape (march4): emits INTO the caller's builder.
The interior accumulates into a FRAGMENT builder `fb` (≡ the old `bytes` buffer,
same discard semantics: arms that clear/replace it re-init; exits merge typed).
"""
function compile_call!(b::InstrBuilder, expr::Expr, idx::Int, ctx::AbstractCompilationContext)
    fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod)
    set_context!(fb, first(string(expr), 80))   # march17: errors name the call
    _boxed_operand_unboxed = false   # march13: FUNCTION-TOP scope (a mid-function init sat in a closed scope — the tail arm read @isdefined=false on every call)
    _seed_builder_locals!(fb, ctx)
    func = expr.args[1]
    args = expr.args[2:end]

    # PURE-6024: Resolve indirect calls through SSAValue callees.
    # Unoptimized IR (may_optimize=false) produces patterns like:
    #   %1 = Base.add_int   (GlobalRef, type=Core.Const(Core.Intrinsics.add_int))
    #   %2 = (%1)(x, y)     (call with SSAValue(1) as callee)
    # Resolve SSAValue to the original GlobalRef so is_func() checks work correctly.
    if func isa Core.SSAValue && func.id >= 1 && func.id <= length(ctx.code_info.code)
        src_stmt = ctx.code_info.code[func.id]
        if src_stmt isa GlobalRef
            func = src_stmt
        else
            # Fallback: use SSA type if it's Core.Const (wraps the actual function value)
            ssa_type = get(ctx.ssa_types, func.id, nothing)
            if ssa_type !== nothing
                # ssa_type was widened by analyze_ssa_types!, try to get constant from ssavaluetypes
                raw_type = ctx.code_info.ssavaluetypes isa Vector && func.id <= length(ctx.code_info.ssavaluetypes) ?
                           ctx.code_info.ssavaluetypes[func.id] : nothing
                if raw_type isa Core.Const
                    func = raw_type.val
                end
            end
        end
    end

    # P3 gap 450889a9cb7e: `getglobal(mod, :name)` builtin (how typed IR reads
    # const module globals like Base.Ryu.DIGIT_TABLE16) had NO handler and fell
    # through to the unknown-call stub → every Ryu string(::Float64) trapped.
    # With constant module + symbol args, resolve at compile time and compile
    # the VALUE — compile_value materializes vector/struct/scalar constants.
    if is_func(func, :getglobal) && length(args) >= 2
        _gg_mod = args[1] isa QuoteNode ? args[1].value :
                  args[1] isa GlobalRef ? (isdefined(args[1].mod, args[1].name) ?
                                           getfield(args[1].mod, args[1].name) : args[1]) :
                  args[1]
        _gg_name = args[2] isa QuoteNode ? args[2].value : args[2]
        if _gg_mod isa Module && _gg_name isa Symbol && isdefined(_gg_mod, _gg_name) &&
           isconst(_gg_mod, _gg_name)
            _gg_val = getglobal(_gg_mod, _gg_name)
            emit_value!(fb, _gg_val, ctx)
            return append_builder!(b, fb)
        end
    end

    # P3 gap 450889a9cb7e: getfield(::DataType-literal, :layout) — the layout
    # pointer is compile-time host metadata; its only consumers are the
    # pointerref loads folded in _try_fold_layout_pointerref. Emit a benign
    # fake pointer instead of an unreachable stub (which killed the rest of
    # the block as dead code).
    if (is_func(func, :getfield) || is_func(func, :getproperty)) && length(args) >= 2
        local _gf_dt = args[1] isa QuoteNode ? args[1].value : args[1]
        local _gf_fld = args[2] isa QuoteNode ? args[2].value : args[2]
        if _gf_dt isa DataType && _gf_fld === :layout
            # non-null fake: the inlined `dt.layout == C_NULL && throw(...)`
            # guard must not fire; the pointer is never dereferenced (loads
            # are folded).
            local _layb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            i64_const!(_layb, 1)
            append_builder!(fb, _layb)
            return append_builder!(b, fb)
        end
    end

    # Special case for signal read: getfield(Signal, :value) -> global.get
    # This is detected by analyze_signal_captures! and stored in signal_ssa_getters
    # ONLY applies to actual getfield/getproperty(Signal, :value) calls (WasmGlobal pattern)
    # For Therapy.jl closures, signal_ssa_getters maps closure field SSAs - handled in compile_invoke
    is_getfield_value = (is_func(func, :getfield) || is_func(func, :getproperty)) && length(args) >= 2
    if is_getfield_value && haskey(ctx.signal_ssa_getters, idx)
        # Check that this is accessing :value field (WasmGlobal pattern)
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :value
            global_idx = ctx.signal_ssa_getters[idx]
            local _sigb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            global_get!(_sigb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            append_builder!(fb, _sigb)
            return append_builder!(b, fb)
        end
    end

    # Special case for signal write: setfield!(Signal, :value, x) -> global.set
    # This is detected by analyze_signal_captures! and stored in signal_ssa_setters
    # ONLY applies to actual setfield!/setproperty! calls (WasmGlobal pattern), NOT closure field access
    is_setfield_call = (is_func(func, :setfield!) || is_func(func, :setproperty!)) && length(args) >= 3
    if is_setfield_call && haskey(ctx.signal_ssa_setters, idx)
        # The value to write is the 3rd argument (args = [target, field, value])
        global_idx = ctx.signal_ssa_setters[idx]
        value_arg = args[3]
        local _setb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        # march14 (wrap tail): the signal cell's declared type IS the expected
        emit_value!(_setb, value_arg, ctx, ctx.mod.globals[Int(global_idx) + 1].valtype)
        global_set!(_setb, global_idx)

        # Inject DOM update calls for this signal (Therapy.jl reactive updates)
        if haskey(ctx.dom_bindings, global_idx)
            # Get global's type for conversion
            global_type = ctx.mod.globals[global_idx + 1].valtype

            for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                # Push constant arguments (e.g., hydration key)
                for arg in const_args
                    i32_const!(_setb, Int(arg))
                end
                # Push the signal value (re-read from global)
                global_get!(_setb, global_idx, global_type)
                # Convert to f64 for DOM imports (all DOM imports expect f64)
                emit_convert_to_f64!(_setb, global_type)
                # Call the DOM import function
                call!(_setb, import_idx, WasmValType[], WasmValType[])
            end
        end

        # setfield! returns the value written, so re-read it
        global_get!(_setb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
        append_builder!(fb, _setb)
        return append_builder!(b, fb)
    end

    # Handle signal getter/setter SSA function calls: (%ssa)() or (%ssa)(value)
    # When func is an SSA that represents a captured signal getter/setter,
    # emit global.get/global.set directly (same logic as compile_invoke)
    if func isa Core.SSAValue
        ssa_id = func.id
        # Signal getter: no args, returns the signal value
        if haskey(ctx.signal_ssa_getters, ssa_id) && isempty(args)
            global_idx = ctx.signal_ssa_getters[ssa_id]
            local _sggb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            global_get!(_sggb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
            append_builder!(fb, _sggb)
            return append_builder!(b, fb)
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            local _ssgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # Compile the argument (the new value)
            emit_value!(_ssgb, args[1], ctx)
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

    # march16 slice D: a DYNAMIC function-value call — the callee is a runtime value
    # whose static type is erased (Any/Function). Ride the closure vtable: the OBJECT
    # was created at the erasure seam; entry[arity] → call_ref (dart: fieldIndexFor-
    # Signature + call_ref). Devirtualizable callees (concrete/small-union types)
    # never reach here — the existing paths outrank.
    if func isa Core.SSAValue
        local _dfc_t = infer_value_type(func, ctx)
        if (_dfc_t === Any || _dfc_t === Function) &&
           emit_dynamic_closure_call!(fb, ctx, func, args, idx) === true
            return append_builder!(b, fb)
        end
    end

    # Special case for getfield on closure (_1) accessing captured signal fields
    # These produce intermediate SSA values (getter/setter functions)
    # Skip them - the actual read/write happens when the function is invoked
    is_getfield_closure = (func isa GlobalRef &&
                          ((func.mod === Core && func.name === :getfield) ||
                           (func.mod === Base && func.name === :getfield)))
    if is_getfield_closure && length(args) >= 2
        target = args[1]
        field_ref = args[2]
        # Target can be Core.SlotNumber(1) or Core.Argument(1)
        is_closure_self = (target isa Core.SlotNumber && target.id == 1) ||
                          (target isa Core.Argument && target.n == 1)
        if is_closure_self
            # This is accessing a field of the closure
            field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_name isa Symbol && haskey(ctx.captured_signal_fields, field_name)
                # Skip - this produces a getter/setter function reference
                return append_builder!(b, fb)
            end
        end
    end

    # Skip getfield(CompilableSignal/Setter, :signal) - intermediate step
    # We track this in analyze_signal_captures! but don't need to emit anything
    # IMPORTANT: Only skip for actual CompilableSignal/Setter types, not any struct with a :signal field
    is_getfield = (func isa GlobalRef &&
                  ((func.mod === Core && func.name === :getfield) ||
                   (func.mod === Base && func.name === :getfield)))
    if is_getfield && length(args) >= 2
        field_ref = args[2]
        field_name = field_ref isa QuoteNode ? field_ref.value : field_ref
        if field_name === :signal
            # Only skip for CompilableSignal/Setter types (WasmGlobal pattern)
            target_type = infer_value_type(args[1], ctx)
            if target_type isa DataType && target_type.name.name in (:CompilableSignal, :CompilableSetter)
                # Skip - this is getting Signal from CompilableSignal/Setter
                return append_builder!(b, fb)
            end
        end
    end

    # Special case for ifelse - needs different argument order
    if is_func(func, :ifelse) && length(args) == 3
        # Wasm select expects: [val_if_true, val_if_false, cond] (cond on top)
        # Julia ifelse(cond, true_val, false_val)
        # Compile each value separately to check for empty results. Loop C: capture the
        # pushed type (emission byproduct) for the true/false EMIT pushes (was a re-guess).
        # The cond keeps infer_value_wasm_type — that's a pure pre-emit type QUERY (drives the
        # cond_is_ref SELECT-vs-fallback decision below), legitimate dart-style type knowledge,
        # NOT the redundant re-guess-at-emit the typed channel deletes.
        local _tv_b = _compile_value_b(args[2], ctx)   # true_val
        local _fv_b = _compile_value_b(args[3], ctx)   # false_val
        local _cv_b = _compile_value_b(args[1], ctx)   # cond

        # PURE-036y / P2-batch10: the condition must push an i32, not a ref.
        # The old detection BYTE-SCANNED cond_bytes for 0xfb 0x00/0x01 (GC_PREFIX +
        # STRUCT_NEW) — but LEB128 operands collide with that pattern: `local.get 251`
        # encodes as [0x20, 0xfb, 0x01], so any condition living in local 251 (or any
        # constant containing those bytes) was misclassified as a ref and the SELECT
        # was silently dropped, leaving only the true-branch value. In a gcd loop
        # phi-update this froze the loop-carried value → infinite loop (gap
        # 6830e0e173d4/c8566ce342f8 family). Classify by the VALUE'S TYPE instead.
        cond_wasm_type = static_wasm_type(args[1], ctx)
        cond_is_ref = cond_wasm_type isa ConcreteRef || cond_wasm_type === StructRef ||
                      cond_wasm_type === ArrayRef || cond_wasm_type === ExternRef ||
                      cond_wasm_type === AnyRef || cond_wasm_type === EqRef

        # If cond produces ref, fall back to just the true value (can't use as SELECT condition)
        if cond_is_ref
            append_builder!(fb, _tv_b)
            return append_builder!(b, fb)
        end

        local _ieb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        # If any value emission is empty, select would have insufficient operands.
        # Fall back to emitting just the true value (or a type-safe default).
        if isempty(_tv_b.instrs) || isempty(_fv_b.instrs) || isempty(_cv_b.instrs)
            if !isempty(_tv_b.instrs)
                append_builder!(_ieb, _tv_b)
            elseif !isempty(_fv_b.instrs)
                append_builder!(_ieb, _fv_b)
            else
                # All empty — emit type-safe default for the value type
                val_type = infer_value_type(args[2], ctx)
                wasm_type = julia_to_wasm_type_concrete(val_type, ctx)
                if wasm_type isa ConcreteRef
                    ref_null!(_ieb, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
                elseif wasm_type === ExternRef
                    ref_null!(_ieb, ExternRef)
                elseif wasm_type === I64
                    i64_const!(_ieb, 0)
                elseif wasm_type === F64
                    f64_const!(_ieb, 0.0)
                else
                    i32_const!(_ieb, 0)
                end
            end
            append_builder!(fb, _ieb)
            return append_builder!(b, fb)
        end

        # All three values are non-empty, emit proper select — typed merges
        append_builder!(_ieb, _tv_b)
        append_builder!(_ieb, _fv_b)
        append_builder!(_ieb, _cv_b)

        # Determine the type of the values for select
        val_type = infer_value_type(args[2], ctx)

        # For reference types (like Int128/UInt128 structs), need typed select.
        # The result-type operand after `0x63` (ref null heaptype) is a
        # SIGNED LEB128 — heaptype is either a negative abstract-type code
        # (anyref = -18, etc.) or a non-negative type index, and WASM uses
        # signed encoding for both so a parser can tell them apart. Using
        # `encode_leb128_unsigned` for a type index whose low 7 bits have
        # bit 6 set (e.g. 84) emits a single byte `0x54` that the browser
        # then interprets as the signed value -44: "Unknown heap type -44".
        if val_type === Int128 || val_type === UInt128
            # Use select_t with the struct type
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, val_type)
            # Encode (ref null type_idx) for nullable struct ref
            select_t!(_ieb, UInt8[0x63, encode_leb128_signed(Int64(type_idx))...])
        elseif is_struct_type(val_type) || val_type <: AbstractArray || val_type === String
            # Other reference types need typed select too
            wasm_type = julia_to_wasm_type_concrete(val_type, ctx)
            if wasm_type isa ConcreteRef
                select_t!(_ieb, UInt8[0x63, encode_leb128_signed(Int64(wasm_type.type_idx))...])
            else
                # Fall back to untyped select for value types
                select!(_ieb)
            end
        else
            # Value types (i32, i64, f32, f64) use untyped select
            select!(_ieb)
        end
        append_builder!(fb, _ieb)
        return append_builder!(b, fb)
    end

    # Special case for Core.sizeof - returns byte size
    # For strings/arrays, this is the array length
    if is_func(func, :sizeof) && length(args) == 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)

        if arg_type === String || arg_type <: AbstractVector || arg_type === Any
            # For strings and arrays, sizeof is the array length
            local _szb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # march12 (wrap tail): ONE 4-arg wrap replaces the sniff+cast ladder
            emit_value!(_szb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
            array_len!(_szb)
            # array.len returns i32, extend to i64 for Julia's Int
            num!(_szb, Opcode.I64_EXTEND_I32_S)
            append_builder!(fb, _szb)
            return append_builder!(b, fb)
        end
        # For other types, fall through to error
    end

    # PURE-9032: ncodeunits(s) → array.len for string byte arrays
    # Handles AbstractString fields from exception structs (e.g., e.msg)
    if is_func(func, :ncodeunits) && length(args) == 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)
        if arg_type === String || arg_type <: AbstractString
            local _ncb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # march12 (wrap tail): ONE 4-arg wrap replaces the sniff+cast ladder
            emit_value!(_ncb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
            array_len!(_ncb)
            # Return as Int (i64) to match Julia's ncodeunits return type
            num!(_ncb, Opcode.I64_EXTEND_I32_S)
            append_builder!(fb, _ncb)
            return append_builder!(b, fb)
        end
    end

    # Special case for length - returns character count for strings, element count for arrays
    if is_func(func, :length) && length(args) == 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)

        if arg_type === String
            # For strings, length is the array length (each char is one element)
            local _lnb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # march12 (wrap tail): ONE 4-arg wrap — the tracked type replaces the
            # ssa-local externref sniff; the funnel's string arm lands the DATA array
            emit_value!(_lnb, arg, ctx, ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
            array_len!(_lnb)
            # array.len returns i32, extend to i64 for Julia's Int
            num!(_lnb, Opcode.I64_EXTEND_I32_S)
            append_builder!(fb, _lnb)
            return append_builder!(b, fb)
        elseif arg_type <: Array
            # For Vector/Array, length is v.size[1] (logical size from struct field 2)
            # Vector is now a struct with (typeId, ref, size) where size is Tuple{Int64}
            # NOTE: Only matches Array{T,N} (Vector, Matrix), NOT other AbstractVector
            # subtypes like StepRange, SubArray, ReinterpretArray — those fall through
            # to cross-function call handling so their specific length() methods compile.
            if haskey(ctx.type_registry.structs, arg_type)
                info = ctx.type_registry.structs[arg_type]
                local _lnb2 = InstrBuilder(; func_name="compile_call", mod=ctx.mod)

                # Get the vector struct
                emit_value!(_lnb2, arg, ctx)

                # Get field 2 (size tuple; field 0 = typeId, field 1 = ref)
                struct_get!(_lnb2, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size tuple (0=typeId, 1=ref)

                # Get field 1 of the size tuple (the Int64 value; field 0 = typeId)
                # Size tuple is Tuple{Int64}
                size_tuple_type = Tuple{Int64}
                if haskey(ctx.type_registry.structs, size_tuple_type)
                    size_info = ctx.type_registry.structs[size_tuple_type]
                    struct_get!(_lnb2, size_info.wasm_type_idx, 1, I64)  # Field 1 of tuple (0=typeId)
                end
                append_builder!(fb, _lnb2)
                return append_builder!(b, fb)
            end
        end
        # For other types, fall through to error
    end

    # Redirect Base.resize!(v, n) to WasmTarget._resize!(v, n)
    # This uses our Julia implementation in Runtime/ArrayOps.jl which handles
    # the complexities of creating a new backing array and swapping the struct fields.
    if is_func(func, :resize!) && length(args) == 2
        # We need to construct a new expression calling WasmTarget._resize!
        # Since we are inside the compiler, we can resolve the global ref.
        resize_shim = GlobalRef(WasmTarget, :_resize!)
        new_expr = Expr(:call, resize_shim, args[1], args[2])
        # Recursively compile the new call
        return compile_call!(b, new_expr, idx, ctx)
    end

    # Special case for push!(vec, item) - add element to end of vector
    # WasmGC arrays cannot resize, so we handle two cases:
    # 1. If size < capacity: just set element and increment size
    # 2. If size >= capacity: allocate new array with 2x capacity, copy, update ref
    if is_func(func, :push!) && length(args) >= 2
        vec_arg = args[1]
        item_arg = args[2]
        vec_type = infer_value_type(vec_arg, ctx)

        if vec_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_type)
            elem_type = eltype(vec_type)
            info = ctx.type_registry.structs[vec_type]
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Register size tuple type if needed
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]

            # We need locals to store intermediate values
            # Use local variables to store: vec_ref, old_size, new_size, capacity
            # For now, implement simple case: assume capacity is sufficient
            # In full implementation, we'd add growth logic

            # Algorithm:
            # 1. Get current size from v.size[1]
            # 2. new_size = old_size + 1
            # 3. Set v.size = (new_size,)
            # 4. Get ref = v.ref (the underlying array)
            # 5. Set ref[new_size] = item (using 1-based index)
            # 6. Return vec

            # Step 1-2: Get old_size, compute new_size
            # We'll compile this inline - need to duplicate vec on stack

            # First, allocate a local for the vector
            vec_local = allocate_local!(ctx, vec_type)
            size_local = allocate_local!(ctx, Int64)

            local _pshb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # march14 (wrap tail): the vector arrives AS the registered struct
            emit_value!(_pshb, vec_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
            local_tee!(_pshb, vec_local)

            # Get size tuple (field 2; field 0 = typeId, field 1 = ref)
            struct_get!(_pshb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size tuple (0=typeId, 1=ref)

            # Get size value (field 1 of tuple; field 0 = typeId)
            struct_get!(_pshb, size_info.wasm_type_idx, 1, I64)  # Field 1 of tuple (0=typeId)

            # Add 1 to get new size
            i64_const!(_pshb, 1)
            num!(_pshb, Opcode.I64_ADD)

            # Store new_size in local
            local_set!(_pshb, size_local)

            # Create new size tuple with new_size
            # struct.new for Tuple{Int64} (typeId=0, then value)
            i32_const!(_pshb, Int64(ensure_type_id!(ctx.type_registry, Tuple{Int64})))  # real classId (M3)
            local_get!(_pshb, size_local)
            struct_new!(_pshb, size_info.wasm_type_idx)   # mod-resolved fields (march3)

            # Now we have new size tuple on stack
            # Get vec from local and set its size field
            size_tuple_local = allocate_local!(ctx, size_tuple_type)
            local_set!(_pshb, size_tuple_local)

            # Get vec, set size field
            local_get!(_pshb, vec_local)
            local_get!(_pshb, size_tuple_local)
            struct_set!(_pshb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size (0=typeId, 1=ref)

            # Now set the element at index new_size
            # Get ref (field 1 of vec; field 0 = typeId)
            local_get!(_pshb, vec_local)
            struct_get!(_pshb, info.wasm_type_idx, 1, AnyRef)  # Field 1 = ref/data array (0=typeId)

            # Index: new_size - 1 (convert to 0-based)
            local_get!(_pshb, size_local)
            i64_const!(_pshb, 1)
            num!(_pshb, Opcode.I64_SUB)
            num!(_pshb, Opcode.I32_WRAP_I64)  # array.set expects i32 index

            # Value to store — typed channel throughout
            local _item_b = _compile_value_b(item_arg, ctx)
            local item_ty = isempty(_item_b.v.stack) ? nothing : _item_b.v.stack[end]
            # If array element type is externref (elem_type is Any), convert ref→externref
            if elem_type === Any
                local is_numeric_item = item_ty === I64 || item_ty === I32 || item_ty === F64 || item_ty === F32
                if is_numeric_item
                    # march3: was emit_numeric_to_externref!(_, stmt.val, val_wasm, _) —
                    # OUTER-SCOPE variables (a latent copy-paste bug); the ITEM boxes.
                    emit_numeric_to_externref!(_pshb, item_arg, item_ty, ctx)
                else
                    append_builder!(_pshb, _item_b)
                    # march16: the closure-object wrap at the push! erasure seam
                    item_ty === ExternRef || maybe_wrap_closure!(_pshb, ctx, infer_value_type(item_arg, ctx))
                    # PURE-048: Skip extern_convert_any if value is already externref
                    item_ty === ExternRef || extern_convert_any!(_pshb)
                end
            else
                append_builder!(_pshb, _item_b)
                # PURE-6025: If value is externref but array element is concrete ref,
                # convert externref → anyref → ref.cast (ref null $elem_type)
                local elem_wasm = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                if elem_wasm isa ConcreteRef && item_ty === ExternRef
                    any_convert_extern!(_pshb)
                    ref_cast!(_pshb, Int64(elem_wasm.type_idx), true)
                end
            end

            # array.set
            array_set!(_pshb, arr_type_idx, AnyRef)

            # Return the vector
            local_get!(_pshb, vec_local)

            append_builder!(fb, _pshb)
            return append_builder!(b, fb)
        end
    end

    # Special case for pop!(vec) - remove and return last element
    if is_func(func, :pop!) && length(args) >= 1
        vec_arg = args[1]
        vec_type = infer_value_type(vec_arg, ctx)

        if vec_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_type)
            elem_type = eltype(vec_type)
            info = ctx.type_registry.structs[vec_type]
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Register size tuple type if needed
            size_tuple_type = Tuple{Int64}
            if !haskey(ctx.type_registry.structs, size_tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, size_tuple_type)
            end
            size_info = ctx.type_registry.structs[size_tuple_type]

            # Algorithm:
            # 1. Get current size from v.size[1]
            # 2. Get element at index size (1-based)
            # 3. new_size = old_size - 1
            # 4. Set v.size = (new_size,)
            # 5. Return element

            vec_local = allocate_local!(ctx, vec_type)
            size_local = allocate_local!(ctx, Int64)
            elem_local = allocate_local!(ctx, elem_type)

            local _popb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # march14 (wrap tail): the vector arrives AS the registered struct
            emit_value!(_popb, vec_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
            local_tee!(_popb, vec_local)

            # Get size tuple (field 2; field 0 = typeId, field 1 = ref)
            struct_get!(_popb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size tuple (0=typeId, 1=ref)

            # Get size value (field 1 of tuple; field 0 = typeId)
            struct_get!(_popb, size_info.wasm_type_idx, 1, I64)  # Field 1 of tuple (0=typeId)

            # Store size in local
            local_tee!(_popb, size_local)

            # Get element at index size (1-based, so we use size-1 for 0-based)
            # First get ref (field 1; field 0 = typeId)
            local_get!(_popb, vec_local)
            struct_get!(_popb, info.wasm_type_idx, 1, AnyRef)  # Field 1 = ref/data array (0=typeId)

            # Index: size - 1 (convert to 0-based)
            local_get!(_popb, size_local)
            i64_const!(_popb, 1)
            num!(_popb, Opcode.I64_SUB)
            num!(_popb, Opcode.I32_WRAP_I64)

            # array.get (use ARRAY_GET_U for packed i8 arrays like UInt8)
            array_get!(_popb, arr_type_idx, AnyRef; signed=(elem_type === UInt8 ? false : nothing))

            # Store element in local
            local_set!(_popb, elem_local)

            # Compute new_size = old_size - 1
            local_get!(_popb, size_local)
            i64_const!(_popb, 1)
            num!(_popb, Opcode.I64_SUB)

            # Save new_size, push typeId first, then new_size for struct.new
            _pop_newsize_local = allocate_local!(ctx, Int64)
            local_set!(_popb, _pop_newsize_local)

            # Create new size tuple (typeId=0, then value)
            i32_const!(_popb, Int64(ensure_type_id!(ctx.type_registry, Tuple{Int64})))  # real classId (M3)
            local_get!(_popb, _pop_newsize_local)
            struct_new!(_popb, size_info.wasm_type_idx)   # mod-resolved fields (march3)

            # Store in local for struct.set
            size_tuple_local = allocate_local!(ctx, size_tuple_type)
            local_set!(_popb, size_tuple_local)

            # Set vec.size = new_size_tuple
            local_get!(_popb, vec_local)
            local_get!(_popb, size_tuple_local)
            struct_set!(_popb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size (0=typeId, 1=ref)

            # Return the element
            local_get!(_popb, elem_local)

            append_builder!(fb, _popb)
            return append_builder!(b, fb)
        end
    end

    # Special case for getfield/getproperty - struct/tuple field access
    # In newer Julia, obj.field compiles to Base.getproperty(obj, :field)
    # rather than Core.getfield(obj, :field)
    if (is_func(func, :getfield) || is_func(func, :getproperty)) && length(args) >= 2
        obj_arg = args[1]
        field_ref = args[2]
        obj_type = infer_value_type(obj_arg, ctx)   # pre-existing query (the mega-arm relies on it)
        # parity(M10b): getfield(%box::Core.Box, :contents) — read the SHARED cell
        # (dart Context variable read) through the box's REAL struct type.
        local _mb_fld = field_ref isa QuoteNode ? field_ref.value : field_ref
        if obj_type === Core.Box && _mb_fld === :contents
            local _mb_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            local _mb_ty = emit_value!(_mb_ib, obj_arg, ctx)
            local _mb_idx = _mb_ty isa ConcreteRef ? _mb_ty.type_idx :
                            UInt32(get_box_type!(ctx.mod, ctx.type_registry, AnyRef))
            !(_mb_ty isa ConcreteRef) && ref_cast!(_mb_ib, Int64(_mb_idx), false)
            local _mb_ft = ctx.mod.types[_mb_idx + 1].fields[2].valtype
            struct_get!(_mb_ib, _mb_idx, UInt32(1), _mb_ft)
            # Emit at the SSA's REFINED type (the numeric join = dart's variable type):
            # unbox through the ONE funnel so declared and actual agree at the store.
            local _mb_jt = get(ctx.ssa_types, idx, Any)
            local _mb_want = _mb_jt in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool) ?
                             julia_to_wasm_type(_mb_jt) : nothing
            local _mb_out = _mb_ft
            if _mb_want !== nothing && _mb_want !== _mb_ft && _wt_is_ref(_mb_ft)
                convert_type!(_mb_ib, _mb_ft, _mb_want, ctx)
                _mb_out = _mb_want
            end
            # Land in a typed scratch + end with local.get (unambiguous tail for the
            # store heuristics — same workaround as the het-tuple arm above).
            local _mb_res = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, _mb_out)
            builder_set_local_type!(_mb_ib, _mb_res, _mb_out)
            local_set!(_mb_ib, _mb_res)
            local_get!(_mb_ib, _mb_res)
            append_builder!(fb, _mb_ib)
            return append_builder!(b, fb)
        end

        # Handle Memory{T}.instance pattern (Julia 1.11+ Vector allocation)
        # This pattern appears as Core.getproperty(Memory{T}, :instance)
        # where Memory{T} is passed directly as a DataType
        # Memory{T}.instance is a singleton empty Memory (length 0)
        # We compile it to create an empty WasmGC array
        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

        # Handle getfield(DataType_constant, :flags) — compile-time constant folding.
        # Broadcasting IR uses DataType.flags to check type properties (e.g., isprimitivetype).
        # The DataType is a compile-time constant, so we can emit the flags value directly.
        if field_sym === :flags && obj_arg isa DataType && isdefined(obj_arg, :flags)
            flags_val = obj_arg.flags
            local _flb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            i32_const!(_flb, Int64(flags_val))
            append_builder!(fb, _flb)
            return append_builder!(b, fb)
        end

        if field_sym === :instance && obj_arg isa DataType && obj_arg <: Memory
            # Memory{T}.instance - create an empty array (length 0)
            # Extract element type from Memory{T}
            elem_type = if obj_arg.name.name === :Memory && length(obj_arg.parameters) >= 1
                obj_arg.parameters[1]
            elseif obj_arg.name.name === :GenericMemory && length(obj_arg.parameters) >= 2
                obj_arg.parameters[2]
            else
                Int32  # default
            end

            # Get or create array type for this element type
            arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

            # Emit array.new_default with length 0
            local _insb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            i32_const!(_insb, 0)  # length = 0
            array_new_default!(_insb, arr_type_idx)
            append_builder!(fb, _insb)
            return append_builder!(b, fb)
        end

        # PURE-9043: Handle Task.rngState0..3 field access → Wasm global.get
        # Julia's rand() accesses task-local Xoshiro state via getfield(task, :rngStateN)
        if obj_type === Task && field_sym in (:rngState0, :rngState1, :rngState2, :rngState3)
            rng_global = get_rng_global_idx(field_sym)
            if rng_global !== nothing
                local _rngb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                global_get!(_rngb, rng_global, ctx.mod.globals[rng_global + 1].valtype)
                append_builder!(fb, _rngb)
                return append_builder!(b, fb)
            end
        end

        # Handle WasmGlobal field access (:value -> global.get)
        if obj_type <: WasmGlobal
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    local _wgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    global_get!(_wgb, global_idx, ctx.mod.globals[global_idx + 1].valtype)
                    append_builder!(fb, _wgb)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle Array field access (:ref and :size) - works for Vector, Matrix, etc.
        # Both Vector and Matrix are now structs with (ref, size) fields
        if obj_type <: AbstractArray
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :ref
                # :ref returns the underlying array reference (field 1 of struct; field 0 = typeId)
                local _refb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    # march14 (wrap tail): typed arrival when the struct is registered
                    emit_value!(_refb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    struct_get!(_refb, info.wasm_type_idx, 1, AnyRef)  # Field 1 = data array (0=typeId)
                else
                    # parity(M11): an unregistered struct previously emitted an INCOMPLETE
                    # struct.get (prefix+opcode, no immediates — invalid wasm). Loud reject.
                    record_unsupported!(ctx, :unsupported_type, "field access on an unregistered struct type"; idx=idx)
                    unreachable!(_refb)
                end
                append_builder!(fb, _refb)
                return append_builder!(b, fb)
            elseif field_sym === :size
                # :size returns a Tuple containing the dimensions (field 2 of struct; field 0 = typeId)
                # For Vector: Tuple{Int64}, for Matrix: Tuple{Int64, Int64}, etc.
                local _szfb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    # march14 (wrap tail): typed arrival when the struct is registered
                    emit_value!(_szfb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                    struct_get!(_szfb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size tuple (0=typeId, 1=ref)
                else
                    record_unsupported!(ctx, :unsupported_type, "size access on an unregistered struct type"; idx=idx)
                    unreachable!(_szfb)
                end
                append_builder!(fb, _szfb)
                return append_builder!(b, fb)
            end

            # P6-trim: CodeUnits{UInt8,String} is an identity wrapper over the
            # byte array — getfield(cu, :s) is the array itself. Must run BEFORE
            # the generic struct_get path (CodeUnits is no longer a struct).
            if obj_type isa DataType && obj_type.name.name === :CodeUnits &&
               length(obj_type.parameters) >= 1 && obj_type.parameters[1] === UInt8
                local _cu_field0 = field_ref isa QuoteNode ? field_ref.value : field_ref
                if _cu_field0 === :s
                    emit_value!(fb, obj_arg, ctx)
                    return append_builder!(b, fb)
                end
            end

            # PURE-325: AbstractArray subtypes that are pure structs (e.g., UnitRange)
            # have named fields like :start, :stop — handle via struct_get
            if isconcretetype(obj_type) && isstructtype(obj_type)
                if !haskey(ctx.type_registry.structs, obj_type)
                    register_struct_type!(ctx.mod, ctx.type_registry, obj_type)
                end
                if haskey(ctx.type_registry.structs, obj_type)
                    info = ctx.type_registry.structs[obj_type]
                    field_idx = findfirst(==(field_sym), info.field_names)
                    if field_idx !== nothing
                        local _sfb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                        # march14 (wrap tail): the object arrives AS the registered struct
                        emit_value!(_sfb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                        struct_get!(_sfb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)  # PURE-9024
                        append_builder!(fb, _sfb)
                        return append_builder!(b, fb)
                    end
                end
            end
        end

        # Handle MemoryRef field access (:mem, :ptr_or_offset)
        # In WasmGC, MemoryRef IS the array, so :mem just returns it
        if obj_type <: MemoryRef
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :mem
                # :mem returns the underlying Memory - in WasmGC this is the array itself
                emit_value!(fb, obj_arg, ctx)
                return append_builder!(b, fb)
            elseif field_sym === :ptr_or_offset
                # P4-stdlib (SHA update!): the fake-pointer VALUE is the byte
                # offset. Base refs → 0; refs from memoryrefnew(ref, i, bc)
                # carry (i-1)*elsize (ctx.memoryref_offsets records i), so
                # pointer arithmetic over indexed refs stays faithful.
                local _poo_idx = obj_arg isa Core.SSAValue ?
                    get(ctx.memoryref_offsets, obj_arg.id, nothing) : nothing
                local _poo_el = obj_type isa DataType && length(obj_type.parameters) >= 1 ?
                    (obj_type.name.name === :GenericMemoryRef && length(obj_type.parameters) >= 2 ?
                     obj_type.parameters[2] : obj_type.parameters[1]) : nothing
                local _poob = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                if _poo_idx !== nothing && _poo_el isa DataType && isbitstype(_poo_el)
                    emit_value!(_poob, _poo_idx, ctx)
                    local _poo_it = infer_value_type(_poo_idx, ctx)
                    (_poo_it === Int64 || _poo_it === Int || _poo_it === UInt64) ||
                        num!(_poob, Opcode.I64_EXTEND_I32_S)
                    i64_const!(_poob, Int64(1))
                    num!(_poob, Opcode.I64_SUB)
                    if sizeof(_poo_el) != 1
                        i64_const!(_poob, Int64(sizeof(_poo_el)))
                        num!(_poob, Opcode.I64_MUL)
                    end
                else
                    i64_const!(_poob, 0)
                end
                append_builder!(fb, _poob)
                return append_builder!(b, fb)
            end
        end

        # Handle Memory field access (:length, :ptr)
        # In WasmGC, Memory IS the array
        if obj_type <: Memory
            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            if field_sym === :length
                # Return array length
                local _mlb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_mlb, obj_arg, ctx)
                array_len!(_mlb)
                num!(_mlb, Opcode.I64_EXTEND_I32_S)
                append_builder!(fb, _mlb)
                return append_builder!(b, fb)
            elseif field_sym === :ptr
                # Not meaningful in WasmGC - return 0
                local _mpb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                i64_const!(_mpb, 0)
                append_builder!(fb, _mpb)
                return append_builder!(b, fb)
            end
        end

        # Handle closure field access (captured variables)
        if is_closure_type(obj_type)
            # Register closure type if not already
            if !haskey(ctx.type_registry.structs, obj_type)
                register_closure_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]

                field_sym = if field_ref isa QuoteNode
                    field_ref.value
                else
                    field_ref
                end

                # P2-batch20: positional getfield(x, i::Integer) — see struct branch
                field_idx = field_sym isa Integer ?
                    (1 <= field_sym <= length(info.field_names) ? Int(field_sym) : nothing) :
                    findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    local _clfb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    emit_value!(_clfb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))   # march14: typed arrival
                    struct_get!(_clfb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)  # PURE-9024
                    append_builder!(fb, _clfb)
                    return append_builder!(b, fb)
                end
            end
        end

        # PURE-9064: Handle Type{T} constants for DataType field access.
        # When a DataType constant (e.g., Vector{Int64}) appears in IR, infer_value_type
        # returns Type{Vector{Int64}}. Unwrap to DataType for struct field access, since
        # DataType is registered in the JlType hierarchy with fields like :name, :parameters.
        effective_obj_type = obj_type
        if obj_type isa DataType && obj_type <: Type && obj_type !== DataType
            # Type{X} where X is a DataType — unwrap to DataType
            if haskey(ctx.type_registry.structs, DataType)
                effective_obj_type = DataType
            end
        end

        # Handle struct field access by name
        if is_struct_type(effective_obj_type) || haskey(ctx.type_registry.structs, effective_obj_type)
            # Register the struct type on-demand if not already registered
            if !haskey(ctx.type_registry.structs, effective_obj_type)
                register_struct_type!(ctx.mod, ctx.type_registry, effective_obj_type)
            end
            info = ctx.type_registry.structs[effective_obj_type]

            field_sym = if field_ref isa QuoteNode
                field_ref.value
            else
                field_ref
            end

            # P2-batch20: getfield(x, i::Integer) — positional access (gap
            # 8f5c0002bb71). Julia field order == info.field_names order.
            field_idx = field_sym isa Integer ?
                (1 <= field_sym <= length(info.field_names) ? Int(field_sym) : nothing) :
                findfirst(==(field_sym), info.field_names)
            if field_idx !== nothing
                local _sfgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                # march14: the typed wrap subsumes the PURE-701 structref-narrow helper
                emit_value!(_sfgb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))
                struct_get!(_sfgb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)  # PURE-9024
                append_builder!(fb, _sfgb)
                return append_builder!(b, fb)
            end
        end

        # Handle tuple field access by numeric index
        if obj_type <: Tuple
            # Register tuple type if needed
            if !haskey(ctx.type_registry.structs, obj_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, obj_type)
            end

            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]

                # Get the field index (1-indexed in Julia)
                field_idx = if field_ref isa Integer
                    field_ref
                elseif field_ref isa Core.SSAValue || field_ref isa Core.Argument
                    # Dynamic index - will be handled below for homogeneous tuples.
                    # `Core.Argument`: the index is a bare function parameter, e.g.
                    # `f(x) = (31,28,…)[x]` → `getfield(tuple, _2, boundscheck)` (gap
                    # d4409a896f5b — daysinmonth's DAYSINMONTH[m] lookup table). Without
                    # this the arg-indexed case fell to `nothing` → unreachable stub.
                    :dynamic
                else
                    nothing
                end

                if field_idx === :dynamic
                    # Dynamic tuple indexing - only supported for homogeneous tuples (NTuple)
                    # Check if all elements have the same type
                    # PURE-605: Guard against types without definite field count (e.g., Vararg tuples)
                    elem_types = try fieldtypes(obj_type) catch; () end
                    if length(elem_types) > 0 && all(t -> t === elem_types[1], elem_types)
                        # Homogeneous tuple - we can treat it as an array
                        elem_type = elem_types[1]

                        # For constant tuple (GlobalRef), create a WasmGC array and access it
                        # The tuple value needs to be compiled as an array first

                        # Get or create array type for this element type.
                        # The array element type MUST equal the tuple's actual field
                        # wasm type (what the struct.get below yields), else
                        # array.new_fixed mismatches. For String, get_string_ref_array_type!'s
                        # arrays[Vector{String}] cache can be polluted (array-of-Vector{String}-
                        # struct) by other registrations → build an array of the REAL field
                        # valtype instead. (Surfaced by Markdown plain over String tuples and
                        # STRESS string-transform funcs once dynamic-dispatch discovery compiles
                        # those specializations.)
                        array_type_idx = if elem_type === String
                            local _tst = ctx.mod.types[Int(info.wasm_type_idx) + 1]
                            local _fvt = _tst.fields[Int(info.field_offset) + 1].valtype
                            add_array_type!(ctx.mod, _fvt, true)
                        else
                            get_array_type!(ctx.mod, ctx.type_registry, elem_type)
                        end

                        # Compile the tuple as an array
                        # First compile the tuple value
                        local _htb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                        emit_value!(_htb, obj_arg, ctx)

                        # The struct is on the stack, we need to convert struct fields to array
                        # Store in local, then create array from fields
                        tuple_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, julia_to_wasm_type_concrete(obj_type, ctx))
                        local_set!(_htb, tuple_local)

                        # Push all fields onto stack (account for typeId at field 0)
                        for i in 0:(length(elem_types)-1)
                            local_get!(_htb, tuple_local)
                            struct_get!(_htb, info.wasm_type_idx, i + Int(info.field_offset), AnyRef)  # skip typeId
                        end

                        # Create array from fields
                        array_new_fixed!(_htb, array_type_idx, length(elem_types), AnyRef)

                        # Store array in local - use concrete ref to specific array type
                        array_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, ConcreteRef(array_type_idx, true))
                        local_set!(_htb, array_local)

                        # Now compile the index and access the array
                        # Julia uses 1-based indexing, Wasm uses 0-based
                        emit_value!(_htb, field_ref, ctx)

                        # Subtract 1 for 0-based indexing
                        i64_const!(_htb, 1)
                        num!(_htb, Opcode.I64_SUB)
                        # Wrap to i32 for array index
                        num!(_htb, Opcode.I32_WRAP_I64)

                        # Store index in local
                        idx_local = length(ctx.locals) + ctx.n_params
                        push!(ctx.locals, I32)
                        local_set!(_htb, idx_local)

                        # Access array: array.get (use ARRAY_GET_U for packed i8 arrays)
                        local_get!(_htb, array_local)
                        local_get!(_htb, idx_local)
                        array_get!(_htb, array_type_idx, AnyRef; signed=(elem_type === UInt8 ? false : nothing))

                        # PURE-036bc: If array element type is ExternRef (e.g., elem_type=Any),
                        # array_get returns externref. Downstream code may ref_cast to a struct
                        # type, which requires anyref input. Add any_convert_extern.
                        wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                        if wasm_elem_type === ExternRef
                            any_convert_extern!(_htb)
                        end

                        append_builder!(fb, _htb)
                        return append_builder!(b, fb)
                    end
                    # Heterogeneous tuple + dynamic index → produce a tagged-union
                    # value `Union{fieldtypes...}` via a runtime switch on the index.
                    # `getfield(::Tuple{A,B,...}, i::Int)` infers to exactly this union,
                    # and the consumers (`isa`, π-narrowing, memoryrefset!) already
                    # speak the tagged-union ABI — so wrapping each field into the union
                    # makes them work unchanged. Surfaced by `Any[a,"x",a]` /
                    # `md"...$x...$y..."` interpolation (Pluto featured corpus): these
                    # lower to `Base.getindex(T, vals...)` which loops `vals[i]` over a
                    # heterogeneous tuple — previously emitted `unreachable`.
                    if length(elem_types) >= 2
                        U = Union{elem_types...}
                        if U isa Union
                            # Produce the value in the CANONICAL representation of the
                            # getfield's INFERRED SSA result type — that is exactly what
                            # the SSA local was allocated as (julia_to_wasm_type_concrete),
                            # so the if-block result matches the local and there's no store
                            # mismatch. (Anchoring on Union{fieldtypes…} instead diverges
                            # from inference — e.g. Dates date-format parsing, where the
                            # inferred result is a tagged union but fieldtypes look
                            # all-struct.) For a tagged-union rep, tag-wrap each field; for
                            # StructRef (all-struct union, e.g. Union{Dog,Cat}) push the raw
                            # struct ref (subtype of structref) — tag-wrapping it would make
                            # the consumer's isa/π cast trap "illegal cast".
                            _ssa_t = get(ctx.ssa_types, idx, nothing)
                            local Ueff
                            if _ssa_t isa Type && _ssa_t !== Union{}
                                union_wasm = julia_to_wasm_type_concrete(_ssa_t, ctx)
                                Ueff = _ssa_t isa Union ? _ssa_t : U
                            else
                                union_wasm = get_concrete_wasm_type(U, ctx.mod, ctx.type_registry)
                                Ueff = U
                            end
                            # B4/U2: the tagged-union wrapper is retired — a het-tuple field's
                            # union value is an AnyRef classId box (the `else` branch below), never
                            # the {typeId,tag,value} wrapper.

                            local _hetb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                            # tuple value → tuple_local
                            emit_value!(_hetb, obj_arg, ctx)
                            tuple_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, julia_to_wasm_type_concrete(obj_type, ctx))
                            local_set!(_hetb, tuple_local)

                            # index (1-based i64) → 0-based i32 → idx_local
                            emit_value!(_hetb, field_ref, ctx)
                            i64_const!(_hetb, 1)
                            num!(_hetb, Opcode.I64_SUB)
                            num!(_hetb, Opcode.I32_WRAP_I64)
                            idx_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, I32)
                            local_set!(_hetb, idx_local)

                            n_fields = length(elem_types)
                            emit_field_wrap = i -> begin
                                local_get!(_hetb, tuple_local)
                                struct_get!(_hetb, info.wasm_type_idx, i + Int(info.field_offset), AnyRef)
                                # M3: dead tagged-union wrapper arm DELETED (needs_tagged_union ≡ false).
                                # Coerce the raw field value to U's canonical wasm rep.
                                fw = julia_to_wasm_type_concrete(elem_types[i + 1], ctx)
                                if union_wasm === AnyRef
                                    if fw === I64 || fw === I32 || fw === F32 || fw === F64
                                        # THE single-source box producer with the field's REAL classId
                                        # (same-wasm-rep members Bool/Int8/Int32 stay isa-distinguishable).
                                        emit_classid_box!(_hetb, ctx, fw, elem_types[i + 1])
                                    elseif fw === ExternRef
                                        any_convert_extern!(_hetb)
                                    end
                                    # ConcreteRef/StructRef field is already anyref-compatible
                                end
                                # union_wasm === StructRef / numeric: push as-is.
                            end
                            # nested if-chain: idx==0 ? wrap(f0) : idx==1 ? wrap(f1) : … : wrap(fN-1)
                            for i in 0:(n_fields - 2)
                                local_get!(_hetb, idx_local)
                                i32_const!(_hetb, Int64(i))
                                num!(_hetb, Opcode.I32_EQ)
                                if_!(_hetb, union_wasm; results=WasmValType[union_wasm])
                                emit_field_wrap(i)
                                else_!(_hetb)
                            end
                            emit_field_wrap(n_fields - 1)  # last field = else-default
                            for _ in 1:(n_fields - 1)
                                end_block!(_hetb)
                            end
                            # Land the union result in a scratch local and end with a
                            # clean `local.get`. The if/else block ends in END, which the
                            # statement-assignment heuristics (which peek at the tail
                            # instruction to infer the produced type) mis-parse — they'd
                            # drop the value and substitute ref.null. A trailing local.get
                            # of the correctly-typed scratch is unambiguous.
                            result_local = length(ctx.locals) + ctx.n_params
                            push!(ctx.locals, union_wasm)
                            local_set!(_hetb, result_local)
                            local_get!(_hetb, result_local)
                            append_builder!(fb, _hetb)
                            return append_builder!(b, fb)
                        end
                    end
                elseif field_idx !== nothing && field_idx >= 1 && field_idx <= length(info.field_names)
                    local _tfgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    emit_value!(_tfgb, obj_arg, ctx, ConcreteRef(UInt32(info.wasm_type_idx), true))   # march14: typed arrival
                    struct_get!(_tfgb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)  # PURE-9024
                    append_builder!(fb, _tfgb)
                    return append_builder!(b, fb)
                end
            end
        end
    end

    # Special case for memoryrefget - array element access
    # memoryrefget(ref, ordering, boundscheck) where ref is from memoryrefnew
    if is_func(func, :memoryrefget) && length(args) >= 1
        ref_arg = args[1]
        ref_type = infer_value_type(ref_arg, ctx)

        # PURE-9065: Nothing-typed memory — always returns nothing (i32.const 0).
        # Consume the [array_ref, i32_index] stack pair from memoryrefnew, then push 0.
        if ref_type isa DataType && (
            (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
            (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
            # Compile ref_arg to push [array_ref, i32_index], then drop both
            local _mrgn = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            emit_value!(_mrgn, ref_arg, ctx)
            drop!(_mrgn)  # drop i32_index
            drop!(_mrgn)  # drop array_ref
            i32_const!(_mrgn, 0)
            append_builder!(fb, _mrgn)
            return append_builder!(b, fb)
        end

        # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
        # Memory{T}, or GenericMemory{atomicity, T, addrspace}
        # PURE-045: Also handle Memory types for direct array access patterns
        elem_type = Int32  # default
        if ref_type isa DataType
            if ref_type.name.name === :MemoryRef
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemoryRef
                # GenericMemoryRef has parameters (atomicity, element_type, addrspace)
                elem_type = ref_type.parameters[2]
            elseif ref_type.name.name === :Memory && length(ref_type.parameters) >= 1
                # Memory{T} - element type is first parameter
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemory && length(ref_type.parameters) >= 2
                # GenericMemory{atomicity, T, addrspace} - element type is second parameter
                elem_type = ref_type.parameters[2]
            end
        end

        # PURE-902: Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
        # When cross-function calls use abstract arg types (e.g., Vector instead of
        # Vector{Any}), code_typed returns bare MemoryRef (UnionAll) instead of
        # MemoryRef{Any} (DataType). The elem_type stays as default Int32.
        # Fix: use the memoryrefget result's own SSA type as the element type.
        if elem_type === Int32 && !(ref_type isa DataType)
            ssa_result_type = get(ctx.ssa_types, idx, Any)
            # If the SSA result type is itself a MemoryRef/array type (UnionAll),
            # the element type is unknown — default to Any
            if ssa_result_type isa UnionAll || ssa_result_type === Any
                elem_type = Any
            elseif ssa_result_type !== Int32
                elem_type = ssa_result_type
            end
        end

        # Get or create array type for this element type
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # The ref SSA value from memoryrefnew will have compiled to [array_ref, i32_index]
        # We need to compile ref_arg which will leave [array_ref, i32_index] on stack
        local _mrgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_mrgb, ref_arg, ctx)

        array_get!(_mrgb, array_type_idx, AnyRef; signed=(elem_type === UInt8 ? false : nothing))

        # Note: if elem_type is Any, array.get returns externref and the SSA local
        # is also typed as externref (fixed in analyze_ssa_types!). No cast needed here.
        append_builder!(fb, _mrgb)
        return append_builder!(b, fb)
    end

    # Special case for memoryrefoffset - get the 1-based offset of a MemoryRef
    # This is used by push!, resize!, and other dynamic array operations
    # Fresh MemoryRefs (from Core.memoryref, getfield(vec, :ref)) have offset 1
    # Indexed MemoryRefs (from memoryrefnew(ref, index, bc)) have offset = index
    if is_func(func, :memoryrefoffset) && length(args) >= 1
        ref_arg = args[1]

        # Check if this ref came from a memoryrefnew with an index
        local _mrob = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        if ref_arg isa Core.SSAValue && haskey(ctx.memoryref_offsets, ref_arg.id)
            # This MemoryRef has a recorded offset - compile the index value
            index_val = ctx.memoryref_offsets[ref_arg.id]
            emit_value!(_mrob, index_val, ctx)

            # Ensure result is i64 (Julia's Int)
            idx_type = infer_value_type(index_val, ctx)
            if idx_type !== Int64 && idx_type !== Int
                # Convert to i64 if needed
                num!(_mrob, Opcode.I64_EXTEND_I32_S)
            end
        else
            # Fresh MemoryRef - offset is always 1
            i64_const!(_mrob, 1)  # 1
        end
        append_builder!(fb, _mrob)
        return append_builder!(b, fb)
    end

    # Special case for memoryrefset! - array element assignment
    # memoryrefset!(ref, value, ordering, boundscheck) -> stores value in array
    # In Julia, setindex! returns the stored value, so we need to return it too
    if is_func(func, :memoryrefset!) && length(args) >= 2
        ref_arg = args[1]
        value_arg = args[2]
        ref_type = infer_value_type(ref_arg, ctx)

        # PURE-9065: Nothing-typed memory — storing nothing is a no-op.
        # Consume the [array_ref, i32_index] stack pair from memoryrefnew, then done.
        # Don't push a result — Nothing has no Wasm representation to keep on the stack.
        if ref_type isa DataType && (
            (ref_type.name.name === :MemoryRef && length(ref_type.parameters) >= 1 && ref_type.parameters[1] === Nothing) ||
            (ref_type.name.name === :GenericMemoryRef && length(ref_type.parameters) >= 2 && ref_type.parameters[2] === Nothing))
            local _mrsn = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            emit_value!(_mrsn, ref_arg, ctx)
            drop!(_mrsn)  # drop i32_index
            drop!(_mrsn)  # drop array_ref
            append_builder!(fb, _mrsn)
            return append_builder!(b, fb)
        end

        # Extract element type from MemoryRef{T}, GenericMemoryRef{atomicity, T, addrspace},
        # Memory{T}, or GenericMemory{atomicity, T, addrspace}
        # PURE-045: Also handle Memory types for direct array access patterns
        elem_type = Int32  # default
        if ref_type isa DataType
            if ref_type.name.name === :MemoryRef
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemoryRef
                # GenericMemoryRef has parameters (atomicity, element_type, addrspace)
                elem_type = ref_type.parameters[2]
            elseif ref_type.name.name === :Memory && length(ref_type.parameters) >= 1
                # Memory{T} - element type is first parameter
                elem_type = ref_type.parameters[1]
            elseif ref_type.name.name === :GenericMemory && length(ref_type.parameters) >= 2
                # GenericMemory{atomicity, T, addrspace} - element type is second parameter
                elem_type = ref_type.parameters[2]
            end
        end

        # PURE-902: Handle UnionAll MemoryRef types (bare MemoryRef without parameters)
        # Same logic as memoryrefget: when ref_type is a bare UnionAll MemoryRef,
        # infer element type from SSA result type or default to Any.
        if elem_type === Int32 && !(ref_type isa DataType)
            ssa_result_type = get(ctx.ssa_types, idx, Any)
            if ssa_result_type isa UnionAll || ssa_result_type === Any
                elem_type = Any
            elseif ssa_result_type !== Int32
                elem_type = ssa_result_type
            end
        end

        # Get or create array type for this element type
        array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # Compile ref_arg which will leave [array_ref, i32_index] on stack
        local _msb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_msb, ref_arg, ctx)

        # Compile the value to store - we need it twice (for array.set and return)
        # First compile gets the value on stack for array.set
        local _mv_b = _compile_value_b(value_arg, ctx)
        local mset_val_ty = isempty(_mv_b.v.stack) ? nothing : _mv_b.v.stack[end]
        # If array element type is anyref/externref (elem_type is Any OR abstract type), box numeric values
        # PURE-045: Check the actual wasm element type, not just elem_type === Any
        # Abstract types like CallInfo also map to ExternRef
        # PHASE-1-004: AnyRef arrays (Memory{Any}) need numeric→anyref boxing via struct.new
        local wasm_elem_type = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
        if wasm_elem_type === AnyRef
            # AnyRef array element — box numeric values to anyref via struct.new.
            # dart2wasm carries the type with the value rather than scanning bytes.
            local mset_src_wasm_any = mset_val_ty
            local is_numeric_mset_any = mset_src_wasm_any === I64 || mset_src_wasm_any === I32 || mset_src_wasm_any === F64 || mset_src_wasm_any === F32
            local is_already_anyref = mset_src_wasm_any === AnyRef || mset_src_wasm_any === StructRef || mset_src_wasm_any isa ConcreteRef
            if is_numeric_mset_any
                emit_numeric_to_anyref!(_msb, value_arg, mset_src_wasm_any, ctx)
            else
                append_builder!(_msb, _mv_b)
                # march16: a KNOWN closure erasing into a Memory{Any} slot wraps into
                # the closure OBJECT (dart convertType at the erasure seam)
                maybe_wrap_closure!(_msb, ctx, infer_value_type(value_arg, ctx))
                if !is_already_anyref && mset_src_wasm_any === ExternRef
                    any_convert_extern!(_msb)
                end
            end
        elseif wasm_elem_type === ExternRef
            # Determine source value's wasm type to decide conversion.
            # dart2wasm carries the type with the value rather than scanning bytes.
            local mset_src_wasm = mset_val_ty
            local is_numeric_mset = mset_src_wasm === I64 || mset_src_wasm === I32 || mset_src_wasm === F64 || mset_src_wasm === F32
            local is_already_externref_mset = mset_src_wasm === ExternRef
            if is_numeric_mset
                emit_numeric_to_externref!(_msb, value_arg, mset_src_wasm, ctx)
            else
                append_builder!(_msb, _mv_b)
                # PURE-048: Skip extern_convert_any if value is already externref.
                # externref is NOT a subtype of anyref, so extern_convert_any would fail.
                if !is_already_externref_mset
                    extern_convert_any!(_msb)
                end
            end
        elseif wasm_elem_type isa ConcreteRef
            # PURE-045: Array of concrete ref types (e.g., struct or array refs)
            # If value is numeric (nothing represented as i32_const 0), emit ref.null instead
            # march3 (typed): numeric-typed value into a ref-typed array slot → ref.null
            # (the const first-byte gate + LOCAL_GET LEB walk are the tracked type now)
            if mset_val_ty === I64 || mset_val_ty === I32 || mset_val_ty === F64 || mset_val_ty === F32
                ref_null!(_msb, Int64(wasm_elem_type.type_idx), ConcreteRef(UInt32(wasm_elem_type.type_idx), true))
            else
                append_builder!(_msb, _mv_b)
                # PURE-6025: If value is externref but array element is concrete ref,
                # convert externref → anyref → ref.cast (ref null $elem_type)
                if mset_val_ty === ExternRef
                    any_convert_extern!(_msb)
                    ref_cast!(_msb, Int64(wasm_elem_type.type_idx), true)
                end
            end
        else
            # TRUE-INT-002-impl2: When storing nothing (i32_const 0) into an i64 array
            # (e.g., Union{Nothing, Int64} element type), emit i64_const 0 instead.
            # compile_value(nothing) always produces i32_const 0, but array_set expects
            # the element type — i64 for Union{Nothing, Int64} arrays.
            if wasm_elem_type === I64 && mset_val_ty === I32
                i64_const!(_msb, 0)  # i64 value 0
            elseif wasm_elem_type === F64 && mset_val_ty === I32
                f64_const!(_msb, 0.0)
            else
                append_builder!(_msb, _mv_b)
            end
        end

        # array.set consumes [array_ref, i32_index, value] and returns nothing
        array_set!(_msb, array_type_idx, AnyRef)

        # Julia's memoryrefset! returns the stored value, so push it again
        # This is needed because compile_statement may add LOCAL_SET after this
        # PURE-6024: Only emit return value if SSA has a local to store it in.
        # Without this guard, the return value (e.g., i32.const 0 for nothing)
        # is left on the stack when the SSA has no allocated local, causing
        # "values remaining on stack at end of block" validation errors.
        if haskey(ctx.ssa_locals, idx)
            local _rv2_b = _compile_value_b(value_arg, ctx)
            local ret_val_ty = isempty(_rv2_b.v.stack) ? nothing : _rv2_b.v.stack[end]
            append_builder!(_msb, _rv2_b)
            # PURE-3113: If the SSA local is externref but the return value is a concrete ref,
            # emit extern_convert_any. The compile_statement safety check can't catch this
            # because has_gc_prefix=true (from array_set above) skips the trailing local_get
            # check, and the SSA type check sees Julia type (Any→ExternRef) matching the local.
            local mset_ret_local = ctx.ssa_locals[idx]
            local mset_ret_arr_idx = mset_ret_local - ctx.n_params + 1
            if mset_ret_arr_idx >= 1 && mset_ret_arr_idx <= length(ctx.locals)
                local mset_ret_local_type = ctx.locals[mset_ret_arr_idx]
                if mset_ret_local_type === ExternRef
                    # Check if return value is a concrete ref (not already externref)
                    local mset_ret_src_wasm = nothing
                    if length(ret_val_bytes) >= 2 && ret_val_bytes[1] == Opcode.LOCAL_GET
                        local mset_src_idx = 0
                        local mset_shift = 0
                        local mset_pos = 2
                        while mset_pos <= length(ret_val_bytes)
                            byt = ret_val_bytes[mset_pos]
                            mset_src_idx |= (Int(byt & 0x7f) << mset_shift)
                            mset_shift += 7
                            mset_pos += 1
                            (byt & 0x80) == 0 && break
                        end
                        if mset_pos - 1 == length(ret_val_bytes) && mset_src_idx >= ctx.n_params
                            local mset_src_arr = mset_src_idx - ctx.n_params + 1
                            if mset_src_arr >= 1 && mset_src_arr <= length(ctx.locals)
                                mset_ret_src_wasm = ctx.locals[mset_src_arr]
                            end
                        end
                    end
                    if mset_ret_src_wasm isa ConcreteRef || mset_ret_src_wasm === StructRef || mset_ret_src_wasm === ArrayRef || mset_ret_src_wasm === AnyRef
                        extern_convert_any!(_msb)
                    end
                end
            end
        end
        append_builder!(fb, _msb)
        return append_builder!(b, fb)
    end

    # Special case for Core.memorynew - creates a new Memory{T} backing store
    # memorynew(Memory{T}, size) -> Memory{T}
    # In WasmGC, Memory{T} IS an array, so this compiles to array.new_default
    if is_func(func, :memorynew) && length(args) >= 2
        mem_type = args[1]  # Memory{T} type (compile-time constant)
        size_arg = args[2]  # size (may be literal or SSA)

        # Extract element type from Memory{T}
        elem_type = if mem_type isa DataType && mem_type <: Memory
            if mem_type.name.name === :Memory && length(mem_type.parameters) >= 1
                mem_type.parameters[1]
            elseif mem_type.name.name === :GenericMemory && length(mem_type.parameters) >= 2
                mem_type.parameters[2]
            else
                Int32  # default
            end
        else
            Int32  # default
        end

        arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

        # Compile size argument
        # WasmGC arrays are fixed-size — they cannot be resized after creation.
        # Julia's push!/append! with _growend! handles growth by creating new arrays,
        # but we enforce a minimum capacity so that small initial allocations
        # (e.g., Vector{T}() which uses memorynew(Memory{T}, 0)) have room for
        # initial push! operations before needing the first growth.
        min_capacity = 16
        local _mnb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        if size_arg isa Int || size_arg isa Int64
            # Literal size - emit as i32 constant with minimum capacity
            actual_size = max(Int64(size_arg), min_capacity)
            i32_const!(_mnb, actual_size)
        else
            # SSA or other expression - compile, convert to i32, apply minimum
            emit_value!(_mnb, size_arg, ctx, I64)   # march14: the wrap-to-i32 follows — the value is an I64 index
            num!(_mnb, Opcode.I32_WRAP_I64)
            # Ensure minimum capacity: max(size, min_capacity)
            local cap_check_local = allocate_local!(ctx, I32)
            local_tee!(_mnb, cap_check_local)
            i32_const!(_mnb, Int64(min_capacity))
            local_get!(_mnb, cap_check_local)
            i32_const!(_mnb, Int64(min_capacity))
            num!(_mnb, Opcode.I32_GE_S)
            select!(_mnb)  # select(size, min_cap, size >= min_cap)
        end

        array_new_default!(_mnb, arr_type_idx)
        append_builder!(fb, _mnb)
        return append_builder!(b, fb)
    end

    # Special case for Core.memoryref - creates MemoryRef from Memory
    # memoryref(memory::Memory{T}) -> MemoryRef{T}
    # In WasmGC, this is a no-op since Memory IS the array
    if is_func(func, :memoryref) && length(args) == 1
        # Pass through the array reference - Memory and MemoryRef are the same in WasmGC
        emit_value!(fb, args[1], ctx)
        return append_builder!(b, fb)
    end

    # Special case for memoryrefnew - handle both patterns:
    # 1. memoryrefnew(memory) -> MemoryRef (for Vector allocation, just pass through)
    # 2. memoryrefnew(base_ref, index, boundscheck) -> MemoryRef at offset
    if is_func(func, :memoryrefnew)
        if length(args) == 1
            # Single arg: just wrapping a Memory - pass through the array reference
            # This is a "fresh" MemoryRef with offset 1
            emit_value!(fb, args[1], ctx)
            return append_builder!(b, fb)
        elseif length(args) >= 2
            base_ref = args[1]
            index = args[2]

            # Record the offset for this MemoryRef SSA so memoryrefoffset can use it
            ctx.memoryref_offsets[idx] = index

            # PURE-9065: For Nothing-typed MemoryRef, check if result is used.
            # If the SSA has no local and no subsequent statement references it,
            # skip bytecode to avoid orphaning [array_ref, i32_index] on the stack.
            ssa_type_mr = get(ctx.ssa_types, idx, Any)
            is_nothing_ref_mr = ssa_type_mr isa DataType && (
                (ssa_type_mr.name.name === :MemoryRef && length(ssa_type_mr.parameters) >= 1 && ssa_type_mr.parameters[1] === Nothing) ||
                (ssa_type_mr.name.name === :GenericMemoryRef && length(ssa_type_mr.parameters) >= 2 && ssa_type_mr.parameters[2] === Nothing))
            if is_nothing_ref_mr && !haskey(ctx.ssa_locals, idx)
                # Check if any subsequent statement uses this SSA
                ssa_used = false
                for j in (idx+1):length(ctx.code_info.code)
                    s = ctx.code_info.code[j]
                    if s isa Expr
                        for a in s.args
                            if a isa Core.SSAValue && a.id == idx
                                ssa_used = true
                                break
                            end
                        end
                    end
                    ssa_used && break
                end
                if !ssa_used
                    return append_builder!(b, fb)  # Skip — orphaned MemoryRef{Nothing}
                end
            end

            # Compile the base array reference
            local _mrnb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            emit_value!(_mrnb, base_ref, ctx)

            # Compile and convert index to i32 (Julia uses 1-based Int64, Wasm uses 0-based i32)
            emit_value!(_mrnb, index, ctx)

            # PURE-6027: Check BOTH Julia type AND actual WASM type for i64→i32 wrap.
            # infer_value_type may return Any/Union while the actual local is i64.
            idx_type = infer_value_type(index, ctx)
            idx_wasm = get_phi_edge_wasm_type(index, ctx)
            if idx_type === Int64 || idx_type === Int || idx_wasm === I64
                # Convert to i32 and subtract 1 for 0-based indexing
                num!(_mrnb, Opcode.I32_WRAP_I64)  # i64 -> i32
            end
            i32_const!(_mrnb, 1)  # 1
            num!(_mrnb, Opcode.I32_SUB)  # index - 1 for 0-based

            # Now stack has [array_ref, i32_index] which is what memoryrefget needs
            append_builder!(fb, _mrnb)
            return append_builder!(b, fb)
        end
    end

    # Special case for Core.tuple - tuple creation
    if is_func(func, :tuple) && length(args) > 0
        # Infer tuple type from arguments
        elem_types = Type[infer_value_type(arg, ctx) for arg in args]
        tuple_type = Tuple{elem_types...}

        # Register tuple type
        if !haskey(ctx.type_registry.structs, tuple_type)
            register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
        end

        if haskey(ctx.type_registry.structs, tuple_type)
            info = ctx.type_registry.structs[tuple_type]

            # Push typeId for tuple struct (field 0 = typeId)
            local _tupb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            i32_const!(_tupb, Int64(ensure_type_id!(ctx.type_registry, tuple_type)))  # real classId (M3)

            # Push all tuple elements with type safety for externref fields
            # PURE-142: Core.tuple args may be phi locals typed as i64 but
            # struct field expects externref (Any-typed tuple element)
            struct_type_def = ctx.mod.types[info.wasm_type_idx + 1]
            for (fi, arg) in enumerate(args)
                # march3 (typed): the first-byte const scans + LOCAL_GET LEB decodes are
                # gone — arg_ty (the tracked emission type) decides; const-vs-local is an
                # ir/-level kind test (dart looks at node kinds, never at bytes).
                local _ab = _compile_value_b(arg, ctx)
                local arg_ty = isempty(_ab.v.stack) ? nothing : _ab.v.stack[end]
                local _ab_numeric = arg_ty === I32 || arg_ty === I64 || arg_ty === F32 || arg_ty === F64
                local _ab_is_local = length(_ab.instrs) == 1 && _ab.instrs[1] isa InstrIR.LocalGet
                expected_wasm = nothing
                # Account for typeId at field 0: struct_type_def.fields is 1-indexed,
                # wasm field for Julia field fi is at position fi + field_offset
                local wasm_fi = fi + Int(info.field_offset)
                if struct_type_def isa StructType && wasm_fi <= length(struct_type_def.fields)
                    expected_wasm = struct_type_def.fields[wasm_fi].valtype
                end
                if expected_wasm === ExternRef
                    if _ab_numeric
                        ref_null!(_tupb, ExternRef)
                    else
                        append_builder!(_tupb, _ab)
                        # already-externref values pass through (tracked type, any source)
                        arg_ty === ExternRef || extern_convert_any!(_tupb)
                    end
                elseif expected_wasm isa ConcreteRef || expected_wasm === StructRef || expected_wasm === ArrayRef || expected_wasm === AnyRef
                    if _ab_numeric
                        if _ab_is_local && expected_wasm === AnyRef
                            # TRUE-PARSE-002: Box numeric local for anyref tuple field via THE single box emitter.
                            append_builder!(_tupb, _ab)
                            emit_classid_box!(_tupb, ctx, arg_ty, nothing)
                        elseif expected_wasm isa ConcreteRef
                            ref_null!(_tupb, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                        else
                            ref_null!(_tupb, expected_wasm isa UInt8 ? RefType(expected_wasm) : StructRef)
                        end
                    else
                        append_builder!(_tupb, _ab)
                    end
                else
                    append_builder!(_tupb, _ab)
                end
            end

            # struct.new
            struct_new!(_tupb, info.wasm_type_idx)   # mod-resolved fields (march3)

            append_builder!(fb, _tupb)
            return append_builder!(b, fb)
        end
    end

    # Special case for setfield!/setproperty! - mutable struct field assignment
    # Also handles WasmGlobal (:value -> global.set)
    # In newer Julia, obj.field = val compiles to Base.setproperty!(obj, :field, val)
    if (is_func(func, :setfield!) || is_func(func, :setproperty!)) && length(args) >= 3
        obj_arg = args[1]
        field_ref = args[2]
        value_arg = args[3]
        obj_type = infer_value_type(obj_arg, ctx)

        field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

        # PURE-9043: Handle Task.rngState0..3 field assignment → Wasm global.set
        if obj_type === Task && field_sym in (:rngState0, :rngState1, :rngState2, :rngState3)
            rng_global = get_rng_global_idx(field_sym)
            if rng_global !== nothing
                local _rsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_rsb, value_arg, ctx, ctx.mod.globals[Int(rng_global) + 1].valtype)   # march14
                global_set!(_rsb, rng_global)
                append_builder!(fb, _rsb)
                return append_builder!(b, fb)
            end
        end

        # Handle WasmGlobal field assignment (:value -> global.set)
        if obj_type <: WasmGlobal
            if field_sym === :value
                # Extract global index from type parameter
                global_idx = get_wasm_global_idx(obj_arg, ctx)
                if global_idx !== nothing
                    local _wgsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    # Push the value to set
                    emit_value!(_wgsb, value_arg, ctx)
                    # Emit global.set
                    global_set!(_wgsb, global_idx)
                    # setfield! returns the value, so push it again
                    emit_value!(_wgsb, value_arg, ctx)
                    append_builder!(fb, _wgsb)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle Vector/Array field assignment (:ref and :size are mutable)
        # Vector{T} is now a struct with (ref, size) where both fields are mutable
        if obj_type <: AbstractArray
            field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref
            if field_sym === :ref && haskey(ctx.type_registry.structs, obj_type)
                # PURE-325: setfield!(vector, :ref, new_memref) — update data array
                # :ref is field index 1 in the Vector struct (field 0 = typeId)
                # Guard: only handle if value_arg has a local (skip multi-arg memoryrefnew)
                value_has_local = false
                if value_arg isa Core.SSAValue && haskey(ctx.ssa_locals, value_arg.id)
                    value_has_local = true
                elseif value_arg isa Core.Argument
                    value_has_local = true
                end
                if value_has_local
                    info = ctx.type_registry.structs[obj_type]
                    value_type = infer_value_type(value_arg, ctx)
                    temp_local = allocate_local!(ctx, value_type)
                    local _vrb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    emit_value!(_vrb, value_arg, ctx)
                    local_set!(_vrb, temp_local)
                    emit_value!(_vrb, obj_arg, ctx)
                    # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                                        emit_ref_cast_if_structref!(_vrb, obj_arg, info.wasm_type_idx, ctx)
                    local_get!(_vrb, temp_local)
                    struct_set!(_vrb, info.wasm_type_idx, 1, AnyRef)  # Field 1 = data array ref (0=typeId)
                    local_get!(_vrb, temp_local)
                    append_builder!(fb, _vrb)
                    return append_builder!(b, fb)
                end
                # Fall through to generic handling for multi-arg memoryrefnew values
            elseif field_sym === :size && haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                # :size is field index 2 (0=typeId, 1=ref, 2=size)
                # struct.set expects: [ref, value]

                # IMPORTANT: The value_arg might be an SSA that was just computed and
                # is on top of the stack. If we compile obj_arg first, we'd push it
                # AFTER the value, giving wrong order [value, ref] instead of [ref, value].
                # Solution: compile value first, store in temp local, then compile ref.
                value_type = infer_value_type(value_arg, ctx)
                temp_local = allocate_local!(ctx, value_type)
                local _vsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)

                # Compile value and store in local (value may already be on stack from prev stmt)
                emit_value!(_vsb, value_arg, ctx)
                local_set!(_vsb, temp_local)

                # Now compile obj (struct ref)
                emit_value!(_vsb, obj_arg, ctx)
                # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                                emit_ref_cast_if_structref!(_vsb, obj_arg, info.wasm_type_idx, ctx)

                # Load value from local
                local_get!(_vsb, temp_local)

                # struct.set
                struct_set!(_vsb, info.wasm_type_idx, 2, AnyRef)  # Field 2 = size tuple (0=typeId, 1=ref)

                # setfield! returns the value, so push it again
                local_get!(_vsb, temp_local)
                append_builder!(fb, _vsb)
                return append_builder!(b, fb)
            end
        end

        # Handle mutable struct field assignment
        if is_struct_type(obj_type) && ismutabletype(obj_type)
            if haskey(ctx.type_registry.structs, obj_type)
                info = ctx.type_registry.structs[obj_type]
                field_sym = field_ref isa QuoteNode ? field_ref.value : field_ref

                field_idx = findfirst(==(field_sym), info.field_names)
                if field_idx !== nothing
                    # PURE-045: Check if field is Any type (maps to externref in Wasm)
                    field_type = field_idx <= length(info.field_types) ? info.field_types[field_idx] : Any

                    # struct.set expects: [ref, value]
                    local _sfsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    emit_value!(_sfsb, obj_arg, ctx)
                    # PURE-701: If obj_arg's local is structref, insert ref.cast null before struct_set
                                        emit_ref_cast_if_structref!(_sfsb, obj_arg, info.wasm_type_idx, ctx)

                    # PURE-4150: Track if value is a Type reference (used for both struct_set and return value)
                    is_type_value = false

                    # PURE-045: If field type is Any, convert value to match field's WasmGC type.
                    # PURE-9064: The actual Wasm field type may be AnyRef (when JlType hierarchy
                    # is active) or ExternRef (legacy). Look it up from the module type definition.
                    if field_type === Any
                        # Determine the actual Wasm field type from the module
                        local _sf_wasm_fi = wasm_field_idx(info, field_idx)
                        local _sf_ct = ctx.mod.types[info.wasm_type_idx + 1]
                        local _sf_field_is_anyref = _sf_ct isa StructType &&
                            _sf_wasm_fi + 1 <= length(_sf_ct.fields) &&
                            _sf_ct.fields[_sf_wasm_fi + 1].valtype === AnyRef

                        # PURE-4150: Check if value is a Type reference (GlobalRef → Type value)
                        # compile_value(Type) emits i32.const 0, but field expects ref.
                        # Emit ref.null as placeholder (type objects can't be constructed in WasmGC).
                        if value_arg isa GlobalRef
                            try
                                actual_sf_val = getfield(value_arg.mod, value_arg.name)
                                is_type_value = actual_sf_val isa Type
                            catch; end
                        elseif value_arg isa Type
                            is_type_value = true
                        end

                        if is_type_value
                            if _sf_field_is_anyref
                                ref_null!(_sfsb, AnyRef)  # any heap type
                            else
                                ref_null!(_sfsb, ExternRef)
                            end
                        else
                            val_julia_type = infer_value_type(value_arg, ctx)
                            val_wasm_type = julia_to_wasm_type(val_julia_type)
                            if _sf_field_is_anyref
                                # Field is anyref — concrete/struct refs are already subtypes of anyref.
                                # Numerics need boxing. No extern_convert_any needed.
                                if val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                                    emit_numeric_to_anyref!(_sfsb, value_arg, val_wasm_type, ctx)
                                else
                                    # anyref, externref→any.convert_extern, or concrete ref (subtype of anyref)
                                    emit_value!(_sfsb, value_arg, ctx)
                                    if val_wasm_type === ExternRef
                                        any_convert_extern!(_sfsb)
                                    end
                                end
                            else
                                if val_julia_type === Any || val_wasm_type === ExternRef
                                    # PURE-3112/PURE-4150: Already externref — no conversion needed
                                    emit_value!(_sfsb, value_arg, ctx)
                                elseif val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                                    # PURE-4150: Numeric type → box then convert
                                    emit_numeric_to_externref!(_sfsb, value_arg, val_wasm_type, ctx)
                                else
                                    # Concrete/abstract ref → extern_convert_any
                                    emit_value!(_sfsb, value_arg, ctx)
                                    extern_convert_any!(_sfsb)
                                end
                            end
                        end
                    else
                        # PURE-6024: When value is nothing and field is ref-typed,
                        # compile_value(nothing) emits i32_const 0 which fails
                        # struct_set validation. Emit ref.null none instead.
                        if is_nothing_value(value_arg, ctx)
                            field_wasm = julia_to_wasm_type(field_type)
                            if field_wasm === I32 || field_wasm === I64 || field_wasm === F32 || field_wasm === F64
                                emit_value!(_sfsb, value_arg, ctx)
                            else
                                # Ref-typed field: ref.null none (bottom of internal ref hierarchy)
                                ref_null_none!(_sfsb)
                            end
                        else
                            emit_value!(_sfsb, value_arg, ctx)
                        end
                    end

                    struct_set!(_sfsb, info.wasm_type_idx, wasm_field_idx(info, field_idx), AnyRef)  # PURE-9024
                    # setfield! returns the value — use compile_value to match SSA return type
                    emit_value!(_sfsb, value_arg, ctx)
                    append_builder!(fb, _sfsb)
                    return append_builder!(b, fb)
                end
            end
        end

        # Handle setfield! on Base.RefValue (used for optimization sinks)
        # These are no-ops in Wasm since we don't need the sink pattern
        if obj_type <: Base.RefValue
            # Just push the value (setfield! returns the value)
            emit_value!(fb, value_arg, ctx)
            return append_builder!(b, fb)
        end
        # Fall through for other struct types - will hit error
    end

    # Core.donotdelete — compiler fence preventing DCE. No WASM output needed.
    # Arguments were already evaluated by the caller's IR; we just skip emitting.
    # Used by WASM import stubs (Canvas2D, etc.) to keep calls alive in optimized IR.
    if is_func(func, :donotdelete) || (func isa GlobalRef && func.name === :donotdelete && func.mod === Core)
        return append_builder!(b, fb)
    end

    # Special case for compilerbarrier - just pass through the value
    if is_func(func, :compilerbarrier)
        # compilerbarrier(kind, value) - first arg is a symbol, second is the value
        # We only want the value (second arg)
        if length(args) >= 2
            emit_value!(fb, args[2], ctx)
        end
        return append_builder!(b, fb)
    end

    # PURE-9063: typeof(x) — returns a $JlDataType struct ref from the type lookup table
    # If the type lookup table exists, returns (ref null $DataType) for full type object support.
    # Falls back to i32 typeId if no lookup table.
    if is_func(func, :typeof) && length(args) >= 1
        arg = args[1]
        arg_type = infer_value_type(arg, ctx)
        has_lookup = ctx.type_registry.type_lookup_global !== nothing

        local _tofb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        if has_lookup
            # PURE-9063: Return DataType struct ref from lookup table
            if arg_type !== nothing && isconcretetype(arg_type)
                # Statically known type — directly return its DataType global
                if haskey(ctx.type_registry.type_constant_globals, arg_type)
                    dt_global = ctx.type_registry.type_constant_globals[arg_type]
                    global_get!(_tofb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
                else
                    # Type not in globals — return null ref
                    dt_type_idx = get_datatype_type_idx(ctx.type_registry)
                    ref_null!(_tofb, Int64(dt_type_idx), ConcreteRef(UInt32(dt_type_idx), true))
                end
            else
                # Polymorphic value — extract typeId, look up in type table
                emit_value!(_tofb, arg, ctx)
                base_idx = ctx.type_registry.base_struct_idx
                if base_idx !== nothing
                    # Need a scratch local for the typeId. Use a convention:
                    # allocate one if needed, stored in ctx.
                    temp_local = _ensure_typeof_scratch_local!(ctx)
                    emit_typeof_struct_with_local!(_tofb, base_idx, ctx.type_registry, temp_local)
                else
                    dt_type_idx = get_datatype_type_idx(ctx.type_registry)
                    ref_null!(_tofb, Int64(dt_type_idx), ConcreteRef(UInt32(dt_type_idx), true))
                end
            end
        else
            # Fallback: return i32 typeId (pre-PURE-9063 behavior)
            if arg_type !== nothing && isconcretetype(arg_type)
                type_id = get_type_id(ctx.type_registry, arg_type)
                i32_const!(_tofb, Int64(type_id))
            else
                emit_value!(_tofb, arg, ctx)
                base_idx = ctx.type_registry.base_struct_idx
                if base_idx !== nothing
                    emit_typeof!(_tofb, base_idx)
                else
                    i32_const!(_tofb, 0)
                end
            end
        end
        append_builder!(fb, _tofb)
        return append_builder!(b, fb)
    end

    # Core.typeassert(x, T) — dart's CHECKED cast (census F4, march5; emitAsCheck,
    # types.dart:437-481: is-check, throw on mismatch). Statically-proven casts stay
    # pass-through (the common case — inference already narrowed). A runtime check
    # emits when the value is a GC ref and the target has a DFS classId range:
    # typeId ∈ [low, high] or throw TypeError. Values the discriminator can't see
    # (non-$JlBase refs) pass through UNCHECKED (under-check, never wrong-throw).
    if is_func(func, :typeassert)
        if length(args) >= 1
            local _ta_ty = emit_value!(fb, args[1], ctx)
            local _ta_target = length(args) >= 2 ? (args[2] isa Type ? args[2] :
                args[2] isa GlobalRef ? Core.eval(args[2].mod, args[2].name) : nothing) : nothing
            local _ta_static = get_ssa_type(ctx, args[1])
            if _ta_target isa Type && isconcretetype(_ta_target) &&
               !(_ta_static isa Type && _ta_static <: _ta_target) &&
               (_ta_ty === AnyRef || _ta_ty isa ConcreteRef || _ta_ty === StructRef) &&
               ctx.type_registry.base_struct_idx !== nothing
                local _ta_range = get_type_range(ctx.type_registry, _ta_target)
                if _ta_range !== nothing
                    local _ta_low, _ta_high = _ta_range
                    local _ta_base = ctx.type_registry.base_struct_idx
                    local _ta_tmp = allocate_local!(ctx, AnyRef)
                    local_tee!(fb, _ta_tmp)
                    ref_test!(fb, Int64(_ta_base), false)
                    if_!(fb)                                   # discriminable ($JlBase struct)
                    local_get!(fb, UInt32(_ta_tmp))
                    emit_typeof!(fb, _ta_base)
                    emit_classid_ranges!(fb, ctx, _ta_low, _ta_high,
                        ctx.type_registry.type_extra_ids === nothing ? Int32[] :
                        get(ctx.type_registry.type_extra_ids, _ta_target isa DataType && !isempty(_ta_target.parameters) ? _ta_target.name.wrapper : _ta_target, Int32[]))
                    num!(fb, Opcode.I32_EQZ)
                    if_!(fb)                                   # out of range → THROW
                    # null-payload throw (the union_bottom_throw_stub shape): TypeError
                    # carries 4 fields the check site can't populate; throw-PARITY is the
                    # contract (native throws TypeError, wasm throws tag 0 — both catchable)
                    ensure_exception_tag!(ctx.mod)
                    ref_null!(fb, AnyRef)
                    global_set!(fb, ensure_exception_global!(ctx.mod))
                    global_get!(fb, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(fb, ExternRef); throw_!(fb, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                    end_block!(fb)
                    end_block!(fb)
                    local_get!(fb, UInt32(_ta_tmp))            # the value survives the check
                end
            end
        end
        return append_builder!(b, fb)
    end

    # Special case for string/symbol equality/identity comparison (=== and !==)
    # Must be handled before generic argument pushing since strings/symbols are refs, not integers
    # Symbol uses same array<i32> representation as String, so ref.eq would fail (reference equality)
    if (is_func(func, :(===)) || is_func(func, :(!==))) && length(args) == 2
        arg1_type = infer_value_type(args[1], ctx)
        arg2_type = infer_value_type(args[2], ctx)
        if (arg1_type === String || arg1_type === Symbol) && (arg2_type === String || arg2_type === Symbol)
            local _seqb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            append_builder!(_seqb, compile_string_equal_b(args[1], args[2], ctx))
            if is_func(func, :(!==))
                # Negate the result for !==
                num!(_seqb, Opcode.I32_EQZ)
            end
            append_builder!(fb, _seqb)
            return append_builder!(b, fb)
        end

        # PURE-9063: typeof(x) === Type — compare DataType struct refs with ref.eq
        # Detect when one arg comes from typeof() and the other is a Type constant
        arg1_is_typeof = _is_typeof_ssa(args[1], ctx)
        arg2_is_typeof = _is_typeof_ssa(args[2], ctx)
        arg1_is_type_const = _resolve_type_const(args[1], ctx)
        arg2_is_type_const = _resolve_type_const(args[2], ctx)
        has_lookup = ctx.type_registry.type_lookup_global !== nothing

        if (arg1_is_typeof && arg2_is_type_const !== nothing) ||
           (arg2_is_typeof && arg1_is_type_const !== nothing)
            local _toeqb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            if has_lookup
                # PURE-9063: Both sides become DataType struct refs, compared with ref.eq
                if arg1_is_typeof
                    emit_value!(_toeqb, args[1], ctx)  # emits typeof → DataType ref
                    # Push the DataType global for the type constant
                    if haskey(ctx.type_registry.type_constant_globals, arg2_is_type_const)
                        dt_global = ctx.type_registry.type_constant_globals[arg2_is_type_const]
                        global_get!(_toeqb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
                    else
                        dt_type_idx = get_datatype_type_idx(ctx.type_registry)
                        ref_null!(_toeqb, Int64(dt_type_idx), ConcreteRef(UInt32(dt_type_idx), true))
                    end
                else
                    emit_value!(_toeqb, args[2], ctx)  # emits typeof → DataType ref
                    if haskey(ctx.type_registry.type_constant_globals, arg1_is_type_const)
                        dt_global = ctx.type_registry.type_constant_globals[arg1_is_type_const]
                        global_get!(_toeqb, dt_global, ctx.mod.globals[dt_global + 1].valtype)
                    else
                        dt_type_idx = get_datatype_type_idx(ctx.type_registry)
                        ref_null!(_toeqb, Int64(dt_type_idx), ConcreteRef(UInt32(dt_type_idx), true))
                    end
                end
                num!(_toeqb, Opcode.REF_EQ)
            else
                # Fallback: i32 typeId comparison (pre-PURE-9063)
                if arg1_is_typeof
                    emit_value!(_toeqb, args[1], ctx)
                    type_id = get_type_id(ctx.type_registry, arg2_is_type_const)
                    i32_const!(_toeqb, Int64(type_id))
                else
                    emit_value!(_toeqb, args[2], ctx)
                    type_id = get_type_id(ctx.type_registry, arg1_is_type_const)
                    i32_const!(_toeqb, Int64(type_id))
                end
                num!(_toeqb, Opcode.I32_EQ)
            end
            if is_func(func, :(!==))
                num!(_toeqb, Opcode.I32_EQZ)
            end
            append_builder!(fb, _toeqb)
            return append_builder!(b, fb)
        end

        # Special case: comparing ref type with nothing - use ref.is_null
        arg1_is_nothing = is_nothing_value(args[1], ctx)
        arg2_is_nothing = is_nothing_value(args[2], ctx)

        if (arg1_is_nothing && is_ref_type_or_union(arg2_type)) ||
           (arg2_is_nothing && is_ref_type_or_union(arg1_type))
            # Compile the non-nothing ref argument (typed channel)
            local _nv_b = _compile_value_b(arg1_is_nothing ? args[2] : args[1], ctx)
            local _nv_ty = isempty(_nv_b.v.stack) ? nothing : _nv_b.v.stack[end]
            # typed channel: numeric values can never be null — the emission's own type
            # answers (was a LOCAL_GET LEB decode + const first-byte scan + static re-guess).
            local is_numeric_val = _nv_ty === I32 || _nv_ty === I64 || _nv_ty === F32 || _nv_ty === F64
            local _neqb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            if is_numeric_val
                # Numeric value can never be nothing
                # === nothing → false (0), !== nothing → true (1)
                i32_const!(_neqb, is_func(func, :(!==)) ? 1 : 0)
                append_builder!(fb, _neqb)
                return append_builder!(b, fb)
            end
            append_builder!(_neqb, _nv_b)   # typed merge
            # ref.is_null checks if ref is null (returns i32 1 for null, 0 otherwise)
            ref_is_null!(_neqb)
            if is_func(func, :(!==))
                # Negate for !== (we want true when NOT null)
                num!(_neqb, Opcode.I32_EQZ)
            end
            append_builder!(fb, _neqb)
            return append_builder!(b, fb)
        end
    end

    # Determine argument type for opcode selection (do this BEFORE compiling args)
    arg_type = length(args) > 0 ? infer_value_type(args[1], ctx) : Int64
    is_32bit = arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
               arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
               (isprimitivetype(arg_type) && sizeof(arg_type) <= 4)
    is_128bit = arg_type === Int128 || arg_type === UInt128

    # PURE-046: If arg_type is Any/abstract but the intrinsic expects numeric operands,
    # the code is type-confused (externref being used as numeric). Emit unreachable
    # since we can't convert externref to i64 in Wasm.
    is_numeric_intrinsic = is_func(func, :eq_int) || is_func(func, :ne_int) ||
                           is_func(func, :slt_int) || is_func(func, :sle_int) ||
                           is_func(func, :ult_int) || is_func(func, :ule_int) ||
                           is_func(func, :add_int) || is_func(func, :sub_int) ||
                           is_func(func, :mul_int) ||
                           is_func(func, :not_int) || is_func(func, :or_int) ||
                           is_func(func, :xor_int) || is_func(func, :and_int)
    if is_numeric_intrinsic && (arg_type === Any ||
                                 (!isprimitivetype(arg_type) && !is_128bit && !(arg_type <: Integer)))
        # An Any/externref value used in a numeric intrinsic (boxing / type instability).
        # Loud reject — natively the op runs on the concrete value, so a silent trap diverges.
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "numeric intrinsic on a non-concrete (Any/boxed) operand — type instability"; idx=idx)
        return append_builder!(b, fb)
    end

    # PURE-324: Handle pointer arithmetic intrinsics BEFORE the generic arg pre-push.
    # add_ptr, sub_ptr, and pointerref push their own args (or trace back to string ref),
    # so they must NOT have args pre-pushed by the generic loop below.
    if func isa GlobalRef && func.name === :add_ptr
        local _apb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_apb, args[1], ctx)
        emit_value!(_apb, args[2], ctx)
        num!(_apb, Opcode.I64_ADD)
        append_builder!(fb, _apb)
        return append_builder!(b, fb)
    elseif func isa GlobalRef && func.name === :sub_ptr
        local _spb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_spb, args[1], ctx)
        emit_value!(_spb, args[2], ctx)
        num!(_spb, Opcode.I64_SUB)
        append_builder!(fb, _spb)
        return append_builder!(b, fb)
    elseif func isa GlobalRef && func.name === :pointerref
        ptr_arg = length(args) >= 1 ? args[1] : nothing
        str_info = ptr_arg !== nothing ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, idx_ssa = str_info
            local _prsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            string_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            # parity(M9): the classed string → its DATA array (the funnel adjusts)
            emit_value!(_prsb, str_ssa, ctx, ConcreteRef(UInt32(string_arr_type), true))
            emit_value!(_prsb, idx_ssa, ctx, I64)   # march14: the wrap-to-i32 follows — the value is an I64 index
            num!(_prsb, Opcode.I32_WRAP_I64)
            i32_const!(_prsb, 1)
            num!(_prsb, Opcode.I32_SUB)
            array_get!(_prsb, string_arr_type, I32; signed=false)
            append_builder!(fb, _prsb)
            return append_builder!(b, fb)
        end
        # P3 gap 450889a9cb7e: DataType layout-metadata loads
        # (datatype_layoutsize/arrayelem in inlined _unsetindex!) — the layout
        # pointer is compile-time host metadata; fold the whole load.
        local _pr_fold = _try_fold_layout_pointerref(ptr_arg, ctx)
        if _pr_fold !== nothing
            emit_value!(fb, _pr_fold, ctx)
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
            local _prvb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            _emit_backing_array!(_prvb, _pr_vec, ctx, _pr_arr_t)
            emit_value!(_prvb, ptr_arg, ctx)
            if length(args) >= 2 && !(args[2] isa Integer && args[2] == 1)
                emit_value!(_prvb, args[2], ctx)
                i64_const!(_prvb, Int64(1))
                num!(_prvb, Opcode.I64_SUB)
                num!(_prvb, Opcode.I64_ADD)
            end
            num!(_prvb, Opcode.I32_WRAP_I64)
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
            local _prwb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            _emit_backing_array!(_prwb, _pr_vec, ctx, _prw_arr)
            local_set!(_prwb, _prw_la)
            emit_value!(_prwb, ptr_arg, ctx)
            if length(args) >= 2 && !(args[2] isa Integer && args[2] == 1)
                emit_value!(_prwb, args[2], ctx)
                i64_const!(_prwb, Int64(1))
                num!(_prwb, Opcode.I64_SUB)
                i64_const!(_prwb, Int64(_prw_s))
                num!(_prwb, Opcode.I64_MUL)
                num!(_prwb, Opcode.I64_ADD)
            end
            num!(_prwb, Opcode.I32_WRAP_I64)
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
            local _prbb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # byte offset = ptr + (i-1)   (pointer target is 1 byte wide)
            emit_value!(_prbb, ptr_arg, ctx)
            if length(args) >= 2 && !(args[2] isa Integer && args[2] == 1)
                emit_value!(_prbb, args[2], ctx)
                i64_const!(_prbb, Int64(1))
                num!(_prbb, Opcode.I64_SUB)
                num!(_prbb, Opcode.I64_ADD)
            end
            num!(_prbb, Opcode.I32_WRAP_I64)
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
        # Same fake-pointer model: the pointer VALUE is the byte offset;
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
                local _prrb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_prrb, _prg_vec, ctx)
                ref_cast!(_prrb, Int64(_prr_info.wasm_type_idx), true)
                struct_get!(_prrb, _prr_info.wasm_type_idx, UInt32(1), julia_to_wasm_type(_prr_te))   # field 0 = typeId, 1 = x
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
                local _prgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_prgb, _prg_vec, ctx)
                local _prg_vinfo = ctx.type_registry.structs[_prg_vt]
                struct_get!(_prgb, _prg_vinfo.wasm_type_idx, UInt32(1), ConcreteRef(_prg_arr, true))
                ref_cast!(_prgb, Int64(_prg_arr), true)
                emit_value!(_prgb, ptr_arg, ctx)      # i64 byte offset
                if length(args) >= 2 && !(args[2] isa Integer && args[2] == 1)
                    emit_value!(_prgb, args[2], ctx)
                    i64_const!(_prgb, Int64(1))
                    num!(_prgb, Opcode.I64_SUB)
                    i64_const!(_prgb, Int64(sizeof(_prg_te)))
                    num!(_prgb, Opcode.I64_MUL)
                    num!(_prgb, Opcode.I64_ADD)
                end
                num!(_prgb, Opcode.I32_WRAP_I64)
                i32_const!(_prgb, Int64(trailing_zeros(sizeof(_prg_te))))
                num!(_prgb, Opcode.I32_SHR_U)
                array_get!(_prgb, _prg_arr, julia_to_wasm_type(_prg_te))
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
        let _prub = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            record_unsupported!(ctx, :unsupported_method, "un-lowerable popfirst!/array-mutation call shape"; idx=idx)
            unreachable!(_prub); append_builder!(fb, _prub)
        end
        ctx.last_stmt_was_stub = true  # PURE-908
        return append_builder!(b, fb)
    elseif func isa GlobalRef && func.name === :pointerset
        # P3 gap 450889a9cb7e: byte writes through Vector{UInt8} storage
        # pointers (Ryu digit emission). pointerset(ptr, value, i, align)
        # returns the pointer; consumers ignore it (fake i64 0).
        local _ps_ptr = length(args) >= 1 ? args[1] : nothing
        local _ps_vec = _ps_ptr !== nothing ? _trace_memmove_ptr(_ps_ptr, ctx) : nothing
        local _ps_vt = length(args) >= 2 ? infer_value_type(args[2], ctx) : nothing
        if _ps_vec !== nothing && (_ps_vt === UInt8 || _ps_vt === Int8)
            local _ps_arr_t = get_array_type!(ctx.mod, ctx.type_registry, UInt8)
            local _psb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            _emit_backing_array!(_psb, _ps_vec, ctx, _ps_arr_t)
            emit_value!(_psb, _ps_ptr, ctx, I64)   # march14: the wrap-to-i32 follows — the value is an I64 index
            num!(_psb, Opcode.I32_WRAP_I64)
            emit_value!(_psb, args[2], ctx)
            array_set!(_psb, _ps_arr_t, I32)
            i64_const!(_psb, 0)
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
                local _psrb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_psrb, _psg_vec, ctx)
                ref_cast!(_psrb, Int64(_psr_info.wasm_type_idx), true)
                emit_value!(_psrb, args[2], ctx)
                if _psr_te === Float64 && (_psg_tp === UInt64 || _psg_tp === Int64)
                    num!(_psrb, Opcode.F64_REINTERPRET_I64)
                elseif (_psr_te === UInt64 || _psr_te === Int64) && _psg_tp === Float64
                    num!(_psrb, Opcode.I64_REINTERPRET_F64)
                elseif _psr_te === Float32 && (_psg_tp === UInt32 || _psg_tp === Int32)
                    num!(_psrb, Opcode.F32_REINTERPRET_I32)
                elseif (_psr_te === UInt32 || _psr_te === Int32) && _psg_tp === Float32
                    num!(_psrb, Opcode.I32_REINTERPRET_F32)
                end
                struct_set!(_psrb, _psr_info.wasm_type_idx, UInt32(1), julia_to_wasm_type(_psr_te))
                i64_const!(_psrb, 0)
                append_builder!(fb, _psrb)
                return append_builder!(b, fb)
            end
        elseif _psg_vec !== nothing && length(args) >= 2
            local _psg_vt = infer_value_type(_psg_vec, ctx)
            local _psg_te = eltype(_psg_vt)
            if sizeof(_psg_te) == sizeof(_psg_tp) && sizeof(_psg_te) in (4, 8)
                local _psg_arr = get_array_type!(ctx.mod, ctx.type_registry, _psg_te)
                local _psgb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_value!(_psgb, _psg_vec, ctx)
                # A Memory/GenericMemory value IS the raw data array (no vector-struct
                # wrapper) — just cast it. A Vector is a {typeId, data-array, size}
                # struct → struct.get field 1 to reach the array. (The old code did an
                # unconditional `structs[_psg_vt]` direct lookup, which both crashed on
                # Memory and was ORDER-DEPENDENT — KeyError when a perturbed compile
                # order left _psg_vt unregistered. Register-or-guard fixes both.)
                local _psg_is_mem = _psg_vt isa DataType &&
                    _psg_vt.name.name in (:Memory, :GenericMemory, :MemoryRef, :GenericMemoryRef)
                if !_psg_is_mem
                    if !haskey(ctx.type_registry.structs, _psg_vt)
                        register_struct_type!(ctx.mod, ctx.type_registry, _psg_vt)
                    end
                    local _psg_vinfo = ctx.type_registry.structs[_psg_vt]
                    struct_get!(_psgb, _psg_vinfo.wasm_type_idx, UInt32(1), ConcreteRef(_psg_arr, true))
                end
                ref_cast!(_psgb, Int64(_psg_arr), true)
                emit_value!(_psgb, _ps_ptr, ctx)      # i64 byte offset
                if length(args) >= 3 && !(args[3] isa Integer && args[3] == 1)
                    emit_value!(_psgb, args[3], ctx)
                    i64_const!(_psgb, Int64(1))
                    num!(_psgb, Opcode.I64_SUB)
                    i64_const!(_psgb, Int64(sizeof(_psg_te)))
                    num!(_psgb, Opcode.I64_MUL)
                    num!(_psgb, Opcode.I64_ADD)
                end
                num!(_psgb, Opcode.I32_WRAP_I64)
                i32_const!(_psgb, Int64(trailing_zeros(sizeof(_psg_te))))
                num!(_psgb, Opcode.I32_SHR_U)
                emit_value!(_psgb, args[2], ctx)
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
                i64_const!(_psgb, 0)
                append_builder!(fb, _psgb)
                return append_builder!(b, fb)
            end
        end
        # P4-stdlib (Random digest!): CROSS-WIDTH store — Ptr{UInt64/32/16}
        # into Vector{UInt8} storage (SHA writes the bitlength into its byte
        # buffer). Emit little-endian byte-wise array.set stores.
        local _psw_vec = (_ps_ptr !== nothing && _psg_tp isa DataType &&
                          isprimitivetype(_psg_tp) && sizeof(_psg_tp) in (2, 4, 8)) ?
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
                local _pswb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                # array ref
                _emit_backing_array!(_pswb, _psw_vec, ctx, _psw_arr)
                local_set!(_pswb, _psw_la)
                # base byte index = ptr + (i-1)*s
                emit_value!(_pswb, _ps_ptr, ctx)
                if length(args) >= 3 && !(args[3] isa Integer && args[3] == 1)
                    emit_value!(_pswb, args[3], ctx)
                    i64_const!(_pswb, Int64(1))
                    num!(_pswb, Opcode.I64_SUB)
                    i64_const!(_pswb, Int64(_psw_s))
                    num!(_pswb, Opcode.I64_MUL)
                    num!(_pswb, Opcode.I64_ADD)
                end
                num!(_pswb, Opcode.I32_WRAP_I64)
                local_set!(_pswb, _psw_li)
                # value as i64 (extend 32-bit values)
                emit_value!(_pswb, args[2], ctx)
                local _psw_vw = julia_to_wasm_type(_psg_tp)
                _psw_vw === I32 && num!(_pswb, Opcode.I64_EXTEND_I32_U)
                _psw_vw === F64 && num!(_pswb, Opcode.I64_REINTERPRET_F64)
                local_set!(_pswb, _psw_lv)
                for _psw_k in 0:(_psw_s - 1)
                    local_get!(_pswb, _psw_la)
                    local_get!(_pswb, _psw_li)
                    if _psw_k > 0
                        i32_const!(_pswb, Int64(_psw_k))
                        num!(_pswb, Opcode.I32_ADD)
                    end
                    local_get!(_pswb, _psw_lv)
                    if _psw_k > 0
                        i64_const!(_pswb, Int64(8 * _psw_k))
                        num!(_pswb, Opcode.I64_SHR_U)
                    end
                    num!(_pswb, Opcode.I32_WRAP_I64)
                    array_set!(_pswb, _psw_arr, I32)
                end
                i64_const!(_pswb, 0)   # fake ptr return
                append_builder!(fb, _pswb)
                return append_builder!(b, fb)
            end
        end
        let _psub = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            record_unsupported!(ctx, :unsupported_method, "un-lowerable pushfirst!/array-mutation call shape"; idx=idx)
            unreachable!(_psub); append_builder!(fb, _psub)
        end
        ctx.last_stmt_was_stub = true  # PURE-908
        return append_builder!(b, fb)
    end

    # PURE-325: Int128 checked/div/rem arithmetic can't be compiled (struct args on
    # stack would mismatch i64 ops). Emit unreachable BEFORE pushing args.
    if (arg_type === Int128 || arg_type === UInt128) && func isa GlobalRef && func.name in
            (:checked_smul_int, :checked_umul_int, :checked_sadd_int, :checked_uadd_int,
             :checked_ssub_int, :checked_usub_int, :checked_sdiv_int, :checked_udiv_int,
             :checked_srem_int, :checked_urem_int,
             :sdiv_int, :udiv_int, :srem_int, :urem_int)
        # 128-bit checked/div/rem arithmetic unsupported. Loud reject (returns a value natively).
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "128-bit checked/division/remainder arithmetic (Int128/UInt128)"; idx=idx)
        return append_builder!(b, fb)
    end

    # Push arguments onto the stack (normal case)
    # Skip Type arguments (e.g., first arg of sext_int, zext_int, trunc_int, bitcast)
    # These are compile-time type parameters, not runtime values
    # EXCEPTION: For === and !== comparisons, Type values ARE runtime values
    # (they get compiled to i32 type tags and compared)
    # PURE-325: Skip arg-pushing for Core._expr — its handler manages its own args
    # PURE-905: Skip arg-pushing for cross-call candidates — the cross-call handler
    # at line ~20714 pushes args with type bridging. Pre-pushing here causes duplicate
    # args on the stack (e.g., setindex! gets 6 args instead of 3).
    # Cross-call candidates are GlobalRef functions found in the func_registry that
    # aren't handled by a specific earlier handler (intrinsics, ===, _expr, etc.).
    is_expr_call = is_func(func, :_expr)
    is_equality_comparison = is_func(func, :(===)) || is_func(func, :(!==))
    _skip_arg_prepush = is_expr_call
    if !_skip_arg_prepush && func isa GlobalRef && ctx.func_registry !== nothing &&
            !is_numeric_intrinsic && !is_equality_comparison
        _called_func = try getfield(func.mod, func.name) catch; nothing end
        if _called_func !== nothing
            _call_arg_types = tuple([infer_value_type(a, ctx) for a in args]...)
            _target = get_function(ctx.func_registry, _called_func, _call_arg_types)
            if _target === nothing && typeof(_called_func) <: Function && isconcretetype(typeof(_called_func))
                _target = get_function(ctx.func_registry, _called_func, (typeof(_called_func), _call_arg_types...))
            end
            _skip_arg_prepush = _target !== nothing
        end
    end
    # PURE-7012: Reorder muladd_float args for correct WASM stack order.
    # muladd_float(a, b, c) = a*b + c. With default push order [a, b, c],
    # WASM f64.mul takes top 2 (b,c) giving a+b*c (WRONG). Reorder to
    # [c, a, b] so f64.mul takes (a,b) then f64.add takes (c, a*b) = a*b+c.
    _push_args = args
    if (is_func(func, :muladd_float) || is_func(func, :fma_float)) && length(args) == 3
        _push_args = Any[args[3], args[1], args[2]]
    end
    for arg in _push_args
        if _skip_arg_prepush
            continue
        end
        # Check if this argument is a type reference
        is_type_arg = false
        if arg isa Type
            # Directly a Type value (Julia already resolved it)
            is_type_arg = true
        elseif arg isa GlobalRef
            try
                resolved = getfield(arg.mod, arg.name)
                if resolved isa Type
                    is_type_arg = true
                end
            catch
            end
        end
        # Skip Type args for intrinsics (e.g., sext_int(Int64, x))
        # but NOT for equality comparisons (e.g., x === SomeType)
        if is_type_arg && !is_equality_comparison
            continue
        end
        local _ia_ty = emit_value!(fb, arg, ctx)   # THE typed value channel
        # PURE-6027: Fix i32/i64 mismatch for numeric intrinsics — driven by the
        # emission's OWN type now (was the get_phi_edge_wasm_type re-guess).
        if is_numeric_intrinsic && !_is_externref_value(arg, ctx)
            _actual_wasm = _ia_ty
            if is_32bit && _actual_wasm === I64
                local _wb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                num!(_wb, Opcode.I32_WRAP_I64)
                append_builder!(fb, _wb)
            elseif !is_32bit && !is_128bit && _actual_wasm === I32
                local _wb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                num!(_wb, Opcode.I64_EXTEND_I32_S)
                append_builder!(fb, _wb)
            end
        end
        # P4-stdlib (Random hash_seed): unbox ANYREF-housed numeric args —
        # Any-returning callees (e.g. _foldl_impl) box numerics, and
        # Union{Nothing, UInt64}-style SSAs live in AnyRef locals; consuming
        # them raw in i64 arithmetic failed validation. Mirror of the
        # externref unbox below, minus any_convert_extern. Gated on the
        # ACTUAL local type (type-derived guesses say I64 for these unions).
        local _arg_anyref = false
        if !_is_externref_value(arg, ctx) && arg isa Core.SSAValue
            local _aa_li = get(ctx.ssa_locals, arg.id, nothing)
            _aa_li === nothing && (_aa_li = get(ctx.phi_locals, arg.id, nothing))
            if _aa_li !== nothing
                local _aa_off = _aa_li - ctx.n_params
                if _aa_off >= 0 && _aa_off < length(ctx.locals)
                    _arg_anyref = ctx.locals[_aa_off + 1] === AnyRef
                end
            end
        end
        # Also fire for the GENERIC arithmetic operators (+,-,*,div,rem,mod):
        # dynamic call sites with everything typed Any (e.g. `4 - %foldl` in
        # Random.hash_seed) default to the i64 opcodes but consume raw anyref.
        local _generic_arith = func isa GlobalRef &&
            func.name in (:+, :-, :*, :div, :rem, :mod)
        # parity(M10): when the SSA's REFINED type is already numeric (the join),
        # the LOAD (_narrow_generic_local!) is THE single unbox source — appending a
        # second unbox here double-converted. Only unbox when the type is truly erased.
        local _aa_refined_numeric = arg isa Core.SSAValue &&
            get(ctx.ssa_types, arg.id, Any) in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool)
        if (is_numeric_intrinsic || _generic_arith) && _arg_anyref && !_aa_refined_numeric
            local _aa_target = is_32bit ? I32 : I64
            local _ub = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            emit_classid_unbox!(_ub, ctx, _aa_target; nullable=true)
            append_builder!(fb, _ub)
            _boxed_operand_unboxed = true   # march13: function-scoped (the tail rebox keys on this)
        end
        # PURE-904: Unbox externref args for numeric intrinsics.
        # When a param/SSA has Wasm type externref but Julia IR uses it as
        # numeric (UInt32, Int64, etc.), unbox: any_convert_extern → ref.cast → struct.get
        if is_numeric_intrinsic && _is_externref_value(arg, ctx)
            target_wasm = is_32bit ? I32 : I64
            local _eub = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            any_convert_extern!(_eub)
            emit_classid_unbox!(_eub, ctx, target_wasm; nullable=true)
            append_builder!(fb, _eub)
        end
    end

    # PURE-046: For numeric intrinsics, verify the compiled args don't contain externref
    # (this catches cases where Julia type inference says Int64 but actual struct field is Any)
    if is_numeric_intrinsic && length(args) > 0
        # typed channel: a ref-typed emission feeding a numeric intrinsic = boxed/Any operand
        # (was a GC_PREFIX+STRUCT_GET byte probe + LEB decode + SSA-type re-check).
        local arg1_bytes, _p1_ty = compile_value_typed(args[1], ctx)
        if _p1_ty !== nothing && (_p1_ty === ExternRef || _p1_ty === AnyRef)
            local arg1_ssa = args[1]
            if arg1_ssa isa Core.SSAValue && get(ctx.ssa_types, arg1_ssa.id, nothing) === Any
                # numeric intrinsic on an Any-typed (boxed) operand — type instability. Loud reject.
                fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "numeric intrinsic on an Any-typed (boxed) operand — type instability"; idx=idx)
                return append_builder!(b, fb)
            end
        end
        # Also check for local_get of externref-typed local.
        # dart2wasm carries the type with the value rather than scanning bytes.
        if length(arg1_bytes) >= 2 && arg1_bytes[1] == Opcode.LOCAL_GET &&
           static_wasm_type(args[1], ctx) === ExternRef
            # externref-typed local fed to a numeric intrinsic — boxing. Loud reject.
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
            emit_unsupported_stub!(ctx, fb, :unsupported_method,
                "numeric intrinsic on an externref (boxed) local — type instability"; idx=idx)
            return append_builder!(b, fb)
        end
    end

    # Migration helper: emit ONE no-immediate numeric/cmp/conv op into `bytes`
    # via a scratch InstrBuilder (byte-identical to push!(bytes, op)).
    # march17: DIRECT emission — the one-instruction fragment wrapper was a
    # migration artifact; the fresh builder's empty stack underflowed by design
    # and the merge papered over it (7k+ harvest errors from this one idiom).
    _op1! = (op::UInt8) -> num!(fb, op)

    # parity(M11.2): THE INTRINSICS TABLE ROUTE (dart intrinsics.dart) — one
    # declarative lookup ahead of the arm chain. Covered (lhsT, rhsT, op) entries
    # emit here; the chain below keeps only what the table can't express
    # (128-bit, checked-overflow, unary, ===, conversions) and shrinks with M11.
    local _it_name = func isa GlobalRef ? func.name :
                     (func isa Core.IntrinsicFunction ? Symbol(func) : nothing)
    if _it_name !== nothing && !is_128bit
        # floats classify FIRST (is_32bit is true for Float32 — an INT-width flag)
        local _it_w = arg_type === Float64 ? F64 :
                      arg_type === Float32 ? F32 : (is_32bit ? I32 : I64)
        local _it_e = get(INTRINSIC_BINOPS, (_it_w, _it_w, _it_name), nothing)
        if _it_e !== nothing
            # Comparisons observe FULL register width — narrow pairs (Int8/Int16 on
            # i32) normalise first (sign-extend for signed/equality, mask for
            # unsigned; P2-batch13/14 semantics carried into the table route).
            if is_32bit && _it_name in (:slt_int, :sle_int, :eq_int, :ne_int)
                _emit_normalise_narrow_pair!(fb, ctx, true, _julia_int_width(arg_type, is_32bit))
            elseif is_32bit && _it_name in (:ult_int, :ule_int)
                _emit_normalise_narrow_pair!(fb, ctx, false, _julia_int_width(arg_type, is_32bit))
            end
            _op1!(_it_e.opcode)
            # march13 (the rebox link): a numeric intrinsic whose SSA LOCAL is
            # ref-typed (the boxed accumulator: Any-joined phi) must REBOX its
            # result — keyed on the REAL local type, never inference (the sink's
            # re-guess said anyref≡anyref while raw i64 sat on the stack).
            local _rbx_li = get(ctx.ssa_locals, idx, nothing)
            if _rbx_li !== nothing
                local _rbx_off = _rbx_li - ctx.n_params
                if _rbx_off >= 0 && _rbx_off < length(ctx.locals) && _wt_is_ref(ctx.locals[_rbx_off + 1]) &&
                   _it_e.result in (I32, I64, F32, F64)
                    emit_classid_box!(fb, ctx, _it_e.result,
                                      arg_type isa Type && isconcretetype(arg_type) ? arg_type : nothing)
                end
            end
            return append_builder!(b, fb)
        end
    end

    # Match intrinsics by name
    if is_func(func, :add_int)
        # (non-128-bit handled by THE intrinsics table route above)
        # 128-bit addition: (a_lo, a_hi) + (b_lo, b_hi)
        # Stack has: [a_struct, b_struct], need to produce result_struct
        # This is complex - need to extract fields, compute with carry, create new struct
        emit_int128_add!(fb, ctx, arg_type)

    elseif is_func(func, :sub_int)
        # (non-128-bit handled by THE intrinsics table route above)
        # 128-bit subtraction
        emit_int128_sub!(fb, ctx, arg_type)

    elseif is_func(func, :mul_int)
        # (non-128-bit handled by THE intrinsics table route above)
        # 128-bit multiplication (only need low 128 bits of result)
        emit_int128_mul!(fb, ctx, arg_type)

    # P2-batch13: NARROW-WIDTH checked add/sub/mul (Int8/UInt8/Int16/UInt16).
    # The register-width handlers below detect overflow with sign-bit tricks at
    # bit 31/63 — but a narrow op can never overflow the wide register, so the
    # flag stayed false and e.g. checked_abs(Int8(-128)) leaked 128 instead of
    # throwing OverflowError (lcm(Int8(-128), 1) divergent_throw family).
    # Compute in i32 on normalised inputs; flag = result fails the
    # sign/zero-extend round-trip at the JULIA width; value = wrapped result.
    elseif is_32bit && _julia_int_width(arg_type, is_32bit) < 32 &&
           (is_func(func, :checked_sadd_int) || is_func(func, :checked_uadd_int) ||
            is_func(func, :checked_ssub_int) || is_func(func, :checked_usub_int) ||
            is_func(func, :checked_smul_int) || is_func(func, :checked_umul_int))
        local _ncw = _julia_int_width(arg_type, is_32bit)
        local _nc_signed = is_func(func, :checked_sadd_int) || is_func(func, :checked_ssub_int) ||
                           is_func(func, :checked_smul_int)
        local _nc_op = (is_func(func, :checked_sadd_int) || is_func(func, :checked_uadd_int)) ? Opcode.I32_ADD :
                       (is_func(func, :checked_ssub_int) || is_func(func, :checked_usub_int)) ? Opcode.I32_SUB :
                       Opcode.I32_MUL
        _emit_normalise_narrow_pair!(fb, ctx, _nc_signed, _ncw)
        local _nc_r = UInt32(allocate_local!(ctx, I32))
        local _ncb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
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
        local _nc_tt = Tuple{Int32, Bool}
        if !haskey(ctx.type_registry.structs, _nc_tt)
            register_tuple_type!(ctx.mod, ctx.type_registry, _nc_tt)
        end
        local _nc_info = ctx.type_registry.structs[_nc_tt]
        i32_const!(_ncb, 0)   # typeId
        _nc_norm!()                                           # field 1: wrapped value
        _nc_norm!()                                           # flag: wrapped != raw
        local_get!(_ncb, _nc_r)
        num!(_ncb, Opcode.I32_NE)
        struct_new!(_ncb, _nc_info.wasm_type_idx)   # mod-resolved fields (march3)
        append_builder!(fb, _ncb)

    # PURE-9003: checked_smul_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    # Overflow detection via division check: if a != 0 && a != -1: overflow = result/a != b
    elseif is_func(func, :checked_smul_int) || is_func(func, :checked_umul_int)
        _compile_call_checked_mul(func, args, fb, ctx, is_128bit, is_32bit)

    # PURE-9003: checked_sadd_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    # Overflow detection: ((a ^ result) & (b ^ result)) has sign bit set
    elseif is_func(func, :checked_sadd_int) || is_func(func, :checked_uadd_int)
        if is_128bit
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
            emit_unsupported_stub!(ctx, fb, :unsupported_method,
                "128-bit checked addition (Int128/UInt128)"; idx=idx)
        else
            is_signed = is_func(func, :checked_sadd_int)
            local_type = is_32bit ? I32 : I64
            local_a = allocate_local!(ctx, local_type)
            local_b = allocate_local!(ctx, local_type)
            local_result = allocate_local!(ctx, local_type)
            local _caddb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)

            # Save b, save a, compute a+b, save result
            local_set!(_caddb, local_b)
            local_tee!(_caddb, local_a)
            local_get!(_caddb, local_b)
            num!(_caddb, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
            local_set!(_caddb, local_result)

            # Push typeId for Tuple struct (field 0 = typeId)
            i32_const!(_caddb, Int64(ensure_type_id!(ctx.type_registry, is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool})))  # real classId (M3)
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

            tuple_type = is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool}
            if !haskey(ctx.type_registry.structs, tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
            end
            tuple_info = ctx.type_registry.structs[tuple_type]
            struct_new!(_caddb, tuple_info.wasm_type_idx)   # mod-resolved fields (march3)
            append_builder!(fb, _caddb)
        end

    # PURE-9003: checked_ssub_int(a, b) -> Tuple{T, Bool} (result, overflow_flag)
    # Signed overflow: ((a ^ b) & (a ^ result)) has sign bit set
    elseif is_func(func, :checked_ssub_int) || is_func(func, :checked_usub_int)
        if is_128bit
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
            emit_unsupported_stub!(ctx, fb, :unsupported_method,
                "128-bit checked subtraction (Int128/UInt128)"; idx=idx)
        else
            is_signed = is_func(func, :checked_ssub_int)
            local_type = is_32bit ? I32 : I64
            local_a = allocate_local!(ctx, local_type)
            local_b = allocate_local!(ctx, local_type)
            local_result = allocate_local!(ctx, local_type)
            local _csubb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)

            # Save b, save a, compute a-b, save result
            local_set!(_csubb, local_b)
            local_tee!(_csubb, local_a)
            local_get!(_csubb, local_b)
            num!(_csubb, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
            local_set!(_csubb, local_result)

            # Push typeId for Tuple struct (field 0 = typeId)
            i32_const!(_csubb, Int64(ensure_type_id!(ctx.type_registry, is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool})))  # real classId (M3)
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

            tuple_type = is_32bit ? Tuple{Int32, Bool} : Tuple{Int64, Bool}
            if !haskey(ctx.type_registry.structs, tuple_type)
                register_tuple_type!(ctx.mod, ctx.type_registry, tuple_type)
            end
            tuple_info = ctx.type_registry.structs[tuple_type]
            struct_new!(_csubb, tuple_info.wasm_type_idx)   # mod-resolved fields (march3)
            append_builder!(fb, _csubb)
        end

    elseif is_func(func, :sdiv_int) || is_func(func, :checked_sdiv_int)
        local _dw = _julia_int_width(arg_type, is_32bit)
        is_32bit && _emit_normalise_narrow_pair!(fb, ctx, true, _dw)
        _emit_div_guard!(fb, ctx, is_32bit; check_overflow=true, julia_width=_dw)
        _op1!(is_32bit ? Opcode.I32_DIV_S : Opcode.I64_DIV_S)

    elseif is_func(func, :udiv_int) || is_func(func, :checked_udiv_int)
        is_32bit && _emit_normalise_narrow_pair!(fb, ctx, false, _julia_int_width(arg_type, is_32bit))
        _emit_div_guard!(fb, ctx, is_32bit)
        _op1!(is_32bit ? Opcode.I32_DIV_U : Opcode.I64_DIV_U)

    elseif is_func(func, :srem_int) || is_func(func, :checked_srem_int)
        is_32bit && _emit_normalise_narrow_pair!(fb, ctx, true, _julia_int_width(arg_type, is_32bit))
        _emit_div_guard!(fb, ctx, is_32bit)
        _op1!(is_32bit ? Opcode.I32_REM_S : Opcode.I64_REM_S)

    elseif is_func(func, :urem_int) || is_func(func, :checked_urem_int)
        is_32bit && _emit_normalise_narrow_pair!(fb, ctx, false, _julia_int_width(arg_type, is_32bit))
        _emit_div_guard!(fb, ctx, is_32bit)
        _op1!(is_32bit ? Opcode.I32_REM_U : Opcode.I64_REM_U)

    # Bitcast (reinterpret bits between types)
    elseif is_func(func, :bitcast)
        # Bitcast reinterprets bits between same-size types
        # Need to emit reinterpret instructions for float<->int conversions
        # args = [target_type, source_value]
        # Get the target type - it's the first actual argument (args[1] after extracting args[2:end])
        target_type_ref = length(args) >= 1 ? args[1] : nothing
        source_val = length(args) >= 2 ? args[2] : nothing

        # Determine target type from the GlobalRef or type literal
        target_type = if target_type_ref isa GlobalRef
            # Try to get the actual type from the GlobalRef
            if target_type_ref.name === :Int64 || target_type_ref.name === Symbol("Base.Int64")
                Int64
            elseif target_type_ref.name === :UInt64
                UInt64
            elseif target_type_ref.name === :Int32 || target_type_ref.name === Symbol("Base.Int32")
                Int32
            elseif target_type_ref.name === :UInt32
                UInt32
            elseif target_type_ref.name === :Float64
                Float64
            elseif target_type_ref.name === :Float32
                Float32
            elseif target_type_ref.name === :Int128
                Int128
            elseif target_type_ref.name === :UInt128
                UInt128
            else
                # Try to evaluate the GlobalRef
                try
                    getfield(target_type_ref.mod, target_type_ref.name)
                catch
                    Any
                end
            end
        elseif target_type_ref isa DataType
            target_type_ref
        else
            Any
        end

        # Determine source type
        source_type = source_val !== nothing ? infer_value_type(source_val, ctx) : Any

        # Emit appropriate reinterpret instruction if needed
        if source_type === Float64 && (target_type === Int64 || target_type === UInt64)
            _op1!(Opcode.I64_REINTERPRET_F64)
        elseif (source_type === Int64 || source_type === UInt64) && target_type === Float64
            _op1!(Opcode.F64_REINTERPRET_I64)
        elseif source_type === Float32 && (target_type === Int32 || target_type === UInt32)
            _op1!(Opcode.I32_REINTERPRET_F32)
        elseif (source_type === Int32 || source_type === UInt32) && target_type === Float32
            _op1!(Opcode.F32_REINTERPRET_I32)
        end
        # STACK-003: Char is stored as Julia's internal representation (UTF-8 packed UInt32),
        # so bitcast(UInt32, Char) and bitcast(Char, UInt32) are no-ops (same as Int32<->UInt32).
        # For other cases (Int64<->UInt64, Int32<->UInt32, Int128<->UInt128),
        # bitcast is a no-op in Wasm (same representation)

    elseif is_func(func, :neg_int)
        if is_128bit
            # 128-bit negation
            emit_int128_neg!(fb, ctx, arg_type)
        elseif is_32bit
            # For simplicity, emit: i32.const -1, i32.xor, i32.const 1, i32.add
            # Which is equivalent to: ~x + 1 = -x
                i32_const!(fb, -1)  # -1 in signed LEB128
                num!(fb, Opcode.I32_XOR)
                i32_const!(fb, 1)
                num!(fb, Opcode.I32_ADD)
        else
                i64_const!(fb, -1)  # -1 in signed LEB128
                num!(fb, Opcode.I64_XOR)
                i64_const!(fb, 1)
                num!(fb, Opcode.I64_ADD)
        end

    elseif is_func(func, :flipsign_int)
        _compile_call_flipsign(args, fb, ctx, is_128bit, is_32bit, arg_type)

    # Comparison operations
    # P2-batch13: ordered comparisons OBSERVE the full register width, so narrow
    # operands must be renormalised first (same policy as div/rem): an Int8 value
    # of -x can sit in the i32 register as 128, and slt_int(128, 0) = false flips
    # checked_abs's overflow test (lcm(Int8(-128), 1) returned 128 instead of
    # throwing). Signed → sign-extend in register; unsigned → mask.
    elseif is_func(func, :slt_int)  # signed less than
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_slt!(fb, ctx, arg_type)

    elseif is_func(func, :sle_int)  # signed less or equal
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_sle!(fb, ctx, arg_type)

    elseif is_func(func, :ult_int)  # unsigned less than
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_ult!(fb, ctx, arg_type)

    elseif is_func(func, :ule_int)  # unsigned less or equal
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_ule!(fb, ctx, arg_type)

    elseif is_func(func, :eq_int)
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_eq!(fb, ctx, arg_type)

    elseif is_func(func, :ne_int)
        # (non-128-bit handled by THE intrinsics table route above)
        emit_int128_ne!(fb, ctx, arg_type)

    # Float comparison operations
    elseif is_func(func, :gt_float)
        _op1!(arg_type === Float32 ? Opcode.F32_GT : Opcode.F64_GT)

    elseif is_func(func, :ge_float)
        _op1!(arg_type === Float32 ? Opcode.F32_GE : Opcode.F64_GE)

    # Identity comparison (=== for integers is same as ==, for floats use float eq)
    elseif is_func(func, :(===))
        _compile_call_egaleq(args, fb, ctx, is_128bit, is_32bit, arg_type)

    elseif is_func(func, :(!==))
        if is_128bit
            emit_int128_ne!(fb, ctx, arg_type)
        elseif arg_type === Float64
            local _nb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            num!(_nb, Opcode.F64_NE)
            append_builder!(fb, _nb)
        elseif arg_type === Float32
            local _nb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            num!(_nb, Opcode.F32_NE)
            append_builder!(fb, _nb)
        else
            local arg2_type_ne = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
            local arg1_is_ref_ne = is_ref_type_or_union(arg_type) && arg_type !== Nothing
            local arg2_is_ref_ne = is_ref_type_or_union(arg2_type_ne) && arg2_type_ne !== Nothing

            # Quick check: if one arg is ref-typed and other is Nothing (compiles to i32),
            # they can't be equal, so !== is always true. Drop both and return true.
            if (arg1_is_ref_ne && arg2_type_ne === Nothing) || (arg2_is_ref_ne && arg_type === Nothing)
                local _db = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                drop!(_db); drop!(_db); i32_const!(_db, 1)
                append_builder!(fb, _db)
                return append_builder!(b, fb)
            end

            # Special case: both args are Nothing-typed. Need to check actual Wasm representation.
            if arg_type === Nothing && arg2_type_ne === Nothing
                # typed channel: the emissions' own types (was first-byte checks + LEB decodes).
                local arg1_bytes_ne_chk, _a1ne_ty = compile_value_typed(args[1], ctx)
                local arg2_bytes_ne_chk, _a2ne_ty = compile_value_typed(args[2], ctx)
                local a1_ref_ne = _a1ne_ty !== nothing && _wt_is_ref(_a1ne_ty)
                local a2_ref_ne = _a2ne_ty !== nothing && _wt_is_ref(_a2ne_ty)
                # If Wasm types mismatch (one ref, one not), drop both and return true (not equal)
                if a1_ref_ne != a2_ref_ne
                    local _db = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    drop!(_db); drop!(_db); i32_const!(_db, 1)
                    append_builder!(fb, _db)
                    return append_builder!(b, fb)
                elseif a1_ref_ne && a2_ref_ne
                    # Both refs - use ref.eq then negate
                    local _rb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    num!(_rb, Opcode.REF_EQ)
                    num!(_rb, Opcode.I32_EQZ)
                    append_builder!(fb, _rb)
                    return append_builder!(b, fb)
                end
                # Both numeric - fall through to normal handling
            end

            # Check actual Wasm representation for Nothing-typed args
            local arg1_wasm_is_ref_ne = arg1_is_ref_ne
            local arg2_wasm_is_ref_ne = arg2_is_ref_ne
            local arg1_is_externref_ne = (arg_type === Any)
            local arg2_is_externref_ne = (arg2_type_ne === Any)
            # Check Wasm representation for any potentially mixed comparison
            if arg_type === Nothing || arg2_type_ne === Nothing || arg1_is_ref_ne || arg2_is_ref_ne
                # For Nothing-typed args, determine ref-ness from the inferred value type
                # (dart2wasm carries the type with the value rather than scanning bytes).
                # `nothing` is treated as a ref here (it may be ref.null when compared
                # against a ref-typed Nothing local).
                if length(args) >= 1 && arg_type === Nothing
                    arg1_wasm_is_ref_ne = is_nothing_value(args[1], ctx) ||
                                          _wt_is_ref(static_wasm_type(args[1], ctx))
                end
                if length(args) >= 2 && arg2_type_ne === Nothing
                    arg2_wasm_is_ref_ne = is_nothing_value(args[2], ctx) ||
                                          _wt_is_ref(static_wasm_type(args[2], ctx))
                end
            end
            # BOTH args must be ref types to use ref.eq
            if arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Convert externref → eqref before ref.eq (same pattern as === handler)
                local _neb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                if arg1_is_externref_ne && arg2_is_externref_ne
                    local tmp_ne = allocate_local!(ctx, EqRef)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_set!(_neb, tmp_ne)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_get!(_neb, tmp_ne)
                elseif arg1_is_externref_ne
                    local tmp_ne2 = allocate_local!(ctx, EqRef)
                    local_set!(_neb, tmp_ne2)
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                    local_get!(_neb, tmp_ne2)
                elseif arg2_is_externref_ne
                    any_convert_extern!(_neb)
                    ref_cast!(_neb, EqRef, true)
                end
                num!(_neb, Opcode.REF_EQ)
                num!(_neb, Opcode.I32_EQZ)  # Negate for !==
                append_builder!(fb, _neb)
            elseif arg1_wasm_is_ref_ne && !arg2_wasm_is_ref_ne
                # Comparing ref with non-ref: type mismatch, always not-equal
                local _db = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                drop!(_db); drop!(_db); i32_const!(_db, 1)
                append_builder!(fb, _db)
            elseif !arg1_wasm_is_ref_ne && arg2_wasm_is_ref_ne
                # Comparing non-ref with ref: type mismatch, always not-equal
                local _db = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                drop!(_db); drop!(_db); i32_const!(_db, 1)
                append_builder!(fb, _db)
            elseif !is_32bit && arg2_type_ne === Nothing
                # arg1 is 64-bit, arg2 is Nothing (i32). Extend i32 to i64 before comparing.
                local _xb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                num!(_xb, Opcode.I64_EXTEND_I32_S)
                num!(_xb, Opcode.I64_NE)
                append_builder!(fb, _xb)
            elseif is_32bit && arg_type === Nothing && !is_ref_type_or_union(arg2_type_ne)
                # arg1 is Nothing (i32), arg2 is 64-bit - mismatched types, always not-equal
                local _db = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                drop!(_db); drop!(_db); i32_const!(_db, 1)
                append_builder!(fb, _db)
            else
                local _eb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                num!(_eb, is_32bit ? Opcode.I32_NE : Opcode.I64_NE)
                append_builder!(fb, _eb)
            end
        end

    # Bitwise operations
    elseif is_func(func, :and_int)
        if is_128bit
            emit_int128_and!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_AND : Opcode.I64_AND)
        end

    elseif is_func(func, :or_int)
        if is_128bit
            emit_int128_or!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_OR : Opcode.I64_OR)
        end

    elseif is_func(func, :xor_int)
        if is_128bit
            emit_int128_xor!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_XOR : Opcode.I64_XOR)
        end

    elseif is_func(func, :not_int)
        # Check if this is boolean negation (result of comparison)
        # If so, use eqz instead of bitwise NOT
        if length(args) == 1 && is_boolean_value(args[1], ctx)
            # Boolean NOT: eqz turns 0->1, 1->0
            _op1!(Opcode.I32_EQZ)
        elseif is_128bit
            # F11: 128-bit bitwise NOT (xor each i64 limb with -1) — a single i64.xor on a
            # 128-bit struct value was invalid wasm (surfaced via count_zeros = count_ones(~x)).
            emit_int128_not!(fb, ctx, arg_type)
        else
            # Bitwise NOT: x xor -1
                if is_32bit
                    i32_const!(fb, -1)  # -1
                    num!(fb, Opcode.I32_XOR)
                else
                    i64_const!(fb, -1)  # -1
                    num!(fb, Opcode.I64_XOR)
                end
        end

    # Shift operations
    # Note: Wasm requires shift amount to have same type as value being shifted
    # Julia often uses Int64/UInt64 shift amounts even for Int32 values
    elseif is_func(func, :shl_int)
        if is_128bit
            # 128-bit left shift: stack has [x_struct, n_i64]
            emit_int128_shl!(fb, ctx, arg_type)
        else
            if length(args) >= 2
                shift_type = infer_value_type(args[2], ctx)
                if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                    # Saturating wrap of i64 amount → i32 (preserves over-shift magnitude)
                    _emit_wrap_shift_amount_saturating!(fb, ctx, _julia_int_width(arg_type, is_32bit))
                elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                    # Extend i32 shift amount to i64 (Wasm requires matching types)
                    _op1!(Opcode.I64_EXTEND_I32_S)
                end
            end
            _emit_shift_guarded!(fb, ctx, is_32bit, :shl;
                                 julia_width = _julia_int_width(arg_type, is_32bit),
                                 signed_narrow = arg_type isa Type && arg_type <: Signed)   # over-shift → 0 + narrow truncation
        end

    elseif is_func(func, :ashr_int)  # arithmetic shift right
        if is_128bit
            # 128-bit arithmetic right shift: stack has [x_struct, n_i64]. shl_int
            # and lshr_int already special-cased 128-bit; ashr_int did not, so signed
            # `Int128 >> n` fell through to the i64 guard and emitted `i64.shr_s` on
            # the struct ref (validation: expected i64, found (ref null $int128) —
            # WasmMakie TwicePrecision range/tick widemul path).
            emit_int128_ashr!(fb, ctx, arg_type)
        else
            if length(args) >= 2
                shift_type = infer_value_type(args[2], ctx)
                if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                    # Truncate i64 shift amount to i32
                    _op1!(Opcode.I32_WRAP_I64)
                elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                    # Extend i32 shift amount to i64 (Wasm requires matching types)
                    _op1!(Opcode.I64_EXTEND_I32_S)
                end
            end
            _emit_shift_guarded!(fb, ctx, is_32bit, :ashr;
                                 julia_width = _julia_int_width(arg_type, is_32bit))   # over-shift → sign-fill; narrow input sign-extended
        end

    elseif is_func(func, :lshr_int)  # logical shift right
        if is_128bit
            # 128-bit logical right shift: stack has [x_struct, n_i64]
            emit_int128_lshr!(fb, ctx, arg_type)
        else
            if length(args) >= 2
                shift_type = infer_value_type(args[2], ctx)
                if is_32bit && (shift_type === Int64 || shift_type === UInt64)
                    # Saturating wrap of i64 amount → i32 (preserves over-shift magnitude)
                    _emit_wrap_shift_amount_saturating!(fb, ctx, _julia_int_width(arg_type, is_32bit))
                elseif !is_32bit && shift_type !== Int64 && shift_type !== UInt64 && shift_type !== Int128 && shift_type !== UInt128
                    # Extend i32 shift amount to i64 (Wasm requires matching types)
                    _op1!(Opcode.I64_EXTEND_I32_S)
                end
            end
            _emit_shift_guarded!(fb, ctx, is_32bit, :lshr;
                                 julia_width = _julia_int_width(arg_type, is_32bit),
                                 signed_narrow = arg_type isa Type && arg_type <: Signed)   # over-shift → 0 (Julia semantics)
        end

    # Count leading/trailing zeros (used in Char conversion)
    elseif is_func(func, :ctlz_int)
        if is_128bit
            emit_int128_ctlz!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_CLZ : Opcode.I64_CLZ)
        end

    elseif is_func(func, :cttz_int)
        if is_128bit
            emit_int128_cttz!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_CTZ : Opcode.I64_CTZ)
        end

    # PURE-9004: Population count (number of set bits)
    elseif is_func(func, :ctpop_int)
        if is_128bit
            emit_int128_ctpop!(fb, ctx, arg_type)
        else
            _op1!(is_32bit ? Opcode.I32_POPCNT : Opcode.I64_POPCNT)
        end

    # Byte swap (used in Char ↔ codepoint conversion)
    # WebAssembly has no native bswap — implement with bit manipulation
    elseif is_func(func, :bswap_int)
        if is_128bit
            # 128-bit byte-swap is unsupported: the i64 reversal sequence below would run on a
            # struct value → invalid wasm. Loud-reject (sound trap / strict reject) like the
            # Int128 div/rem guard, rather than emitting an invalid module. (Full impl = reverse
            # 16 bytes = bswap each i64 limb + swap lo/hi; deferred — niche op.)
            emit_unsupported_stub!(ctx, fb, :unsupported_method,
                "128-bit byte-swap (Int128/UInt128)"; idx=idx)
            return append_builder!(b, fb)
        end
        # Allocate a scratch local to hold the input value (need it 4 times)
        scratch_local = length(ctx.locals) + ctx.n_params
        push!(ctx.locals, is_32bit ? I32 : I64)
        local _bswb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        # Store input value
        local_set!(_bswb, scratch_local)
        if is_32bit
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

    # Float operations
    elseif is_func(func, :add_float)
        _op1!(arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)

    elseif is_func(func, :sub_float)
        _op1!(arg_type === Float32 ? Opcode.F32_SUB : Opcode.F64_SUB)

    elseif is_func(func, :mul_float)
        _op1!(arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)

    elseif is_func(func, :div_float)
        _op1!(arg_type === Float32 ? Opcode.F32_DIV : Opcode.F64_DIV)

    elseif is_func(func, :neg_float)
        _op1!(arg_type === Float32 ? Opcode.F32_NEG : Opcode.F64_NEG)

    # Fused multiply-add: muladd_float(a, b, c) = a*b + c
    # WASM doesn't have native fma, so we implement as mul then add
    elseif is_func(func, :muladd_float)
        # Stack has [a, b, c], we need to compute a*b + c
        # First multiply a*b, then add c
        _op1!(arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)
        _op1!(arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)

    # fma_float: hardware FMA intrinsic. WASM has no scalar FMA instruction,
    # so emit mul+add. This branch is dead code when have_fma returns false,
    # but WASM requires structurally valid bytecode for both branches.
    elseif is_func(func, :fma_float)
        _op1!(arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)
        _op1!(arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)

    # have_fma: runtime FMA availability check. WASM has no scalar FMA,
    # so always return false. The type argument (Float64) is not on the stack.
    elseif is_func(func, :have_fma)
            i32_const!(fb, 0)  # false — WASM has no hardware FMA

    # Type conversions
    elseif is_func(func, :sext_int)  # Sign extend
        # sext_int(TargetType, value) - first arg is target type
        target_type_ref = args[1]
        # Extract actual type from GlobalRef if needed
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end
        local _sxb = _sub_builder(fb, ctx, "compile_call", 1)   # march17: consumes the operand
        if target_type === Int64 || target_type === UInt64
            # Extending to 64-bit - emit extend instruction
            # PURE-324: Skip extend if source is already i64 (e.g., from widened phi local)
            src_wasm = length(args) >= 2 ? get_phi_edge_wasm_type(args[2], ctx) : nothing
            if src_wasm !== I64
                # P2-batch13: a narrow source must be renormalised at its JULIA
                # width first — sext_int(Int64, x::Int8) with register value 128
                # otherwise widens to 128 instead of -128.
                local _sx_src = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
                if _sx_src === Int8
                    num!(_sxb, Opcode.I32_EXTEND8_S)
                elseif _sx_src === Int16
                    num!(_sxb, Opcode.I32_EXTEND16_S)
                elseif _sx_src === UInt8
                    i32_const!(_sxb, Int64(0xff)); num!(_sxb, Opcode.I32_AND)
                elseif _sx_src === UInt16
                    i32_const!(_sxb, Int64(0xffff)); num!(_sxb, Opcode.I32_AND)
                end
                num!(_sxb, Opcode.I64_EXTEND_I32_S)
            end
        elseif target_type === Int128 || target_type === UInt128
            # Sign-extending to 128-bit - create struct with (typeId, lo=value, hi=sign_extension)
            # The value is already on the stack (i64)
            source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64

            # If source is 32-bit, sign-extend to 64-bit first
            # PURE-325: Bool also maps to i32
            if source_type === Int32 || source_type === UInt32 || source_type === Int16 || source_type === Int8 || source_type === Bool
                num!(_sxb, Opcode.I64_EXTEND_I32_S)
            end

            # Now we have i64 on stack (the lo part)
            # Need to duplicate it to compute the hi part (sign extension)
            # Use a scratch local: store, load twice
            scratch_idx = ctx.n_params + length(ctx.locals)
            push!(ctx.locals, I64)

            # Store to scratch
            local_tee!(_sxb, scratch_idx)

            # Compute hi = lo >> 63 (arithmetic shift, gives 0 or -1)
            i64_const!(_sxb, 63)  # 63
            num!(_sxb, Opcode.I64_SHR_S)

            # Stack: [hi]. Need [typeId, lo, hi] for struct.new
            # Save hi to scratch, then push typeId, lo, hi
            scratch2_idx = ctx.n_params + length(ctx.locals)
            push!(ctx.locals, I64)
            local_set!(_sxb, scratch2_idx)

            # Stack: [] — push in struct field order: typeId, lo, hi
            i32_const!(_sxb, Int64(ensure_type_id!(ctx.type_registry, target_type)))  # real classId (M3)
            local_get!(_sxb, scratch_idx)
            local_get!(_sxb, scratch2_idx)

            # Create the 128-bit struct (typeId, lo, hi)
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
            struct_new!(_sxb, type_idx)   # mod-resolved fields (march3)
        end
        # If extending to 32-bit (Int32), it's a no-op since small types already map to i32
        append_builder!(fb, _sxb)

    elseif is_func(func, :zext_int)  # Zero extend
        # zext_int(TargetType, value) - first arg is target type
        target_type_ref = args[1]
        # Extract actual type from GlobalRef if needed
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end
        # P3 gap da22976c7cd6: sub-32-bit values live in i32 locals that can
        # carry dirty high bits (e.g. `0x01 + 0xff` leaves 0x100 — add_int does
        # not re-narrow). zext_int takes the BITS of the source width, so mask
        # to that width before extending (`x << Int64(0x01 + x)` shifted by 256
        # instead of 0 — over-shift gave 0 where native wraps the count).
        _zx_src = length(args) >= 2 ? infer_value_type(args[2], ctx) : nothing
        _zx_mask = (_zx_src === UInt8 || _zx_src === Int8) ? Int64(0xFF) :
                   (_zx_src === UInt16 || _zx_src === Int16) ? Int64(0xFFFF) : Int64(0)
        local _zxb = _sub_builder(fb, ctx, "compile_call", 1)   # march17: consumes the operand
        if target_type === Int64 || target_type === UInt64
            # Extending to 64-bit - emit extend instruction
            # PURE-324: Skip extend if source is already i64 (e.g., from widened phi local)
            src_wasm_z = length(args) >= 2 ? get_phi_edge_wasm_type(args[2], ctx) : nothing
            if src_wasm_z !== I64
                if _zx_mask != 0
                    i32_const!(_zxb, _zx_mask)
                    num!(_zxb, Opcode.I32_AND)
                end
                num!(_zxb, Opcode.I64_EXTEND_I32_U)
            end
        elseif target_type === Int32 || target_type === UInt32
            # Same-register-class extension: mask the source width so dirty
            # carry bits don't leak into the wider type
            if _zx_mask != 0 && get_phi_edge_wasm_type(args[2], ctx) !== I64
                i32_const!(_zxb, _zx_mask)
                num!(_zxb, Opcode.I32_AND)
            end
        elseif target_type === Int128 || target_type === UInt128
            # Extending to 128-bit - create struct with (typeId, lo=value, hi=0)
            # The value is already on the stack (i64), need to create 128-bit struct
            source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : UInt64

            # If source is 32-bit or narrower, extend to 64-bit first
            # PURE-325: Bool also maps to i32, so include it here
            # P3 da22976c7cd6: 8/16-bit sources also live in i32 — mask their
            # width (dirty carry bits) before the unsigned extend
            if _zx_mask != 0
                i32_const!(_zxb, _zx_mask)
                num!(_zxb, Opcode.I32_AND)
                num!(_zxb, Opcode.I64_EXTEND_I32_U)
            elseif source_type === Int32 || source_type === UInt32 || source_type === Bool
                num!(_zxb, Opcode.I64_EXTEND_I32_U)
            end

            # Now we have i64 on stack (the lo part)
            # Save lo to scratch, push typeId, restore lo, then push hi=0
            _zext_scratch = length(ctx.locals) + ctx.n_params
            push!(ctx.locals, I64)
            local_set!(_zxb, _zext_scratch)
            i32_const!(_zxb, Int64(ensure_type_id!(ctx.type_registry, target_type)))  # real classId (M3)
            local_get!(_zxb, _zext_scratch)
            # Push 0 for hi part
            i64_const!(_zxb, 0)

            # Create the 128-bit struct (typeId, lo, hi)
            type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
            struct_new!(_zxb, type_idx)   # mod-resolved fields (march3)
        end
        # If extending to 32-bit (UInt32/Int32), it's a no-op since small types already map to i32
        append_builder!(fb, _zxb)

    elseif is_func(func, :trunc_int)  # Truncate to smaller type
        # trunc_int(TargetType, value)
        target_type_ref = args[1]
        target_type = if target_type_ref isa GlobalRef
            try
                getfield(target_type_ref.mod, target_type_ref.name)
            catch
                target_type_ref
            end
        else
            target_type_ref
        end

        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64

        # Determine source and target WASM bit widths
        # PURE-324: Also check actual Wasm type — widened phi locals may be I64
        # even though Julia type says UInt32
        source_is_64bit = source_type === Int64 || source_type === UInt64 || source_type === Int
        if !source_is_64bit && length(args) >= 2
            src_wasm_t = get_phi_edge_wasm_type(args[2], ctx)
            if src_wasm_t === I64
                source_is_64bit = true
            end
        end
        target_is_32bit = target_type === Int32 || target_type === UInt32 ||
                          target_type === Int16 || target_type === UInt16 ||
                          target_type === Int8 || target_type === UInt8 ||
                          target_type === Bool || target_type === Char

        local _trb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        if source_type === Int128 || source_type === UInt128
            # Truncating from 128-bit - extract lo part
            source_type_idx = get_int128_type!(ctx.mod, ctx.type_registry, source_type)
            struct_get!(_trb, source_type_idx, UInt32(1), I64)  # Field 1 = lo (0=typeId)

            # Now we have i64, may need to wrap to i32
            if target_is_32bit
                num!(_trb, Opcode.I32_WRAP_I64)
            end
        elseif source_is_64bit && target_is_32bit
            # i64 to i32 truncation (includes UInt8, Int8, UInt16, Int16 targets)
            num!(_trb, Opcode.I32_WRAP_I64)
        end
        # i64 to i64 or i32 to i32 is a no-op
        # P3 gap 40da73b299fc (2nd find): sub-32-bit targets must be width-
        # normalised — bare i32.wrap_i64 is 32-bit truncation, so the
        # InexactError round-trip `zext(trunc(x)) == x` compared x against
        # itself and let out-of-range values through silently. Unsigned
        # targets zero-mask; signed targets sign-extend (so sext consumers
        # and the return marshalling read the right value directly).
        if target_type === Bool
            i32_const!(_trb, 1)
            num!(_trb, Opcode.I32_AND)
        elseif target_type === UInt8
            i32_const!(_trb, Int64(0xFF))
            num!(_trb, Opcode.I32_AND)
        elseif target_type === UInt16
            i32_const!(_trb, Int64(0xFFFF))
            num!(_trb, Opcode.I32_AND)
        elseif target_type === Int8
            num!(_trb, Opcode.I32_EXTEND8_S)
        elseif target_type === Int16
            num!(_trb, Opcode.I32_EXTEND16_S)
        end
        append_builder!(fb, _trb)

    elseif is_func(func, :sitofp)  # Signed int to float
        # sitofp(TargetType, value) - first arg is target type, second is value
        # Need to check: target float type (first arg) and source int type (second arg)
        target_type = args[1]  # Float32 or Float64
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
        source_is_32bit = source_type === Int32 || source_type === UInt32 || source_type === Char ||
                          source_type === Int16 || source_type === UInt16 || source_type === Int8 || source_type === UInt8 ||
                          (isprimitivetype(source_type) && sizeof(source_type) <= 4)

        # P3 gap 40ed488e7f10: narrow signed values can sit in the i32 register
        # zero-extended (e.g. a width-masked shl leaves Int8(-8) as 0xF8), but
        # the signed convert reads the full register. Sign-extend at the
        # consumer, same convention as the comparison normalisation.
        if source_type === Int8
            _op1!(Opcode.I32_EXTEND8_S)
        elseif source_type === Int16
            _op1!(Opcode.I32_EXTEND16_S)
        end

        if target_type === Float32
            _op1!(source_is_32bit ? Opcode.F32_CONVERT_I32_S : Opcode.F32_CONVERT_I64_S)
        else  # Float64
            _op1!(source_is_32bit ? Opcode.F64_CONVERT_I32_S : Opcode.F64_CONVERT_I64_S)
        end

    elseif is_func(func, :uitofp)  # Unsigned int to float
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Int64
        source_is_32bit = source_type === Int32 || source_type === UInt32 || source_type === Char ||
                          source_type === Int16 || source_type === UInt16 || source_type === Int8 || source_type === UInt8 ||
                          (isprimitivetype(source_type) && sizeof(source_type) <= 4)

        if target_type === Float32
            _op1!(source_is_32bit ? Opcode.F32_CONVERT_I32_U : Opcode.F32_CONVERT_I64_U)
        else  # Float64
            _op1!(source_is_32bit ? Opcode.F64_CONVERT_I32_U : Opcode.F64_CONVERT_I64_U)
        end

    elseif is_func(func, :fptosi)  # Float to signed int
        # fptosi(TargetType, value) - first arg is target type
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float64
        source_is_f32 = source_type === Float32

        if target_type === Int32 || target_type === Int16 || target_type === Int8
            _op1!(source_is_f32 ? Opcode.I32_TRUNC_F32_S : Opcode.I32_TRUNC_F64_S)
        else  # Int64
            _op1!(source_is_f32 ? Opcode.I64_TRUNC_F32_S : Opcode.I64_TRUNC_F64_S)
        end

    elseif is_func(func, :fptoui)  # Float to unsigned int
        target_type = args[1]
        source_type = length(args) >= 2 ? infer_value_type(args[2], ctx) : Float64
        source_is_f32 = source_type === Float32

        if target_type === UInt32 || target_type === UInt16 || target_type === UInt8
            _op1!(source_is_f32 ? Opcode.I32_TRUNC_F32_U : Opcode.I32_TRUNC_F64_U)
        else  # UInt64
            _op1!(source_is_f32 ? Opcode.I64_TRUNC_F32_U : Opcode.I64_TRUNC_F64_U)
        end

    elseif is_func(func, :fpext)  # Float precision extension
        _compile_call_fpext(args, fb, ctx)

    elseif is_func(func, :fptrunc)  # Float precision truncation (Float64 → Float32)
        # fptrunc(TargetType, value) - truncate Float64 to Float32
        # The source is always Float64, target is Float32
        _op1!(0xB6)  # f32.demote_f64

    elseif is_func(func, :trunc_llvm)  # Truncate float towards zero (returns float)
        _op1!(arg_type === Float32 ? Opcode.F32_TRUNC : Opcode.F64_TRUNC)

    elseif is_func(func, :floor_llvm)  # Floor float
        _op1!(arg_type === Float32 ? Opcode.F32_FLOOR : Opcode.F64_FLOOR)

    elseif is_func(func, :ceil_llvm)  # Ceil float
        _op1!(arg_type === Float32 ? Opcode.F32_CEIL : Opcode.F64_CEIL)

    elseif is_func(func, :rint_llvm)  # Round to nearest even
        _op1!(arg_type === Float32 ? Opcode.F32_NEAREST : Opcode.F64_NEAREST)

    elseif is_func(func, :abs_float)  # Absolute value of float
        _op1!(arg_type === Float32 ? Opcode.F32_ABS : Opcode.F64_ABS)

    elseif is_func(func, :sqrt_llvm) || is_func(func, :sqrt_llvm_fast)  # Square root
        _op1!(arg_type === Float32 ? Opcode.F32_SQRT : Opcode.F64_SQRT)

    elseif is_func(func, :copysign_float)  # Copy sign
        _op1!(arg_type === Float32 ? Opcode.F32_COPYSIGN : Opcode.F64_COPYSIGN)

    elseif is_func(func, :min_float) || is_func(func, :min_float_fast)
        _op1!(arg_type === Float32 ? Opcode.F32_MIN : Opcode.F64_MIN)

    elseif is_func(func, :max_float) || is_func(func, :max_float_fast)
        _op1!(arg_type === Float32 ? Opcode.F32_MAX : Opcode.F64_MAX)

    # High-level operators (fallback)
    elseif is_func(func, :+)
        if arg_type === Float32
            _op1!(Opcode.F32_ADD)
        elseif arg_type === Float64
            _op1!(Opcode.F64_ADD)
        elseif is_32bit
            _op1!(Opcode.I32_ADD)
        else
            _op1!(Opcode.I64_ADD)
        end

    elseif is_func(func, :-)
        if arg_type === Float32
            _op1!(Opcode.F32_SUB)
        elseif arg_type === Float64
            _op1!(Opcode.F64_SUB)
        elseif is_32bit
            _op1!(Opcode.I32_SUB)
        else
            _op1!(Opcode.I64_SUB)
        end

    elseif is_func(func, :*)
        # String/Symbol `*` is CONCATENATION, not arithmetic: the plain-call
        # path (closure-compiled bodies present concat as `call *`, not
        # invoke) fell into the numeric branch and emitted i64.mul on two
        # string refs — the E-003 island's fn#107 validation failure. Route
        # to the same compile_string_concat the invoke path uses; args were
        # pre-pushed, so rebuild the buffer (PURE-908 pattern).
        _conc1 = length(args) >= 1 ? infer_value_type(args[1], ctx) : Nothing
        _conc2 = length(args) >= 2 ? infer_value_type(args[2], ctx) : Nothing
        if length(args) == 2 && (_conc1 === String || _conc1 === Symbol) &&
           (_conc2 === String || _conc2 === Symbol)
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
            append_builder!(fb, compile_string_concat_b(args[1], args[2], ctx))
        elseif arg_type === Float32
            _op1!(Opcode.F32_MUL)
        elseif arg_type === Float64
            _op1!(Opcode.F64_MUL)
        elseif is_32bit
            _op1!(Opcode.I32_MUL)
        else
            _op1!(Opcode.I64_MUL)
        end

    # Compiler hints - these can be ignored
    elseif is_func(func, :compilerbarrier)
        # compilerbarrier(kind, value) - just return the value
        # The first arg is a symbol (like :type), second is the actual value
        # We only pushed the value (args[2]) since args[1] is a QuoteNode
        # The value is already on stack, nothing more to do

    # isa() - type checking for Union discrimination
    elseif is_func(func, :isa) && length(args) >= 2
        _compile_call_isa(args, fb, ctx)

    # throw() - compile to WASM throw instruction
    elseif func isa GlobalRef && func.name === :throw
        # PURE-1102: Emit throw instruction with tag 0 (our Julia exception tag)
        # PURE-9032: Stash exception value in $current_exn global before throwing.
        # The throw(obj) call has obj as args[1]. Compile it to anyref for stashing.
        ensure_exception_tag!(ctx.mod)
        exn_global = ensure_exception_global!(ctx.mod)
        local _thrb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        if length(args) >= 1
            # Check if the value is a QuoteNode containing a struct with undefined fields.
            # compile_value produces ref.null for such structs, but we need a non-null
            # struct instance for ref.test (isa checks) to work in catch blocks.
            local _throw_val = args[1]
            local _throw_raw = _throw_val isa QuoteNode ? _throw_val.value : _throw_val
            local _throw_used_default = false
            if !(_throw_raw isa Core.SSAValue) && !(_throw_raw isa Core.Argument) &&
               isstructtype(typeof(_throw_raw)) && !isa(_throw_raw, Function) && !isa(_throw_raw, Module)
                local _throw_T = typeof(_throw_raw)
                local _throw_has_undef = any(!isdefined(_throw_raw, fn) for fn in fieldnames(_throw_T))
                if _throw_has_undef
                    # Create a struct with default fields instead of ref.null
                    local _throw_info = register_struct_type!(ctx.mod, ctx.type_registry, _throw_T)
                    if _throw_info !== nothing
                        struct_new_default!(_thrb, _throw_info.wasm_type_idx)
                        global_set!(_thrb, exn_global)
                        _throw_used_default = true
                    end
                end
            end
            if !_throw_used_default
                # Compile the exception value normally
                local _exn_b = _compile_value_b(_throw_val, ctx)
                if !isempty(_exn_b.instrs)
                    append_builder!(_thrb, _exn_b)   # typed merge
                    global_set!(_thrb, exn_global)
                end
            end
        end
        global_get!(_thrb, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(_thrb, ExternRef); throw_!(_thrb, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
        append_builder!(fb, _thrb)

    # Base.add_ptr - pointer arithmetic (used in string operations)
    # In WasmGC, pointers are i64, so this is just i64 add
    elseif func isa GlobalRef && func.name === :add_ptr
        # add_ptr(ptr, offset) -> ptr + offset
        local _apb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_apb, args[1], ctx)
        emit_value!(_apb, args[2], ctx)
        num!(_apb, Opcode.I64_ADD)
        append_builder!(fb, _apb)

    # Base.sub_ptr - pointer subtraction
    elseif func isa GlobalRef && func.name === :sub_ptr
        # sub_ptr(ptr, offset) -> ptr - offset
        local _spb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        emit_value!(_spb, args[1], ctx)
        emit_value!(_spb, args[2], ctx)
        num!(_spb, Opcode.I64_SUB)
        append_builder!(fb, _spb)

    # Base.pointerref - read from pointer
    # In WasmGC, raw pointer ops don't exist. But for string byte access
    # (codeunit), we trace back to jl_string_ptr and emit array.get.
    elseif func isa GlobalRef && func.name === :pointerref
        # Try to trace pointer arg back to jl_string_ptr
        ptr_arg = length(args) >= 1 ? args[1] : nothing
        str_info = ptr_arg !== nothing ? _trace_string_ptr(ptr_arg, ctx.code_info.code) : nothing
        if str_info !== nothing
            str_ssa, idx_ssa = str_info
            # Emit: array.get string_array (index - 1)
            # String is array<i32> (type 1). Index is 1-based, array.get is 0-based.
            string_arr_type = get_string_array_type!(ctx.mod, ctx.type_registry)
            local _prsb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            # parity(M9): the classed string → its DATA array (the funnel adjusts)
            emit_value!(_prsb, str_ssa, ctx, ConcreteRef(UInt32(string_arr_type), true))
            emit_value!(_prsb, idx_ssa, ctx)
            # Convert i64 index to i32 and subtract 1 for 0-based
            num!(_prsb, Opcode.I32_WRAP_I64)
            i32_const!(_prsb, 1)
            num!(_prsb, Opcode.I32_SUB)
            # array.get_u on string type (packed i8 array)
            array_get!(_prsb, string_arr_type, I32; signed=false)
            append_builder!(fb, _prsb)
        else
            # PURE-908: Clear pre-pushed args
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
                record_unsupported!(ctx, :unsupported_method, "call shape with un-lowerable arguments (args cleared, trap)"; idx=idx)
            ctx.last_stmt_was_stub = true  # PURE-908
        end

    # Base.pointerset - write to pointer
    # WasmGC has no linear memory — pointer ops are invalid. Trap at runtime.
    elseif func isa GlobalRef && func.name === :pointerset
        # WasmGC has no linear memory — pointer write is unsupported. Loud reject.
        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "Base.pointerset (raw pointer write — no linear memory in WasmGC)"; idx=idx)

    # PURE-1102: throw_methoderror — emit throw (catchable) instead of unreachable
    elseif func isa GlobalRef && func.name === :throw_methoderror
        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
        ensure_exception_tag!(ctx.mod)
            global_get!(fb, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(fb, ExternRef); throw_!(fb, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
        ctx.last_stmt_was_stub = true  # PURE-908

    # PURE-4149: Core._svec_len(sv) — SimpleVector is an externref array in WasmGC.
    # _svec_len returns Int64 = array.len (converted from i32 to i64).
    # Match both GlobalRef(Core, :_svec_len) and the direct builtin function object.
    # Julia's type inference may resolve length(::SimpleVector) to the builtin directly.
    # PURE-6021: args[1] (svec array) is already pre-pushed by the generic loop above.
    elseif ((func isa GlobalRef && func.name === :_svec_len && func.mod === Core) || (isdefined(Core, :_svec_len) && func === Core._svec_len)) && length(args) == 1
        # P4-stdlib: fold against host-constant svecs (padding/typename.names)
        local _svl = _try_host_svec(args[1], ctx)
        if _svl isa Core.SimpleVector
            fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)   # discard pre-pushed placeholder
                i64_const!(fb, Int64(length(_svl)))
        else
                array_len!(fb)
                # array.len returns i32 but Julia expects Int64
                num!(fb, Opcode.I64_EXTEND_I32_U)
        end

    # PURE-4149: Core._svec_ref(sv, i) — get element from SimpleVector (externref array).
    # _svec_ref is 1-indexed in Julia, 0-indexed in Wasm → subtract 1.
    # Match both GlobalRef and direct builtin function object (same as _svec_len above).
    # PURE-6021: args[1] (svec array) and args[2] (i64 index) are already pre-pushed by
    # the generic loop above — do NOT call compile_value again here (causes double-push,
    # leaving 2 orphaned values on the stack → "values remaining" validation error).
    elseif ((func isa GlobalRef && func.name === :_svec_ref && func.mod === Core) || (isdefined(Core, :_svec_ref) && func === Core._svec_ref)) && length(args) == 2
        # Get element from externref array
        svec_type_info = register_struct_type!(ctx.mod, ctx.type_registry, Core.SimpleVector)
        svec_arr_idx = svec_type_info.wasm_type_idx
        local _svrb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        # Convert i64 Julia index to i32 Wasm index and subtract 1 for 0-indexing
        num!(_svrb, Opcode.I32_WRAP_I64)
        i32_const!(_svrb, 1)  # 1
        num!(_svrb, Opcode.I32_SUB)
        array_get!(_svrb, svec_arr_idx, ExternRef)
        # array.get returns externref but downstream ref.cast expects anyref
        # PURE-9064: Skip conversion when array elements are already anyref (JlType hierarchy)
        if ctx.type_registry.jl_type_idx === nothing
            any_convert_extern!(_svrb)
        end
        append_builder!(fb, _svrb)

    # Core._apply_iterate(Base.iterate, f, container...) — vector splatting.
    # Tuple splatting is resolved by Julia at code_typed time (no _apply_iterate).
    # Only runtime-length containers (Vector) produce this IR node.
    # Handle the common case: binary reduce over a single Vector{T}.
    elseif func isa GlobalRef && func.name === :_apply_iterate && func.mod === Core && length(args) >= 3
        # args layout: [Base.iterate, target_func, container1, ...]
        # Clear pre-pushed args (iterate ref, func ref, container ref are on stack)
        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
        target_func = args[2]  # The function to apply (e.g., Base.:+)
        container_arg = args[3]  # The container to iterate

        # Get container Julia type
        container_type = infer_value_type(container_arg, ctx)

        # Handle Core.tuple target (kwarg dispatch pattern):
        # _apply_iterate(iterate, Core.tuple, vec_of_symbols) converts remaining
        # unknown kwargs into a tuple. The subsequent isa(result, Tuple{}) check
        # determines whether to proceed or call kwerr.
        # Emit struct.new with Tuple{}'s typeId — the isa check uses typeId
        # comparison (shared wasm type at base struct index), so the typeId must
        # match Tuple{}'s assigned ID for the check to pass correctly.
        target_is_tuple = (target_func isa GlobalRef && target_func.name === :tuple && target_func.mod === Core)

        if target_is_tuple
            # Kwarg dispatch pattern: _apply_iterate(iterate, Core.tuple, unknown_kwargs_vec)
            # produces a Tuple{Vararg{Symbol}} which is checked by isa(result, Tuple{}).
            # The isa check uses ref.test against Tuple{}'s concrete WasmGC type,
            # so we must emit a struct.new of the actual Tuple{} type (not base struct).
            info = register_tuple_type!(ctx.mod, ctx.type_registry, Tuple{})
            tuple_empty_tid = ensure_type_id!(ctx.type_registry, Tuple{})
            # Emit: i32.const $typeId; struct.new $Tuple_empty_type_idx
                i32_const!(fb, Int64(tuple_empty_tid))
                struct_new!(fb, info.wasm_type_idx)   # mod-resolved fields (march3)
        # Single-container Vector{T} splatting: vector-literal collect (`[v...]`)
        # or a known binary-reduce intrinsic.
        elseif length(args) == 3 && container_type <: Vector && container_type isa DataType
            elem_type = eltype(container_type)
            target_name = target_func isa GlobalRef ? target_func.name : nothing
            target_mod  = target_func isa GlobalRef ? target_func.mod  : nothing

            if target_name === :vect && target_mod === Base
                # `[v...]` ⇒ Base.vect(v...) ⇒ a shallow copy of the vector.
                _emit_apply_iterate_vect!(fb, container_arg, container_type, ctx)
            else
                # Resolve target function to a WASM opcode for binary reduce
                reduce_op = _get_binary_reduce_opcode(target_name, elem_type)
                if reduce_op !== nothing
                    # Emit inline reduce loop: acc = v[1]; for i in 2:length(v), acc = op(acc, v[i])
                    _emit_apply_iterate_reduce!(fb, container_arg, container_type, elem_type, reduce_op, ctx)
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

    # Core.svec — genuinely unsupported. Loud reject (returns a SimpleVector natively).
    elseif func isa GlobalRef && func.name === :svec && func.mod === Core
        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
        emit_unsupported_stub!(ctx, fb, :unsupported_method,
            "Core.svec (SimpleVector construction)"; idx=idx)

    # PURE-604/605: Core builtins re-exported through Base (isdefined, getfield, setfield!).
    # These are dead code paths from dynamic dispatch — trap silently in WasmGC.
    elseif func isa GlobalRef && func.name in (:isdefined, :getfield, :setfield!) && func.mod in (Core, Base)
        # PURE-908: Clear pre-pushed args
        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
        # P4-stdlib (Statistics median): getfield on a compile-time CONSTANT
        # receiver (QuoteNode) — e.g. getfield(typename(UInt64), :flags) from
        # inlined isbits-style predicates in sort. Host-evaluate; emit the
        # constant when it has a primitive/string representation. (The :names
        # svec form stays trapped — no constant emission for SimpleVector.)
        local _gfc_done = false
        if func.name === :getfield && length(args) == 2 && args[1] isa QuoteNode
            local _gfc_fld = args[2] isa QuoteNode ? args[2].value : args[2]
            if _gfc_fld isa Symbol
                local _gfc_val = try getfield(args[1].value, _gfc_fld) catch; nothing end
                if _gfc_val isa Union{Integer, Bool, Char, Float32, Float64, String, Symbol} &&
                   !(_gfc_val isa Union{Int128, UInt128, BigInt})
                    emit_value!(fb, _gfc_val, ctx)
                    _gfc_done = true
                end
            end
        end
        # P4-stdlib: constant-receiver getfield yielding a SimpleVector
        # (typename(T).names) — emit a benign null placeholder (a stub
        # dead-codes the rest of the block); consumers fold against the
        # host value via _try_host_svec.
        if !_gfc_done && func.name === :getfield && length(args) == 2 && args[1] isa QuoteNode
            local _gfc_fld2 = args[2] isa QuoteNode ? args[2].value : args[2]
            if _gfc_fld2 isa Symbol
                local _gfc_v2 = try getfield(args[1].value, _gfc_fld2) catch; nothing end
                if _gfc_v2 isa Core.SimpleVector
                        ref_null!(fb, ArrayRef)
                    _gfc_done = true
                end
            end
        end
        # parity(M10b): setfield!(%box::Core.Box, :contents, v) — WRITE the shared cell
        # (dart Context variable write); the value wraps to anyref through the funnel.
        if !_gfc_done && func.name === :setfield! && length(args) == 3 &&
           args[1] isa Core.SSAValue && ((args[2] isa QuoteNode && args[2].value === :contents) || args[2] === :contents) &&
           (args[1] isa Core.SSAValue && get(ctx.ssa_types, args[1].id, Any) === Core.Box)
            local _bxs_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            local _bxs_ty = emit_value!(_bxs_ib, args[1], ctx)
            local _bxs_idx = _bxs_ty isa ConcreteRef ? _bxs_ty.type_idx :
                             UInt32(get_box_type!(ctx.mod, ctx.type_registry, AnyRef))
            !(_bxs_ty isa ConcreteRef) && ref_cast!(_bxs_ib, Int64(_bxs_idx), false)
            local _bxs_ft = ctx.mod.types[_bxs_idx + 1].fields[2].valtype
            emit_value!(_bxs_ib, args[3], ctx, _bxs_ft)
            struct_set!(_bxs_ib, _bxs_idx, UInt32(1), _bxs_ft)
            # setfield! evaluates to the VALUE; re-emit it (dup semantics via re-eval)
            emit_value!(_bxs_ib, args[3], ctx, _bxs_ft)
            append_builder!(fb, _bxs_ib)
            _gfc_done = true
        end
        # parity(M10b): isdefined(%box::Core.Box, :contents) — the shared cell's
        # defined-check = a null test on the anyref contents.
        if !_gfc_done && func.name === :isdefined && length(args) == 2 &&
           args[1] isa Core.SSAValue && ((args[2] isa QuoteNode && args[2].value === :contents) || args[2] === :contents) &&
           (args[1] isa Core.SSAValue && get(ctx.ssa_types, args[1].id, Any) === Core.Box)
            local _bxd_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            local _bxd_ty = emit_value!(_bxd_ib, args[1], ctx)
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
        # parity(M10b): getfield(%box::Core.Box, :contents) — read the SHARED cell
        # (dart Context variable read). The cell is the F3 anyref box struct.
        if !_gfc_done && func.name === :getfield && length(args) == 2 &&
           args[1] isa Core.SSAValue && ((args[2] isa QuoteNode && args[2].value === :contents) || args[2] === :contents) &&
           (args[1] isa Core.SSAValue && get(ctx.ssa_types, args[1].id, Any) === Core.Box)
            local _bx_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
            local _bx_ty = emit_value!(_bx_ib, args[1], ctx)
            local _bx_idx = _bx_ty isa ConcreteRef ? _bx_ty.type_idx :
                            UInt32(get_box_type!(ctx.mod, ctx.type_registry, AnyRef))
            !( _bx_ty isa ConcreteRef) && ref_cast!(_bx_ib, Int64(_bx_idx), false)
            local _bx_ft = ctx.mod.types[_bx_idx + 1].fields[2].valtype
            struct_get!(_bx_ib, _bx_idx, UInt32(1), _bx_ft)
            append_builder!(fb, _bx_ib)
            _gfc_done = true
        end
        # parity(M10b): getfield(closure_value, :boxfield) — the box was born in a
        # callee; read the registered struct field here (the ONE shared cell).
        if !_gfc_done && func.name === :getfield && length(args) == 2 &&
           args[1] isa Core.SSAValue && ((args[2] isa QuoteNode && args[2].value isa Symbol) || args[2] isa Symbol)
            local _gfb_T = args[1] isa Core.SSAValue ? get(ctx.ssa_types, args[1].id, Any) : Any
            if _gfb_T isa DataType && isstructtype(_gfb_T) &&
               haskey(ctx.type_registry.structs, _gfb_T)
                local _gfb_info = ctx.type_registry.structs[_gfb_T]
                local _gfb_fld = args[2] isa QuoteNode ? args[2].value : args[2]
                local _gfb_fi = findfirst(==(_gfb_fld), fieldnames(_gfb_T))
                if _gfb_fi !== nothing
                    # the wasm field index comes from the REGISTERED layout's offset
                    # (1 = classId header present, 0 = headerless) — never hardcoded.
                    local _gfb_wfi = _gfb_fi - 1 + Int(_gfb_info.field_offset)
                    local _gfb_flds = ctx.mod.types[_gfb_info.wasm_type_idx + 1].fields
                    if _gfb_wfi >= 0 && _gfb_wfi < length(_gfb_flds)
                        local _gfb_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
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
        if !_gfc_done
                record_unsupported!(ctx, :unsupported_method, "getfield call shape not lowerable"; idx=idx)
            ctx.last_stmt_was_stub = true  # PURE-908
        end

    # PURE-604: Symbol(x) — in WasmGC, Symbol IS String (both are byte arrays).
    # The argument is already compiled as a string array — just pass through.
    elseif is_func(func, :Symbol) && func isa GlobalRef && length(args) == 1
        _compile_call_symbol(args, fb, ctx)

    # Cross-function call via GlobalRef (dynamic dispatch when Julia can't specialize)
    # PURE-325: Skip cross-call lookup for Core._expr — it's a builtin that has a
    # special handler below (line ~19900). Without this guard, get_function returns
    # nothing (builtins aren't in the function registry) and emits unreachable.
    elseif func isa GlobalRef && ctx.func_registry !== nothing && !is_func(func, :_expr)
        # Try to find this function in our registry
        called_func = try
            getfield(func.mod, func.name)
        catch
            nothing
        end

        # Fallback: if getfield failed (e.g., GlobalRef from anonymous module),
        # try looking up by name string in func_registry. This handles import stubs
        # like compiled_get_prop_string_id referenced from re-exported modules.
        # WASMMAKIE E-003: the name match MUST also match arity — with broad
        # registries (65 canvas ops incl. names like width/height/fill/stroke/
        # rect/save/translate) the bare-name redirect hijacked unrelated
        # same-named calls and emitted arity-mismatched call instructions
        # (validation: 'not enough arguments on the stack').
        if called_func === nothing
            target_by_name = get_function(ctx.func_registry, string(func.name))
            if target_by_name !== nothing && length(target_by_name.arg_types) == length(args)
                called_func = target_by_name.func_ref
            end
        end

        if called_func !== nothing
            # Infer argument types BEFORE pushing (need for type checking)
            call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)

            # 1f6e77980994: dynamic-dispatch sites must not pick a same-name
            # overload with an incompatible return (i32 getindex for a ref site)
            _exp_ret_c = get(ctx.ssa_types, idx, nothing)
            target_info = get_function(ctx.func_registry, called_func, call_arg_types;
                                       expected_return=_exp_ret_c isa Type ? _exp_ret_c : nothing)

            # PURE-320: Closure/kwarg functions are registered with self-type prepended
            if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                closure_arg_types = (typeof(called_func), call_arg_types...)
                target_info = get_function(ctx.func_registry, called_func, closure_arg_types;
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
                    local _cw_arg_ty = isempty(_cab.v.stack) ? nothing : _cab.v.stack[end]
                    local _cab_merged = false
                    # Check if arg type matches expected param type (the merge happens
                    # AFTER the phantom/numeric-replacement decisions — the pop! surgeries
                    # are gone; we just don't merge a replaced arg)
                    if arg_idx <= length(target_info.arg_types)
                        expected_julia_type = target_info.arg_types[arg_idx]
                        expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                        actual_julia_type = call_arg_types[arg_idx]
                        actual_wasm = get_concrete_wasm_type(actual_julia_type, ctx.mod, ctx.type_registry)

                        # PURE-901/4155: Handle Nothing→ref conversion BEFORE type bridging.
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
                                # Update actual_wasm so bridging logic below is a no-op
                                actual_wasm = expected_wasm
                            end
                        end

                        # march5 F8 (twin of the invoke collapse): the bridging chain IS
                        # one convertType call (dart code_generator.dart:879). The tracked
                        # emission type refines `actual`; replaced arms incl. the phantom
                        # handled above.
                        _cw_arg_ty isa WasmValType && actual_julia_type !== Nothing && (actual_wasm = _cw_arg_ty)
                        _cab_merged || (append_builder!(fb, _cab); _cab_merged = true)
                        convert_type!(fb, actual_wasm, expected_wasm, ctx;
                                      from_julia=(actual_julia_type isa Type && isconcretetype(actual_julia_type)) ? actual_julia_type : nothing)
                        end
             end
                # Cross-function call - emit call instruction with target index
                local _xcb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                call!(_xcb, target_info.wasm_idx, WasmValType[], WasmValType[])
                # PURE-3111: If the callee returns Union{} (Bottom), it always throws.
                # The Wasm func type has no result, so code after is unreachable.
                # Skip type bridge and emit unreachable to prevent stack underflow.
                if target_info.return_type === Union{}
                    unreachable!(_xcb)  # structural trap (dart-legit dead path)
                    ctx.last_stmt_was_stub = true
                # PURE-900: Bridge type gap between function's Wasm return type
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
                            # PURE-908: Function returns externref, local expects anyref
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
                            # 1f6e77980994: callee returns a numeric but the SSA local is a
                            # ref class (dynamic Any-typed call site, e.g. getindex on a bond
                            # Vector resolving to an i32-returning overload) — box the RESULT
                            # (on the stack) exactly like the PURE-9022 arg path via the one emitter.
                            # The box struct is already a structref subtype — no cast needed for StructRef.
                            emit_classid_box!(_xcb, ctx, ret_wasm, nothing)
                        end
                    end
                end
                append_builder!(fb, _xcb)
            else
                # P4-stdlib (Random hash_seed): dynamic ==/!= on BOXED operands
                # (Any-typed foldl results in anyref locals) is LIVE code — the
                # unreachable below dead-coded the loop-exit condition. Unbox
                # both sides as i64 boxes and compare; a non-i64 box traps
                # LOUD on the cast (correct-or-loud) instead of silently.
                local _dyneq_ok = false
                if (func.name === :(==) || func.name === :!=) && length(args) == 2
                    local _dq_all_ref = true
                    for _dq_a in args
                        local _dq_is = false
                        if _dq_a isa Core.SSAValue
                            local _dq_li = get(ctx.ssa_locals, _dq_a.id, nothing)
                            _dq_li === nothing && (_dq_li = get(ctx.phi_locals, _dq_a.id, nothing))
                            if _dq_li !== nothing
                                local _dq_off = _dq_li - ctx.n_params
                                if _dq_off >= 0 && _dq_off < length(ctx.locals)
                                    _dq_is = ctx.locals[_dq_off + 1] === AnyRef
                                end
                            end
                        end
                        _dq_is || (_dq_all_ref = false)
                    end
                    if _dq_all_ref
                        fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)
                        local _dqb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                        for _dq_a in args
                            emit_value!(_dqb, _dq_a, ctx)
                            # unbox each boxed-i64 operand via THE single consumer, then compare
                            emit_classid_unbox!(_dqb, ctx, I64; nullable=true)
                        end
                        num!(_dqb, Opcode.I64_EQ)
                        func.name === :!= && num!(_dqb, Opcode.I32_EQZ)
                        # The result SSA is Any-typed (anyref local) — box the
                        # i32 Bool; compile_condition_to_i32 unboxes at use.
                        local _dq_dst = get(ctx.ssa_locals, idx, nothing)
                        if _dq_dst !== nothing
                            local _dq_doff = _dq_dst - ctx.n_params
                            local _dq_lt = _dq_doff >= 0 && _dq_doff < length(ctx.locals) ?
                                ctx.locals[_dq_doff + 1] : nothing
                            if _dq_lt === AnyRef || _dq_lt isa ConcreteRef || _dq_lt === StructRef
                                # Box the Bool === result for the ref-typed dest via THE single emitter,
                                # carrying Bool's REAL classId (was a hardcoded typeId 0 = non-discriminable).
                                emit_classid_box!(_dqb, ctx, I32, Bool)
                            end
                        end
                        append_builder!(fb, _dqb)
                        _dyneq_ok = true
                    end
                end
                # parity(M10b): convert(T, x) where x's REFINED type is already T —
                # identity (dart: no conversion node when types agree). The join can
                # refine an erased Any to T after inference classified the convert.
                if !_dyneq_ok && called_func === Base.convert && length(args) == 2 &&
                   length(call_arg_types) == 2 && call_arg_types[1] isa Type &&
                   call_arg_types[1] <: Type && call_arg_types[1] isa DataType &&
                   length(call_arg_types[1].parameters) == 1 &&
                   call_arg_types[2] === call_arg_types[1].parameters[1]
                    fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # clear pre-pushed args — identity re-emits the value itself
                    local _cvi_ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                    emit_value!(_cvi_ib, args[2], ctx)
                    append_builder!(fb, _cvi_ib)
                    _dyneq_ok = true
                end
                if !_dyneq_ok
                # WASMTARGET dynamic dispatch: before giving up, try an inline typeId
                # switch over the compiled specializations (the dynamic call dispatches
                # on a concrete-struct arg at runtime). Unblocks Markdown.plain/show
                # recursion over heterogeneous AST nodes (md"…" rendering).
                _disp = _try_inline_typeid_dispatch(ctx, called_func, args, call_arg_types, idx)
                if _disp !== nothing
                    fb = _disp   # discard-and-replace: the dispatch builder IS the product (march4)
                else
                # No matching signature - likely dead code from Union type branches
                # Emit unreachable instead of error (the branch won't be taken at runtime)
                # PURE-605: Suppress warning for known-safe dynamic dispatch paths where
                # Julia couldn't specialize (arg types contain Any/abstract types).
                # These are dead code branches in WasmGC context (we compile with concrete types).
                _has_abstract = any(t -> t === Any || !isconcretetype(t), call_arg_types)
                @debug "CROSS-CALL UNREACHABLE: $(func) with arg types $(call_arg_types) (in func_$(ctx.func_idx))$((_has_abstract ? " [abstract-suppressed]" : ""))"
                fb = InstrBuilder(; func_name="compile_call.frag", mod=ctx.mod); _seed_builder_locals!(fb, ctx)  # PURE-908: clear pre-pushed args
                if get(ctx.ssa_types, idx, Any) === Union{}
                    # always-throws callee (Category-B parity) — sound silent trap.
                    ctx.last_stmt_was_stub = true
                else
                    # Unresolved dynamic call returning a value = un-lowerable dynamic dispatch
                    # (boxing / type instability — abstract-keyed Dict `dict_with_eltype` lands
                    # here). emit_unsupported_stub!'s must-execute gate loud-rejects only when
                    # definitely executed; dead Union-branch calls stay sound silent traps.
                    emit_unsupported_stub!(ctx, fb, :unsupported_method,
                        "unresolved dynamic call `$(func)` $(call_arg_types) — dynamic dispatch / type instability WT cannot lower"; idx=idx)
                end
                end
                end
            end
        else
            # GlobalRef constructor call: SSA return type reveals the struct being constructed
            ssa_type = ctx.code_info.ssavaluetypes[idx]
            if ssa_type isa DataType && isconcretetype(ssa_type) && !isprimitivetype(ssa_type)
                new_expr = Expr(:new, ssa_type, args...)
                return compile_new!(b, new_expr, idx, ctx)
            end
            error("Unsupported function call: $func (type: $(typeof(func)))")
        end

    # NamedTuple{names}(tuple) - convert tuple to named tuple
    # This pattern appears in keyword argument handling
    # Check: func is UnionAll and func <: NamedTuple
    elseif func isa UnionAll && func <: NamedTuple
        # func is NamedTuple{(:name1, :name2, ...)}
        # args[1] should be a tuple with the values
        # The result is a NamedTuple which is a struct with named fields

        # Extract the names from the type
        # NamedTuple{names} has structure: UnionAll(T, NamedTuple{names, T})
        # So func.body is NamedTuple{names, T<:Tuple} and we need to get names from there
        inner_type = func.body  # e.g., NamedTuple{(:filename, :first_line), T<:Tuple}

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
                            local _ntb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                            # Compile the tuple argument - this pushes the tuple struct
                            emit_value!(_ntb, tuple_arg, ctx)
                            # Create a temporary local to hold the tuple
                            tuple_local = allocate_local!(ctx, ConcreteRef(tuple_info.wasm_type_idx, true))
                            local_set!(_ntb, tuple_local)

                            # Push typeId for NamedTuple struct (field 0 = typeId)
                            i32_const!(_ntb, Int64(ensure_type_id!(ctx.type_registry, nt_type)))  # real classId (M3)

                            # Extract each field from tuple and push for struct.new
                            for (i, (name, vtype)) in enumerate(zip(names, value_types))
                                local_get!(_ntb, tuple_local)
                                struct_get!(_ntb, tuple_info.wasm_type_idx, wasm_field_idx(tuple_info, i), julia_to_wasm_type(vtype))  # account for typeId
                            end

                            # Create the NamedTuple struct
                            struct_new!(_ntb, info.wasm_type_idx)   # mod-resolved fields (march3)
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

    # Special case for Core._expr — creates an Expr(head::Symbol, args::Vector{Any})
    # IR pattern: Core._expr(:head, arg1, arg2, ...) with 1+ args
    # head is the first arg (Symbol), remaining args become the Expr.args Vector{Any}
    elseif is_func(func, :_expr)
        # Register Expr type if not already registered
        if !haskey(ctx.type_registry.structs, Expr)
            register_struct_type!(ctx.mod, ctx.type_registry, Expr)
        end

        if haskey(ctx.type_registry.structs, Expr)
            expr_info = ctx.type_registry.structs[Expr]

            # Ensure Vector{Any} is registered (for the args field)
            if !haskey(ctx.type_registry.structs, Vector{Any})
                register_vector_type!(ctx.mod, ctx.type_registry, Vector{Any})
            end
            vec_any_info = ctx.type_registry.structs[Vector{Any}]

            # Ensure Tuple{Int64} is registered (for Vector size field)
            if !haskey(ctx.type_registry.structs, Tuple{Int64})
                register_tuple_type!(ctx.mod, ctx.type_registry, Tuple{Int64})
            end
            size_tuple_info = ctx.type_registry.structs[Tuple{Int64}]

            # Get array type for Any (externref array)
            any_array_type_idx = get_array_type!(ctx.mod, ctx.type_registry, Any)
            str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

            # args[1] is the head (Symbol), args[2:end] are the Expr.args elements
            head_arg = args[1]
            expr_args = args[2:end]
            n_expr_args = length(expr_args)

            # Locals-first approach: compile each piece into a local, then assemble.

            # Step 1: Compile head (Symbol = array<i32>) → local
            # parity(M9): the head Symbol is a CLASSED string value
            head_local = allocate_local!(ctx, ConcreteRef(get_string_struct_type!(ctx.mod, ctx.type_registry), true))
                emit_value!(fb, head_arg, ctx)
                local_set!(fb, head_local)

            # Step 2: Create data array (array<anyref>) → local
            # Any maps to AnyRef — GC refs are subtypes of anyref (no conversion needed).
            # ExternRef values need any_convert_extern. Numeric values need ref.null any placeholder.
            wasm_elem_type = get_concrete_wasm_type(Any, ctx.mod, ctx.type_registry)
            is_anyref_array = (wasm_elem_type === AnyRef)
            if n_expr_args == 0
                    i32_const!(fb, 0)
                    array_new_default!(fb, any_array_type_idx)
            else
                # Push each arg, then array_new_fixed
                for ea in expr_args
                    local _eab = _compile_value_b(ea, ctx)
                    local _ea_ty = isempty(_eab.v.stack) ? nothing : _eab.v.stack[end]
                    # march3/4 (typed): the GC_PREFIX scan + const/local first-byte gates
                    # ARE the tracked type — numeric iff the emission's type is numeric.
                    is_numeric = _ea_ty === I32 || _ea_ty === I64 || _ea_ty === F32 || _ea_ty === F64
                    if isempty(_eab.instrs)
                        # TRUE-INT-002-impl2-impl: compile_value returned empty bytes
                        # (e.g., QuoteNode wrapping an unserializable Core type).
                        # Push ref.null as placeholder to maintain array_new_fixed stack balance.
                        local _pnb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                        if is_anyref_array
                            ref_null!(_pnb, AnyRef)  # any heap type
                        else
                            ref_null!(_pnb, ExternRef)
                        end
                        append_builder!(fb, _pnb)
                    elseif is_numeric
                        local _pnb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                        if is_anyref_array
                            ref_null!(_pnb, AnyRef)  # any heap type
                        else
                            ref_null!(_pnb, ExternRef)
                        end
                        append_builder!(fb, _pnb)
                    else
                        append_builder!(fb, _eab)   # typed merge
                        if is_anyref_array
                            # For anyref arrays: GC refs are already subtypes of anyref.
                            # Only externref values need conversion (any_convert_extern).
                            is_extern = (_ea_ty === ExternRef)
                            if is_extern
                                local _aceb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                                any_convert_extern!(_aceb)
                                append_builder!(fb, _aceb)
                            end
                        else
                            # For externref arrays: GC refs need extern_convert_any.
                            is_extern = (_ea_ty === ExternRef)
                            if !is_extern
                                local _ecab = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                                extern_convert_any!(_ecab)
                                append_builder!(fb, _ecab)
                            end
                        end
                    end
                end
                    array_new_fixed!(fb, any_array_type_idx, n_expr_args, AnyRef)
            end
            data_arr_local = allocate_local!(ctx, ConcreteRef(any_array_type_idx, true))
                local_set!(fb, data_arr_local)

                # Step 3: Create Tuple{Int64} for size → local (typeId, then value)
                i32_const!(fb, Int64(ensure_type_id!(ctx.type_registry, Tuple{Int64})))  # real classId (M3)
                i64_const!(fb, Int64(n_expr_args))
                struct_new!(fb, size_tuple_info.wasm_type_idx)   # mod-resolved fields (march3)
            size_local = allocate_local!(ctx, ConcreteRef(size_tuple_info.wasm_type_idx, true))
            let ib = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                local_set!(ib, size_local)

                # Step 4: Assemble Expr struct
                # Push typeId for Expr struct (field 0 = typeId)
                i32_const!(ib, Int64(ensure_type_id!(ctx.type_registry, Expr)))  # real classId (M3)
                # Push head (Expr field 1)
                local_get!(ib, head_local)
                # Create Vector{Any} inline (Expr field 2): push typeId, data_array, size_tuple, struct.new
                i32_const!(ib, Int64(ensure_type_id!(ctx.type_registry, Vector{Any})))  # real classId (M3)
                local_get!(ib, data_arr_local)
                local_get!(ib, size_local)
                struct_new!(ib, vec_any_info.wasm_type_idx)   # mod-resolved fields (march3)
                # struct.new Expr with (typeId, head, vector)
                struct_new!(ib, expr_info.wasm_type_idx)   # mod-resolved fields (march3)
                append_builder!(fb, ib)
            end

            return append_builder!(b, fb)
        end

    else
        # GlobalRef constructor call: SSA return type reveals the struct being constructed
        if func isa GlobalRef
            ssa_type = ctx.code_info.ssavaluetypes[idx]
            if ssa_type isa DataType && isconcretetype(ssa_type) && !isprimitivetype(ssa_type)
                new_expr = Expr(:new, ssa_type, args...)
                return compile_new!(b, new_expr, idx, ctx)
            end
        end
        # Unknown function call — emit unreachable (will trap at runtime)
        @debug "Stubbing unsupported call: $func (will trap at runtime) (in func_$(ctx.func_idx))"
        # PURE-908: Clear pre-pushed args before UNREACHABLE
        local _urb = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
        record_unsupported!(ctx, :unsupported_method, "unknown function call (no handler arm)"; idx=idx)
        unreachable!(_urb)
        fb = _urb   # discard-and-replace (march4)
        ctx.last_stmt_was_stub = true  # PURE-908
    end

    # parity(M6/F3): the symmetric RESULT side of the anyref-OPERAND unbox above — a numeric
    # arith result flowing into a ref-typed SSA local boxes through THE one producer (the
    # scalar-replaced Core.Box accumulator cycle: unbox → op → BOX → store; dart convertType).
    # march13: keyed on the FUNCTION-scoped flag — the old @isdefined-guarded read of a
    # LOOP-scoped variable made this arm silently dead for every call since introduction.
    if (@isdefined _boxed_operand_unboxed) && _boxed_operand_unboxed && !ctx.last_stmt_was_stub
        local _dl = get(ctx.ssa_locals, idx, nothing)
        if _dl !== nothing
            local _doff = _dl - ctx.n_params
            if _doff >= 0 && _doff < length(ctx.locals) && ctx.locals[_doff + 1] === AnyRef
                local _rbx = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
                emit_classid_box!(_rbx, ctx, is_32bit ? I32 : I64, nothing)
                append_builder!(fb, _rbx)
            end
        end
    end

    return append_builder!(b, fb)
end

# ============================================================================
# _apply_iterate helpers (vector splatting)
# ============================================================================

"""bytes shell for the remaining byte-region callers (dies with them)."""
function compile_call(expr::Expr, idx::Int, ctx::AbstractCompilationContext)::Vector{UInt8}
    b = InstrBuilder(; func_name="compile_call", mod=ctx.mod)
    _seed_builder_locals!(b, ctx)
    compile_call!(b, expr, idx, ctx)
    return builder_code(b)
end

"""
Map a known binary function name to its WASM reduce opcode for the given element type.
Returns nothing if the function is not a known binary reduce operation.
"""
function _get_binary_reduce_opcode(func_name::Union{Symbol, Nothing}, elem_type::Type)::Union{UInt8, Nothing}
    func_name === nothing && return nothing
    if elem_type === Int64 || elem_type === UInt64
        func_name === :+ && return Opcode.I64_ADD
        func_name === :add_int && return Opcode.I64_ADD
        func_name === :* && return Opcode.I64_MUL
        func_name === :mul_int && return Opcode.I64_MUL
    elseif elem_type === Int32 || elem_type === UInt32
        func_name === :+ && return Opcode.I32_ADD
        func_name === :add_int && return Opcode.I32_ADD
        func_name === :* && return Opcode.I32_MUL
        func_name === :mul_int && return Opcode.I32_MUL
    elseif elem_type === Float64
        func_name === :+ && return Opcode.F64_ADD
        func_name === :add_float && return Opcode.F64_ADD
        func_name === :* && return Opcode.F64_MUL
        func_name === :mul_float && return Opcode.F64_MUL
        func_name === :min && return Opcode.F64_MIN
        func_name === :max && return Opcode.F64_MAX
    elseif elem_type === Float32
        func_name === :+ && return Opcode.F32_ADD
        func_name === :add_float && return Opcode.F32_ADD
        func_name === :* && return Opcode.F32_MUL
        func_name === :mul_float && return Opcode.F32_MUL
        func_name === :min && return Opcode.F32_MIN
        func_name === :max && return Opcode.F32_MAX
    end
    return nothing
end

"""
Emit a reduce loop for _apply_iterate(iterate, binary_op, vec::Vector{T}).

Generates WASM that computes: acc = v[0]; for i in 1..len-1: acc = op(acc, v[i]); return acc
Uses WasmGC array access (no MemoryRef indirection — the compiler flattens Vector{T}
to struct { typeId, data_array, size_tuple }).

Allocates 5 temporary locals: vec_ref, arr_ref, len (i32), loop_i (i32), acc.
"""
function _emit_apply_iterate_reduce!(fb::InstrBuilder, container_arg, container_type::DataType,
                                      elem_type::Type, reduce_op::UInt8, ctx)
    bld = InstrBuilder(; func_name="_emit_apply_iterate_reduce!", mod=ctx.mod)
    # Get WasmGC type indices for the vector struct and its fields
    vec_info = get(ctx.type_registry.structs, container_type, nothing)
    if vec_info === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: vector struct unregistered")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end
    vec_type_idx = vec_info.wasm_type_idx
    field_offset = vec_info.field_offset  # usually 1 (after typeId)

    # Data array type index
    arr_type_idx = get(ctx.type_registry.arrays, elem_type, nothing)
    if arr_type_idx === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: data array type unregistered")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end

    # Size tuple type index (Tuple{Int64})
    size_tuple_type = Tuple{Int64}
    size_info = get(ctx.type_registry.structs, size_tuple_type, nothing)
    if size_info === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: size tuple type unregistered")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end
    size_type_idx = size_info.wasm_type_idx
    size_field_offset = size_info.field_offset  # field 1 after typeId

    # Determine the WASM element type for the accumulator local
    elem_wasm_type = julia_to_wasm_type(elem_type)

    # Allocate temporary locals
    vec_ref_local = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, ConcreteRef(vec_type_idx, true))

    arr_ref_local = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, ConcreteRef(arr_type_idx, true))

    len_local = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, I32)

    loop_i_local = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, I32)

    acc_local = UInt32(ctx.n_params + length(ctx.locals))
    push!(ctx.locals, elem_wasm_type)

    # --- Emit WASM bytecode ---

    # Step 1: Compile and store the container reference
    emit_value!(bld, container_arg, ctx)
    local_set!(bld, vec_ref_local)

    # Step 2: Get the data array reference
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset, ConcreteRef(arr_type_idx, true))  # data array field
    local_set!(bld, arr_ref_local)

    # Step 3: Get the length (vec → size tuple → i64 length → i32)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset + 1, ConcreteRef(size_type_idx, true))  # size tuple field
    struct_get!(bld, size_type_idx, size_field_offset, I64)  # i64 length
    num!(bld, Opcode.I32_WRAP_I64)
    local_set!(bld, len_local)

    # Step 4: Initialize accumulator = arr[0] (first element)
    local_get!(bld, arr_ref_local)
    i32_const!(bld, 0)
    array_get!(bld, arr_type_idx, elem_wasm_type)
    local_set!(bld, acc_local)

    # Step 5: Initialize loop counter i = 1
    i32_const!(bld, 1)
    local_set!(bld, loop_i_local)

    # Step 6: block { loop { if i >= len: br 1; acc = op(acc, arr[i]); i++; br 0 } }
    block!(bld)  # void blocktype
    loop!(bld)  # void blocktype

    # if i >= len, exit loop
    local_get!(bld, loop_i_local)
    local_get!(bld, len_local)
    num!(bld, Opcode.I32_GE_S)
    br_if!(bld, 1)  # br 1 = exit block

    # acc = op(acc, arr[i])
    local_get!(bld, acc_local)
    local_get!(bld, arr_ref_local)
    local_get!(bld, loop_i_local)
    array_get!(bld, arr_type_idx, elem_wasm_type)
    num!(bld, reduce_op)
    local_set!(bld, acc_local)

    # i++
    local_get!(bld, loop_i_local)
    i32_const!(bld, 1)
    num!(bld, Opcode.I32_ADD)
    local_set!(bld, loop_i_local)

    # br 0 = continue loop
    br!(bld, 0)

    end_block!(bld)  # end loop
    end_block!(bld)  # end block

    # Step 7: Push accumulator as result
    local_get!(bld, acc_local)
    append_builder!(fb, bld)
end

"""
Emit a shallow copy for _apply_iterate(iterate, Base.vect, vec::Vector{T}) — i.e.
the `[v...]` splat-collect idiom, which for a single Vector argument is exactly
`copy(v)`: a new Vector{T} with the same elements.

Builds the result struct { typeId, data_array, size_tuple } from `vec`:
  * typeId   — copied from the source (field 0)
  * data_array — a fresh array.new_default of the LOGICAL length (read from the
    size tuple, not array.len, since the backing array may carry extra capacity),
    populated via array.copy
  * size_tuple — reused from the source (Tuple{Int64} is immutable → safe to share)

Allocates 4 temporary locals: vec_ref, src_arr, len (i32), new_arr.
"""
function _emit_apply_iterate_vect!(fb::InstrBuilder, container_arg, container_type::DataType, ctx)
    vec_info  = get(ctx.type_registry.structs, container_type, nothing)
    elem_type = eltype(container_type)
    arr_type_idx = get(ctx.type_registry.arrays, elem_type, nothing)
    size_info = get(ctx.type_registry.structs, Tuple{Int64}, nothing)
    bld = InstrBuilder(; func_name="_emit_apply_iterate_vect!", mod=ctx.mod)
    if vec_info === nothing || arr_type_idx === nothing || size_info === nothing
        record_unsupported!(ctx, :unsupported_method, "apply-iterate reduce: vector layout unavailable")
        unreachable!(bld); append_builder!(fb, bld)
        ctx.last_stmt_was_stub = true
        return
    end
    vec_type_idx = vec_info.wasm_type_idx
    field_offset = vec_info.field_offset           # 1: data array (0 = typeId, 2 = size)
    size_type_idx = size_info.wasm_type_idx
    size_field_offset = size_info.field_offset

    vec_ref_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(vec_type_idx, true))
    src_arr_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(arr_type_idx, true))
    len_local     = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, I32)
    new_arr_local = UInt32(ctx.n_params + length(ctx.locals)); push!(ctx.locals, ConcreteRef(arr_type_idx, true))

    # vec_ref = container
    emit_value!(bld, container_arg, ctx)
    local_set!(bld, vec_ref_local)

    # src_arr = vec_ref.data  (field_offset)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset, ConcreteRef(arr_type_idx, true))
    local_set!(bld, src_arr_local)

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

    # array.copy(new_arr, 0, src_arr, 0, len)
    local_get!(bld, new_arr_local)
    i32_const!(bld, 0)
    local_get!(bld, src_arr_local)
    i32_const!(bld, 0)
    local_get!(bld, len_local)
    array_copy!(bld, arr_type_idx, arr_type_idx)

    # result = struct.new vec_type_idx [ typeId(src), new_arr, size_tuple(src) ]
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset - 1, I32)  # typeId
    local_get!(bld, new_arr_local)
    local_get!(bld, vec_ref_local)
    struct_get!(bld, vec_type_idx, field_offset + 1, ConcreteRef(size_type_idx, true))  # size tuple
    struct_new!(bld, vec_type_idx)   # mod-resolved fields (march3)
    append_builder!(fb, bld)
end


"""
    _try_fold_layout_pointerref(ptr_arg, ctx) -> DataTypeLayout | nothing

P3 gap 450889a9cb7e: fold `unsafe_load(convert(Ptr{DataTypeLayout},
dt.layout))` (the datatype_layoutsize / datatype_arrayelem idiom) when `dt`
is a DataType literal — the layout struct is immutable host metadata, fully
known at compile time. Returns the host-loaded DataTypeLayout for literal
materialization, or nothing if the chain doesn't match.
"""

# P4-stdlib (Random hash_seed): resolve an IR value to a HOST SimpleVector
# constant when its definition is compile-time evaluable — `padding(T, n)`
# with literal args, or `getfield(typename(T), :names)`. The defs emit benign
# null placeholders (no svec constant emission exists); consumers like
# _svec_len/_svec_ref fold against the host value instead of reading it.
function _try_host_svec(arg, ctx::AbstractCompilationContext)
    arg isa Core.SSAValue || return nothing
    (arg.id < 1 || arg.id > length(ctx.code_info.code)) && return nothing
    st = ctx.code_info.code[arg.id]
    if st isa Expr && (st.head === :invoke || st.head === :call)
        a1 = st.head === :invoke ? (length(st.args) >= 2 ? st.args[2] : nothing) : st.args[1]
        nm = a1 isa GlobalRef ? a1.name : a1 isa Function ? nameof(a1) : nothing
        rest = st.head === :invoke ? st.args[3:end] : st.args[2:end]
        if nm === :padding && length(rest) == 2 && rest[1] isa Type && rest[2] isa Integer
            return try Base.padding(rest[1], Int(rest[2])) catch; nothing end
        elseif nm === :getfield && length(rest) >= 2 && rest[1] isa QuoteNode
            fld = rest[2] isa QuoteNode ? rest[2].value : rest[2]
            if fld isa Symbol
                v = try getfield(rest[1].value, fld) catch; nothing end
                v isa Core.SimpleVector && return v
            end
        end
    end
    return nothing
end

function _try_fold_layout_pointerref(ptr_arg, ctx::AbstractCompilationContext)
    cur = ptr_arg
    for _ in 1:4
        cur isa Core.SSAValue || return nothing
        st = ctx.code_info.code[cur.id]
        st isa Expr && st.head === :call || return nothing
        cf = st.args[1]
        cfn = cf isa GlobalRef ? cf.name : cf
        if cfn === :bitcast && length(st.args) >= 3
            cur = st.args[3]
        elseif cfn === :getfield && length(st.args) >= 3
            dt = st.args[2]
            dt isa QuoteNode && (dt = dt.value)
            if dt isa GlobalRef
                dt = isdefined(dt.mod, dt.name) ? getfield(dt.mod, dt.name) : nothing
            end
            fld = st.args[3] isa QuoteNode ? st.args[3].value : st.args[3]
            (dt isa DataType && fld === :layout) || return nothing
            lay = try getfield(dt, :layout) catch; return nothing end
            lay == C_NULL && return nothing
            return unsafe_load(convert(Ptr{Base.DataTypeLayout}, lay))
        else
            return nothing
        end
    end
    return nothing
end
