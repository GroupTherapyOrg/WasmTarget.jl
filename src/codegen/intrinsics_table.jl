# ============================================================================
# parity(intrinsics.dart:437 _binaryOperatorMap): THE INTRINSICS TABLE
# ============================================================================
#
# dart's model: a DECLARATIVE map (lhsType → rhsType → opName → emitter callback),
# consulted by ONE dispatch point. This table replaces that per-site dispatch: the
# calls.jl binary-op arm routes through `emit_intrinsic_binop!` — its ONE
# production caller — ahead of the legacy `is_func` chain, which keeps only
# what the table can't yet express and dies family-by-family through M11.2-.4.
#
# An emitter is `(b, ctx, julia_width) -> Nothing` — it assumes its operands are
# already on the stack AT THEIR TABLE TYPES (the callers' wrap channel guarantees
# that). Most entries ignore `ctx`/`julia_width`; the div/rem entries need `ctx` to
# build the catchable-DivideError guard (_emit_div_guard!, calls.jl — no dart
# equivalent for the trap-vs-throw distinction, quarantined there) and `julia_width`
# for its typemin(width) overflow check, since Int8/Int16 share the I32 register
# with Int32 but have a narrower typemin. One uniform signature (not special-cased
# per entry) keeps the table a single declarative shape, mirroring dart's
# `CodeGenCallback` (intrinsics.dart:437).

"""One typed binary-op emission: a callback (both operands already on the stack, at
this key's wasm types) + result type."""
struct BinOpEmit
    emit!::Function          # (b::InstrBuilder, ctx, julia_width::Int) -> Nothing
    result::WasmValType
end

