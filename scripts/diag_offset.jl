#!/usr/bin/env julia
# Find exact instruction at validation error offset using wasm-tools dump
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function diagnose(name, func, arg_types)
    println("\n=== $name ===")
    local bytes
    try
        bytes = WasmTarget.compile_multi([(func, arg_types)])
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e)[1:min(200,end)])")
        return
    end
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    println("Size: $(length(bytes)) bytes")

    # Validate
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    if ok
        println("VALIDATES!")
        rm(tmpf; force=true)
        return
    end

    err = strip(String(take!(errbuf)))
    println("ERROR: $err")

    m = match(r"at offset (0x[0-9a-f]+)", err)
    fm = match(r"func (\d+) failed", err)
    if isnothing(m) || isnothing(fm)
        rm(tmpf; force=true)
        return
    end

    offset_hex = m[1]
    offset_int = parse(Int, offset_hex[3:end]; base=16)
    func_num = parse(Int, fm[1])
    println("Offset: $offset_hex ($offset_int), Func: $func_num")

    # Dump bytes around the offset
    dumpbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
        dump_text = String(take!(dumpbuf))
        lines = split(dump_text, '\n')

        # Find the closest line to the target offset
        best_i = 0
        best_off = 0
        for (i, line) in enumerate(lines)
            lm = match(r"^\s*(0x[0-9a-f]+)", line)
            if !isnothing(lm)
                line_off = parse(Int, lm[1][3:end]; base=16)
                if line_off <= offset_int
                    best_i = i
                    best_off = line_off
                end
                if line_off > offset_int + 100
                    break
                end
            end
        end

        if best_i > 0
            lo = max(1, best_i - 20)
            hi = min(length(lines), best_i + 10)
            for j in lo:hi
                marker = j == best_i ? " >>> " : "     "
                println("$marker$(lines[j])")
            end
        else
            println("Could not find offset in dump")
        end
    catch e
        println("Dump failed: $e")
    end

    rm(tmpf; force=true)
end

# Test the simplest failing function first
diagnose("register_struct_type!", WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))
println()
diagnose("register_int128_type!", WasmTarget.register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type))
