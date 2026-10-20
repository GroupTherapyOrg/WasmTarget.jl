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
    :sdiv_int  => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=true,  rem=false); _int128_structref(ctx, t)),
    :udiv_int  => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=false, rem=false); _int128_structref(ctx, t)),
    :srem_int  => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=true,  rem=true);  _int128_structref(ctx, t)),
    :urem_int  => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=false, rem=true);  _int128_structref(ctx, t)),
    :checked_sdiv_int => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=true,  rem=false); _int128_structref(ctx, t)),
    :checked_udiv_int => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=false, rem=false); _int128_structref(ctx, t)),
    :checked_srem_int => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=true,  rem=true);  _int128_structref(ctx, t)),
    :checked_urem_int => (b, ctx, t) -> (emit_int128_divrem!(b, ctx, t; signed=false, rem=true);  _int128_structref(ctx, t)),
    :bswap_int => (b, ctx, t) -> (emit_int128_bswap!(b, ctx, t); _int128_structref(ctx, t)),
)

"""
    emit_int128_op!(b, ctx, op, arg_type, call, idx) -> Union{WasmValType,Nothing}

THE Int128/UInt128 dispatch point, consulted from `compile_call!` right where the
`!is_128bit`-guarded intrinsics table routes leave off (mirrors `emit_intrinsic_binop!`
and `emit_intrinsic_unop!`'s nullable-return contract). Operands are already on `b`'s
stack (the same operand emission the residue arms relied on); `arg_type` is the
caller's already-inferred Int128/UInt128 source type (the same value the residue arms
were passed — recomputing it here would be a second reader of its type, L174).
Returns `nothing` when `op` is not one of this tier's ops.

On a hit, finishes exactly like the intrinsics table routes: the SSA result gets the
same rebox check (a numeric result flowing into a ref-typed local boxes through
`emit_classid_box!`, keyed on the real Julia source type — dart's `convertType`).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64,
translator.dart:346 — so Julia's `*_int` intrinsics on a 128-bit operand need their own
dispatch onto the two-i64 limb-struct emitters of int128.jl.)
"""
function emit_int128_op!(b::InstrBuilder, ctx, op::Symbol, arg_type, call::NirCall, idx::Int)::Union{WasmValType,Nothing}
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
                    idx=idx, detail=call)
            emit_classid_box!(b, ctx, result, arg_type)
        end
    end
    return result
end

# ============================================================================
# Checked-overflow registry (checked_s{add,sub,mul}_int / checked_u{add,sub,mul}_int)
# ============================================================================
#
# A pure move of the six arms that used to sit at the head of `compile_call!`'s
# ladder (`_compile_call_checked!` in calls.jl tests the Dict key `op` directly — a
# data test, R19 — instead of re-deriving identity via `is_func`; all six keys forward
# to the one dispatcher).
# parity(quarantine: Julia's checked_*_int intrinsics answer a value and an overflow flag; dart's ints wrap.)
const _checked_dispatch = (fbref, ctx, op, args, is_128bit, is_32bit, arg_type, idx) ->
    _compile_call_checked!(fbref, ctx, op, args, is_128bit, is_32bit, arg_type, idx)
# parity(quarantine: no dart equivalent — dart's `int` wraps silently on overflow,
# translator.dart never traps or returns a flag; the `Tuple{T,Bool}` contract is
# purely Julia's `Base.Checked` surface of checked_{s,u}{add,sub,mul}_int.)
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
# entry to anchor to). `muladd_float` and `fma_float` round once: each calls Julia's own
# software fma, `Base.fma_emulated`, which the collector enrolls wherever either intrinsic
# appears (trimcollect.jl `_fused_multiply_add_mis`). `have_fma` then answers true, as it
# does natively on any host with an FMA unit. Native Julia fuses `muladd` on such a host,
# so the single rounding is native's answer; the two roundings of `mul; add` were not,
# and made Julia's own `exp`, `expm1` and `acos` differ from native in the last bit, while
# `have_fma = false` sent `hypot` down its fallback branch.
const FMA_OPS = Dict{Symbol,Function}(
    :muladd_float => (fb, ctx, arg_type) -> _emit_fused_multiply_add!(fb, ctx, arg_type),
    :fma_float => (fb, ctx, arg_type) -> _emit_fused_multiply_add!(fb, ctx, arg_type),
    :have_fma => (fb, ctx, arg_type) -> (i32_const!(fb, 1); I32),
)

