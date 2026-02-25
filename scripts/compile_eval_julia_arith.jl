#!/usr/bin/env julia
# compile_eval_julia_arith.jl — PURE-6026
#
# Compile the WASM-compatible eval_julia pipeline for basic arithmetic.
# Uses _wasm_eval_arith_to_bytes as the seed — avoids Module/kwargs/string blockers.
# Pre-computed CodeInfo for +, -, * is evaluated at include() time (natively).
# The codegen (compile_module_from_ir) runs in WASM at runtime.

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
    println("=== PURE-6026: Compile WASM-compatible eval_julia (arith pipeline) ===")
    println("Started: $(Dates.now())")
    println()

    # Step 0: Verify native pipeline
    println("Step 0: Verify _wasm_eval_arith_to_bytes natively...")
    for expr in ["1+1", "2+3", "9-3", "6*7"]
        code_bytes = Vector{UInt8}(codeunits(expr))
        result = _wasm_eval_arith_to_bytes(code_bytes)
        println("  _wasm_eval_arith_to_bytes(\"$expr\"): $(length(result)) bytes")
    end
    println()

    # Step 1: Discover dependencies
    println("Step 1: Discovering dependencies...")
    seed = [
        # === NEW WASM-COMPATIBLE PIPELINE ===
        (_wasm_eval_arith_to_bytes, (Vector{UInt8},)),
        (eval_julia_test_arith_to_bytes, (Vector{UInt8},)),
        (_wasm_compile_codeinfo_to_bytes, (Core.CodeInfo, Type, String, Tuple)),
        # === HELPERS ===
        (eval_julia_result_length, (Vector{UInt8},)),
        (eval_julia_result_byte, (Vector{UInt8}, Int32)),
        (make_byte_vec, (Int32,)),
        (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
        # === PARSE DIAGNOSTICS (already CORRECT in WASM) ===
        (eval_julia_test_parse_arith, (Vector{UInt8},)),
        (_wasm_parse_arith, (JuliaSyntax.ParseStream,)),
    ]
    all_funcs = WasmTarget.discover_dependencies(seed)
    println("  Found $(length(all_funcs)) functions")
    println()

    # Step 2: Compile
    println("Step 2: Compiling...")
    t_start = time()
    wasm_bytes = WasmTarget.compile_multi(seed)
    t_elapsed = time() - t_start
    println("  COMPILE SUCCESS: $(length(wasm_bytes)) bytes ($(round(t_elapsed, digits=1))s)")
    println()

    # Step 3: Validate
    outf = joinpath(@__DIR__, "..", "output", "eval_julia_arith.wasm")
    mkpath(dirname(outf))
    write(outf, wasm_bytes)
    println("Step 3: Validating $(outf) ($(length(wasm_bytes)) bytes)...")

    errbuf = IOBuffer()
    validate_ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
        validate_ok = true
    catch; end

    if validate_ok
        println("  VALIDATES ✓")
        print_buf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
        wasm_text = String(take!(print_buf))
        func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
        println("  Function count: $func_count")
        println("  RESULT: VALIDATES ✓")
    else
        err_msg = String(take!(errbuf))
        println("  VALIDATE_ERROR:")
        for line in split(err_msg, '\n')[1:min(10, end)]
            println("  $line")
        end

        m = match(r"func (\d+) failed", err_msg)
        if m !== nothing
            func_idx = Base.parse(Int, m.captures[1])
            println("\n  Failed func index: $func_idx")
            # Find the export name
            print_buf = IOBuffer()
            try
                Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
                wasm_text = String(take!(print_buf))
                for line in split(wasm_text, '\n')
                    if contains(line, "(export") && contains(line, "(func $(func_idx))")
                        println("  Export: $line")
                    end
                end
            catch; end
        end
    end

    println()
    println("Done: $(Dates.now())")
end

main()
