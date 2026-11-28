# min, max and clamp of IEEE floats with NaN operands, against native Julia, asserting exactly what Julia's own source
# fixes, on every host:
# - min and max of two IEEE floats are the intrinsics min_float and max_float (julia/base/math.jl:834-840, `return
#   min_float(x, y)`), LLVM's llvm.minimum and llvm.maximum (julia/src/intrinsics.cpp:1517, :1522). Where neither
#   operand is a NaN the result is exact, its bits fixed (-0.0 below +0.0). Where the result is a NaN, LLVM leaves its
#   sign, quiet bit and payload to the operation: "the result has a non-deterministic sign; the quiet bit and payload
#   are non-deterministically chosen" (llvm/docs/LangRef.md:4241-4243 at the llvm pin, "on wasm ... this set contains
#   all possible payloads", :4251-4254), so only isnan is Julia's answer there, and the answer below encodes a NaN
#   result as one value, never its bits.
# - clamp (julia/base/intfuncs.jl:1338: `(x > hi) ? convert(T, hi) : (x < lo) ? convert(T, lo) : convert(T, x)`) only
#   compares and returns one operand unchanged, so its bits are fixed, a NaN's included.
module MinMaxNanTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module MinMaxCases
# the operands, by index: quiet NaNs of two payloads and both signs, a signalling NaN of each sign, numbers (±0 too)
const B64 = UInt64[0x7ff8000000000001, 0x7ff8000000000abc, 0xfff8000000000002, 0x7ff0000000000005, 0xfff0000000000007,
                   0x3ff0000000000000, 0xc000000000000000, 0x0000000000000000, 0x8000000000000000]
const B32 = UInt32[0x7fc00001, 0x7fc00abc, 0xffc00002, 0x7f800005, 0xff800007, 0x3f800000, 0xc0000000, 0x00000000, 0x80000000]
# a min or max result: -1 for any NaN (whose bits LLVM leaves open), else its bits, which no NaN's are
fixed(r::Float64)::Int64 = isnan(r) ? Int64(-1) : reinterpret(Int64, r)
fixed(r::Float32)::Int64 = isnan(r) ? Int64(-1) : Int64(reinterpret(Int32, r))
# k: 1 min Float64, 2 max Float64, 3 min Float32, 4 max Float32, 5 clamp Float64 (bits), 6 clamp Float32 (bits); i
# and j index the operands (read at run time, so no fold)
function mm(k::Int64, i::Int64, j::Int64)::Int64
    local a, b = reinterpret(Float64, B64[i]), reinterpret(Float64, B64[j])
    local c, d = reinterpret(Float32, B32[i]), reinterpret(Float32, B32[j])
    k == 1 && return fixed(min(a, b))
    k == 2 && return fixed(max(a, b))
    k == 3 && return fixed(min(c, d))
    k == 4 && return fixed(max(c, d))
    k == 5 && return reinterpret(Int64, clamp(a, b, 4.0))
    return Int64(reinterpret(Int32, clamp(c, d, 4.0f0)))
end
end

const MC = MinMaxCases

@testset "min, max and clamp with NaN operands: what Julia's source fixes" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(MC.mm, (Int64(1), Int64(1), Int64(2)))
    local n = length(MC.B64)
    local args = [(Int64(k), Int64(i), Int64(j)) for k in 1:6 for i in 1:n for j in 1:n if i <= 5 || j <= 5]
    local cases = [Main.WTChild.RunCase("minmax_nan/mm$a", plain, a, Main.WTChild.native_answer(MC.mm, a); optimized = opt) for a in args]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
