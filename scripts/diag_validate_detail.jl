#!/usr/bin/env julia
# diag_validate_detail.jl — PURE-6025
# Get exact wasm-tools validation error for each failing function

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget

println("=== PURE-6025: Detailed validation error diagnosis ===")
flush(stdout)

# Subset of functions with VALIDATE_ERROR — focus on simpler ones
test_fns = [
    ("get_string_array_type!", WasmTarget.get_string_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("get_numeric_box_type!", WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType)),
    ("add_type! FuncType", WasmTarget.add_type!, (WasmTarget.WasmModule, WasmTarget.FuncType)),
    ("add_type! StructType", WasmTarget.add_type!, (WasmTarget.WasmModule, WasmTarget.StructType)),
    ("add_function!", WasmTarget.add_function!, (WasmTarget.WasmModule, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{UInt8})),
    ("types_equal", WasmTarget.types_equal, (WasmTarget.FuncType, WasmTarget.FuncType)),
    ("validate_pop! NumType", WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, WasmTarget.NumType)),
    ("fix_broken_select_instructions", WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
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
            println("VALIDATES")
        else
            err_msg = strip(String(take!(errbuf)))
            # Show just the key error line
            for line in split(err_msg, '\n')
                line = strip(line)
                if startswith(line, "0:")
                    println(line)
                    break
                end
            end
        end
        rm(tmpf; force=true)
    catch e
        msg = sprint(showerror, e)
        println("COMPILE_ERROR: $(msg[1:min(100,end)])")
    end
    flush(stdout)
end
