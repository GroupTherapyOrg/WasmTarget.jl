# Byte-identity probe lane (dev/MARCH.md §4 Phase 1 item 4, §5 "byte identity").
#
# Purpose: a fast, deterministic fingerprint of a fixed probe corpus so any PURE
# restructuring (Phase 2 bloat nuke, Phase 4 duplication collapse, etc.) can be
# checked for byte-for-byte identical codegen output in seconds, without running
# the full differential suite. This is NOT a soundness or parity gate — it only
# proves "nothing observable changed"; dart2wasm structural parity and the native
# differential remain the real oracles (see dev/PARITY_MASTER.md).
#
# Each probe compiles with `WasmTarget.compile(f, argtypes; validate=false)`
# (unoptimized IR, no wasm-tools double-check — module bytes only) and is
# fingerprinted with `bytes2hex(SHA.sha256(bytes))`. SHA is a Julia stdlib
# (always on LOAD_PATH regardless of the active Project.toml), so `using SHA`
# resolves under plain `--project=.` with no extra dependency wiring.
#
# Usage:
#   julia --project=. test/probe_bytes.jl            # compare against the baseline
#   WT_PROBE_RECORD=1 julia --project=. test/probe_bytes.jl   # rewrite the baseline
#
# On mismatch: prints every changed probe name (baseline hash vs new hash) and
# exits 1. On a clean run: prints a one-line summary and exits 0.

using WasmTarget
using SHA

const _PROBE_DIR = @__DIR__
const _BASELINE_PATH = joinpath(_PROBE_DIR, "probe_baseline.txt")

const CASES = Vector{Pair{String,Tuple}}()   # name => (f, argtypes::Tuple)
_c(name::String, f, argtypes...) = push!(CASES, name => (f, argtypes))

# ─────────────────────────────────────────────────────────────────────────────
# 1. INTRINSIC_BINOPS families (dev/PARITY_MASTER.md `INTRINSIC_BINOPS`):
#    add, sub, mul, div, rem, and, or, xor, comparisons (<, <=, ==, !=) over
#    Int64/Int32/UInt64/UInt32/Float64/Float32, plus narrow-pair (Int8/Int16/
#    UInt8/UInt16) arithmetic + comparisons exercising the pre-table narrow
#    normalization.
# ─────────────────────────────────────────────────────────────────────────────

_c("i64_add",  (x::Int64,y::Int64) -> x + y, Int64, Int64)
_c("i64_sub",  (x::Int64,y::Int64) -> x - y, Int64, Int64)
_c("i64_mul",  (x::Int64,y::Int64) -> x * y, Int64, Int64)
_c("i64_div",  (x::Int64,y::Int64) -> div(x, y), Int64, Int64)
_c("i64_rem",  (x::Int64,y::Int64) -> rem(x, y), Int64, Int64)
_c("i64_and",  (x::Int64,y::Int64) -> x & y, Int64, Int64)
_c("i64_or",   (x::Int64,y::Int64) -> x | y, Int64, Int64)
_c("i64_xor",  (x::Int64,y::Int64) -> xor(x, y), Int64, Int64)
_c("i64_eq",   (x::Int64,y::Int64) -> x == y, Int64, Int64)
_c("i64_ne",   (x::Int64,y::Int64) -> x != y, Int64, Int64)
_c("i64_lt",   (x::Int64,y::Int64) -> x < y, Int64, Int64)
_c("i64_le",   (x::Int64,y::Int64) -> x <= y, Int64, Int64)

