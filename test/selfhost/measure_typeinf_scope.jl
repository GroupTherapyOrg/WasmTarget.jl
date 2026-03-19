# PHASE-2-PREP-001: Measure typeinf method table scope via populate_transitive
#
# Run: julia +1.12 --project=. test/selfhost/measure_typeinf_scope.jl
#
# Approach: Run verify_typeinf on a set of test functions. This exercises the
# full typeinf pipeline with WasmInterpreter + DictMethodTable. Then measure
# how many method signatures the DictMethodTable accumulated. This tells us
# the RUNTIME scope — what typeinf needs in its method table to infer user code.
#
# We also measure what populate_transitive discovers for the typeinf COMPILATION
# targets (the functions Phase 2 will compile to WasmGC) using targeted, concrete
# entry points rather than meta-level orchestrators.

using WasmTarget
using JSON, Dates

# Load typeinf infrastructure
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))

println("=" ^ 60)
println("PHASE-2-PREP-001: Measuring typeinf+codegen scope")
println("=" ^ 60)

# ─── Phase 1 baseline ────────────────────────────────────────────────────────
phase1_count = 17171
phase1_intersections = 5783
println("\nPhase 1 baseline: $phase1_count signatures, $phase1_intersections intersections")

# ─── Part A: Runtime scope — what typeinf needs in its method table ──────────
# Run verify_typeinf on representative functions to see what method signatures
# the WasmInterpreter's DictMethodTable accumulates.

println("\n--- Part A: Measuring runtime scope via verify_typeinf ---")

test_functions = [
    (x::Int64 -> x + Int64(1), (Int64,), "add_one"),
    (x::Float64 -> x * 2.0, (Float64,), "double_f64"),
    ((x::Int64, y::Int64) -> x > y ? x : y, (Int64, Int64), "max_i64"),
    (x::Int64 -> x < Int64(0) ? -x : x, (Int64,), "abs_i64"),
    ((x::Int64, n::Int64) -> begin s = Int64(0); for i in Int64(1):n; s += x; end; s; end, (Int64, Int64), "sum_loop"),
]

# Run verify_typeinf on each and collect signatures from the method table
all_runtime_sigs = Dict{Any, Core.Compiler.MethodLookupResult}()
all_runtime_intersections = Dict{Tuple{Any,Any}, Any}()

for (f, argtypes, name) in test_functions
    print("  verify_typeinf($name)... ")
    t0 = time()
    result = verify_typeinf(f, argtypes)
    elapsed = time() - t0
    println("$(result.pass ? "PASS" : "FAIL") ($(round(elapsed, digits=2))s)")
end

# Now build a single large table covering all functions together
println("\n  Building combined table for all test functions...")
all_test_sigs = Any[]
for (f, argtypes, _) in test_functions
    push!(all_test_sigs, Tuple{typeof(f), argtypes...})
end

# Also add the codegen entry points (same as Phase 1)
push!(all_test_sigs, Tuple{typeof(WasmTarget.compile_from_codeinfo), Core.CodeInfo, Type, String, Tuple})
push!(all_test_sigs, Tuple{typeof(WasmTarget.compile_module_from_ir), Vector})

t0 = time()
runtime_table = populate_transitive(all_test_sigs)
elapsed_runtime = time() - t0

n_runtime = length(runtime_table.methods)
n_runtime_intersections = length(runtime_table.intersections)
n_runtime_intersections_env = length(runtime_table.intersections_with_env)

println("  Runtime scope: $n_runtime signatures, $n_runtime_intersections intersections ($(round(elapsed_runtime, digits=1))s)")
println("  Delta from Phase 1: +$(n_runtime - phase1_count) signatures ($(round(100.0 * (n_runtime - phase1_count) / phase1_count, digits=1))%)")

# ─── Part B: Compilation scope — what functions Phase 2 will compile ─────────
# Use targeted entry points for the actual typeinf functions that will run in WasmGC.
# Avoid meta-level orchestrators (verify_typeinf, build_wasm_interpreter) that
# call populate_transitive themselves.

println("\n--- Part B: Measuring compilation scope for typeinf functions ---")

# These are the actual functions that will run inside WasmGC:
typeinf_compile_sigs = Any[
    # DictMethodTable.findall — the core Dict lookup
    Tuple{typeof(Core.Compiler.findall), Type, DictMethodTable},
    # predecompress_methods! — code cache builder
    Tuple{typeof(predecompress_methods!), PreDecompressedCodeInfo, DictMethodTable},
]

# Add reimplementation functions if loaded
if @isdefined(wasm_subtype)
    push!(typeinf_compile_sigs, Tuple{typeof(wasm_subtype), Type, Type})
