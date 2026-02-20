#!/usr/bin/env julia
# diag_be_wat.jl — Extract WAT for builtin_effects func 15 around i64_mul error

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

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

function analyze_func(bytes, func_num)
    tmpf2 = tempname() * ".wasm"
    write(tmpf2, bytes)
    wat = String(read(`wasm-tools print $tmpf2`, String))
    lines = split(wat, '\n')
    println("WAT has $(length(lines)) lines")

    # Find func N
    func_count = 0
    func_start = nothing
    func_end = nothing
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func ")
            func_count += 1
            if func_count == func_num
                func_start = i
            end
        end
        if func_start !== nothing && i > func_start && func_end === nothing
            # Count parens to find end
            # Just scan until we find a line starting with "(func " again at same depth
        end
    end

    # Simpler: find next func after func_start
    if func_start !== nothing
        for i in (func_start+1):length(lines)
            if startswith(strip(lines[i]), "(func ")
                func_end = i - 1
                break
            end
        end
        if func_end === nothing
            func_end = length(lines)
        end
    end

    println("func $func_num spans lines $func_start to $func_end ($(func_end - func_start + 1) lines)")

    if func_start !== nothing
        # Show first 50 lines (locals + start of function)
        println("\n=== LOCALS / HEAD of func $func_num ===")
        for i in func_start:min(func_start+49, func_end)
            println("$i: $(lines[i])")
        end

        # Find i64.mul
        println("\n=== i64.mul in func $func_num ===")
        mul_found = false
        for i in func_start:func_end
            if contains(lines[i], "i64.mul")
                mul_found = true
                println("Found i64.mul at line $i")
                println("Context (±12 lines):")
                for j in max(func_start, i-12):min(func_end, i+5)
                    mark = j == i ? ">>>" : "   "
                    println("$mark $j: $(lines[j])")
                end
                println()
            end
        end
        if !mul_found
            println("  (none found)")
        end
    end
end

println("\nAnalyzing func 15...")
analyze_func(bytes, 15)