_c("u64_add",  (x::UInt64,y::UInt64) -> x + y, UInt64, UInt64)
_c("u64_sub",  (x::UInt64,y::UInt64) -> x - y, UInt64, UInt64)
_c("u64_mul",  (x::UInt64,y::UInt64) -> x * y, UInt64, UInt64)
_c("u64_div",  (x::UInt64,y::UInt64) -> div(x, y), UInt64, UInt64)
_c("u64_rem",  (x::UInt64,y::UInt64) -> rem(x, y), UInt64, UInt64)
_c("u64_and",  (x::UInt64,y::UInt64) -> x & y, UInt64, UInt64)
_c("u64_or",   (x::UInt64,y::UInt64) -> x | y, UInt64, UInt64)
_c("u64_xor",  (x::UInt64,y::UInt64) -> xor(x, y), UInt64, UInt64)
_c("u64_eq",   (x::UInt64,y::UInt64) -> x == y, UInt64, UInt64)
_c("u64_ne",   (x::UInt64,y::UInt64) -> x != y, UInt64, UInt64)
_c("u64_lt",   (x::UInt64,y::UInt64) -> x < y, UInt64, UInt64)
_c("u64_le",   (x::UInt64,y::UInt64) -> x <= y, UInt64, UInt64)

_c("i32_add",  (x::Int32,y::Int32) -> x + y, Int32, Int32)
_c("i32_sub",  (x::Int32,y::Int32) -> x - y, Int32, Int32)
_c("i32_mul",  (x::Int32,y::Int32) -> x * y, Int32, Int32)
_c("i32_div",  (x::Int32,y::Int32) -> div(x, y), Int32, Int32)
_c("i32_rem",  (x::Int32,y::Int32) -> rem(x, y), Int32, Int32)
_c("i32_and",  (x::Int32,y::Int32) -> x & y, Int32, Int32)
_c("i32_or",   (x::Int32,y::Int32) -> x | y, Int32, Int32)
_c("i32_xor",  (x::Int32,y::Int32) -> xor(x, y), Int32, Int32)
_c("i32_eq",   (x::Int32,y::Int32) -> x == y, Int32, Int32)
_c("i32_ne",   (x::Int32,y::Int32) -> x != y, Int32, Int32)
_c("i32_lt",   (x::Int32,y::Int32) -> x < y, Int32, Int32)
_c("i32_le",   (x::Int32,y::Int32) -> x <= y, Int32, Int32)

_c("u32_add",  (x::UInt32,y::UInt32) -> x + y, UInt32, UInt32)
_c("u32_sub",  (x::UInt32,y::UInt32) -> x - y, UInt32, UInt32)
_c("u32_mul",  (x::UInt32,y::UInt32) -> x * y, UInt32, UInt32)
_c("u32_div",  (x::UInt32,y::UInt32) -> div(x, y), UInt32, UInt32)
_c("u32_rem",  (x::UInt32,y::UInt32) -> rem(x, y), UInt32, UInt32)
_c("u32_and",  (x::UInt32,y::UInt32) -> x & y, UInt32, UInt32)
_c("u32_or",   (x::UInt32,y::UInt32) -> x | y, UInt32, UInt32)
_c("u32_xor",  (x::UInt32,y::UInt32) -> xor(x, y), UInt32, UInt32)
_c("u32_eq",   (x::UInt32,y::UInt32) -> x == y, UInt32, UInt32)
_c("u32_ne",   (x::UInt32,y::UInt32) -> x != y, UInt32, UInt32)
_c("u32_lt",   (x::UInt32,y::UInt32) -> x < y, UInt32, UInt32)
_c("u32_le",   (x::UInt32,y::UInt32) -> x <= y, UInt32, UInt32)

_c("f64_add",  (x::Float64,y::Float64) -> x + y, Float64, Float64)
_c("f64_sub",  (x::Float64,y::Float64) -> x - y, Float64, Float64)
_c("f64_mul",  (x::Float64,y::Float64) -> x * y, Float64, Float64)
_c("f64_div",  (x::Float64,y::Float64) -> x / y, Float64, Float64)
_c("f64_eq",   (x::Float64,y::Float64) -> x == y, Float64, Float64)
_c("f64_ne",   (x::Float64,y::Float64) -> x != y, Float64, Float64)
_c("f64_lt",   (x::Float64,y::Float64) -> x < y, Float64, Float64)
_c("f64_le",   (x::Float64,y::Float64) -> x <= y, Float64, Float64)

