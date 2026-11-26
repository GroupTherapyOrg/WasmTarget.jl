# A branch on a value of a type other than Bool (julia/src/codegen.cpp:6117 emit_condition, src/code_generator.jl
# branch_if): checked against Bool, raising TypeError(:if, "", Bool, value) where it is none, else unboxed as a Bool.
# Each case's answer is native Julia's, compared in both modules; the TypeError's func, expected and got are read back.
module BranchConditionTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module CondCases
struct Cmp; v::Int64; end
# Bool where the receiver's field is 2, else the Int64 field itself: a Union{Bool,Int64} condition
@noinline lt(a::Cmp, b::Cmp) = a.v == 2 ? (a.v < b.v) : a.v
@noinline maybe_bool(x::Int64) = x > 0 ? nothing : iseven(x)
caught(e, x) = e isa TypeError ? (e.func === :if && e.expected === Bool && e.got === x ? Int64(100) : Int64(101)) : Int64(-2)
cond_union(x::Int64) = try; if lt(Cmp(x), Cmp(3)); Int64(1); else; Int64(2); end; catch e; caught(e, x); end
cond_nothing(x::Int64) = try; maybe_bool(x) ? Int64(1) : Int64(2); catch e; caught(e, nothing); end
end

const CC = CondCases

@testset "a branch on a value of a type other than Bool" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((CC.cond_union, (2, 5)), (CC.cond_nothing, (1, -4, -3)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("branch_condition/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: Bool true, then TypeError(:if, "", Bool, 5); nothing's TypeError, then true, then false
    @test [c.native for c in cases] == [1, 100, 100, 1, 2]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
