#!/usr/bin/env julia
# trace_critical_path.jl — PURE-6021c
#
# Traces which functions in the eval_julia_to_bytes(String) dependency tree
# actually EXECUTE when we call eval_julia_to_bytes("1+1") natively.
#
# Strategy: Run with Profile.@profile, extract flat method list,
# cross-reference with eval_julia_manifest.txt.
#
# Output: scripts/eval_julia_critical_path.txt
# (list of INDEX | MODULE | FUNCTION | ARG_TYPES from the manifest)
#
# testCommand: julia +1.12 --project=. scripts/trace_critical_path.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates
using Profile

# Load typeinf (required for eval_julia_to_bytes)
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
# Load eval_julia_to_bytes
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6021c: Trace critical path for eval_julia_to_bytes(\"1+1\") ===")
println("Started: $(Dates.now())")
println()

# ── Step 1: Load the manifest ──────────────────────────────────────────────────
manifest_file = joinpath(@__DIR__, "eval_julia_manifest.txt")
manifest_entries = Tuple{Int, String, String, String}[]  # (idx, mod, func, arg_types)
for line in eachline(manifest_file)
    startswith(line, "#") && continue
    isempty(strip(line)) && continue
    parts = split(line, " | "; limit=6)
    length(parts) >= 4 || continue
    idx = parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    push!(manifest_entries, (idx, mod_name, func_name, arg_types_str))
end
println("Loaded $(length(manifest_entries)) entries from manifest")

# ── Step 2: Warmup (compile eval_julia_to_bytes machinery) ────────────────────
println("Warmup: eval_julia_to_bytes(\"1+1\")...")
t0 = time()
bytes = eval_julia_to_bytes("1+1")
t1 = time()
println("  Warmup done in $(round(t1-t0, digits=2))s — $(length(bytes)) bytes")

# Verify correctness
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
tmpjs = tempname() * ".mjs"
write(tmpjs, """
import { readFile } from 'fs/promises';
const bytes = await readFile('$(tmpf)');
const { instance } = await WebAssembly.instantiate(bytes);
const result = instance.exports['+'](1n, 1n);
process.stdout.write(String(result));
""")
native_result = try
    strip(read(`node $tmpjs`, String))
catch e
    "ERROR: $e"
end
rm(tmpf; force=true)
rm(tmpjs; force=true)
println("  Native result: 1+1 = $native_result (expected 2)")
println()

# ── Step 3: Profile the execution ─────────────────────────────────────────────
println("Profiling eval_julia_to_bytes(\"1+1\") (10 iterations)...")
Profile.clear()
Profile.init(n=10^7, delay=0.0001)  # High resolution

# First build the WasmInterpreter once to avoid profiling setup cost
@profile for _ in 1:3
    eval_julia_to_bytes("1+1")
end

# Collect profile data
io = IOBuffer()
Profile.print(io, format=:flat, sortedby=:count, mincount=1)
profile_text = String(take!(io))

println("Profile collected: $(length(split(profile_text, '\n'))) lines")
println()

# ── Step 4: Cross-reference profile with manifest ─────────────────────────────

# Build a set of (mod, func) pairs from the profile
# Profile format: "  count [file:line]; module.function"
profiled_methods = Set{Tuple{String, String}}()

for line in split(profile_text, '\n')
    # Profile flat format: "  123 [file.jl:456]; function_name"
    # or "  123 Base.function_name"
    m = match(r";\s+(.+)$", line)
    if m !== nothing
        # Try to parse "Module.function"
        full_name = strip(m.captures[1])
        # Split on last dot
        dot_idx = findlast('.', full_name)
        if dot_idx !== nothing
            mod_part = full_name[1:dot_idx-1]
            func_part = full_name[dot_idx+1:end]
            push!(profiled_methods, (mod_part, func_part))
            # Also try without module prefix
            push!(profiled_methods, ("", func_part))
        else
            push!(profiled_methods, ("", full_name))
        end
    end
end

println("Found $(length(profiled_methods)) unique methods in profile")

# ── Step 5: Also do explicit method tracing via MethodTracing ─────────────────
# Julia doesn't have built-in method tracing, but we can use the approach
# of wrapping discover_dependencies to find the dependency tree for
# the ACTUAL types encountered during execution.
#
# Alternative: Use MethodTracing via Profile data
# We already have profile data — let's cross-reference manifest with it.

println()
println("Cross-referencing manifest with profile...")

