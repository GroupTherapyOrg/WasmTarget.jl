#!/usr/bin/env julia
# diag_ir_dump.jl — Add temporary debug logging, compile, then remove
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))

# Add temporary warn to set_phi_locals_for_edge! to trace type mismatches
# Read the codegen file, add logging, compile, then revert
codegen_path = joinpath(@__DIR__, "..", "src", "compiler", "codegen.jl")
original = read(codegen_path, String)

# Instead of modifying code, let's use a different approach:
# Compile with the debug flag and check the binary output directly

using WasmTarget

# Compile register_struct_type!
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = "/tmp/regstruct_ir.wasm"
write(tmpf, wasm_bytes)

# Get WAT and find local declarations for func 13
wat = read(`wasm-tools print $tmpf`, String)
wat_lines = split(wat, '\n')

func_count = 0
in_func13 = false
func13_lines = String[]
for (i, line) in enumerate(wat_lines)
    if contains(line, "(func ") && !contains(line, "(func_ref")
        func_count += 1
        if func_count == 14
            in_func13 = true
        elseif in_func13
            break
        end
    end
    if in_func13
        push!(func13_lines, line)
    end
end

println("Func 13: $(length(func13_lines)) lines")

# Print local declarations (first N lines up to first instruction)
println("\n=== Local declarations ===")
for (i, line) in enumerate(func13_lines)
    if i > 1 && !contains(line, "local") && !contains(line, "param") && !contains(line, "result")
        break
    end
    println("  $line")
    if i > 50
        break
    end
end

# Find lines around the error offset and extract local types for locals 26, 27, 60, 61
println("\n=== Local types for key locals ===")
local_decls = String[]
for line in func13_lines
    if contains(line, "(local ")
        push!(local_decls, strip(line))
    end
end
println("Total locals declared: $(length(local_decls))")

# Parse local types — each (local $name type) or (local type)
local_types = String[]
for decl in local_decls
    # Extract the type from (local $name type) or (local type)
    m = match(r"\(local\s+(?:\$\w+\s+)?(.+)\)", decl)
    if m !== nothing
        push!(local_types, m[1])
    end
end

# Show locals 26, 27, 60, 61 (0-indexed in WAT, but may be offset by params)
for idx in [26, 27, 36, 37, 60, 61]
    if idx + 1 <= length(local_types)
        println("  local $idx: $(local_types[idx + 1])")
    else
        println("  local $idx: <not in range> (total: $(length(local_types)))")
    end
end

rm(tmpf; force=true)
println("\nDone.")
