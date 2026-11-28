# The landing's float guard: the bit-exact cases of Julia's math kernels a change broke silently. bdd08864 landed 14
# corpus cases answering otherwise than native (exp, expm1, acos, asin, sinh, cosh, hypot, the Float32 exp family,
# muladd_fused) with every landing check green, since test/smoke_corpus.jl's bit_exact_math ran only at a clause's
# closure. One case per kernel it broke is compiled here (codegen's module and wasm-opt's) and run in node against
# native, so a wrong answer there cannot land (D2).
# The cases are the corpus's own, one source (D5): bit_exact_math's group and the definitions it calls are read from
# test/smoke_corpus.jl's text and evaluated in a module of their own. Loading the whole corpus (DartCorpus) would
# redefine Base methods the corpus's types overload, invalidating WasmTarget's compiled pipeline (~174 G instructions
# to compile again, wt3-latency): the same nine cases in test/src/dart_tests.jl, after that load, measured 308 G
# instructions, here 212 G (each after the warm-up compile, at background QoS).
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module FloatGuardCases
const GROUPS = Pair{String,Vector{Any}}[]
_g(name, cases) = push!(GROUPS, name => cases)
end

# the corpus's top-level expressions that define these names, and its bit_exact_math group
const _FG_NAMES = (:_sm_bits, :_SM_FMA_TABLE, :_sm_fma_bits)
function _fg_defines(a)::Union{Symbol,Nothing}
    a isa Expr || return nothing
    a.head === :macrocall && return _fg_defines(last(a.args))
    a.head === :const && return _fg_defines(a.args[1])
    if a.head in (:function, :(=))
        local sig = a.args[1]
        while sig isa Expr && sig.head in (:where, :(::))
            sig = sig.args[1]
        end
        sig isa Symbol && return sig
        sig isa Expr && sig.head === :call && sig.args[1] isa Symbol && return sig.args[1]
    end
    return nothing
end
let corpus = Meta.parseall(read(joinpath(@__DIR__, "..", "smoke_corpus.jl"), String))
    for a in corpus.args
        (_fg_defines(a) in _FG_NAMES || (a isa Expr && a.head === :call && a.args[1] === :_g && a.args[2] == "bit_exact_math")) &&
            Core.eval(FloatGuardCases, a)
    end
end

# the kernels bdd08864 broke, a case each, and a muladd folded at compile time beside the same muladd at run time (A93E1)
const FLOAT_GUARD = ("exp_f64", "expm1_f64", "acos_f64", "asin_f64", "sinh_f64", "cosh_f64", "hypot_f64", "exp_f32", "muladd_fused",
                     "muladd_folded_and_run")
@testset "the landing's float guard: bit_exact_math's kernels a change broke, each answer native's" begin
    local group = only(FloatGuardCases.GROUPS)
    @test first(group) == "bit_exact_math"
    local cs = [c for c in last(group) if c[1] in FLOAT_GUARD]
    @test sort!([c[1] for c in cs]) == sort!(collect(FLOAT_GUARD))
    # each case's own modules and, for a tuple's answer, a reader per leaf type, its facts read one by one
    local cases = reduce(vcat, (first(Main.WTChild.answer_cases("bit_exact_math/$(c[1])", WasmTarget.compile, c[2], Tuple(c[3:end])))
                                for c in cs))
    for r in Main.WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
end
