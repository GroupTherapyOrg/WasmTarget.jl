# parity(quarantine: Julia numeric semantics dart2wasm does not have — dart's `int` is one
# NumType.i64 (translator.dart:346): no Int128, no checked overflow, no first-class narrow
# ints in arithmetic; dart coerces only through convertType (translator.dart:1597) and the
# dart:_wasm shims (intrinsics.dart:710-929). Each registry here is consulted from ONE site
# in compile_call! with the intrinsifier's nullable-return contract (intrinsics.dart:1007):
# `nothing` means "not this tier's op", and the generic lowering continues.)

# ============================================================================
# Int128/UInt128 registry
# ============================================================================
#
# dart2wasm has no 128-bit integer type — the whole family is Julia-only quarantine, not
# a dart-anchored table (int128.jl's `emit_int128_*!` emitters carry their own per-op
# `parity(quarantine: ...)` headers). This registry is a pure move of the arms that used
# to live in `compile_call!`'s `is_func` ladder (each tagged `# table residue: Int128 →
# quarantine tier`, or reachable only when `is_128bit` since the non-128-bit case was
# already consumed by THE intrinsics table route in intrinsics_table.jl): op symbol →
# `(b, ctx, arg_type) -> WasmValType`, wrapping the existing `emit_int128_*!` call exactly
# as the arm invoked it, then reporting the result type it pushed (the struct type for
# arithmetic/bitwise/shift ops, `I32` for comparisons — mirrors `emit_intrinsic_binop!`'s
# contract).
const INT128_OPS = Dict{Symbol,Function}(
    :add_int   => (b, ctx, t) -> (emit_int128_add!(b, ctx, t);   _int128_structref(ctx, t)),
    :sub_int   => (b, ctx, t) -> (emit_int128_sub!(b, ctx, t);   _int128_structref(ctx, t)),
    :mul_int   => (b, ctx, t) -> (emit_int128_mul!(b, ctx, t);   _int128_structref(ctx, t)),
    :and_int   => (b, ctx, t) -> (emit_int128_and!(b, ctx, t);   _int128_structref(ctx, t)),
    :or_int    => (b, ctx, t) -> (emit_int128_or!(b, ctx, t);    _int128_structref(ctx, t)),
    :xor_int   => (b, ctx, t) -> (emit_int128_xor!(b, ctx, t);   _int128_structref(ctx, t)),
    :not_int   => (b, ctx, t) -> (emit_int128_not!(b, ctx, t);   _int128_structref(ctx, t)),
    :neg_int   => (b, ctx, t) -> (emit_int128_neg!(b, ctx, t);   _int128_structref(ctx, t)),
    :ctlz_int  => (b, ctx, t) -> (emit_int128_ctlz!(b, ctx, t);  _int128_structref(ctx, t)),
    :cttz_int  => (b, ctx, t) -> (emit_int128_cttz!(b, ctx, t);  _int128_structref(ctx, t)),
    :ctpop_int => (b, ctx, t) -> (emit_int128_ctpop!(b, ctx, t); _int128_structref(ctx, t)),
    :slt_int   => (b, ctx, t) -> (emit_int128_slt!(b, ctx, t);   I32),
    :sle_int   => (b, ctx, t) -> (emit_int128_sle!(b, ctx, t);   I32),
    :ult_int   => (b, ctx, t) -> (emit_int128_ult!(b, ctx, t);   I32),
    :ule_int   => (b, ctx, t) -> (emit_int128_ule!(b, ctx, t);   I32),
    :eq_int    => (b, ctx, t) -> (emit_int128_eq!(b, ctx, t);    I32),
    :ne_int    => (b, ctx, t) -> (emit_int128_ne!(b, ctx, t);    I32),
    :shl_int   => (b, ctx, t) -> (emit_int128_shl!(b, ctx, t);   _int128_structref(ctx, t)),
    :ashr_int  => (b, ctx, t) -> (emit_int128_ashr!(b, ctx, t);  _int128_structref(ctx, t)),
    :lshr_int  => (b, ctx, t) -> (emit_int128_lshr!(b, ctx, t);  _int128_structref(ctx, t)),
)

