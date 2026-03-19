# PHASE-2-PREP-001: Measure typeinf method table scope via populate_transitive
#
# Run: julia +1.12 --project=. test/selfhost/measure_typeinf_scope.jl
#
# This extends PHASE-1-001 by adding typeinf entry points alongside codegen.
# Records: total signatures, delta from Phase 1 (codegen-only), top method families
# unique to typeinf, intersection cache growth.

using WasmTarget
using JSON, Dates

# Load typeinf infrastructure (not part of WasmTarget module — standalone)
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))

println("=" ^ 60)
println("PHASE-2-PREP-001: Measuring typeinf+codegen scope")
println("=" ^ 60)

# ─── Phase 1 baseline (codegen-only) ────────────────────────────────────────
# From PHASE-1-001: 17,171 signatures with just codegen entry points
phase1_count = 17171
phase1_intersections = 5783

println("\nPhase 1 baseline: $phase1_count signatures, $phase1_intersections intersections")

# ─── Step 1: Define codegen-only entry points (same as Phase 1) ─────────────
codegen_sigs = Any[
    Tuple{typeof(WasmTarget.compile_from_codeinfo), Core.CodeInfo, Type, String, Tuple},
    Tuple{typeof(WasmTarget.compile_module_from_ir), Vector},
]

# ─── Step 2: Define typeinf entry points ────────────────────────────────────
# These are the functions Phase 2 will compile to WasmGC.

# Core typeinf (the main inference loop)
# Note: We can't directly use WasmInterpreter/InferenceState as entry because
# code_typed can't specialize on abstract types. Instead use verify_typeinf
# which is the concrete entry point, and also individual typeinf functions.

typeinf_sigs = Any[]

# verify_typeinf is the concrete entry that exercises the full path
push!(typeinf_sigs, Tuple{typeof(verify_typeinf), Function, Tuple})

# build_wasm_interpreter — builds interpreter + populates method table
push!(typeinf_sigs, Tuple{typeof(build_wasm_interpreter), Vector})

# DictMethodTable findall — core lookup
push!(typeinf_sigs, Tuple{typeof(Core.Compiler.findall), Type, DictMethodTable})

# populate_transitive — the method table builder
push!(typeinf_sigs, Tuple{typeof(populate_transitive), Vector})

# populate_method_table — simpler version
push!(typeinf_sigs, Tuple{typeof(populate_method_table), Vector})

# predecompress_methods! — code cache builder
push!(typeinf_sigs, Tuple{typeof(predecompress_methods!), PreDecompressedCodeInfo, DictMethodTable})

# preexpand_generated! — @generated function pre-expansion
push!(typeinf_sigs, Tuple{typeof(preexpand_generated!), PreDecompressedCodeInfo, DictMethodTable})

# If subtype/matching reimplementations are loaded, include those too
if @isdefined(wasm_subtype)
    push!(typeinf_sigs, Tuple{typeof(wasm_subtype), Type, Type})
    println("  Added wasm_subtype entry point")
end
if @isdefined(wasm_type_intersection)
    push!(typeinf_sigs, Tuple{typeof(wasm_type_intersection), Type, Type})
    println("  Added wasm_type_intersection entry point")
end
if @isdefined(wasm_matching_methods)
    # Use the positional version to avoid kwargs recursion
    if @isdefined(_wasm_matching_methods_positional)
        push!(typeinf_sigs, Tuple{typeof(_wasm_matching_methods_positional), Type, Int})
        println("  Added _wasm_matching_methods_positional entry point")
    end
end

println("\n--- Entry points ---")
println("Codegen: $(length(codegen_sigs)) signatures")
println("TypeInf: $(length(typeinf_sigs)) signatures")
println("Total:   $(length(codegen_sigs) + length(typeinf_sigs)) signatures")

# ─── Step 3: Run populate_transitive with BOTH codegen + typeinf ────────────
all_sigs = vcat(codegen_sigs, typeinf_sigs)

println("\n--- Running populate_transitive (codegen + typeinf combined) ---")
t0 = time()
combined_table = populate_transitive(all_sigs)
elapsed_combined = time() - t0
println("Elapsed: $(round(elapsed_combined, digits=2))s")

n_combined = length(combined_table.methods)
n_intersections_combined = length(combined_table.intersections)
n_intersections_env_combined = length(combined_table.intersections_with_env)

println("\n--- Combined Results ---")
println("Method signatures: $n_combined (Phase 1 was $phase1_count)")
println("Delta: $(n_combined - phase1_count) new signatures from typeinf")
println("Intersections: $n_intersections_combined (Phase 1 was $phase1_intersections)")
println("Intersections (with env): $n_intersections_env_combined")

# ─── Step 4: Run populate_transitive with typeinf-ONLY ──────────────────────
println("\n--- Running populate_transitive (typeinf-only) ---")
t1 = time()
typeinf_table = populate_transitive(typeinf_sigs)
elapsed_typeinf = time() - t1
println("Elapsed: $(round(elapsed_typeinf, digits=2))s")

n_typeinf_only = length(typeinf_table.methods)
n_intersections_typeinf = length(typeinf_table.intersections)

println("TypeInf-only signatures: $n_typeinf_only")
println("TypeInf-only intersections: $n_intersections_typeinf")

# ─── Step 5: Identify signatures UNIQUE to typeinf ──────────────────────────
# (This approximation compares combined vs what Phase 1 would have had)
# We can't rerun Phase 1 here, so we'll analyze the combined set's module distribution

