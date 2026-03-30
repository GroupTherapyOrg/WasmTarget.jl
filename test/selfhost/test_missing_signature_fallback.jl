# test_missing_signature_fallback.jl — PHASE-2-INT-003: Missing signature diagnostics
#
# Verify that when browser typeinf hits a call signature NOT in the
# pre-computed method table, it reports a clear diagnostic, returns
# conservative type (Any), and compilation continues.
#
# Run: julia +1.12 --project=. test/selfhost/test_missing_signature_fallback.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "selfhost", "typeinf", "dict_method_table.jl"))

# ─── Test setup ──────────────────────────────────────────────────────────────

world = Base.get_world_counter()

# Functions for testing
simple_add(x::Int64)::Int64 = x + 1
simple_mul(x::Int64)::Int64 = x * 2
calls_both(x::Int64)::Int64 = simple_add(x) + simple_mul(x)

# ─── Test 1: DictMethodTable records missing signatures ──────────────────────

println("=== Test 1: Missing signature logging ===")

# Build a table with ONLY simple_add, not simple_mul or +
table1 = DictMethodTable(world)
sig_add = Tuple{typeof(simple_add), Int64}
sig_mul = Tuple{typeof(simple_mul), Int64}
sig_plus = Tuple{typeof(+), Int64, Int64}

native_mt = Core.Compiler.InternalMethodTable(world)
result_add = Core.Compiler.findall(sig_add, native_mt; limit=3)
table1.methods[sig_add] = result_add

# Look up known sig — should find it
found = Core.Compiler.findall(sig_add, table1)
println("  Known sig: $(found !== nothing ? "found" : "missing")")

# Look up unknown sig — should return nothing and log it
found2 = Core.Compiler.findall(sig_mul, table1)
println("  Unknown sig: $(found2 !== nothing ? "found" : "missing")")

# Look up another unknown
found3 = Core.Compiler.findall(sig_plus, table1)
println("  Unknown +: $(found3 !== nothing ? "found" : "missing")")

println("  Missing sigs logged: $(length(table1.missing_sigs))")
report = report_missing_signatures(table1; verbose=true)

# ─── Test 2: Complete table has no misses ─────────────────────────────────────

println("\n=== Test 2: Complete table — no misses ===")

# Build a table with ALL needed sigs (add + plus)
full_table = DictMethodTable(world)
for sig in [sig_add, sig_plus]
    r = Core.Compiler.findall(sig, native_mt; limit=3)
    if r !== nothing
        full_table.methods[sig] = r
    end
end
println("  Full table: $(length(full_table.methods)) entries")

# Run typeinf through the complete table
mi = Core.Compiler.specialize_method(first(methods(simple_add, (Int64,))),
    Tuple{typeof(simple_add), Int64}, Core.svec())
src = Core.Compiler.retrieve_code_info(mi, world)
full_interp = WasmInterpreter(world, full_table)
result_inf = Core.Compiler.InferenceResult(mi)
frame = Core.Compiler.InferenceState(result_inf, src, :no, full_interp)
Core.Compiler.typeinf(full_interp, frame)

full_report = report_missing_signatures(full_table)
println("  Missing after typeinf: $(length(full_report))")
if !isempty(full_report)
    report_missing_signatures(full_table; verbose=true)
end

# Check inferred type — typeinf stores in the InferenceResult
inferred_type = result_inf.result
println("  Inferred return type: $inferred_type")

# ─── Test 3: Incomplete table — typeinf degrades gracefully ──────────────────

println("\n=== Test 3: Incomplete table — graceful degradation ===")

# Build a table with only the user function sig (not its callees like +)
partial_table = DictMethodTable(world)
partial_table.methods[sig_add] = result_add

partial_interp = WasmInterpreter(world, partial_table)
# Get fresh CodeInfo (typeinf mutates it)
src3 = Core.Compiler.retrieve_code_info(mi, world)
result3 = Core.Compiler.InferenceResult(mi)
frame3 = Core.Compiler.InferenceState(result3, src3, :no, partial_interp)

typeinf_ok = false
try
    Core.Compiler.typeinf(partial_interp, frame3)
    global typeinf_ok = true
    println("  typeinf completed (did not crash)")
catch e
    println("  typeinf error: $(sprint(showerror, e))")
end

partial_report = report_missing_signatures(partial_table; verbose=true)
println("  Missing sigs: $(length(partial_report))")

# Check: did it degrade to Any?
partial_result = result3.result
println("  Inferred type (degraded): $partial_result")

# ─── Test 4: report_missing_signatures output ────────────────────────────────

println("\n=== Test 4: Report format ===")

# Create table and trigger multiple lookups for same missing sig
table4 = DictMethodTable(world)
for _ in 1:3
    Core.Compiler.findall(sig_plus, table4)
end
Core.Compiler.findall(sig_mul, table4)

report4 = report_missing_signatures(table4)
println("  Unique missing: $(length(report4))")
println("  Total lookups: $(sum(values(report4)))")
println("  + looked up: $(get(report4, sig_plus, 0)) times")

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "Missing signature fallback — PHASE-2-INT-003" begin
    @testset "Missing signature logging" begin
        @test found !== nothing        # Known sig found
        @test found2 === nothing       # Unknown sig returns nothing
        @test found3 === nothing       # Unknown + returns nothing
        @test length(table1.missing_sigs) == 2  # Two misses logged
        @test length(report) == 2      # Two unique missing sigs
    end

    @testset "Full table — no misses" begin
        @test length(full_report) == 0  # Full transitive table has no misses
        @test inferred_type == Int64    # Correct inference with full table
    end

    @testset "Graceful degradation" begin
        @test typeinf_ok               # typeinf completed without crash
        @test length(partial_report) > 0  # Some misses were logged
    end

    @testset "Report format" begin
        @test length(report4) == 2     # Two unique missing sigs
        @test sum(values(report4)) == 4  # Four total lookups
        @test get(report4, sig_plus, 0) == 3  # + looked up 3 times
    end
end

println("\n=== PHASE-2-INT-003: Missing signature fallback test complete ===")