critical_path = Tuple{Int, String, String, String}[]
for (idx, mod_name, func_name, arg_types_str) in manifest_entries
    # Check if this function appears in the profile
    # Try various module name formats
    found = false
    for (pm, pf) in profiled_methods
        if pf == func_name || pf == func_name * "!" || endswith(pf, "." * func_name)
            # Rough match — refine by module
            found = true
            break
        end
    end
    # Also check by module.func
    if (mod_name, func_name) in profiled_methods
        found = true
    end
    if ("Base.Compiler", func_name) in profiled_methods && mod_name == "Base.Compiler"
        found = true
    end
    if found
        push!(critical_path, (idx, mod_name, func_name, arg_types_str))
    end
end

println("Cross-reference found $(length(critical_path)) functions in critical path")
println()

# ── Step 6: Alternative — use discover_dependencies approach ──────────────────
# The profile cross-reference may be imprecise. Let's also do a targeted
# dependency discover from the actual types:
println("Running targeted dependency discovery for +(Int64, Int64)...")
t2 = time()
seed_fn = Base.:+
seed_types = (Int64, Int64)
target_sig = Tuple{typeof(seed_fn), seed_types...}

# Discover dependencies needed to compile + with Int64 args
# This is a SUBSET of the full eval_julia_to_bytes deps
targeted_deps = try
    WasmTarget.discover_dependencies([(seed_fn, seed_types)])
catch e
    @warn "discover_dependencies failed: $e"
    []
end
t3 = time()
println("  Found $(length(targeted_deps)) targeted deps in $(round(t3-t2, digits=2))s")
println()

# ── Step 7: Identify the ACTUAL critical path functions ───────────────────────
# The true critical path for eval_julia_to_bytes("1+1"):
# 1. JuliaSyntax.parsestmt — parsing "1+1"
# 2. build_wasm_interpreter — setup
# 3. Core.Compiler.findall, specialize_method — method lookup
# 4. Core.Compiler.typeinf_frame — type inference for +(Int64,Int64)
# 5. compile_from_codeinfo — codegen for +(Int64,Int64)
#
# The manifest contains 542 functions. The critical path is those that
# ACTUALLY GET CALLED during execution for "1+1".
#
# Let's use discover_dependencies on the actual function being inferred:
# Base.:+(::Int64, ::Int64) only needs add_int builtin — very shallow tree.

println("Determining critical path by compile dependency for +(Int64, Int64)...")

# These functions are definitely in the critical path for +(Int64, Int64):
# - The actual compiled function: Base.:+ with (Int64,Int64) args
# - JuliaSyntax parsestmt functions
# - Core.Compiler typeinf functions

# The manifest was built from discover_dependencies(eval_julia_to_bytes, (String,))
# That's ALL possible deps. For "1+1", we need to filter to what's actually needed.

# The best heuristic: compile just Base.:+ and see what it needs:
plus_deps = targeted_deps  # from above
plus_dep_names = Set{String}()
for (f, arg_types, name) in plus_deps
    push!(plus_dep_names, name)
end
println("Deps for +(Int64,Int64): $(join(collect(plus_dep_names)[1:min(10,end)], ", "))...")

# ── Step 8: Write critical path output ────────────────────────────────────────
outfile = joinpath(@__DIR__, "eval_julia_critical_path.txt")
open(outfile, "w") do io
    println(io, "# PURE-6021c: Critical path for eval_julia_to_bytes(\"1+1\")")
    println(io, "# Generated: $(Dates.now())")
    println(io, "#")
    println(io, "# Format: INDEX | MODULE | FUNCTION | ARG_TYPES")
    println(io, "# (INDEX refers to position in eval_julia_manifest.txt)")
    println(io, "")
    println(io, "# === Profile-based critical path ($(length(critical_path)) functions) ===")
    for (idx, mod, func, args) in critical_path
        println(io, "$idx | $mod | $func | $args")
    end
    println(io, "")
    println(io, "# === +(Int64,Int64) targeted deps ($(length(plus_deps)) functions) ===")
    for (f, arg_types, name) in plus_deps
        mod_name = try string(parentmodule(f)) catch; "Unknown" end
        arg_str = "(" * join([string(t) for t in arg_types], ", ") * ")"
        println(io, "TARGETED | $mod_name | $name | $arg_str")
    end
end
println("Critical path written to: $outfile")
println()

# ── Step 9: Summary ───────────────────────────────────────────────────────────
println("=== SUMMARY ===")
println("eval_julia_to_bytes(\"1+1\") native result: $native_result (expected 2)")
println("Profile-based critical path: $(length(critical_path)) functions")
println("Targeted deps for +(Int64,Int64): $(length(plus_deps)) functions")
println()
println("NEXT: Run test_critical_path_correct.jl to compile each function")
println("      and test for CORRECT (not just VALIDATES)")
println()
println("Done: $(Dates.now())")
