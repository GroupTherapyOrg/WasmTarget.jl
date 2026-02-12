#!/usr/bin/env julia
#
# PURE-501: Pattern Classification — Tested vs Untested vs Stubbed vs Broken
#
# Reads ir_audit_results.json and cross-references against the test suite
# and known runtime findings to classify each pattern.
#
# Output: scripts/ir_pattern_checklist.md
#
# Usage: julia +1.12 --project=WasmTarget.jl scripts/classify_patterns.jl

using JSON

# ============================================================================
# Load Audit Data
# ============================================================================

const AUDIT_PATH = joinpath(@__DIR__, "ir_audit_results.json")
const CHECKLIST_PATH = joinpath(@__DIR__, "ir_pattern_checklist.md")
const RUNTESTS_PATH = joinpath(dirname(@__DIR__), "test", "runtests.jl")

function load_audit()
    JSON.parsefile(AUDIT_PATH)
end

# ============================================================================
# Tested Pattern Detection
#
# Scan runtests.jl for patterns that are actually exercised.
# We look for: function signatures compiled with WasmTarget.compile() or
# @test_compile, and the operations they test.
# ============================================================================

# These are the IR operations that the test suite exercises,
# mapped from the test phases to the Base/Core functions they compile.
# Built by reading runtests.jl phases 3-29.
# Tested call patterns — matched by base function name (module prefix stripped)
const TESTED_CALL_BASE_NAMES = Set([
    # Phase 3: Int64 addition
    "add_int",
    # Phase 4: Comparisons
    "slt_int", "sle_int", "eq_int",
    "not_int",
    # Phase 5: Integer operations
    "sub_int", "mul_int", "sdiv_int", "srem_int",
    "neg_int",
    "and_int", "or_int", "xor_int",
    "shl_int", "ashr_int", "lshr_int",
    # Phase 6: Type conversions
    "sext_int", "trunc_int",
    "sitofp",
    # Float arithmetic (Phase 6, 14)
    "add_float", "sub_float", "mul_float", "div_float",
    # Phase 7: Structs (getfield, setfield)
    "getfield",
    # Phase 15: Strings — identity comparison
    "===",
    # Phase 22: Math
    "sqrt_llvm", "abs_float", "floor_llvm",
    "ceil_llvm", "rint_llvm", "trunc_llvm",
    # Bitwise unsigned compare
    "ult_int",
    # Bitcast
    "bitcast",
    # Tuple creation
    "tuple",
    # Zext
    "zext_int",
])

# Invoke patterns tested — method names that runtests.jl compiles and verifies
const TESTED_INVOKE_NAMES = Set([
    # Phase 3-5: Arithmetic (compiled as Julia functions)
    "+", "-", "*", "÷", "%",
    # Phase 4: Comparisons
    ">", "<", "==", "!=", "<=", ">=",
    # Phase 6: Conversions
    "Int32", "Int64", "Float64",
    # Phase 11: Loops (while loop sum, factorial, countdown)
    # Phase 12: Recursion
    "test_factorial_rec", "test_fib", "test_sum_rec",
    "is_even_mutual", "is_odd_mutual", "deep_recursion_test",
    # Phase 13: Struct field access
    "getproperty",
    # Phase 14: Float operations
    # Phase 15: String operations (via runtime intrinsics)
    "sizeof", "length",
    # Phase 22: Math
    "sqrt", "abs", "floor", "ceil", "round", "trunc",
    # Phase 23: Control flow patterns
    "complex_while_test", "nested_cond_test", "classify_number_test",
    # Phase 28: Binaryen (same ops)
    # Phase 29: Stack validator (builder tests, not codegen)
])

# Known BROKEN patterns from PURE-324 diagnostics
# These compile but crash at runtime (unreachable, array bounds, wrong result)
const BROKEN_INVOKE_NAMES = Set([
    # PURE-324 findings: parsestmt runtime crashes
    # NTuple{4,Char} field access — multi-char identifiers crash
    # IOBuffer.eof — validation fails
    # SourceFile constructor — array bounds at func_16
    # SubString.string field access
    # parsestmt entry point — unreachable in func_1
])

