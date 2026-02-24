#!/usr/bin/env julia
# diag_compact.jl — Diagnose compact! and non_dce_finish! VALIDATE_ERRs
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

println("=== Diagnose VALIDATE_ERRs in critical path ===")
flush(stdout)

function test_and_report(name, func, argtypes)
    println("\n--- $name ---")
    flush(stdout)
    bytes = try
        compile(func, argtypes)
    catch ex
        println("  COMPILE_ERROR: $(sprint(showerror, ex)[1:min(300,end)])")
        return :COMPILE_ERROR
    end
    println("  Compiled: $(length(bytes)) bytes")
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    if ok
        println("  VALIDATES ✓")
        return :VALIDATES
    end

    err_msg = String(take!(errbuf))
    println("  VALIDATE_ERROR:")
    for line in split(err_msg, '\n')[1:min(5,end)]
        println("    $line")
    end

    # Get WAT and save
    wat = try
        read(`wasm-tools print $tmpf`, String)
    catch
        ""
    end
    if !isempty(wat)
        wat_file = replace(tmpf, ".wasm" => ".wat")
        write(wat_file, wat)
        println("  WAT: $wat_file ($(count('\n', wat)) lines)")
    end
    flush(stdout)
    return :VALIDATE_ERROR
end

# Test the 4 known failures
test_and_report("compact!(IRCode, Bool)", Compiler.compact!, (Compiler.IRCode, Bool))
test_and_report("non_dce_finish!(IncrementalCompact)", Compiler.non_dce_finish!, (Compiler.IncrementalCompact,))
test_and_report("builtin_effects(InferenceLattice,...)", Compiler.builtin_effects,
    (Compiler.InferenceLattice{Compiler.ConditionalsLattice{Compiler.PartialsLattice{Compiler.ConstsLattice}}}, Core.Builtin, Vector{Any}, Any))
test_and_report("builtin_effects(PartialsLattice,...)", Compiler.builtin_effects,
    (Compiler.PartialsLattice{Compiler.ConstsLattice}, Core.Builtin, Vector{Any}, Any))

println("\nDone.")
