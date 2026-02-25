#!/usr/bin/env julia
# Count all validation errors in the eval_julia module by iteratively stubbing
# failing functions and re-validating.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

function main()
    println("=== Counting validation errors ===")

    funcs_to_compile = [
        (eval_julia_to_bytes_vec, (Vector{UInt8},)),
        (make_byte_vec, (Int32,)),
        (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
        (eval_julia_result_length, (Vector{UInt8},)),
        (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    ]

    println("Compiling...")
    t = time()
    wasm_bytes = WasmTarget.compile_multi(funcs_to_compile)
    println("Compiled in $(round(time()-t, digits=1))s ($(length(wasm_bytes)) bytes)")

    outf = "/tmp/eval_julia_count.wasm"
    write(outf, wasm_bytes)

    # Count total functions
    print_buf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
    wasm_text = String(take!(print_buf))
    func_count = count(l -> contains(l, "(func (;"), split(wasm_text, '\n'))
    println("Total defined functions: $func_count")

    # Iterate: validate → find first failing func → record → stub → repeat
    failing_funcs = Int[]
    max_iterations = 200  # Safety limit

    for iteration in 1:max_iterations
        errbuf = IOBuffer()
        validate_ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
            validate_ok = true
        catch; end

        if validate_ok
            println("\nVALIDATES after stubbing $(length(failing_funcs)) functions!")
            break
        end

        err_msg = String(take!(errbuf))
        m = match(r"func (\d+) failed", err_msg)
        if m === nothing
            println("ERROR: Can't parse validation error: $err_msg")
            break
        end

        func_idx = Base.parse(Int, m.captures[1])
        push!(failing_funcs, func_idx)

        # Extract error type
        cause = match(r"Caused by:\s*\n\s*\d+: (.+)", err_msg)
        cause_str = cause !== nothing ? cause.captures[1] : "unknown"

        if iteration <= 30 || iteration % 10 == 0
            println("  [$iteration] func $func_idx: $cause_str")
        end

        # Stub the failing function in WAT: replace body with (unreachable)
        # Use wasm-tools to roundtrip: print → modify → assemble
        # For speed, use a sed-like approach: find the func definition line and replace
        # Actually, let's use a binary approach: patch the function body

        # Simpler approach: use wasm-tools print/parse roundtrip with sed
        # Find func N in the text, replace its body with unreachable
        # This is slow but reliable
        wat_file = "/tmp/eval_julia_count.wat"
        Base.run(pipeline(`wasm-tools print $outf`, stdout=wat_file))

        # Read WAT, find func N, replace body
        lines = readlines(wat_file)
        in_target_func = false
        depth = 0
        func_start_line = 0
        func_end_line = 0

        for (li, line) in enumerate(lines)
            if contains(line, "(func (;$func_idx;)")
                in_target_func = true
                func_start_line = li
                depth = 1  # The opening paren of (func ...)
                continue
            end
            if in_target_func
                # Count parens to find matching close
                for ch in line
                    if ch == '('
                        depth += 1
                    elseif ch == ')'
                        depth -= 1
                        if depth == 0
                            func_end_line = li
                            in_target_func = false
                            break
                        end
                    end
                end
            end
        end

        if func_start_line > 0 && func_end_line > 0
            # Get the function signature from the first line
            sig_line = lines[func_start_line]
            # Replace body: keep (func ...) declaration, replace contents with unreachable
            # Extract type, params, result from the sig line
            new_lines = vcat(
                lines[1:func_start_line],
                ["    unreachable)"],
                lines[func_end_line+1:end]
            )
            open(wat_file, "w") do io
                for l in new_lines
                    println(io, l)
                end
            end

            # Reassemble WAT → WASM
            try
                Base.run(pipeline(`wasm-tools parse $wat_file -o $outf`))
            catch e
                println("  ERROR reassembling after stubbing func $func_idx: $e")
                break
            end
        else
            println("  ERROR: Could not find func $func_idx in WAT")
            break
        end
    end

    println("\n=== RESULTS ===")
    println("Total functions: $func_count")
    println("Failing functions: $(length(failing_funcs))")
    println("Passing functions: $(func_count - length(failing_funcs))")
    pct = round(100 * (func_count - length(failing_funcs)) / func_count, digits=1)
    println("Pass rate: $pct%")
    println("\nFailing func indices: $(failing_funcs)")
end

main()
