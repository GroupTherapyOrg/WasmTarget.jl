#!/usr/bin/env julia
# compile_eval_julia_stubbed.jl — PURE-6024
#
# Compile eval_julia_to_bytes(String) to WASM, stubbing optimization pass
# functions that are never called at runtime (may_optimize=false).
#
# discover_dependencies uses static analysis and follows ALL branches,
# including dead branches from may_optimize=true. This pulls in ~10
# Core.Compiler optimization pass functions that fail validation.
# With may_optimize=false on WasmInterpreter, these functions are never
# called at runtime, so we stub them with `unreachable`.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6024: Compile eval_julia_to_bytes with optimization pass stubs ===")
println("Started: $(Dates.now())")
println()

# Step 0: Verify native pipeline
println("Step 0: Verify native eval_julia works...")
for (expr, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
    result = eval_julia_native(expr)
    status = result == expected ? "CORRECT" : "WRONG (got $result)"
    println("  eval_julia_native(\"$expr\") = $result — $status")
end
println()

# Step 1: Discover dependencies
println("Step 1: Discovering dependencies...")
seed = [(eval_julia_to_bytes, (String,))]
all_funcs = WasmTarget.discover_dependencies(seed)
println("  Found $(length(all_funcs)) functions")
println()

# Step 2: Identify optimization pass functions to stub
# These are Core.Compiler optimization functions pulled in by static analysis
# but never called at runtime with may_optimize=false
OPT_PASS_NAMES = Set([
    "construct_ssa!",
    "compact!",
    "assemble_inline_todo!",
    "batch_inline!",
    "sroa_pass!",
    "adce_pass!",
    "run_passes_ipo_safe",
    "convert_to_ircode",
    "construct_domtree",
    "scan_slot_def_use",
    "replace_code_newstyle!",
    "widen_all_consts!",
])

# Build stub_names: match by function name AND Core.Compiler module
stub_names = Set{String}()
for (f, arg_types, name) in all_funcs
    mod = try parentmodule(f) catch; nothing end
    mod_name = try string(nameof(mod)) catch; "" end
    # Stub Core.Compiler optimization pass functions
    if mod_name == "Compiler" && name in OPT_PASS_NAMES
        push!(stub_names, name)
        println("  STUB: $name (Core.Compiler optimization pass)")
    end
end
println("  Stubbing $(length(stub_names)) functions")
println()

# Step 3: Compile with stubs
println("Step 3: Compiling with stub_names...")
t_start = time()
wasm_bytes = nothing
try
    wasm_bytes = WasmTarget.compile_multi(seed; stub_names=stub_names)
    t_elapsed = time() - t_start
    println("  COMPILE SUCCESS: $(length(wasm_bytes)) bytes ($(round(t_elapsed, digits=1))s)")
catch e
    t_elapsed = time() - t_start
    println("  COMPILE FAILED after $(round(t_elapsed, digits=1))s:")
    println("  $(sprint(showerror, e))")
    bt = catch_backtrace()
    io = IOBuffer()
    Base.show_backtrace(io, bt)
    bt_lines = split(String(take!(io)), '\n')
    for l in bt_lines[1:min(20, end)]
        println("  $l")
    end
    exit(1)
end
println()

# Step 4: Validate
outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
mkpath(dirname(outf))
write(outf, wasm_bytes)
println("Step 4: Validating output/eval_julia.wasm ($(length(wasm_bytes)) bytes)...")

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
else
    err_msg = String(take!(errbuf))
    println("  VALIDATE_ERROR:")
    println("  $err_msg")

    # Try to identify which function failed
    m = match(r"func (\d+) failed", err_msg)
    if m !== nothing
        func_idx = parse(Int, m.captures[1])
        println()
        println("  Failed func index: $func_idx")
        # List exports around that index
        for line in split(wasm_text, '\n')
            if contains(line, "(export") && contains(line, "(func $(func_idx))")
                println("  Export: $line")
            end
        end
    end
end

println()
println("Done: $(Dates.now())")
