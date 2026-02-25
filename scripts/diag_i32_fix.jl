using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

funcs_to_test = [
    ("is_self_referential_type", WasmTarget.is_self_referential_type, (DataType,)),
    ("get_nullable_inner_type", WasmTarget.get_nullable_inner_type, (Union,)),
    ("register_union_type!", WasmTarget.register_union_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)),
]

for (name, func, arg_types) in funcs_to_test
    print("$name: ")
    flush(stdout)
    local bytes
    try
        bytes = WasmTarget.compile_multi([(func, arg_types)])
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e)[1:min(100,end)])")
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
    if ok
        println("VALIDATES ✓ ($(length(bytes)) bytes)")
    else
        err = strip(String(take!(errbuf)))
        m = match(r"type mismatch: (.+) \(at offset", err)
        if m !== nothing
            println("VALIDATE_ERROR: $(m[1])")
        else
            println("VALIDATE_ERROR: $err")
        end
    end
    rm(tmpf; force=true)
end