"""
    _emit_fused_multiply_add!(fb, ctx, T) -> WasmValType

`muladd_float`/`fma_float` over the three operands on the stack, in order: a call of
Julia's `Base.fma_emulated(::T, ::T, ::T)`, which rounds once.
parity(quarantine: WASM has no scalar FMA instruction; Julia's own software fma is the body
its `fma` runs without one.)
"""
function _emit_fused_multiply_add!(fb::InstrBuilder, ctx, T)::WasmValType
    numeric_register(T) in (F32, F64) ||
        error("a fused multiply-add over $(T) reached codegen; the collector enrolls Float32 and Float64 only")
    # the MethodInstance the collector rooted for this lowering (_fused_multiply_add_mis), recorded
    # on the plan
    local fma_mi = plan_lowering_callee(ctx.translator.plan, Tuple{typeof(Base.fma_emulated), T, T, T})
    info = fma_mi === nothing ? nothing : get_function_by_mi(ctx.func_registry, fma_mi)
    info === nothing && error("Base.fma_emulated(::$T, ::$T, ::$T) is not in the closed world")
    local w = julia_to_wasm_type(T)
    call!(fb, info.wasm_idx)
    return w
end

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
    emit_julia_numeric!(fbref, ctx, op, args, arg_type, is_128bit, is_32bit, idx) -> Union{WasmValType,Nothing}

THE Julia-only numeric quarantine dispatch, consulted from `compile_call!`
right where THE Int128/UInt128 registry route leaves off (mirrors
`emit_int128_op!`'s nullable-return contract). Tries CHECKED_OPS, SHIFT_OPS,
FMA_OPS, then MISC_OPS in turn; `nothing` means none of the four claim `op` —
the caller's legacy ladder (bitcast, `===`/`!==`, sext/zext/trunc, …) keeps
handling it. `op` is the caller's single extracted callee-identity Symbol
(R19: every entry tests IT, a data value, never re-deriving identity from the
raw callee via `is_func`) — there is no `func` parameter here at all.

`fbref` is a `Ref{InstrBuilder}` rather than a plain `InstrBuilder`: only
CHECKED_OPS's is_128bit add/sub reject ever needs to REPLACE the builder (see
`_compile_call_checked_add!`'s docstring); every other entry just appends to
`fbref[]`. No result rebox is needed here: these ops take the machine numerics
Julia's IR states for their operands.
parity(quarantine: dispatch over Julia intrinsics dart2wasm has no counterpart for —
checked_*_int (overflow flag), mixed-width shl/ashr/lshr_int, muladd/fma_float/have_fma,
bswap_int, flipsign_int; dart's `int` is one i64 with a fixed operator map,
intrinsics.dart:437.)
"""
function emit_julia_numeric!(fbref::Base.RefValue{InstrBuilder}, ctx, op::Symbol, args,
                             arg_type, is_128bit::Bool, is_32bit::Bool,
                             idx::Int)::Union{WasmValType,Nothing}
    if haskey(CHECKED_OPS, op)
        return CHECKED_OPS[op](fbref, ctx, op, args, is_128bit, is_32bit, arg_type, idx)
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
# living in i32, so a narrow value is re-normalised before an op or a widening reads
# its register; dart's `int` is uniformly i64, translator.dart:346, and narrows only
# at an explicit dart:_wasm conversion). The emitted shapes are dart's narrowing arms:
# `extend8_s` (intrinsics.dart:2037 wasmI32Int8FromInt), `and 0xFF` (:2043
# wasmI32Uint8FromInt), `extend16_s` (:2050 wasmI32Int16FromInt), `and 0xFFFF` (:2056
# wasmI32Uint16FromInt).
"""
    normalise_narrow!(b, ctx, julia_type::Type, signed::Bool)

THE wrap channel: for a value of `julia_type` already on `b`'s stack, held in its register
(numeric_register) with junk above its width, emits its sign replicated upward or its bits
above its width cleared, by its type's own bits (`_julia_int_width`, 8*sizeof: Julia's
intrinsics read jl_datatype_size), through emit_extend_from_width!; a no-op for a register
that holds exactly its value (exact_register: 32 or 64 bits, a Bool) and for a primitive as
wide as its register. `signed` is the CALLER's interpretation of the bits — independent of
`julia_type`'s own signedness (e.g. `ult_int` normalises an Int8 operand unsigned; `zext_int`
always normalises unsigned regardless of source signedness).
"""
function normalise_narrow!(b::InstrBuilder, ctx,
                           julia_type::Type, signed::Bool)::InstrBuilder
    # a register that holds exactly its value (a Bool's 0 or 1, exact_register) carries no junk
    exact_register(julia_type) === nothing || return b
    return emit_extend_from_width!(b, numeric_register(julia_type), _operand_width(julia_type), signed)
end

"""
    emit_extend_from_width!(b, reg, width, signed) -> b