_c("f32_add",  (x::Float32,y::Float32) -> x + y, Float32, Float32)
_c("f32_sub",  (x::Float32,y::Float32) -> x - y, Float32, Float32)
_c("f32_mul",  (x::Float32,y::Float32) -> x * y, Float32, Float32)
_c("f32_div",  (x::Float32,y::Float32) -> x / y, Float32, Float32)
_c("f32_eq",   (x::Float32,y::Float32) -> x == y, Float32, Float32)
_c("f32_ne",   (x::Float32,y::Float32) -> x != y, Float32, Float32)
_c("f32_lt",   (x::Float32,y::Float32) -> x < y, Float32, Float32)
_c("f32_le",   (x::Float32,y::Float32) -> x <= y, Float32, Float32)
# every op × width the diagonal table claims (a Float32 copysign gap once hid a regression)
_c("f64_copysign", (x::Float64,y::Float64) -> copysign(x, y), Float64, Float64)
_c("f32_copysign", (x::Float32,y::Float32) -> copysign(x, y), Float32, Float32)
_c("f64_min",  (x::Float64,y::Float64) -> min(x, y), Float64, Float64)
_c("f32_min",  (x::Float32,y::Float32) -> min(x, y), Float32, Float32)
_c("f64_max",  (x::Float64,y::Float64) -> max(x, y), Float64, Float64)
_c("f32_max",  (x::Float32,y::Float32) -> max(x, y), Float32, Float32)

# narrow-width pairs (i32-mapped, exercise the narrow-pair normalization
# ahead of the table route)
_c("i8_add",   (x::Int8,y::Int8) -> x + y, Int8, Int8)
_c("i8_eq",    (x::Int8,y::Int8) -> x == y, Int8, Int8)
_c("i8_ne",    (x::Int8,y::Int8) -> x != y, Int8, Int8)
_c("i8_lt",    (x::Int8,y::Int8) -> x < y, Int8, Int8)
_c("i8_le",    (x::Int8,y::Int8) -> x <= y, Int8, Int8)
_c("i8_div",   (x::Int8,y::Int8) -> div(x, y), Int8, Int8)
_c("i8_rem",   (x::Int8,y::Int8) -> rem(x, y), Int8, Int8)
_c("u8_add",   (x::UInt8,y::UInt8) -> x + y, UInt8, UInt8)
_c("u8_lt",    (x::UInt8,y::UInt8) -> x < y, UInt8, UInt8)
_c("u8_le",    (x::UInt8,y::UInt8) -> x <= y, UInt8, UInt8)
_c("u8_div",   (x::UInt8,y::UInt8) -> div(x, y), UInt8, UInt8)
_c("u8_rem",   (x::UInt8,y::UInt8) -> rem(x, y), UInt8, UInt8)
_c("i16_add",  (x::Int16,y::Int16) -> x + y, Int16, Int16)
_c("i16_lt",   (x::Int16,y::Int16) -> x < y, Int16, Int16)
_c("i16_le",   (x::Int16,y::Int16) -> x <= y, Int16, Int16)
_c("i16_div",  (x::Int16,y::Int16) -> div(x, y), Int16, Int16)
_c("i16_rem",  (x::Int16,y::Int16) -> rem(x, y), Int16, Int16)
_c("u16_add",  (x::UInt16,y::UInt16) -> x + y, UInt16, UInt16)
_c("u16_lt",   (x::UInt16,y::UInt16) -> x < y, UInt16, UInt16)
_c("u16_le",   (x::UInt16,y::UInt16) -> x <= y, UInt16, UInt16)
_c("u16_div",  (x::UInt16,y::UInt16) -> div(x, y), UInt16, UInt16)
_c("u16_rem",  (x::UInt16,y::UInt16) -> rem(x, y), UInt16, UInt16)

# ─────────────────────────────────────────────────────────────────────────────
# 2. The six float arms Phase 3.1 deletes (`gt_float`/`ge_float` on Float64
#    and Float32, plus the four arithmetic arms on both widths — already
#    covered by family 1's f64_*/f32_* add/sub/mul/div above).
# ─────────────────────────────────────────────────────────────────────────────

