using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))
println("Function: ", f)
println("Methods:")
for m in methods(f)
    println("  ", m.sig)
end

# Compile individually to test validation
println("\nCompiling construct_ssa! individually...")
try
    sig = first(methods(f)).sig
    arg_types = Tuple(sig.parameters[2:end])
    println("Using signature: $arg_types")
    bytes = WasmTarget.compile(f, arg_types)
    tmpf = joinpath(@__DIR__, "..", "output", "construct_ssa.wasm")
    write(tmpf, bytes)
    println("Compiled: $(length(bytes)) bytes → $tmpf")

    # Validate
    validate_cmd = `wasm-tools validate --features=gc,function-references,reference-types,multi-value,bulk-memory,sign-extension,mutable-global,tail-call,exceptions $tmpf`
    result = success(validate_cmd)
    if result
        println("VALIDATES: true")
    else
        println("VALIDATES: false")
        run(ignorestatus(validate_cmd))
    end
catch e
    println("Error: ", e)
    println(sprint(showerror, e, catch_backtrace()))
end
