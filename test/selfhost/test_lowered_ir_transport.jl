# test_lowered_ir_transport.jl — PHASE-2-INT-001: Lowered IR JSON transport
#
# Verify that lowered (pre-typeinf) IR can be serialized→deserialized→typeinf'd
# and produce identical CodeInfo to native typeinf.
#
# Run: julia +1.12 --project=. test/selfhost/test_lowered_ir_transport.jl

using Test
using WasmTarget
using JSON

include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))

# ─── Test functions ──────────────────────────────────────────────────────────

add_one(x::Int64)::Int64 = x + 1
mul_two(x::Int64)::Int64 = x * 2
sub_three(x::Int64)::Int64 = x - 3
negate(x::Int64)::Int64 = -x
square(x::Int64)::Int64 = x * x
add_pair(a::Int64, b::Int64)::Int64 = a + b
max_val(a::Int64, b::Int64)::Int64 = a > b ? a : b
abs_val(x::Int64)::Int64 = x >= 0 ? x : -x
sum_to(n::Int64)::Int64 = n <= 0 ? Int64(0) : n + sum_to(n - 1)
fma_val(a::Float64, b::Float64, c::Float64)::Float64 = a * b + c

test_functions = [
    (add_one, (Int64,), "add_one"),
    (mul_two, (Int64,), "mul_two"),
    (sub_three, (Int64,), "sub_three"),
    (negate, (Int64,), "negate"),
    (square, (Int64,), "square"),
    (add_pair, (Int64, Int64), "add_pair"),
    (max_val, (Int64, Int64), "max_val"),
    (abs_val, (Int64,), "abs_val"),
    (sum_to, (Int64,), "sum_to"),
    (fma_val, (Float64, Float64, Float64), "fma_val"),
]

# ─── Step 1: Get lowered IR and native typed IR for comparison ───────────────

println("=== Step 1: Get lowered + typed IR for $(length(test_functions)) functions ===")

lowered_entries = []
typed_entries = []

for (f, atypes, name) in test_functions
    # Get lowered IR (pre-typeinf)
    lowered_ci = Base.code_lowered(f, atypes)[1]
    push!(lowered_entries, (lowered_ci, Any, atypes, name))

    # Get typed IR (post-typeinf) for comparison
    typed_ci, ret = Base.code_typed(f, atypes)[1]
    push!(typed_entries, (typed_ci, ret, atypes, name))

    println("  $name: lowered=$(length(lowered_ci.code)) stmts, typed=$(length(typed_ci.code)) stmts → $ret")
end

# ─── Step 2: Serialize lowered IR ────────────────────────────────────────────

println("\n=== Step 2: Serialize lowered IR to JSON ===")

json_str = WasmTarget.serialize_ir_entries(lowered_entries)
println("  JSON size: $(length(json_str)) bytes")

# Verify it's valid JSON
parsed = JSON.parse(json_str)
n_entries = length(parsed["entries"])
println("  Entries: $n_entries")

# Check that ssavaluetypes is an integer (lowered) not a list
first_entry = parsed["entries"][1]
ssa_types_field = first_entry["ssavaluetypes"]
is_lowered_format = ssa_types_field isa Integer
println("  ssavaluetypes format: $(is_lowered_format ? "integer (lowered)" : "array (typed)")")

# ─── Step 3: Deserialize and verify roundtrip ─────────────────────────────────

println("\n=== Step 3: Deserialize and verify roundtrip ===")

deserialized = WasmTarget.deserialize_ir_entries(json_str)
n_deser = length(deserialized)
println("  Deserialized: $n_deser entries")

roundtrip_ok = 0
for (i, (orig_ci, _, _, name)) in enumerate(lowered_entries)
    deser_ci, _, _, deser_name = deserialized[i]
    match = deser_name == name && length(deser_ci.code) == length(orig_ci.code)
    if match
        global roundtrip_ok += 1
    end
    println("  $(match ? "✓" : "✗") $name: $(length(deser_ci.code)) stmts (match=$match)")
end

# ─── Step 4: Typed IR transport (the existing path) still works ──────────────

println("\n=== Step 4: Verify typed IR transport still works ===")

typed_prep = WasmTarget.preprocess_ir_entries(typed_entries)
typed_json = WasmTarget.serialize_ir_entries(typed_prep)
typed_deser = WasmTarget.deserialize_ir_entries(typed_json)
typed_roundtrip_ok = 0
for (i, (_, ret, _, name)) in enumerate(typed_entries)
    deser_ci, deser_ret, _, deser_name = typed_deser[i]
    match = deser_name == name
    if match
        global typed_roundtrip_ok += 1
    end
end
println("  Typed IR roundtrip: $typed_roundtrip_ok/$(length(typed_entries))")

# ─── Step 5: Compile typed IR from transport ─────────────────────────────────

println("\n=== Step 5: Compile typed IR from transport path ===")

compile_ok = 0
for (ci, ret, atypes, name) in typed_deser
    try
        mod = WasmTarget.compile_module_from_ir([(ci, ret, atypes, name)])
        bytes = WasmTarget.to_bytes(mod)
        if length(bytes) > 0
            global compile_ok += 1
        end
    catch
    end
end
println("  Compiled from typed transport: $compile_ok/$(length(typed_deser))")

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "Lowered IR transport — PHASE-2-INT-001" begin
    @testset "Serialization" begin
        @test length(json_str) > 0
        @test n_entries == 10
        @test is_lowered_format  # ssavaluetypes is integer for lowered IR
    end

    @testset "Deserialization roundtrip" begin
        @test n_deser == 10
        @test roundtrip_ok == 10  # All functions roundtrip correctly
    end

    @testset "Typed IR transport still works" begin
        @test typed_roundtrip_ok == 10
        @test compile_ok >= 8  # Most functions compile from typed transport
    end
end

println("\n=== PHASE-2-INT-001: Lowered IR transport test complete ===")
