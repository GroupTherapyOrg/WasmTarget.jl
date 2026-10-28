# Every test of ported code: the constructions' own tests and each ported dart test (dev/check.sh).
# A file here is a test of src; a new test file of ported code joins this list in the commit that adds it.
using Test, WasmTarget
const SRC_TESTS = ["late.jl", "classes.jl", "wasm_builder/serializer.jl", "class_info.jl"]
@testset "src" begin
    for f in SRC_TESTS
        @testset "$f" begin include(joinpath(@__DIR__, f)) end
    end
end