# (lhs wasm type, rhs wasm type, julia op symbol) → emission.
# Mirrors dart's _binaryOperatorMap shape; Julia's INTRINSIC names (add_int etc.)
# are the op keys — the surface operators lower to these in typed IR.
const INTRINSIC_BINOPS = Dict{Tuple{WasmValType,WasmValType,Symbol},BinOpEmit}(
    # ── i64 × i64 ────────────────────────────────────────────────────────
    (I64, I64, :add_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_ADD), I64),
    (I64, I64, :sub_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_SUB), I64),
    (I64, I64, :mul_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_MUL), I64),
    (I64, I64, :and_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_AND), I64),
    (I64, I64, :or_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_OR), I64),
    (I64, I64, :xor_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_XOR), I64),
    # parity(boxed_int.dart:54 BoxedInt._truncDiv): dart's `~/` entry calls a helper
    # that guards divisor==0 and MIN_INT÷-1 before the raw op; these entries do the
    # same through _emit_div_guard! (calls.jl), throwing a catchable DivideError.
    # Julia's div/rem lower to the checked_* names, so both spellings land here.
    # `jw` is the call site's actual Julia bit width (8/16/32/64): Int8/Int16 share
    # the I32 register with Int32 but have a narrower `typemin` for the overflow check.
    (I64, I64, :sdiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false; check_overflow=true, julia_width=jw); num!(b, Opcode.I64_DIV_S)), I64),
    (I64, I64, :checked_sdiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false; check_overflow=true, julia_width=jw); num!(b, Opcode.I64_DIV_S)), I64),
    (I64, I64, :udiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_DIV_U)), I64),
    (I64, I64, :checked_udiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_DIV_U)), I64),
    (I64, I64, :srem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_REM_S)), I64),
    (I64, I64, :checked_srem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_REM_S)), I64),
    (I64, I64, :urem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_REM_U)), I64),
    (I64, I64, :checked_urem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, false); num!(b, Opcode.I64_REM_U)), I64),
    (I64, I64, :eq_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_EQ), I32),
    (I64, I64, :ne_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_NE), I32),
    (I64, I64, :slt_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_LT_S), I32),
    (I64, I64, :sle_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_LE_S), I32),
    (I64, I64, :ult_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_LT_U), I32),
    (I64, I64, :ule_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I64_LE_U), I32),
    # ── i32 × i32 ────────────────────────────────────────────────────────
    (I32, I32, :add_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_ADD), I32),
    (I32, I32, :sub_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_SUB), I32),
    (I32, I32, :mul_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_MUL), I32),
    (I32, I32, :and_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_AND), I32),
    (I32, I32, :or_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_OR), I32),
    (I32, I32, :xor_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_XOR), I32),
    # (ALL shifts excluded: Julia shift AMOUNTS vary in width independently of the
    # value — i64<<i32, i32<<i64 — mixed-width doesn't fit the uniform key; the
    # legacy arms coerce the amount. dart's ints are uniformly i64: no such case.)
    (I32, I32, :sdiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true; check_overflow=true, julia_width=jw); num!(b, Opcode.I32_DIV_S)), I32),
    (I32, I32, :checked_sdiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true; check_overflow=true, julia_width=jw); num!(b, Opcode.I32_DIV_S)), I32),
    (I32, I32, :udiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_DIV_U)), I32),
    (I32, I32, :checked_udiv_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_DIV_U)), I32),
    (I32, I32, :srem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_REM_S)), I32),
    (I32, I32, :checked_srem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_REM_S)), I32),
    (I32, I32, :urem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_REM_U)), I32),
    (I32, I32, :checked_urem_int) => BinOpEmit((b, ctx, jw) -> (_emit_div_guard!(b, ctx, true); num!(b, Opcode.I32_REM_U)), I32),
    (I32, I32, :eq_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_EQ), I32),
    (I32, I32, :ne_int)   => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_NE), I32),
    (I32, I32, :slt_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_LT_S), I32),
    (I32, I32, :sle_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_LE_S), I32),
    (I32, I32, :ult_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_LT_U), I32),
    (I32, I32, :ule_int)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.I32_LE_U), I32),
    # ── f64 × f64 ────────────────────────────────────────────────────────
    (F64, F64, :add_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_ADD), F64),
    (F64, F64, :sub_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_SUB), F64),
    (F64, F64, :mul_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_MUL), F64),
    (F64, F64, :div_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_DIV), F64),
    (F64, F64, :eq_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_EQ), I32),
    (F64, F64, :ne_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_NE), I32),
    (F64, F64, :lt_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_LT), I32),
    (F64, F64, :le_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_LE), I32),
    (F64, F64, :gt_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_GT), I32),
    (F64, F64, :ge_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_GE), I32),
    (F64, F64, :copysign_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_COPYSIGN), F64),
    (F64, F64, :min_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_MIN), F64),
    (F64, F64, :min_float_fast) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_MIN), F64),
    (F64, F64, :max_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_MAX), F64),
    (F64, F64, :max_float_fast) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F64_MAX), F64),
    # ── f32 × f32 ────────────────────────────────────────────────────────
    (F32, F32, :add_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_ADD), F32),
    (F32, F32, :sub_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_SUB), F32),
    (F32, F32, :mul_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_MUL), F32),
    (F32, F32, :div_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_DIV), F32),
    (F32, F32, :eq_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_EQ), I32),
    (F32, F32, :ne_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_NE), I32),
    (F32, F32, :lt_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_LT), I32),
    (F32, F32, :le_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_LE), I32),
    (F32, F32, :gt_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_GT), I32),
    (F32, F32, :ge_float)  => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_GE), I32),
    (F32, F32, :copysign_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_COPYSIGN), F32),
    (F32, F32, :min_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_MIN), F32),
    (F32, F32, :min_float_fast) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_MIN), F32),
    (F32, F32, :max_float) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_MAX), F32),
    (F32, F32, :max_float_fast) => BinOpEmit((b, ctx, jw) -> num!(b, Opcode.F32_MAX), F32),
)

