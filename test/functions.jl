# functions.dart (src/functions.jl): the shapes of dynamic calls. A shape's kind says whether it calls a
# getter, a setter or a method; a method shape matches a Julia method by its positional arity (a
# trailing vararg takes any number), and passes no type arguments or named ones, which a Julia
# method's body never declares; shapes compare and hash by their fields, as dart's do.

module FunctionsTest

using Test
using WasmTarget

const WT = WasmTarget
const W = WasmTarget.Dart2Wasm

module Targets
two(a::Int, b::Int) = a + b
rest(a::Int, xs::Int...) = a + sum(xs; init = 0)
end

nir_body(f, at) = only(b for b in WT.build_nir(WT.check_subset(f, at, "functions"), "functions") if b.ci.def.def.name === nameof(f))

@testset "CallShape" begin
    local m = W.MethodCallShape(:two, 0, 2, Symbol[])
    local g = W.GetterCallShape(:x)
    local s = W.SetterCallShape(:x)
    @test (W.is_method(m), W.is_getter(m), W.is_setter(m)) == (true, false, false)
    @test (W.is_method(g), W.is_getter(g), W.is_setter(g)) == (false, true, false)
    @test (W.is_method(s), W.is_getter(s), W.is_setter(s)) == (false, false, true)
    @test W.total_argument_count(W.MethodCallShape(:f, 1, 2, [:a, :b])) == 5
    @test W.is_index_set(W.MethodCallShape(:setindex!, 0, 3, Symbol[])) && !W.is_index_set(m)

    @test m == W.MethodCallShape(:two, 0, 2, Symbol[]) && hash(m) == hash(W.MethodCallShape(:two, 0, 2, Symbol[]))
    @test m != W.MethodCallShape(:two, 0, 3, Symbol[]) && m != W.copy_with_name(m, :three)
    @test W.copy_with_name(m, :three) == W.MethodCallShape(:three, 0, 2, Symbol[])
    @test g == W.GetterCallShape(:x) && g != s && hash(g) != hash(s)      # a getter and a setter of one name differ
    @test length(Set{W.CallShape}([m, W.MethodCallShape(:two, 0, 2, Symbol[]), g, s])) == 3

    @test sprint(show, W.MethodCallShape(:f, 1, 2, [:a, :b])) == "MethodCallShape(f types:1 pos:2 names:a-b)"
    @test sprint(show, W.MethodCallShape(:f, 0, 0, Symbol[])) == "MethodCallShape(f)"
    @test sprint(show, g) == "GetterCallShape(x)" && sprint(show, s) == "SetterCallShape(x)"

    @test_throws WT.RejectionError W.CallShape(:f)                         # the sealed class itself

    local two = nir_body(Targets.two, (Int, Int))
    @test W.matches_target(W.MethodCallShape(:two, 0, 2, Symbol[]), two)
    @test !W.matches_target(W.MethodCallShape(:two, 0, 1, Symbol[]), two)   # too few
    @test !W.matches_target(W.MethodCallShape(:two, 0, 3, Symbol[]), two)   # too many
    @test !W.matches_target(W.MethodCallShape(:two, 1, 2, Symbol[]), two)   # a type argument
    @test !W.matches_target(W.MethodCallShape(:two, 0, 2, [:k]), two)       # a named argument
    local rest = nir_body(Targets.rest, (Int, Int, Int))
    @test W.matches_target(W.MethodCallShape(:rest, 0, 1, Symbol[]), rest)  # the vararg takes none
    @test W.matches_target(W.MethodCallShape(:rest, 0, 4, Symbol[]), rest)  # or any number
    @test !W.matches_target(W.MethodCallShape(:rest, 0, 0, Symbol[]), rest)
end

end # module FunctionsTest
