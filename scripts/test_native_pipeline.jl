using WasmTarget
using JuliaSyntax

# Load typeinf infrastructure and eval_julia from WasmTarget.jl project root
const PROJ_ROOT = dirname(dirname(@__FILE__))
include(joinpath(PROJ_ROOT, "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(PROJ_ROOT, "src", "eval_julia.jl"))

function run_tests()
    println("=== Testing eval_julia_native with may_optimize=false ===")
    test_cases = [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
    pass_count = 0
    for (expr, expected) in test_cases
        try
            result = eval_julia_native(expr)
            ok = result == expected
            if ok
                pass_count += 1
            end
            status = ok ? "CORRECT" : "MISMATCH"
            println("  eval_julia_native(\"$expr\") = $result (expected $expected) -- $status")
        catch e
            println("  eval_julia_native(\"$expr\") FAILED: $(sprint(showerror, e))")
        end
    end
    println("\n=== Result: $pass_count/$(length(test_cases)) CORRECT ===")
end

run_tests()
