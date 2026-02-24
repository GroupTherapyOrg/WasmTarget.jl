# try_compile_eval_julia.jl — Try to compile eval_julia_to_bytes to WASM
# Tests whether may_optimize=false eliminated optimization passes from compilation

using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Attempting compile_multi for eval_julia_to_bytes(String) ===")
t0 = time()
try
    bytes = WasmTarget.compile_multi([(eval_julia_to_bytes, (String,))])
    elapsed = round(time() - t0, digits=1)
    println("SUCCESS: $(length(bytes)) bytes in $(elapsed)s")

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    try
        run(`wasm-tools validate $tmpf`)
        println("VALIDATES: wasm-tools validate passed")
    catch e
        println("VALIDATE_ERROR: $e")
        # Get first error
        try
            output = read(`wasm-tools validate $tmpf`, String)
            println("  $output")
        catch e2
            err_output = String(read(pipeline(`wasm-tools validate $tmpf`; stderr=devnull)))
            println("  validation failed")
        end
    end

    # Count functions
    func_count = read(`wasm-tools print $tmpf`, String)
    n_funcs = count("(func", func_count)
    println("Function count: $n_funcs")
    rm(tmpf; force=true)
catch e
    elapsed = round(time() - t0, digits=1)
    println("FAILED after $(elapsed)s: $e")
    println(sprint(showerror, e, catch_backtrace()))
end
