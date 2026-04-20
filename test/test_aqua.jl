# Aqua QA — structural/metadata checks on the package itself.
# Runs on Julia 1.12 as part of `Pkg.test` via test/runtests.jl.
using Aqua
using Test
using WasmTarget

@testset "Aqua" begin
    Aqua.test_all(WasmTarget)
end