_c("gt_f64",   (x::Float64,y::Float64) -> x > y, Float64, Float64)
_c("ge_f64",   (x::Float64,y::Float64) -> x >= y, Float64, Float64)
_c("gt_f32",   (x::Float32,y::Float32) -> x > y, Float32, Float32)
_c("ge_f32",   (x::Float32,y::Float32) -> x >= y, Float32, Float32)

# ─────────────────────────────────────────────────────────────────────────────
# 3. Unary / conversion (INTRINSIC_UNOPS + result map, dev/PARITY_MASTER.md)
# ─────────────────────────────────────────────────────────────────────────────

_c("not_int",         (x::Int64) -> ~x, Int64)
_c("neg_int",         (x::Int64) -> -x, Int64)
_c("bool_not",        (x::Bool) -> !x, Bool)
_c("leading_zeros",   (x::Int64) -> leading_zeros(x), Int64)
_c("trailing_zeros",  (x::Int64) -> trailing_zeros(x), Int64)
_c("count_ones",      (x::Int64) -> count_ones(x), Int64)
_c("abs_f64",         (x::Float64) -> abs(x), Float64)
_c("sqrt_f64",        (x::Float64) -> sqrt(x), Float64)
_c("floor_f64",       (x::Float64) -> floor(x), Float64)
_c("ceil_f64",        (x::Float64) -> ceil(x), Float64)
_c("trunc_f64",       (x::Float64) -> trunc(x), Float64)
_c("round_f64",       (x::Float64) -> round(x), Float64)
_c("i64_from_i32",    (x::Int32) -> Int64(x), Int32)
_c("i32_from_i64",    (x::Int64) -> x % Int32, Int64)
_c("f64_from_i64",    (x::Int64) -> Float64(x), Int64)
_c("i64_from_f64_unsafe", (x::Float64) -> Base.unsafe_trunc(Int64, x), Float64)
_c("reinterpret_u64_f64", (x::Float64) -> reinterpret(UInt64, x), Float64)

# Phase 3.3/3.4c-ii conversions-registry coverage (calls.jl's ten sext_int/
# zext_int/trunc_int/sitofp/uitofp/fptosi/fptoui/fpext/fptrunc/bitcast arms →
# INTRINSIC_CONVERSIONS registry, julia_numeric_tier.jl): narrow-source sext/
# zext/sitofp, narrow-target trunc, the first uitofp/fptoui probes, standard
# (non-Float16) fpext/fptrunc, and both bitcast shapes (float<->int reinterpret,
# same-width int<->int no-op).
_c("sext_i8_to_i64",      (x::Int8) -> Int64(x), Int8)
_c("zext_u8_to_u64",      (x::UInt8) -> UInt64(x), UInt8)
_c("trunc_i64_to_i8",     (x::Int64) -> x % Int8, Int64)
_c("sitofp_i16_f64",      (x::Int16) -> Float64(x), Int16)
_c("uitofp_u32_f64",      (x::UInt32) -> Float64(x), UInt32)
_c("fptosi_f32_i32_unsafe", (x::Float32) -> Base.unsafe_trunc(Int32, x), Float32)
_c("fptoui_f64_u64_unsafe", (x::Float64) -> Base.unsafe_trunc(UInt64, x), Float64)
_c("fpext_f32_f64",       (x::Float32) -> Float64(x), Float32)
_c("fptrunc_f64_f32",     (x::Float64) -> Float32(x), Float64)
_c("reinterpret_i32_f32", (x::Float32) -> reinterpret(Int32, x), Float32)
_c("reinterpret_i64_u64", (x::UInt64) -> reinterpret(Int64, x), UInt64)

# ─────────────────────────────────────────────────────────────────────────────
# 4. Quarantine tier (`src/codegen/julia_numeric_tier.jl`, Julia-only —
#    no dart equivalent): Int128, checked overflow, muladd, mixed-width
#    shift, bswap.
# ─────────────────────────────────────────────────────────────────────────────

