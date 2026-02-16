using WasmTarget, Core.Compiler

# Get the list of cross-call functions by looking at what methods are compiled
# First, let's compile and check the WAT to identify func 11's signature
println("=== Compiling record_slot_assign! ===")
bytes = compile(Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,))
f = tempname() * ".wasm"
write(f, bytes)

# Get func 11 from WAT and show its exports
wat = read(`wasm-tools print $f`, String)
lines = split(wat, "\n")

# List ALL functions with their signatures and export names
func_count = 0
for (i, line) in enumerate(lines)
    if occursin("(func (;", line)
        # Extract function number
        m = match(r"\(func \(;(\d+);\)", line)
        if m !== nothing
            idx = parse(Int, m.captures[1])
            println("func $idx: $(strip(line))")
            # Also check next few lines for export
            for j in i-3:i-1
                if j >= 1 && occursin("(export", lines[j])
                    println("  export: $(strip(lines[j]))")
                end
            end
        end
    end
end