"""
    emit_int128_op!(b, ctx, op, arg_type, expr, idx) -> Union{WasmValType,Nothing}

THE Int128/UInt128 dispatch point, consulted from `compile_call!` right where the
`!is_128bit`-guarded intrinsics table routes leave off (mirrors `emit_intrinsic_binop!`
and `emit_intrinsic_unop!`'s nullable-return contract). Operands are already on `b`'s
stack (the same operand emission the residue arms relied on); `arg_type` is the
caller's already-inferred Int128/UInt128 source type (the same value the residue arms
were passed — recomputing it here would be a second `infer_value_type` call site, R3).
Returns `nothing` when `op` is not one of this tier's ops — the caller's legacy arm
(`bswap_int`'s loud reject) keeps handling it.

On a hit, finishes exactly like the intrinsics table routes: the SSA result gets the
same rebox check (a numeric result flowing into a ref-typed local boxes through
`emit_classid_box!`, keyed on the real Julia source type — dart's `convertType`).
"""
function emit_int128_op!(b::InstrBuilder, ctx, op::Symbol, arg_type, expr::Expr, idx::Int)::Union{WasmValType,Nothing}
    f = get(INT128_OPS, op, nothing)
    f === nothing && return nothing
    result = f(b, ctx, arg_type)::WasmValType

    # (The rebox link, mirroring the table binop/unop routes in intrinsics_table.jl.)
    local _rbx_li = get(ctx.ssa_locals, idx, nothing)
    if _rbx_li !== nothing
        local _rbx_off = _rbx_li - ctx.n_params
        if _rbx_off >= 0 && _rbx_off < length(ctx.locals) && _wt_is_ref(ctx.locals[_rbx_off + 1]) &&
           result in (I32, I64, F32, F64)
            (arg_type isa Type && isconcretetype(arg_type)) ||
                record_unsupported!(ctx, :unsupported_type,
                    "intrinsic result boxing lacks a concrete Julia source type";
                    idx=idx, detail=expr)
            emit_classid_box!(b, ctx, result, arg_type)
        end
    end
    return result
end

# ============================================================================
# Checked-overflow registry (checked_s{add,sub,mul}_int / checked_u{add,sub,mul}_int)
# ============================================================================
#
# parity(quarantine: no dart equivalent — dart's `int` wraps silently on overflow,
# translator.dart never traps or returns a flag; the `Tuple{T,Bool}` contract is
# purely Julia's `Base.Checked` surface). A pure move of the six arms that used to
# sit at the head of `compile_call!`'s ladder (`_compile_call_checked!` in
# calls.jl re-derives the exact op the same way the ladder did — `is_func`, not a
# symbol-equality shortcut — so all six keys forward to the one dispatcher).
const _checked_dispatch = (fbref, ctx, func, args, is_128bit, is_32bit, arg_type, idx) ->
    _compile_call_checked!(fbref, ctx, func, args, is_128bit, is_32bit, arg_type, idx)
const CHECKED_OPS = Dict{Symbol,Function}(
    :checked_sadd_int => _checked_dispatch,
    :checked_uadd_int => _checked_dispatch,
    :checked_ssub_int => _checked_dispatch,
    :checked_usub_int => _checked_dispatch,
    :checked_smul_int => _checked_dispatch,
    :checked_umul_int => _checked_dispatch,
)

# ============================================================================
# Mixed-width shift registry (shl_int, ashr_int, lshr_int)
# ============================================================================
#
# parity(quarantine: no dart equivalent — dart's `int` is uniformly i64, so
# there is no mixed-width shift-count coercion to speak of; `readIntArray`'s
# extension (intrinsics.dart) is array-storage-specific, not this). 128-bit
# operands never reach this registry — THE Int128 registry route (above)
# already owns `shl_int`/`ashr_int`/`lshr_int` for `is_128bit`.
const SHIFT_OPS = Dict{Symbol,Function}(
    :shl_int  => (fb, ctx, args, arg_type, is_32bit) -> _compile_call_shift!(fb, ctx, args, arg_type, is_32bit, :shl),
    :ashr_int => (fb, ctx, args, arg_type, is_32bit) -> _compile_call_shift!(fb, ctx, args, arg_type, is_32bit, :ashr),
    :lshr_int => (fb, ctx, args, arg_type, is_32bit) -> _compile_call_shift!(fb, ctx, args, arg_type, is_32bit, :lshr),
)

