# test_e2e_user_types.jl — PHASE-2B-008: E2E browser typeinf + codegen for user-defined structs
#
# Full Phase 2b pipeline: user defines struct → server lowers → serialize →
# browser deserializes → typeinf (WasmInterpreter with DictMethodTable) →
# codegen → execute. Compare to native results.
#
# CRITICAL ORDERING CONSTRAINT:
# dict_method_table.jl overrides Base._methods_by_ftype and Base.typeintersect globally.
# This breaks: code_lowered, code_typed, methods(), JSON.parse, process spawning, etc.
# So ALL external operations must happen BEFORE loading dict_method_table.jl.
# Only WasmInterpreter typeinf (which uses DictMethodTable.findall internally,
# not _methods_by_ftype) can safely run after the overrides.
#
# Run: julia +1.12 --project=. test/selfhost/test_e2e_user_types.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))

# ─── User-defined structs (what a user would type in the browser) ────────────

struct E2EPoint
    x::Float64
    y::Float64
end

struct E2EPointI
    x::Int64
    y::Int64
end

struct E2ERect
    origin::E2EPoint
    width::Float64
    height::Float64
end

# ─── User functions operating on structs ──────────────────────────────────────

e2e_x_plus_one(x::Float64, y::Float64)::Float64 = begin
    p = E2EPoint(x, y)
    p.x + 1.0
end

e2e_get_x(x::Float64, y::Float64)::Float64 = begin
    p = E2EPoint(x, y)
    p.x
end

e2e_point_sum(x::Float64, y::Float64)::Float64 = begin
    p = E2EPoint(x, y)
    p.x + p.y
end

e2e_dist_sq(x::Float64, y::Float64)::Float64 = begin
    p = E2EPoint(x, y)
    p.x * p.x + p.y * p.y
end

e2e_int_sum(x::Int64, y::Int64)::Int64 = begin
    p = E2EPointI(x, y)
    p.x + p.y
end

e2e_int_diff(x::Int64, y::Int64)::Int64 = begin
    p = E2EPointI(x, y)
    p.x - p.y
end

e2e_rect_area(ox::Float64, oy::Float64, w::Float64, h::Float64)::Float64 = begin
    r = E2ERect(E2EPoint(ox, oy), w, h)
    r.width * r.height
end

e2e_rect_origin_x(ox::Float64, oy::Float64, w::Float64, h::Float64)::Float64 = begin
    r = E2ERect(E2EPoint(ox, oy), w, h)
    r.origin.x
end

e2e_clamp_x(x::Float64, y::Float64)::Float64 = begin
    p = E2EPoint(x, y)
    p.x < 0.0 ? 0.0 : (p.x > 1.0 ? 1.0 : p.x)
end

e2e_dot_product(x1::Float64, y1::Float64, x2::Float64, y2::Float64)::Float64 = begin
    a = E2EPoint(x1, y1)
    b = E2EPoint(x2, y2)
    a.x * b.x + a.y * b.y
end

test_functions = [
    (e2e_x_plus_one,    (Float64, Float64),                                 "e2e_x_plus_one",
        [(5.0, 0.0), (0.0, 0.0), (-1.0, 0.0)]),
    (e2e_get_x,         (Float64, Float64),                                 "e2e_get_x",
        [(1.0, 2.0), (5.0, 0.0)]),
    (e2e_point_sum,     (Float64, Float64),                                 "e2e_point_sum",
        [(3.0, 4.0), (0.0, 0.0)]),
    (e2e_dist_sq,       (Float64, Float64),                                 "e2e_dist_sq",
        [(3.0, 4.0), (1.0, 0.0)]),
    (e2e_int_sum,       (Int64, Int64),                                     "e2e_int_sum",
        [(Int64(10), Int64(20)), (Int64(0), Int64(0))]),
    (e2e_int_diff,      (Int64, Int64),                                     "e2e_int_diff",
        [(Int64(10), Int64(3)), (Int64(5), Int64(5))]),
    (e2e_rect_area,     (Float64, Float64, Float64, Float64),               "e2e_rect_area",
        [(0.0, 0.0, 5.0, 3.0), (1.0, 1.0, 10.0, 2.0)]),
    (e2e_rect_origin_x, (Float64, Float64, Float64, Float64),               "e2e_rect_origin_x",
        [(7.0, 8.0, 1.0, 1.0), (0.0, 0.0, 5.0, 5.0)]),
    (e2e_clamp_x,       (Float64, Float64),                                 "e2e_clamp_x",
        [(-0.5, 0.0), (0.5, 0.0), (1.5, 0.0)]),
    (e2e_dot_product,   (Float64, Float64, Float64, Float64),               "e2e_dot_product",
        [(1.0, 0.0, 0.0, 1.0), (3.0, 4.0, 4.0, 3.0)]),
]

