#!/usr/bin/env julia
# Diagnose detailed validation error for a specific function
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

func_name = get(ARGS, 1, "register_struct_type!")

# Map names to (function, arg_types)
func_map = Dict(
    "register_struct_type!" => (WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    "get_concrete_wasm_type" => (WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    "register_vector_type!" => (WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    "register_tuple_type!" => (WasmTarget.register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}})),
    "register_closure_type!" => (WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    "register_int128_type!" => (WasmTarget.register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    "register_matrix_type!" => (WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    "get_array_type!" => (WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    "register_union_type!" => (WasmTarget.register_union_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)),
    "analyze_blocks" => (WasmTarget.analyze_blocks, (Vector{Any},)),
    "validate_emitted_bytes!" => (WasmTarget.validate_emitted_bytes!, (WasmTarget.CompilationContext, Vector{UInt8}, Int64)),
    "fix_broken_select_instructions" => (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
)

if !haskey(func_map, func_name)
    println("Unknown function: $func_name")
    println("Available: $(join(keys(func_map), ", "))")
    exit(1)
end

func, arg_types = func_map[func_name]
println("=== Diagnosing: $func_name ===")

bytes = WasmTarget.compile_multi([(func, arg_types)])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes")

# Validate
errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch
end

if ok
    println("VALIDATES OK!")
    rm(tmpf; force=true)
    exit(0)
end

err = String(take!(errbuf))
println("\nFULL ERROR:")
println(err)

# Get offset
m = match(r"at offset (0x[0-9a-f]+)", err)
if !isnothing(m)
    offset_hex = m[1]
    println("\n--- WAT near offset $offset_hex ---")
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    for (i, line) in enumerate(lines)
        if contains(line, offset_hex)
            lo = max(1, i - 15)
            hi = min(length(lines), i + 5)
            for j in lo:hi
                marker = j == i ? " >>> " : "     "
                println("$marker$(lines[j])")
            end
            break
        end
    end
end

rm(tmpf; force=true)
