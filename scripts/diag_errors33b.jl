#!/usr/bin/env julia
# diag_errors33b.jl — Get EXACT wasm-tools validate error for each failing function
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

test_functions = [
    ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_vector_type!", () -> WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("register_closure_type!", () -> WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_matrix_type!", () -> WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("get_array_type!", () -> WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("analyze_blocks", () -> WasmTarget.analyze_blocks, (Vector{Any},)),
    ("validate_emitted_bytes!", () -> WasmTarget.validate_emitted_bytes!, (WasmTarget.CompilationContext, Vector{UInt8}, Int64)),
    ("fix_broken_select_instructions", () -> WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
]

for (name, func_getter, arg_types) in test_functions
    println("--- $name ---")
    flush(stdout)
    func = func_getter()
    try
        wasm_bytes = WasmTarget.compile_multi([(func, arg_types)])
        tmpf = tempname() * ".wasm"
        write(tmpf, wasm_bytes)

        # Use read to capture stderr
        errf = tempname() * ".err"
        exitcode = -1
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stdout=devnull, stderr=errf))
            exitcode = 0
        catch; end

        if exitcode == 0
            println("  VALIDATES ✓")
        else
            err = read(errf, String)
            lines = split(strip(err), '\n')
            for (i, line) in enumerate(lines)
                i > 6 && break
                println("  $line")
            end
        end
        rm(tmpf; force=true)
        rm(errf; force=true)
    catch e
        println("  COMPILE_ERROR: $(sprint(showerror, e)[1:min(150,end)])")
    end
    println()
    flush(stdout)
end
