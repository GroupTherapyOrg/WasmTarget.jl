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

# ============================================================================
# THE wrap channel: normalise_narrow!
# ============================================================================
#
# parity(quarantine: Julia's Int8/Int16/UInt8/UInt16 are first-class operand types
# living in i32; dart's `int` is uniformly i64, translator.dart:346, and its only
# narrow extension is array-storage-driven, intrinsics.dart:3490-3533).
"""
    normalise_narrow!(b, ctx, julia_type::Type, signed::Bool)

THE wrap channel: emits the sign-extension (`i32.extend8_s`/`extend16_s`) or mask
(`and 0xff`/`0xffff`) for a narrow value already on `b`'s stack; a no-op for canonical
widths (Int32/Int64/UInt32/UInt64/anything else `julia_type` isn't one of the four
narrow BitIntegers). `signed` is the CALLER's interpretation of the bits — independent
of `julia_type`'s own signedness (e.g. `ult_int` normalises an Int8 operand unsigned;
`zext_int` always normalises unsigned regardless of source signedness).
"""
function normalise_narrow!(b::InstrBuilder, ctx,
                           julia_type::Type, signed::Bool)
    julia_width = julia_type === Int8 || julia_type === UInt8 ? 8 :
                  julia_type === Int16 || julia_type === UInt16 ? 16 : 32
    if julia_width < 32
        if signed
            num!(b, julia_width == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
        else
            i32_const!(b, Int64((1 << julia_width) - 1))
            num!(b, Opcode.I32_AND)
        end
    end
    return b
end

# ============================================================================
# Conversions registry (sext_int/zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/
# fpext/fptrunc/bitcast)
# ============================================================================
#
# parity(quarantine: Julia's width/kind conversion intrinsics have no dart map —
# dart coerces only through convertType, translator.dart:1597, and the dart:_wasm
# shims, intrinsics.dart:710-929). Mirrors intrinsics_table.jl's BinOpEmit/UnOpEmit
# shape: a callback (source value already on the stack, at this key's wasm type) +
# result type, keyed on (source wasm type, target wasm type, julia op symbol) for the
# CANONICAL-WIDTH cases. Narrow Int8/16/UInt8/16 operands are NOT separate table
# rows (dart has no such distinction to mirror) — `emit_conversion!` wraps the table
# lookup with `normalise_narrow!` pre/post steps, exactly as the callers of
# INTRINSIC_BINOPS narrow-normalise before consulting that table.

"""One typed conversion emission: a callback (source value already on the stack) +
result type."""
struct ConvEmit
    emit!::Function          # (b::InstrBuilder) -> Nothing
    result::WasmValType
end

const INTRINSIC_CONVERSIONS = Dict{Tuple{WasmValType,WasmValType,Symbol},ConvEmit}(
    (I32, I64, :sext_int)  => ConvEmit(b -> num!(b, Opcode.I64_EXTEND_I32_S), I64),
    (I32, I64, :zext_int)  => ConvEmit(b -> num!(b, Opcode.I64_EXTEND_I32_U), I64),
    (I64, I32, :trunc_int) => ConvEmit(b -> num!(b, Opcode.I32_WRAP_I64), I32),
    (I32, F32, :sitofp) => ConvEmit(b -> num!(b, Opcode.F32_CONVERT_I32_S), F32),
    (I64, F32, :sitofp) => ConvEmit(b -> num!(b, Opcode.F32_CONVERT_I64_S), F32),
    (I32, F64, :sitofp) => ConvEmit(b -> num!(b, Opcode.F64_CONVERT_I32_S), F64),
    (I64, F64, :sitofp) => ConvEmit(b -> num!(b, Opcode.F64_CONVERT_I64_S), F64),
    (I32, F32, :uitofp) => ConvEmit(b -> num!(b, Opcode.F32_CONVERT_I32_U), F32),
    (I64, F32, :uitofp) => ConvEmit(b -> num!(b, Opcode.F32_CONVERT_I64_U), F32),
    (I32, F64, :uitofp) => ConvEmit(b -> num!(b, Opcode.F64_CONVERT_I32_U), F64),
    (I64, F64, :uitofp) => ConvEmit(b -> num!(b, Opcode.F64_CONVERT_I64_U), F64),
    # dart's shim (intrinsics.dart) uses SATURATING trunc_sat for float→int; Julia's
    # fptosi/fptoui intrinsic is undefined out-of-range (InexactError territory at
    # the Base level, not this intrinsic's job) — WT keeps the TRAPPING wasm trunc
    # (loud on overflow/NaN), the honest choice for an intrinsic whose Julia
    # contract assumes an in-range value, rather than dart's silent clamp.
    (F32, I32, :fptosi) => ConvEmit(b -> num!(b, Opcode.I32_TRUNC_F32_S), I32),
    (F64, I32, :fptosi) => ConvEmit(b -> num!(b, Opcode.I32_TRUNC_F64_S), I32),
    (F32, I64, :fptosi) => ConvEmit(b -> num!(b, Opcode.I64_TRUNC_F32_S), I64),
    (F64, I64, :fptosi) => ConvEmit(b -> num!(b, Opcode.I64_TRUNC_F64_S), I64),
    (F32, I32, :fptoui) => ConvEmit(b -> num!(b, Opcode.I32_TRUNC_F32_U), I32),
    (F64, I32, :fptoui) => ConvEmit(b -> num!(b, Opcode.I32_TRUNC_F64_U), I32),
    (F32, I64, :fptoui) => ConvEmit(b -> num!(b, Opcode.I64_TRUNC_F32_U), I64),
    (F64, I64, :fptoui) => ConvEmit(b -> num!(b, Opcode.I64_TRUNC_F64_U), I64),
    (F32, F64, :fpext)   => ConvEmit(b -> num!(b, 0xBB), F64),   # f64.promote_f32
    (F64, F32, :fptrunc) => ConvEmit(b -> num!(b, 0xB6), F32),   # f32.demote_f64
    # bitcast reinterpret pairs. Same-width int<->int (Int32<->UInt32, Int64<->
    # UInt64, Char<->Int32/UInt32 — STACK-003: Char's internal rep IS a packed
    # UInt32) and Int128<->UInt128 are a no-op in Wasm and carry NO table row —
    # `emit_conversion!` falls through to a no-op exactly like every op above does
    # for a (src,dst,op) combination the table doesn't cover.
    (F64, I64, :bitcast) => ConvEmit(b -> num!(b, Opcode.I64_REINTERPRET_F64), I64),
    (I64, F64, :bitcast) => ConvEmit(b -> num!(b, Opcode.F64_REINTERPRET_I64), F64),
    (F32, I32, :bitcast) => ConvEmit(b -> num!(b, Opcode.I32_REINTERPRET_F32), I32),
    (I32, F32, :bitcast) => ConvEmit(b -> num!(b, Opcode.F32_REINTERPRET_I32), F32),
)

# Int128/UInt128 conversion bodies for sext_int/zext_int/trunc_int — pure moves of
# the struct_new!/struct_get! logic the arms had. Kept OUT of INT128_OPS (whose
# `(b, ctx, t) -> WasmValType` signature is for a same-type arithmetic/bitwise op; a
# conversion needs BOTH a source and a target type, a different shape) and consulted
# directly from `emit_conversion!` rather than through `emit_int128_op!`'s
# is_128bit-gated route: sext/zext INTO Int128 have a narrow, non-128-bit SOURCE, so
# that gate (keyed on the call's general operand type) never fires for them.
function _int128_sext!(b::InstrBuilder, ctx,
                       julia_src, target_type::Type)
    source_type = julia_src isa Type ? julia_src : Int64
    if source_type === Int32 || source_type === UInt32 || source_type === Int16 ||
       source_type === Int8 || source_type === Bool
        num!(b, Opcode.I64_EXTEND_I32_S)
    end
    scratch_idx = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I64)
    local_tee!(b, scratch_idx)
    i64_const!(b, 63)
    num!(b, Opcode.I64_SHR_S)
    scratch2_idx = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I64)
    local_set!(b, scratch2_idx)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, target_type)))
    local_get!(b, scratch_idx)
    local_get!(b, scratch2_idx)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
    struct_new!(b, type_idx)
    return _int128_structref(ctx, target_type)
