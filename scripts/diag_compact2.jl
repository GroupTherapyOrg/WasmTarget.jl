using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

println("Compiling compact!...")
bytes = compile(Compiler.compact!, (Compiler.IRCode, Bool))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written $(length(bytes)) bytes to $tmpf")

# Get error
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES ✓")
catch
    err = String(take!(errbuf))
    println("Error:\n$err")
end

# Dump around error offset 0x33f6 and 0x33f9
println("\n=== wasm-tools dump around offset 0x33f6 ===")
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')
for target_offset in [0x33f6, 0x33f9]
    println("\n--- offset $(string(target_offset, base=16)) ---")
    for (i, line) in enumerate(dump_lines)
        m = match(r"0x([0-9a-f]+)", line)
        if m !== nothing
            offset = parse(Int, m.captures[1]; base=16)
            if abs(offset - target_offset) < 80
                println(line)
            end
        end
    end
end
