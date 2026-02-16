using WasmTarget, Core.Compiler

println("=== Compiling record_slot_assign! ===")
bytes = compile(Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,))
f = tempname() * ".wasm"
write(f, bytes)
println("Size: $(length(bytes)) bytes → $f")

function analyze_func11(f)
    wat = read(`wasm-tools print $f`, String)
    lines = split(wat, "\n")

    # Find func 11 (0-indexed, so the 12th function declaration)
    func_count = 0
    func11_start = 0
    func11_end = 0
    for (i, line) in enumerate(lines)
        if occursin("(func (;", line)
            func_count += 1
            if func_count == 12  # 0-indexed func 11 = 12th func
                func11_start = i
                println("func 11 starts at WAT line $i: $(strip(line))")
            elseif func_count == 13
                func11_end = i - 1
                println("func 11 ends at WAT line $(i-1)")
                break
            end
        end
    end

    if func11_start == 0
        println("Could not find func 11!")
        return
    end
    if func11_end == 0
        func11_end = length(lines)
    end

    # Show func 11's local declarations
    println("\n=== func 11 local declarations ===")
    for i in func11_start:min(func11_start+30, func11_end)
        line = lines[i]
        if occursin("local", line) || occursin("param", line) || occursin("func", line) || occursin("result", line)
            println("  $i: $(strip(line))")
        end
        if !occursin("local", line) && !occursin("param", line) && !occursin("func", line) && !occursin("result", line) && i > func11_start + 2
            break
        end
    end

    # Find ALL i32.const 0 + local.set patterns in func 11
    println("\n=== i32.const 0 + local.set patterns in func 11 ===")
    pattern_count = 0
    for i in func11_start:func11_end
        line = lines[i]
        if occursin("i32.const 0", line) && !occursin("i32.const 0x", line) && i < func11_end && occursin("local.set", lines[i+1])
            pattern_count += 1
            # Extract local.set index
            m = match(r"local\.set (\d+)", lines[i+1])
            local_idx = m !== nothing ? m.captures[1] : "?"
            println("\nPattern #$pattern_count (local.set $local_idx) at line $i:")
            for j in max(func11_start, i-10):min(func11_end, i+5)
                marker = (j == i || j == i+1) ? ">>>" : "   "
                println("  $marker $(j): $(lines[j])")
            end
        end
    end
    println("\nTotal patterns in func 11: $pattern_count")
end

analyze_func11(f)
