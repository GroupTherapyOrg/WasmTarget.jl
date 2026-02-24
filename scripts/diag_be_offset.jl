#!/usr/bin/env julia
# Diagnose builtin_effects VALIDATE_ERROR — find code around error offset

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

# Compile builtin_effects(PartialsLattice) — smaller offset, easier to analyze
argtypes = (Compiler.PartialsLattice{Compiler.ConstsLattice}, Core.Builtin, Vector{Any}, Any)
println("Compiling builtin_effects(PartialsLattice)...")
flush(stdout)
bytes = compile(Compiler.builtin_effects, argtypes)
println("Compiled: $(length(bytes)) bytes")

tmpf = joinpath(tempdir(), "be_partials.wasm")
write(tmpf, bytes)

# Get the WAT for func 14 (the failing function)
watf = joinpath(tempdir(), "be_partials.wat")
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf, stderr=devnull))

# Read the WAT and find func 14
wat = read(watf, String)
lines = split(wat, '\n')

# Find func 14 boundaries
func_start = 0
func_end = 0
func_count = 0
for (i, line) in enumerate(lines)
    if occursin("(func ", line) && occursin("(;", line)
        func_count += 1
        if func_count == 14
            func_start = i
        end
    end
    if func_start > 0 && func_end == 0
        # Track indentation to find the end
        if i > func_start && !isempty(strip(line)) && !startswith(lstrip(line), "(") && !startswith(lstrip(line), ")")
            # Still inside
        end
    end
end

# Simpler approach: just dump func ;14;
in_func14 = false
func14_lines = String[]
depth = 0
for (i, line) in enumerate(lines)
    if occursin("(;14;)", line) || occursin("(func (;14;)", line)
        in_func14 = true
        depth = 1
        push!(func14_lines, "$i: $line")
        continue
    end
    if in_func14
        push!(func14_lines, "$i: $line")
        depth += count("(", line) - count(")", line)
        if depth <= 0
            break
        end
    end
end

if !isempty(func14_lines)
    println("\n=== func ;14; (builtin_effects) — $(length(func14_lines)) lines ===")

    # Find the i64.mul or other i64 operation that expects i64 but gets externref
    for (i, line) in enumerate(func14_lines)
        if occursin("i64.mul", line) || occursin("i64.add", line) || occursin("i64.sub", line) || occursin("i64.and", line) || occursin("i64.or", line) || occursin("i64.xor", line) || occursin("i64.shl", line) || occursin("i64.shr", line)
            # Print context around this line
            start_ctx = max(1, i-10)
            end_ctx = min(length(func14_lines), i+5)
            println("\n--- Found i64 op at relative line $i ---")
            for j in start_ctx:end_ctx
                marker = j == i ? " >>>" : "    "
                println("$marker $(func14_lines[j])")
            end
        end
    end

    # Also search for local.get with externref locals used before i64 ops
    println("\n--- First 200 lines of func ;14; ---")
    for line in func14_lines[1:min(200, length(func14_lines))]
        println(line)
    end
else
    println("Could not find func ;14;")
    # List function headers
    println("\n=== Function headers ===")
    for (i, line) in enumerate(lines)
        if occursin("(func ", line)
            println("$i: $line")
        end
    end
end

println("\nDone.")
