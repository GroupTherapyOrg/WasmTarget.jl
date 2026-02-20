#!/usr/bin/env julia
# compile_eval_julia_v3.jl — PURE-6021c
#
# Attempt to compile eval_julia_to_bytes(String) to WASM.
# This discovers the exact critical path (all reachable functions) and
# shows which ones have compile/validate errors — much more targeted than
# testing arbitrary 150/542 functions.
#
# If it succeeds: test for CORRECT (eval_julia_to_bytes("1+1") → 2 in WASM)
# If it fails: document the specific errors for targeted fixes

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6021c: compile eval_julia_to_bytes(String) → WASM ===")
println("Started: $(Dates.now())")
println()

# First verify native execution works
println("Step 0: Verify native eval_julia_to_bytes works...")
native_result = nothing
try
    bytes_native = eval_julia_to_bytes("1+1")
    println("  eval_julia_to_bytes('1+1') returned $(length(bytes_native)) bytes ✓")
    native_result = bytes_native
catch e
    println("  NATIVE FAIL: $(sprint(showerror, e))")
    println("  Cannot proceed without working native pipeline")
    exit(1)
end
println()

# Discover dependencies (what would be compiled into the WASM module)
println("Step 1: Discover dependencies of eval_julia_to_bytes...")
seed = [(eval_julia_to_bytes, (String,))]
dep_list = nothing
try
    dep_list = WasmTarget.discover_dependencies(seed)
    println("  Found $(length(dep_list)) functions in critical path")
catch e
    println("  discover_dependencies FAILED: $(sprint(showerror, e))")
    println("  Falling back to full compile attempt anyway...")
end
println()

# Attempt full compile
println("Step 2: Attempting compile(eval_julia_to_bytes, (String,))...")
println("  (This may take 1-5 minutes for the full dependency tree)")
println()

wasm_bytes = nothing
compile_err = nothing
t_start = time()
try
    wasm_bytes = compile(eval_julia_to_bytes, (String,))
    t_elapsed = time() - t_start
    println("  COMPILE SUCCESS: $(length(wasm_bytes)) bytes ($(round(t_elapsed, digits=1))s)")
catch e
    t_elapsed = time() - t_start
    compile_err = e
    println("  COMPILE FAILED after $(round(t_elapsed, digits=1))s:")
    println("  $(sprint(showerror, e))")
end
println()

if !isnothing(wasm_bytes)
    # Write to file for validation
    outf = joinpath(@__DIR__, "eval_julia_v3.wasm")
    write(outf, wasm_bytes)
    println("  Wrote $(length(wasm_bytes)) bytes to eval_julia_v3.wasm")

    # Validate
    println("Step 3: Validating...")
    errbuf = IOBuffer()
    validate_ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
        validate_ok = true
    catch; end

    if validate_ok
        println("  VALIDATES ✓")

        # Count functions
        print_buf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
        wasm_text = String(take!(print_buf))
        func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
        println("  Function count: $func_count")
        println()
        println("  RESULT: VALIDATES ✓ — ready to test for CORRECT")
        println("  Next: test eval_julia_to_bytes('1+1') in Node.js → expect 2")
    else
        err_msg = String(take!(errbuf))
        println("  VALIDATE_ERROR:")
        println("  $err_msg")
    end
else
    # Analyze compile error
    println("Step 3: Analyzing compile error for targeted fix...")
    if compile_err !== nothing
        err_str = sprint(showerror, compile_err)
        println("  Error type: $(typeof(compile_err))")
        println("  Full error: $err_str")

        # Extract useful info
        if compile_err isa BoundsError
            println()
            println("  BoundsError — likely SSAValue bounds issue in codegen")
            println("  See ARCHITECTURE.md for codegen.jl line references")
        end

        # Show backtrace
        bt = catch_backtrace()
        println()
        println("  Backtrace (first 20 frames):")
        io = IOBuffer()
        Base.show_backtrace(io, bt)
        bt_str = String(take!(io))
        lines = split(bt_str, '\n')
        for l in lines[1:min(30, end)]
            println("  $l")
        end
    end
end

println()
println("Done: $(Dates.now())")
