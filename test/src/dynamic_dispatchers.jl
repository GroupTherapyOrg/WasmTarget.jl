# dart2wasm's dynamic_dispatchers.dart, ported (src/dynamic_dispatchers.jl): the dispatchers are empty
# by Julia's answer, since Julia's trim verifier rejects every call it cannot resolve statically.
module DynamicDispatchersTest

using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const W = WasmTarget.WasmBuilder

struct DispatcherNodes <: D.KernelNodes end

# a call Julia cannot resolve statically: the receiver's type is open
dynamic_call(xs::Vector{Any}) = length(xs[1])

@testset "dynamic_dispatchers.dart" begin
    # no dispatcher until a dynamic call asks for one
    local d = D.DynamicDispatchers(DispatcherNodes(), W.ModuleBuilder("m", nothing))
    @test isempty(d._dispatchers)
    # and none ever does: Julia's trim verifier rejects the dynamic call, located, before any NIR exists
    local e = try; WasmTarget.check_subset(dynamic_call, (Vector{Any},), "dynamic_dispatchers"); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.OutsideSubset
end

end
