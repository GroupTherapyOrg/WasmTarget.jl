using WasmTarget, Core.Compiler

println("=== type_annotate! — func 31 WAT ===")
bytes = compile(Core.Compiler.type_annotate!,
    (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Print the WAT and find func 31
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, "\n")

function print_func(lines, target_idx)
    in_func = false
    func_idx = -1
    for (line_no, line) in enumerate(lines)
        if occursin(r"\(func \$func_\d+", line)
            func_idx += 1
            if func_idx == target_idx
                in_func = true
            elseif func_idx == target_idx + 1
                break
            end
        end
        if in_func
            println(line)
        end
    end
end

print_func(lines, 31)
