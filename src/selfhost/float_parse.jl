# float_parse.jl — Pure Julia replacement for JuliaSyntax.parse_float_literal
#
# PURE-5002: The original parse_float_literal uses raw pointers and ccall(:jl_strtod_c)
# which cannot compile to WasmGC. This override implements float parsing using only
# Vector{UInt8} indexing and arithmetic — patterns WasmTarget already handles.
#
# Usage: include this file AFTER `using JuliaSyntax` but BEFORE compilation.
#   using JuliaSyntax
#   include("src/runtime/float_parse.jl")
#   # Now parse_float_literal compiles to Wasm without ccalls
#
# Handles: decimal (1.0, 3.14), scientific (1e3, 1.5e-2), underscores (1_000.0)
# Does NOT handle: Float32 (1.0f0), hex floats, Inf, NaN

import JuliaSyntax

function JuliaSyntax.parse_float_literal(::Type{T}, str::Union{String, SubString, Vector{UInt8}},
        firstind::Integer, endind::Integer) where T
    val = 0.0
    frac_part = 0.0
    frac_mult = 0.1
    in_frac = false
    negative = false
    exp_val = Int64(0)
    exp_neg = false
    in_exp = false

    i = Int(firstind)
    last_i = Int(endind) - 1
    while i <= last_i
        b = UInt8(str[i])
        if b == 0x5f  # underscore — skip
            i += 1
            continue
        elseif b == 0x2d  # minus '-'
            if in_exp
                exp_neg = true
            else
                negative = true
            end
        elseif b == 0x2b  # plus '+'
            # skip (exponent sign)
        elseif b == 0x2e  # dot '.'
            in_frac = true
        elseif b == 0x65 || b == 0x45  # 'e' or 'E'
            in_exp = true
        elseif 0x30 <= b <= 0x39  # '0'-'9'
            d = Float64(b - 0x30)
            if in_exp
                exp_val = exp_val * Int64(10) + Int64(b - 0x30)
            elseif in_frac
                frac_part += d * frac_mult
                frac_mult *= 0.1
            else
                val = val * 10.0 + d
            end
        end
        i += 1
    end

    val += frac_part
    if negative
        val = -val
    end
    if in_exp
        e = exp_neg ? -exp_val : exp_val
        val *= 10.0^Float64(e)
    end

    return (T(val), :ok)
end
