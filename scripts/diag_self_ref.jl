#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.is_self_referential_type, (DataType,))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get WAT text — use grep to find func_2
outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))

# Write WAT to temp file and use grep
watf = tempname() * ".wat"
write(watf, wat)

println("--- func signatures ---")
Base.run(pipeline(`grep -n "func " $watf`; stdout))

println("\n--- Around func_2 (lines near offset 0x453) ---")
# Use sed to extract func_2 region
lines = split(wat, "\n")
func2_start = 0
for (i, line) in pairs(lines)
    if contains(line, "(func \$func_2")
        func2_start = i
        break
    end
end

if func2_start > 0
    stop = min(func2_start + 80, length(lines))
    for i in func2_start:stop
        println("L$i: ", strip(lines[i]))
    end
end

# Validate
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("\nVALIDATES")
catch
    err = String(take!(errbuf))
    println("\n$err")
end
rm(tmpf; force=true)
rm(watf; force=true)
