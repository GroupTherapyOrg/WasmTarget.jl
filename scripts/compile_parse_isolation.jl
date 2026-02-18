#!/usr/bin/env julia
# PURE-5001: Isolation tests for parsestmt subsystem
#
# Tests individual components of the JuliaSyntax parse pipeline to find
# which specific function traps.

using WasmTarget
using JuliaSyntax

println("=" ^ 60)
println("PURE-5001: Parse Subsystem Isolation Tests")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════
# Test 1: Can we create a SourceFile? (simplest constructor)
# ═══════════════════════════════════════════════════════════════
function test_sourcefile_create()::Int32
    sf = JuliaSyntax.SourceFile("1+1")
    return Int32(1)  # If we get here, it worked
end

# ═══════════════════════════════════════════════════════════════
# Test 2: Can we create a ParseStream?
# ═══════════════════════════════════════════════════════════════
function test_parsestream_create()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    return Int32(1)
end

# ═══════════════════════════════════════════════════════════════
# Test 3: Can we call parse! on a ParseStream?
# ═══════════════════════════════════════════════════════════════
function test_parse_bang()::Int32
    ps = JuliaSyntax.ParseStream("1+1")
    JuliaSyntax.parse!(ps)
    return Int32(1)
end

# ═══════════════════════════════════════════════════════════════
# Test 4: Full parsestmt(Expr, "1+1")
# ═══════════════════════════════════════════════════════════════
function test_parsestmt_full()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result isa Expr ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Test 5: String length (even simpler — can we handle strings at all?)
# ═══════════════════════════════════════════════════════════════
function test_string_length()::Int32
    s = "1+1"
    return Int32(length(s))
end

# ═══════════════════════════════════════════════════════════════
# Test 6: String ncodeunits (used by IOBuffer internally)
# ═══════════════════════════════════════════════════════════════
function test_string_ncodeunits()::Int32
    s = "1+1"
    return Int32(ncodeunits(s))
end

# ═══════════════════════════════════════════════════════════════
# Compile each test INDIVIDUALLY to isolate failures
# ═══════════════════════════════════════════════════════════════

include(joinpath(@__DIR__, "..", "test", "utils.jl"))

tests = [
    ("test_string_length", test_string_length, (), Int32(3)),
    ("test_string_ncodeunits", test_string_ncodeunits, (), Int32(3)),
    ("test_sourcefile_create", test_sourcefile_create, (), Int32(1)),
    ("test_parsestream_create", test_parsestream_create, (), Int32(1)),
    ("test_parse_bang", test_parse_bang, (), Int32(1)),
    ("test_parsestmt_full", test_parsestmt_full, (), Int32(1)),
]

results = Dict{String,String}()

for (name, func, argtypes, expected) in tests
    println("\n--- $name ---")
    print("  Compiling: ")
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, argtypes)])
        println("$(length(wasm_bytes)) bytes")
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 200))")
        results[name] = "COMPILE_ERROR"
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    print("  Validate: ")
    valid = try
        run(`wasm-tools validate --features=gc $tmpf`)
        println("VALIDATES ✓")
        true
    catch
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("VALIDATE_ERROR: $(first(valerr, 200))")
        false
    end

    if !valid
        results[name] = "VALIDATES_ERROR"
        rm(tmpf, force=true)
        continue
    end

    # Execute in Node.js
    if NODE_CMD !== nothing
        print("  Execute: ")
        try
            actual = run_wasm(wasm_bytes, name)
            if actual == expected
                println("CORRECT ✓ (returned $actual)")
                results[name] = "CORRECT"
            else
                println("WRONG (got $actual, expected $expected)")
                results[name] = "EXECUTES_WRONG"
            end
        catch e
            emsg = sprint(showerror, e)
            if contains(emsg, "unreachable") || contains(emsg, "trap")
                println("TRAP")
                results[name] = "TRAP"
            elseif contains(emsg, "timeout") || contains(emsg, "hang")
                println("HANG")
                results[name] = "HANG"
            else
                println("ERROR: $(first(emsg, 100))")
                results[name] = "ERROR"
            end
        end
    else
        results[name] = "VALIDATES_ONLY"
    end

    rm(tmpf, force=true)
end

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
println("\n" * "=" ^ 60)
println("PURE-5001: Parse Isolation Results")
println("=" ^ 60)
println("| Function | Result |")
println("|----------|--------|")
for (name, _, _, _) in tests
    result = get(results, name, "UNKNOWN")
    println("| $name | $result |")
end
println()
