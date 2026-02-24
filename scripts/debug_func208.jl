#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

# Find adjust_macro_name!
sym = Symbol("adjust_macro_name!")
f = getfield(JuliaSyntax, sym)
println("Function: ", f)
println("Type: ", typeof(f))

for method in methods(f)
    println("  ", method)
    println("    sig: ", method.sig)
end

# Try to compile it individually
println("\nAttempting individual compilation...")
for method in methods(f)
    sig = method.sig
    if sig <: Tuple
        arg_types = Tuple{fieldtypes(sig)...}
        println("Compiling: $f with $arg_types")
        try
            bytes = WasmTarget.compile(f, Tuple(fieldtypes(sig)[2:end]))
            println("  COMPILE SUCCESS: $(length(bytes)) bytes")
            tmpf = tempname() * ".wasm"
            write(tmpf, bytes)
            result = run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=stderr, stdout=devnull), wait=false)
            wait(result)
            if result.exitcode == 0
                println("  VALIDATES")
            else
                println("  VALIDATE_ERROR")
            end
            rm(tmpf, force=true)
        catch e
            println("  ERROR: ", e)
        end
    end
end
