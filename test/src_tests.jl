# Every test of ported code: the constructions' own tests and each ported dart test (dev/check.sh).
# A file here is a test of src; a new test file of ported code joins this list in the commit that
# adds it, one file per line in sorted order, so lanes adding tests at once touch different lines.
using Test, WasmTarget
const SRC_TESTS = [
    "class_info.jl",
    "classes.jl",
    "closures.jl",
    "code_generator.jl",
    "constants.jl",
    "dart_tests.jl",
    "dispatch_table.jl",
    "functions.jl",
    "globals.jl",
    "intrinsics.jl",
    "js_runtime.jl",
    "late.jl",
    "llvm_cfg_sort.jl",
    "llvm_cfg_stackify.jl",
    "llvm_loop_info.jl",
    "namer.jl",
    "param_info.jl",
    "parity.jl",
    "records.jl",
    "source_map_utils.jl",
    "target.jl",
    "translator.jl",
    "types.jl",
    "util.jl",
    "wasm_builder/barrel_exports.jl",
    "wasm_builder/builder_modules.jl",
    "wasm_builder/builder_refusals.jl",
    "wasm_builder/builder_validation.jl",
    "wasm_builder/ir_modules.jl",
    "wasm_builder/serializer.jl",
]
# WT_PROGRESS names a file dev/check.sh reads when a stage outlives its hard limit: the test file and
# the case running then, so a hang names itself
const WT_PROGRESS = get(ENV, "WT_PROGRESS", "")
wt_progress(what::AbstractString) = isempty(WT_PROGRESS) || write(WT_PROGRESS, what)
@testset "src" begin
    for f in SRC_TESTS
        wt_progress(f)
        @testset "$f" begin include(joinpath(@__DIR__, f)) end
    end
end
