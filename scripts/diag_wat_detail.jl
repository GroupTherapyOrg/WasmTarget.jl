#!/usr/bin/env julia
# diag_wat_detail.jl — Compile register_struct_type! and dump func 13 WAT
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

println("=== Compiling register_struct_type! ===")
flush(stdout)
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = "/tmp/register_struct.wasm"
write(tmpf, wasm_bytes)
println("Written $(length(wasm_bytes)) bytes to $tmpf")

# Get WAT for func 13
println("\n=== func 13 in WAT (around error offset 0x895f) ===")
flush(stdout)
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, '\n')

# Find func 13
func_count = 0
func13_start = 0
func13_end = 0
for (i, line) in enumerate(lines)
    if contains(line, "(func ") && !contains(line, "(func_ref")
        func_count += 1
        if func_count == 14  # 0-indexed so func 13 is 14th
            func13_start = i
        elseif func_count == 15
            func13_end = i - 1
            break
        end
    end
end

if func13_start > 0
    func13_end = func13_end > 0 ? func13_end : min(func13_start + 2000, length(lines))
    func_lines = lines[func13_start:func13_end]
    println("  func 13: lines $(func13_start)-$(func13_end) ($(length(func_lines)) lines)")

    # Print first 5 lines (signature)
    for line in func_lines[1:min(5, end)]
        println("  $line")
    end

    # Find the first local.set or instruction that touches a ref type near the error
    # Also look for patterns: i32.const followed by local.set or struct_new or struct_set
    println("\n  --- Looking for i32 → ref type mismatch patterns ---")
    for (i, line) in enumerate(func_lines)
        # Look for struct.set or struct.new where i32 is being stored
        if contains(line, "local.set") || contains(line, "struct.set") || contains(line, "array.set")
            # Check if prev lines have i32.const
            if i > 1 && (contains(func_lines[i-1], "i32.const") || contains(func_lines[i-1], "i32.wrap"))
                start_i = max(1, i - 3)
                end_i = min(length(func_lines), i + 1)
                for j in start_i:end_i
                    marker = j == i ? ">>>" : "   "
                    println("$marker  $(func_lines[j])")
                end
                println("  ---")
                # Only show first 5 matches
                if i > 100
                    break
                end
            end
        end
    end
else
    println("  func 13 not found! Total funcs found: $func_count")
end

# Also: write func 13 WAT to a file for manual inspection
if func13_start > 0
    func13_end_actual = func13_end > 0 ? func13_end : min(func13_start + 2000, length(lines))
    open("/tmp/func13.wat", "w") do f
        for line in lines[func13_start:func13_end_actual]
            println(f, line)
        end
    end
    println("\nFull func 13 WAT written to /tmp/func13.wat")
end

println("Done.")
