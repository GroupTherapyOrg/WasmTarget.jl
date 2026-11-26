# Two String constants that are two objects are still `===` when their contents are: src/constants.jl ensureConstant
# keys a String constant by its object (StringObject, src/julia/wasm_array.jl), so a const binding's String and an
# equal literal get two infos and two globals, and Julia's `===` on Strings answers by contents whatever the objects
# (julia/src/builtins.c:243 jl_egal__bitstag, its jl_string_tag arm: the lengths, then memcmp of the bytes), which
# src/intrinsics.jl Val(:string_egal) compiles. dev/formal/Constants.tla models the key and claims EgalByContent.
# Each case's answer is native Julia's, compared in both modules; no answer reads an address, objectid or hash.
module StringConstantsEgalTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module StringConstantEgalCases
const KS = "hello"
const KT = "hello"
bits(bs::Bool...) = sum(Int64(b) << (i - 1) for (i, b) in enumerate(bs))
# a literal of KS's contents against KS: two objects, two constants; ===, == and isequal by contents
function literal_vs_const(x::Int64)::Int64
    local a = x > 0 ? "hello" : "x"
    return bits(a === KS, a == KS, isequal(a, KS))
end
# two const bindings of equal contents: two objects natively, two constants in the module
function two_consts(x::Int64)::Int64
    local a = x > 0 ? KS : "x"
    local b = x > 1 ? "y" : KT
    return bits(a === b, a == b, isequal(a, b))
end
# a literal of one method against the const read in another
@noinline lit(x::Int64) = x > 0 ? "hello" : "z"
@noinline konst(x::Int64) = x > 1 ? "w" : KT
literal_two_methods(x::Int64)::Int64 = bits(lit(x) === konst(x), lit(x) == konst(x), isequal(lit(x), konst(x)))
end

const SE = StringConstantEgalCases

@testset "two String constants of equal contents, two objects, are ===" begin
    # natively the bindings and the literal are distinct objects (the two-info situation), egal by contents
    @test pointer_from_objref(SE.KS) != pointer_from_objref(SE.KT)
    @test SE.KS === SE.KT
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((SE.literal_vs_const, (1, 0)), (SE.two_consts, (1, 2)), (SE.literal_two_methods, (1, 2)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("string_constants_egal/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: equal contents egal, == and isequal (7), different contents none (0)
    @test [c.native for c in cases] == [7, 0, 7, 0, 7, 0]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
