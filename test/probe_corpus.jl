# Probe corpus definition (shared by test/probe_bytes.jl and test/shadow_compile.jl)
# Each case is a (f, argtypes) pair compiled with an explicit export name.

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
# kwerr is not fingerprinted: its MethodError embeds the compile-time world age, so its
# bytes change whenever the session defines a method — L81 covers it differentially.

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
# 5b. Phase 5.2 (dev/MARCH.md §2 "Identity registries", §4 Phase 5 items 2/4):
#     spike A (bespoke string builders hash/repeat/lpad/rpad → generic/overlay
#     path) and registry B (invoke.jl name===:x arms → Method-keyed
#     INVOKE_INTRINSICS). These wrapper functions exercise ops that are never
#     otherwise reachable through ordinary Julia syntax (the WT-only str_*/
#     arr_* intrinsics) so the invoke arm/registry entry actually compiles.
# ─────────────────────────────────────────────────────────────────────────────

_c("string_hash",      () -> WasmTarget.str_hash("hello"))
_c("string_repeat_char", () -> repeat('a', 3))
_c("string_lpad",      () -> lpad("x", 5))
_c("string_lpad_char", () -> lpad("x", 5, '-'))
_c("string_rpad_char", () -> rpad("x", 5, '-'))

# Int32 index (not Int/Int64 — see the report: generate_intrinsic_body's
# hardcoded str_char/str_setchar! bodies assume an i32 index local and
# StackImbalanceError on the Int64 overload EVEN BEFORE this migration; that
# latent bug is fixed as a side effect of routing these through the registry
# + _skip_cross_call, so it is validated differentially, not by this probe).
_wt_wrap_strchar(s::String, i::Int32) = WasmTarget.str_char(s, i)
_c("wt_str_char", _wt_wrap_strchar, String, Int32)
_wt_wrap_strsetchar(s::String, i::Int32, c::Int32) = WasmTarget.str_setchar!(s, i, c)
_c("wt_str_setchar", _wt_wrap_strsetchar, String, Int32, Int32)
_wt_wrap_strlen(s::String) = WasmTarget.str_len(s)
_c("wt_str_len", _wt_wrap_strlen, String)
_wt_wrap_strnew(n::Int32) = WasmTarget.str_new(n)
_c("wt_str_new", _wt_wrap_strnew, Int32)
_wt_wrap_strcopy(a::String, b::Int32, c::String, d::Int32, e::Int32) = WasmTarget.str_copy(a, b, c, d, e)
_c("wt_str_copy", _wt_wrap_strcopy, String, Int32, String, Int32, Int32)

_wt_wrap_arrnew()::Vector{Int64} = WasmTarget.arr_new(Int64, Int32(5))
_c("wt_arr_new", _wt_wrap_arrnew)
_wt_wrap_arrget(v::Vector{Int64}, i::Int32) = WasmTarget.arr_get(v, i)
_c("wt_arr_get", _wt_wrap_arrget, Vector{Int64}, Int32)
_wt_wrap_arrset(v::Vector{Int64}, i::Int32, x::Int64) = WasmTarget.arr_set!(v, i, x)
_c("wt_arr_set", _wt_wrap_arrset, Vector{Int64}, Int32, Int64)
_wt_wrap_arrlen(v::Vector{Int64}) = WasmTarget.arr_len(v)
_c("wt_arr_len", _wt_wrap_arrlen, Vector{Int64})

_wt_wrap_isascii(s::String) = isascii(codeunits(s))
_c("wt_isascii_codeunits", _wt_wrap_isascii, String)
_wt_wrap_streq(a::String, b::String) = a == b
_c("wt_string_eq", _wt_wrap_streq, String, String)
_wt_wrap_substr3(s::String, i::Int, j::Int) = SubString(s, i, j)
_c("wt_substring3", _wt_wrap_substr3, String, Int, Int)
_wt_wrap_substr1(s::String) = SubString(s)
_c("wt_substring1", _wt_wrap_substr1, String)
_c("wt_array_subpadding", () -> Base.array_subpadding(Float64, Int64))
_wt_wrap_unalias(a::Vector{Int64}, b::Vector{Int64}) = Base.unalias(a, b)
_c("wt_unalias", _wt_wrap_unalias, Vector{Int64}, Vector{Int64})
# 5b. Phase 5.3 foreigncall registry migration (statements.jl compile_foreigncall!
#     → FOREIGN_LOWERINGS): one probe per migrated symbol not already covered
#     above (memoryrefnew is covered by memoryrefnew_vecmut). Each name reaches
#     the arm named in its comment (verified against the pre-migration source
#     via WasmTarget.compile succeeding, i.e. never falling into the
#     unknown-foreigncall trap — confirmed 2026-09-02).
# ─────────────────────────────────────────────────────────────────────────────

