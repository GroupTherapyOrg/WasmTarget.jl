#!/usr/bin/env julia
# Tier 1 Test Extraction Script
# Extracts self-contained @test expressions from Julia's test suite.
#
# Usage: julia +1.12 --project=. test/tier1_suite/extract.jl
#
# Outputs: test/tier1_suite/extracted_tests.jl (included by the runner)

const JULIA_TEST_DIR = joinpath(Sys.STDLIB, "..", "..", "test")

# Tier 1 test files (§9.4.1 — pure computation, no FFI/IO/threading)
const TIER1_FILES = [
    "int.jl",
    "operators.jl",
    "combinatorics.jl",
    "some.jl",
    "char.jl",
    "floatfuncs.jl",
    "fastmath.jl",
    "parse.jl",
    "enums.jl",
    "functional.jl",
    "numbers.jl",
    "intfuncs.jl",
    "math.jl",
    "tuple.jl",
    "namedtuple.jl",
    "reduce.jl",
    "hashing.jl",
    "complex.jl",
    "rational.jl",
    "subtype.jl",
    "specificity.jl",
    "missing.jl",
]

# Patterns that indicate a test uses unsupported features
const INFEASIBLE_PATTERNS = [
    r"BigInt|BigFloat|big\(",             # GMP/MPFR
    r"@eval|Meta\.|eval\(",              # Runtime eval
    r"GC\.|finalizer",                    # GC control
    r"ccall|@ccall",                      # C FFI
    r"Threads\.|@async|@sync",           # Threading
    r"open\(|run\(|read\(|write\(",      # IO (be careful - write/read also used for math)
    r"sprint\(|IOBuffer|io\b",           # IO buffers
    r"stdout|stderr|stdin",              # Standard streams
    r"@allocated|@timed|@elapsed",       # Timing/allocation
    r"Ref\{|Ptr\{|pointer",             # Pointers
    r"Complex\{|im\b|complex\(",         # Complex numbers (for now)
    r"Rational\{|//",                    # Rationals (for now)
    r"missing\b|Missing",               # Missing values
    r"Random\.|rand\(|shuffle",         # Random
    r"Regex|r\"",                        # Regex
    r"@inferred",                        # Type inference testing
    r"@test_throws",                     # Exception tests (separate category)
    r"@test_broken",                     # Known broken tests
    r"typeof\(|isa\(|<:\s",             # Type system tests (complex)
    r"promote_type|convert\(",           # Type promotion (complex)
    r"@testset",                         # Nested testsets
    r"\bfor\b.*\bin\b",                 # Loop-based tests
    r"let\b",                           # Let blocks
    r"function\b",                       # Function definitions
    r"begin\b",                         # Begin blocks
    r"\.\.\.|\.\.\.",                    # Splatting
    r"@test\s+\!",                      # Negation tests (tricky)
    r"nothing\b|Nothing",              # Nothing type
    r"Some\(",                          # Some wrapper
    r"===",                             # Identity comparison (strict)
    r"≈|isapprox",                      # Approximate comparison
    r"string\(|repr\(",                # String formatting
    r"show\(|print",                   # Show/print
    r"Array|Vector|Matrix|Dict|Set",    # Collections
    r"Tuple\{|NamedTuple",             # Parameterized tuples
    r"Symbol|QuoteNode",               # Symbols
    r"Inf\b|NaN\b",                    # Special floats (some may work later)
    r"\bpi\b|π",                       # Pi constant
    r"typemax|typemin",                # Type bounds
    r"zero\(|one\(",                   # Type-parameterized zeros/ones
    # ---- Operations that compile but trap at runtime (stubbed methods) ----
    r"\bparse\(|tryparse\(",           # String→number parsing (complex Base method)
    r"@fastmath|macroexpand",          # Macro-related operations
    r"\breduce\(|\bfoldl\(|\bfoldr\(",  # Higher-order reduction (closure dispatch)
    r"\bmapreduce\(",                   # Map-reduce with closures
    r"\bmap\(|\bfilter\(",             # Higher-order with closures
    r"\bpowermod\(|\binvmod\(",        # Complex integer math
    r"\bhash\(",                        # Hash function (complex dispatch)
    r"\bmerge\(",                       # NamedTuple merge (complex)
    r"\bkeys\(|\bvalues\(",            # Collection accessors
    r"\bpermute!\(",                    # Array permutation
    r"\bfactorial\(",                  # Factorial (overflow checking)
    r"\bwiden\(",                      # Type widening (Int128 etc.)
    r"Int128|UInt128",                 # 128-bit integers (partial support)
    r"\bcollect\(",                    # Iterator materialization
    r"\bsort\(|\bsort!\(",            # Sorting
    r"\breverse\(",                    # Reverse (for collections)
    r"\b\.->",                         # Lambda with dot syntax
]

"""
Check if a @test line is self-contained and feasible for WasmTarget.
A self-contained test uses only literals and Base functions.
"""
function is_feasible(line::AbstractString)::Bool
    for pat in INFEASIBLE_PATTERNS
        if occursin(pat, line)
            return false
        end
    end
    return true
end

"""
Extract the expression from a @test line.
Returns the expression string, or nothing if not extractable.
"""
function extract_test_expr(line::AbstractString)
    # Match @test expr == value or @test expr
    m = match(r"@test\s+(.+)$", strip(line))
    if m === nothing
        return nothing
    end
    return strip(m.captures[1])
end

"""
Try to parse a test expression. Returns the parsed Expr or nothing.
"""
function try_parse(expr_str::AbstractString)
    try
        return Meta.parse(expr_str)
    catch
        return nothing
    end
