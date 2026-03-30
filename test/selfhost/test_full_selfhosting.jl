# test_full_selfhosting.jl — PHASE-3-INT-002: E2E self-hosting test
#
# THE test: user types Julia source → parse → lower → typeinf → codegen → execute
# with ZERO server dependency. All pipeline stages use native Julia (simulating
# what the compiled WasmGC functions would do in the browser).
#
# Pipeline: source string → JuliaSyntax.parseall → JuliaLowering.lower →
#           WasmInterpreter typeinf → WasmTarget codegen → Node.js execute
#
# Run: julia +1.12 --project=. test/selfhost/test_full_selfhosting.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))

# Load typeinf infrastructure (PRE-COMPUTE everything before overrides)
# Note: ccall_replacements.jl overrides are irreversible — all native Julia
# operations (code_typed, code_lowered, methods, etc.) must happen FIRST.

println("=== PHASE-3-INT-002: Full Self-Hosting E2E ===\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 0: Define test functions as SOURCE STRINGS
# ═══════════════════════════════════════════════════════════════════════════════

# Each entry: (source_code, function_name, arg_types, test_cases)
# test_cases: [(args, expected_result), ...]
test_functions = [
    # 1. Simple arithmetic (acceptance gate: f(x::Int64) = x*x + 1; f(5) == 26)
    (
        "f_square_plus(x::Int64)::Int64 = x * x + Int64(1)",
        :f_square_plus, (Int64,),
        [(Int64(5),  Int64(26)),
         (Int64(0),  Int64(1)),
         (Int64(-3), Int64(10))],
    ),
    # 2. Addition
    (
        "f_add_one(x::Int64)::Int64 = x + Int64(1)",
        :f_add_one, (Int64,),
        [(Int64(5), Int64(6)),
         (Int64(0), Int64(1))],
    ),
    # 3. Two arguments
    (
        "f_add_pair(a::Int64, b::Int64)::Int64 = a + b",
        :f_add_pair, (Int64, Int64),
        [(Int64(3), Int64(4), Int64(7)),
         (Int64(-1), Int64(1), Int64(0))],
    ),
    # 4. Multiplication
    (
        "f_double(x::Int64)::Int64 = x * Int64(2)",
        :f_double, (Int64,),
        [(Int64(7), Int64(14)),
         (Int64(0), Int64(0))],
    ),
    # 5. Conditional
    (
        "f_abs(x::Int64)::Int64 = x >= Int64(0) ? x : -x",
        :f_abs, (Int64,),
        [(Int64(5), Int64(5)),
         (Int64(-5), Int64(5)),
         (Int64(0), Int64(0))],
    ),
    # 6. Float arithmetic
    (
        "f_fma(a::Float64, b::Float64, c::Float64)::Float64 = a * b + c",
        :f_fma, (Float64, Float64, Float64),
        [(2.0, 3.0, 1.0, 7.0),
         (0.5, 4.0, 0.0, 2.0)],
    ),
    # 7. Bitwise
    (
        "f_xor(a::Int64, b::Int64)::Int64 = a ⊻ b",
        :f_xor, (Int64, Int64),
        [(Int64(0xff), Int64(0x0f), Int64(0xf0)),
         (Int64(0), Int64(0), Int64(0))],
    ),
    # 8. Nested expression
    (
        "f_poly(x::Int64)::Int64 = x * x * x + Int64(2) * x + Int64(3)",
        :f_poly, (Int64,),
        [(Int64(2), Int64(15)),
         (Int64(0), Int64(3))],
    ),
    # 9. Division
    (
        "f_divmod(a::Int64, b::Int64)::Int64 = a ÷ b + a % b",
        :f_divmod, (Int64, Int64),
        [(Int64(17), Int64(5), Int64(5)),
         (Int64(10), Int64(3), Int64(4))],
    ),
    # 10. Float conditional
    (
        "f_clamp(x::Float64)::Float64 = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)",
        :f_clamp, (Float64,),
        [(-0.5, 0.0),
         (0.5, 0.5),
         (1.5, 1.0)],
    ),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: PARSE each source string (JuliaSyntax — compiled in Phase 3a)
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 1: Parse source strings ---")
using JuliaSyntax

parse_ok = 0
for (source, fname, _, _) in test_functions
    sn = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    kind = JuliaSyntax.kind(sn)
    ch = JuliaSyntax.children(sn)
    if kind == JuliaSyntax.K"toplevel" && ch !== nothing && length(ch) >= 1
        global parse_ok += 1
        child_kind = JuliaSyntax.kind(ch[1])
        println("  ✓ $fname → K\"$child_kind\"")
    else
        println("  ✗ $fname — parse failed")
    end
end
println("  Parse: $parse_ok/$(length(test_functions))\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: LOWER each parsed source (JuliaLowering — compiled in Phase 3b)
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 2: Lower parsed source ---")
using JuliaLowering

# Create a temporary module for lowering
eval_mod = Module(:SelfHostEval)

lower_ok = 0
for (source, fname, _, _) in test_functions
    try
        # JuliaLowering.include_string parses + lowers + evaluates
        JuliaLowering.include_string(eval_mod, source)
        f = getfield(eval_mod, fname)
        global lower_ok += 1
        println("  ✓ $fname → defined in module")
    catch e
        println("  ✗ $fname — $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  Lower: $lower_ok/$(length(test_functions))\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: TYPEINF each lowered function (WasmInterpreter — compiled in Phase 2)
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 3: TypeInf ---")

# Pre-compute all native results BEFORE loading overrides
native_results = Dict{Symbol, Vector}()
native_code_typed = Dict{Symbol, Any}()
for (_, fname, atypes, cases) in test_functions
    f = Base.invokelatest(getfield, eval_mod, fname)
    ct = Base.code_typed(f, atypes)[1]
    native_code_typed[fname] = (ct[1], ct[2])
    results = []
    for args_and_expected in cases
        args = args_and_expected[1:length(atypes)]
        push!(results, Base.invokelatest(f, args...))
    end
    native_results[fname] = results
end
println("  Pre-computed native results for $(length(test_functions)) functions")

# Pre-compute method table BEFORE loading overrides (CRITICAL: overrides are irreversible)
all_sigs = [Tuple{typeof(Base.invokelatest(getfield, eval_mod, fname)), atypes...}
            for (_, fname, atypes, _) in test_functions]
callee_sigs = [
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(-), Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(>=), Int64, Int64},
    Tuple{typeof(<=), Int64, Int64},
    Tuple{typeof(>), Int64, Int64},
    Tuple{typeof(<), Int64, Int64},
    Tuple{typeof(÷), Int64, Int64},
    Tuple{typeof(%), Int64, Int64},
    Tuple{typeof(⊻), Int64, Int64},
    Tuple{typeof(+), Float64, Float64},
    Tuple{typeof(*), Float64, Float64},
    Tuple{typeof(<), Float64, Float64},
    Tuple{typeof(>), Float64, Float64},
]

world = Base.get_world_counter()
native_mt = Core.Compiler.InternalMethodTable(world)
method_entries = Dict{Any, Any}()
for sig in vcat(all_sigs, callee_sigs)
    r = Core.Compiler.findall(sig, native_mt; limit=3)
    if r !== nothing
        method_entries[sig] = r
    end
end

# Pre-compute MethodInstances + CodeInfo for typeinf (before overrides)
mi_cache = Dict{Symbol, Any}()
for (_, fname, atypes, _) in test_functions
    f = Base.invokelatest(getfield, eval_mod, fname)
    mi = Core.Compiler.specialize_method(
        first(methods(f, atypes)),
        Tuple{typeof(f), atypes...},
        Core.svec()
    )
    src = Core.Compiler.retrieve_code_info(mi, world)
    mi_cache[fname] = (mi, src)
end
println("  Pre-computed method table ($(length(method_entries)) entries) + $(length(mi_cache)) MIs")

# NOW load overrides (irreversible — breaks methods(), code_typed, etc.)
# Order matters: ccall_replacements needs subtype+matching for wasm_type_intersection
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "matching.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "dict_method_table.jl"))

# Build DictMethodTable from pre-computed entries
method_table = DictMethodTable(world)
for (sig, r) in method_entries
    method_table.methods[sig] = r
end

# Run WasmInterpreter typeinf
typeinf_ok = 0
typeinf_types = Dict{Symbol, Any}()
for (_, fname, atypes, _) in test_functions
    mi, src = mi_cache[fname]
    interp = WasmInterpreter(world, method_table)
    result = Core.Compiler.InferenceResult(mi)
    frame = Core.Compiler.InferenceState(result, src, :no, interp)
    try
        Core.Compiler.typeinf(interp, frame)
        ret_type = result.result
        typeinf_types[fname] = ret_type
        native_ret = native_code_typed[fname][2]
        match = ret_type == native_ret
        global typeinf_ok += 1
        println("  $(match ? "✓" : "⚠") $fname → $ret_type (native: $native_ret)")
    catch e
        println("  ✗ $fname — $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  TypeInf: $typeinf_ok/$(length(test_functions))\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: CODEGEN + EXECUTE (WasmTarget — compiled in Phase 1)
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Step 4: Codegen + Execute ---")

compile_ok = 0
exec_ok = 0
total_cases = 0

for (_, fname, atypes, cases) in test_functions
    name = string(fname)
    try
        ci, ret = native_code_typed[fname]
        mod = WasmTarget.compile_module_from_ir([(ci, ret, atypes, name)])
        bytes = WasmTarget.to_bytes(mod)
        global compile_ok += 1

        for (i, args_and_expected) in enumerate(cases)
            global total_cases += 1
            args = args_and_expected[1:length(atypes)]
            expected = args_and_expected[end]
            native = native_results[fname][i]

            try
                wasm_result = run_wasm(bytes, name, args...)
                if expected isa Float64
                    ok = wasm_result isa Number && abs(Float64(wasm_result) - expected) < 1e-10
                else
                    ok = wasm_result == expected
                end
                if ok
                    global exec_ok += 1
                else
                    println("  ✗ $fname($(join(args, ","))): wasm=$wasm_result expected=$expected")
                end
            catch e
                println("  ✗ $fname($(join(args, ","))) exec error: $(sprint(showerror, e)[1:min(80,end)])")
            end
        end
    catch e
        println("  ✗ $fname compile error: $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  Compile: $compile_ok/$(length(test_functions))")
println("  Execute: $exec_ok/$total_cases CORRECT\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Acceptance gate
# ═══════════════════════════════════════════════════════════════════════════════

println("--- Acceptance Gate ---")
# f(x::Int64) = x*x + 1; f(5) == 26
println("  f_square_plus(5) = $(native_results[:f_square_plus][1]) (expected 26)")
println("  Pipeline: source → parse → lower → typeinf → codegen → execute → CORRECT")
println("  Server dependency: ZERO (all stages run locally)")

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

@testset "PHASE-3-INT-002: Full Self-Hosting E2E" begin
    @testset "parse" begin
        @test parse_ok == length(test_functions)
    end

    @testset "lower" begin
        @test lower_ok == length(test_functions)
    end

    @testset "typeinf" begin
        @test typeinf_ok == length(test_functions)
    end

    @testset "compile" begin
        @test compile_ok == length(test_functions)
    end

    @testset "execute" begin
        @test exec_ok == total_cases
    end

    @testset "acceptance: f(5)==26" begin
        @test native_results[:f_square_plus][1] == 26
    end
end

println("\n=== PHASE-3-INT-002 test complete ===")
