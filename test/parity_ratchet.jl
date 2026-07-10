# ============================================================================
# parity_ratchet.jl — the M0 enforcement harness (dev/PARITY_MASTER.md §2-§3).
#
# Makes "clean up as you go" MECHANICAL: every structural-disease metric from the
# 2026-07-01 census is counted here with a precise pattern and compared against the
# committed baseline (dev/parity_baseline.toml).
#
#   RATCHET metrics may only go DOWN.  count > baseline  ⇒  FAIL.
#   LOCK    metrics must match EXACTLY. count != locked  ⇒  FAIL.
#
# When a commit legitimately lowers a count, tighten the baseline IN THE SAME COMMIT:
#     WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl
# (update mode still FAILS on any increase — a ratchet never loosens; flipping a
# metric from ratchet to lock is done by hand in the baseline = "phase done").
#
# Run standalone (seconds, exit 0/1):   julia --project=. test/parity_ratchet.jl
# Also included by runtests.jl on shard 0 as a @testset.
# ============================================================================
module ParityRatchet

# NO deps (not even stdlib TOML — the test env doesn't declare it; a `using TOML` here
# LoadError'd shard 0 inside Pkg.test). The baseline is a flat TOML-shaped file of
# `[section]` + `key = int` lines; the two 10-line helpers below read/write exactly that.

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SRC = joinpath(ROOT, "src")
const CODEGEN = joinpath(SRC, "codegen")
const BASELINE_PATH = joinpath(ROOT, "dev", "parity_baseline.toml")

_iscomment(line::AbstractString) = startswith(lstrip(line), "#")

# Minimal reader for the baseline's `[section]` / `key = int` shape (TOML-compatible subset).
function _read_baseline(path::String)::Dict{String,Dict{String,Int}}
    out = Dict{String,Dict{String,Int}}()
    isfile(path) || return out
    section = ""
    for line in eachline(path)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        if (m = match(r"^\[(\w+)\]$", s)) !== nothing
            section = m.captures[1]
            out[section] = get(out, section, Dict{String,Int}())
        # Accept TOML inline comments.  Without this, an annotated baseline entry is
        # silently omitted and reported as NEW(baseline), which disables its ratchet.
        elseif (m = match(r"^(\w+)\s*=\s*(\d+)(?:\s+#.*)?$", s)) !== nothing && !isempty(section)
            out[section][m.captures[1]] = parse(Int, m.captures[2])
        end
    end
    return out
end

function _write_baseline(path::String, metrics::Dict{String,Int}, locks::Dict{String,Int})
    open(path, "w") do io
        println(io, "# dev/parity_baseline.toml — enforced by test/parity_ratchet.jl.")
        println(io, "# RATCHET: counts may only DECREASE. LOCKS: must match exactly.")
        println(io, "# Tighten via: WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl")
        for (name, d) in (("locks", locks), ("metrics", metrics))
            println(io, "\n[", name, "]")
            for k in sort!(collect(keys(d)))
                println(io, k, " = ", d[k])
            end
        end
    end
end

"""
Count non-comment lines in `.jl` files under `roots` matching `rx`, skipping files whose
path ends with an entry of `exclude_files` and lines matching `exclude_line` (e.g. defs).
Multiple matches on one line count once (call-SITE counting, stable + cheap).
"""
function count_sites(rx::Regex; roots=[SRC], exclude_files=String[],
                     exclude_line::Union{Regex,Nothing}=nothing)
    n = 0
    for root in roots
        for (dir, _, files) in walkdir(root), f in files
            endswith(f, ".jl") || continue
            path = joinpath(dir, f)
            # Windows: normalize separators so "codegen/values.jl" excludes match D:\...\codegen\values.jl
            _npath = replace(path, '\\' => '/')
            any(x -> endswith(_npath, x), exclude_files) && continue
            for line in eachline(path)
                _iscomment(line) && continue
                occursin(rx, line) || continue
                exclude_line !== nothing && occursin(exclude_line, line) && continue
                n += 1
            end
        end
    end
    return n
end

