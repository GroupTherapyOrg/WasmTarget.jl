# try_compile_eval_julia3.jl — Compile and save for analysis
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("Compiling...")
t0 = time()
bytes = WasmTarget.compile_multi([(eval_julia_to_bytes, (String,))])
elapsed = round(time() - t0, digits=1)
println("Compiled: $(length(bytes)) bytes in $(elapsed)s")

outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
mkpath(dirname(outf))
write(outf, bytes)
println("Saved to: $outf")

# Validate and show errors
result = try
    err = read(pipeline(`wasm-tools validate $outf`; stderr=`cat`), String)
    println("VALIDATES!")
    true
catch e
    # Run wasm-tools validate and capture stderr
    proc = run(pipeline(`wasm-tools validate $outf`; stdout=devnull, stderr=outf * ".err"); wait=false)
    wait(proc)
    if isfile(outf * ".err")
        err_text = read(outf * ".err", String)
        println("VALIDATE_ERROR:\n$err_text")
        rm(outf * ".err"; force=true)
    else
        println("VALIDATE_ERROR (no stderr captured)")
    end
    false
end
