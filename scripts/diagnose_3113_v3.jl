using WasmTarget, Core.Compiler

println("=== type_annotate! — diagnosis ===")
bytes = compile(Core.Compiler.type_annotate!,
    (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("File: $tmpf")
println("Size: $(length(bytes)) bytes")

# Save WAT to file for analysis
wat = read(`wasm-tools print $tmpf`, String)
watf = tempname() * ".wat"
write(watf, wat)
println("WAT file: $watf")

# Count funcs
func_count = count(r"\(func ", wat)
println("Total funcs: $func_count")

# Find all func headers
for line in split(wat, "\n")
    if occursin(r"\(func ", line)
        # Just print the func header (first 120 chars)
        println(length(line) > 120 ? line[1:120] * "..." : line)
    end
end