# ---- METRIC DEFINITIONS (ids match dev/PARITY_MASTER.md §2) -----------------
# Each entry: id => (description, thunk). Patterns deliberately exclude the
# definition line (`function name`) so they count CALLERS.
const METRICS = [
    "R2_emit_raw_bridges" => ("emit_raw!( byte-bridges into the typed builder (M2 → 0; ZERO since march4 — see L13)",
        () -> count_sites(r"emit_raw!\("; exclude_line=r"function emit_raw!|`emit_raw!")),
    "R3_infer_value_type" => ("infer_value_type( callers — RECLASSIFIED (march4): dart's node.getStaticType equivalent, legitimate PRE-EMIT type knowledge (never post-emission re-guessing, which is dead — L4); monotone consolidation only",
        () -> count_sites(r"infer_value_type\("; exclude_line=r"function infer_value_type\(")),
    "R5_julia_type_reguess" => ("get_concrete_wasm_type( + julia_to_wasm_type_concrete( callers (M2 → pre-emit floor)",
        () -> count_sites(r"get_concrete_wasm_type\(|julia_to_wasm_type_concrete\(";
                          exclude_line=r"function (get_concrete_wasm_type|julia_to_wasm_type_concrete)\(")),
    "R7_raw_coercion_ops" => ("numeric-coercion opcodes outside values.jl's convert_type! funnel (M2 → intrinsic floor)",
        () -> count_sites(r"I32_WRAP_I64|I64_EXTEND_I32_S|I64_EXTEND_I32_U|I64_TRUNC_F|I32_TRUNC_F|F64_CONVERT_I|F32_CONVERT_I|F32_DEMOTE_F64|F64_PROMOTE_F32";
                          roots=[CODEGEN], exclude_files=["values.jl"])),
    # ── marches 6-9 progress ratchets (mapped 2026-07-05, discovery-grounded;
    # see dev/PARITY_MASTER.md § MARCHES 6-10 for each metric's anchor census) ──
    "R12_try_drivers" => ("shape-specialized try/catch drivers (march 6 → 1: dart's ONE visitTryCatch)",
        () -> count_sites(r"^function (generate_(try_catch|branch_split_try|catch_arm|catch_try_chain|sequential_try_catch|nested_try_catch)|_compile_(catch_region|try_body))";
                          exclude_line=nothing)),
    "R13_catch_all_clauses" => ("catch_all_clause emissions (march 6 → 0: the typed (exn,stackTrace) tag catches; catch_all reserved for host exns)",
        () -> count_sites(r"catch_all_clause"; exclude_line=r"function |catch_all_clause`|catch_all_clause\(label::Integer\)")),
    "R14_fresh_constant_structs" => ("struct_new!(b in values.jl — fresh heap-constant materializations (march 7: internable kinds route through THE funnel; the remaining sites are the MUTABLE kinds [Vector/Dict/Memory — per-object identity, documented floor] + funnel fallbacks)",
        () -> count_sites(r"struct_new!\(b"; roots=[joinpath(SRC, "codegen")], exclude_files=setdiff(readdir(joinpath(SRC, "codegen")), ["values.jl"]))),
    "R15_constant_data_segments" => ("add_passive_data_segment! in values.jl (march 7: segments are CONTENT-ADDRESSED at the builder — these sites now dedup by construction; count = the long-string + symbol fallback paths)",
        () -> count_sites(r"add_passive_data_segment!"; exclude_files=["builder/instructions.jl", "codegen/strings.jl", "codegen/compile.jl", "codegen/interpreter.jl", "codegen/types.jl"])),   # types.jl = the lazy creator's ONE legit segment site
    "R16_external_convert_ladders" => ("convert_type! callers outside values.jl (march 8 → 0: fold into the 4-arg wrap)",
        () -> count_sites(r"convert_type!\("; exclude_files=["codegen/values.jl"], exclude_line=r"function convert_type!")),
    "R17_unwrapped_value_emissions" => ("3-arg emit_value! sites — no expectedType (march 8 → ~40 floor: dart wraps 100%)",
        () -> count_sites(r"emit_value!\([^()]*, ctx\)"; exclude_line=r"function emit_value!")),
    "R18_anyref_dispatch_sigs" => ("fill(AnyRef dispatch signatures (march 9 → 0: dart per-param LUB, dispatch_table.dart:86-205)",
        () -> count_sites(r"fill\(AnyRef"; exclude_line=nothing)),
    "R11_patch_markers" => ("patch-tag comment sediment PURE-/WBUILD-/CG-/TRUE-PARSE-/E2E- (monotone down via root-fixes)",
        () -> begin  # markers live IN comments, so count comment lines too
            n = 0
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                for line in eachline(joinpath(dir, f))
                    occursin(r"(PURE|WBUILD|CG|TRUE-PARSE|E2E)-\d", line) && (n += 1)
                end
            end
            n
        end),
]

