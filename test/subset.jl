# The strict subset's entry (src/julia/subset.jl): the closed world is inferred from the specialization
# Julia compiles for the call, its compileable signature, as juliac's entrypoint takes it, never the
# call's own argument types where Julia widens them.
using Test
using WasmTarget

module SubsetCases
f(@nospecialize(x)) = x
k(xs...) = length(xs)
g(x::Int) = x + 1
# Base.depwarn, which juliac --trim stubs out before it verifies (juliac-trim-base.jl) and WT does not
dw(x::Int) = (Base.depwarn("old", :dw); x)
end

# the specialization types of the CodeInstances a closed world holds
_spec_types(w) = [Core.Compiler.get_ci_mi(c).specTypes for c in w.codeinfos if c isa Core.CodeInstance]

@testset "check_subset: the entry is Julia's compileable specialization" begin
    local S = SubsetCases
    # a @nospecialize argument: Julia compiles f for Any, not for Int
    local wf = _spec_types(WasmTarget.check_subset(S.f, (Int,), "subset"))
    @test Tuple{typeof(S.f), Any} in wf
    @test !(Tuple{typeof(S.f), Int} in wf)
    # five varargs: Julia compiles k for one Int and a Vararg of any count, not for exactly five
    local wk = _spec_types(WasmTarget.check_subset(S.k, (Int, Int, Int, Int, Int), "subset"))
    @test Tuple{typeof(S.k), Int, Vararg{Int}} in wk
    @test !(Tuple{typeof(S.k), Vararg{Int, 5}} in wk)
    # a signature Julia compiles as written stays as written
    @test Tuple{typeof(S.g), Int} in _spec_types(WasmTarget.check_subset(S.g, (Int,), "subset"))
    # no method: Julia's `which` text, located
    local r = try
        WasmTarget.check_subset(S.g, (String,), "subset"); nothing
    catch e
        e isa WasmTarget.RejectionError ? e.rejection : rethrow()
    end
    @test r isa WasmTarget.OutsideSubset
end

@testset "check_subset: Julia's verifier over unmodified Base, smaller than juliac's subset" begin
    # juliac verifies after patching Base (depwarn a no-op); WT verifies Base as it is, so the call
    # juliac accepts is outside WT's subset, located
    local r = try
        WasmTarget.check_subset(SubsetCases.dw, (Int,), "subset"); nothing
    catch e
        e isa WasmTarget.RejectionError ? e.rejection : rethrow()
    end
    @test r isa WasmTarget.OutsideSubset
end
