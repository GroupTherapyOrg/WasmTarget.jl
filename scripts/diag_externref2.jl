using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Use register_tuple_type! — it's small and has the externref error
func = WasmTarget.register_tuple_type!
arg_types = (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}})

bytes = WasmTarget.compile_multi([(func, arg_types)])
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

err = strip(String(take!(errbuf)))
if !ok
    println("ERROR: $err")
    m = match(r"at offset (0x[0-9a-f]+)", err)
    fm = match(r"func (\d+) failed", err)
    if m !== nothing && fm !== nothing
        offset = m[1]
        func_num = fm[1]
        println("Func: $func_num, Offset: $offset")
        
        # Dump around offset
        dumpbuf = IOBuffer()
        Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
        dump_lines = split(String(take!(dumpbuf)), '\n')
        
        offset_int = parse(Int, offset[3:end]; base=16)
        
        # Find the error region
        for (i, line) in enumerate(dump_lines)
            lm = match(r"^\s*(0x[0-9a-f]+)", line)
            if lm !== nothing
                lo = parse(Int, lm[1][3:end]; base=16)
                if abs(lo - offset_int) <= 40
                    start_idx = max(1, i - 15)
                    end_idx = min(length(dump_lines), i + 5)
                    for j in start_idx:end_idx
                        marker = (lo == offset_int && j == i) ? " <<<ERROR" : ""
                        println("  $(dump_lines[j])$marker")
                    end
                    break
                end
            end
        end
    end
else
    println("VALIDATES!")
end
rm(tmpf; force=true)
