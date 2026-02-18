# PURE-4141: Full typeinf — 77/77 CORRECT with Julia reimplementations
#
# Re-runs the DictMethodTable verification suite with REAL Julia reimplementations
# (wasm_subtype, wasm_type_intersection, wasm_matching_methods) instead of
# pre-computed Dict lookups.
#
# ALL 77 original test cases must be CORRECT.
# Additional tests with user-defined / parametric / Union types prove the
# reimplementation works for types NOT seen at build time.
#
# Usage:
#   julia +1.12 --project=WasmTarget.jl -e 'include("WasmTarget.jl/test/test_typeinf_reimpl.jl")'

# Load the typeinf reimplementation stack
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

using Test

# ─── User-defined types (same as test_dict_typeinf.jl) ────────────────────────

struct Point2D
    x::Float64
    y::Float64
end

struct MyContainer{T}
    value::T
    label::String
end

distance(p::Point2D) = sqrt(p.x^2 + p.y^2)
translate(p::Point2D, dx::Float64, dy::Float64) = Point2D(p.x + dx, p.y + dy)
get_value(c::MyContainer) = c.value

# ─── Simple functions for control flow testing ────────────────────────────────

function my_abs(x::Int64)
    if x < 0
        return -x
    else
        return x
    end
end

function my_sum(n::Int64)
    s = 0
    for i in 1:n
        s += i
    end
    return s
end

function my_while_sum(n::Int64)
    s = 0
    i = 1
    while i <= n
        s += i
        i += 1
    end
    return s
end

function my_factorial(n::Int64)
    n <= 1 && return 1
    return n * my_factorial(n - 1)
end

# ─── Phase D verification functions (PURE-3110) ──────────────────────────────

function my_string_concat(a::String, b::String)
    return a * b
end

function my_dict_get(d::Dict{String, Int64}, key::String)
    return get(d, key, 0)
end

function my_squares(n::Int64)
    return [i^2 for i in 1:n]
end

function my_make_tuple(a::Int64, b::Float64)
    return (a, b)
end

my_double(x::Int64) = 2x
my_double(x::Float64) = 2.0 * x

function my_map_inc(v::Vector{Int64})
    return map(x -> x + 1, v)
end

function my_repeat_str(s::String, n::Int64)
    return repeat(s, n)
end

function my_convert_float(x::Int64)
    return convert(Float64, x)
end

function my_make_pair(a::Int64, b::String)
    return Pair(a, b)
end

function my_push_vec(v::Vector{Int64}, x::Int64)
    push!(v, x)
    return length(v)
end

# ─── NEW: Novel types NOT in original Dict (Phase 2d runtime verification) ───

# User-defined struct types
struct Color3
    r::UInt8
    g::UInt8
    b::UInt8
end

struct Particle{T<:Real}
    x::T
    y::T
    mass::T
end

struct NamedValue{K, V}
    key::K
    val::V
end

color_brightness(c::Color3) = (Int(c.r) + Int(c.g) + Int(c.b)) / 3.0
particle_energy(p::Particle) = 0.5 * p.mass * (p.x^2 + p.y^2)
named_pair(nv::NamedValue) = nv.key => nv.val

# Parametric types with new type parameters
function my_sum_vec(v::Vector{Float32})
    s = Float32(0)
    for x in v
        s += x
    end
    return s
end

function my_int32_add(a::Int32, b::Int32)
    return a + b
end

function my_uint_shift(x::UInt64, n::Int64)
    return x >> n
end

# Union types not seen at build time
function my_union_check(x::Union{Int64, String})
    if x isa Int64
        return x + 1
    else
        return length(x)
    end
end

function my_maybe_nothing(x::Union{Float64, Nothing})
    if x === nothing
        return 0.0
    else
        return x * 2.0
    end
end

