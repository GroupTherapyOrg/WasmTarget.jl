#!/usr/bin/env julia
# Diagnose the 3 known failing critical path functions
# compact!(IRCode, Bool), builtin_effects (2 variants)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax

const Compiler = Core.Compiler

# Load WasmInterpreter type
include(joinpath(@__DIR__, "..", "src", "typeinf", "dict_method_table.jl"))

# Test functions
test_cases = [
    (Compiler.compact!, (Compiler.IRCode, Bool), "compact!"),
    (Compiler.builtin_effects, (Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Core.Builtin, Vector{Any}, Any), "builtin_effects(InferenceLattice)"),
    (Compiler.builtin_effects, (Compiler.PartialsLattice{Compiler.ConstsLattice}, Core.Builtin, Vector{Any}, Any), "builtin_effects(PartialsLattice)"),
]

tmpdir = mktempdir()

for (func, argtypes, name) in test_cases
    println("\n=== Testing: $name ===")
    flush(stdout)

    bytes = try
        compile(func, argtypes)
    catch ex
        println("COMPILE_ERROR: $(sprint(showerror, ex)[1:min(300,end)])")
        continue
    end

    tmpf = joinpath(tmpdir, "$(name).wasm")
    write(tmpf, bytes)
    println("Compiled: $(length(bytes)) bytes")

    # Validate
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    if ok
        println("VALIDATES ✓")
    else
        err_msg = String(take!(errbuf))
        println("VALIDATE_ERROR:")
        println(err_msg)

        # Get WAT for diagnosis
        watf = joinpath(tmpdir, "$(name).wat")
        try
            Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf, stderr=devnull))
            # Count functions
            wat_content = read(watf, String)
            func_count = count("(func ", wat_content)
            println("Functions in module: $func_count")

            # Extract the failing function's WAT
            # Find error offset to locate the issue
            m = match(r"at offset (0x[0-9a-f]+)", err_msg)
            if m !== nothing
                offset = m.captures[1]
                println("Error offset: $offset")
            end

            # Dump first 100 lines of WAT for inspection
            lines = split(wat_content, '\n')
            println("\n--- First 50 lines of WAT ---")
            for (i, line) in enumerate(lines[1:min(50, length(lines))])
                println("$i: $line")
            end
        catch ex
            println("WAT generation failed: $(sprint(showerror, ex)[1:min(200,end)])")
        end
    end
    flush(stdout)
end

rm(tmpdir; recursive=true, force=true)
println("\nDone.")
