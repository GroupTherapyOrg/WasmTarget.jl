using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

# builtin_effects with PartialsLattice (smaller func number = easier to analyze)
bl = Compiler.PartialsLattice{Compiler.ConstsLattice}
println("Compiling builtin_effects(PartialsLattice,...)...")
bytes = compile(Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written $(length(bytes)) bytes to $tmpf")

# Get detailed error
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate -v --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES ✓")
catch
    err = String(take!(errbuf))
    for line in split(err, '\n')[1:min(10,end)]
        println(line)
    end
end

# Dump around error offset 0x757d
println("\n=== wasm-tools dump around offset 0x757d ===")
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')
target_offset = 0x757d
for (i, line) in enumerate(dump_lines)
    m = match(r"0x([0-9a-f]+)", line)
    if m !== nothing
        offset = parse(Int, m.captures[1]; base=16)
        if abs(offset - target_offset) < 60
            println(line)
        end
    end
end
