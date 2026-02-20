#!/usr/bin/env julia
# diag_be_wat2.jl — Find local.set 62 and understand the full context in func 15

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

bl = Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}

println("Compiling builtin_effects...")
bytes = compile(Core.Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
println("Compiled: $(length(bytes)) bytes")

function analyze_local62(bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    wat = String(read(`wasm-tools print $tmpf`, String))
    lines = split(wat, '\n')

    # Find func 15 (0-indexed = (;15;) in WAT)
    func15_start = nothing
    func15_end = nothing
    for (i, line) in enumerate(lines)
        if contains(line, "(func (;15;)")
            func15_start = i
        end
        if func15_start !== nothing && i > func15_start
            if contains(line, "(func (;") && i > func15_start + 1
                func15_end = i - 1
                break
            end
        end
    end
    func15_end = something(func15_end, length(lines))

    println("func 15 spans lines $func15_start to $func15_end")

    # Find all local.set 62 occurrences
    println("\n=== All 'local.set 62' in func 15 ===")
    for i in func15_start:func15_end
        if contains(lines[i], "local.set 62")
            println("  Line $i: $(lines[i])")
            println("  Context before (10 lines):")
            for j in max(func15_start, i-10):i
                mark = j == i ? ">>>" : "   "
                println("  $mark $j: $(lines[j])")
            end
            println()
        end
    end

    # Also show the full func 15 in sections
    println("\n=== Full func 15, lines 100-200 (from func start) ===")
    for i in (func15_start+99):min(func15_start+199, func15_end)
        println("$i: $(lines[i])")
    end

    println("\n=== Full func 15, lines 200-257 (tail) ===")
    for i in (func15_start+199):func15_end
        println("$i: $(lines[i])")
    end
end

analyze_local62(bytes)

# Also show Julia IR for builtin_effects to correlate
println("\n=== Julia IR for builtin_effects ===")
try
    results = code_typed(Core.Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any); optimize=true)
    ci, rt = results[1]
    println("Return type: $rt, stmts: $(length(ci.code))")
    println("Slot types: $(ci.slottypes)")
    for i in 1:min(40, length(ci.code))
        inst = ci.code[i]
        typ = ci.ssavaluetypes[i]
        println("  %$i ::$typ = $inst")
    end
    println("  ... ($(length(ci.code)-40) more stmts)")
catch e
    println("code_typed error: $e")
end
