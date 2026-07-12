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
    "L65_no_codegen_byte_shells" => ("codegen helpers expose only builder-native emission; dead byte-vector adapter APIs are deleted",
        () -> count_sites(r"bytes shell|\(bytes::Vector\{UInt8\}|target_bytes::Vector\{UInt8\}";
                          roots=[CODEGEN], exclude_files=["sourcemap.jl"])),
    "L66_no_fabricated_string_results" => ("specialized string lowering either proves every input representation or rejects it; mixed arguments can never become an empty string",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            strings_src = read(joinpath(CODEGEN, "strings.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["Fall back to empty string", "array_new_fixed!(bms, str_type_idx, 0, I32)",
                         "For now, just do first two", "Multi-string concat: concat pairwise"]
            required = ["specialized multi-argument string lowering requires every argument to be String or Symbol",
                        "unreachable!(bms)  # polymorphic bottom; no fabricated String value",
                        "function compile_string_concat_many_b", "for loc in str_locals",
                        "_wt_many_string_length"]
            all_src = invoke_src * strings_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L67_one_exception_and_block_owner" => ("the stackifier alone owns block and try-region structure; no dead block-emission adapter or statement-level EnterNode implementation may coexist",
        () -> begin
            api_src = read(joinpath(SRC, "WasmTarget.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            forbidden = ["codegen/conditionals.jl", "generate_block_code!",
                         "For now, we just skip this - full implementation requires try_table"]
            required = ["THE stackifier owns the", "every CFG shape, including a single block",
                        "try_open_at", "try_table!(b"]
            all_src = api_src * stmt_src * flow_src * stack_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L68_one_runtime_type_representation" => ("type constants, TypeNames, population, and lookup tables use only the canonical JlType hierarchy; the raw Julia DataType fallback is extinct",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            forbidden = ["_populate_legacy_types!", "Legacy path: Populate Julia DataType",
                         "else fall back to Julia DataType", "else Julia DataType struct",
                         "Fallback: return i32 typeId", "Type not in globals — return null ref",
                         "Fallback: i32 typeId"]
            required = ["type constants require the canonical JlType hierarchy",
                        "TypeName constants require the canonical JlType hierarchy",
                        "type constant population requires the canonical JlType hierarchy",
                        "type lookup table requires the canonical JlType hierarchy"]
            all_src = types_src * calls_src * context_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L69_one_vector_mutation_path" => ("push!, pop!, and resize! compile their collected pure-Julia overlays; name-routed mutation emitters and capacity assumptions are extinct",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            runtime_src = read(joinpath(SRC, "runtime", "arrayops.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["is_func(func, :push!)", "is_func(func, :pop!)",
                         "is_func(func, :resize!)", "assume capacity is sufficient",
                         "function _resize!"]
            required = ["function Base.push!(v::Vector{T}, x)",
                        "function Base.pop!(v::Vector{T})",
                        "function Base.resize!(v::Vector{T}, n::Integer)",
                        "_wt_vector_mutation_semantics"]
            all_src = calls_src * interp_src * runtime_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L70_no_host_power_fallback" => ("power compiles through the collected Julia body; unresolved invokes cannot switch to a Math.pow host import or approximation",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["pow_import_idx", "requires 'pow' import", "approximation using exp",
                         "add_import!(mod, \"Math\", \"pow\"", "assume `Math.pow` sits at import index 0"]
            required = ["_wt_pure_power_semantics"]
            count(p -> occursin(p, invoke_src * compile_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L71_no_silent_io_argument_skip" => ("out-of-scope IO glue may reject an unrepresentable show argument but cannot silently omit it and report success",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["show: unsupported argument type \$arg_type, skipping"]
            required = ["show has no IO bridge representation for argument type",
                        "_wt_unsupported_show", "@test_throws WasmTarget.WasmCompileError"]
            all_src = invoke_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L72_no_fabricated_string_encoder" => ("the JS string boundary exposes only implemented imports; no unused encoder API may alias the decoder as a placeholder",
        () -> begin
            strings_src = read(joinpath(CODEGEN, "strings.jl"), String)
            forbidden = ["encode_idx", "add_string_io_imports!", "old approach as a stub"]
            count(p -> occursin(p, strings_src), forbidden)
        end),
    "L73_capture_analysis_never_silently_disables" => ("capture/value-channel proof failures propagate; no catch-all may erase all inferred joins and continue compilation",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            capture_src = read(joinpath(CODEGEN, "box_capture.jl"), String)
            capture_test = read(joinpath(ROOT, "test", "f3_box_capture_l2b_propagate.jl"), String)
            forbidden = ["catch\n        Dict{Int,Type}()", "capture analysis fallback"]
            required = ["_numeric_joins = try", "catch\n        rethrow()",
                        "propagate_numeric_value_types",
                        "f3_self_box_joins", "f3_closure_box_seeds",
                        "isconcretetype(T) && isstructtype(T)",
                        "Tuple{Vararg{Int64}}"]
            all_src = context_src * capture_src * capture_test
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L74_builder_owns_statement_arity" => ("post-emission drop decisions use the builder's actual stack delta; no Julia-type/registry heuristic may re-guess whether a call produced a value",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            forbidden = ["function statement_produces_wasm_value", "assume no value produced"]
            required = ["_stmt_stack0 = length(bb.v.stack)",
                        "_stmt_pushed_value = length(bb.v.stack) > _stmt_stack0",
                        "_stmt_emitted && _stmt_pushed_value"]
            all_src = context_src * stack_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L75_globalref_absence_is_explicit" => ("core typing, dispatch, and cross-call resolution test binding existence explicitly; broad catches cannot disguise internal resolution failures as a missing GlobalRef",
        () -> begin
            files = ["flow.jl", "stackified.jl", "dispatch.jl", "invoke.jl", "calls.jl"]
            src = join((read(joinpath(CODEGEN, f), String) for f in files), "\n")
            forbidden = ["actual_val = getfield(val.mod, val.name)\n            return get_phi_edge_wasm_type(actual_val",
                         "called_func = try\n            getfield(func.mod, func.name)",
                         "ft_early = try\n            infer_value_type"]
            required = ["isdefined(val.mod, val.name) || return nothing",
                        "isdefined(callee.mod, callee.name)",
                        "isdefined(actual_func_ref.mod, actual_func_ref.name)",
                        "isdefined(func.mod, func.name)"]
            count(p -> occursin(p, src), forbidden) + count(p -> !occursin(p, src), required)
        end),
    "L76_no_silent_invoke_or_io_substitution" => ("invoke resolution uses explicit singleton/binding predicates; unsupported IO cannot disappear or fabricate question-mark output",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            forbidden = ["func_type.instance\n                    catch", "try infer_value_type",
                         "No IO imports — stub as no-op", "unsupported argument type \$arg_type, skipping",
                         "Unsupported element type — just write \"?\"", "Create a synthetic GlobalRef for lookup"]
            required = ["function _compile_invoke_print_b", "_invoke_singleton_instance",
                        "Base.issingletontype(T)",
                        "println/print requires an explicitly configured IO bridge",
                        "println/print has no IO bridge representation"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !occursin(p, invoke_src), required)
        end),
    "L77_call_reflection_is_structural" => ("call lowering tests binding, singleton, tuple, and field structure explicitly; reflection failures cannot silently select another lowering",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            forbidden = ["try getfield(func.mod, func.name) catch", "try infer_value_type",
                         "try fieldtypes(obj_type) catch", "return try Base.padding",
                         "try getfield(target_type_ref.mod", "try getfield(args[1].value"]
            required = ["isdefined(func.mod, func.name)",
                        "obj_type isa DataType && isconcretetype(obj_type)",
                        "sext_int target is not a defined Julia type",
                        "zext_int target is not a defined Julia type",
                        "trunc_int target is not a defined Julia type"]
            count(p -> occursin(p, calls_src), forbidden) +
                count(p -> !occursin(p, calls_src), required)
        end),
    "L78_closed_world_reaches_a_real_fixpoint" => ("dynamic and explicit-invoke discovery are unconditional fixpoints with no environment opt-out, round ceiling, method-count cliff, or swallowed specialization failure",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            tests_src = read(joinpath(ROOT, "test", "runtests.jl"), String)
            forbidden = ["WT_DYNDISPATCH", "for _round in 1:8", "length(ms) <= 64",
                         "try CC.specialize_method", "try collect(methods", "try which(f, ats)"]
            required = ["while true", "hasmethod(f, ats) ? which(f, ats) : nothing",
                        "dynamic dispatch: discover every target admitted by the closed",
                        "has no environment opt-out or arbitrary round/method ceiling"]
            all_src = trim_src * tests_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L79_partial_new_requires_definite_initialization" => ("Wasm physical defaults for missing primitive fields are emitted only when a closed-world CFG must-analysis proves every field is written before read or escape",
        () -> begin
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["struct_type === Random.Xoshiro", "nameof(struct_type)",
                         "primitive_init_proven = true", "allow_uninitialized"]
            required = ["function _definitely_initializes_in_ir", "intersect(incoming[dest], assigned)",
                        "_partial_new_is_definitely_initialized", "primitive_init_proven",
                        "_wt_make_undefined_field", "_wt_use_definitely_initialized_fields"]
            all_src = stmts_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L80_dynamic_callable_enrollment_is_function_scoped" => ("dynamic callable bodies are paired only with signatures observed in the same collected function; no component-wide arity Cartesian product may enroll unrelated functions",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            forbidden = ["    dyn_sigs = Set", "    callable_types = Set", "for _T in callable_types",
                         "for ds in dyn_sigs"]
            required = ["callable_invocations = Set{Tuple{DataType,Tuple}}()",
                        "function flush_callable_invocations!",
                        "for T in _fn_callables, sig in _fn_dyn_sigs",
                        "Never form a component-wide Cartesian product"]
            count(p -> occursin(p, trim_src), forbidden) +
                count(p -> !occursin(p, trim_src), required)
        end),
    "L81_kwerr_throws_exact_methoderror" => ("reachable invalid-keyword paths throw a real MethodError with Core.kwcall, exact argument tuple, and collection world instead of a generic trap",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            required = ["name === :kwerr", "emit_value!(bkw, Core.kwcall",
                        "args_tuple_type = Tuple{arg_julia_types...}",
                        "Base.get_world_counter()", "_wt_exact_kwerr_exception"]
            count(p -> !occursin(p, invoke_src * test_src), required)
        end),
    "L82_inexact_helper_throws_exact_payload" => ("Core.throw_inexacterror constructs the real InexactError func and argument tuple and throws it through the Julia exception tag",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            required = ["name === :throw_inexacterror", "payload = args[2:end]",
                        "payload_type = Tuple{payload_types...}",
                        "register_struct_type!(ctx.mod, ctx.type_registry, InexactError)",
                        "_wt_exact_inexact_exception"]
            count(p -> !occursin(p, invoke_src * test_src), required)
        end),
    "L64_no_unknown_numeric_type_guess" => ("unknown values and unresolved globals retain Any instead of being guessed as Int64",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            forbidden = ["If we can't evaluate, default to Int64",
                         "phi_julia_type = Int64", "phic_julia_type = Int64",
                         "phi_wasm_type = I64  # Default for Any/Union"]
            required = ["An unresolved global has no numeric type evidence",
                        "Preserve missing type evidence as Any", "end\n    return Any\nend"]
            count(p -> occursin(p, context_src), forbidden) +
                count(p -> !occursin(p, context_src), required)
        end),
    "L63_no_control_or_allocation_defaults" => ("dynamic dispatch and Bool conditions never synthesize values; partial %new uses null only as Julia's explicit undefined-reference sentinel and rejects missing physical values",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["push_default! =", "drop!(b); i32_const!(b, 0)",
                         "emit default values for the missing fields"]
            required = ["value-producing dynamic dispatch selected a void target",
                        "Bool condition has a non-boolean reference representation",
                        "struct construction leaves a non-reference Julia field undefined",
                        "_wt_make_undefined_field"]
            count(p -> occursin(p, calls_src) || occursin(p, values_src) || occursin(p, stmts_src), forbidden) +
                count(p -> !(occursin(p, calls_src) || occursin(p, values_src) ||
                             occursin(p, stmts_src) || occursin(p, test_src)), required)
        end),
    "L62_exact_primitive_reinterpret_layout" => ("primitive ReinterpretArray construction folds exact bits/padding predicates, preserves runtime dimension errors, and bottom helpers never acquire a result representation",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            test_src = read(joinpath(ROOT, "test", "reinterpret_array_semantics.jl"), String)
            required = ["Base.isbitstype(", "{S<:_WT_PRIMITIVE_BITS,T<:_WT_PRIMITIVE_BITS} = true",
                        "ctx.return_type === Union{}", "ctx.return_type !== Union{}",
                        "_reinterpret_invalid_dimension"]
            count(p -> !(occursin(p, interp_src) || occursin(p, context_src) ||
                         occursin(p, stack_src) || occursin(p, test_src)), required)
        end),
    "L61_one_pure_interpolation_path" => ("Base.print_to_string is one pure-Julia overlay route and no invoke arm may truncate Int64 interpolation through Int32",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["elseif name === :print_to_string", "string interpolation requires int_to_string"]
            required = ["function Base.print_to_string(xs...)", "typemax(Int64)", "typemin(Int64)"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !(occursin(p, interp_src) || occursin(p, test_src)), required)
        end),
    "L60_no_fabricated_exception_payloads" => ("exception lowering either initializes every Julia field exactly or rejects it; no null/zero/default exception fabrication remains",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            forbidden = ["struct_new_default!(_thrb", "Default: push null ref for ref fields",
                         "ref_null!(berr, ArrayRef)", "name === :throw || name === :throw_boundserror",
                         "PURE-9032: Error constructors"]
            required = ["constant exception contains undefined fields",
                        "isempty(args) ? \"\" : args[1]"]
            count(p -> occursin(p, calls_src) || occursin(p, invoke_src), forbidden) +
                count(p -> !(occursin(p, calls_src) || occursin(p, invoke_src)), required)
        end),
    "L59_real_base_exception_helpers" => ("Bounds/Inexact/Domain/Overflow helper bodies construct and throw their real Julia exceptions; no name-routed null-payload helper family remains",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["Stash a ref.null any as exception", "no specific value for these",
                         "no specific value)"]
            required = ["_wt_bounds_helper_catch", "_wt_inexact_helper_catch",
                        "_wt_domain_helper_catch", "_wt_overflow_helper_catch"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L58_no_bottom_invoke_stub" => ("Bottom-returning invokes compile their collected target and preserve native catch flow; no generic null exception may replace an unresolved invoke",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["get(ctx.ssa_types, idx, Any) === Union{}",
                         "an :invoke with inferred rettype Union{}"]
            required = ["_wt_bottom_invoke_catch", "typemax(Int64)"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L57_exact_typeassert_exception" => ("proven typeassert failure throws a classed TypeError preserving func, context, expected type, and the concretely boxed got value",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            required = ["function _emit_typeerror_throw!", "Any[:typeassert, \"\", target, got]",
                        "i == 4 ? get_ssa_type(ctx, got)",
                        "_emit_typeerror_throw!(fb, args[1], _ta_target",
                        "err.expected === String", "err.got isa Int64"]
            forbidden = ["null-payload throw", "union_bottom_throw_stub shape"]
            count(p -> !occursin(p, calls_src * test_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L56_real_bottom_exception_bodies" => ("Union{} functions compile their actual Julia body and preserve catchable exception identity; no null-payload whole-body stub may replace them",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["union_bottom_throw_stub", "Auto-stub functions that always throw",
                         "if return_type === Union{}"]
            required = ["_wt_bottom_throw", "err isa ArgumentError"]
            count(p -> occursin(p, compile_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L55_static_type_rendering_excludes_compiler_metadata" => ("Type{T} stays specialized through string/print/show so generated-function Method metadata never enters the runtime constant graph",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            required = ["Base.string(::Type{T})", "Base.print(io::IO, ::Type{T})",
                        "Base.show(io::IO, ::Type{T})", "_wt_type_name_str(T)",
                        "f === _wt_type_name_str"]
            count(p -> !occursin(p, interp_src), required)
        end),
    "L54_pure_dense_statistics_correlation" => ("dense float correlation retains Statistics corm arithmetic over one explicitly length-validated index domain",
        () -> begin
            stats_src = read(joinpath(ROOT, "ext", "WasmTargetStatisticsExt.jl"), String)
            required = ["Statistics.corm(", "x::Vector{T}, mx::T, y::Vector{T}, my::T",
                        "length(y) == n", "@simd for i in eachindex(x)",
                        "Statistics.clampcor("]
            forbidden = ["@simd for i in eachindex(x, y)"]
            count(p -> !occursin(p, stats_src), required) +
                count(p -> occursin(p, stats_src), forbidden)
        end),
    "L53_pure_dense_linalg_kernels" => ("dense float norm/opnorm and mutating vector kernels stay in pure Julia with homogeneous signatures and one explicitly validated index domain",
        () -> begin
            linalg_src = read(joinpath(ROOT, "ext", "WasmTargetLinearAlgebraExt.jl"), String)
            required = ["LinearAlgebra.norm(x::Array{T,N})",
                        "LinearAlgebra.opnorm(", "_wt_osj_svdvals(A)",
                        "a::T, x::Vector{T}, y::Vector{T}",
                        "a::T, x::Vector{T}, b::T, y::Vector{T}",
                        "LinearAlgebra.rotate!(", "LinearAlgebra.reflect!(",
                        "length(x) == length(y)", "for i in eachindex(x)"]
            forbidden = ["for i in eachindex(x, y)",
                         "LinearAlgebra.norm(x::Vector{T})"]
            count(p -> !occursin(p, linalg_src), required) +
                count(p -> occursin(p, linalg_src), forbidden)
        end),
    "L52_dynamic_storage_owner_and_generic_norm" => ("pointer consumers retain runtime Memory/MemoryRef ownership across allocation phis, memmove returns its exact destination, and float norm uses LinearAlgebra's pure generic reference path instead of BLAS FFI",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            linalg_src = read(joinpath(ROOT, "ext", "WasmTargetLinearAlgebraExt.jl"), String)
            required = ["owner_is_memory ? owner_arg",
                        "Canonicalize repeated `.mem` projections",
                        "emit_value!(b, dest_ptr_arg, ctx, I64)",
                        "LinearAlgebra.generic_norm2(x)",
                        "LinearAlgebra.generic_normp(x, p)"]
            forbidden = ["memmove returns dest ptr — push i64.const 0"]
            all_src = statements_src * linalg_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L51_no_escaping_or_ambiguous_storage_pointers" => ("jl_value_ptr is an exact storage-relative offset only under whole-use-graph proof; escaping values and phis over different backing objects reject",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["_storage_relative_pointer_is_closed(ctx, idx)",
                        "jl_value_ptr escapes storage-relative WasmGC operations",
                        "phi-multiple-storage",
                        "soundness_fatal=true"]
            forbidden = ["fake-pointer", "fake pointer"]
            all_src = statements_src * calls_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L50_closed_world_result_lub_and_reinterpret_bits" => ("dynamic selector results use the closed-world target LUB, proven numeric phis are globally typed, and primitive ReinterpretArray operations use structural value bits rather than host layout queries",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["foldl(typejoin, returns)",
                        "ctx.ssa_types[_jk] = _jv",
                        "foreach(observe_type!, T.parameters)",
                        "last_param isa Core.TypeofVararg",
                        "runtime_type <: atypes[p]",
                        "Base.array_subpadding",
                        "Core.bitcast(T, bits)",
                        "% TargetBits",
                        "% SourceBits"]
            forbidden = ["getfield(a, :parent)"]
            all_src = context_src * interp_src * trim_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L49_monomorphic_invokes_and_typed_args" => ("explicit invokes specialize from concrete SSA types and every argument converts at emission; positional post-push repairs and runtime-generic _compute_sparams lowering are forbidden",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            required = ["ir_arg_type = function", "Base._methods_by_ftype",
                        "param_types = first_explicit <= length(target_info_early.arg_types)",
                        "Push arguments through the resolved target signature",
                        "Base.ReinterpretArray{T,N,S,A,false}"]
            forbidden = ["only handle the case where the LAST arg",
                         "Also handle middle args if needed",
                         "extern_convert_emitted_args", "compile_compute_sparams"]
            all_src = trim_src * invoke_src * calls_src * interp_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L48_exact_mutable_global_initialization" => ("mutable GlobalRefs use identity-keyed exact initializer functions behind the one module start; fabricated default objects and silent partial emission are forbidden",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            all_src = compile_src * context_src * types_src * values_src
            required = ["mutable_constant_globals", "module_init_functions",
                        "finalize_module_initializers!", "function_wasm_signature",
                        "GlobalRef is not defined in its source module"]
            forbidden = ["module_globals", "patched at runtime, so exact field values don't matter",
                         "If we can't evaluate, might be a type reference"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L47_single_memmove_lowering" => ("memmove/memcpy has one array-copy lowering and its one pointer walk recognizes Vector, Memory, String, and Symbol backing identities",
        () -> begin
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["extract_foreigncall_name(st.args[1]) in (:jl_string_ptr, :jl_symbol_name)",
                        "backing_type === String || backing_type === Symbol"]
            count(p -> !occursin(p, stmt_src), required) +
                abs(length(collect(eachmatch(r"if \(name === :memmove \|\| name === :memcpy\)", stmt_src))) - 1)
        end),
    "L46_symbol_syntax_value_metadata" => ("operator and syntactic-operator classification travels on the classed Symbol/string value across normal calls; unknown dynamic Symbols trap instead of defaulting false",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            all_src = types_src * values_src * stmt_src
            required = ["symbol_syntax_flags", "syntax_flags::Integer=-1",
                        "name in (:jl_is_operator, :jl_is_syntactic_operator)",
                        "dynamically-created Symbol lacks operator metadata"]
            forbidden = [":name_is_operator", ":singleton_is_operator",
                         "ASCII-only operator"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L45_one_source_slot_and_vararg_abi" => ("semantic Core.Argument source types have one slot authority while the one physical vararg projection path maps fixed-prefix packs by their ABI offset",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            helpers_src = read(joinpath(CODEGEN, "helpers.jl"), String)
            required = ["function source_slot_type", "source_type = source_slot_type(ctx, val.n)",
                        "local _gft_fixed = args[1].n - 2",
                        "physical_offset + i - 1", "_gft_result_T isa Union ? AnyRef",
                        "function is_builtin_func"]
            forbidden = ["ctx.code_info.slottypes[args[1].n]",
                         "ctx.code_info.slottypes[val.id]",
                         "func.name in (:isdefined, :getfield, :setfield!) && func.mod in"]
            all_src = context_src * calls_src * values_src * flow_src * helpers_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L44_interned_module_metadata" => ("Module is one interned identity object with exact name/parent and collected binding visibility metadata; no empty shell or TypeName module-name string surrogate remains",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            all_src = types_src * values_src * calls_src * stmt_src
            required = ["get_module_constant_global!", "_closed_world_isvisible",
                        "emit_closed_world_isvisible!", "name_visible_main",
                        "_fc_sym === :jl_module_parent", "_fc_sym === :jl_module_name"]
            forbidden = ["Module constant — empty struct", "module_name (mut string ref)",
                         "module_name → string"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L43_typename_world_bounds_metadata" => ("mutable Julia BindingPartition history is reduced once to exact immutable TypeName world-bound metadata; no partial Binding object or fake partition chain exists",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            all_src = types_src * calls_src * interp_src * trim_src
            required = ["world_bounded", "Base.check_world_bounded(tn)",
                        "emit_closed_world_type_bounds!",
                        "_closed_world_type_bounds", "f === _closed_world_type_bounds"]
            forbidden = ["registry.structs[Core.Binding]",
                         "registry.structs[Core.BindingPartition]",
                         "jl_bpart_get_restriction_value"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L42_exact_unicode_property_table" => ("utf8proc category/width and Julia identifier predicates share one exact version-matched packed table and one pre-indexed helper; target Wasm never substitutes ASCII-only answers",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["const _UTF8PROC_PROPERTY_DATA",
                        "get_or_create_unicode_property_func!",
                        "needs_unicode_properties && get_or_create_unicode_property_func!",
                        "_fc_sym === :utf8proc_category",
                        "_fc_sym === :utf8proc_charwidth",
                        "name === :jl_id_start_char", "name === :jl_id_char"]
            forbidden = ["assume valid, conservative", "true = always a grapheme break"]
            all_src = types_src * compile_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L41_cross_calls_share_builder_stack" => ("cross-function argument pushes, call pops, and result coercion execute on the same authoritative builder stack",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["local _xcb = fb", "Arguments already live on `fb`"]
            forbidden = ["local _xcb = _ctx_builder(ctx, \"compile_call\")\n                call!(_xcb, target_info.wasm_idx"]
            count(p -> !occursin(p, calls_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L40_explicit_invokes_in_closed_world" => ("every explicit invoke MethodInstance is enrolled before selector discovery; unspecialized Vararg signatures never become physical Wasm entries",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["function _missing_explicit_invoke_mis",
                        "extra_invokes = _missing_explicit_invoke_mis",
                        "any(T -> T isa Core.TypeofVararg, arg_types) && continue"]
            count(p -> !occursin(p, trim_src), required)
        end),
    "L39_only_proven_dead_traps" => ("unsupported lowering rejects unless its Julia CFG block is proven unreachable; non-dominance is never treated as deadness",
        () -> begin
            diag_src = read(joinpath(CODEGEN, "diagnostics.jl"), String)
            gen_src = read(joinpath(CODEGEN, "generate.jl"), String)
            required = ["function stmt_is_proven_unreachable",
                        "!stmt_is_proven_unreachable",
                        "soundness_fatal=(soundness_fatal && !_dead2)",
                        "soundness_fatal=(soundness_fatal && !_dead)"]
            forbidden = ["soundness_fatal && _me", "soundness_fatal && _me2",
                         "sound *silent* trap", "A non-must-execute"]
            count(p -> !occursin(p, diag_src * gen_src), required) +
                count(p -> occursin(p, diag_src), forbidden)
        end),
    "L38_no_known_value_substitutions" => ("known Memory, ifelse, allocation, and grapheme gaps reject instead of substituting null, zero, one, or an arbitrary arm",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["Memory constant of type \$T has an undefined slot",
                        "array.new_fixed 0",
                        "ifelse condition did not lower to i32",
                        "ifelse operand emitted no runtime value",
                        "utf8proc_grapheme_break_stateful requires the Unicode grapheme runtime",
                        "jl_alloc_string without its required length operand"]
            forbidden = ["Memory constant too large to materialize (\$n_mem elements) — emitting null",
                         "Fall back to emitting just the true value",
                         "true = always a grapheme break"]
            all_src = values_src * calls_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L37_no_fabricated_constant_fields" => ("constant fallbacks emit the registered Object prefix and every real field through its physical expected type; undefined fields are rejected",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            required = ["WT never fabricates field values",
                        "emit_struct_prefix!(b, ctx.type_registry, T, info)",
                        "emit_value!(b, field_val, ctx, expected; from_julia=fieldtype(T, fi))"]
            forbidden = ["emit ref.null for the field's expected type",
                         "type-correct defaults",
                         "mismatched concrete struct ref"]
            count(p -> !occursin(p, values_src), required) +
                count(p -> occursin(p, values_src), forbidden)
        end),
    "L36_no_hash_dispatch_residue" => ("the live selector registry contains no FNV-era hash/table/global fields and never fabricates a numeric value for a void target",
        () -> begin
            dispatch_src = read(joinpath(CODEGEN, "dispatch.jl"), String)
            forbidden = ["hash::UInt32", "table_size::Int32", "mask::Int32",
                         "keys_global_idx::", "values_global_idx::", "typeids_global_idx::",
                         "func_table_idx::", "i32_array_type_idx::",
                         "VALUE-typed dispatch signature over a", "MIRROR hole"]
            required = ["all_no_return ? nothing"]
            count(p -> occursin(p, dispatch_src), forbidden) +
                count(p -> !occursin(p, dispatch_src), required)
        end),
    "L34_single_pointer_lowering" => ("add_ptr/sub_ptr/pointerref/pointerset each have one compile_call lowering route",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            sum(max(count(line -> occursin("func.name === :$(name)", line), split(calls_src, '\n')) - 1, 0)
                for name in (:add_ptr, :sub_ptr, :pointerref, :pointerset))
        end),
    "L35_unwrapped_emissions_classified" => ("every intentional no-expectedType emission is explicitly classified by why its actual type is the consumer contract",
        () -> begin
            n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                endswith(f, ".jl") || continue
                for line in eachline(joinpath(dir, f))
                    occursin(r"emit_value!\([^()]*, ctx\)", line) || continue
                    occursin("function emit_value!", line) && continue
                    occursin("R17-floor:", line) || (n += 1)
                end
            end
            n
        end),
    "L32_empty_tuple_egal" => ("Tuple{} is an immutable zero-field singleton: dynamic Any-versus-() egal tests its concrete tuple type rather than heap identity",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["tuples are still egal in Julia",
                        "(arg_type === Any && arg2_type === Tuple{})",
                        "ref_test!(bld, Int64(empty_info.wasm_type_idx), false)"]
            count(p -> !occursin(p, calls_src), required)
        end),
    "L31_multi_container_apply" => ("homogeneous multi-Vector _apply_iterate reductions traverse every container through one loop generator and never return an identity for Julia's invalid all-empty +()/*() call",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["container_args = args[3:end]",
                        "for (container_arg, container_type) in zip(container_args, container_types)",
                        "_emit_apply_method_error!",
                        "MethodError(f, (), world)",
                        "Base.get_world_counter()",
                        "_get_binary_reduce_opcode(target_value, elem_type)",
                        "func === (+)",
                        "local_set!(bld, has_value)"]
            forbidden = ["_get_binary_reduce_opcode(func_name"]
            count(p -> !occursin(p, calls_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L30_runtime_vararg_tuple" => ("Core._apply_iterate uses a real Object/data/size representation for runtime Vararg tuples and tests Tuple{} from runtime arity; it never fabricates an empty tuple",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            structs_src = read(joinpath(CODEGEN, "structs.jl"), String)
            required = ["_iterable_proven_empty(container_arg, ctx)",
                        "register_vararg_tuple_type!",
                        "is_runtime_vararg_tuple_type",
                        "unsupported Vararg tuple layout",
                        "result_type=result_type",
                        "A runtime-length tuple is empty iff its immutable size tuple says zero"]
            forbidden = ["produces a Tuple{Vararg{Symbol}} which is checked",
                         "must emit a struct.new of the actual Tuple{} type"]
            all_src = calls_src * structs_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L29_recursive_type_groups" => ("recursive definitions use ordered contiguous Wasm recursion-group intervals; no post-hoc nominal regrouping or process-global registration stack may reorder type indices",
        () -> begin
            builder_src = read(joinpath(SRC, "builder", "instructions.jl"), String)
            structs_src = read(joinpath(CODEGEN, "structs.jl"), String)
            required = [
                "recursive groups must be contiguous type-section intervals",
                "recursive group indices must be in type-section order",
                "sort!(rec_group_types)",
                "_struct_reg_stack() = get!",
                "ft === T && return true",
                "The wrapper's size tuple must precede the contiguous recursive group",
                "The recursive struct's own superclass must also precede its reserved",
            ]
            all_src = builder_src * structs_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src),
                      ["ensure_nominal_struct_types!", "const _STRUCT_REG_STACK"])
        end),
    "L28_ordinary_object_prefix" => ("ordinary structs, tuples, and Array wrappers inherit Object's classId/identityHash prefix through one representation-aware allocation funnel",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            structs_src = read(joinpath(CODEGEN, "structs.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = [
                "object_prefix_fields()",
                "emit_object_prefix!",
                "emit_struct_prefix!",
                "fields = value_branch ? FieldType[FieldType(I32, false)] : object_prefix_fields()",
                "T <: Number ? registry.base_struct_idx : get_object_struct_type!",
                "wasm_fields = object_prefix_fields()",
                "if T === Core.Box",
                "StructInfo(T, idx, [:contents], Type[Any], UInt32(1))",
                "StructInfo(T, type_idx, field_names, field_types, UInt32(2))",
                "StructInfo(T, type_idx, field_names, field_types_vec, UInt32(2))",
                "emit_struct_prefix!(b, ctx.type_registry, struct_type, info)",
                "ctx.type_registry.structs[object_type].field_offset == 2",
            ]
            all_src = types_src * structs_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), ["set_struct_supertypes!"])
        end),
    "L27_no_postbuilder_byte_truncation" => ("the finalized typed instruction IR is authoritative; no raw-byte scanner may truncate or repair function bodies afterward",
        () -> begin
            gen_src = read(joinpath(CODEGEN, "generate.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            builder_src = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            missing = count(p -> !occursin(p, gen_src * flow_src * builder_src),
                            ["finish_function!(b)", "structured IR has"])
            forbidden = count(p -> occursin(p, gen_src),
                              ["strip_excess_after_function_end", "Truncate everything after this byte",
                               "_last_instr_starts", "_instr_next", "_skip_leb_count",
                               "bytes[_tail", "dead returns at the very end"])
            missing + forbidden
        end),
    "L26_dispatch_roots_only" => ("dynamic selector candidates are only discovery roots; their transitive helper dependencies remain ordinary cross-call-visible functions",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["_DYNAMIC_ROOT_MIS", "union!(_DYNAMIC_ROOT_MIS[], extra)",
                        "mi in _DYNAMIC_ROOT_MIS[]"]
            forbidden = ["pair_no > base_pairs", "_TRIM_BASE_PAIRS"]
            count(p -> !occursin(p, trim_src), required) + count(p -> occursin(p, trim_src), forbidden)
        end),
    "L25_flat_runtime_composition" => ("runtime-length composition is typed before optimization as a valid-Julia flat callable and allocated through normal struct codegen",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            call_src = read(joinpath(CODEGEN, "calls.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["struct _RuntimeComposition", "function CC.abstract_apply(interp::WasmInterpreter",
                        "_RuntimeComposition{container}", "_runtime_composition_apply",
                        "_emit_runtime_composition_context!", "register_closure_type!",
                        "T <: _RuntimeComposition"]
            forbidden = ["compose_and_call", "composition_callsite", "fake_composition"]
            all_src = interp_src * call_src * compile_src * trim_src
            count(p -> !occursin(p, all_src), required) + count(p -> occursin(p, all_src), forbidden)
        end),
    "L24_unified_static_tearoffs" => ("named-function tear-offs enroll in the closed world and use the same closure Object/context/vtable/RTI representation as capturing closures",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            required = ["_ENROLLED_CALLABLE_TYPES", "isdefined(T, :instance)",
                        "typeof(f) in _ENROLLED_CALLABLE_TYPES[]", "takes_context ? 1 : 0",
                        "get_nothing_global!(ctx.mod, ctx.type_registry)"]
            forbidden = ["static_tearoff_struct", "tearoff_base_idx", "tearoff_callsite"]
            all_src = trim_src * compile_src * closure_src
            count(p -> !occursin(p, all_src), required) +
            count(p -> occursin(p, all_src), forbidden)
        end),
    "L23_closure_rti" => ("closure objects copy Dart's Object/context/vtable/functionType layout and use a real closed-world Julia type object",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["FieldType(ConcreteRef(get_datatype_type_idx(registry), false), false)",
                        "haskey(type_globals, closure_type)",
                        "global_get!(b, type_global",
                        "observe_callable!(CC.widenconst(t))"]
            forbidden = ["functionType=ref.null", "dummy functionType", "placeholder functionType"]
            count(p -> !occursin(p, types_src * closure_src * trim_src), required) +
            count(p -> occursin(p, types_src * closure_src), forbidden)
        end),
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
        () -> count_sites(r"dummy anyref|emit empty string|fallback to constant hash|exception placeholder|benign null placeholder|union_bottom_throw_stub|Core\.svec \(SimpleVector construction\)")),
    "L18_no_value_repair_defaults" => ("PiNode, GlobalRef, returns, SSA stores, and struct fields preserve and coerce the emitted value; no zero/null repair helper or duplicate return ladder may remain",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            forbidden_count = count_sites(
                r"needs_type_safe_default|_emit_default!|_append_default!|_gv_replaced|ssa_type_mismatch|Push a type-correct default|compile_value produced empty bytes")
            forbidden_count +
                (occursin("emit_return_coerced!(b, stmt.val, ctx)", statements_src) ? 0 : 1)
        end),
    "L17_one_compilation_path" => ("public compilation always enters the closed-world planner; legacy discovery, recursive mode switching, byte shells, and legacy body compilers are extinct",
        () -> count_sites(r"_TRIM_ACTIVE|discovery=:legacy|discover_dependencies|AUTODISCOVER|FrozenCompilationState|InplaceCompilationContext|compile_from_ir_(?:inplace|prebaked)|compile_module_from_ir_frozen|compile_handler|compile_closure_body|compile_function_into!|compile_const_value|overlay_entries|_autodiscover_closure_deps!|run_selfhost|run_direct|to_bytes_mvp|FakeGlobalRef|wasm_compile_(?:flat|source)|function _compile_function_legacy|function compile_(?:value|statement|call|invoke|new|foreigncall|condition_to_i32)\([^!]")),
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
                recent = String[]
                for line in eachline(joinpath(dir, f))
                    if occursin(r"unreachable!\(", line) && !occursin("function unreachable!", line) &&
                       !startswith(lstrip(line), "#") &&
                       !occursin("structural trap", line) &&
                       !any(prev -> occursin("record_unsupported!", prev), recent)
                        n += 1
                    end
                    push!(recent, line)
                    length(recent) > 5 && popfirst!(recent)
                end
            end
            n
        end),
    "L7_wasmtools_demoted" => ("no always-on external-validate default may return — validity is the strict builder's job; wasm-tools is opt-in (validate=true / WT_VALIDATE=1) (M4; locked 2026-07-01)",
        () -> count_sites(r"validate::Bool\s*=\s*true")),
    "L6_all_builders_strict" => ("instruction validation is unconditional: no strict/enabled field, environment switch, setter, constructor keyword, production opt-out, or silently unmodeled opcode may exist.",
        () -> begin
            builder_root = joinpath(SRC, "builder")
            validator_src = read(joinpath(builder_root, "validator.jl"), String)
            required = ["unmodeled Wasm opcode", "unmodeled Wasm GC opcode"]
            forbidden_count = count_sites(
                r"InstrBuilder\([^)]*strict\s*=|_wt_builder_strict|set_strict!|strict::Bool|enabled::Bool|enabled\s*=|skip silently";
                roots=[builder_root])
            forbidden_count + count(p -> !occursin(p, validator_src), required)
        end),
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