# ---- LOCKS (completed dimensions; exact match required) ---------------------
const LOCKS = [
    "L22_artifact_binaryen" => ("optimization uses Binaryen_jll's artifact executable and cannot silently depend on or skip for a system wasm-opt",
        () -> begin
            api_src = read(joinpath(SRC, "WasmTarget.jl"), String)
            tests_src = read(joinpath(ROOT, "test", "runtests.jl"), String)
            project_src = read(joinpath(ROOT, "Project.toml"), String)
            missing = count(p -> !occursin(p, api_src * project_src),
                            ["using Binaryen_jll: wasmopt", "Binaryen_jll =", "\$(wasmopt())"])
            forbidden = count(p -> occursin(p, api_src * tests_src),
                              ["Sys.which(\"wasm-opt\")", "wasm-opt not found", "skipping optimization tests"])
            missing + forbidden
        end),
    "L21_packed_integer_arrays" => ("Int8/UInt8 and Int16/UInt16 arrays use packed Wasm GC storage and generic loads derive signedness from the Julia element type",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            load_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                       read(joinpath(CODEGEN, "invoke.jl"), String)
            required = ["T === Int8 || T === UInt8 ? UInt8(0x78)",
                        "T === Int16 || T === UInt16 ? UInt8(0x77)",
                        "packed_array_signedness(elem_type)"]
            count(p -> !occursin(p, types_src * load_src), required) +
            count(_ -> true, eachmatch(r"signed=\(elem_type === UInt8", load_src))
        end),
    "L20_object_identity_layout" => ("Top owns classId; Object adds mutable identityHash; objectid reads/writes that slot and never fabricates a constant/content hash",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            required = [
                "object_struct_idx::Union{Nothing, UInt32}",
                "StructType(fields, top)",
                "FieldType(I32, true)",
                "get_identity_counter_global!",
                "struct_get!(b, object_idx, UInt32(1), I32)",
                "struct_set!(b, object_idx, UInt32(1), I32)",
                "StructType(fields, object)",
                "struct_get!(tb, base_idx, UInt32(2), AnyRef)",
                "struct_get!(b, base_idx, UInt32(3), StructRef)",
                "ensure_type_id!(registry, body_return_type)",
            ]
            all_src = types_src * stmt_src * closure_src
            missing = count(p -> !occursin(p, all_src), required)
            forbidden = count(p -> occursin(p, all_src),
                              ["constant 42", "array.len for strings", "fake identity", "fabricated identity"])
            missing + forbidden
        end),
    "L19_no_fabricated_invoke_results" => ("invoke/call lowering may not substitute dummy exceptions, empty strings, constant hashes, or null SimpleVectors",
        () -> count_sites(r"dummy anyref|emit empty string|fallback to constant hash|exception placeholder|benign null placeholder|Core\.svec \(SimpleVector construction\)")),
    "L18_no_value_repair_defaults" => ("PiNode, GlobalRef, SSA-store, and struct-field lowering preserve and coerce the emitted value; no zero/null repair helper may return",
        () -> count_sites(r"needs_type_safe_default|_emit_default!|_append_default!|_gv_replaced|ssa_type_mismatch")),
    "L17_one_compilation_path" => ("public compilation always enters the closed-world planner; legacy discovery, recursive mode switching, byte shells, and legacy body compilers are extinct",
        () -> count_sites(r"_TRIM_ACTIVE|discovery=:legacy|discover_dependencies|AUTODISCOVER|FrozenCompilationState|InplaceCompilationContext|compile_from_ir_(?:inplace|prebaked)|compile_module_from_ir_frozen|compile_handler|compile_closure_body|compile_function_into!|_autodiscover_closure_deps!|run_selfhost|run_direct|to_bytes_mvp|FakeGlobalRef|wasm_compile_(?:flat|source)|function _compile_function_legacy|function compile_(?:value|statement|call|invoke|new|foreigncall|condition_to_i32)\([^!]")),
    "L16_no_codegen_lax_mode" => ("codegen correctness is unconditional: no strict keyword/field, paranoid environment toggle, or entry-vs-dependency downgrade state",
        () -> count_sites(r"strict::Bool|ctx\.strict|WT_PARANOID_STUBS|TRIM_ENTRY_NAMES";
                          exclude_files=["codegen/interpreter.jl"])),
    "L15_no_fabricated_ssa_store" => ("an emitted SSA value is coerced from its builder-tracked actual type; the drop-and-default store repair path is extinct",
        () -> count_sites(r"SSA-store type mismatch|value dropped, type-safe default|_cs4_func_ref")),
    "L14_no_posthoc_module_repair" => ("no codegen-crash or external-validator failure may be converted into an unreachable function body after the fact",
        () -> count_sites(r"_stub_invalid_isolated_funcs|dispatch-isolation|stubbing isolated|stub_names")),
    "L1_box_typeid_external" => ("emit_box_type_id! callers outside its home files (ONE box producer; locked 2026-06-30)",
        () -> count_sites(r"emit_box_type_id!\(";
                          exclude_files=["codegen/values.jl", "codegen/types.jl"],
                          exclude_line=r"function emit_box_type_id!")),
    "L2_ref_i31_callers" => ("ref_i31! callers (i31 box family deleted; locked 2026-06-30)",
        () -> count_sites(r"ref_i31!\(";
                          exclude_line=r"^ref_i31!\(b::InstrBuilder\)|function ref_i31!")),
    "L9_no_unjustified_untyped_emission" => ("every untyped compile_value splice carries the god-fn-seam annotation; unjustified untyped emission is DEAD (M4; locked 2026-07-02)",
        () -> count_sites(r"compile_value\("; exclude_line=r"function compile_value\(|god-fn seam")),
    "L8_no_silent_traps" => ("every unreachable! is record_unsupported!-routed OR an annotated structural trap — NO silent stubs (M5; locked 2026-07-01)",
        () -> begin
            n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                endswith(f, ".jl") || continue
                prev = ""
                for line in eachline(joinpath(dir, f))
                    if occursin(r"unreachable!\(", line) && !occursin("function unreachable!", line) &&
                       !startswith(lstrip(line), "#") &&
                       !occursin("structural trap", line) && !occursin("record_unsupported!", prev)
                        n += 1
                    end
                    prev = line
                end
            end
            n
        end),
    "L7_wasmtools_demoted" => ("no always-on external-validate default may return — validity is the strict builder's job; wasm-tools is opt-in (validate=true / WT_VALIDATE=1) (M4; locked 2026-07-01)",
        () -> count_sites(r"validate::Bool\s*=\s*true")),
    "L6_all_builders_strict" => ("instruction validation is unconditional: no strict field, environment switch, setter, constructor keyword, or production opt-out may exist.",
        () -> count_sites(r"InstrBuilder\([^)]*strict\s*=" ) +
              count_sites(r"_wt_builder_strict|set_strict!|strict::Bool";
                          roots=[joinpath(SRC, "builder")])),
    "L5_no_tagged_union" => ("the tagged-union wrapper family is DELETED — needs_tagged_union/emit_(un)wrap_union_value must never reappear (M3; locked 2026-07-01)",
        () -> count_sites(r"needs_tagged_union\(|emit_wrap_union_value\(|emit_unwrap_union_value\(")),
    "L4_no_postemit_reguess" => ("infer_value_wasm_type is GONE — renamed to static_wasm_type (pre-emit-ONLY contract); the post-emission re-guess anti-pattern is dead (M2; locked 2026-07-01)",
        () -> count_sites(r"infer_value_wasm_type\(")),
    "L13_no_byte_bridges" => ("THE byte-bridge class is EXTINCT — zero emit_raw! call sites exist; every emission is a typed method or a tracked merge (march4 COMPLETE; locked 2026-07-04)",
        () -> count_sites(r"emit_raw!\("; exclude_line=r"function emit_raw!|`emit_raw!")),
    "L12_god_fn_seams_only" => ("every emit_raw! splice is an ANNOTATED god-fn seam or front — the byte-bridge class is closed to new members; R2 falls only by killing seams (march3; locked 2026-07-04)",
        () -> count_sites(r"emit_raw!\(";
                          exclude_line=r"function emit_raw!|god-fn seam|THE front seam|`emit_raw!")),
    "L11_driver_fronts" => ("driver-level byte splices flow ONLY through the declared fronts (compile_statement!/generate_stackified_flow!/_compile_catch_region! builder methods) — no raw driver splices at call sites (M11.3; locked 2026-07-03)",
        () -> count_sites(r"emit_raw!\(\w+, (?:generate_stackified_flow|compile_statement|generate_branch_split_try)\(";
                          exclude_line=r"THE front seam|pops=1|declared push|god-fn seam")),
    "L10_no_fnv_dispatch" => ("the FNV-1a hash-dispatch apparatus is DELETED — dispatch is dart's ONE selector table, classId + offset + call_indirect (M8.4; locked 2026-07-03)",
        () -> count_sites(r"fnv1a_hash\(|FNV_OFFSET_BASIS\b|FNV_PRIME\b|_emit_table_probe_body|OverlayRegistry\b";
                          exclude_files=["codegen/types.jl"])),
    "L3_legacy_flow_family" => ("ALL legacy lowering strategies — nested_conditionals/if_then_else/nested_if_else/void_flow/linear_flow/loop_code/branched_loops/complex_flow router (M1 COMPLETE: ONE lowering = the stackifier; DELETED + locked 2026-07-01)",
        () -> count_sites(r"generate_nested_conditionals\(|generate_if_then_else\(|compile_nested_if_else\(|generate_void_flow\(|generate_linear_flow\(|generate_loop_code\(|generate_branched_loops\(|generate_complex_flow\(";
                          exclude_line=r"function (generate_nested_conditionals|generate_if_then_else|compile_nested_if_else|generate_void_flow|generate_linear_flow|generate_loop_code|generate_branched_loops|generate_complex_flow)\(")),
]

