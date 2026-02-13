#!/usr/bin/env julia
# PURE-325: Batch Compilation for build_tree functions
# Compile each function individually, save .wasm files for Node.js testing

using WasmTarget
using JuliaSyntax

outdir = joinpath(@__DIR__, "..", "browser", "isolation")
mkpath(outdir)

println("=" ^ 60)
println("PURE-325: Batch Compile — build_tree functions")
println("Output directory: $outdir")
println("=" ^ 60)

# Helper: compile and save
function compile_and_save(name, f, arg_types)
    print("  $name... ")
    try
        bytes = compile(f, arg_types)
        outf = joinpath(outdir, "$(name).wasm")
        write(outf, bytes)
        # Validate
        try
            run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=devnull))
            println("$(length(bytes)) bytes, VALIDATES ✓")
            return (true, true, length(bytes))
        catch
            println("$(length(bytes)) bytes, VALIDATES=NO ✗")
            return (true, false, length(bytes))
        end
    catch e
        println("COMPILE=NO: $(sprint(showerror, e))")
        return (false, false, 0)
    end
end

# ============================================================================
# Phase 1: Wrapper functions that return simple types for Node.js testing
# ============================================================================

# Wrapper 1: tryparse_internal(Int64) returning i64
function wrap_tryparse_int64(s::String)::Int64
    result = Base.tryparse_internal(Int64, s, 1, ncodeunits(s), 10, false)
    result === nothing ? Int64(-1) : Int64(result)
end

# Wrapper 2: tryparse_internal(Int128) returning i64 (truncated for testing)
function wrap_tryparse_int128(s::String)::Int64
    result = Base.tryparse_internal(Int128, s, 1, ncodeunits(s), 10, false)
    result === nothing ? Int64(-1) : Int64(result)
end

# Wrapper 3: parse_int_literal returning i64 (the key build_tree function)
function wrap_parse_int_literal(s::String)::Int64
    result = JuliaSyntax.parse_int_literal(s)
    Int64(result)
end

# Wrapper 4: take!(IOBuffer) → length (since we can't return Vector easily)
function wrap_take_length()::Int64
    io = IOBuffer()
    write(io, UInt8(0x68))  # 'h'
    write(io, UInt8(0x65))  # 'e'
    write(io, UInt8(0x6c))  # 'l'
    write(io, UInt8(0x6c))  # 'l'
    write(io, UInt8(0x6f))  # 'o'
    result = take!(io)
    Int64(length(result))
end

# Wrapper 5: parse_float_literal → Float64 value only
function wrap_parse_float(s::String)::Float64
    buf = Vector{UInt8}(s)
    val, code = JuliaSyntax.parse_float_literal(Float64, buf, 1, length(buf))
    val
end

# ============================================================================
# Phase 2: Compile all functions
# ============================================================================

println("\n--- Direct functions ---")
compile_and_save("parse_int_literal", JuliaSyntax.parse_int_literal, (String,))
compile_and_save("tryparse_internal_Int64", Base.tryparse_internal, (Type{Int64}, String, Int64, Int64, Int64, Bool))
compile_and_save("tryparse_internal_Int128", Base.tryparse_internal, (Type{Int128}, String, Int64, Int64, Int64, Bool))
compile_and_save("take_IOBuffer", take!, (IOBuffer,))
compile_and_save("parse_float_literal_F64", JuliaSyntax.parse_float_literal, (Type{Float64}, Vector{UInt8}, Int64, Int64))

println("\n--- Wrapper functions (for Node.js testing) ---")
compile_and_save("wrap_tryparse_int64", wrap_tryparse_int64, (String,))
compile_and_save("wrap_tryparse_int128", wrap_tryparse_int128, (String,))
compile_and_save("wrap_parse_int_literal", wrap_parse_int_literal, (String,))
compile_and_save("wrap_take_length", wrap_take_length, ())
compile_and_save("wrap_parse_float", wrap_parse_float, (String,))

# ============================================================================
# Phase 3: Print native Julia ground truth
# ============================================================================

println("\n--- Native Julia Ground Truth ---")
println("  tryparse_internal(Int64, \"1\", 1, 1, 10, false) = $(Base.tryparse_internal(Int64, "1", 1, 1, 10, false))")
println("  tryparse_internal(Int64, \"42\", 1, 2, 10, false) = $(Base.tryparse_internal(Int64, "42", 1, 2, 10, false))")
println("  tryparse_internal(Int64, \"999\", 1, 3, 10, false) = $(Base.tryparse_internal(Int64, "999", 1, 3, 10, false))")
println("  tryparse_internal(Int128, \"1\", 1, 1, 10, false) = $(Base.tryparse_internal(Int128, "1", 1, 1, 10, false))")
println("  parse_int_literal(\"1\") = $(JuliaSyntax.parse_int_literal("1")) ($(typeof(JuliaSyntax.parse_int_literal("1"))))")
println("  parse_int_literal(\"42\") = $(JuliaSyntax.parse_int_literal("42")) ($(typeof(JuliaSyntax.parse_int_literal("42"))))")
println("  parse_int_literal(\"1_000\") = $(JuliaSyntax.parse_int_literal("1_000")) ($(typeof(JuliaSyntax.parse_int_literal("1_000"))))")
println("  take! test = $(let io=IOBuffer(); write(io,UInt8(0x68));write(io,UInt8(0x65));write(io,UInt8(0x6c));write(io,UInt8(0x6c));write(io,UInt8(0x6f)); length(take!(io)) end)")

buf = Vector{UInt8}("1.0")
println("  parse_float_literal(Float64, \"1.0\") = $(JuliaSyntax.parse_float_literal(Float64, buf, 1, 3))")
buf2 = Vector{UInt8}("3.14")
println("  parse_float_literal(Float64, \"3.14\") = $(JuliaSyntax.parse_float_literal(Float64, buf2, 1, 4))")

println("\nDone! Now test with Node.js: node scripts/test_isolation_node.mjs")