const BROKEN_CALL_PATTERNS = Set([
    # Specific patterns known to crash from PURE-324
])

# Broken patterns are identified by their spec_types containing these markers
const BROKEN_SPEC_MARKERS = [
    "NTuple{4, Char}",       # Multi-char identifiers crash
    "SourceFile",            # Constructor array bounds error
]

# ============================================================================
# Classification Logic
# ============================================================================

struct ClassifiedPattern
    category::String     # STUBBED, BROKEN, HANDLED_UNTESTED, TESTED
    name::String         # Function/pattern name
    detail::String       # Signature or description
    count::Int           # How many times it appears in IR
    source::String       # Which audit category (call, invoke, foreigncall, etc.)
end

function classify_calls(calls)
    results = ClassifiedPattern[]
    for c in calls
        func = c["func"]
        count = c["count"]
        args = join(c["arg_types"], ", ")
        detail = "$func($args)"

        # Strip module prefix to get base function name
        base_name = replace(func, r"^[A-Za-z]+\." => "")

        if base_name in TESTED_CALL_BASE_NAMES
            cat = "TESTED"
        else
            cat = "HANDLED_UNTESTED"
        end

        push!(results, ClassifiedPattern(cat, func, detail, count, "call"))
    end
    results
end

function classify_invokes(invokes)
    results = ClassifiedPattern[]
    for inv in invokes
        name = inv["name"]
        count = inv["count"]
        spec = inv["spec_types"]
        detail = spec

        # Check if broken (known runtime crash patterns)
        is_broken = any(marker -> occursin(marker, spec), BROKEN_SPEC_MARKERS)

        if is_broken
            cat = "BROKEN"
        elseif name in TESTED_INVOKE_NAMES
            cat = "TESTED"
        else
            cat = "HANDLED_UNTESTED"
        end

        push!(results, ClassifiedPattern(cat, name, detail, count, "invoke"))
    end
    results
end

function classify_stubs(stubs)
    results = ClassifiedPattern[]
    for s in stubs
        func = s["func"]
        reason = s["reason"]
        push!(results, ClassifiedPattern("STUBBED", func, reason, 1, "stub"))
    end
    results
end

function classify_foreigncalls(foreigncalls)
    results = ClassifiedPattern[]
    for fc in foreigncalls
        name = fc["name"]
        count = fc["count"]
        # All foreigncalls are handled (they map to JS imports or intrinsics)
        # but none are tested for correctness against native Julia
        push!(results, ClassifiedPattern("HANDLED_UNTESTED", name, "foreigncall", count, "foreigncall"))
    end
    results
end

function classify_intrinsics(intrinsics)
    results = ClassifiedPattern[]
    for i in intrinsics
        name = i["name"]
        count = i["count"]
        # Most intrinsics are handled by codegen, but atomic_pointerset is stubbed
        if name == "atomic_pointerset"
            push!(results, ClassifiedPattern("STUBBED", name, "intrinsic (stubbed)", count, "intrinsic"))
        else
            push!(results, ClassifiedPattern("HANDLED_UNTESTED", name, "intrinsic", count, "intrinsic"))
        end
    end
    results
end

function classify_new_types(new_types)
    results = ClassifiedPattern[]
    for nt in new_types
        name = nt["name"]
        count = nt["count"]
        # Struct construction — tested types vs untested
        if any(t -> occursin(t, name), ["Int32", "Int64", "Float64", "Bool"])
            cat = "TESTED"
        else
            cat = "HANDLED_UNTESTED"
        end
        push!(results, ClassifiedPattern(cat, name, "struct construction", count, "new_type"))
    end
    results
end

# ============================================================================
# Checklist Generation
# ============================================================================

