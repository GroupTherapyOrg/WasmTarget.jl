# Test may_optimize=false natively (PURE-6024)
using JuliaSyntax
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))

function test_unoptimized_codeinfo()
    world = Base.get_world_counter()
    sig = Tuple{typeof(Base.:+), Int64, Int64}
    interp = build_wasm_interpreter([sig]; world=world)
    native_mt = Core.Compiler.InternalMethodTable(world)
    lkup = Core.Compiler.findall(sig, native_mt; limit=3)
    mi = Core.Compiler.specialize_method(first(lkup.matches))

    _WASM_USE_REIMPL[] = true
    _WASM_CODE_CACHE[] = interp.code_info_cache
    local inf_frame
    try
        inf_frame = Core.Compiler.typeinf_frame(interp, mi, false)
    finally
        _WASM_USE_REIMPL[] = false
        _WASM_CODE_CACHE[] = nothing
    end

    if inf_frame === nothing
        println("ERROR: typeinf_frame returned nothing with run_optimizer=false")
        return
    end

    ci = inf_frame.result.src
    println("=== UNOPTIMIZED CodeInfo for +(Int64, Int64) ===")
    println(ci)
    println()
    println("=== Statement details ===")
    for (i, stmt) in enumerate(ci.code)
        println("  %$i = $(repr(stmt))")
        println("       type=$(ci.ssavaluetypes[i])")
    end
end

function test_optimized_codeinfo()
    world = Base.get_world_counter()
    sig = Tuple{typeof(Base.:+), Int64, Int64}

    # Use a separate interp with may_optimize=true via Base.code_typed
    ci_opt, rettype = Base.code_typed(Base.:+, (Int64, Int64); optimize=true)[1]
    println("=== OPTIMIZED CodeInfo for +(Int64, Int64) (Base.code_typed) ===")
    println(ci_opt)
    println()
    println("=== Statement details ===")
    for (i, stmt) in enumerate(ci_opt.code)
        println("  %$i = $(repr(stmt))")
        println("       type=$(ci_opt.ssavaluetypes[i])")
    end
end

function test_eval_julia_native()
    println("\n=== Testing eval_julia_native with may_optimize=false ===")
    include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
    for (code, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
        try
            result = eval_julia_native(code)
            status = result == expected ? "CORRECT" : "WRONG (got $result, expected $expected)"
            println("eval_julia_native(\"$code\") = $result — $status")
        catch e
            println("eval_julia_native(\"$code\") = ERROR: $e")
            showerror(stdout, e, catch_backtrace())
            println()
        end
    end
end

println("--- Unoptimized (may_optimize=false) ---")
test_unoptimized_codeinfo()
println()
println("--- Optimized (Base.code_typed) ---")
test_optimized_codeinfo()
println()
test_eval_julia_native()
