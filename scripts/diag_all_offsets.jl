#!/usr/bin/env julia
# diag_all_offsets.jl — Dump instructions around error offset for each failing function
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

test_functions = [
    ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), 0x895f),
    ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry), 0xead8),
    ("register_vector_type!", () -> WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 0xfafd),
    ("register_closure_type!", () -> WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), 0xfb9c),
    ("register_matrix_type!", () -> WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 0xeeeb),
    ("get_array_type!", () -> WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 0xec45),
    ("validate_emitted_bytes!", () -> WasmTarget.validate_emitted_bytes!, (WasmTarget.CompilationContext, Vector{UInt8}, Int64), 0x1a0da),
]

for (name, func_getter, arg_types, err_offset) in test_functions
    println("=== $name (offset 0x$(string(err_offset, base=16))) ===")
    flush(stdout)
    func = func_getter()
    wasm_bytes = WasmTarget.compile_multi([(func, arg_types)])
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)

    dump_output = read(`wasm-tools dump $tmpf`, String)
    dump_lines = split(dump_output, '\n')

    for (i, line) in enumerate(dump_lines)
        m = match(r"^\s*0x([0-9a-fA-F]+)", line)
        if m !== nothing
            offset = parse(UInt64, m[1]; base=16)
            if offset >= err_offset - 20 && offset <= err_offset + 10
                marker = offset == err_offset ? ">>>" : "   "
                println("$marker $line")
            end
        end
    end
    rm(tmpf; force=true)
    println()
    flush(stdout)
end
println("Done.")
