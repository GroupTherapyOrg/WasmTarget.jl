using WasmTarget, Core.Compiler

# Compile record_slot_assign! and find i32.const 0 + local.set patterns
println("=== Compiling record_slot_assign! ===")
bytes = compile(Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,))
f = tempname() * ".wasm"
write(f, bytes)
println("Size: $(length(bytes)) bytes → $f")

# Validate (don't throw on failure)
try
    result = read(pipeline(`wasm-tools validate --features=gc $f`, stderr=stdout), String)
    if isempty(result)
        println("VALIDATES ✓")
    else
        for l in split(strip(result), "\n")[1:min(5, end)]
            println(l)
        end
    end
catch e
    println("Validation failed (expected)")
end

function analyze_wat(f)
    println("\n=== Searching WAT for i32.const 0 + local.set patterns ===")
    wat = read(`wasm-tools print $f`, String)
    lines = split(wat, "\n")

    current_func = ""
    for (i, line) in enumerate(lines)
        if occursin("(func ", line)
            current_func = strip(line)
        end
        # Look for i32.const 0 followed by local.set on next line
        if occursin("i32.const 0", line) && !occursin("i32.const 0x", line) && i < length(lines) && occursin("local.set", lines[i+1])
            println("\n[$current_func]")
            println("  Pattern at line $i:")
            for j in max(1, i-8):min(length(lines), i+5)
                marker = (j == i || j == i+1) ? ">>>" : "   "
                println("  $marker $(j): $(lines[j])")
            end
        end
    end
end

analyze_wat(f)
