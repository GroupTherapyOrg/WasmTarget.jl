#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

outbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
wat = String(take!(outbuf))
lines = split(wat, "\n")

# Print all type definitions (to understand func_3's signature)
println("--- Type definitions ---")
for (i, line) in enumerate(lines)
    stripped = strip(line)
    if startswith(stripped, "(type ")
        println("  L$i: $stripped")
    end
end

# Find func_3 definition (including its type and params)
println("\n--- func_3 definition (first 5 lines) ---")
found = false
count = 0
for (i, line) in enumerate(lines)
    stripped = strip(line)
    if contains(stripped, "(func \$func_3")
        found = true
    end
    if found && count < 5
        println("  L$i: $stripped")
        count += 1
    end
end

# More context around the call (20 lines before)
println("\n--- 20 lines before call 3 ---")
for (i, line) in enumerate(lines)
    stripped = strip(line)
    if contains(stripped, "call 3") && !contains(stripped, "call 3)")
        for j in max(1, i-20):i
            println("  L$j: $(strip(lines[j]))")
        end
        break
    end
end

# Find func_1 local types
println("\n--- func_1 locals ---")
found = false
for (i, line) in enumerate(lines)
    stripped = strip(line)
    if contains(stripped, "(func \$func_1")
        found = true
    end
    if found && (contains(stripped, "(local ") || contains(stripped, "(param "))
        println("  L$i: $stripped")
    end
    if found && !contains(stripped, "(local ") && !contains(stripped, "(param ") && !startswith(stripped, "(func ")
        if i > 10
            break
        end
    end
end
