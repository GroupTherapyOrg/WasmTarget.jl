using WasmTarget, Core.Compiler

println("=== type_annotate! — func 31 analysis ===")
bytes = compile(Core.Compiler.type_annotate!,
    (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Use wasm-tools dump to find offset 0xe236
println("\n--- Dumping around offset 0xe236 ---")
dump_out = read(`wasm-tools dump $tmpf`, String)
lines = split(dump_out, "\n")
# Find lines around offset 0xe236 = 57910
target = 0xe236
for (i, line) in enumerate(lines)
    m = match(r"^\s*(0x[0-9a-f]+)\s", line)
    if m !== nothing
        offset = parse(Int, m.captures[1], base=16)
        if abs(offset - target) < 40
            println(line)
        end
    end
end

# Also print WAT for func 31 header
println("\n--- WAT func 31 signature ---")
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, "\n")
in_func = false
func_idx = -1
line_count = 0
for line in lines
    if contains(line, "(func \$func_")
        func_idx += 1
        if func_idx == 31
            in_func = true
            println(line)
            line_count = 1
            continue
        elseif func_idx == 32
            break
        end
    end
    if in_func
        line_count += 1
        if line_count <= 3
            println(line)
        end
    end
end