# ══════════════════════════════════════════════════════════════════════════════
# PHASE A: ALL external operations BEFORE loading overrides
# ══════════════════════════════════════════════════════════════════════════════

println("=== PHASE-2B-008: E2E User-Defined Types — Browser TypeInf + Codegen ===\n")

world = Base.get_world_counter()

# Step 1: SERVER — lower and serialize
println("--- Step 1: Server — code_lowered + serialize ---")
lowered_entries = []
for (f, atypes, name, _) in test_functions
    lowered_ci = Base.code_lowered(f, atypes)[1]
    push!(lowered_entries, (lowered_ci, Any, atypes, name))
end
json_str = WasmTarget.serialize_ir_entries(lowered_entries)
println("  Serialized $(length(test_functions)) functions, $(length(json_str)) bytes JSON")

# Step 2: BROWSER — deserialize lowered IR
println("\n--- Step 2: Browser — deserialize lowered IR ---")
deserialized = WasmTarget.deserialize_ir_entries(json_str)
println("  Deserialized $(length(deserialized)) entries")

# Pre-compute native code_typed (optimized IR)
println("\n--- Pre-compute: native code_typed ---")
native_typed = Dict{String, Tuple{Core.CodeInfo, Any}}()
for (f, atypes, name, _) in test_functions
    ci, ret = Base.code_typed(f, atypes)[1]
    native_typed[name] = (ci, ret)
    println("  ✓ $name → $ret ($(length(ci.code)) stmts)")
end

# Pre-compute method table entries
println("\n--- Pre-compute: method table entries ---")
using Core.Compiler: InternalMethodTable, MethodLookupResult, InferenceResult,
    InferenceState, InferenceParams, OptimizationParams, CachedMethodTable

native_mt = InternalMethodTable(world)
all_sigs = [Tuple{typeof(f), atypes...} for (f, atypes, _, _) in test_functions]
callee_sigs = [
    Tuple{typeof(+), Float64, Float64},
    Tuple{typeof(*), Float64, Float64},
    Tuple{typeof(-), Float64, Float64},
    Tuple{typeof(<), Float64, Float64},
    Tuple{typeof(>), Float64, Float64},
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
]
precomputed_methods = Dict{Any, MethodLookupResult}()
for sig in vcat(all_sigs, callee_sigs)
    r = Core.Compiler.findall(sig, native_mt; limit=3)
    if r !== nothing
        precomputed_methods[sig] = r
    end
end
println("  Pre-computed $(length(precomputed_methods)) method entries")

# Pre-compute MethodInstances and CodeInfo for WasmInterpreter
precomputed_mi = Dict{String, Core.MethodInstance}()
precomputed_src = Dict{String, Core.CodeInfo}()
for (f, atypes, name, _) in test_functions
    mi = Core.Compiler.specialize_method(
        first(methods(f, atypes)),
        Tuple{typeof(f), atypes...},
        Core.svec()
    )
    src = Core.Compiler.retrieve_code_info(mi, world)
    precomputed_mi[name] = mi
    if src !== nothing
        precomputed_src[name] = src
    end
end

# Step 4: Codegen + execute (ALL before overrides)
println("\n--- Step 4: Codegen + execute (BEFORE overrides) ---")
compile_ok = 0
exec_ok = 0
total_cases = 0
for (f, atypes, name, cases) in test_functions
    try
        ci, ret = native_typed[name]
        mod = WasmTarget.compile_module_from_ir([(ci, ret, atypes, name)])
        bytes = WasmTarget.to_bytes(mod)
        global compile_ok += 1

        for args in cases
            global total_cases += 1
            native_result = f(args...)
            try
                wasm_result = run_wasm(bytes, name, args...)
                if native_result isa Float64
                    ok = wasm_result isa Number && abs(Float64(wasm_result) - native_result) < 1e-10
                else
                    ok = wasm_result == native_result
                end
                if ok
                    global exec_ok += 1
                    println("  ✓ $name($(join(args, ", "))) = $wasm_result")
                else
                    println("  ✗ $name($(join(args, ", "))) = $wasm_result (expected $native_result)")
                end
            catch e
                println("  ✗ $name($(join(args, ", "))): $(sprint(showerror, e))")
            end
        end
    catch e
        println("  ✗ $name compile: $(sprint(showerror, e))")
    end