end

function _int128_zext!(b::InstrBuilder, ctx,
                       julia_src, target_type::Type)
    source_type = julia_src isa Type ? julia_src : UInt64
    zx_mask = (source_type === UInt8 || source_type === Int8) ? Int64(0xFF) :
              (source_type === UInt16 || source_type === Int16) ? Int64(0xFFFF) : Int64(0)
    if zx_mask != 0
        i32_const!(b, zx_mask)
        num!(b, Opcode.I32_AND)
        num!(b, Opcode.I64_EXTEND_I32_U)
    elseif source_type === Int32 || source_type === UInt32 || source_type === Bool
        num!(b, Opcode.I64_EXTEND_I32_U)
    end
    zext_scratch = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    local_set!(b, zext_scratch)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, target_type)))
    local_get!(b, zext_scratch)
    i64_const!(b, 0)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
    struct_new!(b, type_idx)
    return _int128_structref(ctx, target_type)
end

function _int128_trunc_lo!(b::InstrBuilder, ctx, source_type::Type)
    source_type_idx = get_int128_type!(ctx.mod, ctx.type_registry, source_type)
    struct_get!(b, source_type_idx, UInt32(1), I64)  # field 1 = lo (0 = typeId)
    return I64
end

"""Resolve `bitcast`'s target-type argument (GlobalRef/DataType/unresolved) — a pure
move of the arm's resolution logic. `record_unsupported!`'s reject stays the
registry's loud path for an unresolvable GlobalRef (Design item C)."""
function _resolve_bitcast_target(ctx, target_type_ref, idx::Int)
    if target_type_ref isa GlobalRef
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
        elseif isdefined(target_type_ref.mod, target_type_ref.name)
            getfield(target_type_ref.mod, target_type_ref.name)
        else
            record_unsupported!(ctx, :unsupported_type,
                "reinterpret target GlobalRef is not defined"; idx=idx, detail=target_type_ref)
        end
    elseif target_type_ref isa DataType
        target_type_ref
    else
        Any
    end
