using WasmTarget, Core.Compiler

bytes = compile(Core.Compiler.type_annotate!,
    (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Save full WAT
wat = read(`wasm-tools print $tmpf`, String)
watf = "/tmp/type_annotate_3113.wat"
write(watf, wat)
println("Full WAT saved to: $watf")
println("Size: $(length(bytes)) bytes, $(length(split(wat, "\n"))) lines")

function extract_func(wat_text, func_num)
    lines = split(wat_text, "\n")
    start_idx = 0
    end_idx = 0
    depth = 0
    for (i, line) in enumerate(lines)
        if occursin("(func (;$(func_num);)", line)
            start_idx = i
            depth = 1
        elseif start_idx > 0 && i > start_idx
            depth += count("(", line) - count(")", line)
            if depth <= 0
                end_idx = i
                break
            end
        end
    end
    if start_idx > 0 && end_idx > 0
        return join(lines[start_idx:end_idx], "\n")
    end
    return "Could not find func $func_num"
end

func31 = extract_func(wat, 31)
nlines = length(split(func31, "\n"))
println("\n=== func 31 (tmerge_types_slow) — $nlines lines ===")
println(func31)