`[reg] -> [reg]`: the `width`-bit integer held in an i32 or i64 register `reg` with junk above
its width, made the register's value: its bit `width-1` replicated upward (`signed`) or its
bits above `width` cleared; a no-op at the register's own width. The 8- and 16-bit arms in an
i32 are dart's narrowing shapes (`extend8_s`, `extend16_s`, `and 0xFF`, `and 0xFFFF`); any
other width (a 24-bit primitive in an i32, a 40-, 48- or 56-bit one in an i64) shifts its sign
bit to the register's top and back (`shl`, `shr_s`) or masks.
parity(intrinsics.dart:2037 wasmI32Int8FromInt): the narrowing arms, at every width.
"""
function emit_extend_from_width!(b::InstrBuilder, reg::Union{Nothing,NumType}, width::Integer, signed::Bool)::InstrBuilder
    local bits = reg === I32 ? 32 : reg === I64 ? 64 :
                 error("a $(width)-bit integer held in $(reg), which is no integer register")
    1 <= width <= bits || error("a $(width)-bit integer cannot be held in an i$(bits) register")
    width < bits || return b
    local c = v -> reg === I32 ? i32_const!(b, Int64(v)) : i64_const!(b, Int64(v))
    if signed && reg === I32 && (width == 8 || width == 16)
        num!(b, width == 8 ? Opcode.I32_EXTEND8_S : Opcode.I32_EXTEND16_S)
    elseif signed
        c(bits - width); num!(b, reg === I32 ? Opcode.I32_SHL : Opcode.I64_SHL)
        c(bits - width); num!(b, reg === I32 ? Opcode.I32_SHR_S : Opcode.I64_SHR_S)
    else
        c((Int64(1) << width) - 1); num!(b, reg === I32 ? Opcode.I32_AND : Opcode.I64_AND)
    end
    return b
end

# ============================================================================
# Conversions registry (sext_int/zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/
# fpext/fptrunc/bitcast)
# ============================================================================
#
# dart lowers these conversions as switch arms of generateInstanceIntrinsic /
# generateStaticIntrinsic (anchored at INTRINSIC_CONVERSIONS below); Julia names them
# as intrinsics with explicit (source, target) types, so they are keyed here in the
# shape of dart's _binaryOperatorMap. Mirrors intrinsics_table.jl's BinOpEmit/UnOpEmit
# shape: a callback (source value already on the stack, at this key's wasm type) +
# result type, keyed on (source wasm type, target wasm type, julia op symbol) for the
# CANONICAL-WIDTH cases. Narrow Int8/16/UInt8/16 operands are NOT separate table
# rows (dart has no such distinction to mirror) — `emit_conversion!` wraps the table
# lookup with `normalise_narrow!` pre/post steps, exactly as the callers of
# INTRINSIC_BINOPS narrow-normalise before consulting that table.

"""One typed conversion emission: a callback (source value already on the stack) +
result type.
parity(intrinsics.dart:17 CodeGenCallback) — the map's value type, as BinOpEmit."""
struct ConvEmit
    emit!::Function          # (b::InstrBuilder) -> Nothing
    result::WasmValType
end