function my_multi_union(x::Union{Int32, Float32, Bool})
    if x isa Int32
        return Int64(x)
    elseif x isa Float32
        return Float64(x)
    else
        return x ? 1 : 0
    end
end

# ─── Test cases ──────────────────────────────────────────────────────────────

const ORIGINAL_TEST_CASES = [
    # ── Arithmetic (Int64) ──
    ("+(Int64,Int64)",       +,        (Int64, Int64)),
    ("-(Int64,Int64)",       -,        (Int64, Int64)),
    ("*(Int64,Int64)",       *,        (Int64, Int64)),
    ("div(Int64,Int64)",     div,      (Int64, Int64)),
    ("rem(Int64,Int64)",     rem,      (Int64, Int64)),
    ("mod(Int64,Int64)",     mod,      (Int64, Int64)),
    ("abs(Int64)",           abs,      (Int64,)),
    ("-(Int64) [unary]",     -,        (Int64,)),

    # ── Arithmetic (Float64) ──
    ("+(Float64,Float64)",   +,        (Float64, Float64)),
    ("-(Float64,Float64)",   -,        (Float64, Float64)),
    ("*(Float64,Float64)",   *,        (Float64, Float64)),
    ("/(Float64,Float64)",   /,        (Float64, Float64)),
    ("abs(Float64)",         abs,      (Float64,)),

    # ── Math functions ──
    ("sin(Float64)",         sin,      (Float64,)),
    ("cos(Float64)",         cos,      (Float64,)),
    ("tan(Float64)",         tan,      (Float64,)),
    ("sqrt(Float64)",        sqrt,     (Float64,)),
    ("log(Float64)",         log,      (Float64,)),
    ("exp(Float64)",         exp,      (Float64,)),
    ("floor(Float64)",       floor,    (Float64,)),
    ("ceil(Float64)",        ceil,     (Float64,)),
    ("round(Float64)",       round,    (Float64,)),

    # ── Comparison ──
    ("<(Int64,Int64)",       <,        (Int64, Int64)),
    (">(Int64,Int64)",       >,        (Int64, Int64)),
    ("==(Int64,Int64)",      ==,       (Int64, Int64)),
    ("!=(Int64,Int64)",      !=,       (Int64, Int64)),
    ("<=(Int64,Int64)",      <=,       (Int64, Int64)),
    (">=(Int64,Int64)",      >=,       (Int64, Int64)),
    ("isless(Float64,Float64)", isless, (Float64, Float64)),

    # ── Boolean / bitwise ──
    ("&(Bool,Bool)",         &,        (Bool, Bool)),
    ("|(Bool,Bool)",         |,        (Bool, Bool)),
    ("xor(Bool,Bool)",       xor,      (Bool, Bool)),

    # ── Type checks ──
    ("iseven(Int64)",        iseven,   (Int64,)),
    ("isodd(Int64)",         isodd,    (Int64,)),
    ("iszero(Int64)",        iszero,   (Int64,)),
    ("isone(Int64)",         isone,    (Int64,)),
    ("isnan(Float64)",       isnan,    (Float64,)),
    ("isinf(Float64)",       isinf,    (Float64,)),
    ("isfinite(Float64)",    isfinite, (Float64,)),

    # ── String operations ──
    ("length(String)",       length,   (String,)),
    ("ncodeunits(String)",   ncodeunits, (String,)),
    ("sizeof(String)",       sizeof,   (String,)),
    ("isempty(String)",      isempty,  (String,)),
    ("uppercase(String)",    uppercase, (String,)),
    ("lowercase(String)",    lowercase, (String,)),

    # ── Array operations ──
    ("length(Vector{Int64})", length,  (Vector{Int64},)),
    ("isempty(Vector{Int64})", isempty, (Vector{Int64},)),
    ("first(Vector{Int64})", first,    (Vector{Int64},)),
    ("last(Vector{Int64})",  last,     (Vector{Int64},)),
    ("sum(Vector{Int64})",   sum,      (Vector{Int64},)),

    # ── Type conversion ──
    ("float(Int64)",         float,    (Int64,)),
    ("Int64(Bool)",          Int64,    (Bool,)),

    # ── Control flow (user-defined) ──
    ("my_abs(Int64)",        my_abs,   (Int64,)),
    ("my_sum(Int64)",        my_sum,   (Int64,)),
    ("my_while_sum(Int64)",  my_while_sum, (Int64,)),
    ("my_factorial(Int64)",  my_factorial, (Int64,)),

    # ── User-defined structs ──
    ("distance(Point2D)",    distance, (Point2D,)),
    ("translate(Point2D,Float64,Float64)", translate, (Point2D, Float64, Float64)),
    ("get_value(MyContainer{Int64})", get_value, (MyContainer{Int64},)),

    # ── Misc ──
    ("zero(Int64)",          zero,     (Type{Int64},)),
    ("one(Int64)",           one,      (Type{Int64},)),
    ("typemax(Int64)",       typemax,  (Type{Int64},)),
    ("typemin(Int64)",       typemin,  (Type{Int64},)),
    ("min(Int64,Int64)",     min,      (Int64, Int64)),
    ("max(Int64,Int64)",     max,      (Int64, Int64)),
    ("clamp(Int64,Int64,Int64)", clamp, (Int64, Int64, Int64)),
    ("sign(Int64)",          sign,     (Int64,)),

    # ── Phase D verification (PURE-3110) ──
    ("my_string_concat(String,String)", my_string_concat, (String, String)),
    ("my_dict_get(Dict{String,Int64},String)", my_dict_get, (Dict{String,Int64}, String)),
    ("my_squares(Int64)",    my_squares, (Int64,)),
    ("my_make_tuple(Int64,Float64)", my_make_tuple, (Int64, Float64)),
    ("my_double(Int64)",     my_double,  (Int64,)),
    ("my_map_inc(Vector{Int64})", my_map_inc, (Vector{Int64},)),
    ("my_repeat_str(String,Int64)", my_repeat_str, (String, Int64)),
    ("my_convert_float(Int64)", my_convert_float, (Int64,)),
    ("my_make_pair(Int64,String)", my_make_pair, (Int64, String)),
    ("my_push_vec(Vector{Int64},Int64)", my_push_vec, (Vector{Int64}, Int64)),
]

