# PURE-3003 + PURE-3110: DictMethodTable native Julia verification
#
# Tests that DictMethodTable typeinf produces the SAME CodeInfo as standard typeinf
# for 77 representative (f, argtypes) pairs covering all playground operations.
#
# PURE-3003: Original 67 test functions
# PURE-3110: 10 NEW test functions (string concat, Dict, Array comprehension, etc.)
#
# Usage:
#   julia +1.12 --project=WasmTarget.jl -e 'include("WasmTarget.jl/src/typeinf/dict_method_table.jl"); include("WasmTarget.jl/test/test_dict_typeinf.jl")'

using Test

# ─── User-defined types for testing ──────────────────────────────────────────

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

# ─── Simple functions for control flow testing ───────────────────────────────

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

# ─── NEW Phase D verification functions (PURE-3110) ─────────────────────────

# String concatenation
function my_string_concat(a::String, b::String)
    return a * b
end

# Dict construction and lookup
function my_dict_get(d::Dict{String, Int64}, key::String)
    return get(d, key, 0)
end

# Array comprehension result type
function my_squares(n::Int64)
    return [i^2 for i in 1:n]
end

# Tuple construction
function my_make_tuple(a::Int64, b::Float64)
    return (a, b)
end

# Multiple dispatch — two methods, same name
my_double(x::Int64) = 2x
my_double(x::Float64) = 2.0 * x

# Higher-order function: map
function my_map_inc(v::Vector{Int64})
    return map(x -> x + 1, v)
end

# String repeat
function my_repeat_str(s::String, n::Int64)
    return repeat(s, n)
end

# Convert between numeric types
function my_convert_float(x::Int64)
    return convert(Float64, x)
end

# Pair construction
function my_make_pair(a::Int64, b::String)
    return Pair(a, b)
end

# push! on vector (mutating)
function my_push_vec(v::Vector{Int64}, x::Int64)
    push!(v, x)
    return length(v)
end

# ─── Test runner ─────────────────────────────────────────────────────────────

const TEST_CASES = [
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

    # ── NEW: Phase D verification (PURE-3110) ──
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

println("=" ^ 80)
println("PURE-3003: DictMethodTable Native Julia Verification")
println("Testing $(length(TEST_CASES)) function signatures")
println("=" ^ 80)
println()

# Results table
results = []
n_pass = 0
n_fail = 0
n_error = 0

@testset "DictMethodTable vs NativeInterpreter" begin
    for (name, f, argtypes) in TEST_CASES
        result = try
            verify_typeinf(f, argtypes)
        catch e
            (pass=false, reason="ERROR: $(sprint(showerror, e))",
             native_rettype=nothing, dict_rettype=nothing)
        end

        status = if hasproperty(result, :reason)
            global n_error += 1
            "ERROR"
        elseif result.pass
            global n_pass += 1
            "MATCH"
        else
            global n_fail += 1
            "MISMATCH"
        end

        push!(results, (name=name, status=status,
            native=hasproperty(result, :native_rettype) ? result.native_rettype : nothing,
            dict=hasproperty(result, :dict_rettype) ? result.dict_rettype : nothing,
            reason=hasproperty(result, :reason) ? result.reason : nothing))

        @test result.pass == true
    end
end

# ─── Print results table ────────────────────────────────────────────────────

println()
println("=" ^ 100)
println("| # | Function                          | Status   | Native RetType              | Dict RetType                |")
println("|---|-----------------------------------|----------|-----------------------------|-----------------------------|")
for (i, r) in enumerate(results)
    name_pad = rpad(r.name, 35)
    status_pad = rpad(r.status, 8)
    native_str = rpad(string(r.native), 27)
    dict_str = rpad(string(r.dict), 27)
    println("| $(lpad(i, 1)) | $name_pad | $status_pad | $native_str | $dict_str |")
end
println("=" ^ 100)
println()
println("Summary: $n_pass MATCH, $n_fail MISMATCH, $n_error ERROR out of $(length(TEST_CASES)) tests")

# Print failures/errors for debugging
if n_fail + n_error > 0
    println("\n--- Failures/Errors ---")
    for r in results
        if r.status != "MATCH"
            println("  $(r.name): $(r.status)")
            if r.reason !== nothing
                println("    Reason: $(r.reason)")
            else
                println("    Native: $(r.native)")
                println("    Dict:   $(r.dict)")
            end
        end
    end
end