"""
    emit_intrinsic_binop!(b, lhs_ty, rhs_ty, op, ctx=nothing, julia_width=default) -> Union{WasmValType,Nothing}

THE dispatch point (dart code_generator: one lookup, one emission). Operands are on
the stack at (lhs_ty, rhs_ty). Returns the result type, or `nothing` when the table
has no entry (the caller keeps its legacy arm until its family migrates). `ctx` and
`julia_width` are trailing/optional: only the div/rem entries read them (`ctx` to
build the DivideError guard, `julia_width` for its overflow check — see the table's
header comment); every other entry ignores both, so a caller that never reaches a
div/rem key (e.g. the M11.1 table smoke test) may omit them.
"""
function emit_intrinsic_binop!(b::InstrBuilder, lhs_ty::WasmValType, rhs_ty::WasmValType,
                               op::Symbol, ctx=nothing, julia_width::Int=(lhs_ty === I32 ? 32 : 64))
    e = get(INTRINSIC_BINOPS, (lhs_ty, rhs_ty, op), nothing)
    e === nothing && return nothing
    e.emit!(b, ctx, julia_width)
    return e.result
end

# ============================================================================
# parity(intrinsics.dart:474 _unaryOperatorMap, :1007 _inlineUnaryOperatorMap
# lookup): THE UNARY INTRINSICS TABLE
# ============================================================================
#
# dart's unary map is keyed on the operand's canonical wasm type and an op
# name, and its values are CALLBACKS — most are one instruction, but two of
# dart's seven entries emit two instructions (`~` = const -1; xor, `unary-`
# = const -1; mul, intrinsics.dart:477-484). The result type is
# `_unaryResultMap[op]` when present, else the operand type (intrinsics.dart:
# 578-583, :1010).

"""One typed unary-op emission: a callback (operand already on the stack) + result type."""
struct UnOpEmit
    emit!::Function          # (b::InstrBuilder) -> Nothing
    result::WasmValType
end

# (operand wasm type, julia op symbol) → emission.
const INTRINSIC_UNOPS = Dict{Tuple{WasmValType,Symbol},UnOpEmit}(
    # ── count leading/trailing zeros, population count (i32/i64) ──────────
    (I32, :ctlz_int)  => UnOpEmit(b -> num!(b, Opcode.I32_CLZ),    I32),
    (I64, :ctlz_int)  => UnOpEmit(b -> num!(b, Opcode.I64_CLZ),    I64),
    (I32, :cttz_int)  => UnOpEmit(b -> num!(b, Opcode.I32_CTZ),    I32),
    (I64, :cttz_int)  => UnOpEmit(b -> num!(b, Opcode.I64_CTZ),    I64),
    (I32, :ctpop_int) => UnOpEmit(b -> num!(b, Opcode.I32_POPCNT), I32),
    (I64, :ctpop_int) => UnOpEmit(b -> num!(b, Opcode.I64_POPCNT), I64),
    # ── float unary (f32/f64) ──────────────────────────────────────────────
    (F32, :neg_float)      => UnOpEmit(b -> num!(b, Opcode.F32_NEG),     F32),
    (F64, :neg_float)      => UnOpEmit(b -> num!(b, Opcode.F64_NEG),     F64),
    (F32, :abs_float)      => UnOpEmit(b -> num!(b, Opcode.F32_ABS),     F32),
    (F64, :abs_float)      => UnOpEmit(b -> num!(b, Opcode.F64_ABS),     F64),
    (F32, :sqrt_llvm)      => UnOpEmit(b -> num!(b, Opcode.F32_SQRT),    F32),
    (F64, :sqrt_llvm)      => UnOpEmit(b -> num!(b, Opcode.F64_SQRT),    F64),
    (F32, :sqrt_llvm_fast) => UnOpEmit(b -> num!(b, Opcode.F32_SQRT),    F32),
    (F64, :sqrt_llvm_fast) => UnOpEmit(b -> num!(b, Opcode.F64_SQRT),    F64),
    (F32, :floor_llvm)     => UnOpEmit(b -> num!(b, Opcode.F32_FLOOR),   F32),
    (F64, :floor_llvm)     => UnOpEmit(b -> num!(b, Opcode.F64_FLOOR),   F64),
    (F32, :ceil_llvm)      => UnOpEmit(b -> num!(b, Opcode.F32_CEIL),    F32),
    (F64, :ceil_llvm)      => UnOpEmit(b -> num!(b, Opcode.F64_CEIL),    F64),
    (F32, :trunc_llvm)     => UnOpEmit(b -> num!(b, Opcode.F32_TRUNC),   F32),
    (F64, :trunc_llvm)     => UnOpEmit(b -> num!(b, Opcode.F64_TRUNC),   F64),
    (F32, :rint_llvm)      => UnOpEmit(b -> num!(b, Opcode.F32_NEAREST), F32),
    (F64, :rint_llvm)      => UnOpEmit(b -> num!(b, Opcode.F64_NEAREST), F64),
    # ── bitwise NOT (i32/i64): dart's `~` = const -1; xor (intrinsics.dart:481-484) ──
    (I32, :not_int) => UnOpEmit(b -> (i32_const!(b, -1); num!(b, Opcode.I32_XOR)), I32),
    (I64, :not_int) => UnOpEmit(b -> (i64_const!(b, -1); num!(b, Opcode.I64_XOR)), I64),
    # ── integer negation (i32/i64): dart's `unary-` = const -1; mul
    #    (intrinsics.dart:477-480).
    (I32, :neg_int) => UnOpEmit(b -> (i32_const!(b, -1); num!(b, Opcode.I32_MUL)), I32),
    (I64, :neg_int) => UnOpEmit(b -> (i64_const!(b, -1); num!(b, Opcode.I64_MUL)), I64),
)

