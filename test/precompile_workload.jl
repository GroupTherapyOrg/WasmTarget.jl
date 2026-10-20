using Test
using WasmTarget

# The precompile workload's signatures compile (src/WasmTarget.jl _PC_WORKLOAD). A local
# precompile compiles them in the workload and fails on a rejection; the gate's jobs precompile
# with the workload off (LocalPreferences.toml), so this family is where the gate compiles them.
@testset "the precompile workload's signatures compile" begin
    @test length(WasmTarget._PC_WORKLOAD) == 21
    for (f, ts) in WasmTarget._PC_WORKLOAD
        @test WasmTarget.compile(f, ts; validate=true) isa Vector{UInt8}
    end
end