# parity(intrinsics.dart:710 wasmTypesBaseClass) — dart's Wasm(I32|I64|F32|F64)
# conversion arms: toIntSigned :739 (i64.extend_i32_s), toIntUnsigned :742
# (i64.extend_i32_u), f32 toDouble :882 (f64.promote_f32), truncSatS :894; with
# wasmI32FromInt :2032 (i32.wrap_i64), _unaryOperatorMap toDouble :485
# (f64.convert_i64_s), and the bit-reinterpret arms floatToIntBits :1523 …
# intBitsToDouble :1548. Held as a map in the shape of intrinsics.dart:437.
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
    # bitcast reinterpret pairs, as dart's doubleToIntBits/intBitsToDouble
    # (intrinsics.dart:1541, :1548). Same-register pairs (Int32<->UInt32, Int64<->
    # UInt64, Char<->Int32/UInt32 — STACK-003: Char's internal rep IS a packed
    # UInt32) and Int128<->UInt128 are no instruction and carry NO table row
    # (emit_bitcast! emits nothing where the registers agree).
    (F64, I64, :bitcast) => ConvEmit(b -> num!(b, Opcode.I64_REINTERPRET_F64), I64),
    (I64, F64, :bitcast) => ConvEmit(b -> num!(b, Opcode.F64_REINTERPRET_I64), F64),
    (F32, I32, :bitcast) => ConvEmit(b -> num!(b, Opcode.I32_REINTERPRET_F32), I32),
    (I32, F32, :bitcast) => ConvEmit(b -> num!(b, Opcode.F32_REINTERPRET_I32), F32),
)

"""
    emit_bitcast!(b, from, to) -> b

Julia's `bitcast(to, x::from)` of a primitive value already on the stack, `from` and `to` of one
size: the conversion table's `:bitcast` entry between their registers (the width rule's
julia_to_wasm_type), nothing where the registers agree.
parity(pkg/dart2wasm/lib/intrinsics.dart:1541 StaticIntrinsic.doubleToIntBits): dart reinterprets
a double's bits as an int by i64.reinterpret_f64 (intBitsToDouble :1548 the reverse, floatToIntBits
:1523 through f32); Julia's bitcast takes both types as operands.
"""
function emit_bitcast!(b::InstrBuilder, @nospecialize(from), @nospecialize(to))::InstrBuilder
    local fw, tw = julia_to_wasm_type(from), julia_to_wasm_type(to)
    fw === tw && return b
    local e = get(INTRINSIC_CONVERSIONS, (fw, tw, :bitcast), nothing)
    e === nothing && error("no bitcast from $(from) to $(to): their registers are $(fw) and $(tw)")
    e.emit!(b)
    return b
end

# Int128/UInt128 conversion bodies for sext_int/zext_int/trunc_int — pure moves of
# the struct_new!/struct_get! logic the arms had. Kept OUT of INT128_OPS (whose
# `(b, ctx, t) -> WasmValType` signature is for a same-type arithmetic/bitwise op; a
# conversion needs BOTH a source and a target type, a different shape) and consulted
# directly from `emit_conversion!` rather than through `emit_int128_op!`'s
# is_128bit-gated route: sext/zext INTO Int128 have a narrow, non-128-bit SOURCE, so
# that gate (keyed on the call's general operand type) never fires for them.
# parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64,
# translator.dart:346; Julia's sext_int into a 128-bit target builds the two-i64 limb struct.)
function _int128_sext!(b::InstrBuilder, ctx,
                       source_type::Type, target_type::Type)::ConcreteRef
    if julia_to_wasm_type(source_type) === I32
        # a narrow source's register may hold junk above its width, or its unsigned bits: its
        # sign is the bit at its own width (sext_int(Int128, 0x80) is -128)
        normalise_narrow!(b, ctx, source_type, true)
        num!(b, Opcode.I64_EXTEND_I32_S)
    end
    scratch_idx = allocate_local!(ctx, I64)
    local_tee!(b, scratch_idx)
    i64_const!(b, 63)
    num!(b, Opcode.I64_SHR_S)
    scratch2_idx = allocate_local!(ctx, I64)
    local_set!(b, scratch2_idx)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, target_type)))
    local_get!(b, scratch_idx)
    local_get!(b, scratch2_idx)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
    struct_new!(b, type_idx)
    return _int128_structref(ctx, target_type)
