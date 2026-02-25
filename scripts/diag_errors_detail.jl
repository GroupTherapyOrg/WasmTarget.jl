#!/usr/bin/env julia
# Diagnose remaining VALIDATE_ERROR functions — get actual error messages
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

test_functions = [
    ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("is_self_referential_type", () -> WasmTarget.is_self_referential_type, (DataType,)),
    ("fix_broken_select_instructions", () -> WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
    ("analyze_blocks", () -> WasmTarget.analyze_blocks, (Vector{Any},)),
]

for (name, func_getter, arg_types) in test_functions
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

    if ok
        println("$name: VALIDATES")
    else
        err = String(take!(errbuf))
        # Extract just the error type/details
        lines = split(strip(err), "\n")
        println("$name:")
        for line in lines
            println("  $line")
        end
    end
    rm(tmpf; force=true)
    println()
end
