# PHASE-1-T02: Generate golden files for 20 representative functions
#
# For each function:
#   1. CodeInfo JSON (via serialize_ir_entries)
#   2. Expected WASM bytes (via compile)
#   3. Expected result for given test inputs
#
# Run: julia +1.12 --project=. test/golden/generate.jl

using WasmTarget
import JSON
import SHA

const GOLDEN_DIR = @__DIR__

# ============================================================================
# 20 representative functions across categories
# ============================================================================

# Category 1: Basic arithmetic (4 functions)
golden_add(x::Int64, y::Int64) = x + y
golden_sub(x::Int64, y::Int64) = x - y
golden_mul(x::Int64, y::Int64) = x * y
golden_neg(x::Int64) = -x

# Category 2: Conditionals (3 functions)
golden_max(x::Int64, y::Int64) = x > y ? x : y
golden_min(x::Int64, y::Int64) = x < y ? x : y
golden_abs(x::Int64) = x < Int64(0) ? -x : x

# Category 3: Multi-operation (3 functions)
golden_poly2(x::Int64) = x * x + Int64(2) * x + Int64(1)
golden_poly3(x::Int64) = x * x * x - Int64(3) * x + Int64(2)
golden_clamp(x::Int64) = x < Int64(0) ? Int64(0) : (x > Int64(100) ? Int64(100) : x)

# Category 4: While loops (3 functions)
function golden_sum_to(n::Int64)::Int64
    s = Int64(0); i = Int64(1)
    while i <= n; s += i; i += Int64(1); end
    return s
end

function golden_count_down(n::Int64)::Int64
    s = Int64(0)
    while n > Int64(0); s += n; n -= Int64(1); end
    return s
end

function golden_power(base::Int64, exp::Int64)::Int64
    result = Int64(1)
    while exp > Int64(0); result *= base; exp -= Int64(1); end
    return result
end

# Category 5: Float operations (4 functions)
golden_fadd(x::Float64, y::Float64) = x + y
golden_fmul(x::Float64, y::Float64) = x * y
golden_circle_area(r::Float64) = 3.14159265358979 * r * r
golden_fahrenheit(c::Float64) = c * 1.8 + 32.0

# Category 6: Complex branching (3 functions)
function golden_classify(x::Int64)::Int64
    if x > Int64(100)
        return Int64(3)
    elseif x > Int64(0)
        return Int64(2)
    elseif x == Int64(0)
        return Int64(1)
    else
        return Int64(0)
    end
end

function golden_branch_compute(x::Int64)::Int64
    if x > Int64(10)
        a = x * Int64(2)
    else
        a = x + Int64(5)
    end
    if a > Int64(20)
        return a - Int64(10)
    else
        return a
    end
end

function golden_sign(x::Int64)::Int64
    return x > Int64(0) ? Int64(1) : (x < Int64(0) ? Int64(-1) : Int64(0))
end

# ============================================================================
# Test inputs for each function
# ============================================================================

const GOLDEN_FUNCTIONS = [
    # (name, func, arg_types, test_inputs_list)
    ("golden_add", golden_add, (Int64, Int64), [(3, 4), (0, 0), (-1, 1), (100, 200)]),
    ("golden_sub", golden_sub, (Int64, Int64), [(10, 3), (0, 5), (-1, -1), (100, 200)]),
    ("golden_mul", golden_mul, (Int64, Int64), [(6, 7), (0, 99), (-3, 4), (100, 100)]),
    ("golden_neg", golden_neg, (Int64,), [(42,), (0,), (-99,)]),
    ("golden_max", golden_max, (Int64, Int64), [(10, 20), (20, 10), (-5, -3), (0, 0)]),
    ("golden_min", golden_min, (Int64, Int64), [(10, 20), (20, 10), (-5, -3), (0, 0)]),
    ("golden_abs", golden_abs, (Int64,), [(-42,), (42,), (0,)]),
    ("golden_poly2", golden_poly2, (Int64,), [(0,), (1,), (5,), (10,)]),
    ("golden_poly3", golden_poly3, (Int64,), [(0,), (1,), (3,), (-2,)]),
    ("golden_clamp", golden_clamp, (Int64,), [(-5,), (0,), (50,), (150,)]),
    ("golden_sum_to", golden_sum_to, (Int64,), [(10,), (100,), (0,), (1,)]),
    ("golden_count_down", golden_count_down, (Int64,), [(10,), (5,), (0,)]),
    ("golden_power", golden_power, (Int64, Int64), [(2, 10), (3, 5), (5, 0), (1, 100)]),
    ("golden_fadd", golden_fadd, (Float64, Float64), [(1.5, 2.5), (0.0, 0.0), (-1.0, 1.0)]),
    ("golden_fmul", golden_fmul, (Float64, Float64), [(3.0, 4.0), (0.5, 2.0), (-1.0, 3.0)]),
    ("golden_circle_area", golden_circle_area, (Float64,), [(1.0,), (2.0,), (0.0,)]),
    ("golden_fahrenheit", golden_fahrenheit, (Float64,), [(0.0,), (100.0,), (-40.0,)]),
    ("golden_classify", golden_classify, (Int64,), [(200,), (50,), (0,), (-10,)]),
    ("golden_branch_compute", golden_branch_compute, (Int64,), [(5,), (15,), (25,)]),
    ("golden_sign", golden_sign, (Int64,), [(42,), (-7,), (0,)]),
]

# ============================================================================
# Generate golden files
# ============================================================================

println("Generating $(length(GOLDEN_FUNCTIONS)) golden files...")

for (name, f, arg_types, test_inputs_list) in GOLDEN_FUNCTIONS
    # Get CodeInfo and serialize
    ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
    entries = [(ci, rt, arg_types, name)]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)
    codeinfo_json = WasmTarget.serialize_ir_entries(preprocessed)

    # Compile to WASM
    wasm_bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(preprocessed))

    # Compute expected results
    expected_results = []
    for args in test_inputs_list
        result = f(args...)
        push!(expected_results, Dict("args" => collect(args), "expected" => result))
    end

    # Create golden file
    golden = Dict(
        "name" => name,
        "arg_types" => [WasmTarget.serialize_type_name(T) for T in arg_types],
        "return_type" => WasmTarget.serialize_type_name(rt),
        "codeinfo" => JSON.parse(codeinfo_json),
        "wasm_size" => length(wasm_bytes),
        "wasm_sha256" => bytes2hex(SHA.sha256(wasm_bytes)),
        "test_cases" => expected_results,
    )

    filepath = joinpath(GOLDEN_DIR, "$name.json")
    open(filepath, "w") do io
        JSON.print(io, golden, 2)
    end
    println("  ✓ $name ($(length(wasm_bytes)) bytes, $(length(test_inputs_list)) test cases)")
end

println("Done. $(length(GOLDEN_FUNCTIONS)) golden files written to $GOLDEN_DIR")
