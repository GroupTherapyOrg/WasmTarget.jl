#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    f1_start = findfirst(l -> contains(l, "(func (;1;)"), lines)
    if f1_start !== nothing
        println("--- func_1: lines with call/externref/struct ---")
        n = 0
        for i in f1_start:length(lines)
            line = strip(lines[i])
            if contains(line, "call ") || contains(line, "externref") || contains(line, "extern.") || contains(line, "local.get 2")
                println("L$i: $line")
                n += 1
            end
            if contains(line, "(func (;2;)")
                break
            end
            if n > 50
                break
            end
        end
    end

    println()
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end
    if !ok
        println(String(take!(errbuf)))
    end
    rm(tmpf; force=true)
end

main()
