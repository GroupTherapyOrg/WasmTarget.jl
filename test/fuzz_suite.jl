# ============================================================================
# Bounded differential fuzz — runs inside the main suite / CI
# ============================================================================
#
# Replays the committed corpus (test/fuzz/corpus) as a regression ratchet, then
# runs a small fixed-seed budget of generated compositions, asserting native==wasm.
# The full machine and the standalone self-fulfilling loop live in test/fuzz/
# (run `julia --project=test/fuzz test/fuzz/run.jl` for deep exploration).
#
# Requires Supposition (test-only dep) + Node.js; skips cleanly without Node.

@testset "Differential fuzz (bounded)" begin
    include(joinpath(@__DIR__, "fuzz", "run.jl"))
    if FuzzHarness.NODE_OK
        @test ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
    else
        @info "Differential fuzz skipped — Node.js unavailable"
        @test_skip true
    end
end
