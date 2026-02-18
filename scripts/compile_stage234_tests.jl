#!/usr/bin/env julia
# PURE-5001: Test stages 2-4 execution
#
# Stage 1 (parse) confirmed EXECUTING via build_tree.
# Now test stages 2-4 with compiled wrapper functions.

using WasmTarget
using JuliaSyntax
using JuliaLowering

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
using Core.Compiler: InferenceState

include(joinpath(@__DIR__, "..", "test", "utils.jl"))

println("=" ^ 60)
println("PURE-5001: Stages 2-4 Execution Tests")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════
# STAGE 2: Lowering
# _to_lowered_expr needs a SyntaxTree — too complex to construct.
# But we can test if the lowering module loads and simple helpers work.
# ═══════════════════════════════════════════════════════════════

# The lowering stage was compiled with:
#   (_to_lowered_expr, (CT, Int64)) where CT = SyntaxTree{SyntaxGraph{Dict{Symbol,Any}}}
# This is an internal JuliaLowering function that needs a proper syntax tree.
# We can't easily create one from scratch.
#
# Instead, let's test if we can chain parse → lowering in a single function.

# ═══════════════════════════════════════════════════════════════
# STAGE 3: Type inference reimpl — already confirmed 15/15 CORRECT
# ═══════════════════════════════════════════════════════════════

# Stage 3 reimpl functions (wasm_subtype, wasm_type_intersection) are
# already verified CORRECT from PURE-4151. Let's also test them here
# as a sanity check.

function test_subtype_int_number()::Int32
    return Int32(wasm_subtype(Int64, Number))
end

function test_subtype_int_string()::Int32
    return Int32(wasm_subtype(Int64, String))
end

function test_isect_int_number()::Int32
    result = wasm_type_intersection(Int64, Number)
    return result === Int64 ? Int32(1) : Int32(0)
end

function test_isect_int_string()::Int32
    result = wasm_type_intersection(Int64, String)
    return result === Union{} ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# STAGE 4: Codegen — WasmTarget.compile
# The compile function needs (Function, Type{Tuple{...}})
# Let's test it with a simple function
# ═══════════════════════════════════════════════════════════════

# Test: Can compile produce bytes?
function test_compile_produces_bytes()::Int32
    # compile(+, Tuple{Int64, Int64}) should produce .wasm bytes
    bytes = WasmTarget.compile(+, Tuple{Int64, Int64})
    return length(bytes) > 0 ? Int32(1) : Int32(0)
end

# Test: Is the compiled output reasonable size?
function test_compile_size()::Int32
    bytes = WasmTarget.compile(+, Tuple{Int64, Int64})
    # Simple Int64 addition should produce at least 50 bytes
    return length(bytes) > 50 ? Int32(1) : Int32(0)
end

tests = [
    ("test_subtype_int_number", test_subtype_int_number, (), Int32(1)),
    ("test_subtype_int_string", test_subtype_int_string, (), Int32(0)),
    ("test_isect_int_number", test_isect_int_number, (), Int32(1)),
    ("test_isect_int_string", test_isect_int_string, (), Int32(1)),
    # Stage 4 tests are special — self-hosting codegen
    ("test_compile_produces_bytes", test_compile_produces_bytes, (), Int32(1)),
    ("test_compile_size", test_compile_size, (), Int32(1)),
]

for (name, func, argtypes, expected) in tests
    println("\n--- $name ---")
    print("  Compiling: ")
    local wasm_bytes
    try
        wasm_bytes = compile_multi([(func, argtypes)])
        println("$(length(wasm_bytes)) bytes")
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 200))")
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    valid = try
        run(`wasm-tools validate --features=gc $tmpf`)
        true
    catch; false end

    if !valid
        valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
        println("  VALIDATE_ERROR: $(first(valerr, 200))")
        rm(tmpf, force=true)
        continue
    end

    if NODE_CMD !== nothing
        try
            actual = run_wasm(wasm_bytes, name)
            if actual == expected
                println("  CORRECT: $actual")
            else
                println("  WRONG: got $actual, expected $expected")
            end
        catch e
            emsg = sprint(showerror, e)
            if contains(emsg, "unreachable")
                println("  TRAP (unreachable)")
            elseif contains(emsg, "timeout") || contains(emsg, "hang")
                println("  HANG")
            else
                println("  ERROR: $(first(emsg, 150))")
            end
        end
    end
    rm(tmpf, force=true)
end

println("\nDone.")