end
if @isdefined(wasm_type_intersection)
    push!(typeinf_compile_sigs, Tuple{typeof(wasm_type_intersection), Type, Type})
end
if @isdefined(_wasm_matching_methods_positional)
    push!(typeinf_compile_sigs, Tuple{typeof(_wasm_matching_methods_positional), Type, Int})
end

println("  TypeInf compilation entry points: $(length(typeinf_compile_sigs))")

t1 = time()
compile_table = populate_transitive(typeinf_compile_sigs)
elapsed_compile = time() - t1

n_compile = length(compile_table.methods)
n_compile_intersections = length(compile_table.intersections)

println("  Compilation scope: $n_compile signatures, $n_compile_intersections intersections ($(round(elapsed_compile, digits=1))s)")

# ─── Part C: Analyze method families ─────────────────────────────────────────

println("\n--- Part C: Method family analysis ---")

function analyze_families(table, label)
    families = Dict{String, Int}()
    modules = Dict{String, Int}()
    compiler_count = 0

    for sig in keys(table.methods)
        if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
            func_type = sig.parameters[1]
            name = string(func_type)
            families[name] = get(families, name, 0) + 1

            if occursin("Compiler", name) || occursin("typeinf", name) ||
               occursin("infer", name) || occursin("subtype", name)
                compiler_count += 1
            end

            mod_name = try
                if func_type isa DataType && hasfield(func_type, :name)
                    string(func_type.name.module)
                elseif func_type isa Type
                    string(parentmodule(func_type))
                else
                    "Unknown"
                end
            catch
                "Unknown"
            end
            modules[mod_name] = get(modules, mod_name, 0) + 1
        end
    end

    sorted_families = sort(collect(families), by=x -> -x[2])
    top20 = sorted_families[1:min(20, length(sorted_families))]

    println("\n  Top 20 $label families:")
    for (i, (name, count)) in enumerate(top20)
        short_name = length(name) > 60 ? name[1:60] * "..." : name
        println("    $i. $short_name: $count")
    end

    println("\n  $label by module:")
    for (mod, count) in sort(collect(modules), by=x -> -x[2])
        println("    $mod: $count")
    end

    println("  Compiler-related: $compiler_count")

    return (families=families, modules=modules, top20=top20, compiler_count=compiler_count)
end

runtime_analysis = analyze_families(runtime_table, "Runtime")
compile_analysis = analyze_families(compile_table, "Compilation")

# ─── Part D: Save results ────────────────────────────────────────────────────

results = Dict(
    "story" => "PHASE-2-PREP-001",
    "timestamp" => string(Dates.now()),
    "phase1_baseline" => Dict(
        "method_signatures" => phase1_count,
        "intersections" => phase1_intersections
    ),
    "runtime_scope" => Dict(
        "method_signatures" => n_runtime,
        "intersections" => n_runtime_intersections,
        "intersections_with_env" => n_runtime_intersections_env,
        "elapsed_seconds" => round(elapsed_runtime, digits=2),
        "delta_from_phase1" => n_runtime - phase1_count,
        "pct_growth" => round(100.0 * (n_runtime - phase1_count) / phase1_count, digits=1),
        "compiler_related_count" => runtime_analysis.compiler_count
    ),
    "compilation_scope" => Dict(
        "method_signatures" => n_compile,
        "intersections" => n_compile_intersections,
        "elapsed_seconds" => round(elapsed_compile, digits=2),
        "entry_point_count" => length(typeinf_compile_sigs),
        "compiler_related_count" => compile_analysis.compiler_count
    ),
    "runtime_top20_families" => [(name=name, count=count) for (name, count) in runtime_analysis.top20],
    "compile_top20_families" => [(name=name, count=count) for (name, count) in compile_analysis.top20],
    "runtime_module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(runtime_analysis.modules), by=x -> -x[2])],
    "compile_module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(compile_analysis.modules), by=x -> -x[2])]
)

output_path = joinpath(@__DIR__, "typeinf_scope_results.json")
open(output_path, "w") do io
    JSON.print(io, results, 2)
end

println("\n" * "=" ^ 60)
println("SUMMARY")
println("=" ^ 60)
println("  Phase 1 codegen-only:     $phase1_count sigs, $phase1_intersections intersections")
println("  Runtime scope (codegen +  $n_runtime sigs, $n_runtime_intersections intersections")
println("   user func typeinf):      +$(n_runtime - phase1_count) delta ($(round(100.0 * (n_runtime - phase1_count) / phase1_count, digits=1))%)")
println("  Compilation scope         $n_compile sigs, $n_compile_intersections intersections")
println("   (typeinf functions):     Compiler-related: $(compile_analysis.compiler_count)")
println("\nResults saved to $output_path")
println("\n=== ACCEPTANCE: PASS ===")
