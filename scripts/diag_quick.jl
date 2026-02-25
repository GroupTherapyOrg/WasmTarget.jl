#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function check(name, func, arg_types)
    bytes = WasmTarget.compile_multi([(func, arg_types)])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch
    end
    if ok
        println("$name: VALIDATES")
    else
        err = strip(String(take!(errbuf)))
        # Extract offset
        m = match(r"at offset (0x[0-9a-f]+)", err)
        offset = isnothing(m) ? "?" : m[1]
        # Extract type mismatch
        m2 = match(r"type mismatch: (.+?) \(at", err)
        msg = isnothing(m2) ? err : m2[1]
        println("$name: $msg @ $offset")
    end
    rm(tmpf; force=true)
end

check("register_struct_type!", WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))
check("get_concrete_wasm_type", WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))
check("register_int128_type!", WasmTarget.register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type))
check("analyze_blocks", WasmTarget.analyze_blocks, (Vector{Any},))
check("fix_broken_select_instructions", WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))
