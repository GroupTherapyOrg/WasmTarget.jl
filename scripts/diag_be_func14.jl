#!/usr/bin/env julia
# Find func ;14; in builtin_effects WAT — search for i64.mul with externref local

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

PL = Compiler.PartialsLattice{Compiler.ConstsLattice}
println("Compiling builtin_effects(PartialsLattice)...")
flush(stdout)
bytes = compile(Compiler.builtin_effects, (PL, Core.Builtin, Vector{Any}, Any))
println("Compiled: $(length(bytes)) bytes")

tmpf = joinpath(tempdir(), "be_func14.wasm")
write(tmpf, bytes)

# Use wasm-tools dump to find the exact bytes at offset 0x7670
println("\n=== wasm-tools dump around offset 0x7670 ===")
flush(stdout)
dump_out = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_out, '\n')

for (i, line) in enumerate(dump_lines)
    m = match(r"^\s*(0x[0-9a-fA-F]+)", line)
    if m !== nothing
        offset = parse(Int, m.captures[1]; base=16)
        if offset >= 0x7630 && offset <= 0x76A0
            println(line)
        end
    end
end

# Also get WAT and find func ;14;
println("\n=== Finding func ;14; in WAT ===")
flush(stdout)

watf = joinpath(tempdir(), "be_func14.wat")
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf, stderr=devnull))
wat = read(watf, String)
wat_lines = split(wat, '\n')

# Find func 14
in_func14 = false
func_count_v = 0
func14_start = 0
func14_lines = String[]
brace_depth = 0

for (i, line) in enumerate(wat_lines)
    if occursin(r"\(func\s", line)
        func_count_v += 1
        if func_count_v == 14
            in_func14 = true
            func14_start = i
            brace_depth = 0
        end
    end
    if in_func14
        brace_depth += count("(", line) - count(")", line)
        push!(func14_lines, line)
        if brace_depth <= 0 && length(func14_lines) > 1
            break
        end
    end
end

if !isempty(func14_lines)
    println("func ;14; starts at line $func14_start, $(length(func14_lines)) lines")

    # Find all i64.mul operations and show context
    println("\n=== i64.mul operations in func ;14; ===")
    for (i, line) in enumerate(func14_lines)
        if occursin("i64.mul", line)
            start_ctx = max(1, i - 20)
            end_ctx = min(length(func14_lines), i + 3)
            println("\n--- i64.mul at relative line $i ---")
            for j in start_ctx:end_ctx
                marker = j == i ? " >>> " : "     "
                println("$marker$(func14_lines[j])")
            end
            # Only show first match
            break
        end
    end

    # Count locals by type
    externref_locals = 0
    i64_locals = 0
    for line in func14_lines
        if occursin("(local ", line) && occursin("externref", line)
            externref_locals += 1
        end
        if occursin("(local ", line) && occursin("i64", line)
            i64_locals += 1
        end
    end
    println("\nLocal counts: $externref_locals externref, $i64_locals i64")
else
    println("Could not find func ;14;")
end

println("\nDone.")