# ============================================================================
# Three-argument float registry (muladd_float, fma_float, have_fma)
# ============================================================================
#
# parity(quarantine: WASM has no scalar FMA instruction — no `intrinsics.dart`
# entry to anchor to). `muladd_float`/`fma_float` both lower to `mul; add` (TWO
# roundings), which is Julia's `muladd` semantics exactly but NOT `fma`'s
# single-rounding contract — `have_fma` always answers `false` so Julia's
# generic `fma` fallback (mul+add) is consistent with what gets emitted; the
# double-rounding divergence this creates on the rare input where single- vs
# double-rounding differ is a PRE-EXISTING gap, unchanged by this move (see the
# Phase 6 finding: measured, not fixed, here). The 3-arg push-order reorder
# (`[c, a, b]` so `f64.mul` sees `(a,b)` then `f64.add` sees `(c, a*b)`) happens
# in `compile_call!`'s SHARED arg-push loop, ahead of every registry consult —
# operands are already correctly ordered on the stack by the time these fire.
const FMA_OPS = Dict{Symbol,Function}(
    :muladd_float => (fb, ctx, arg_type) -> begin
        num!(fb, arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)
        num!(fb, arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)
        arg_type === Float32 ? F32 : F64
    end,
    :fma_float => (fb, ctx, arg_type) -> begin
        num!(fb, arg_type === Float32 ? Opcode.F32_MUL : Opcode.F64_MUL)
        num!(fb, arg_type === Float32 ? Opcode.F32_ADD : Opcode.F64_ADD)
        arg_type === Float32 ? F32 : F64
    end,
    :have_fma => (fb, ctx, arg_type) -> (i32_const!(fb, 0); I32),   # WASM has no hardware FMA
)

# ============================================================================
# Misc registry (bswap_int, flipsign_int)
# ============================================================================
#
# parity(quarantine: no dart intrinsic for either — dart2wasm's low-level
# switch, intrinsics.dart:710-929, has no byte-swap or sign-copy entry).
const MISC_OPS = Dict{Symbol,Function}(
    :bswap_int => (fb, ctx, args, arg_type, is_128bit, is_32bit, idx) ->
        _compile_call_bswap!(fb, ctx, is_128bit, is_32bit, idx),
    :flipsign_int => (fb, ctx, args, arg_type, is_128bit, is_32bit, idx) ->
        _compile_call_flipsign(args, fb, ctx, is_128bit, is_32bit, arg_type),
)

"""
    emit_julia_numeric!(fbref, ctx, op, func, args, arg_type, is_128bit, is_32bit, idx) -> Union{WasmValType,Nothing}

THE Julia-only numeric quarantine dispatch, consulted from `compile_call!`
right where THE Int128/UInt128 registry route leaves off (mirrors
`emit_int128_op!`'s nullable-return contract). Tries CHECKED_OPS, SHIFT_OPS,
FMA_OPS, then MISC_OPS in turn; `nothing` means none of the four claim `op` —
the caller's legacy ladder (bitcast, `===`/`!==`, sext/zext/trunc, …) keeps
handling it.

`fbref` is a `Ref{InstrBuilder}` rather than a plain `InstrBuilder`: only
CHECKED_OPS's is_128bit add/sub reject ever needs to REPLACE the builder (see
`_compile_call_checked_add!`'s docstring); every other entry just appends to
`fbref[]`. No rebox link is needed here (unlike `emit_int128_op!`) — none of
these op names are in `NUMERIC_INTRINSIC_ARG_OPS` (intrinsics_table.jl), so
the boxed-operand-unbox flag that link depends on can never be set for them;
the tail rebox in `compile_call!` was already a no-op for every op this
dispatch owns.
"""
function emit_julia_numeric!(fbref::Base.RefValue{InstrBuilder}, ctx, op::Symbol, func, args,
                             arg_type, is_128bit::Bool, is_32bit::Bool,
                             idx::Int)::Union{WasmValType,Nothing}
    if haskey(CHECKED_OPS, op)
        return CHECKED_OPS[op](fbref, ctx, func, args, is_128bit, is_32bit, arg_type, idx)
    elseif haskey(SHIFT_OPS, op)
        return SHIFT_OPS[op](fbref[], ctx, args, arg_type, is_32bit)
    elseif haskey(FMA_OPS, op)
        return FMA_OPS[op](fbref[], ctx, arg_type)
    elseif haskey(MISC_OPS, op)
        return MISC_OPS[op](fbref[], ctx, args, arg_type, is_128bit, is_32bit, idx)
    end
    return nothing
end
