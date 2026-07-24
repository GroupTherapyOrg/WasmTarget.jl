using Test

include(joinpath(@__DIR__, "evidence_utils.jl"))
using .JumpCertificationEvidence

@testset "JuMP certification evidence policy" begin
    authored = (
        f = identity,
        inputs = [(1,)],
        expected = Dict((1,) => 1),
    )
    digest_only = (
        f = identity,
        inputs = [(1,)],
        expected_ledger_sha256 = "not-an-independent-oracle",
    )

    @test has_independent_oracle(authored, "moi-variable-bound-algebra-v1")
    @test !has_independent_oracle(
        digest_only,
        "moi-variable-bound-algebra-v1",
    )
    @test has_independent_oracle(digest_only, "t0")
end
