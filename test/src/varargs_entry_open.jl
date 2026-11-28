# A varargs specialization of a fixed count whose packed tuple's class only run time knows: Julia's codegen packs it at entry
# by jl_f_tuple over the parameters (julia/src/codegen.cpp:8859, its non-concrete arm), here the record of its arity, as a
# call packs an open count (src/code_generator.jl _setupLocalParameters, _visitArguments). Base.kwerr, which a keyword a
# method does not take reaches, is one: Julia specializes it to the call's count with a Function element. Each case's
# answer is native Julia's, compared in both modules.
module VarargsEntryOpenTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const W = WasmTarget

module EntryOpenCases
struct ArgA
    nonce::Int64
end
kw_f(a1::String, a2::Int64, a3::ArgA; n1::String = "d", n2::Int64 = -1) = ncodeunits(a1) + a2 + a3.nonce + ncodeunits(n1) + n2
kw_try(g) = try; g(); Int64(0); catch e; e isa MethodError ? Int64(1) : Int64(3); end
# keywords kw_f does not take: Base.kwerr, its tail a Tuple{Function, String, Int64, ArgA} packed at entry
function unknown_keyword(n::Int64)::Int64
    local f = kw_f
    return kw_try(() -> f("abc", n, ArgA(1), n4 = 4)) * 10 + kw_try(() -> f("abc", n, ArgA(1), n1 = "x", n4 = n)) +
           100 * kw_f("abc", n, ArgA(2); n2 = n)
end
end

const EC = EntryOpenCases

@testset "a varargs tuple whose class only run time knows packs at entry" begin
    # the specialization the case reaches packs at entry and its tuple type is not concrete
    local world = W.build_nir(W.check_subset(EC.unknown_keyword, (Int64,), "varargs_entry_open", Base.get_world_counter()), "varargs_entry_open")
    local kwerr = [b.ci.def for b in world if b.ci.def.def isa Method && b.ci.def.def.name === :kwerr]
    @test !isempty(kwerr)
    @test any(mi -> (va = W.nir_vararg_packing(mi); va !== nothing && va.at_entry && !isconcretetype(va.packed)), kwerr)
    local cases = Main.WTChild.RunCase[]
    local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, EC.unknown_keyword, (Int64(1),))
    for x in (1, 2)
        push!(cases, Main.WTChild.RunCase("varargs_entry_open/unknown_keyword($x)", p, (Int64(x),), Main.WTChild.native_answer(EC.unknown_keyword, (Int64(x),)); optimized = o))
    end
    @test [c.native for c in cases] == [11 + 100 * (3 + 1 + 2 + 1 + 1), 11 + 100 * (3 + 2 + 2 + 1 + 2)]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
