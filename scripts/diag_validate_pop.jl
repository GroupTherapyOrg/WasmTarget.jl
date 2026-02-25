#!/usr/bin/env julia
# diag_validate_pop.jl — PURE-6025
# Diagnose the VALIDATE_ERROR in validate_pop!(WasmStackValidator, NumType)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget

println("=== Diagnosing validate_pop! VALIDATE_ERROR ===")
flush(stdout)

# Compile
bytes = WasmTarget.compile_multi([(WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, WasmTarget.NumType))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Validate
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES")
catch
    err_msg = String(take!(errbuf))
    println("VALIDATE_ERROR:")
    println(err_msg)
end

# Get WAT
printbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=printbuf))
wat = String(take!(printbuf))

func_count = count(l -> contains(l, "(func "), split(wat, '\n'))
println("\nFunctions: $func_count, Size: $(length(bytes)) bytes")

# Print function signatures
println("\nFunction signatures:")
for line in split(wat, '\n')
    if contains(line, "(func ") || contains(line, "(export ")
        println("  ", strip(line))
    end
end

# Find the failing func and print it
println("\nSearching for func 1...")
lines = split(wat, '\n')
func_num = 0
printing = false
for line in lines
    if contains(line, "(func ")
        func_num += 1
        if func_num == 2  # func 1 in wasm-tools numbering = second func (0-indexed)
            printing = true
            println("=== func 1 (wasm-tools numbering) ===")
        elseif printing
            break
        end
    end
    if printing
        println(line)
    end
end

rm(tmpf; force=true)
