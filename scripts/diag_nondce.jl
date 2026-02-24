using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
const Compiler = Core.Compiler

println("Compiling non_dce_finish!...")
bytes = compile(Compiler.non_dce_finish!, (Compiler.IncrementalCompact,))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written $(length(bytes)) bytes to $tmpf")

# Print WAT of func 3 (the failing one)
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, '\n')

# Find func 3
function find_func_wat(lines, func_num)
    local fc = 0
    local fstart = 0
    local fend = length(lines)
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func ")
            fc += 1
            if fc == func_num
                fstart = i
            elseif fc == func_num + 1
                fend = i - 1
                break
            end
        end
    end
    return fstart, fend
end

fstart, fend = find_func_wat(lines, 3)
println("\n=== func 3 (lines $fstart to $fend) ===")
for i in fstart:fend
    println("$(lpad(i, 5)): $(lines[i])")
end
