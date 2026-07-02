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
        elseif (m = match(r"^(\w+)\s*=\s*(\d+)$", s)) !== nothing && !isempty(section)
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
            any(x -> endswith(path, x), exclude_files) && continue
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
    "R1_untyped_compile_value" => ("untyped compile_value( callers (M2 → 0)",
        () -> count_sites(r"compile_value\("; exclude_line=r"function compile_value\(")),
    "R2_emit_raw_bridges" => ("emit_raw!( byte-bridges into the typed builder (M2 → 0)",
        () -> count_sites(r"emit_raw!\("; exclude_line=r"function emit_raw!")),
    "R3_infer_value_type" => ("infer_value_type( re-guess callers (M2 → 0 + delete fn)",
        () -> count_sites(r"infer_value_type\("; exclude_line=r"function infer_value_type\(")),
    "R5_julia_type_reguess" => ("get_concrete_wasm_type( + julia_to_wasm_type_concrete( callers (M2 → pre-emit floor)",
        () -> count_sites(r"get_concrete_wasm_type\(|julia_to_wasm_type_concrete\(";
                          exclude_line=r"function (get_concrete_wasm_type|julia_to_wasm_type_concrete)\(")),
    "R7_raw_coercion_ops" => ("numeric-coercion opcodes outside values.jl's convert_type! funnel (M2 → intrinsic floor)",
        () -> count_sites(r"I32_WRAP_I64|I64_EXTEND_I32_S|I64_EXTEND_I32_U|I64_TRUNC_F|I32_TRUNC_F|F64_CONVERT_I|F32_CONVERT_I|F32_DEMOTE_F64|F64_PROMOTE_F32";
                          roots=[CODEGEN], exclude_files=["values.jl"])),
    "R10_silent_unreachable" => ("unreachable!( emissions in codegen (M5: silent stubs → loud reject; post-throw legit uses get annotated + excluded when M5 refines this)",
        () -> count_sites(r"unreachable!\("; roots=[CODEGEN],
                          exclude_line=r"function unreachable!")),
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
    "L1_box_typeid_external" => ("emit_box_type_id! callers outside its home files (ONE box producer; locked 2026-06-30)",
        () -> count_sites(r"emit_box_type_id!\(";
                          exclude_files=["codegen/values.jl", "codegen/types.jl"],
                          exclude_line=r"function emit_box_type_id!")),
    "L2_ref_i31_callers" => ("ref_i31! callers (i31 box family deleted; locked 2026-06-30)",
        () -> count_sites(r"ref_i31!\(";
                          exclude_line=r"^ref_i31!\(b::InstrBuilder\)|function ref_i31!")),
    "L7_wasmtools_demoted" => ("no always-on external-validate default may return — validity is the strict builder's job; wasm-tools is opt-in (validate=true / WT_VALIDATE=1) (M4; locked 2026-07-01)",
        () -> count_sites(r"validate::Bool\s*=\s*true")),
    "L6_all_builders_strict" => ("explicit InstrBuilder strict opt-outs — ZERO: every builder is a hard type-checking gate, always-on (M4; locked 2026-07-01)",
        () -> count_sites(r"InstrBuilder\([^)]*strict\s*=\s*false")),
    "L5_no_tagged_union" => ("the tagged-union wrapper family is DELETED — needs_tagged_union/emit_(un)wrap_union_value must never reappear (M3; locked 2026-07-01)",
        () -> count_sites(r"needs_tagged_union\(|emit_wrap_union_value\(|emit_unwrap_union_value\(")),
    "L4_no_postemit_reguess" => ("infer_value_wasm_type is GONE — renamed to static_wasm_type (pre-emit-ONLY contract); the post-emission re-guess anti-pattern is dead (M2; locked 2026-07-01)",
        () -> count_sites(r"infer_value_wasm_type\(")),
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
