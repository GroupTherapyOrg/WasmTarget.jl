using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

# Compile builtin_effects (smaller variant) and analyze
println("Compiling builtin_effects(PartialsLattice,...)...")
bl = Compiler.PartialsLattice{Compiler.ConstsLattice}
bytes = compile(Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
tmpf = joinpath(@__DIR__, "be_partials.wasm")
write(tmpf, bytes)
println("Written $(length(bytes)) bytes to $tmpf")

# Get WAT
watf = joinpath(@__DIR__, "be_partials.wat")
wat = read(`wasm-tools print $tmpf`, String)
write(watf, wat)
println("WAT saved to $watf ($(count('\n', wat)) lines)")

# Find the area around offset 0x757d in the dump
println("\n=== wasm-tools dump around offset 0x757d ===")
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')
for (i, line) in enumerate(dump_lines)
    m = match(r"0x([0-9a-f]+)", line)
    if m !== nothing
        offset = parse(Int, m.captures[1]; base=16)
        if abs(offset - 0x757d) < 50
            println(line)
        end
    end
end

# Also find the i64.mul instruction in the WAT
println("\n=== i64.mul occurrences in WAT ===")
wat_lines = split(wat, '\n')
for (i, line) in enumerate(wat_lines)
    if occursin("i64.mul", line)
        println("Line $i: $line")
        # Print context
        for j in max(1,i-10):min(length(wat_lines),i+2)
            println("  $(j): $(wat_lines[j])")
        end
        println()
    end
end