end

"""
Check if an expression is a simple comparison (expr == value).
"""
function is_simple_comparison(expr)
    if expr isa Expr && expr.head == :call
        op = expr.args[1]
        if op in (:(==), :(!=), :(<=), :(>=), :(<), :(>))
            return true
        end
    end
    return false
end

"""
Extract all feasible @test expressions from a Julia test file.
Returns a vector of (line_number, expression_string, parsed_expr).
"""
function extract_from_file(filepath::AbstractString)
    if !isfile(filepath)
        @warn "File not found: $filepath"
        return []
    end

    lines = readlines(filepath)
    results = []

    for (i, line) in enumerate(lines)
        stripped = strip(line)

        # Must start with @test (not @test_throws, @testset, etc.)
        if !startswith(stripped, "@test ") && !startswith(stripped, "@test(")
            continue
        end

        # Skip multi-line tests (line ends with operator or opening bracket)
        if endswith(stripped, "\\") || endswith(stripped, ",") ||
           endswith(stripped, "(") || endswith(stripped, "[") ||
           endswith(stripped, "&&") || endswith(stripped, "||")
            continue
        end

        # Check feasibility
        if !is_feasible(stripped)
            continue
        end

        # Extract the expression
        expr_str = extract_test_expr(stripped)
        if expr_str === nothing
            continue
        end

        # Try to parse
        parsed = try_parse(expr_str)
        if parsed === nothing
            continue
        end

        push!(results, (line=i, expr_str=expr_str, parsed=parsed))
    end

    return results
end

"""
Run the extraction across all Tier 1 files and output statistics.
"""
function run_extraction()
    total_tests = 0
    total_extracted = 0
    all_tests = []

    println("=" ^ 70)
    println("Tier 1 Julia Test Suite Extraction")
    println("=" ^ 70)
    println()

    for filename in TIER1_FILES
        filepath = joinpath(JULIA_TEST_DIR, filename)

        # Count total @test lines
        if !isfile(filepath)
            println("  SKIP $filename — not found")
            continue
        end

        lines = readlines(filepath)
        total_in_file = count(l -> occursin(r"^\s*@test\s", l), lines)

        # Extract feasible tests
        extracted = extract_from_file(filepath)

        total_tests += total_in_file
        total_extracted += length(extracted)

        for t in extracted
            push!(all_tests, (file=filename, line=t.line, expr_str=t.expr_str, parsed=t.parsed))
        end

        println("  $filename: $(length(extracted))/$total_in_file extracted")
    end

    println()
    println("Total: $total_extracted/$total_tests tests extracted ($(round(100*total_extracted/max(total_tests,1), digits=1))%)")
    println()

    # Write extracted tests to file
    outpath = joinpath(@__DIR__, "extracted_tests.jl")
    open(outpath, "w") do io
        println(io, "# Auto-generated by extract.jl — $(length(all_tests)) extracted tests")
        println(io, "# Source: Julia $(VERSION) test suite, Tier 1 files")
        println(io, "# Generated: $(Dates.now())")
        println(io)
        println(io, "const EXTRACTED_TESTS = [")
        for (i, t) in enumerate(all_tests)
            # Escape \, ", and $ for inclusion in string literals
            expr_escaped = replace(t.expr_str, "\\" => "\\\\", "\"" => "\\\"", "\$" => "\\\$")
            println(io, "    (file=\"$(t.file)\", line=$(t.line), expr=\"$(expr_escaped)\"),")
        end
        println(io, "]")
    end

    println("Wrote $(length(all_tests)) tests to $outpath")

    return all_tests
end

using Dates

function verify_native(tests)
    println()
    println("=" ^ 70)
    println("Verifying extracted tests in native Julia...")
    println("=" ^ 70)

    native_pass = 0
    native_fail = 0
    native_error = 0
    verified = []
    error_reasons = Dict{String,Int}()

    for (i, t) in enumerate(tests)
        try
            result = Core.eval(Main, t.parsed)
            if result === true
                native_pass += 1
                push!(verified, t)
            else
                native_fail += 1
            end
        catch e
            native_error += 1
            reason = split(string(typeof(e)), '.')[end]
            error_reasons[reason] = get(error_reasons, reason, 0) + 1
        end
    end

    println()
    println("Native Julia verification:")
    println("  Pass:  $native_pass")
    println("  Fail:  $native_fail")
    println("  Error: $native_error ($(length(error_reasons)) distinct types)")
    for (reason, count) in sort(collect(error_reasons), by=x->-x[2])
        println("    $reason: $count")
    end
    println("  Total: $(length(tests))")
    println()
    println("$(length(verified)) tests pass in native Julia and are candidates for Wasm compilation")

    # Write verified tests list
    outpath = joinpath(@__DIR__, "verified_tests.jl")
    open(outpath, "w") do io
        println(io, "# Verified Tier 1 tests — pass in native Julia $(VERSION)")
        println(io, "# Generated: $(Dates.now())")
        println(io, "# $(length(verified)) tests from $(length(tests)) extracted")
        println(io)
        println(io, "const VERIFIED_TESTS = [")
        for t in verified
            # Must escape \, ", and $ to prevent interpolation
            expr_escaped = replace(t.expr_str, "\\" => "\\\\", "\"" => "\\\"", "\$" => "\\\$")
            println(io, "    (file=\"$(t.file)\", line=$(t.line), expr=\"$(expr_escaped)\"),")
        end
        println(io, "]")
    end
    println("Wrote $(length(verified)) verified tests to $outpath")

    return verified
end

tests = run_extraction()
verified = verify_native(tests)
