#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@eval const Compiler = Core.Compiler
@eval const IRCode = Core.Compiler.IRCode

f = Compiler.compact!
arg_types = (IRCode, Bool)
bytes = compile(f, arg_types)
println("Compiled: $(length(bytes)) bytes")

function run_diag(bytes)
    function read_leb(bytes, i)
        val = 0; shift = 0
        while true
            b = bytes[i]; i += 1
            val |= (b & 0x7f) << shift; shift += 7
            (b & 0x80) == 0 && break
        end
        return val, i
    end
    function skip_leb(bytes, j)
        while j <= length(bytes) && (bytes[j] & 0x80) != 0; j += 1; end
        return j + 1
    end
    
    # Find code section
    idx = 9
    code_section_start = 0
    while idx <= length(bytes)
        section_id = bytes[idx]; idx += 1
        section_size, idx = read_leb(bytes, idx)
        if section_id == 10
            code_section_start = idx
            break
        end
        idx += section_size
    end
    println("Code section at 0x$(string(code_section_start-1, base=16))")
    
    num_funcs, idx = read_leb(bytes, code_section_start)
    println("Num functions: $num_funcs")
    
    # Find all function bodies
    func_starts = Int[]
    tmp = idx
    for fi in 1:num_funcs
        push!(func_starts, tmp)
        fsize, tmp2 = read_leb(bytes, tmp)
        tmp = tmp2 + fsize
    end
    
    # func_4 (0-indexed) = index 5 (1-indexed)
    func4_i = func_starts[5]
    func4_size, func4_body_i = read_leb(bytes, func4_i)
    func4_end_i = func4_body_i + func4_size
    
    println("func_4: body starts at 0x$(string(func4_body_i-1, base=16)), size=$func4_size, body ends at 0x$(string(func4_end_i-2, base=16))")
    
    # Skip locals
    j = func4_body_i
    num_local_groups, j = read_leb(bytes, j)
    for _ in 1:num_local_groups
        _, j = read_leb(bytes, j)
        j += 1
    end
    println("Code starts at 0x$(string(j-1, base=16))")
    
    depth = 0
    target_lo, target_hi = 0x33c0, 0x3420
    
    while j < func4_end_i
        off = j - 1
        b = bytes[j]; j += 1
        in_region = off >= target_lo && off <= target_hi
        
        if b in (0x02, 0x03, 0x04)
            j += 1  # skip block type
            depth += 1
            if in_region || depth <= 1
                name = b==0x02 ? "BLOCK" : b==0x03 ? "LOOP" : "IF"
                println("  0x$(string(off, base=16)): $name depth→$depth")
            end
        elseif b == 0x05
            if in_region; println("  0x$(string(off, base=16)): ELSE depth=$depth"); end
        elseif b == 0x0b
            depth -= 1
            if in_region || depth <= 0
                println("  0x$(string(off, base=16)): END depth→$depth")
            end
            if depth < 0
                println("  *** FUNCTION BODY END at 0x$(string(off, base=16)) ***")
                remaining = func4_end_i - j
                println("  *** $remaining bytes remaining after outermost END ***")
                for k in j:min(j+15, func4_end_i-1)
                    println("    0x$(string(k-1, base=16)): 0x$(string(bytes[k], base=16))")
                end
                return
            end
        elseif b == 0x0c
            tgt, j = read_leb(bytes, j)
            if in_region; println("  0x$(string(off, base=16)): BR $tgt depth=$depth"); end
        elseif b == 0x0d
            tgt, j = read_leb(bytes, j)
            if in_region; println("  0x$(string(off, base=16)): BR_IF $tgt depth=$depth"); end
        elseif b == 0x0f
            if in_region || depth <= 1; println("  0x$(string(off, base=16)): RETURN depth=$depth"); end
        elseif b == 0x00
            if in_region; println("  0x$(string(off, base=16)): UNREACHABLE depth=$depth"); end
        else
            if b in (0x20, 0x21, 0x22, 0x23, 0x24, 0x10, 0x41, 0x42, 0xd2)
                j = skip_leb(bytes, j)
            elseif b == 0x43; j += 4
            elseif b == 0x44; j += 8
            elseif b == 0xd0; j += 1
            elseif b == 0xfc
                sub = bytes[j]; j += 1
                j = skip_leb(bytes, j)
            elseif b == 0xfb
                sub = bytes[j]; j += 1
                if sub in (0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d)
                    j = skip_leb(bytes, j); j = skip_leb(bytes, j)
                elseif sub in (0x00, 0x01, 0x0e, 0x0f, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x20, 0x21, 0x22, 0x23)
                    j = skip_leb(bytes, j)
                end
            end
        end
    end
    println("Reached end of func body without depth=-1 (function ends with RETURN/UNREACHABLE)")
end

run_diag(bytes)
