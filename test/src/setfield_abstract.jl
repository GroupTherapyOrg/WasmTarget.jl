# Core.setfield! on a receiver Julia's inference left abstract (a field selector's setter, src/dispatch_table.jl) of a
# value whose Julia type is not the target class's declared field type: Julia's jl_f_setfield checks the value against
# the object's own field type and raises TypeError (julia/src/builtins.c jl_f_setfield, jl_type_error_rt), never
# storing it. Two classes whose fields share a wasm type (an Int64 field and a UInt64 field, each i64) are where a
# store could take the bits unchecked. Each answer is native Julia's.
module SetfieldAbstractTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module SetCases
abstract type AB end
mutable struct S1 <: AB; f::Int64; end
mutable struct S2 <: AB; f::UInt64; end
@noinline pick(k::Int64)::AB = k > 0 ? S1(1) : S2(UInt64(2))
# k > 0: an Int64 into S1's Int64 field (stored); k <= 0: an Int64 into S2's UInt64 field (natively a TypeError)
function store(k::Int64, v::Int64)::Int64
    local x = pick(k)
    try
        Core.setfield!(x, :f, v)
    catch e
        return e isa TypeError ? -1 : -2
    end
    return x isa S1 ? x.f : reinterpret(Int64, (x::S2).f)
end
end

const SC = SetCases

@testset "setfield! on an abstract receiver checks the value against each class's field type" begin
    @test SC.store(1, 7) == 7 && SC.store(-1, 7) == -1
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(SC.store, (Int64(1), Int64(7)))
    local cases = [Main.WTChild.RunCase("setfield_abstract/store$a", plain, a, Main.WTChild.native_answer(SC.store, a); optimized = opt)
                   for a in ((Int64(1), Int64(7)), (Int64(-1), Int64(7)))]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
