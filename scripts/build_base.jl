#!/usr/bin/env julia
# Build base.wasm from Tier 1 function set
# Run: julia +1.12 --project=. scripts/build_base.jl
#
# Strategy: validate each function individually with wasm-tools,
# then compile_multi() only the validated functions into base.wasm.

using WasmTarget

# All candidate functions: (function, arg_types, export_name)
const ALL_FUNCTIONS = [
    # ── Arithmetic (expanded for Tier 2 dispatch tables) ────
    # PURE-9061: 9+ specializations per key function → triggers hash dispatch
    (+, (Int64, Int64), "add_i64"),
    (+, (Float64, Float64), "add_f64"),
    (+, (Int32, Int32), "add_i32"),
    (+, (Int64, Float64), "add_i64_f64"),
    (+, (Float64, Int64), "add_f64_i64"),
    (+, (Int32, Int64), "add_i32_i64"),
    (+, (Int64, Int32), "add_i64_i32"),
    (+, (Float32, Float32), "add_f32"),
    (+, (Float32, Float64), "add_f32_f64"),
    (+, (Float64, Float32), "add_f64_f32"),
    (+, (Int32, Float64), "add_i32_f64"),
    (+, (Float64, Int32), "add_f64_i32"),
    (-, (Int64, Int64), "sub_i64"),
    (-, (Float64, Float64), "sub_f64"),
    (-, (Int32, Int32), "sub_i32"),
    (-, (Int64, Float64), "sub_i64_f64"),
    (-, (Float64, Int64), "sub_f64_i64"),
    (-, (Int32, Int64), "sub_i32_i64"),
    (-, (Int64, Int32), "sub_i64_i32"),
    (-, (Float32, Float32), "sub_f32"),
    (-, (Float32, Float64), "sub_f32_f64"),
    (-, (Float64, Float32), "sub_f64_f32"),
    (-, (Int32, Float64), "sub_i32_f64"),
    (-, (Float64, Int32), "sub_f64_i32"),
    (*, (Int64, Int64), "mul_i64"),
    (*, (Float64, Float64), "mul_f64"),
    (*, (Int64, Float64), "mul_i64_f64"),
    (*, (Int32, Int32), "mul_i32"),
    (*, (Float64, Int64), "mul_f64_i64"),
    (*, (Int32, Int64), "mul_i32_i64"),
    (*, (Int64, Int32), "mul_i64_i32"),
    (*, (Float32, Float32), "mul_f32"),
    (*, (Float32, Float64), "mul_f32_f64"),
    (*, (Float64, Float32), "mul_f64_f32"),
    (*, (Int32, Float64), "mul_i32_f64"),
    (*, (Float64, Int32), "mul_f64_i32"),
    (/, (Float64, Float64), "div_f64"),
    (div, (Int64, Int64), "div_i64"),
    (rem, (Int64, Int64), "rem_i64"),
    (mod, (Int64, Int64), "mod_i64"),
    (divrem, (Int64, Int64), "divrem_i64"),
    (fld, (Int64, Int64), "fld_i64"),
    (cld, (Int64, Int64), "cld_i64"),
    (muladd, (Float64, Float64, Float64), "muladd_f64"),
    (widemul, (Int32, Int32), "widemul_i32"),

    # ── Math: rounding, abs, sign ───────────────────────────
    (abs, (Int64,), "abs_i64"),
    (abs, (Int32,), "abs_i32"),
    (abs, (Float64,), "abs_f64"),
    (sign, (Int64,), "sign_i64"),
    (sign, (Float64,), "sign_f64"),
    (signbit, (Float64,), "signbit_f64"),
    (copysign, (Int64, Int64), "copysign_i64"),
    (copysign, (Float64, Float64), "copysign_f64"),
    (flipsign, (Int64, Int64), "flipsign_i64"),
    (flipsign, (Float64, Float64), "flipsign_f64"),
    (floor, (Float64,), "floor_f64"),
    (ceil, (Float64,), "ceil_f64"),
    (round, (Float64,), "round_f64"),
    (trunc, (Float64,), "trunc_f64"),
    (clamp, (Int64, Int64, Int64), "clamp_i64"),
    (clamp, (Float64, Float64, Float64), "clamp_f64"),
    (min, (Int64, Int64), "min_i64"),
    (max, (Int64, Int64), "max_i64"),
    (min, (Float64, Float64), "min_f64"),
    (max, (Float64, Float64), "max_f64"),
    (minmax, (Int64, Int64), "minmax_i64"),
    (sqrt, (Float64,), "sqrt_f64"),
    (cbrt, (Float64,), "cbrt_f64"),

    # ── Trig ────────────────────────────────────────────────
    (sin, (Float64,), "sin_f64"),
    (cos, (Float64,), "cos_f64"),
    (tan, (Float64,), "tan_f64"),
    (asin, (Float64,), "asin_f64"),
    (acos, (Float64,), "acos_f64"),
    (atan, (Float64,), "atan_f64"),
    (atan, (Float64, Float64), "atan2_f64"),

    # ── Exp/Log ─────────────────────────────────────────────
    (exp, (Float64,), "exp_f64"),
    (exp2, (Float64,), "exp2_f64"),
    (exp10, (Float64,), "exp10_f64"),
    (cosh, (Float64,), "cosh_f64"),
    (tanh, (Float64,), "tanh_f64"),

    # ── Number theory ───────────────────────────────────────
    (gcd, (Int64, Int64), "gcd_i64"),
    (lcm, (Int64, Int64), "lcm_i64"),
    (gcdx, (Int64, Int64), "gcdx_i64"),
    (powermod, (Int64, Int64, Int64), "powermod_i64"),
    (invmod, (Int64, Int64), "invmod_i64"),
    (ndigits, (Int64,), "ndigits_i64"),

    # ── Comparison ──────────────────────────────────────────
    (isequal, (Int64, Int64), "isequal_i64"),
    (isless, (Int64, Int64), "isless_i64"),
    (isless, (Float64, Float64), "isless_f64"),
    (cmp, (Int64, Int64), "cmp_i64"),

    # ── Predicates ──────────────────────────────────────────
    (iszero, (Int64,), "iszero_i64"),
    (isone, (Int64,), "isone_i64"),
    (iseven, (Int64,), "iseven_i64"),
    (isodd, (Int64,), "isodd_i64"),
    (isnan, (Float64,), "isnan_f64"),
    (isinf, (Float64,), "isinf_f64"),
    (isfinite, (Float64,), "isfinite_f64"),

    # ── Bitwise ─────────────────────────────────────────────
    ((&), (Int64, Int64), "band_i64"),
    ((|), (Int64, Int64), "bor_i64"),
    (xor, (Int64, Int64), "xor_i64"),
    ((~), (Int64,), "bnot_i64"),
    ((<<), (Int64, Int64), "shl_i64"),
    ((>>), (Int64, Int64), "shr_i64"),
    ((>>>), (Int64, Int64), "ushr_i64"),
    (count_ones, (Int64,), "count_ones_i64"),
    (leading_zeros, (Int64,), "leading_zeros_i64"),
    (trailing_zeros, (Int64,), "trailing_zeros_i64"),

    # ── Conversion ──────────────────────────────────────────
    (float, (Int64,), "float_i64"),
    (widen, (Int32,), "widen_i32"),

    # ── Boolean ─────────────────────────────────────────────
    ((!), (Bool,), "not_bool"),
    (xor, (Bool, Bool), "xor_bool"),

    # ── Char ────────────────────────────────────────────────
    (isdigit, (Char,), "isdigit_char"),
    (isletter, (Char,), "isletter_char"),
    (isspace, (Char,), "isspace_char"),
    (isuppercase, (Char,), "isuppercase_char"),
    (islowercase, (Char,), "islowercase_char"),
    (uppercase, (Char,), "uppercase_char"),
    (lowercase, (Char,), "lowercase_char"),
    (isascii, (Char,), "isascii_char"),
    (textwidth, (Char,), "textwidth_char"),

    # ── Tuple ───────────────────────────────────────────────
    (first, (Tuple{Int64,Int64},), "first_tuple2"),
    (last, (Tuple{Int64,Int64},), "last_tuple2"),

    # ── Misc ────────────────────────────────────────────────
    (identity, (Int64,), "identity_i64"),
    (zero, (Int64,), "zero_i64"),
    (one, (Int64,), "one_i64"),
    (hash, (Int64,), "hash_i64"),
    (ifelse, (Bool, Int64, Int64), "ifelse_i64"),

    # ── String ops ──────────────────────────────────────────
    (ncodeunits, (String,), "ncodeunits_str"),
    (sizeof, (String,), "sizeof_str"),
    (startswith, (String, String), "startswith_str"),
    (endswith, (String, String), "endswith_str"),
    (isempty, (String,), "isempty_str"),
    (isascii, (String,), "isascii_str"),
    (thisind, (String, Int64), "thisind_str"),
    (nextind, (String, Int64), "nextind_str"),
    (prevind, (String, Int64), "prevind_str"),

    # ── Array ops ───────────────────────────────────────────
    (length, (Vector{Int64},), "length_vec_i64"),
    (length, (Vector{Float64},), "length_vec_f64"),
    (sum, (Vector{Int64},), "sum_vec_i64"),
    (sum, (Vector{Float64},), "sum_vec_f64"),
    (prod, (Vector{Int64},), "prod_vec_i64"),
    (maximum, (Vector{Int64},), "maximum_vec_i64"),
    (minimum, (Vector{Int64},), "minimum_vec_i64"),
    (issorted, (Vector{Int64},), "issorted_vec_i64"),
    (any, (Vector{Bool},), "any_vec_bool"),
    (all, (Vector{Bool},), "all_vec_bool"),
]

