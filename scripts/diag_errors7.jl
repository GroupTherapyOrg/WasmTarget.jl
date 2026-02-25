#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# The 7 real VALIDATE_ERROR functions — use signatures from test_codegen_helpers.jl
failing = [
    (WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    (WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    (WasmTarget.register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    (WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    (WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    (WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    (WasmTarget.analyze_blocks, (Core.Compiler.IRCode,)),
]

for (func, argtypes) in failing
    fname = nameof(func)
    println("\n========== $fname ==========")
    try
        bytes = WasmTarget.compile_multi([(func, argtypes)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)

        # Get FULL validation error
        errbuf = IOBuffer()
        try Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull)) catch end
        err = strip(String(take!(errbuf)))
        # Print full error (first 5 lines if multi-line)
        errlines = split(err, "\n")
        for (i, l) in enumerate(errlines)
            println("  $l")
            if i >= 5; break; end
        end

        rm(tmpf; force=true)
    catch e
        println("  COMPILE_ERROR: $e")
    end
end
