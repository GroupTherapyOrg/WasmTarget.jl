#!/usr/bin/env julia
# Tier 1 Function Compilation Verification
# Tests that all functions in src/tier1_functions.toml compile successfully.
# Run: julia --project=. test/test_tier1.jl

using WasmTarget

# Map type name strings to Julia types
const TYPE_MAP = Dict{String, Any}(
    "Int64" => Int64, "Int32" => Int32,
    "UInt64" => UInt64, "UInt32" => UInt32,
    "Float64" => Float64, "Float32" => Float32,
    "Bool" => Bool, "Char" => Char,
    "Nothing" => Nothing, "String" => String,
    "Type{Int64}" => Type{Int64}, "Type{Int32}" => Type{Int32},
    "Tuple{Int64,Int64}" => Tuple{Int64,Int64},
    "Tuple{Int64,Int64,Int64}" => Tuple{Int64,Int64,Int64},
)

# Map function name strings to Julia functions
function resolve_func(name::String)
    func_map = Dict{String, Any}(
        "+" => +, "-" => -, "*" => *, "/" => /,
        "^" => ^, "div" => div, "rem" => rem, "mod" => mod,
        "divrem" => divrem, "fld" => fld, "cld" => cld,
        "muladd" => muladd, "widemul" => widemul,
        "abs" => abs, "sign" => sign, "signbit" => signbit,
        "copysign" => copysign, "flipsign" => flipsign,
        "floor" => floor, "ceil" => ceil, "round" => round, "trunc" => trunc,
        "clamp" => clamp, "min" => min, "max" => max, "minmax" => minmax,
        "sqrt" => sqrt, "cbrt" => cbrt,
        "sin" => sin, "cos" => cos, "tan" => tan,
        "asin" => asin, "acos" => acos, "atan" => atan,
        "exp" => exp, "exp2" => exp2, "exp10" => exp10,
        "cosh" => cosh, "tanh" => tanh,
        "gcd" => gcd, "lcm" => lcm, "gcdx" => gcdx,
        "powermod" => powermod, "invmod" => invmod, "ndigits" => ndigits,
        "isequal" => isequal, "isless" => isless, "cmp" => cmp,
        "iszero" => iszero, "isone" => isone,
        "iseven" => iseven, "isodd" => isodd,
        "isnan" => isnan, "isinf" => isinf, "isfinite" => isfinite,
        "&" => &, "|" => |, "xor" => xor, "~" => ~,
        "<<" => <<, ">>" => >>, ">>>" => >>>,
        "count_ones" => count_ones, "leading_zeros" => leading_zeros,
        "trailing_zeros" => trailing_zeros,
        "float" => float, "widen" => widen,
        "Int64" => Int64, "Int32" => Int32, "Float64" => Float64,
        "Float32" => Float32, "UInt64" => UInt64, "UInt32" => UInt32,
        "Char" => Char, "Bool" => Bool,
        "!" => !, "isdigit" => isdigit, "isletter" => isletter,
        "isspace" => isspace, "isuppercase" => isuppercase,
        "islowercase" => islowercase, "uppercase" => uppercase,
        "lowercase" => lowercase,
        "first" => first, "last" => last, "length" => length,
        "reverse" => reverse,
        "identity" => identity, "zero" => zero, "one" => one,
        "typemax" => typemax, "typemin" => typemin,
        "objectid" => objectid, "hash" => hash,
        "UnitRange" => UnitRange,
    )
    return get(func_map, name, nothing)
end

function run_tier1_test()
    # Parse TOML manually (avoid TOML dependency)
    toml_path = joinpath(dirname(@__DIR__), "src", "tier1_functions.toml")
    if !isfile(toml_path)
        println("ERROR: $toml_path not found")
        return
    end

    # Simple approach: test all functions we know about
    test_cases = [
        # (name, function, arg_types)
        # Arithmetic
        ("+", +, (Int64, Int64)),
        ("-", -, (Int64, Int64)),
        ("*", *, (Int64, Int64)),
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
        # Math
        ("abs(Int64)", abs, (Int64,)),
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
        # Trig
        ("sin", sin, (Float64,)),
        ("cos", cos, (Float64,)),
        ("tan", tan, (Float64,)),
        ("asin", asin, (Float64,)),
        ("acos", acos, (Float64,)),
        ("atan", atan, (Float64,)),
        ("atan2", atan, (Float64, Float64)),
        # Exp
        ("exp", exp, (Float64,)),
        ("exp2", exp2, (Float64,)),
        ("exp10", exp10, (Float64,)),
        ("cosh", cosh, (Float64,)),
        ("tanh", tanh, (Float64,)),
        # Number theory
        ("gcd", gcd, (Int64, Int64)),
        ("lcm", lcm, (Int64, Int64)),
        ("gcdx", gcdx, (Int64, Int64)),
        ("powermod", powermod, (Int64, Int64, Int64)),
        ("invmod", invmod, (Int64, Int64)),
        ("ndigits", ndigits, (Int64,)),
        # Comparisons
        ("isequal", isequal, (Int64, Int64)),
        ("isless(Int64)", isless, (Int64, Int64)),
        ("isless(Float64)", isless, (Float64, Float64)),
        ("cmp", cmp, (Int64, Int64)),
        # Predicates
        ("iszero", iszero, (Int64,)),
        ("isone", isone, (Int64,)),
        ("iseven", iseven, (Int64,)),
        ("isodd", isodd, (Int64,)),
        ("isnan", isnan, (Float64,)),
        ("isinf", isinf, (Float64,)),
        ("isfinite", isfinite, (Float64,)),
        # Bitwise
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
        # Conversion
        ("float", float, (Int64,)),
        ("widen", widen, (Int32,)),
        ("Int64(Int32)", Int64, (Int32,)),
        ("Float64(Int32)", Float64, (Int32,)),
        ("Float64(Float32)", Float64, (Float32,)),
        ("Float32(Float64)", Float32, (Float64,)),
        ("UInt64(Int64)", UInt64, (Int64,)),
        ("Int64(UInt64)", Int64, (UInt64,)),
        ("UInt32(Int32)", UInt32, (Int32,)),
        ("Char(Int32)", Char, (Int32,)),
        ("Int32(Char)", Int32, (Char,)),
        ("Bool(Int64)", Bool, (Int64,)),
        # Boolean
        ("!", !, (Bool,)),
        ("xor(Bool)", xor, (Bool, Bool)),
        # Char
        ("isdigit", isdigit, (Char,)),
        ("isletter", isletter, (Char,)),
        ("isspace", isspace, (Char,)),
        ("isuppercase", isuppercase, (Char,)),
        ("islowercase", islowercase, (Char,)),
        ("uppercase", uppercase, (Char,)),
        ("lowercase", lowercase, (Char,)),
        # Tuple
        ("first", first, (Tuple{Int64,Int64},)),
        ("last", last, (Tuple{Int64,Int64},)),
        ("length(Tuple)", length, (Tuple{Int64,Int64,Int64},)),
        ("reverse(Tuple)", reverse, (Tuple{Int64,Int64},)),
        # Misc
        ("identity", identity, (Int64,)),
        ("zero", zero, (Int64,)),
        ("one", one, (Int64,)),
        ("typemax", typemax, (Type{Int64},)),
        ("typemin", typemin, (Type{Int64},)),
        ("objectid", objectid, (Int64,)),
        ("hash", hash, (Int64,)),
        # Range
        ("UnitRange", UnitRange, (Int64, Int64)),
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