# ── Phase 1: Validate each function individually ──────────────
println("Phase 1: Validating $(length(ALL_FUNCTIONS)) functions individually...")
println("=" ^ 60)

tmpfile = tempname() * ".wasm"
validated = []
skipped = []

for (i, (f, types, name)) in enumerate(ALL_FUNCTIONS)
    try
        bytes = compile(f, types)
        write(tmpfile, bytes)
        result = read(`wasm-tools validate $tmpfile`, String)
        push!(validated, (f, types, name))
        println("  ✓ $name ($(length(bytes)) bytes)")
    catch e
        if e isa ProcessFailedException || e isa Base.IOError
            push!(skipped, (name, "wasm-tools validation failed"))
            println("  ✗ $name → validation failed")
        else
            # Check if compile itself failed
            push!(skipped, (name, string(e)[1:min(60, length(string(e)))]))
            println("  ✗ $name → compile error")
        end
    end
end

rm(tmpfile, force=true)

println()
println("Phase 1 results: $(length(validated))/$(length(ALL_FUNCTIONS)) validated")
if !isempty(skipped)
    println("Skipped ($(length(skipped))):")
    for (name, reason) in skipped
        println("  - $name: $reason")
    end
end

# ── Phase 2: Build base.wasm with registries ──────────────────
println()
println("Phase 2: Building base.wasm from $(length(validated)) validated functions...")
println("=" ^ 60)

