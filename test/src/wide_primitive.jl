# A primitive type of 128 bits that is no Int128 (src/julia/classes.jl type_expand_integer): Julia's codegen gives it
# the LLVM type i128 (julia/src/cgutils.cpp:668 bitstype_to_llvm), which LLVM's wasm type legalizer expands into two
# i64 halves (TypeExpandInteger) as it does Int128's, so its class is the struct of the two halves and every
# operation on it is the expanded i128's. Each answer is compared with native Julia's.
module WidePrimitiveTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module WideCases
primitive type P128 128 end
primitive type P96 96 end
const KP = Core.bitcast(P128, Int128(-7) << 70)
# k selects the case
function wide(k::Int64, n::Int64)::Int64
    local x = Core.bitcast(P128, Int128(n) << 64 | Int128(n))
    if k == 1       # bitcast there and back: the halves kept
        return Int64(Core.bitcast(Int128, Core.bitcast(P128, Int128(n))))
    elseif k == 2   # its own integer arithmetic, i128's: add, mul, shifts, compares
        local y = Core.Intrinsics.add_int(x, Core.Intrinsics.mul_int(x, x))
        local z = Core.Intrinsics.lshr_int(y, 67)
        return Int64(Core.bitcast(UInt128, z) % UInt64 % Int64) + Int64(Core.Intrinsics.ult_int(x, y))
    elseif k == 3   # a constant of the class: its literal's halves
        return Int64((Core.bitcast(Int128, KP) >> 64) % Int64) + n
    else            # compared by ===, its bits (a Memory of it is Memory{Int128}'s gap: 16-byte elements, no storage class)
        local x2 = Core.bitcast(P128, Core.bitcast(Int128, x) + Int128(0))
        return Int64(x === x2) + 2 * Int64(x !== Core.bitcast(P128, Int128(n + 1)))
    end
end
narrow96(n::Int64)::Int64 = Int64(Core.bitcast(Int64, Core.Intrinsics.trunc_int(Int64, Core.Intrinsics.zext_int(P96, n))))
end

const WC = WideCases

@testset "a 128-bit primitive type is two i64 halves, as Int128" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(WC.wide, (Int64(1), Int64(1)))
    local args = [(Int64(k), n) for k in 1:4 for n in (Int64(3), Int64(-5), typemax(Int64))]
    local cases = [Main.WTChild.RunCase("wide_primitive/wide$a", plain, a, Main.WTChild.native_answer(WC.wide, a); optimized = opt) for a in args]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # another width past 64 bits is no class of halves: refused, located
    local e = try; WasmTarget.compile(WC.narrow96, (Int64,)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && occursin("P96", sprint(showerror, e))
end

end # module