end

"""
    emit_conversion!(b, ctx, op, julia_src, julia_dst, idx; src_already_wide=false) -> Union{WasmValType,Nothing}

THE conversions dispatch, consulted from `compile_call!` as a sibling to
`emit_julia_numeric!` (same nullable-return funnel shape). `op` is one of
sext_int/zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/fpext/fptrunc/bitcast;
anything else returns `nothing` immediately (not this dispatch's op — mirrors
`emit_int128_op!`/`emit_julia_numeric!`). For these ten ops this dispatch is
EXHAUSTIVE (the calls.jl arms it replaces are deleted, so a `nothing`
"try the next thing" fall-through would reach nothing): every branch below either
emits (possibly nothing, for an already-canonical width) or calls
`record_unsupported!`.

`julia_dst` is the caller-resolved target Julia type: for sext_int/zext_int/
trunc_int it is ALREADY VALIDATED (calls.jl keeps that resolution — and its three
literal diagnostic messages — locally, L77); for sitofp/uitofp/fptosi/fptoui it is
`args[1]` unresolved (the arms never resolved it either); for bitcast it is the RAW
`target_type_ref`, resolved here via `_resolve_bitcast_target`; fpext/fptrunc ignore
it. `src_already_wide` is `get_phi_edge_wasm_type(args[2], ctx) === I64` — a widened
phi local already occupies the full register, so sext_int/zext_int must not
re-extend it, and trunc_int must treat it as a 64-bit source even when the Julia
type looks narrower.
"""
function emit_conversion!(b::InstrBuilder, ctx, op::Symbol,
                          julia_src, julia_dst, idx::Int;
                          src_already_wide::Bool=false)::Union{WasmValType,Nothing}
    op in (:sext_int, :zext_int, :trunc_int, :sitofp, :uitofp, :fptosi, :fptoui,
           :fpext, :fptrunc, :bitcast) || return nothing

    if op === :sext_int
        if julia_dst === Int128 || julia_dst === UInt128
            return _int128_sext!(b, ctx, julia_src, julia_dst)
        elseif (julia_dst === Int64 || julia_dst === UInt64) && !src_already_wide
            julia_src isa Type && normalise_narrow!(b, ctx, julia_src, julia_src <: Signed)
            num!(b, Opcode.I64_EXTEND_I32_S)
            return I64
        end
        return julia_dst === Int64 || julia_dst === UInt64 ? I64 : I32   # already wide, or a ≤32-bit target: no-op

    elseif op === :zext_int
        if julia_dst === Int128 || julia_dst === UInt128
            return _int128_zext!(b, ctx, julia_src, julia_dst)
        elseif (julia_dst === Int64 || julia_dst === UInt64) && !src_already_wide
            julia_src isa Type && normalise_narrow!(b, ctx, julia_src, false)
            num!(b, Opcode.I64_EXTEND_I32_U)
            return I64
        elseif (julia_dst === Int32 || julia_dst === UInt32) && !src_already_wide
            julia_src isa Type && normalise_narrow!(b, ctx, julia_src, false)
            return I32
        end
        return julia_dst === Int64 || julia_dst === UInt64 ? I64 : I32   # already wide, or a no-op target

    elseif op === :trunc_int
        source_is_64bit = julia_src === Int64 || julia_src === UInt64 || julia_src === Int ||
                          src_already_wide
        target_is_32bit = julia_dst === Int32 || julia_dst === UInt32 ||
                          julia_dst === Int16 || julia_dst === UInt16 ||
                          julia_dst === Int8 || julia_dst === UInt8 ||
                          julia_dst === Bool || julia_dst === Char
        if julia_src === Int128 || julia_src === UInt128
            _int128_trunc_lo!(b, ctx, julia_src)
            target_is_32bit && num!(b, Opcode.I32_WRAP_I64)
        elseif source_is_64bit && target_is_32bit
            num!(b, Opcode.I32_WRAP_I64)
        end
        # P3 gap 40da73b299fc: sub-32-bit targets must be width-normalised — bare
        # i32.wrap_i64 is 32-bit truncation. Unsigned targets zero-mask; signed
        # targets sign-extend.
        if julia_dst === Bool
            i32_const!(b, 1)
            num!(b, Opcode.I32_AND)
        elseif julia_dst isa Type
            normalise_narrow!(b, ctx, julia_dst, julia_dst <: Signed)
        end
        return target_is_32bit ? I32 : I64

    elseif op === :sitofp
        # P3 gap 40ed488e7f10: a narrow SIGNED source can sit zero-extended in the
        # i32 register; sign-extend at the consumer (UInt8/UInt16 never legitimately
        # reach sitofp — Julia routes those through uitofp — so `<: Signed` alone,
        # like the arm's own Int8/Int16-only branches, is the exact original set).
        julia_src isa Type && julia_src <: Signed && normalise_narrow!(b, ctx, julia_src, true)
        source_is_32bit = julia_src === Int32 || julia_src === UInt32 || julia_src === Char ||
                          julia_src === Int16 || julia_src === UInt16 ||
                          julia_src === Int8 || julia_src === UInt8 ||
                          (julia_src isa Type && isprimitivetype(julia_src) && sizeof(julia_src) <= 4)
        src_ty = source_is_32bit ? I32 : I64
        dst_ty = julia_dst === Float32 ? F32 : F64
        e = INTRINSIC_CONVERSIONS[(src_ty, dst_ty, :sitofp)]
        e.emit!(b)
        return e.result

    elseif op === :uitofp
        # dart has no unsigned-source shim to anchor to (dart's int has no unsigned
        # variant); this normalise is a genuine WT addition (not an original-arm
        # behaviour) — a narrow UNSIGNED source can carry dirty high bits the same
        # way a narrow signed one does, and f64.convert_i32_u reads the whole
        # register.
        julia_src isa Type && normalise_narrow!(b, ctx, julia_src, false)
        source_is_32bit = julia_src === Int32 || julia_src === UInt32 || julia_src === Char ||
                          julia_src === Int16 || julia_src === UInt16 ||
                          julia_src === Int8 || julia_src === UInt8 ||
                          (julia_src isa Type && isprimitivetype(julia_src) && sizeof(julia_src) <= 4)
        src_ty = source_is_32bit ? I32 : I64
        dst_ty = julia_dst === Float32 ? F32 : F64
        e = INTRINSIC_CONVERSIONS[(src_ty, dst_ty, :uitofp)]
        e.emit!(b)
        return e.result

    elseif op === :fptosi || op === :fptoui
        src_ty = julia_src === Float32 ? F32 : F64
        dst_ty = (op === :fptosi ? (julia_dst === Int32 || julia_dst === Int16 || julia_dst === Int8) :
                                    (julia_dst === UInt32 || julia_dst === UInt16 || julia_dst === UInt8)) ?
                 I32 : I64
        e = INTRINSIC_CONVERSIONS[(src_ty, dst_ty, op)]
        e.emit!(b)
        return e.result

    elseif op === :fpext
        if julia_src === Float16
            # F26 (test/fuzz/FINDINGS.md): Float16 is mis-represented end-to-end —
            # the emulation this replaced silently mishandled zero/-zero/inf/nan/
            # subnormal (measured: 5/8 cases wrong). No test in test/ relies on
            # Float16→Float64 for a value (only the wasm_subtype type-lattice checks
            # reference Float16). A proper fix needs a full Float16 representation
            # overhaul (FINDINGS.md), out of scope here — loud reject instead of a
            # silently-wrong value.
            record_unsupported!(ctx, :unsupported_type,
                "Float16→Float64 conversion (fpext) needs a Float16 representation overhaul (see test/fuzz/FINDINGS.md F26)";
                idx=idx, detail=julia_src)
            unreachable!(b)
            ctx.last_stmt_was_stub = true
            return F64
        end
        e = INTRINSIC_CONVERSIONS[(F32, F64, :fpext)]
        e.emit!(b)
        return e.result

    elseif op === :fptrunc
        # fptrunc(TargetType, value): the source is always Float64, target Float32
        # (the arm never inspected either type argument).
        e = INTRINSIC_CONVERSIONS[(F64, F32, :fptrunc)]
        e.emit!(b)
        return e.result

    else   # :bitcast
        target_type = _resolve_bitcast_target(ctx, julia_dst, idx)
        source_type = julia_src isa Type ? julia_src : Any
        src_ty = source_type === Float64 ? F64 : source_type === Float32 ? F32 :
                 (source_type === Int64 || source_type === UInt64) ? I64 :
                 (source_type === Int32 || source_type === UInt32) ? I32 : nothing
        dst_ty = target_type === Float64 ? F64 : target_type === Float32 ? F32 :
                 (target_type === Int64 || target_type === UInt64) ? I64 :
                 (target_type === Int32 || target_type === UInt32) ? I32 : nothing
        # STACK-003 / Int128<->UInt128 / anything the table doesn't cover: a no-op
        # in Wasm (same representation) — the arm's documented fallthrough.
        if src_ty !== nothing && dst_ty !== nothing
            e = get(INTRINSIC_CONVERSIONS, (src_ty, dst_ty, :bitcast), nothing)
            e !== nothing && e.emit!(b)
            return dst_ty
        end
        return src_ty === nothing ? I32 : src_ty
    end
end
