# Every test of ported code: the constructions' own tests and each ported dart test (dev/check.sh).
# A file here is a test of src; a new test file of ported code joins this list in the commit that adds it.
using Test, WasmTarget
const SRC_TESTS = ["parity.jl", "late.jl", "js_runtime.jl", "source_map_utils.jl", "globals.jl", "constants.jl", "target.jl", "classes.jl", "wasm_builder/serializer.jl", "class_info.jl", "translator.jl", "util.jl", "namer.jl", "records.jl", "code_generator.jl", "dispatch_table.jl", "dart_tests.jl", "wasm_builder/ir_modules.jl", "types.jl", "closures.jl", "wasm_builder/builder_modules.jl", "wasm_builder/builder_refusals.jl"]
@testset "src" begin
    for f in SRC_TESTS
        @testset "$f" begin include(joinpath(@__DIR__, f)) end
    end
end
