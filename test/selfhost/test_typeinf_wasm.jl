# test_typeinf_wasm.jl — Probe: compile typeinf entry point to WasmGC
#
# PHASE-2A-006: Compile WasmInterpreter + typeinf entry point to WasmGC.
#
# Strategy: profile which functions typeinf calls for a simple function,
# then try to compile each individually. Document successes and failures.
#
# Run: julia +1.12 --project=. test/selfhost/test_typeinf_wasm.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))

using Core.Compiler: InferenceResult, InferenceState

# ─── Step 1: Run typeinf natively to verify it works ──────────────────────────

println("=== Step 1: Run typeinf natively ===")

test_sig = Tuple{typeof(+), Int64, Int64}
world = Base.get_world_counter()
interp = build_wasm_interpreter([test_sig]; world=world, transitive=false)

native_mt = Core.Compiler.InternalMethodTable(world)
lookup = Core.Compiler.findall(test_sig, native_mt; limit=3)
mi = Core.Compiler.specialize_method(first(lookup.matches))
src = Core.Compiler.retrieve_code_info(mi, world)

result = InferenceResult(mi)
frame = InferenceState(result, src, :no, interp)

println("  Running typeinf on $(test_sig)...")
success = Core.Compiler.typeinf(interp, frame)
println("  typeinf success: $success")
println("  Return type: $(result.result)")

# ─── Step 2: code_typed for key WasmInterpreter interface methods ─────────────

println("\n=== Step 2: code_typed for WasmInterpreter methods ===")

interp_type = typeof(interp)

interface_functions = [
    (Core.Compiler.method_table,        (interp_type,),  "method_table"),
    (Core.Compiler.InferenceParams,     (interp_type,),  "InferenceParams"),
    (Core.Compiler.OptimizationParams,  (interp_type,),  "OptimizationParams"),
    (Core.Compiler.get_inference_world,  (interp_type,),  "get_inference_world"),
    (Core.Compiler.get_inference_cache,  (interp_type,),  "get_inference_cache"),
]

code_typed_results = []
for (f, atypes, name) in interface_functions
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        n_stmts = length(ci_pair[1].code)
        push!(code_typed_results, (name=name, f=f, atypes=atypes, ci=ci_pair[1], ret=ci_pair[2], stmts=n_stmts))
        println("  ✓ $name ($n_stmts stmts) → $(ci_pair[2])")
    catch e
        println("  ✗ $name — $(string(e)[1:min(80,end)])")
    end
end

# ─── Step 3: Try compile_from_codeinfo ────────────────────────────────────────

println("\n=== Step 3: Compile WasmInterpreter methods to WasmGC ===")

global g_compiled = 0
global g_failed = 0
global g_failures = String[]

for entry in code_typed_results
    try
        sig_type = Tuple{entry.atypes...}
        bytes = WasmTarget.compile_from_codeinfo(entry.ci, entry.ret, entry.name, entry.atypes)
        global g_compiled += 1
        println("  ✓ compiled: $(entry.name) → $(length(bytes)) bytes")
    catch e
        global g_failed += 1
        emsg = string(e)[1:min(150, end)]
        push!(g_failures, "$(entry.name): $emsg")
        println("  ✗ compile: $(entry.name) — $emsg")
    end
end

# ─── Step 4: Try compiling more typeinf functions ─────────────────────────────

println("\n=== Step 4: Probe deeper typeinf functions ===")

# These are key functions called during typeinf
# Phase 1 learned: manual function listing is more reliable than transitive discovery.
deeper_targets = [
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
    # Core typeinf infrastructure
    (Core.Compiler.typeinf,          (interp_type, typeof(frame)), "typeinf"),
    (Core.Compiler.typeinf_local,     (interp_type, typeof(frame)), "typeinf_local"),
    # Method matching
    (Core.Compiler.findall, (Type, typeof(interp.method_table.table)), "findall_DictMethodTable"),
    (Core.Compiler.isoverlayed, (typeof(interp.method_table.table),), "isoverlayed"),
]

for (f, atypes, name) in deeper_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        n_stmts = length(ci_pair[1].code)
        try
            bytes = WasmTarget.compile_from_codeinfo(ci_pair[1], ci_pair[2], name, atypes)
            global g_compiled += 1
            println("  ✓ compiled: $name ($n_stmts stmts) → $(length(bytes)) bytes")
        catch e
            global g_failed += 1
            emsg = string(e)[1:min(150, end)]
            push!(g_failures, "$name: $emsg")
            println("  ✗ compile: $name ($n_stmts stmts) — $emsg")
        end
    catch e
        global g_failed += 1
        emsg = string(e)[1:min(100, end)]
        push!(g_failures, "$name: code_typed failed — $emsg")
        println("  ✗ code_typed: $name — $emsg")
    end
end

# ─── Summary and Tests ────────────────────────────────────────────────────────

println("\n=== Summary ===")
println("  typeinf native: $(success ? "PASS" : "FAIL"), return type: $(result.result)")
println("  code_typed: $(length(code_typed_results)) succeeded")
println("  compiled: $g_compiled, failed: $g_failed")
for f in g_failures
    println("    - $f")
end

# ─── Step 5: Assemble multi-function module ───────────────────────────────────

println("\n=== Step 5: Assemble multi-function typeinf module ===")

# Collect all functions that compiled individually and try to compile them together
module_functions = []
for entry in code_typed_results
    push!(module_functions, (entry.ci, entry.ret, entry.atypes, entry.name))
end
# Add deeper targets that compiled
for (f, atypes, name) in deeper_targets
    try
        ci_pair = only(Base.code_typed(f, atypes; optimize=false))
        push!(module_functions, (ci_pair[1], ci_pair[2], atypes, name))
    catch
    end
end

println("  Attempting to compile $(length(module_functions)) functions into one module...")
module_compiled = false
module_bytes = UInt8[]
try
    mod = WasmTarget.compile_module_from_ir(module_functions)
    global module_bytes = WasmTarget.to_bytes(mod)
    global module_compiled = true
    println("  ✓ Module compiled: $(length(module_bytes)) bytes, $(length(module_functions)) functions")
catch e
    emsg = string(e)[1:min(200, end)]
    println("  ✗ Module compilation failed: $emsg")
end

# Validate if compiled
if module_compiled
    tmpfile = joinpath(tempdir(), "test_typeinf_module.wasm")
    write(tmpfile, module_bytes)
    validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
        true
    catch
        false
    end
    println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

    # Try loading in Node.js
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
    tmpjs = joinpath(tempdir(), "test_typeinf_load.cjs")
    write(tmpjs, js_code)
    load_output = try
        strip(read(`node $tmpjs`, String))
    catch e
        "ERROR: $e"
    end
    println("  Node.js load: $load_output")
end

@testset "Typeinf compilation probe" begin
    @test success == true
    @test result.result == Int64
    @test length(code_typed_results) >= 3
    @test g_compiled >= 8
    if module_compiled
        @test length(module_bytes) > 0
    end
end

println("\n=== PHASE-2A-006: typeinf compilation probe complete ===")
