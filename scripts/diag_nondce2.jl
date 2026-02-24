using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

println("Compiling non_dce_finish!...")
bytes = compile(Compiler.non_dce_finish!, (Compiler.IncrementalCompact,))
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
    println("Error:\n$err")
end

# Get dump around the error offset 0xe2e = 3630
println("\n=== wasm-tools dump around offset 0xe2e ===")
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')
# Find lines near offset 0xe2e (3630 decimal)
target_offset = 0xe2e
for (i, line) in enumerate(dump_lines)
    # Lines look like "  0xe20 | ..."
    m = match(r"0x([0-9a-f]+)", line)
    if m !== nothing
        offset = parse(Int, m.captures[1]; base=16)
        if abs(offset - target_offset) < 40
            println(line)
        end
    end
end
