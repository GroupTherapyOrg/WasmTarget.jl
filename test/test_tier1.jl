#!/usr/bin/env julia
# Tier 1 Function Compilation Verification
# Tests that all functions in src/tier1_functions.toml compile successfully.
# Run: julia --project=. test/test_tier1.jl

using WasmTarget

function run_tier1_test()
    test_cases = [
        # (name, function, arg_types)
        # ================================================================
        # ARITHMETIC
        # ================================================================
        ("+", +, (Int64, Int64)),
        ("+(Float64)", +, (Float64, Float64)),
        ("+(Int64,Float64)", +, (Int64, Float64)),
        ("+(Int32)", +, (Int32, Int32)),
        ("-", -, (Int64, Int64)),
        ("-(Float64)", -, (Float64, Float64)),
        ("-(Int32)", -, (Int32, Int32)),
        ("*", *, (Int64, Int64)),
        ("*(Float64)", *, (Float64, Float64)),
        ("*(Int64,Float64)", *, (Int64, Float64)),
        ("*(Int32)", *, (Int32, Int32)),
        ("/", /, (Float64, Float64)),
        ("^", ^, (Int64, Int64)),
        ("div", div, (Int64, Int64)),
        ("rem", rem, (Int64, Int64)),
        ("mod", mod, (Int64, Int64)),
        ("divrem", divrem, (Int64, Int64)),
        ("fld", fld, (Int64, Int64)),
        ("cld", cld, (Int64, Int64)),
        ("muladd", muladd, (Float64, Float64, Float64)),
        ("widemul", widemul, (Int32, Int32)),
        # ================================================================
        # MATH — Rounding, abs, sign
        # ================================================================
        ("abs(Int64)", abs, (Int64,)),
        ("abs(Int32)", abs, (Int32,)),
        ("abs(Float64)", abs, (Float64,)),
        ("sign(Int64)", sign, (Int64,)),
        ("sign(Float64)", sign, (Float64,)),
        ("signbit", signbit, (Float64,)),
        ("copysign(Int64)", copysign, (Int64, Int64)),
        ("copysign(Float64)", copysign, (Float64, Float64)),
        ("flipsign(Int64)", flipsign, (Int64, Int64)),
        ("flipsign(Float64)", flipsign, (Float64, Float64)),
        ("floor", floor, (Float64,)),
        ("ceil", ceil, (Float64,)),
        ("round", round, (Float64,)),
        ("trunc", trunc, (Float64,)),
        ("clamp(Int64)", clamp, (Int64, Int64, Int64)),
        ("clamp(Float64)", clamp, (Float64, Float64, Float64)),
        ("min(Int64)", min, (Int64, Int64)),
        ("max(Int64)", max, (Int64, Int64)),
        ("min(Float64)", min, (Float64, Float64)),
        ("max(Float64)", max, (Float64, Float64)),
        ("minmax", minmax, (Int64, Int64)),
        ("sqrt", sqrt, (Float64,)),
        ("cbrt", cbrt, (Float64,)),
        # ================================================================
        # MATH — Trigonometric
        # ================================================================
        ("sin", sin, (Float64,)),
        ("cos", cos, (Float64,)),
        ("tan", tan, (Float64,)),
        ("asin", asin, (Float64,)),
        ("acos", acos, (Float64,)),
        ("atan", atan, (Float64,)),
        ("atan2", atan, (Float64, Float64)),
        # ================================================================
        # MATH — Exponential/Logarithmic
        # ================================================================
        ("exp", exp, (Float64,)),
        ("exp2", exp2, (Float64,)),
        ("exp10", exp10, (Float64,)),
        ("cosh", cosh, (Float64,)),
        ("tanh", tanh, (Float64,)),
        ("log", log, (Float64,)),
        ("log2", log2, (Float64,)),
        ("log10", log10, (Float64,)),
        ("log1p", log1p, (Float64,)),
        ("sinh", sinh, (Float64,)),
        ("expm1", expm1, (Float64,)),
        ("hypot", hypot, (Float64, Float64)),
        # ================================================================
        # MATH — Number Theory
        # ================================================================
        ("gcd", gcd, (Int64, Int64)),
        ("lcm", lcm, (Int64, Int64)),
        ("gcdx", gcdx, (Int64, Int64)),
        ("powermod", powermod, (Int64, Int64, Int64)),
        ("invmod", invmod, (Int64, Int64)),
        ("ndigits", ndigits, (Int64,)),
        # ================================================================
        # COMPARISON
        # ================================================================
        ("isequal(Int64)", isequal, (Int64, Int64)),
        ("isequal(Float64)", isequal, (Float64, Float64)),
        ("isless(Int64)", isless, (Int64, Int64)),
        ("isless(Float64)", isless, (Float64, Float64)),
        ("cmp", cmp, (Int64, Int64)),
        # ================================================================
        # PREDICATES
        # ================================================================
        ("iszero", iszero, (Int64,)),
        ("isone", isone, (Int64,)),
        ("iseven", iseven, (Int64,)),
        ("isodd", isodd, (Int64,)),
        ("isnan", isnan, (Float64,)),
        ("isinf", isinf, (Float64,)),
        ("isfinite", isfinite, (Float64,)),
        # ================================================================
        # BITWISE
        # ================================================================
        ("&", &, (Int64, Int64)),
        ("|", |, (Int64, Int64)),
        ("xor", xor, (Int64, Int64)),
        ("~", ~, (Int64,)),
        ("<<", <<, (Int64, Int64)),
        (">>", >>, (Int64, Int64)),
        (">>>", >>>, (Int64, Int64)),
        ("count_ones", count_ones, (Int64,)),
        ("leading_zeros", leading_zeros, (Int64,)),
        ("trailing_zeros", trailing_zeros, (Int64,)),
        # ================================================================
        # TYPE CONVERSION
        # ================================================================
        ("float", float, (Int64,)),
        ("widen", widen, (Int32,)),
        ("Int64(Int32)", Int64, (Int32,)),
        ("Int64(UInt64)", Int64, (UInt64,)),
        ("Float64(Int32)", Float64, (Int32,)),
        ("Float64(Float32)", Float64, (Float32,)),
        ("Float32(Float64)", Float32, (Float64,)),
        ("UInt64(Int64)", UInt64, (Int64,)),
        ("UInt32(Int32)", UInt32, (Int32,)),
        ("Char(Int32)", Char, (Int32,)),
        ("Int32(Char)", Int32, (Char,)),
        ("Bool(Int64)", Bool, (Int64,)),
        ("Int(Float64)", Int, (Float64,)),
        # ================================================================
        # BOOLEAN
        # ================================================================
        ("!", !, (Bool,)),
        ("xor(Bool)", xor, (Bool, Bool)),
        # ================================================================
        # CHAR
        # ================================================================
        ("isdigit", isdigit, (Char,)),
        ("isletter", isletter, (Char,)),
        ("isspace", isspace, (Char,)),
        ("isuppercase", isuppercase, (Char,)),
        ("islowercase", islowercase, (Char,)),
        ("uppercase(Char)", uppercase, (Char,)),
        ("lowercase(Char)", lowercase, (Char,)),
        ("isascii(Char)", isascii, (Char,)),
        ("textwidth(Char)", textwidth, (Char,)),
        # ================================================================
        # TUPLE
        # ================================================================
        ("first(Tuple)", first, (Tuple{Int64,Int64},)),
        ("last(Tuple)", last, (Tuple{Int64,Int64},)),
        ("length(Tuple)", length, (Tuple{Int64,Int64,Int64},)),
        ("reverse(Tuple)", reverse, (Tuple{Int64,Int64},)),
        # ================================================================
        # IDENTITY / CONSTANTS
        # ================================================================
        ("identity", identity, (Int64,)),
        ("zero", zero, (Int64,)),
        ("one", one, (Int64,)),
        ("typemax", typemax, (Type{Int64},)),
        ("typemin", typemin, (Type{Int64},)),
        ("objectid", objectid, (Int64,)),
        ("hash", hash, (Int64,)),
        # ================================================================
        # RANGE / CONTROL FLOW
        # ================================================================
        ("UnitRange", UnitRange, (Int64, Int64)),
        ("ifelse", ifelse, (Bool, Int64, Int64)),
        # ================================================================
        # STRING OPERATIONS
        # ================================================================
        ("ncodeunits", ncodeunits, (String,)),
        ("codeunit", codeunit, (String, Int64)),
        ("sizeof(String)", sizeof, (String,)),
        ("startswith", startswith, (String, String)),
        ("endswith", endswith, (String, String)),
        ("contains", contains, (String, String)),
        ("repeat", repeat, (String, Int64)),
        ("chomp", chomp, (String,)),
        ("strip", strip, (String,)),
        ("lstrip", lstrip, (String,)),
        ("rstrip", rstrip, (String,)),
        ("uppercase(String)", uppercase, (String,)),
        ("lowercase(String)", lowercase, (String,)),
        ("titlecase", titlecase, (String,)),
        ("ascii", ascii, (String,)),
        ("isascii(String)", isascii, (String,)),
        ("isempty(String)", isempty, (String,)),
        ("isvalid(String)", isvalid, (String,)),
        ("lpad", lpad, (String, Int64, Char)),
        ("rpad", rpad, (String, Int64, Char)),
        ("first(String,Int)", first, (String, Int64)),
        ("last(String,Int)", last, (String, Int64)),
        ("chop", chop, (String,)),
        ("thisind", thisind, (String, Int64)),
        ("nextind", nextind, (String, Int64)),
        ("prevind", prevind, (String, Int64)),
        ("replace", replace, (String, Pair{String,String})),
        ("string(Int64)", string, (Int64,)),
        ("string(Float64)", string, (Float64,)),
        ("string(Bool)", string, (Bool,)),
        # ================================================================
        # ARRAY OPERATIONS
        # ================================================================
        ("length(Vector{Int64})", length, (Vector{Int64},)),
        ("length(Vector{Float64})", length, (Vector{Float64},)),
        ("length(Vector{Int32})", length, (Vector{Int32},)),
        ("getindex(Vector{Int64})", getindex, (Vector{Int64}, Int64)),
        ("setindex!(Vector{Int64})", setindex!, (Vector{Int64}, Int64, Int64)),
        ("push!(Vector{Int64})", push!, (Vector{Int64}, Int64)),
        ("pop!(Vector{Int64})", pop!, (Vector{Int64},)),
        ("empty!(Vector{Int64})", empty!, (Vector{Int64},)),
        ("append!(Vector{Int64})", append!, (Vector{Int64}, Vector{Int64})),
        ("sum(Vector{Int64})", sum, (Vector{Int64},)),
        ("sum(Vector{Float64})", sum, (Vector{Float64},)),
        ("prod(Vector{Int64})", prod, (Vector{Int64},)),
        ("maximum(Vector{Int64})", maximum, (Vector{Int64},)),
        ("minimum(Vector{Int64})", minimum, (Vector{Int64},)),
        ("findmax(Vector{Int64})", findmax, (Vector{Int64},)),
        ("findmin(Vector{Int64})", findmin, (Vector{Int64},)),
        ("reverse(Vector{Int64})", reverse, (Vector{Int64},)),
        ("sort(Vector{Int64})", sort, (Vector{Int64},)),
        ("sort!(Vector{Int64})", sort!, (Vector{Int64},)),
        ("issorted(Vector{Int64})", issorted, (Vector{Int64},)),
        ("any(Vector{Bool})", any, (Vector{Bool},)),
        ("all(Vector{Bool})", all, (Vector{Bool},)),
        ("in(Int64,Vector{Int64})", in, (Int64, Vector{Int64})),
        ("unique(Vector{Int64})", unique, (Vector{Int64},)),
        ("diff(Vector{Int64})", diff, (Vector{Int64},)),
        ("cumsum(Vector{Int64})", cumsum, (Vector{Int64},)),
        ("collect(UnitRange)", collect, (UnitRange{Int64},)),
        ("reduce(+,Vector{Int64})", reduce, (typeof(+), Vector{Int64})),
    ]

    ok = 0
    fail = 0
    total = length(test_cases)

    println("Tier 1 Compilation Verification — $(total) functions")
    println("=" ^ 60)

    for (name, f, types) in test_cases
        try
            bytes = compile(f, types)
            ok += 1
            println("  ✓ $name → $(length(bytes)) bytes")
        catch e
            fail += 1
            msg = string(e)[1:min(60, length(string(e)))]
            println("  ✗ $name → $msg")
        end
    end

    println()
    println("Results: $ok/$total compiled ($fail failed)")
    println()
    if fail == 0
        println("ALL TIER 1 FUNCTIONS COMPILE SUCCESSFULLY")
    else
        println("$fail functions need fixes")
    end
end

run_tier1_test()
