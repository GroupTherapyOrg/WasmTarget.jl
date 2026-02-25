#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    failing = [
        ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
        ("get_numeric_box_type!", () -> WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType)),
        ("fix_broken_select_instructions", () -> WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
        ("is_self_referential_type", () -> WasmTarget.is_self_referential_type, (DataType,)),
        ("get_nullable_inner_type", () -> WasmTarget.get_nullable_inner_type, (Union,)),
    ]
    
    for (name, func_getter, arg_types) in failing
        func = func_getter()
        bytes = WasmTarget.compile_multi([(func, arg_types)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        
        errbuf = IOBuffer()
        ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            ok = true
        catch; end
        
        if !ok
            err = String(take!(errbuf))
            println("\n=== $name ===")
            println(strip(err))
        end
        rm(tmpf; force=true)
    end
end
main()
