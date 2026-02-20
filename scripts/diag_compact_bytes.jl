#!/usr/bin/env julia
# diag_compact_bytes.jl — Show raw bytes around offset 0x33f6 in compact! wasm
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

# Show raw bytes around 0x33f6 = 13302
target_offset = 0x33f6
start = max(1, target_offset - 30)
stop = min(length(bytes), target_offset + 30)

println("Raw bytes at 0x$(string(start-1, base=16))-0x$(string(stop-1, base=16)):")
for i in start:stop
    off_hex = string(i-1, base=16; pad=4)
    byte_hex = string(bytes[i], base=16; pad=2)
    marker = (i-1) == target_offset ? "<<<ERROR" : ""
    println("  0x$off_hex: 0x$byte_hex  $marker")
end

# Decode the instruction at the error offset
println()
println("Decoding instruction at 0x33f6 = $(target_offset):")
idx = target_offset + 1  # 1-indexed
if idx <= length(bytes)
    b = bytes[idx]
    println("  opcode: 0x$(string(b, base=16))")
    if b == 0x0b
        println("  -> END opcode!")
    elseif b == 0x20
        println("  -> local.get (index follows)")
        if idx+1 <= length(bytes)
            n = Int(bytes[idx+1]) & 0x7f
            if (bytes[idx+1] & 0x80) != 0 && idx+2 <= length(bytes)
                n |= (Int(bytes[idx+2]) & 0x7f) << 7
                println("  -> local.get $(n) (2-byte LEB)")
            else
                println("  -> local.get $(n) (1-byte LEB)")
            end
        end
    elseif b == 0xd0
        println("  -> ref.null (type follows)")
        if idx+1 <= length(bytes)
            t = bytes[idx+1]
            println("  -> ref.null type=0x$(string(t, base=16))")
        end
    elseif b == 0x0f
        println("  -> return opcode!")
    else
        println("  -> other opcode")
    end
end

# Show the last 50 bytes of the function body
println()
println("Last 50 bytes of wasm ($(max(1,length(bytes)-49)) to $(length(bytes))):")
for i in max(1, length(bytes)-49):length(bytes)
    b = bytes[i]
    marker = b == 0x0b ? "END" : b == 0x0f ? "RETURN" : b == 0x00 ? "UNREACHABLE" : ""
    println("  byte $(i): 0x$(string(b, base=16; pad=2)) $marker")
end