_c("int128_add",   (x::Int128,y::Int128) -> x + y, Int128, Int128)
_c("int128_mul",   (x::Int128,y::Int128) -> x * y, Int128, Int128)
_c("int128_lt",    (x::Int128,y::Int128) -> x < y, Int128, Int128)
_c("checked_add",  (x::Int64,y::Int64) -> Base.checked_add(x, y), Int64, Int64)
_c("checked_mul",  (x::Int64,y::Int64) -> Base.checked_mul(x, y), Int64, Int64)
_c("muladd_f64",   (x::Float64,y::Float64,z::Float64) -> muladd(x, y, z), Float64, Float64, Float64)
_c("shl_mixed",    (x::UInt32,n::Int64) -> x << n, UInt32, Int64)
_c("bswap_i64",    (x::Int64) -> bswap(x), Int64)

# CHECKED_OPS: add/sub/mul on every width Phase 3.4c-i's registry handles
# (Int64/Int32/UInt64 register-width path; Int8/Int16 narrow-normalise path).
_c("checked_add_i32", (x::Int32,y::Int32) -> Base.checked_add(x, y), Int32, Int32)
_c("checked_add_u64", (x::UInt64,y::UInt64) -> Base.checked_add(x, y), UInt64, UInt64)
_c("checked_add_i8",  (x::Int8,y::Int8) -> Base.checked_add(x, y), Int8, Int8)
_c("checked_add_i16", (x::Int16,y::Int16) -> Base.checked_add(x, y), Int16, Int16)
_c("checked_sub_i64", (x::Int64,y::Int64) -> Base.checked_sub(x, y), Int64, Int64)
_c("checked_sub_i32", (x::Int32,y::Int32) -> Base.checked_sub(x, y), Int32, Int32)
_c("checked_sub_u64", (x::UInt64,y::UInt64) -> Base.checked_sub(x, y), UInt64, UInt64)
_c("checked_sub_i8",  (x::Int8,y::Int8) -> Base.checked_sub(x, y), Int8, Int8)
_c("checked_sub_i16", (x::Int16,y::Int16) -> Base.checked_sub(x, y), Int16, Int16)
_c("checked_mul_i32", (x::Int32,y::Int32) -> Base.checked_mul(x, y), Int32, Int32)
_c("checked_mul_u64", (x::UInt64,y::UInt64) -> Base.checked_mul(x, y), UInt64, UInt64)
_c("checked_mul_i8",  (x::Int8,y::Int8) -> Base.checked_mul(x, y), Int8, Int8)
_c("checked_mul_i16", (x::Int16,y::Int16) -> Base.checked_mul(x, y), Int16, Int16)

# SHIFT_OPS: <<, >>, >>> on every register width with both a matching-width
# and a mismatched-width (Int64 vs Int32) shift-count operand — exercises the
# count-coercion/saturation ahead of `_emit_shift_guarded!` (shl_mixed above
# already covers UInt32 << with an Int64 count).
_c("shl_i64_c64",  (x::Int64,n::Int64) -> x << n, Int64, Int64)
_c("shl_i64_c32",  (x::Int64,n::Int32) -> x << n, Int64, Int32)
_c("shl_i32_c64",  (x::Int32,n::Int64) -> x << n, Int32, Int64)
_c("shl_i32_c32",  (x::Int32,n::Int32) -> x << n, Int32, Int32)
_c("shl_u64_c64",  (x::UInt64,n::Int64) -> x << n, UInt64, Int64)
_c("shl_u64_c32",  (x::UInt64,n::Int32) -> x << n, UInt64, Int32)
_c("shl_u32_c32",  (x::UInt32,n::Int32) -> x << n, UInt32, Int32)
_c("shr_i64_c64",  (x::Int64,n::Int64) -> x >> n, Int64, Int64)
_c("shr_i64_c32",  (x::Int64,n::Int32) -> x >> n, Int64, Int32)
_c("shr_i32_c64",  (x::Int32,n::Int64) -> x >> n, Int32, Int64)
_c("shr_i32_c32",  (x::Int32,n::Int32) -> x >> n, Int32, Int32)
_c("shr_u64_c64",  (x::UInt64,n::Int64) -> x >> n, UInt64, Int64)
_c("shr_u64_c32",  (x::UInt64,n::Int32) -> x >> n, UInt64, Int32)
_c("shr_u32_c64",  (x::UInt32,n::Int64) -> x >> n, UInt32, Int64)
_c("shr_u32_c32",  (x::UInt32,n::Int32) -> x >> n, UInt32, Int32)
_c("ushr_i64_c64", (x::Int64,n::Int64) -> x >>> n, Int64, Int64)
_c("ushr_i64_c32", (x::Int64,n::Int32) -> x >>> n, Int64, Int32)
_c("ushr_i32_c64", (x::Int32,n::Int64) -> x >>> n, Int32, Int64)
_c("ushr_i32_c32", (x::Int32,n::Int32) -> x >>> n, Int32, Int32)
_c("ushr_u64_c64", (x::UInt64,n::Int64) -> x >>> n, UInt64, Int64)
_c("ushr_u64_c32", (x::UInt64,n::Int32) -> x >>> n, UInt64, Int32)
_c("ushr_u32_c64", (x::UInt32,n::Int64) -> x >>> n, UInt32, Int64)
_c("ushr_u32_c32", (x::UInt32,n::Int32) -> x >>> n, UInt32, Int32)