"""
    emit_intrinsic_unop!(b, operand_ty, op) -> Union{WasmValType,Nothing}

THE unary dispatch point (dart's `_inlineUnaryOperatorMap` lookup, intrinsics.dart:1007).
Operand is on the stack at `operand_ty`. Returns the result type, or `nothing` when the
table has no entry — nullable-return fall-through (the caller keeps its legacy arm/ladder
until the family migrates).
"""
function emit_intrinsic_unop!(b::InstrBuilder, operand_ty::WasmValType, op::Symbol)::Union{WasmValType,Nothing}
    e = get(INTRINSIC_UNOPS, (operand_ty, op), nothing)
    e === nothing && return nothing
    e.emit!(b)
    return e.result
end

# ============================================================================
# NUMERIC-INTRINSIC ARG-HANDLING GATE (`compile_call!`'s pre-push guard: type-
# instability rejection for a boxed/Any operand, register-width bridging, and
# anyref/externref unboxing before an intrinsic consumes its args)
# ============================================================================
#
# NOT a raw "is this op in either table" membership query. That was tried first:
# the gate's unboxing sites hardcode their unbox TARGET as `is_32bit ? I32 : I64`
# (compile_call!'s `_aa_target`/`target_wasm`) — correct for every op below, but
# WRONG for a float op (add_float, sqrt_llvm, …): a boxed Float64 would unbox
# into an I64 register instead of F64. Full table membership would also add
# ctlz/cttz/ctpop/neg_int silently (harmless — same int-width shape as the ops
# already here) alongside the float breakage, so it isn't a safe drop-in either
# way. This is the curated int-only, register-width-symmetric subset the gate
# was actually written for — same 13 ops `is_numeric_intrinsic` named one-by-one
# before this table existed; kept as a Set (not an `is_func(func, :key)` chain)
# so the gate reads as ONE membership check instead of a ladder R22 must track.
const NUMERIC_INTRINSIC_ARG_OPS = Set{Symbol}((
    :eq_int, :ne_int, :slt_int, :sle_int, :ult_int, :ule_int,
    :add_int, :sub_int, :mul_int,
    :not_int, :or_int, :xor_int, :and_int,
))

"""True when `func` names one of `NUMERIC_INTRINSIC_ARG_OPS` — same name-extraction
rule `_it_name` uses (GlobalRef / Core.IntrinsicFunction), so this is a drop-in for
a chain of individual per-op `is_func` name checks, ORed together, that it replaces."""
function is_numeric_intrinsic_arg(func)::Bool
    name = func isa GlobalRef ? func.name :
           func isa Core.IntrinsicFunction ? Symbol(func) : nothing
    return name !== nothing && name in NUMERIC_INTRINSIC_ARG_OPS
end
