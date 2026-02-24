#!/usr/bin/env julia
# Diagnose compact! block structure at error offset 0x33f6
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@eval const Compiler = Core.Compiler
@eval const IRCode = Core.Compiler.IRCode

f = Compiler.compact!
arg_types = (IRCode, Bool)
println("Compiling compact! ...")
bytes = compile(f, arg_types)
println("Compiled: $(length(bytes)) bytes")

# Decode the block structure starting from the beginning of func_4
# We need to find where func_4 starts in the binary
# The WASM binary has: magic (4), version (4), sections...
# We'll parse the code section to find func_4's offset

# Instead, decode bytes around 0x33f6 backwards to find block structure
# Scan for BLOCK/LOOP/IF/END opcodes in the region 0x3300-0x3413
println("\nDecoding instructions in region 0x3300-0x3413:")
i = 0x3301  # 1-indexed (0x3300 = 13056)
opcodes_block = []
while i <= min(0x3413 + 1, length(bytes))
    b = bytes[i]
    offset_hex = string(i - 1, base=16; pad=4)
    
    if b == 0x02
        push!(opcodes_block, (i-1, "BLOCK", 0x40))
        println("  0x$offset_hex: BLOCK (void)")
        i += 1
        if i <= length(bytes) && bytes[i] == 0x40
            i += 1  # skip void type
        end
    elseif b == 0x03
        println("  0x$offset_hex: LOOP (void)")
        push!(opcodes_block, (i-1, "LOOP", 0x40))
        i += 1
        if i <= length(bytes) && bytes[i] == 0x40
            i += 1  # skip void type
        end
    elseif b == 0x04
        println("  0x$offset_hex: IF (void)")
        push!(opcodes_block, (i-1, "IF", 0x40))
        i += 1
        if i <= length(bytes) && bytes[i] == 0x40
            i += 1  # skip void type
        end
    elseif b == 0x05
        println("  0x$offset_hex: ELSE")
        i += 1
    elseif b == 0x0b
        println("  0x$offset_hex: END")
        push!(opcodes_block, (i-1, "END", 0))
        i += 1
    elseif b == 0x0c
        println("  0x$offset_hex: BR 0x$(string(bytes[i+1], base=16))")
        i += 2  # BR + target
    elseif b == 0x0d
        println("  0x$offset_hex: BR_IF 0x$(string(bytes[i+1], base=16))")
        i += 2  # BR_IF + target
    elseif b == 0x0f
        println("  0x$offset_hex: RETURN")
        i += 1
    elseif b == 0x00
        println("  0x$offset_hex: UNREACHABLE")
        i += 1
    else
        # Skip non-control-flow opcodes
        i += 1
    end
end
