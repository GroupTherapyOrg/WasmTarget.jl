#!/usr/bin/env julia
# Tier 1 Test Runner — Compile and execute extracted tests via WasmTarget
#
# Usage: julia +1.12 --project=. test/tier1_suite/run.jl
#
# For each verified @test expression:
# 1. Wrap as a zero-arg function returning Int32 (1 for true, 0 for false)
# 2. Try to compile via WasmTarget
# 3. If compilation succeeds, execute in Node.js
# 4. Compare to expected result (1)
# 5. Report COMPILE_FAIL / EXECUTE_FAIL / CORRECT / MISMATCH

using WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))

# Load verified tests
include(joinpath(@__DIR__, "verified_tests.jl"))

# Results tracking
struct TestResult
    file::String
    line::Int
    expr::String
    status::Symbol  # :correct, :mismatch, :execute_fail, :compile_fail, :wrap_fail
    detail::String
end

"""
Counter for unique function names to avoid redefinition.
"""
const _FUNC_COUNTER = Ref(0)

"""
Try to wrap a test expression as a compilable function.
Returns (func, return_type) or nothing.

Strategy: parse the expression, wrap in a function that returns Int32(1) or Int32(0).
"""
function wrap_test(expr_str::String)
    _FUNC_COUNTER[] += 1
    fname = Symbol("_tier1_test_$(_FUNC_COUNTER[])")

    # Create a function that evaluates the expression and returns Int32(1/0)
    func_code = """
    function $fname()::Int32
        return ($expr_str) ? Int32(1) : Int32(0)
    end
    """
    try
        parsed = Meta.parse(func_code)
        f = Core.eval(Main, parsed)
        # Use invokelatest to handle world age
        result = Base.invokelatest(f)
        return (f, result, string(fname))
    catch
        return nothing
    end
end

"""
Try to compile a test function and return the wasm bytes.
"""
function try_compile(f)
    try
        bytes = WasmTarget.compile(f, ())
        return bytes
    catch e
        return string(e)[1:min(120, length(string(e)))]
    end
end

