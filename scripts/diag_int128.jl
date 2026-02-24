#!/usr/bin/env julia
# Diagnose Int128 codegen bug in WasmTarget.jl
# The ParseStream constructor uses Int128 arithmetic for IOBuffer seek positioning.
# If Int128 sext/add/trunc is buggy, the truncation check falsely throws.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Test functions that exercise Int128 operations
# These match the patterns in ParseStream's IOBuffer seek code

# Test 1: Simple Int128 round-trip (sext → trunc)
function test_int128_roundtrip(x::Int64)::Int64
    # This is what ParseStream does:
    # sext to Int128, then trunc back to Int64
    x128 = Core.sext_int(Core.Int128, x)
    result = Core.trunc_int(Int64, x128)
    return result
end

# Test 2: Int128 addition then truncation
function test_int128_add_trunc(a::Int64, b::Int64)::Int64
    a128 = Core.sext_int(Core.Int128, a)
    b128 = Core.sext_int(Core.Int128, b)
    sum128 = Base.add_int(a128, b128)
    result = Core.trunc_int(Int64, sum128)
    return result
end

# Test 3: The exact ParseStream pattern (offset + position + 1)
function test_parsestream_seek(offset::Int64, position::Int64)::Int64
    off128 = Core.sext_int(Core.Int128, offset)
    pos128 = Core.sext_int(Core.Int128, position)
    sum128 = Base.add_int(off128, pos128)
    sum_plus_1 = Base.add_int(sum128, Core.sext_int(Core.Int128, Int64(1)))

    # Check if result fits in Int64 (the truncation check)
    if Base.slt_int(Int128(9223372036854775807), sum_plus_1)
        return Int64(9223372036854775807)  # overflow
    end
    if Base.slt_int(sum_plus_1, Int128(-9223372036854775808))
        return Int64(-9223372036854775808)  # underflow
    end

    truncated = Core.trunc_int(Int64, sum_plus_1)
    roundtrip = Core.sext_int(Core.Int128, truncated)
    if !Core.eq_int(sum_plus_1, roundtrip)
        return Int64(-1)  # inexact error (this is what ParseStream throws on)
    end
    return truncated
end

# Native ground truth
println("=== Native Ground Truth ===")
for x in [0, 1, 3, 100, -1]
    r = test_int128_roundtrip(Int64(x))
    println("  roundtrip($x) = $r ($(r == x ? "CORRECT" : "WRONG"))")
end
println()

for (a, b) in [(0, 0), (0, 1), (1, 0), (1, 1), (3, 0)]
    r = test_int128_add_trunc(Int64(a), Int64(b))
    expected = a + b
    println("  add_trunc($a, $b) = $r (expected $expected, $(r == expected ? "CORRECT" : "WRONG"))")
end
println()

for (off, pos) in [(0, 0), (0, 1), (1, 0)]
    r = test_parsestream_seek(Int64(off), Int64(pos))
    expected = off + pos + 1
    println("  seek($off, $pos) = $r (expected $expected, $(r == expected ? "CORRECT" : "WRONG"))")
end
println()

# Compile each to WASM and test
println("=== Compiling to WASM ===")
for (name, func, args) in [
    ("roundtrip", test_int128_roundtrip, (Int64,)),
    ("add_trunc", test_int128_add_trunc, (Int64, Int64)),
    ("seek", test_parsestream_seek, (Int64, Int64)),
]
    print("  $name: ")
    try
        bytes = WasmTarget.compile(func, args)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        errbuf = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf))
            println("$(length(bytes)) bytes, VALIDATES")
        catch
            println("VALIDATE_ERROR: $(String(take!(errbuf)))")
        end
    catch e
        println("COMPILE ERROR: $e")
    end
end
