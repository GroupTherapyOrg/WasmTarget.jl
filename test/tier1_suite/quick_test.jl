#!/usr/bin/env julia
# Quick test — run first N verified tests through WasmTarget
# Usage: julia +1.12 --project=. test/tier1_suite/quick_test.jl [N]

using WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))
include(joinpath(@__DIR__, "verified_tests.jl"))

const _FC = Ref(0)

function run_quick(n::Int)
    compile_ok = 0
    compile_fail = 0
    correct = 0
    exec_fail = 0
    wrap_fail = 0
    errors = Dict{String,Int}()

    tests = VERIFIED_TESTS[1:min(n, length(VERIFIED_TESTS))]
    println("Running $(length(tests)) tests...")
    println()

    for (i, t) in enumerate(tests)
        _FC[] += 1
        fname = "_tier1_q$(_FC[])"

        # Wrap
        func_code = "function $fname()::Int32; return ($(t.expr)) ? Int32(1) : Int32(0); end"
        local f
        try
            parsed = Meta.parse(func_code)
            f = Core.eval(Main, parsed)
            Base.invokelatest(f)  # verify in Julia
        catch e
            wrap_fail += 1
            continue
        end

        # Compile
        local bytes
        try
            bytes = WasmTarget.compile(f, ())
        catch e
            compile_fail += 1
            msg = string(e)
            # Categorize
            key = if occursin("Unsupported", msg)
                m2 = match(r"Unsupported (\w+ ?\w*)", msg)
                m2 !== nothing ? m2.match : "Unsupported"
            elseif occursin("not found", msg)
                "Not found"
            elseif occursin("StackOverflowError", msg)
                "StackOverflow"
            else
                split(string(typeof(e)), '.')[end]
            end
            errors[key] = get(errors, key, 0) + 1
            continue
        end
        compile_ok += 1

        # Execute
        try
            actual = run_wasm(bytes, fname)
            if actual == 1
                correct += 1
                if i <= 30
                    println("  ✓ $(t.file):$(t.line) $(t.expr[1:min(60,length(t.expr))])")
                end
            else
                println("  ✗ MISMATCH $(t.file):$(t.line) got=$actual $(t.expr[1:min(50,length(t.expr))])")
            end
        catch e
            exec_fail += 1
            if i <= 30
                msg = string(e)[1:min(60, length(string(e)))]
                println("  ⊘ EXEC_FAIL $(t.file):$(t.line) $msg")
            end
        end

        if i % 100 == 0
            println("  ...progress: $i/$(length(tests)) (compiled=$compile_ok, correct=$correct)")
        end
    end

    println()
    println("=" ^ 60)
    println("Results ($n tests)")
    println("=" ^ 60)
    println("  Wrap fail:     $wrap_fail")
    println("  Compile fail:  $compile_fail")
    println("  Compile ok:    $compile_ok")
    println("  Execute fail:  $exec_fail")
    println("  Correct:       $correct")
    attempted = length(tests) - wrap_fail
    println()
    if attempted > 0
        println("  Compile rate: $(round(100*compile_ok/attempted, digits=1))%")
    end
    if compile_ok > 0
        println("  Correct rate (of compiled): $(round(100*correct/compile_ok, digits=1))%")
    end
    if attempted > 0
        println("  Overall correct: $(round(100*correct/attempted, digits=1))%")
    end

    if !isempty(errors)
        println()
        println("Compile error categories:")
        for (k, v) in sort(collect(errors), by=x->-x[2])
            println("  $(rpad(k, 40)) $v")
        end
    end
end

n = length(ARGS) > 0 ? parse(Int, ARGS[1]) : 50
run_quick(n)
