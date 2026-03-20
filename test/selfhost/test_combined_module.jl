# test_combined_module.jl — PHASE-2A-009: Combined typeinf + codegen module
#
# Assemble self-hosted-compiler.wasm combining:
# - Phase 2a typeinf functions (9 from PHASE-2A-006)
# - Phase 2a CodeInfo construction functions (5 from PHASE-2A-008)
# - Method table data (hash table + globals from PHASE-2A-002/003)
# - Intersection cache (from PHASE-2A-010)
#
# Run: julia +1.12 --project=. test/selfhost/test_combined_module.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))

using Core.Compiler: InferenceResult, InferenceState

# ─── Setup test environment ─────────────────────────────────────────────────

test_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
]
world = Base.get_world_counter()
interp = build_wasm_interpreter(test_sigs; world=world, transitive=false)
interp_type = typeof(interp)

native_mt = Core.Compiler.InternalMethodTable(world)
lookup = Core.Compiler.findall(test_sigs[1], native_mt; limit=3)
mi = Core.Compiler.specialize_method(first(lookup.matches))
src = Core.Compiler.retrieve_code_info(mi, world)
result = InferenceResult(mi)
frame = InferenceState(result, src, :no, interp)

# ─── Collect ALL Phase 2a functions ──────────────────────────────────────────

println("=== Step 1: Collecting Phase 2a functions ===")

all_functions = []
compiled_names = String[]

# Group A: WasmInterpreter interface (PHASE-2A-006)
interface_targets = [
    (Core.Compiler.method_table,        (interp_type,),  "method_table"),
    (Core.Compiler.InferenceParams,     (interp_type,),  "InferenceParams"),
    (Core.Compiler.OptimizationParams,  (interp_type,),  "OptimizationParams"),
    (Core.Compiler.get_inference_world,  (interp_type,),  "get_inference_world"),
    (Core.Compiler.get_inference_cache,  (interp_type,),  "get_inference_cache"),
]

# Group B: Core typeinf functions (PHASE-2A-006)
typeinf_targets = [
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
    (Core.Compiler.typeinf,          (interp_type, typeof(frame)), "typeinf"),
    (Core.Compiler.findall, (Type, typeof(interp.method_table.table)), "findall_DictMethodTable"),
    (Core.Compiler.isoverlayed, (typeof(interp.method_table.table),), "isoverlayed"),
]

# Group C: CodeInfo construction (PHASE-2A-008)
codeinfo_targets = [
    (get_code_info, (typeof(PreDecompressedCodeInfo()), Core.MethodInstance), "get_code_info"),
    (InferenceResult, (Core.MethodInstance,), "InferenceResult_ctor"),
    (Core.Compiler.retrieve_code_info, (Core.MethodInstance, UInt64), "retrieve_code_info"),
    (InferenceState, (typeof(result), typeof(src), Symbol, interp_type), "InferenceState_ctor"),
]

all_targets = vcat(interface_targets, typeinf_targets, codeinfo_targets)

for (f, atypes, name) in all_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        push!(all_functions, (ci_pair[1], ci_pair[2], atypes, name, f))
        push!(compiled_names, name)
        println("  ✓ $name ($(length(ci_pair[1].code)) stmts)")
    catch e
        println("  ✗ $name — $(string(e)[1:min(80,end)])")
    end
end

println("  Total: $(length(all_functions)) functions")

# ─── Step 2: Assemble combined module ────────────────────────────────────────

println("\n=== Step 2: Assemble combined typeinf+codegen module ===")

module_compiled = false
module_bytes = UInt8[]
validate_ok = false
load_ok = false
n_exports = 0

try
    mod = WasmTarget.compile_module_from_ir(all_functions)
    global module_bytes = WasmTarget.to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $n_exports")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
catch e
    println("  ✗ Module failed: $(string(e)[1:min(300,end)])")
end

# ─── Step 3: Validate ────────────────────────────────────────────────────────

if module_compiled
    println("\n=== Step 3: Validate ===")
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-compiler.wasm")
    write(output_path, module_bytes)

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

    # Node.js load test
    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$output_path');
    WebAssembly.compile(bytes).then(mod => {
        const exps = WebAssembly.Module.exports(mod);
        console.log("OK: " + exps.length + " exports loaded");
    }).catch(e => {
        console.error("FAIL:", e.message);
        process.exit(1);
    });
    """
    tmpjs = joinpath(tempdir(), "test_combined_load.cjs")
    write(tmpjs, js_code)
    load_output = try
        strip(read(`node $tmpjs`, String))
    catch e
        "ERROR: $e"
    end
    global load_ok = startswith(load_output, "OK")
    println("  Node.js: $load_output")

    # Size analysis
    println("\n=== Binary Size Analysis ===")
    println("  Raw: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    # Rough Brotli estimate: ~0.3-0.5 compression ratio for WASM
    est_brotli = round(length(module_bytes) * 0.35 / 1024, digits=1)
    println("  Estimated Brotli: ~$(est_brotli) KB")
    println("  Functions: $(length(all_functions))")
end

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "Combined typeinf+codegen module — PHASE-2A-009" begin
    @testset "Function collection" begin
        @test length(all_functions) >= 13  # 5 interface + 4 typeinf + 4 codeinfo
    end

    @testset "Module assembly" begin
        @test module_compiled
        @test length(module_bytes) > 0
    end

    @testset "Validation" begin
        @test validate_ok  # wasm-tools validate passes
    end

    @testset "Node.js loading" begin
        @test load_ok  # WebAssembly.compile succeeds
    end

    @testset "Binary size" begin
        # Must be < 5 MB raw (spec budget)
        @test length(module_bytes) < 5_000_000
        # Should be reasonable for 13 functions
        @test length(module_bytes) > 10_000  # at least 10 KB
    end
end

println("\n=== PHASE-2A-009: Combined module test complete ===")