t = @elapsed begin
    bytes, type_registry, func_registry, dispatch_registry = compile_multi(validated; return_registries=true)
end

size_kb = round(length(bytes) / 1024, digits=1)
size_mb = round(length(bytes) / (1024 * 1024), digits=2)

outpath = joinpath(dirname(@__DIR__), "base.wasm")
write(outpath, bytes)

println("  Functions: $(length(validated))")
println("  Size: $(length(bytes)) bytes ($size_kb KB / $size_mb MB)")
println("  Time: $(round(t, digits=1))s")
println("  Written to: $outpath")

# ── Phase 3: Validate final module ───────────────────────────
println()
println("Phase 3: Validating base.wasm...")
try
    run(`wasm-tools validate $outpath`)
    println("  ✓ base.wasm passes wasm-tools validate")
catch
    println("  ✗ base.wasm fails validation — trying to identify bad functions in multi-module...")
    println("  (Individual functions validated, but compile_multi may introduce type conflicts)")
end

# ── Phase 4: Serialize type registry and function table ───────
println()
println("Phase 4: Serializing metadata...")

# Simple JSON serializer (no dependency needed)
function to_json(x, indent=0)
    pad = "  " ^ indent
    if x isa Dict
        pairs = sort(collect(x), by=first)
        isempty(pairs) && return "{}"
        lines = ["$pad  $(to_json(string(k))): $(to_json(v, indent+1))" for (k,v) in pairs]
        return "{\n" * join(lines, ",\n") * "\n$pad}"
    elseif x isa Vector
        isempty(x) && return "[]"
        lines = ["$pad  $(to_json(v, indent+1))" for v in x]
        return "[\n" * join(lines, ",\n") * "\n$pad]"
    elseif x isa AbstractString
        return "\"$(escape_string(x))\""
    elseif x isa Number
        return string(x)
    elseif x isa Bool
        return x ? "true" : "false"
    else
        return "\"$(escape_string(string(x)))\""
    end
end

# Serialize type registry
type_reg_data = serialize_type_registry(type_registry)
type_reg_path = joinpath(dirname(@__DIR__), "type-registry.json")
open(type_reg_path, "w") do io
    write(io, to_json(type_reg_data))
    write(io, "\n")
end
println("  ✓ type-registry.json ($(filesize(type_reg_path)) bytes)")

# Serialize function table
func_table_data = serialize_function_table(func_registry)
func_table_path = joinpath(dirname(@__DIR__), "function-table.json")
open(func_table_path, "w") do io
    write(io, to_json(func_table_data))
    write(io, "\n")
end
println("  ✓ function-table.json ($(length(func_table_data)) entries, $(filesize(func_table_path)) bytes)")

# PURE-9061: Serialize dispatch tables (frozen, immutable at runtime)
dispatch_data = serialize_dispatch_tables(dispatch_registry, type_registry)
dispatch_path = joinpath(dirname(@__DIR__), "dispatch-tables.json")
open(dispatch_path, "w") do io
    write(io, to_json(dispatch_data))
    write(io, "\n")
end
n_tables = length(dispatch_data)
n_total_entries = sum(d["num_entries"] for d in dispatch_data; init=0)
println("  ✓ dispatch-tables.json ($n_tables tables, $n_total_entries entries, $(filesize(dispatch_path)) bytes)")

println()
println("Build complete: base.wasm + type-registry.json + function-table.json + dispatch-tables.json")
