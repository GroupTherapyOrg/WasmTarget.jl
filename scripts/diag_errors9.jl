#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

failing = [
    (WasmTarget.get_concrete_wasm_type, (DataType,), "get_concrete_wasm_type"),
    (WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), "register_struct_type!"),
    (WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "register_vector_type!"),
    (WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), "register_closure_type!"),
    (WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "register_matrix_type!"),
    (WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), "get_array_type!"),
    (WasmTarget.analyze_blocks, (Core.Compiler.IRCode,), "analyze_blocks"),
    (WasmTarget.validate_emitted_bytes!, (WasmTarget.WasmModule,), "validate_emitted_bytes!"),
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions"),
]

for (func, argtypes, name) in failing
    println("\n========== $name ==========")
    try
        bytes = WasmTarget.compile_multi([(func, argtypes)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        errbuf = IOBuffer()
        try Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull)) catch end
        err = strip(String(take!(errbuf)))
        if isempty(err)
            println("  VALIDATES OK")
        else
            errlines = split(err, "\n")
            for (i, l) in enumerate(errlines)
                println("  $l")
                if i >= 5; break; end
            end
        end
        rm(tmpf; force=true)
    catch e
        println("  COMPILE_ERROR: $e")
    end
end