# Analyze method families for the combined set
combined_families = Dict{String, Int}()
for sig in keys(combined_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        combined_families[name] = get(combined_families, name, 0) + 1
    end
end

# Same for typeinf-only
typeinf_families = Dict{String, Int}()
for sig in keys(typeinf_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        typeinf_families[name] = get(typeinf_families, name, 0) + 1
    end
end

# Top 20 combined families
sorted_combined = sort(collect(combined_families), by=x -> -x[2])
top20_combined = sorted_combined[1:min(20, length(sorted_combined))]

println("\n--- Top 20 Combined Method Families ---")
for (i, (name, count)) in enumerate(top20_combined)
    short_name = length(name) > 60 ? name[1:60] * "..." : name
    println("  $i. $short_name: $count signatures")
end

# Top 20 typeinf-only families
sorted_typeinf = sort(collect(typeinf_families), by=x -> -x[2])
top20_typeinf = sorted_typeinf[1:min(20, length(sorted_typeinf))]

println("\n--- Top 20 TypeInf-Only Method Families ---")
for (i, (name, count)) in enumerate(top20_typeinf)
    short_name = length(name) > 60 ? name[1:60] * "..." : name
    println("  $i. $short_name: $count signatures")
end

# ─── Step 6: Module distribution for combined set ───────────────────────────
combined_modules = Dict{String, Int}()
for sig in keys(combined_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
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
        combined_modules[mod_name] = get(combined_modules, mod_name, 0) + 1
    end
end

println("\n--- Combined Methods by Module ---")
for (mod, count) in sort(collect(combined_modules), by=x -> -x[2])
    println("  $mod: $count")
end

# Typeinf-only module distribution
typeinf_modules = Dict{String, Int}()
for sig in keys(typeinf_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
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
        typeinf_modules[mod_name] = get(typeinf_modules, mod_name, 0) + 1
    end
end

println("\n--- TypeInf-Only Methods by Module ---")
for (mod, count) in sort(collect(typeinf_modules), by=x -> -x[2])
    println("  $mod: $count")
end

# ─── Step 7: Check for Core.Compiler signatures (most relevant to Phase 2) ──
compiler_sigs = []
for sig in keys(combined_table.methods)
    if sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1
        func_type = sig.parameters[1]
        name = string(func_type)
        if occursin("Compiler", name) || occursin("typeinf", name) ||
           occursin("infer", name) || occursin("subtype", name) ||
           occursin("matching", name)
            push!(compiler_sigs, (name, sig))
        end
    end
end

println("\n--- Compiler/TypeInf-Related Signatures ($(length(compiler_sigs))) ---")
for (name, _) in sort(compiler_sigs, by=x->x[1])[1:min(30, length(compiler_sigs))]
    short_name = length(name) > 80 ? name[1:80] * "..." : name
    println("  $short_name")
end
if length(compiler_sigs) > 30
    println("  ... and $(length(compiler_sigs) - 30) more")
end

# ─── Step 8: Save results as JSON ──────────────────────────────────────────
results = Dict(
    "story" => "PHASE-2-PREP-001",
    "timestamp" => string(Dates.now()),
    "phase1_baseline" => Dict(
        "method_signatures" => phase1_count,
        "intersections" => phase1_intersections
    ),
    "combined" => Dict(
        "method_signatures" => n_combined,
        "intersections" => n_intersections_combined,
        "intersections_with_env" => n_intersections_env_combined,
        "elapsed_seconds" => round(elapsed_combined, digits=2)
    ),
    "typeinf_only" => Dict(
        "method_signatures" => n_typeinf_only,
        "intersections" => n_intersections_typeinf,
        "elapsed_seconds" => round(elapsed_typeinf, digits=2)
    ),
    "delta" => Dict(
        "new_signatures" => n_combined - phase1_count,
        "pct_growth" => round(100.0 * (n_combined - phase1_count) / phase1_count, digits=1),
        "new_intersections" => n_intersections_combined - phase1_intersections
    ),
    "codegen_entry_count" => length(codegen_sigs),
    "typeinf_entry_count" => length(typeinf_sigs),
    "top20_combined_families" => [(name=name, count=count) for (name, count) in top20_combined],
    "top20_typeinf_families" => [(name=name, count=count) for (name, count) in top20_typeinf],
    "combined_module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(combined_modules), by=x -> -x[2])],
    "typeinf_module_distribution" => [(module_name=mod, count=count) for (mod, count) in sort(collect(typeinf_modules), by=x -> -x[2])],
    "compiler_related_signature_count" => length(compiler_sigs)
)

output_path = joinpath(@__DIR__, "typeinf_scope_results.json")
open(output_path, "w") do io
    JSON.print(io, results, 2)
end

println("\n--- Results saved to $output_path ---")
println("\n=== SUMMARY ===")
println("  Phase 1 codegen-only:    $phase1_count signatures, $phase1_intersections intersections")
println("  Combined codegen+typeinf: $n_combined signatures, $n_intersections_combined intersections")
println("  Delta: +$(n_combined - phase1_count) signatures ($(round(100.0 * (n_combined - phase1_count) / phase1_count, digits=1))% growth)")
println("  TypeInf-only:            $n_typeinf_only signatures, $n_intersections_typeinf intersections")
println("  Compiler-related sigs:   $(length(compiler_sigs))")
println("\n=== ACCEPTANCE: PASS (measurement complete) ===")
