#!/usr/bin/env julia
# S-001: Reproduce stackifier bug with minimal case
#
# The stackifier produces wrong results for large branchy functions
# (many GotoIfNot with forward-only jumps, no loops).
#
# Known failing functions:
#   - is_operator_start_char('+') → expected 1 (true), gets 0 (false)
#   - is_never_id_char (some inputs wrong)
#   - sin(PI/4) → expected ~0.707, gets 0
#
# The bug: The stackifier's control flow (block/br) structure has an error
# for deeply nested forward branches, causing the wrong code path to be taken
# and returning the default-initialized local value (0).

using Test
using JuliaSyntax, JuliaSyntax.Tokenize
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))

# ── Step 1: Verify native Julia behavior ────────────────────────────────────
println("=== Native Julia ground truth ===")

# is_operator_start_char: checks if a character starts an operator
println("is_operator_start_char('+') = ", Tokenize.is_operator_start_char('+'))  # true
println("is_operator_start_char('-') = ", Tokenize.is_operator_start_char('-'))  # true
println("is_operator_start_char('*') = ", Tokenize.is_operator_start_char('*'))  # true
println("is_operator_start_char('a') = ", Tokenize.is_operator_start_char('a'))  # false
println("is_operator_start_char('1') = ", Tokenize.is_operator_start_char('1'))  # false
println("is_operator_start_char('=') = ", Tokenize.is_operator_start_char('='))  # true
println("is_operator_start_char('<') = ", Tokenize.is_operator_start_char('<'))  # true
println("is_operator_start_char('>') = ", Tokenize.is_operator_start_char('>'))  # true

# ── Step 2: Inspect IR ─────────────────────────────────────────────────────
println("\n=== IR Analysis ===")
ci_list = Base.code_typed(Tokenize.is_operator_start_char, (Char,), optimize=true)
ci = ci_list[1][1]
rettype = ci_list[1][2]
println("Return type: $rettype")
println("Statements: $(length(ci.code))")

# Count control flow patterns
n_gotoifnot = count(s -> s isa Core.GotoIfNot, ci.code)
n_goto = count(s -> s isa Core.GotoNode, ci.code)
n_phi = count(s -> s isa Core.PhiNode, ci.code)
n_return = count(s -> s isa Core.ReturnNode, ci.code)
println("GotoIfNot: $n_gotoifnot")
println("GotoNode: $n_goto")
println("PhiNode: $n_phi")
println("ReturnNode: $n_return")

# ── Step 3: Compile to WASM ─────────────────────────────────────────────────
println("\n=== Compile to WASM ===")
bytes = WasmTarget.compile(Tokenize.is_operator_start_char, (Char,))
println("WASM size: $(length(bytes)) bytes")

# Write WASM for inspection
wasm_path = joinpath(@__DIR__, "stackifier_bug.wasm")
write(wasm_path, bytes)
println("Written to: $wasm_path")

# ── Step 4: Run in Node.js and compare ──────────────────────────────────────
println("\n=== WASM Execution Results ===")

test_cases = [
    ('+', true),   # 0x2B = 43
    ('-', true),   # 0x2D = 45
    ('*', true),   # 0x2A = 42
    ('=', true),   # 0x3D = 61
    ('<', true),   # 0x3C = 60
    ('>', true),   # 0x3E = 62
    ('a', false),  # 0x61 = 97
    ('1', false),  # 0x31 = 49
    ('z', false),  # 0x7A = 122
    (' ', false),  # 0x20 = 32
]

results = []
for (ch, expected) in test_cases
    native_result = Tokenize.is_operator_start_char(ch)
    # Char maps to i32 in WASM
    wasm_result = run_wasm(bytes, "is_operator_start_char", Int32(ch))
    expected_i32 = native_result ? 1 : 0

    pass = (wasm_result == expected_i32)
    status = pass ? "PASS" : "FAIL"
    push!(results, pass)

    println("  '$ch' ($(Int(ch))): native=$native_result, wasm=$wasm_result, expected=$expected_i32 → $status")
end

println("\nResults: $(count(results)) pass, $(count(!, results)) fail out of $(length(test_cases))")

# ── Step 5: Also test is_never_id_char for comparison ──────────────────────
println("\n=== is_never_id_char ===")
ci_list2 = Base.code_typed(Tokenize.is_never_id_char, (Char,), optimize=true)
ci2 = ci_list2[1][1]
println("Statements: $(length(ci2.code))")
println("GotoIfNot: $(count(s -> s isa Core.GotoIfNot, ci2.code))")

bytes2 = WasmTarget.compile(Tokenize.is_never_id_char, (Char,))
println("WASM size: $(length(bytes2)) bytes")
write(joinpath(@__DIR__, "stackifier_bug_never_id.wasm"), bytes2)

never_id_cases = [
    ('(', true),   # parenthesis - never an identifier
    (')', true),
    ('[', true),
    (']', true),
    ('{', true),
    ('}', true),
    ('a', false),  # letter - could be identifier
    ('_', false),  # underscore - could be identifier
    (' ', true),   # space
    ('+', true),   # operator
]

for (ch, expected) in never_id_cases
    native_result = Tokenize.is_never_id_char(ch)
    wasm_result = run_wasm(bytes2, "is_never_id_char", Int32(ch))
    expected_i32 = native_result ? 1 : 0
    pass = (wasm_result == expected_i32)
    status = pass ? "PASS" : "FAIL"
    println("  '$ch' ($(Int(ch))): native=$native_result, wasm=$wasm_result, expected=$expected_i32 → $status")
end

# ── Step 6: Analyze the specific block structure for '+' ────────────────────
println("\n=== Block structure analysis for is_operator_start_char ===")
println("Dumping IR for manual inspection:")
println("(Use `julia +1.12 -e 'using JuliaSyntax.Tokenize; display(Base.code_typed(Tokenize.is_operator_start_char, (Char,), optimize=true)[1][1])' ` to view)")

# Show first and last few statements to understand the pattern
println("\nFirst 20 statements:")
for i in 1:min(20, length(ci.code))
    println("  [$i] $(ci.code[i])  :: $(ci.ssavaluetypes[i])")
end
println("\nLast 20 statements:")
for i in max(1, length(ci.code)-19):length(ci.code)
    println("  [$i] $(ci.code[i])  :: $(ci.ssavaluetypes[i])")
end
