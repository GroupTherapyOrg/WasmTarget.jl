#!/usr/bin/env julia
# Find exact instruction at validation error offset
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Test small failing functions
funcs_to_test = [
    ("is_self_referential_type", WasmTarget.is_self_referential_type, (DataType,)),
    ("get_nullable_inner_type", WasmTarget.get_nullable_inner_type, (Union,)),
]

for (name, func, arg_types) in funcs_to_test
    println("\n=== $name ===")
    local bytes
    try
        bytes = WasmTarget.compile_multi([(func, arg_types)])
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e)[1:min(200,end)])")
        continue
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
        continue
    end

    err = strip(String(take!(errbuf)))
    println("ERROR: $err")

    # Get WAT and search near the error
    m = match(r"at offset (0x[0-9a-f]+)", err)
    fm = match(r"func (\d+) failed", err)
    if m === nothing || fm === nothing
        rm(tmpf; force=true)
        continue
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
        
        for (i, line) in enumerate(lines)
            lm = match(r"^\s*(0x[0-9a-f]+)", line)
            if lm !== nothing
                line_offset = parse(Int, lm[1][3:end]; base=16)
                if abs(line_offset - offset_int) <= 30
                    start_idx = max(1, i - 10)
                    end_idx = min(length(lines), i + 10)
                    for j in start_idx:end_idx
                        marker = (line_offset == offset_int && j == i) ? " <<<ERROR" : ""
                        println("  $(lines[j])$marker")
                    end
                    println()
                    break
                end
            end
        end
    catch e
        println("Dump failed: $e")
    end

    rm(tmpf; force=true)
end