"""
Run the Tier 1 test suite against WasmTarget.
"""
function run_tier1_suite(; max_tests::Int=0, verbose::Bool=false)
    tests = VERIFIED_TESTS
    if max_tests > 0
        tests = tests[1:min(max_tests, length(tests))]
    end

    results = TestResult[]
    compile_ok = 0
    compile_fail = 0
    execute_ok = 0
    execute_fail = 0
    correct = 0
    mismatch = 0
    wrap_fail = 0

    n = length(tests)
    println("=" ^ 70)
    println("Tier 1 Test Suite — WasmTarget Compilation + Execution")
    println("$(n) tests to process")
    println("=" ^ 70)
    println()

    # Category tracking
    file_stats = Dict{String, @NamedTuple{total::Int, compiled::Int, correct::Int}}()

    for (i, t) in enumerate(tests)
        file = t.file
        if !haskey(file_stats, file)
            file_stats[file] = (total=0, compiled=0, correct=0)
        end
        s = file_stats[file]
        file_stats[file] = (total=s.total+1, compiled=s.compiled, correct=s.correct)

        # Step 1: Wrap expression
        wrapped = wrap_test(t.expr)
        if wrapped === nothing
            wrap_fail += 1
            push!(results, TestResult(t.file, t.line, t.expr, :wrap_fail, ""))
            if verbose
                println("  [$i/$n] WRAP_FAIL: $(t.file):$(t.line) $(t.expr[1:min(50,length(t.expr))])")
            end
            continue
        end

        func, native_result, fname = wrapped

        # Step 2: Compile
        wasm = try_compile(func)
        if wasm isa String
            compile_fail += 1
            push!(results, TestResult(t.file, t.line, t.expr, :compile_fail, wasm))
            if verbose
                println("  [$i/$n] COMPILE_FAIL: $(t.file):$(t.line) $(wasm[1:min(60,length(wasm))])")
            end
            continue
        end

        compile_ok += 1
        s = file_stats[file]
        file_stats[file] = (total=s.total, compiled=s.compiled+1, correct=s.correct)

        # Step 3: Execute in Node.js
        try
            actual = run_wasm(wasm, fname)
            if actual === nothing
                execute_fail += 1
                push!(results, TestResult(t.file, t.line, t.expr, :execute_fail, "Node.js unavailable"))
                continue
            end

            # Step 4: Compare
            expected = native_result  # Should be Int32(1) for passing tests
            if actual == expected
                correct += 1
                s = file_stats[file]
                file_stats[file] = (total=s.total, compiled=s.compiled, correct=s.correct+1)
                push!(results, TestResult(t.file, t.line, t.expr, :correct, ""))
                if verbose
                    println("  [$i/$n] CORRECT: $(t.file):$(t.line)")
                end
            else
                mismatch += 1
                push!(results, TestResult(t.file, t.line, t.expr, :mismatch, "expected=$expected actual=$actual"))
                println("  [$i/$n] MISMATCH: $(t.file):$(t.line) $(t.expr[1:min(50,length(t.expr))]) expected=$expected got=$actual")
            end
        catch e
            execute_fail += 1
            msg = string(e)[1:min(80, length(string(e)))]
            push!(results, TestResult(t.file, t.line, t.expr, :execute_fail, msg))
            if verbose
                println("  [$i/$n] EXECUTE_FAIL: $(t.file):$(t.line) $msg")
            end
        end

        # Progress every 50 tests
        if i % 50 == 0
            println("  Progress: $i/$n (compile: $compile_ok ok, $compile_fail fail; exec: $correct correct, $mismatch mismatch, $execute_fail fail)")
        end
    end

    # Summary
    println()
    println("=" ^ 70)
    println("RESULTS")
    println("=" ^ 70)
    println()
    println("Total tests:      $n")
    println("Wrap failures:    $wrap_fail")
    println("Compile failures: $compile_fail")
    println("Compile success:  $compile_ok")
    println("Execute failures: $execute_fail")
    println("Correct:          $correct")
    println("Mismatch:         $mismatch")
    println()

    total_attempted = n - wrap_fail
    if total_attempted > 0
        println("Compile rate: $(round(100*compile_ok/total_attempted, digits=1))%")
    end
    if compile_ok > 0
        println("Execute rate: $(round(100*(correct+mismatch)/compile_ok, digits=1))%")
        println("Correct rate (of compiled): $(round(100*correct/compile_ok, digits=1))%")
    end
    if total_attempted > 0
        println("Overall correct: $(round(100*correct/total_attempted, digits=1))%")
    end

    # Per-file breakdown
    println()
    println("Per-file breakdown:")
    println("-" ^ 60)
    for (file, stats) in sort(collect(file_stats))
        rate = stats.total > 0 ? round(100*stats.correct/stats.total, digits=0) : 0
        comp_rate = stats.total > 0 ? round(100*stats.compiled/stats.total, digits=0) : 0
        println("  $(rpad(file, 25)) $(stats.correct)/$(stats.total) correct ($(rate)%), $(stats.compiled) compiled ($(comp_rate)%)")
    end

    # Compile failure categorization
    compile_errors = Dict{String,Int}()
    for r in results
        if r.status == :compile_fail
            # Extract first meaningful error token
            key = if occursin("Unsupported", r.detail)
                m = match(r"Unsupported [^:]+: (.+?)(?:\s|$)", r.detail)
                m !== nothing ? "Unsupported: $(m.captures[1])" : "Unsupported (other)"
            elseif occursin("not yet", r.detail)
                "Not yet implemented"
            elseif occursin("MethodError", r.detail)
                "MethodError"
            elseif occursin("type", lowercase(r.detail))
                "Type error"
            else
                tok = split(r.detail, r"[\n\r]")[1]
                length(tok) > 60 ? tok[1:60] : tok
            end
            compile_errors[key] = get(compile_errors, key, 0) + 1
        end
    end

    if !isempty(compile_errors)
        println()
        println("Compile failure categories:")
        println("-" ^ 60)
        for (reason, count) in sort(collect(compile_errors), by=x->-x[2])[1:min(15, length(compile_errors))]
            println("  $(rpad(reason, 50)) $count")
        end
    end

    # Write results to JSON
    results_path = joinpath(@__DIR__, "results.json")
    open(results_path, "w") do io
        println(io, "{")
        println(io, "  \"total\": $n,")
        println(io, "  \"wrap_fail\": $wrap_fail,")
        println(io, "  \"compile_fail\": $compile_fail,")
        println(io, "  \"compile_ok\": $compile_ok,")
        println(io, "  \"execute_fail\": $execute_fail,")
        println(io, "  \"correct\": $correct,")
        println(io, "  \"mismatch\": $mismatch,")
        println(io, "  \"files\": {")
        files = sort(collect(file_stats))
        for (i, (file, stats)) in enumerate(files)
            comma = i < length(files) ? "," : ""
            println(io, "    \"$file\": {\"total\": $(stats.total), \"compiled\": $(stats.compiled), \"correct\": $(stats.correct)}$comma")
        end
        println(io, "  }")
        println(io, "}")
    end
    println()
    println("Results written to $results_path")

    return results
end

# Run with all tests
results = run_tier1_suite(verbose=false)