end

# parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64,
# translator.dart:346; Julia's zext_int into a 128-bit target builds the two-i64 limb struct.)
function _int128_zext!(b::InstrBuilder, ctx,
                       source_type::Type, target_type::Type)::ConcreteRef
    if julia_to_wasm_type(source_type) === I32
        normalise_narrow!(b, ctx, source_type, false)   # a narrow source's dirty high bits masked
        num!(b, Opcode.I64_EXTEND_I32_U)
    end
    zext_scratch = allocate_local!(ctx, I64)
    local_set!(b, zext_scratch)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, target_type)))
    local_get!(b, zext_scratch)
    i64_const!(b, 0)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, target_type)
    struct_new!(b, type_idx)
    return _int128_structref(ctx, target_type)
end

# parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64,
# translator.dart:346; Julia's trunc_int from a 128-bit source reads the struct's lo limb.)
function _int128_trunc_lo!(b::InstrBuilder, ctx, source_type::Type)::NumType
    source_type_idx = get_int128_type!(ctx.mod, ctx.type_registry, source_type)
    struct_get!(b, source_type_idx, UInt32(1))  # field 1 = lo (0 = typeId)
    return I64
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
emits (possibly nothing, for a same-register pair) and returns the target's register (the
128-bit integers' struct reference), or calls `record_unsupported!`: an integer conversion whose
target is held in no integer register rejects, never a default register.

