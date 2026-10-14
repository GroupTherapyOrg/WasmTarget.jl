# Aqua QA — structural/metadata checks on the package itself.
# Runs on Julia 1.12 as part of `Pkg.test` via test/runtests.jl.
using Aqua
using Test
using WasmTarget

@testset "Aqua" begin
    # JSON is no longer used by src (the typed-IR transport is deleted); it stays a [deps]
    # entry only because the lanes run the test harness (Node-output decoding in
    # test/utils.jl, test/wasm_runner.jl, test/fuzz/bridge*.jl) under `--project=.`. It
    # leaves [deps] with this exception when the lanes get their own test environment.
    Aqua.test_all(WasmTarget; stale_deps = (ignore = [:JSON],))
end
