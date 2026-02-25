#!/usr/bin/env julia
# diag_errors_detailed.jl — Get specific wasm-tools validate error messages for failing functions
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# The 9 functions that still fail
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
    println("=== $name ===")
    func = func_getter()
    try
        wasm_bytes = WasmTarget.compile_multi([(func, arg_types)])
        tmpf = tempname() * ".wasm"
        write(tmpf, wasm_bytes)

        # Get detailed error
        errbuf = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            println("  VALIDATES ✓")
        catch
            err = String(take!(errbuf))
            # Show first 5 lines of error
            for (i, line) in enumerate(split(err, '\n'))
                i > 5 && break
                println("  $line")
            end
        end

        # Also dump around the error offset if available
        err_str = String(take!(errbuf))
        m = match(r"at offset (0x[0-9a-f]+)", err_str)
        if m !== nothing
            println("  [offset: $(m[1])]")
        end

        rm(tmpf; force=true)
    catch e
        println("  COMPILE_ERROR: $(sprint(showerror, e)[1:min(200,end)])")
    end
    println()
    flush(stdout)
end
