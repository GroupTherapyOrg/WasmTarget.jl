#!/usr/bin/env julia
# Diagnose fix_broken_select_instructions validation error
# This function takes Vector{UInt8} and returns Vector{UInt8}
# It's simpler than the register_* functions so easier to debug
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Compile
bytes = WasmTarget.compile_multi([(WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Written: $tmpf ($(length(bytes)) bytes)")

# Count functions
print_buf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=print_buf))
wasm_text = String(take!(print_buf))
func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
println("Functions: $func_count")

# Validate with details
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

    # Use wasm-tools dump to find the problematic instruction
    offset_match = match(r"at offset (0x[0-9a-f]+)", err)
    if offset_match !== nothing
        offset = offset_match[1]
        println("\nDumping around offset $offset:")
        dump_buf = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
            dump_text = String(take!(dump_buf))
            # Find lines near the offset
            for line in split(dump_text, '\n')
                if contains(line, offset) || contains(line, string("0x", lstrip(offset[3:end], '0')))
                    println("  ", line)
                end
            end
        catch e
            println("  dump failed: $e")
        end
    end
end