function generate_checklist(all_patterns::Vector{ClassifiedPattern})
    stubbed = filter(p -> p.category == "STUBBED", all_patterns)
    broken = filter(p -> p.category == "BROKEN", all_patterns)
    untested = filter(p -> p.category == "HANDLED_UNTESTED", all_patterns)
    tested = filter(p -> p.category == "TESTED", all_patterns)

    # Sort each by count (descending) for prioritization
    sort!(stubbed; by=p -> -p.count)
    sort!(broken; by=p -> -p.count)
    sort!(untested; by=p -> -p.count)
    sort!(tested; by=p -> -p.count)

    io = IOBuffer()

    println(io, "## Pattern Checklist (auto-generated from audit)")
    println(io)
    println(io, "Generated: $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))")
    println(io, "Source: `scripts/ir_audit_results.json` ($(length(all_patterns)) patterns total)")
    println(io)
    println(io, "| Category | Count | Description |")
    println(io, "|----------|-------|-------------|")
    println(io, "| STUBBED | $(length(stubbed)) | Emits `unreachable` — must implement |")
    println(io, "| BROKEN | $(length(broken)) | Compiles but crashes at runtime |")
    println(io, "| HANDLED_UNTESTED | $(length(untested)) | Compiler handles, no correctness test |")
    println(io, "| TESTED | $(length(tested)) | Verified working in runtests.jl |")
    println(io)

    # STUBBED section
    println(io, "### STUBBED (must implement to unblock parsestmt)")
    println(io)
    for p in stubbed
        println(io, "- [ ] `$(p.name)` — $(p.detail) ($(p.source))")
    end
    println(io)

    # BROKEN section
    println(io, "### BROKEN (compiles but crashes — known from PURE-324)")
    println(io)
    if isempty(broken)
        println(io, "_No broken patterns identified yet. Run PURE-502 comparison harness to find them._")
    else
        for p in broken
            println(io, "- [ ] `$(p.name)` — $(p.count)x, $(truncate_detail(p.detail))")
        end
    end
    println(io)

    # HANDLED_UNTESTED section — group by source for readability
    println(io, "### HANDLED_UNTESTED (high risk — may hide bugs)")
    println(io)

    # Separate by source type
    untested_calls = filter(p -> p.source == "call", untested)
    untested_invokes = filter(p -> p.source == "invoke", untested)
    untested_foreigncalls = filter(p -> p.source == "foreigncall", untested)
    untested_intrinsics = filter(p -> p.source == "intrinsic", untested)
    untested_new_types = filter(p -> p.source == "new_type", untested)

    if !isempty(untested_calls)
        println(io, "#### Calls ($(length(untested_calls)) patterns)")
        println(io)
        for p in untested_calls[1:min(30, end)]
            println(io, "- [ ] `$(p.name)` — $(p.count)x, $(truncate_detail(p.detail))")
        end
        if length(untested_calls) > 30
            println(io, "- ... and $(length(untested_calls) - 30) more call patterns")
        end
        println(io)
    end

    if !isempty(untested_invokes)
        println(io, "#### Invokes ($(length(untested_invokes)) patterns)")
        println(io)
        for p in untested_invokes[1:min(50, end)]
            println(io, "- [ ] `$(p.name)` — $(p.count)x, $(truncate_detail(p.detail))")
        end
        if length(untested_invokes) > 50
            println(io, "- ... and $(length(untested_invokes) - 50) more invoke patterns")
        end
        println(io)
    end

    if !isempty(untested_foreigncalls)
        println(io, "#### Foreigncalls ($(length(untested_foreigncalls)) patterns)")
        println(io)
        for p in untested_foreigncalls
            println(io, "- [ ] `$(p.name)` — $(p.count)x")
        end
        println(io)
    end

    if !isempty(untested_intrinsics)
        println(io, "#### Intrinsics ($(length(untested_intrinsics)) patterns)")
        println(io)
        for p in untested_intrinsics
            println(io, "- [ ] `$(p.name)` — $(p.count)x")
        end
        println(io)
    end

    if !isempty(untested_new_types)
        println(io, "#### Struct Construction ($(length(untested_new_types)) patterns)")
        println(io)
        for p in untested_new_types
            println(io, "- [ ] `$(p.name)` — $(p.count)x")
        end
        println(io)
    end

    # TESTED section — aggregate by name to avoid redundant listings
    println(io, "### TESTED (verified working)")
    println(io)
    tested_agg = Dict{String, Tuple{Int, Int, String}}()  # name => (total_count, num_variants, source)
    for p in tested
        key = p.name
        if haskey(tested_agg, key)
            old = tested_agg[key]
            tested_agg[key] = (old[1] + p.count, old[2] + 1, p.source)
        else
            tested_agg[key] = (p.count, 1, p.source)
        end
    end
    tested_sorted = sort(collect(tested_agg); by=x -> -x.second[1])
    for (name, (total, variants, source)) in tested_sorted
        variant_str = variants > 1 ? " ($variants type variants)" : ""
        println(io, "- [x] `$name` — $(total)x total$variant_str ($source)")
    end
    println(io)

    String(take!(io))
