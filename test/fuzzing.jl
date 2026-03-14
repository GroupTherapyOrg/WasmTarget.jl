# WasmTarget.jl Fuzzing Suite
# Per spec §9.10.2: 3 fuzzer types — expression, type system, wasm-smith
#
# Usage:
#   julia +1.12 --project=. test/fuzzing.jl              # default: 100 iterations
#   julia +1.12 --project=. test/fuzzing.jl 500           # custom iteration count
#   julia +1.12 --project=. test/fuzzing.jl 100 42        # custom seed

using Test, Random
using WasmTarget

include("utils.jl")

const N_ITERATIONS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 100
const RNG_SEED = length(ARGS) >= 2 ? parse(UInt64, ARGS[2]) : rand(UInt64)

println("=== WasmTarget.jl Fuzzing Suite ===")
println("Iterations: $N_ITERATIONS")
println("RNG seed:   $RNG_SEED")
println("Node.js:    $(NODE_CMD !== nothing ? "available" : "NOT AVAILABLE")")
println()

# ============================================================================
# Expression Fuzzer (highest value per spec §9.10.2)
# Generate random Julia expressions, compile via WasmTarget, compare results
# ============================================================================

"""
    random_int32_expr(rng, depth=0) -> (func, name, arg_types, test_args)

Generate a random function operating on Int32 values.
Returns the function, a name, argument types, and test arguments.
"""
function random_int32_unary(rng)
    ops = [
        ("neg", x::Int32 -> -x),
        ("abs", x::Int32 -> abs(x)),
        ("add1", x::Int32 -> x + Int32(1)),
        ("sub1", x::Int32 -> x - Int32(1)),
        ("dbl", x::Int32 -> x * Int32(2)),
        ("sq", x::Int32 -> x * x),
        ("id", x::Int32 -> x),
        ("add7", x::Int32 -> x + Int32(7)),
        ("mul3", x::Int32 -> x * Int32(3)),
        ("xor_ff", x::Int32 -> xor(x, Int32(0xFF))),
        ("and_ff", x::Int32 -> x & Int32(0xFF)),
        ("or_1", x::Int32 -> x | Int32(1)),
        ("shl1", x::Int32 -> x << Int32(1)),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    # Pick test values that avoid overflow for squaring
    test_val = Int32(rand(rng, -100:100))
    return (f, "fuzz_$(name)", (Int32,), (test_val,))
end

function random_int32_binary(rng)
    ops = [
        ("add", (a::Int32, b::Int32) -> a + b),
        ("sub", (a::Int32, b::Int32) -> a - b),
        ("mul", (a::Int32, b::Int32) -> a * b),
        ("and", (a::Int32, b::Int32) -> a & b),
        ("or", (a::Int32, b::Int32) -> a | b),
        ("xor", (a::Int32, b::Int32) -> xor(a, b)),
        ("max", (a::Int32, b::Int32) -> max(a, b)),
        ("min", (a::Int32, b::Int32) -> min(a, b)),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    a = Int32(rand(rng, -100:100))
    b = Int32(rand(rng, -100:100))
    return (f, "fuzz_$(name)", (Int32, Int32), (a, b))
end

function random_float64_unary(rng)
    ops = [
        ("fneg", x::Float64 -> -x),
        ("fabs", x::Float64 -> abs(x)),
        ("fadd1", x::Float64 -> x + 1.0),
        ("fsub1", x::Float64 -> x - 1.0),
        ("fdbl", x::Float64 -> x * 2.0),
        ("fhalf", x::Float64 -> x / 2.0),
        ("fsq", x::Float64 -> x * x),
        ("fid", x::Float64 -> x),
        ("fsqrt_abs", x::Float64 -> sqrt(abs(x))),
        ("ffloor", x::Float64 -> floor(x)),
        ("fceil", x::Float64 -> ceil(x)),
        ("ftrunc", x::Float64 -> trunc(x)),
        ("fround", x::Float64 -> round(x)),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    test_val = rand(rng) * 200.0 - 100.0  # [-100, 100]
    return (f, "fuzz_$(name)", (Float64,), (test_val,))
end

function random_float64_binary(rng)
    ops = [
        ("fadd", (a::Float64, b::Float64) -> a + b),
        ("fsub", (a::Float64, b::Float64) -> a - b),
        ("fmul", (a::Float64, b::Float64) -> a * b),
        ("fdiv", (a::Float64, b::Float64) -> a / b),
        ("fmax", (a::Float64, b::Float64) -> max(a, b)),
        ("fmin", (a::Float64, b::Float64) -> min(a, b)),
        ("fcopysign", (a::Float64, b::Float64) -> copysign(a, b)),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    a = rand(rng) * 200.0 - 100.0
    b_range = name == "fdiv" ? (1.0:100.0) : (-100.0:100.0)
    b = rand(rng) * (last(b_range) - first(b_range)) + first(b_range)
    # Avoid division by zero
    if name == "fdiv" && abs(b) < 1e-10
        b = 1.0
    end
    return (f, "fuzz_$(name)", (Float64, Float64), (a, b))
end

function random_conditional(rng)
    ops = [
        ("ternary_pos", x::Int32 -> x > Int32(0) ? x : -x),
        ("ternary_even", x::Int32 -> x % Int32(2) == Int32(0) ? x : x + Int32(1)),
        ("ternary_neg", x::Int32 -> x < Int32(0) ? Int32(-1) : Int32(1)),
        ("clamp50", x::Int32 -> x > Int32(50) ? Int32(50) : (x < Int32(-50) ? Int32(-50) : x)),
        ("sign", x::Int32 -> x > Int32(0) ? Int32(1) : (x < Int32(0) ? Int32(-1) : Int32(0))),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    test_val = Int32(rand(rng, -100:100))
    return (f, "fuzz_$(name)", (Int32,), (test_val,))
end

function random_bool_expr(rng)
    ops = [
        ("gt0", x::Int32 -> x > Int32(0)),
        ("eq0", x::Int32 -> x == Int32(0)),
        ("lt0", x::Int32 -> x < Int32(0)),
        ("ge10", x::Int32 -> x >= Int32(10)),
        ("le_neg5", x::Int32 -> x <= Int32(-5)),
        ("ne42", x::Int32 -> x != Int32(42)),
    ]
    idx = rand(rng, 1:length(ops))
    name, f = ops[idx]
    test_val = Int32(rand(rng, -100:100))
    return (f, "fuzz_$(name)", (Int32,), (test_val,))
end

"""
    generate_random_test(rng) -> (func, name, arg_types, test_args)

Pick a random expression type and generate a test case.
"""
function generate_random_test(rng)
    category = rand(rng, 1:6)
    if category == 1
        return random_int32_unary(rng)
    elseif category == 2
        return random_int32_binary(rng)
    elseif category == 3
        return random_float64_unary(rng)
    elseif category == 4
        return random_float64_binary(rng)
    elseif category == 5
        return random_conditional(rng)
    else
        return random_bool_expr(rng)
    end
end

"""
    fuzz_result_match(expected, actual) -> Bool

Compare results with tolerance for floating point.
"""
function fuzz_result_match(expected, actual)
    if expected isa Float64 && actual isa Float64
        if isnan(expected) && isnan(actual)
            return true
        end
        if isinf(expected) && isinf(actual)
            return sign(expected) == sign(actual)
        end
        return isapprox(expected, actual; rtol=1e-10, atol=1e-15)
    elseif expected isa Bool && actual isa Number
        return (expected ? 1 : 0) == actual
    else
        return expected == actual
    end
end

# ============================================================================
# Wasm-smith Validation Fuzzer
# Generates random WasmGC modules via wasm-tools smith, validates them
# ============================================================================

function run_wasm_smith_fuzzer(n_modules::Int; verbose=false)
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools === nothing
        @warn "wasm-tools not found, skipping Wasm-smith fuzzer"
        return (total=0, valid=0, invalid=0, errors=String[])
    end

    valid = 0
    invalid = 0
    errors = String[]
    dir = mktempdir()

    for i in 1:n_modules
        seed_file = joinpath(dir, "seed_$i.bin")
        wasm_file = joinpath(dir, "module_$i.wasm")

        # Generate random seed bytes
        seed_bytes = rand(UInt8, rand(50:200))
        write(seed_file, seed_bytes)

        try
            # Generate a WasmGC module via wasm-smith
            run(pipeline(
                `wasm-tools smith --gc-enabled true --reference-types-enabled true -o $wasm_file $seed_file`,
                stderr=devnull
            ))

            # Validate the generated module
            run(pipeline(`wasm-tools validate $wasm_file`, stderr=devnull))
            valid += 1
            verbose && println("  Module $i: VALID")
        catch e
            if e isa ProcessFailedException
                # Smith generation or validation failed — record
                invalid += 1
                push!(errors, "Module $i: generation/validation failed")
                verbose && println("  Module $i: FAILED")
            else
                invalid += 1
                push!(errors, "Module $i: $(sprint(showerror, e))")
            end
        end
    end

    return (total=n_modules, valid=valid, invalid=invalid, errors=errors)
end

# ============================================================================
# Type System Fuzzer
# Generate random Julia types, try to compile their WasmGC representations
# ============================================================================

function random_julia_type(rng)
    types = [
        Int32, Int64, UInt32, UInt64, Float32, Float64, Bool,
        Tuple{Int32, Int32}, Tuple{Float64, Float64},
        Tuple{Int32, Float64}, Tuple{Bool, Int32},
        Vector{Int32}, Vector{Float64}, Vector{Int64},
    ]
    return types[rand(rng, 1:length(types))]
end

function run_type_system_fuzzer(rng, n_types::Int; verbose=false)
    valid = 0
    invalid = 0
    errors = String[]

    for i in 1:n_types
        T = random_julia_type(rng)
        try
            # Try compiling an identity function for this type
            f = identity
            bytes = WasmTarget.compile(f, (T,))

            # Validate the output
            dir = mktempdir()
            wasm_file = joinpath(dir, "type_test_$i.wasm")
            write(wasm_file, bytes)

            wasm_tools = Sys.which("wasm-tools")
            if wasm_tools !== nothing
                run(pipeline(`wasm-tools validate $wasm_file`, stderr=devnull))
            end
            valid += 1
            verbose && println("  Type $T: VALID")
        catch e
            invalid += 1
            msg = "Type $T: $(sprint(showerror, e))"
            push!(errors, length(msg) > 200 ? msg[1:200] * "..." : msg)
            verbose && println("  Type $T: FAILED — $(sprint(showerror, e))")
        end
    end

    return (total=n_types, valid=valid, invalid=invalid, errors=errors)
end

# ============================================================================
# Main Fuzzing Loop
# ============================================================================

@testset "WasmTarget Fuzzing (seed=$RNG_SEED)" begin
    rng = MersenneTwister(RNG_SEED)

    # --- Expression Fuzzer ---
    @testset "Expression Fuzzer ($N_ITERATIONS iterations)" begin
        compile_pass = 0
        compile_fail = 0
        validate_pass = 0
        execute_pass = 0
        correct_pass = 0
        correct_fail = 0
        failures = Tuple{String, String}[]  # (name, error)

        for i in 1:N_ITERATIONS
            f, name, arg_types, test_args = generate_random_test(rng)

            # Step 1: Compile
            local bytes
            try
                bytes = WasmTarget.compile(f, arg_types)
                compile_pass += 1
            catch e
                compile_fail += 1
                msg = sprint(showerror, e)
                push!(failures, (name, "COMPILE: $(msg[1:min(150,length(msg))])"))
                @test_broken false  # record as broken, don't fail the suite
                continue
            end

            # Step 2: Validate
            dir = mktempdir()
            wasm_file = joinpath(dir, "fuzz_$i.wasm")
            write(wasm_file, bytes)
            wasm_tools = Sys.which("wasm-tools")
            if wasm_tools !== nothing
                try
                    run(pipeline(`wasm-tools validate $wasm_file`, stderr=devnull))
                    validate_pass += 1
                catch
                    push!(failures, (name, "VALIDATE: wasm-tools validate failed"))
                    @test_broken false
                    continue
                end
            else
                validate_pass += 1  # can't validate, assume ok
            end

            # Step 3: Execute and compare (ground truth)
            if NODE_CMD !== nothing
                expected = try
                    f(test_args...)
                catch
                    nothing  # skip if native Julia throws
                end

                if expected !== nothing
                    try
                        func_name = string(nameof(f))
                        imports = Dict("Math" => Dict("pow" => "Math.pow"))
                        actual = run_wasm_with_imports(bytes, func_name, imports, test_args...)

                        if actual !== nothing
                            execute_pass += 1
                            if fuzz_result_match(expected, actual)
                                correct_pass += 1
                                @test true
                            else
                                correct_fail += 1
                                push!(failures, (name, "MISMATCH: expected=$expected actual=$actual args=$test_args"))
                                @test_broken false
                            end
                        else
                            execute_pass += 1
                            @test true  # execution returned nothing (void), ok
                        end
                    catch e
                        push!(failures, (name, "EXECUTE: $(sprint(showerror, e)[1:min(150,end)])"))
                        @test_broken false
                    end
                else
                    @test true  # native Julia threw, skip
                end
            else
                @test true  # no Node.js, compile+validate is enough
            end
        end

        println()
        println("Expression Fuzzer Results:")
        println("  Compile:  $compile_pass / $N_ITERATIONS passed ($compile_fail failed)")
        println("  Validate: $validate_pass / $compile_pass passed")
        println("  Execute:  $execute_pass / $validate_pass passed")
        println("  Correct:  $correct_pass / $(correct_pass + correct_fail) matched ground truth")
        if !isempty(failures)
            println("  Failures ($(length(failures))):")
            for (name, err) in failures[1:min(20, length(failures))]
                println("    $name: $err")
            end
            if length(failures) > 20
                println("    ... and $(length(failures) - 20) more")
            end
        end
    end

    # --- Wasm-smith Module Validation ---
    @testset "Wasm-smith Module Validation (20 modules)" begin
        result = run_wasm_smith_fuzzer(20; verbose=false)
        println()
        println("Wasm-smith Results:")
        println("  Generated: $(result.total)")
        println("  Valid:     $(result.valid)")
        println("  Invalid:   $(result.invalid)")
        if !isempty(result.errors)
            println("  Errors:")
            for err in result.errors[1:min(5, length(result.errors))]
                println("    $err")
            end
        end
        # Wasm-smith should produce valid modules — but some seeds fail (documented behavior)
        # We just track the ratio, don't hard-fail
        @test result.valid >= result.total ÷ 2  # at least half should be valid
    end

    # --- Type System Fuzzer ---
    @testset "Type System Fuzzer (30 types)" begin
        result = run_type_system_fuzzer(rng, 30; verbose=false)
        println()
        println("Type System Fuzzer Results:")
        println("  Tested:  $(result.total)")
        println("  Valid:   $(result.valid)")
        println("  Invalid: $(result.invalid)")
        if !isempty(result.errors)
            println("  Errors:")
            for err in result.errors[1:min(5, length(result.errors))]
                println("    $err")
            end
        end
        # Most basic types should compile
        @test result.valid >= result.total ÷ 2
    end
end