const NOVEL_TEST_CASES = [
    # ── Novel user-defined structs (NOT in original Dict) ──
    ("color_brightness(Color3)", color_brightness, (Color3,)),
    ("particle_energy(Particle{Float64})", particle_energy, (Particle{Float64},)),
    ("particle_energy(Particle{Float32})", particle_energy, (Particle{Float32},)),
    ("named_pair(NamedValue{String,Int64})", named_pair, (NamedValue{String,Int64},)),
    ("named_pair(NamedValue{Symbol,Float64})", named_pair, (NamedValue{Symbol,Float64},)),

    # ── Parametric types with new type parameters ──
    ("my_sum_vec(Vector{Float32})", my_sum_vec, (Vector{Float32},)),
    ("my_int32_add(Int32,Int32)", my_int32_add, (Int32, Int32)),
    ("my_uint_shift(UInt64,Int64)", my_uint_shift, (UInt64, Int64)),
    ("get_value(MyContainer{String})", get_value, (MyContainer{String},)),
    ("get_value(MyContainer{Float64})", get_value, (MyContainer{Float64},)),

    # ── Union types not seen at build time ──
    ("my_union_check(Union{Int64,String}→Int64)", my_union_check, (Int64,)),
    ("my_union_check(Union{Int64,String}→String)", my_union_check, (String,)),
    ("my_maybe_nothing(Float64)", my_maybe_nothing, (Float64,)),
    ("my_maybe_nothing(Nothing)", my_maybe_nothing, (Nothing,)),
    ("my_multi_union(Int32)", my_multi_union, (Int32,)),
    ("my_multi_union(Float32)", my_multi_union, (Float32,)),
    ("my_multi_union(Bool)", my_multi_union, (Bool,)),
]

