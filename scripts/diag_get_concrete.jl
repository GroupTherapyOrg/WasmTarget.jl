#!/usr/bin/env julia
# Diagnose get_concrete_wasm_type validation error
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written: $tmpf ($(length(bytes)) bytes)")

errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch; end

if ok
    println("VALIDATES")
else
    err = String(take!(errbuf))
    println("VALIDATE_ERROR:")
    println(err)
end

# Also try register_struct_type!
bytes2 = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf2 = tempname() * ".wasm"
write(tmpf2, bytes2)
println("\nregister_struct_type! — $(length(bytes2)) bytes")

errbuf2 = IOBuffer()
ok2 = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf2`, stderr=errbuf2, stdout=devnull))
    ok2 = true
catch; end

if ok2
    println("VALIDATES")
else
    err2 = String(take!(errbuf2))
    println("VALIDATE_ERROR:")
    println(err2)
end

# Also try fix_broken_select_instructions
bytes3 = WasmTarget.compile_multi([(WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))])
tmpf3 = tempname() * ".wasm"
write(tmpf3, bytes3)
println("\nfix_broken_select_instructions — $(length(bytes3)) bytes")

errbuf3 = IOBuffer()
ok3 = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf3`, stderr=errbuf3, stdout=devnull))
    ok3 = true
catch; end

if ok3
    println("VALIDATES")
else
    err3 = String(take!(errbuf3))
    println("VALIDATE_ERROR:")
    println(err3)
end
