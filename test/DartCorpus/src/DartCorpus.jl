# test/smoke_corpus.jl's groups as a precompiled module, so test/src/dart_tests.jl loads the corpus from a cache rather
# than lowering its tens of thousands of lines again: that include was 21.5 s of the dart tests' 32.2-s load at
# background QoS, and the file the landing check's critical path (2026-10-29). test/src/dart_tests.jl copies this
# package and the corpus under their content's hash into the repository's common dir, so every lane shares one image
# per corpus content (its cache in a shared depot), rebuilt once when the corpus changes, never once per lane.
module DartCorpus
const GROUPS = Pair{String,Vector{Any}}[]
_g(name, cases) = push!(GROUPS, name => cases)
_xf(name, cases) = push!(GROUPS, name => cases)
include(joinpath(@__DIR__, "..", "..", "smoke_corpus.jl"))
end