function run(; update::Bool=(get(ENV, "WT_RATCHET_UPDATE", "0") == "1"))
    baseline = _read_baseline(BASELINE_PATH)
    bm = get(baseline, "metrics", Dict{String,Int}())
    bl = get(baseline, "locks", Dict{String,Int}())

    ok = true
    current_m = Dict{String,Int}()
    current_l = Dict{String,Int}()

    println("── parity ratchet (dev/PARITY_MASTER.md §3) ──")
    for (id, (desc, thunk)) in METRICS
        c = thunk()
        current_m[id] = c
        b = get(bm, id, nothing)
        status = b === nothing ? "NEW(baseline)" :
                 c > b ? "❌ RATCHET BROKEN (+$(c - b))" :
                 c < b ? "▼ improved ($b→$c — tighten with WT_RATCHET_UPDATE=1)" : "= holding"
        b !== nothing && c > b && (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", status, "   # ", desc)
    end
    for (id, (desc, thunk)) in LOCKS
        c = thunk()
        current_l[id] = c
        want = get(bl, id, 0)
        good = (c == want)
        good || (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", good ? "🔒 locked" : "❌ LOCK BROKEN (want $want)", "   # ", desc)
    end

    if update
        if !ok
            println("refusing WT_RATCHET_UPDATE: a ratchet/lock is BROKEN (ratchets never loosen).")
        else
            _write_baseline(BASELINE_PATH, current_m, current_l)
            println("baseline tightened → ", BASELINE_PATH)
        end
    end
    return ok
end

end # module

# Standalone: exit 0/1. From runtests, include this file then assert
# `@test ParityRatchet.run()` inside a @testset (see runtests.jl shard-0 block).
if get(ENV, "WT_RATCHET_INCLUDED", "0") != "1"
    exit(ParityRatchet.run() ? 0 : 1)
end
