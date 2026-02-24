#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function test_int128_roundtrip(x::Int64)::Int64
    x128 = Core.sext_int(Core.Int128, x)
    result = Core.trunc_int(Int64, x128)
    return result
end

function test_int128_add_trunc(a::Int64, b::Int64)::Int64
    a128 = Core.sext_int(Core.Int128, a)
    b128 = Core.sext_int(Core.Int128, b)
    sum128 = Base.add_int(a128, b128)
    result = Core.trunc_int(Int64, sum128)
    return result
end

function test_parsestream_seek(offset::Int64, position::Int64)::Int64
    off128 = Core.sext_int(Core.Int128, offset)
    pos128 = Core.sext_int(Core.Int128, position)
    sum128 = Base.add_int(off128, pos128)
    sum_plus_1 = Base.add_int(sum128, Core.sext_int(Core.Int128, Int64(1)))
    if Base.slt_int(Int128(9223372036854775807), sum_plus_1)
        return Int64(9223372036854775807)
    end
    if Base.slt_int(sum_plus_1, Int128(-9223372036854775808))
        return Int64(-9223372036854775808)
    end
    truncated = Core.trunc_int(Int64, sum_plus_1)
    roundtrip = Core.sext_int(Core.Int128, truncated)
    if !Core.eq_int(sum_plus_1, roundtrip)
        return Int64(-1)
    end
    return truncated
end

# Compile each and write to output
for (name, func, args) in [
    ("roundtrip", test_int128_roundtrip, (Int64,)),
    ("add_trunc", test_int128_add_trunc, (Int64, Int64)),
    ("seek", test_parsestream_seek, (Int64, Int64)),
]
    bytes = WasmTarget.compile(func, args)
    outf = joinpath(@__DIR__, "..", "output", "test_int128_$(name).wasm")
    write(outf, bytes)
    println("$name: $(length(bytes)) bytes → $outf")
end
