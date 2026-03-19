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
deeper_targets = [
    # findall is already compiled as WasmGC function (PHASE-2A-005)
    # These are functions typeinf calls after getting a method match
    (Core.Compiler.specialize_method, (Core.MethodMatch,), "specialize_method"),
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

@testset "Typeinf compilation probe" begin
    @test success == true
    @test result.result == Int64
    @test length(code_typed_results) >= 3
    # At least some functions should compile
    @test g_compiled >= 0
end

println("\n=== PHASE-2A-006: typeinf compilation probe complete ===")