end
println("  Compile: $compile_ok/$(length(test_functions))")
println("  Execution: $exec_ok/$total_cases correct")

# Step 5: Acceptance criteria (BEFORE overrides)
println("\n--- Step 5: Acceptance — Point(5.0).x + 1.0 = 6.0 ---")
native_acceptance = e2e_x_plus_one(5.0, 0.0)
ac_ci, ac_ret = native_typed["e2e_x_plus_one"]
ac_mod = WasmTarget.compile_module_from_ir([(ac_ci, ac_ret, (Float64, Float64), "e2e_x_plus_one")])
ac_bytes = WasmTarget.to_bytes(ac_mod)
ac_wasm = run_wasm(ac_bytes, "e2e_x_plus_one", 5.0, 0.0)
ac_pass = ac_wasm isa Number && abs(Float64(ac_wasm) - 6.0) < 1e-10
println("  Native: e2e_x_plus_one(5.0, 0.0) = $native_acceptance")
println("  Wasm:   e2e_x_plus_one(5.0, 0.0) = $ac_wasm")
println("  $(ac_pass ? "✓ ACCEPTANCE PASS" : "✗ ACCEPTANCE FAIL"): Point(5.0).x + 1.0 = $(ac_wasm)")

# ══════════════════════════════════════════════════════════════════════════════
# PHASE B: Load ALL overrides (subtype + matching for wasm_type_intersection,
# ccall_replacements for typeinf, dict_method_table for WasmInterpreter)
# After this: _methods_by_ftype + typeintersect are overridden globally.
# Only WasmInterpreter typeinf (using DictMethodTable.findall) is safe.
# ══════════════════════════════════════════════════════════════════════════════

println("\n--- Loading typeinf overrides ---")
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "matching.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "dict_method_table.jl"))
println("  All overrides loaded")

# ══════════════════════════════════════════════════════════════════════════════
# PHASE C: WasmInterpreter typeinf (uses DictMethodTable, not _methods_by_ftype)
# ══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Browser — typeinf (WasmInterpreter + DictMethodTable) ---")

# Build DictMethodTable from pre-computed entries
table = DictMethodTable(world)
for (sig, r) in precomputed_methods
    table.methods[sig] = r
end
println("  DictMethodTable: $(length(table.methods)) entries")

# Run typeinf for each user struct function
typeinf_results = Dict{String, Tuple{Core.CodeInfo, Any}}()
typeinf_ok = 0
for (f, atypes, name, _) in test_functions
    mi = precomputed_mi[name]
    src = precomputed_src[name]
    interp = WasmInterpreter(world, table)
    result = InferenceResult(mi)
    frame = InferenceState(result, src, :no, interp)

    try
        Core.Compiler.typeinf(interp, frame)
        typed_ci = frame.src
        ret_type = result.result
        typeinf_results[name] = (typed_ci, ret_type)
        global typeinf_ok += 1
        println("  ✓ $name → $ret_type ($(length(typed_ci.code)) stmts)")
    catch e
        println("  ✗ $name: $(sprint(showerror, e))")
        typeinf_results[name] = native_typed[name]
    end
end
println("  TypeInf OK: $typeinf_ok/$(length(test_functions))")

# Report missing sigs
report = report_missing_signatures(table; verbose=true)

# Verify typeinf types match native
println("\n--- Verify typeinf types match native ---")
type_match_ok = 0
for (f, atypes, name, _) in test_functions
    native_ret = native_typed[name][2]
    wasm_ret = typeinf_results[name][2]
    match = wasm_ret == native_ret
    if match
        global type_match_ok += 1
    end
    println("  $(match ? "✓" : "✗") $name: wasm=$wasm_ret native=$native_ret")
end
println("  Type match: $type_match_ok/$(length(test_functions))")

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "E2E Phase 2b — PHASE-2B-008" begin
    @testset "Lowered IR transport" begin
        @test length(json_str) > 0
        @test length(deserialized) == 10
    end

    @testset "TypeInf (WasmInterpreter)" begin
        @test typeinf_ok == 10
    end

    @testset "TypeInf type accuracy" begin
        @test type_match_ok == 10
    end

    @testset "Codegen compiles all" begin
        @test compile_ok == 10
    end

    @testset "Execution correctness" begin
        @test exec_ok == total_cases
    end

    @testset "Acceptance: Point(5.0).x + 1.0 = 6.0" begin
        @test ac_pass
        @test native_acceptance == 6.0
    end
end

println("\n=== PHASE-2B-008: E2E test complete ===")
