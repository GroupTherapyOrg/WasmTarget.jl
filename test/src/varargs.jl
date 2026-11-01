# A varargs method's trailing arguments reach its body as one tuple (src/julia/nir.jl NirVarargPacking),
# its type Julia's own, Core.Compiler.va_process_argtypes: a specialization of a fixed count takes each
# argument as a parameter and packs them at entry (Julia's specsig, codegen.cpp's emit_new_struct); one
# of an open count takes the tuple as one parameter, which the call packs from its operands (Julia's
# jl_f_tuple over the argument array, moved to the caller, a wasm function's arity being fixed).

module VarargsTest

using Test
using WasmTarget

const W = WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTRunner = Main.WTRunner

module Cases
# Julia leaves a varargs call's count open unless the method names it (Vararg{T,N} where N)
@noinline g(a::Int, xs::Int...) = a + length(xs) + xs[1]
@noinline gn(a::Int, xs::Vararg{Int,N}) where {N} = a + N + xs[1] * xs[2]
h(x::Int) = g(x, 2, 3) + gn(x, 2, 3)
# a fixed count: gn's tail packed at its entry into the Tuple{Int,Int} its body reads
fixed(x::Int) = gn(x, x + 1, 3)
# an open count: g's tail packed by the call into the Tuple{Int,Int} passed as its one parameter
open_count(x::Int) = g(x, 2, 3)
cat3(a::String, b::String, c::String) = string(a, b, c)
end

world_of(f, at) = W.build_nir(W.check_subset(f, at, "varargs"), "varargs")
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

@testset "varargs: Julia's packing of a varargs method's trailing arguments" begin
    # a specialization of a fixed count (gn names its count): each argument its own parameter, packed at entry
    local hw = world_of(Cases.h, (Int,))
    local gn = only(b.ci.def for b in hw if b.ci.def.def.name === :gn)
    local gp = W.nir_vararg_packing(gn)
    @test gp.first == 3 && gp.packed === Tuple{Int,Int} && gp.at_entry
    @test W.nir_parameter_types(gn) == Type[typeof(Cases.gn), Int, Int, Int]
    @test W.nir_argument_type(gn, W.NirArgument(3)) === Tuple{Int,Int} && W.nir_method_nargs(gn) == 3
    # g leaves its count open: its trailing arguments one packed parameter, Julia's tuple type
    local g = only(b.ci.def for b in hw if b.ci.def.def.name === :g)
    local gt = W.nir_parameter_types(g)
    @test length(gt) == 3 && gt[2] === Int && Base.isvatuple(gt[3]) && !W.nir_vararg_packing(g).at_entry
    # string(a, b, c) calls Base._string of an open count: the packed parameter Julia's own tuple type
    local cw = world_of(Cases.cat3, (String, String, String))
    local open = [b.ci.def for b in cw if (local p = W.nir_vararg_packing(b.ci.def); p !== nothing && !p.at_entry)]
    @test !isempty(open)
    for mi in open
        local m = mi.def::Method
        local p = W.nir_vararg_packing(mi)
        local julia = Core.Compiler.widenconst(Core.Compiler.va_process_argtypes(Core.Compiler.fallback_lattice,
            Core.Compiler.most_general_argtypes(m, mi.specTypes), UInt(m.nargs), true)[m.nargs])
        @test p.first == m.nargs && p.packed === julia
        @test last(W.nir_parameter_types(mi)) === julia && length(W.nir_parameter_types(mi)) == m.nargs
    end
    # a method with no varargs packs nothing
    @test W.nir_vararg_packing(only(b.ci.def for b in hw if b.ci.def.def.name === :h)) === nothing
end

@testset "varargs: a fixed count packs at entry and answers as native Julia" begin
    local f = Cases.fixed
    local bytes = W.compile(f, (Int,))
    for r in WTRunner.run_cases([WTRunner.RunCase("fixed$(a)", bytes, a, f(a...)) for a in [(1,), (0,), (-7,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

@testset "varargs: an open count packs at the call; the body's read of a tuple only run time sizes rejects, located" begin
    # the call packs (no rejection names the signature); the body reads the abstract Tuple{Vararg{Int}}
    # by nfields and a run-time index, which WasmTarget's struct-per-class tuples cannot yet answer
    for (f, at) in ((Cases.open_count, (Int,)), (Cases.cat3, (String, String, String)))
        local e = rejection(() -> W.compile(f, at))
        @test e !== nothing && !occursin("Vararg signature", sprint(showerror, e)) &&
            !occursin("varargs specialization", sprint(showerror, e)) && e.rejection isa Union{W.Unquarantined, W.Unported}
    end
end

end
