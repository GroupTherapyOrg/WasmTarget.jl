#!/usr/bin/env julia
# Find which wasm function (func N) fails in each module
# If they all fail on the same dependency, that's the root cause
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

failing_functions = [
    ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_union_type!", () -> WasmTarget.register_union_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)),
    ("get_numeric_box_type!", () -> WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType)),
    ("populate_type_constant_globals!", () -> WasmTarget.populate_type_constant_globals!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
]

for (name, func_getter, arg_types) in failing_functions
    func = func_getter()
    bytes = WasmTarget.compile_multi([(func, arg_types)])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Get export list
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))

    # Find exported functions
    exports_list = String[]
    for line in split(wat, "\n")
        m = match(r"\(export \"([^\"]+)\" \(func (\d+)\)\)", line)
        if m !== nothing
            push!(exports_list, "$(m[2]):$(m[1])")
        end
    end

    # Validate
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    err_msg = ok ? "VALIDATES" : strip(String(take!(errbuf)))
    # Extract func number and error type
    m = match(r"func (\d+) failed.*type mismatch: (.+) \(at", err_msg)
    if m !== nothing
        func_num = parse(Int, m[1])
        err_type = m[2]
        # Find which export corresponds to this func number
        func_name = "unknown"
        for exp in exports_list
            num, fname = split(exp, ":")
            if parse(Int, num) == func_num
                func_name = fname
                break
            end
        end
        println("$name: func $func_num ($func_name) — $err_type")
    else
        println("$name: $err_msg")
    end

    rm(tmpf; force=true)
end
