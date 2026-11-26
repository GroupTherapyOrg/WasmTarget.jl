# The runtime ports a closed world holds (src/julia/subset.jl libjulia_ports, reached_runtime_ports): one table from a
# libjulia foreign call to the ports it lowers to, which check_subset queues for each foreign call the closed world
# holds and carries in the ClosedWorld and its NirWorld (`ports`), and which the code generator reads for the port it
# calls and the egal arm for whether the world holds jl_egal_unionall.
module RuntimePortsTest
using Test, WasmTarget

module PortCases
# Julia's inliner makes a foreign call of jl_type_unionall of UnionAll(v, t) (Compiler/src/ssair/inlining.jl:1745)
mk(n::Int64) = (local v = TypeVar(:T, n > 0 ? Integer : Real); UnionAll(v, Vector{v}))
with_unionall(n::Int64)::Int64 = Int64(mk(n) === mk(n))
without(n::Int64)::Int64 = n + 1
end

@testset "one table from a foreign call to its runtime ports, carried by the closed world" begin
    @test WasmTarget.libjulia_ports(:jl_type_unionall) === (WasmTarget.jl_type_unionall, WasmTarget.jl_egal_unionall)
    @test WasmTarget.libjulia_ports(:jl_types_equal) === (WasmTarget.jl_types_equal,)
    @test WasmTarget.libjulia_ports(:jl_type_hash) === (WasmTarget.jl_type_hash,)
    @test WasmTarget.libjulia_ports(Core.finalizer) === (WasmTarget.jl_gc_add_finalizer_,)
    @test WasmTarget.libjulia_ports(Core.tuple) === ()
    @test WasmTarget.libjulia_ports(:jl_get_tls_world_age) === ()
    local w = Base.get_world_counter()
    local cw = WasmTarget.check_subset(PortCases.with_unionall, (Int64,), "runtime_ports", w)
    @test cw.ports == Function[WasmTarget.jl_type_unionall, WasmTarget.jl_egal_unionall]
    # each port is in the closed world it was queued into
    @test all(f -> any(x -> x isa Core.CodeInstance && x.def.def in methods(f), cw.codeinfos), cw.ports)
    @test WasmTarget.build_nir(cw, "runtime_ports").ports === cw.ports
    @test isempty(WasmTarget.check_subset(PortCases.without, (Int64,), "runtime_ports", w).ports)
end

end # module
