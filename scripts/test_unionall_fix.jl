#!/usr/bin/env julia
# test_unionall_fix.jl — PURE-6025
# Quick test of the UnionAll .parameters fix

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

test_fns = [
    ("get_concrete_wasm_type", WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("register_struct_type!", WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_vector_type!", WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("register_closure_type!", WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_matrix_type!", WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("get_array_type!", WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("validate_emitted_bytes!", WasmTarget.validate_emitted_bytes!, (WasmTarget.CompilationContext, Vector{UInt8}, Int64)),
]

for (name, func, arg_types) in test_fns
    print("$name: ")
    flush(stdout)
    try
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
            println("VALIDATES ($(length(bytes)) bytes)")
        else
            err_msg = String(take!(errbuf))
            println("VALIDATE_ERROR")
        end
        rm(tmpf; force=true)
    catch e
        msg = sprint(showerror, e)
        println("COMPILE_ERROR: $(msg[1:min(100,end)])")
    end
    flush(stdout)
end
