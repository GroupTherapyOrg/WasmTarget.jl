# test_codeinfo_construction.jl — PHASE-2A-008: CodeInfo construction to WasmGC
#
# Verify that the typeinf output pipeline (PreDecompressedCodeInfo, InferenceResult,
# InferenceState, retrieve_code_info) compiles to WasmGC.
#
# Run: julia +1.12 --project=. test/selfhost/test_codeinfo_construction.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "dict_method_table.jl"))

using Core.Compiler: InferenceResult, InferenceState

# ─── Setup ─────────────────────────────────────────────────────────────────────

test_sig = Tuple{typeof(+), Int64, Int64}
world = Base.get_world_counter()
interp = build_wasm_interpreter([test_sig]; world=world, transitive=false)
interp_type = typeof(interp)

native_mt = Core.Compiler.InternalMethodTable(world)
lookup = Core.Compiler.findall(test_sig, native_mt; limit=3)
mi = Core.Compiler.specialize_method(first(lookup.matches))
src = Core.Compiler.retrieve_code_info(mi, world)
result = InferenceResult(mi)
frame = InferenceState(result, src, :no, interp)

# ─── Test functions that need to compile ────────────────────────────────────────

compile_targets = [
    # PreDecompressedCodeInfo
    (get_code_info, (typeof(PreDecompressedCodeInfo()), Core.MethodInstance), "get_code_info"),
    # InferenceResult constructor
    (InferenceResult, (Core.MethodInstance,), "InferenceResult"),
    # retrieve_code_info
    (Core.Compiler.retrieve_code_info, (Core.MethodInstance, UInt64), "retrieve_code_info"),
    # InferenceState constructor
    (InferenceState, (typeof(result), typeof(src), Symbol, interp_type), "InferenceState"),
    # specialize_method (produces MethodInstance from MethodMatch)
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
]

# ─── Step 1: Compile each individually ──────────────────────────────────────────

println("=== Step 1: Compile CodeInfo construction functions individually ===")

compiled_entries = []
n_compiled = 0
n_validated = 0

for (f, atypes, name) in compile_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        ci = ci_pair[1]
        ret = ci_pair[2]
        n_stmts = length(ci.code)

        bytes = WasmTarget.compile_from_codeinfo(ci, ret, name, atypes)
        global n_compiled += 1

        tmpfile = joinpath(tempdir(), "test_ci_$(name).wasm")
        write(tmpfile, bytes)
        valid = try
            run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
            true
        catch
            false
        end
        if valid
            global n_validated += 1
        end

        push!(compiled_entries, (ci=ci, ret=ret, atypes=atypes, name=name, size=length(bytes), valid=valid))
        println("  $(valid ? "✓" : "✗") $name ($n_stmts stmts) → $(length(bytes)) bytes $(valid ? "" : "[VALIDATE FAIL]")")
    catch e
        emsg = string(e)[1:min(100, end)]
        println("  ✗ $name — $emsg")
    end
end

# ─── Step 2: Assemble module from validated functions ────────────────────────────

println("\n=== Step 2: Assemble CodeInfo construction module ===")

module_functions = [(e.ci, e.ret, e.atypes, e.name) for e in compiled_entries if e.valid]

module_compiled = false
module_bytes = UInt8[]
validate_ok = false
load_ok = false

if !isempty(module_functions)
    try
        mod = WasmTarget.compile_module_from_ir(module_functions)
        global module_bytes = WasmTarget.to_bytes(mod)
        global module_compiled = true
        println("  ✓ Module: $(length(module_bytes)) bytes, $(length(module_functions)) functions")
    catch e
        println("  ✗ Module failed: $(string(e)[1:min(200, end)])")
    end
end

if module_compiled
    tmpfile = joinpath(tempdir(), "test_codeinfo_module.wasm")
    write(tmpfile, module_bytes)
    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$tmpfile');
    WebAssembly.compile(bytes).then(m => {
        console.log("OK: loaded");
    }).catch(e => {
        console.error("FAIL:", e.message);
        process.exit(1);
    });
    """
    tmpjs = joinpath(tempdir(), "test_ci_load.cjs")
    write(tmpjs, js_code)
    load_output = try
        strip(read(`node $tmpjs`, String))
    catch e
        "ERROR: $e"
    end
    global load_ok = startswith(load_output, "OK")
    println("  Node.js load: $load_output")
end

# ─── Step 3: Verify native typeinf produces CodeInfo ─────────────────────────────

println("\n=== Step 3: Verify native typeinf CodeInfo production ===")

# Run typeinf natively
native_success = Core.Compiler.typeinf(interp, frame)
native_ret_type = result.result
native_src = result.src
println("  typeinf success: $native_success")
println("  Return type: $native_ret_type")
println("  Source type: $(typeof(native_src))")
println("  Has code: $(native_src isa Core.CodeInfo ? length(native_src.code) : "N/A") stmts")

# Verify CodeInfo is usable by Phase 1 codegen
if native_src isa Core.CodeInfo
    native_ci = native_src
    println("  SSA value types: $(length(native_ci.ssavaluetypes))")
    println("  Return type (from CI): $(native_ci.rettype)")
end

# ─── Tests ────────────────────────────────────────────────────────────────────────

@testset "CodeInfo construction — PHASE-2A-008" begin
    @testset "Individual compilation" begin
        @test n_compiled >= 5  # All 5 targets compile
        @test n_validated >= 5  # All 5 validate
    end

    @testset "Module assembly" begin
        @test module_compiled
        @test length(module_bytes) > 0
        @test validate_ok
        @test load_ok
    end

    @testset "Native typeinf produces CodeInfo" begin
        @test native_success
        @test native_ret_type == Int64
        @test native_src isa Core.CodeInfo
        @test length(native_src.code) > 0
        @test length(native_src.ssavaluetypes) > 0
    end
end

println("\n=== PHASE-2A-008: CodeInfo construction test complete ===")
