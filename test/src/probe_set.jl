# test/probe_set.jl, the byte-identity probes' set, against test/smoke_corpus.jl's groups, by name alone (no compile,
# no corpus loaded, so the landing pays only the reading of two files): the set is not empty, and every group stands
# in exactly one of PROBE_NAMES (by its probe's group) and PROBE_UNCOVERED. An empty set made test/probe_bytes.jl, the
# check every pure restructuring owes (AGENTS.md), pass vacuously (2026-11-01, wt3-latency).
using Test
isdefined(Main, :PROBE_NAMES) || Base.include(Main, joinpath(@__DIR__, "..", "probe_set.jl"))
@testset "the byte-identity probes cover every corpus group, each once" begin
    local groups = unique(m[1] for m in eachmatch(r"^_(?:g|xf)\(\"([^\"]+)\""m, read(joinpath(@__DIR__, "..", "smoke_corpus.jl"), String)))
    local probed = [String(first(split(n, '/'))) for n in PROBE_NAMES]
    @test !isempty(PROBE_NAMES)
    @test allunique(probed) && allunique(PROBE_UNCOVERED) && isempty(intersect(probed, PROBE_UNCOVERED))
    @test sort(groups) == sort(vcat(probed, PROBE_UNCOVERED))
end
