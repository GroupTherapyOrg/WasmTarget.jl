#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    failing = [
        ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
        ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("register_union_type!", () -> WasmTarget.register_union_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)),
        ("register_vector_type!", () -> WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("register_tuple_type!", () -> WasmTarget.register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("register_closure_type!", () -> WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("register_int128_type!", () -> WasmTarget.register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("register_matrix_type!", () -> WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
        ("get_array_type!", () -> WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
        ("is_self_referential_type", () -> WasmTarget.is_self_referential_type, (DataType,)),
        ("get_nullable_inner_type", () -> WasmTarget.get_nullable_inner_type, (Union,)),
        ("populate_type_constant_globals!", () -> WasmTarget.populate_type_constant_globals!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
        ("analyze_blocks", () -> WasmTarget.analyze_blocks, (Core.CodeInfo,)),
        ("validate_emitted_bytes!", () -> WasmTarget.validate_emitted_bytes!, (WasmTarget.WasmStackValidator, Vector{UInt8}, String)),
        ("fix_broken_select_instructions", () -> WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
    ]
    
    for (name, func_getter, arg_types) in failing
        func = func_getter()
        local bytes
        try
            bytes = WasmTarget.compile_multi([(func, arg_types)])
        catch e
            println("$name: COMPILE_ERROR: $(sprint(showerror, e))")
            continue
        end
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        
        errbuf = IOBuffer()
        ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            ok = true
        catch; end
        
        if !ok
            err = strip(String(take!(errbuf)))
            # Extract key info
            m = match(r"type mismatch: (.+) \(at offset", err)
            if m !== nothing
                println("$name: $( m[1])")
            else
                println("$name: $err")
            end
        end
        rm(tmpf; force=true)
    end
end
main()