# ─── Run all tests ───────────────────────────────────────────────────────────

function run_tests(test_cases, section_name)
    n_pass = 0
    n_fail = 0
    n_error = 0
    results = []

    for (name, f, argtypes) in test_cases
        result = try
            verify_typeinf(f, argtypes)
        catch e
            (pass=false, reason="ERROR: $(sprint(showerror, e))",
             native_rettype=nothing, dict_rettype=nothing)
        end

        status = if hasproperty(result, :reason) && !result.pass
            n_error += 1
            "ERROR"
        elseif result.pass
            n_pass += 1
            "CORRECT"
        else
            n_fail += 1
            "MISMATCH"
        end

        push!(results, (name=name, status=status,
            native=hasproperty(result, :native_rettype) ? result.native_rettype : nothing,
            dict=hasproperty(result, :dict_rettype) ? result.dict_rettype : nothing,
            reason=hasproperty(result, :reason) ? result.reason : nothing))

        @test result.pass == true
    end

    return (results=results, n_pass=n_pass, n_fail=n_fail, n_error=n_error)
end

println("=" ^ 80)
println("PURE-4141: Full Typeinf — Julia Reimplementations (Phase 2d)")
println("Testing $(length(ORIGINAL_TEST_CASES)) original + $(length(NOVEL_TEST_CASES)) novel = $(length(ORIGINAL_TEST_CASES) + length(NOVEL_TEST_CASES)) total")
println("Reimplementation mode: _WASM_USE_REIMPL = true (real Julia reimpl)")
println("=" ^ 80)
println()

total_pass = 0
total_fail = 0
total_error = 0

# Section 1: Original 77 test cases
@testset "Original 77 test cases (reimpl mode)" begin
    r = run_tests(ORIGINAL_TEST_CASES, "Original 77")
    global total_pass += r.n_pass
    global total_fail += r.n_fail
    global total_error += r.n_error

    println()
    println("Original 77: $(r.n_pass) CORRECT, $(r.n_fail) MISMATCH, $(r.n_error) ERROR")

    # Print failures
    for res in r.results
        if res.status != "CORRECT"
            println("  FAIL: $(res.name) — $(res.status)")
            if res.reason !== nothing
                println("    $(res.reason)")
            else
                println("    Native: $(res.native)")
                println("    Reimpl: $(res.dict)")
            end
        end
    end
end

# Section 2: Novel types NOT in original Dict
@testset "Novel types (user-defined, parametric, Union)" begin
    r = run_tests(NOVEL_TEST_CASES, "Novel types")
    global total_pass += r.n_pass
    global total_fail += r.n_fail
    global total_error += r.n_error

    println()
    println("Novel types: $(r.n_pass) CORRECT, $(r.n_fail) MISMATCH, $(r.n_error) ERROR")

    # Print failures
    for res in r.results
        if res.status != "CORRECT"
            println("  FAIL: $(res.name) — $(res.status)")
            if res.reason !== nothing
                println("    $(res.reason)")
            else
                println("    Native: $(res.native)")
                println("    Reimpl: $(res.dict)")
            end
        end
    end
end

# ─── Final summary ────────────────────────────────────────────────────────────

total = total_pass + total_fail + total_error
println()
println("=" ^ 80)
println("FINAL: $(total_pass)/$(total) CORRECT ($(total_fail) MISMATCH, $(total_error) ERROR)")
if total_pass == total
    println("ALL TESTS CORRECT — Julia reimplementations produce identical typeinf results")
    println("Phase 2d VERIFIED: reimpl works for arbitrary types (not just pre-computed Dict)")
else
    println("SOME TESTS FAILED — see details above")
end
println("=" ^ 80)
