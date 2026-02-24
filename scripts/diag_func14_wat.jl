#!/usr/bin/env julia
# Extract func 14 from WAT and count locals, show the error area

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler
PL = Compiler.PartialsLattice{Compiler.ConstsLattice}

println("Compiling builtin_effects(PartialsLattice)...")
flush(stdout)
bytes = compile(Compiler.builtin_effects, (PL, Core.Builtin, Vector{Any}, Any))
println("Compiled: $(length(bytes)) bytes")

tmpf = joinpath(tempdir(), "be_wat14.wasm")
write(tmpf, bytes)

watf = joinpath(tempdir(), "be_wat14.wat")
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf, stderr=devnull))
wat = read(watf, String)
lines = split(wat, '\n')

# Find func 14 boundaries
global func_count = 0
func14_start = 0
func14_end = 0
for i in eachindex(lines)
    line = lines[i]
    if occursin("(func ", line) && occursin("(;", line)
        func_count += 1
        if func_count == 14
            func14_start = i
        elseif func_count == 15
            func14_end = i - 1
            break
        end
    end
end

if func14_start > 0
    println("\nFunc 14: lines $func14_start to $func14_end ($(func14_end - func14_start + 1) lines)")
    println("Header: $(strip(lines[func14_start]))")

    # Print locals
    println("\n=== Locals (first 30 lines) ===")
    for i in func14_start:min(func14_start+30, func14_end)
        println("  $(lines[i])")
    end

    # Find and show local 62 type
    println("\n=== Finding local 62 type ===")
    local_count = 1  # Start at 1 because param 0 is the function param
    for i in (func14_start+1):func14_end
        line = strip(lines[i])
        if startswith(line, "(local ")
            # Count locals in this declaration
            # Format: (local i32) or (local $name i32)
            m = match(r"\(local\s+(\S+)\)", line)
            if m !== nothing
                typ = m.captures[1]
                if local_count == 62
                    println("  LOCAL $local_count: $typ  ← THIS IS LOCAL 62")
                elseif local_count >= 58 && local_count <= 66
                    println("  LOCAL $local_count: $typ")
                end
                local_count += 1
            end
        elseif !startswith(line, "(param") && !startswith(line, "(result") && !startswith(line, "(type")
            break  # End of locals section
        end
    end

    # Show lines around the i64.mul error (WAT line ~11253)
    println("\n=== Lines around i64.mul ===")
    for i in func14_start:func14_end
        if occursin("i64.mul", lines[i])
            start_ctx = max(func14_start, i - 25)
            end_ctx = min(func14_end, i + 5)
            for j in start_ctx:end_ctx
                marker = j == i ? " >>> " : "     "
                println("$marker$j: $(lines[j])")
            end
            break
        end
    end
end

println("\nDone.")