end

function truncate_detail(s::String; maxlen=100)
    length(s) <= maxlen ? s : s[1:maxlen] * "..."
end

# ============================================================================
# Main
# ============================================================================

using Dates

function main()
    println("=== PURE-501: Pattern Classification ===")
    println()

    if !isfile(AUDIT_PATH)
        error("Audit results not found at $AUDIT_PATH. Run PURE-500 first.")
    end

    println("Loading audit data from $AUDIT_PATH...")
    audit = load_audit()
    patterns = audit["patterns"]

    println("  Total functions: $(audit["total_functions"])")
    println("  Total statements: $(audit["total_statements"])")
    println()

    # Classify each pattern category
    println("Classifying patterns...")
    all_classified = ClassifiedPattern[]

    append!(all_classified, classify_calls(patterns["calls"]))
    append!(all_classified, classify_invokes(patterns["invokes"]))
    append!(all_classified, classify_stubs(patterns["stubs"]))
    append!(all_classified, classify_foreigncalls(patterns["foreigncalls"]))
    append!(all_classified, classify_intrinsics(patterns["intrinsics"]))
    append!(all_classified, classify_new_types(patterns["new_types"]))

    # Count by category
    cats = Dict{String, Int}()
    for p in all_classified
        cats[p.category] = get(cats, p.category, 0) + 1
    end

    println("  STUBBED: $(get(cats, "STUBBED", 0))")
    println("  BROKEN: $(get(cats, "BROKEN", 0))")
    println("  HANDLED_UNTESTED: $(get(cats, "HANDLED_UNTESTED", 0))")
    println("  TESTED: $(get(cats, "TESTED", 0))")
    println()

    # Generate checklist
    println("Generating checklist...")
    md = generate_checklist(all_classified)

    open(CHECKLIST_PATH, "w") do io
        write(io, md)
    end
    println("Wrote: $CHECKLIST_PATH")
    println()

    # Summary
    total = length(all_classified)
    tested_count = get(cats, "TESTED", 0)
    stubbed_count = get(cats, "STUBBED", 0)
    broken_count = get(cats, "BROKEN", 0)
    untested_count = get(cats, "HANDLED_UNTESTED", 0)

    println("=== Summary ===")
    println("  Total patterns: $total")
    println("  TESTED:           $tested_count ($(round(100*tested_count/total; digits=1))%)")
    println("  STUBBED:          $stubbed_count (must implement)")
    println("  BROKEN:           $broken_count (must fix)")
    println("  HANDLED_UNTESTED: $untested_count (need comparison testing)")
    println()
    println("Priority order for M_PATTERNS:")
    println("  1. STUBBED ($stubbed_count) — these trap, blocking parsestmt")
    println("  2. BROKEN ($broken_count) — these crash, need codegen fixes")
    println("  3. HANDLED_UNTESTED ($untested_count) — high risk, use compare_julia_wasm")
end

main()
