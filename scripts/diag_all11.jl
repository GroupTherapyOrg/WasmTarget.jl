#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# All 11 failing functions with their error func numbers
failing = [
    (:get_concrete_wasm_type, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 6),
    (:register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), 11),
    (:register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 1),
    (:register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), 1),
    (:register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType), 1),
    (:register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry), 1),
    (:register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 1),
    (:get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type), 9),
    (:analyze_blocks, (Core.Compiler.IRCode,), 4),
    (:validate_emitted_bytes!, (WasmTarget.WasmModule, Vector{UInt8}), 14),
    (:fix_broken_select_instructions, (Vector{UInt8}, WasmTarget.WasmModule), 1),
]

for (name, argtypes, errfunc) in failing
    func = getfield(WasmTarget, name)
    println("\n========== $name (error in func $errfunc) ==========")
    try
        bytes = WasmTarget.compile_multi([(func, argtypes)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)

        # Get validation error
        errbuf = IOBuffer()
        try Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull)) catch end
        err = strip(String(take!(errbuf)))
        println("ERROR: $err")

        # Get the specific function's WAT header
        outbuf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
        wat = String(take!(outbuf))
        lines = split(wat, "\n")

        # Find all func headers
        func_starts = Int[]
        for (i, line) in enumerate(lines)
            if startswith(lstrip(line), "(func ")
                push!(func_starts, i)
            end
        end

        # Get the failing func's WAT (first 30 lines)
        if errfunc <= length(func_starts)
            fstart = func_starts[errfunc]
            fend = errfunc < length(func_starts) ? func_starts[errfunc+1]-1 : min(fstart+100, length(lines))
            println("--- func $errfunc starts at WAT line $fstart ---")
            for i in fstart:min(fstart+29, fend)
                println("  $i: $(lines[i])")
            end
        end

        rm(tmpf; force=true)
    catch e
        println("COMPILE_ERROR: $e")
    end
end
