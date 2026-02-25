#!/usr/bin/env julia
# PURE-6022: Integration compile — full eval_julia_to_bytes as single WASM module
#
# All 37 codegen helpers individually VALIDATE (PURE-6025). Now compile the
# full eval_julia_to_bytes_vec pipeline as one module via compile_multi.
#
# Entry points:
#   eval_julia_to_bytes_vec(Vector{UInt8}) — full pipeline: parse→extract→typeinf→codegen
#   make_byte_vec(Int32), set_byte_vec!(Vector{UInt8}, Int32, Int32) — JS interop
#   eval_julia_result_length(Vector{UInt8}), eval_julia_result_byte(Vector{UInt8}, Int32) — extract results

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Helper functions to extract bytes from WasmGC Vector{UInt8} result
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

function main()
    println("=== PURE-6022: Integration compile eval_julia_to_bytes — single WASM module ===")
    println("Started: $(Dates.now())")
    println()

    # Phase 1: Verify native correctness (ground truth)
    println("[Phase 1] Verifying native correctness...")
    all_pass = true
    for (code, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
        try
            result = eval_julia_native(code)
            ok = result == expected
            println("  eval_julia_native(\"$code\") = $result $(ok ? "CORRECT" : "WRONG (expected $expected)")")
            all_pass = all_pass && ok
        catch e
            println("  eval_julia_native(\"$code\") = ERROR: $(sprint(showerror, e))")
            all_pass = false
        end
    end
    if !all_pass
        println("\nFAIL: Native verification failed. Not compiling to WASM.")
        exit(1)
    end
    println("  4/4 CORRECT natively ✓")
    println()

    # Phase 2: Compile to WASM — integration compile
    println("[Phase 2] Compiling eval_julia_to_bytes_vec + helpers to WASM...")
    println("  Entry point: eval_julia_to_bytes_vec(Vector{UInt8})")
    println("  (full pipeline: parse → extract → typeinf → codegen)")
    println()

    funcs_to_compile = [
        # Primary entry point — full pipeline
        (eval_julia_to_bytes_vec, (Vector{UInt8},)),
        # JS interop helpers (create/populate byte vectors)
        (make_byte_vec, (Int32,)),
        (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
        # Result extraction helpers
        (eval_julia_result_length, (Vector{UInt8},)),
        (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    ]

    outf = "/tmp/eval_julia.wasm"
    local wasm_bytes
    try
        t_start = time()
        wasm_bytes = WasmTarget.compile_multi(funcs_to_compile)
        t_elapsed = time() - t_start
        write(outf, wasm_bytes)
        println("  COMPILE SUCCESS")
        println("  Size: $(length(wasm_bytes)) bytes ($(round(length(wasm_bytes)/1024, digits=1)) KB)")
        println("  Time: $(round(t_elapsed, digits=1))s")
        println("  Written to: $outf")
    catch e
        println("  COMPILE ERROR:")
        println("  ", sprint(showerror, e))
        println()
        println("  Stack trace:")
        for (exc, bt) in Base.current_exceptions()
            showerror(stdout, exc, bt)
            println()
        end
        exit(1)
    end
    println()

    # Phase 3: Validate
    println("[Phase 3] Validating with wasm-tools...")
    errbuf = IOBuffer()
    validate_ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
        validate_ok = true
    catch; end

    if validate_ok
        println("  VALIDATES ✓")
    else
        err_msg = String(take!(errbuf))
        println("  VALIDATE_ERROR:")
        for line in split(err_msg, '\n')[1:min(10, end)]
            println("    $line")
        end
        # Try to identify the failing function
        m = match(r"func (\d+) failed", err_msg)
        if m !== nothing
            func_idx = Base.parse(Int, m.captures[1])
            println("\n  Failed func index: $func_idx")
        end
    end
    println()

    # Phase 4: Measure
    println("[Phase 4] Measuring module...")
    print_buf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
        wasm_text = String(take!(print_buf))
        func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
        export_count = count(l -> contains(l, "(export "), split(wasm_text, '\n'))
        println("  Functions: $func_count")
        println("  Exports: $export_count")
        println("  Module size: $(length(wasm_bytes)) bytes ($(round(length(wasm_bytes)/1024/1024, digits=2)) MB)")
    catch e
        println("  MEASURE ERROR: ", sprint(showerror, e))
    end
    println()

    # Summary
    println("=== SUMMARY ===")
    println("  Native: 4/4 CORRECT")
    println("  Compile: $(length(wasm_bytes)) bytes")
    println("  Validate: $(validate_ok ? "VALIDATES ✓" : "VALIDATE_ERROR ✗")")
    println("  Output: $outf")
    println("Done: $(Dates.now())")
end

main()
