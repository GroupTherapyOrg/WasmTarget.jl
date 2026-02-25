#!/usr/bin/env julia
# diag_context_111.jl — Get broad context around the first i32_const 111 instance
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

println("=== Compiling register_struct_type! ===")
flush(stdout)
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = "/tmp/regstruct_ctx.wasm"
write(tmpf, wasm_bytes)
println("Written $(length(wasm_bytes)) bytes")

# Use wasm-tools dump to get context around first bug offset (0x8994)
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')

# Find the line with offset 0x8994 and show 30 lines of context before and 10 after
target_offset = 0x8994
found = false
for (i, line) in enumerate(dump_lines)
    m = match(r"^\s*0x([0-9a-fA-F]+)", line)
    if m !== nothing
        offset = parse(Int, m[1]; base=16)
        if offset >= target_offset && !found
            found = true
            start_i = max(1, i - 40)
            end_i = min(length(dump_lines), i + 15)
            println("\n=== Context around offset 0x$(string(target_offset, base=16)) (40 lines before, 15 after) ===")
            for j in start_i:end_i
                marker = j == i ? ">>>" : "   "
                println("$marker $(dump_lines[j])")
            end
        end
    end
end

# Also show the function's local declarations
println("\n=== Func 13 local declarations ===")
# Find func 13 start in the dump
func_count = 0
for (i, line) in enumerate(dump_lines)
    if contains(line, "| func")
        func_count += 1
        if func_count == 14  # 0-indexed func 13 = 14th func
            println("Found func 13 start at line $i")
            # Show locals (next several lines after func start)
            for j in i:min(i+80, length(dump_lines))
                println("   $(dump_lines[j])")
                # Stop at first instruction that's not a local
                if j > i && !contains(dump_lines[j], "local") && !contains(dump_lines[j], "func") && !contains(dump_lines[j], "|")
                    break
                end
            end
            break
        end
    end
end

# And get the local types from WAT for locals 26, 27, 60
println("\n=== WAT: local types for func 13 ===")
flush(stdout)
wat = read(`wasm-tools print $tmpf`, String)
wat_lines = split(wat, '\n')

func_count = 0
in_func13 = false
for (i, line) in enumerate(wat_lines)
    if contains(line, "(func ")
        func_count += 1
        if func_count == 14  # 0-indexed func 13 = 14th func
            in_func13 = true
            # Print first 30 lines (signature + locals)
            for j in i:min(i+30, length(wat_lines))
                println("  $(wat_lines[j])")
            end
            break
        end
    end
end

rm(tmpf; force=true)
println("\nDone.")