`julia_src` is the source value's type and `julia_dst` the target type, which the caller
resolved once from the operand (a literal type, or a constant global naming one) for all ten
ops, rejecting any other at the statement (calls.jl): each is a type, never a default. A
register is the one width rule's (julia_to_wasm_type through numeric_register), and the one
widening rule normalises a source narrower than its register before any op reads it widened:
sext_int and sitofp read its sign at its own width, zext_int and uitofp its bits, whatever its
type and whatever register the target has (a narrow register carries junk above its width,
calls.jl's narrow-register invariant). `src_already_wide` is
`get_phi_edge_wasm_type(args[2], ctx) === I64` — a widened phi local of a type held in an i32
already occupies the full register, so sext_int/zext_int must not re-extend it, and trunc_int must treat it as a 64-bit
source even when the Julia type looks narrower.
parity(quarantine: Julia's typed IR carries sext_int/zext_int/trunc_int/sitofp/uitofp/
fptosi/fptoui/fpext/fptrunc/bitcast as intrinsic calls with an explicit target type and
narrow Int8/Int16 sources; dart's conversions are per-class methods on one i64 `int`
(intrinsics.dart:710), so the Julia op/width selection before the table lookup is Julia's.)
"""
function emit_conversion!(b::InstrBuilder, ctx, op::Symbol,
                          @nospecialize(julia_src), @nospecialize(julia_dst), idx::Int;
                          src_already_wide::Bool=false)::Union{WasmValType,Nothing}
    op in (:sext_int, :zext_int, :trunc_int, :sitofp, :uitofp, :fptosi, :fptoui,
           :fpext, :fptrunc, :bitcast) || return nothing

    # a located rejection: the statement has no faithful lowering, and the code after its trap
    # is unreachable (its result, an i32, is the polymorphic stack's, read by nothing)
    local function reject!(why)
        record_unsupported!(ctx, :unsupported_type, "$(op) from $(julia_src) to $(julia_dst): $(why)"; idx=idx)
        unreachable!(b)
        ctx.last_stmt_was_stub = true
        return I32
    end
    (julia_src isa Type && julia_dst isa Type) ||
        return reject!("its source or target is not a type")
    local src_reg, dst_reg = numeric_register(julia_src), numeric_register(julia_dst)
    local src_128 = _julia_int_width(julia_src) == 128
    local dst_128 = _julia_int_width(julia_dst) == 128
    # a primitive wider than every register that is no 128-bit integer has no representation
    (isprimitivetype(julia_src) && src_reg === nothing && !src_128) &&
        return reject!("a $(sizeof(julia_src))-byte primitive other than Int128 and UInt128 has no representation")
    (isprimitivetype(julia_dst) && dst_reg === nothing && !dst_128) &&
        return reject!("a $(sizeof(julia_dst))-byte primitive other than Int128 and UInt128 has no representation")
    # the conversion table's entry between two registers, or a located rejection: a pair the table
    # has no entry for (a Float16, held in an i32, converted to or from a float) has no faithful value
    local function table!(src_ty, dst_ty, key)
        local e = get(INTRINSIC_CONVERSIONS, (src_ty, dst_ty, key), nothing)
        e === nothing && return reject!("the conversion table has no entry from $(src_ty) to $(dst_ty)")
        e.emit!(b)
        return e.result
    end
    # an integer conversion's target is a 128-bit integer or held in an i32 or an i64
    (op in (:sext_int, :zext_int, :trunc_int) && !dst_128 && !(dst_reg === I32 || dst_reg === I64)) &&
        return reject!("its target is held in no integer register")
    # a source held wider than its own register (a widened phi local) is already its value
    local widened = src_already_wide && src_reg === I32
    if op === :sext_int
        dst_128 && return _int128_sext!(b, ctx, julia_src, julia_dst)
        widened && return dst_reg
        normalise_narrow!(b, ctx, julia_src, true)   # the one widening rule: its sign at its width
        (src_reg === I32 && dst_reg === I64) && return table!(I32, I64, :sext_int)
        return dst_reg

    elseif op === :zext_int
        dst_128 && return _int128_zext!(b, ctx, julia_src, julia_dst)
        widened && return dst_reg
        normalise_narrow!(b, ctx, julia_src, false)   # the one widening rule: its bits
        (src_reg === I32 && dst_reg === I64) && return table!(I32, I64, :zext_int)
        return dst_reg

    elseif op === :trunc_int
        source_is_64bit = src_reg === I64 || src_already_wide
        target_is_32bit = dst_reg === I32
        if src_128
            _int128_trunc_lo!(b, ctx, julia_src)
            target_is_32bit && INTRINSIC_CONVERSIONS[(I64, I32, :trunc_int)].emit!(b)
        elseif source_is_64bit && target_is_32bit
            INTRINSIC_CONVERSIONS[(I64, I32, :trunc_int)].emit!(b)
        end
        # P3 gap 40da73b299fc: sub-32-bit targets must be width-normalised — bare
        # i32.wrap_i64 is 32-bit truncation. Unsigned targets zero-mask; signed
        # targets sign-extend.
        if julia_dst === Bool
            i32_const!(b, 1)
            num!(b, Opcode.I32_AND)
        else
            normalise_narrow!(b, ctx, julia_dst, julia_dst <: Signed)
        end
        return target_is_32bit ? I32 : I64

    elseif op === :sitofp
        normalise_narrow!(b, ctx, julia_src, true)    # the one widening rule: its sign at its width
        return table!(src_reg, dst_reg, :sitofp)

    elseif op === :uitofp
        normalise_narrow!(b, ctx, julia_src, false)   # the one widening rule: its bits
        return table!(src_reg, dst_reg, :uitofp)

    elseif op === :fptosi || op === :fptoui
        return table!(src_reg, dst_reg, op)

    elseif op === :fpext || op === :fptrunc
        # Float16 is mis-represented end-to-end — the emulation this replaced silently
        # mishandled zero/-zero/inf/nan/subnormal (measured: 5/8 cases wrong); a proper fix
        # needs a full Float16 representation overhaul — loud reject instead of a
        # silently-wrong value.
        Float16 in (julia_src, julia_dst) &&
            return reject!("Float16 has no faithful representation yet")
        return table!(src_reg, dst_reg, op)

    else   # :bitcast
        # a primitive held in one register converts by the table's bitcast; the two 128-bit
        # integers share one representation, no instruction
        src_reg !== nothing && dst_reg !== nothing && (emit_bitcast!(b, julia_src, julia_dst); return dst_reg)
        (src_128 && dst_128) && return _int128_structref(ctx, julia_src)
        return reject!("bitcast between registers $(src_reg === nothing ? "none" : src_reg) and $(dst_reg === nothing ? "none" : dst_reg)")
    end
end