# FMA_OPS: muladd/fma on both float widths (fma missing entirely from the
# prior corpus — `have_fma` is exercised implicitly, it takes no runtime arg).
_c("muladd_f32", (x::Float32,y::Float32,z::Float32) -> muladd(x, y, z), Float32, Float32, Float32)
_c("fma_f64",     (x::Float64,y::Float64,z::Float64) -> fma(x, y, z), Float64, Float64, Float64)
_c("fma_f32",     (x::Float32,y::Float32,z::Float32) -> fma(x, y, z), Float32, Float32, Float32)

# MISC_OPS: bswap (remaining widths) and flipsign.
_c("bswap_i32",  (x::Int32) -> bswap(x), Int32)
_c("bswap_u16",  (x::UInt16) -> bswap(x), UInt16)
_c("flipsign_i64", (x::Int64,y::Int64) -> flipsign(x, y), Int64, Int64)
_c("flipsign_i32", (x::Int32,y::Int32) -> flipsign(x, y), Int32, Int32)

# ─────────────────────────────────────────────────────────────────────────────
# 5. Invoke/foreigncall registry keys (kwerr, throw_inexacterror, memoryrefnew
#    via Vector, jl_string_ptr via string ops) — println EXCLUDED: it requires
#    an explicitly configured IO bridge and raises WasmCompileError under a
#    plain `compile(f, argtypes)` call (unresolved dynamic `Base.print`), so
#    it cannot serve as a byte-identity probe. Confirmed by direct test.
# ─────────────────────────────────────────────────────────────────────────────

_wt_kwerr_probe()::Int64 = try
    Base.kwerr((; unsupported_keyword=true), identity)
    0
catch err
    err isa MethodError && err.f === Core.kwcall ? 1 : 2
end
_c("kwerr", _wt_kwerr_probe)

_wt_inexact_probe()::Int64 = try
    Core.throw_inexacterror(:convert, UInt8, UInt64(300))
    0
catch err
    err isa InexactError && err.func === :convert ? 1 : 2
end
_c("throw_inexacterror", _wt_inexact_probe)

function _wt_vecmut_probe()::Int64   # memoryrefnew path: Vector push!/getindex/length
    v = Int64[]
    for i in 1:20
        push!(v, i)
    end
    return v[3] + length(v)
end
_c("memoryrefnew_vecmut", _wt_vecmut_probe)

mutable struct _WTProbeFieldSet
    x::Int64
end
function _wt_structset_probe(x::Int64)::Int64
    s = _WTProbeFieldSet(0)
    s.x = x
    return s.x
end
_c("struct_setfield", _wt_structset_probe, Int64)

_c("string_from_i64", (x::Int64) -> string(x), Int64)
_c("string_concat",   () -> "a" * "b")
_c("string_occursin", () -> occursin("b", "abc"))
_c("string_findfirst", () -> findfirst("b", "abc"))
_c("string_startswith", () -> startswith("abc", "ab"))
_c("string_uppercase", () -> uppercase("abc"))

