# Test may_optimize=false natively (PURE-6024)
using JuliaSyntax
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Testing eval_julia_native with may_optimize=false ===")
for (code, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
    try
        result = Base.invokelatest(eval_julia_native, code)
        status = result == expected ? "CORRECT" : "WRONG (got $result, expected $expected)"
        println("eval_julia_native(\"$code\") = $result — $status")
    catch e
        println("eval_julia_native(\"$code\") = ERROR: $e")
        showerror(stdout, e, catch_backtrace())
        println()
    end
end
