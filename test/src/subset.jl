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

module SubsetErrors
dyn(x::Int) = Base.inferencebarrier(x) + 1
end

@testset "check_subset: OutsideSubset keeps the verifier's records" begin
    local W = WasmTarget
    local rejection(f, at) = try
        W.check_subset(f, at, "subset"); nothing
    catch e
        e isa W.RejectionError ? e : rethrow()
    end
    # a call inference cannot resolve: Julia's CallMissing, its statement and its stack frames
    local e = rejection(SubsetErrors.dyn, (Int,))
    local o = e.rejection
    @test o isa W.OutsideSubset && length(o.errors) == 1
    local t = only(o.errors)
    @test t.kind == W.unresolved_call
    @test t.codeinst isa Core.CodeInstance && t.stmtidx > 0
    @test t.cause isa WasmTarget.TrimCallMissing && t.cause.record.stmtidx == t.stmtidx
    @test !isempty(t.frames) && t.frames[1].func === :dyn
    # shown in Julia's own words, numbered as juliac numbers them
    @test occursin("Verifier error #1: unresolved call from statement", sprint(showerror, e))
    # an unimplemented builtin and an entry with no method each have their kind
    @test only(rejection(SubsetCases.dw, (Int,)).rejection.errors).kind == W.unimplemented_invoke_in_world
    local nm = only(rejection(SubsetCases.g, (String,)).rejection.errors)
    @test nm.kind == W.no_unique_method && nm.codeinst === nothing && isempty(nm.frames)
    # its text is Julia's `which` text alone, no verifier number
    @test !occursin("Verifier error", sprint(showerror, rejection(SubsetCases.g, (String,))))
    # every description has one kind, and every kind but the entry's two has one description
    local described = collect(values(W.TRIM_ERROR_KINDS))
    @test allunique(described)
    @test Set(described) == Set(k for k in instances(W.TrimErrorKind) if !(k in (W.no_unique_method, W.no_compileable_specialization)))
    # an accepted world keeps the verifier's parents, from which any statement is located
    @test WasmTarget.check_subset(SubsetCases.g, (Int,), "subset").parents isa IdDict
end