# ─────────────────────────────────────────────────────────────────────────────
# 6. Union{Nothing,T}: local, 3-way phi, field read.
# ─────────────────────────────────────────────────────────────────────────────

struct _WTProbeSome
    x::Int64
end

function _wt_union_local_probe(x::Int64)::Int64
    v = x > 0 ? _WTProbeSome(x) : nothing
    return v === nothing ? -1 : v.x
end
_c("union_local", _wt_union_local_probe, Int64)

function _wt_union_phi3_probe(x::Int64)::Int64
    local v
    if x > 10
        v = _WTProbeSome(x)
    elseif x > 0
        v = _WTProbeSome(x * 2)
    else
        v = nothing
    end
    return v === nothing ? -1 : v.x
end
_c("union_phi3", _wt_union_phi3_probe, Int64)

mutable struct _WTProbeHolder
    v::Union{Nothing,_WTProbeSome}
end
function _wt_union_field_probe(h::_WTProbeHolder)::Int64
    local_v = h.v
    return local_v === nothing ? -1 : local_v.x
end
_c("union_field", _wt_union_field_probe, _WTProbeHolder)

# ─────────────────────────────────────────────────────────────────────────────
# 7. STRESS slices (test/runtests.jl STRESS-1000/1001/1004 families,
#    STRESS-1003 array mutation): one representative probe per slice.
# ─────────────────────────────────────────────────────────────────────────────

function _wt_stress_numeric_matrix_probe(a::Int32, b::Int64, c::Float64)::Float64
    x = Int64(a) + b
    y = Float64(x) * c
    return y - Float64(a)
end
_c("stress_numeric_matrix", _wt_stress_numeric_matrix_probe, Int32, Int64, Float64)

_c("stress_lstrip", () -> lstrip("  hi  "))
_c("stress_repeat", () -> repeat("ab", 3))

function _wt_stress_arraymut_probe()::Int64
    v = Int64[]
    push!(v, 1)
    push!(v, 2)
    resize!(v, 5)
    push!(v, 9)
    return length(v)
end
_c("stress_arraymut", _wt_stress_arraymut_probe)

# ─────────────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────────────

function _load_baseline(path::String)::Dict{String,String}
    baseline = Dict{String,String}()
    isfile(path) || return baseline
    for line in eachline(path)
        isempty(line) && continue
        parts = split(line, '\t')
        length(parts) == 2 || continue
        baseline[parts[1]] = parts[2]
    end
    return baseline
end

function _write_baseline(path::String, hashes::Dict{String,String})
    open(path, "w") do io
        for name in sort(collect(keys(hashes)))
            println(io, name, '\t', hashes[name])
        end
    end
end

function main()
    hashes = Dict{String,String}()
    for (name, (f, argtypes)) in CASES
        bytes = WasmTarget.compile(f, argtypes; validate=false)
        hashes[name] = bytes2hex(SHA.sha256(bytes))
    end

    if get(ENV, "WT_PROBE_RECORD", "") == "1"
        _write_baseline(_BASELINE_PATH, hashes)
        println("probe_bytes: recorded $(length(hashes)) probes to $(_BASELINE_PATH)")
        return 0
    end

    baseline = _load_baseline(_BASELINE_PATH)
    if isempty(baseline)
        println("probe_bytes: no baseline at $(_BASELINE_PATH) — run with WT_PROBE_RECORD=1 first")
        return 1
    end

    changed = String[]
    for name in sort(collect(keys(hashes)))
        old = get(baseline, name, nothing)
        new = hashes[name]
        if old === nothing
            println("  NEW probe (not in baseline): ", name, " => ", new)
            push!(changed, name)
        elseif old != new
            println("  CHANGED: ", name, "  ", old, " -> ", new)
            push!(changed, name)
        end
    end
    for name in sort(collect(keys(baseline)))
        if !haskey(hashes, name)
            println("  MISSING probe (in baseline, not in corpus): ", name)
            push!(changed, name)
        end
    end

    println("probe_bytes: $(length(hashes)) probes, $(length(changed)) changed")
    return isempty(changed) ? 0 : 1
end

exit(main())
