# A method's receiver, dart's `this`, as Julia's codegen decides it (src/julia/nir.jl nir_carries_data): a
# closure's or callable struct's callee carries data and is the receiver; a function's singleton callee and a
# constructor's Type{C} callee, a constant Julia never passes (isconstType), carry none, so a constructor
# compiles as a method of its type with no receiver and makes its object with its own `new`.
using Test
using WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

module ReceiverCases
mutable struct Plain      # mutable, so Julia allocates it at run time rather than folding the call
    n::Int
    Plain() = (@noinline; new(0))
end
f(x::Int) = Plain().n + x
end

@testset "receivers: a constructor's Type{C} callee carries no data, and the constructor answers as native" begin
    @test !WasmTarget.nir_carries_data(Type{ReceiverCases.Plain})
    @test !WasmTarget.nir_carries_data(typeof(sin))
    @test WasmTarget.nir_carries_data(ReceiverCases.Plain)
    # wt3-translator's probe: the constructor compiles with no receiver and the module answers native's value
    local cases = [Main.WTRunner.compiled_case("plain", WasmTarget.compile, ReceiverCases.f, (5,), ReceiverCases.f(5); optimized = false)]
    for r in Main.WTRunner.run_cases(cases)
        @test r.ok
    end
end