_c("fc_alloc_genericmemory", (n::Int64) -> (v = Vector{Float64}(undef, n); v[1] = 1.0; v[1]), Int64)   # jl_alloc_genericmemory
_c("fc_memset_dict_ctor", () -> (d = Dict{Int64,Int64}(); d[1] = 2; d[1]))                              # memset
_c("fc_types_equal_pow", (x::Float32) -> x^2.0f0, Float32)                                              # jl_types_equal
mutable struct _WTProbeObjId
    x::Int64
end
_c("fc_object_id", (s::_WTProbeObjId) -> objectid(s), _WTProbeObjId)                                    # jl_object_id
_c("fc_string_to_genericmemory", (s::String) -> length(Vector{UInt8}(s)), String)                       # jl_string_to_genericmemory
_c("fc_genericmemory_to_string", (v::Vector{UInt8}) -> String(v), Vector{UInt8})                        # jl_genericmemory_to_string (+ jl_pchar_to_string)
_c("fc_symbol_to_string", (s::Symbol) -> String(s), Symbol)                                             # jl_symbol_name / jl_string_ptr
_c("fc_string_to_symbol", (s::String) -> String(Symbol(s)), String)                                     # jl_symbol_n
_c("fc_alloc_string", () -> length(Base._string_n(5)))                                                  # jl_alloc_string
_c("fc_cstr_to_string", (s::String) -> unsafe_string(pointer(s)), String)                                # jl_cstr_to_string
_c("fc_pchar_to_string_ptrlen", (v::Vector{UInt8}) -> unsafe_string(pointer(v), length(v)), Vector{UInt8})  # jl_pchar_to_string (ptr,len)
_c("fc_iobuffer_grow_take", () -> (io = IOBuffer(); for i in 1:2000; write(io, UInt8(i % 256)); end; length(take!(io))))  # jl_pchar_to_string (grown IOBuffer)
_c("fc_memchr_findfirst_char", (s::String) -> something(findfirst('b', s), 0), String)                   # memchr
_c("fc_task_rand", () -> rand())                                                                         # jl_get_current_task
_c("fc_hrtime_elapsed", () -> @elapsed (1 + 1))                                                          # jl_hrtime
_c("fc_memhash_dict_string", (s::String) -> (d = Dict{String,Int64}(); d[s] = 1; d[s]), String)          # memhash
_c("fc_genericmemory_copyto", (v::Vector{Float64}) -> copy(v)[1], Vector{Float64})                       # jl_genericmemory_copyto

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
# 8. Constant materialization (dev/MARCH.md Phase 4.4, R14 fresh_constant_structs):
#    a literal Vector, tuple-of-strings, and nested-struct constant. Vector is
#    mutable so it takes the GlobalRef → compile_module_initializer path (the
#    mutable-identity floor); the tuple and struct are immutable so the GlobalRef
#    branch recurses straight into compile_value on the value itself (the tuple
#    and general-struct funnel-fallback sites).
#
#    The Dict probe: a Dict{Int64,Int64} constant once compiled to process-varying
#    bytes (the struct registry was walked in hash order while assigning lazy
#    typeIds — fixed by registered_structs + L112). The probe stays here as the
#    cross-process determinism witness: the baseline is recorded in one process
#    and compared in another on every run.
# ─────────────────────────────────────────────────────────────────────────────

const _WT_CONST_VEC = Int64[1, 2, 3]
_wt_const_vector_probe() = _WT_CONST_VEC
_c("const_vector", _wt_const_vector_probe)

const _WT_CONST_VEC_SAMELEN = Int64[4, 5, 6]
_wt_const_vector_pair_probe() = _WT_CONST_VEC[1] + _WT_CONST_VEC_SAMELEN[1] + Int64(length(_WT_CONST_VEC))
_c("const_vector_pair_samelen", _wt_const_vector_pair_probe)

const _WT_CONST_DICT = Dict{Int64,Int64}(1 => 10, 2 => 20)
_wt_const_dict_probe() = _WT_CONST_DICT[2]
_c("const_dict", _wt_const_dict_probe)

_wt_int128_literal_probe() = Int128(170141183460469231731687303715884105727)
_c("int128_literal_const", _wt_int128_literal_probe)
_wt_int128_tuple_repeated_probe() = (Int128(11111111111111111111), Int128(11111111111111111111))
_c("int128_tuple_repeated_const", _wt_int128_tuple_repeated_probe)

const _WT_CONST_TUPLE = ("a", "b", "c")
_wt_const_tuple_probe() = _WT_CONST_TUPLE
_c("const_tuple_strings", _wt_const_tuple_probe)

struct _WTProbeInner
    x::Int64
end
struct _WTProbeOuter
    inner::_WTProbeInner
    y::Int64
end
const _WT_CONST_STRUCT = _WTProbeOuter(_WTProbeInner(7), 9)
_wt_const_nested_struct_probe() = _WT_CONST_STRUCT
_c("const_nested_struct", _wt_const_nested_struct_probe)

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
