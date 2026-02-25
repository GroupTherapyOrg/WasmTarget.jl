#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Print func_3 signature (the callee) and func_1 around calls to func_3
outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))
lines = split(wat, "\n")

# Find func_3 signature
for (i, line) in enumerate(lines)
    if contains(line, "(func \$func_3") || contains(line, "(func \$func_1")
        println("L$i: $(strip(line))")
    end
end

# Find all calls to func_3 in the WAT with context
println("\n--- Calls to function 3 (with context) ---")
for (i, line) in enumerate(lines)
    stripped = strip(line)
    if contains(stripped, "call \$func_3") || contains(stripped, "call 3")
        # Print 10 lines before
        for j in max(1, i-10):i
            println("  L$j: $(strip(lines[j]))")
        end
        println("---")
    end
end
