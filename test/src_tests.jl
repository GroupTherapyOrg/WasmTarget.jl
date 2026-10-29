# Every test of ported code: each file under test/src/, found by walking the directory (dev/check.sh).
# A lane adds a test by adding its file there; no list is shared between lanes to conflict on.
using Test, WasmTarget
const SRC_TEST_DIR = joinpath(@__DIR__, "src")
const SRC_TESTS = sort!([relpath(joinpath(d, f), SRC_TEST_DIR)
                         for (d, _, fs) in walkdir(SRC_TEST_DIR) for f in fs if endswith(f, ".jl")])
isempty(SRC_TESTS) && error("test/src/ holds no test file: the walk found nothing")
# the file and case running now, for dev/check.sh's hard limit to name (WT_PROGRESS)
const _WT_PROGRESS = get(ENV, "WT_PROGRESS", "")
wt_progress(s::AbstractString) = isempty(_WT_PROGRESS) || write(_WT_PROGRESS, s)
@testset verbose = true "src" begin
    for f in SRC_TESTS
        wt_progress(f)
        @testset "$f" begin include(joinpath(SRC_TEST_DIR, f)) end
    end
end
