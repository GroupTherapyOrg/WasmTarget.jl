#!/usr/bin/env julia
using WasmTarget, JuliaSyntax

function parse_test(s::String)
    ps = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(ps)
    return Int64(1)
end

bytes = compile(parse_test, (String,))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written to: $tmpf")
println("Size: $(length(bytes)) bytes")

# Find unreachable instructions and their function contexts
println("\nSearching for unreachable in WAT...")
lines = readlines(`wasm-tools print $tmpf`)
let current_func = ""
    for (i, line) in enumerate(lines)
        m = match(r"\(func \(;(\d+);\)", line)
        if m !== nothing
            current_func = m[1]
        end
        stripped = strip(line)
        if stripped == "unreachable"
            println("  unreachable at WAT line $i in func $current_func")
        end
    end
end
