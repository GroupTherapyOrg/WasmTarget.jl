# ============================================================================
# Failure Ledger — turns every compiler failure into a trackable, fixable artifact
# ============================================================================
#
# Every failure WasmTarget surfaces — a strict-mode rejection, a validation
# reject, or a fuzzer-found wrong-value / runtime-trap / divergent-throw — is
# recorded here as a committed Markdown "gap" file under test/fuzz/failures/.
#
# The self-fulfilling loop:
#   1. discovery (strict-run triage or the fuzzer) calls `record_gap!`
#   2. each gap is written to failures/<id>.md with a SELF-CONTAINED reproducer
#      whose contract is: **it throws while the gap is present, and runs cleanly
#      once the gap is fixed.**
#   3. a follow-up loop fixes the compiler, then runs `verify_gaps!()`, which
#      re-runs every open gap's reproducer and flips the ones that now pass to
#      `status: fixed` — gaps auto-close, no manual bookkeeping.
#   4. `regenerate_index!()` rewrites INDEX.md, the dashboard a loop reads to
#      pick the next open gap.
#
# Gap ids are a stable, session-independent FNV-1a hash of the gap's identity
# (category + construct + location), so re-discovering the same gap updates the
# same file instead of creating duplicates.

module Ledger

export Gap, gap_id, record_gap!, verify_gaps!, regenerate_index!, open_gaps, load_gaps, rank_gaps

const LEDGER_DIR = joinpath(@__DIR__, "failures")

const CATEGORIES = (:strict_reject, :validation_fail, :wrong_value, :runtime_trap, :divergent_throw)

# Stable, session-independent id (FNV-1a 64-bit → hex) over the gap's identity.
function _stable_id(parts...)
    s = join(string.(parts), "␟")
    h = 0xcbf29ce484222325
    for b in codeunits(s)
        h = (h ⊻ b) * 0x100000001b3
        h &= 0xffffffffffffffff
    end
    return string(h, base = 16, pad = 16)[1:12]
end

"""
    gap_id(category, construct, location) -> String

Stable id identifying a distinct gap. Same identity ⇒ same id ⇒ same file.
"""
gap_id(category, construct, location) = _stable_id(category, construct, location)

"""
    Gap

A single documented compiler gap.

- `category`   — one of `$(CATEGORIES)`
- `kind`       — diagnostic kind (e.g. `:unsupported_method`), or `:none`
- `construct`  — what wasn't handled (human description)
- `location`   — best-effort `"file:line"` of the offending construct
- `fn_name`    — the reproducer's entry function
- `arg_types`  — argument types as a string, e.g. `"(String,)"`
- `reproducer` — a self-contained Julia snippet. CONTRACT: it **throws** while the
                 gap is present and **runs cleanly** once fixed. (Strict/validation
                 gaps: the snippet is `compile(...)` itself. Wrong-value/trap gaps:
                 the snippet runs the differential check and `error`s on mismatch.)
- `diagnostic` — the captured error message / mismatch description
"""
struct Gap
    category::Symbol
    kind::Symbol
    construct::String
    location::String
    fn_name::String
    arg_types::String
    reproducer::String
    diagnostic::String
end

_id(g::Gap) = gap_id(g.category, g.construct, g.location)
_path(id::AbstractString) = joinpath(LEDGER_DIR, "$(id).md")

# --- Writing ---------------------------------------------------------------

const _ANALYSIS_PLACEHOLDER = "_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_"

function _render(g::Gap, id::AbstractString, status::AbstractString, first_seen::AbstractString,
                 analysis::AbstractString = _ANALYSIS_PLACEHOLDER)
    repro = strip(g.reproducer)
    diag = strip(g.diagnostic)
    """
    ---
    id: $id
    status: $status
    category: $(g.category)
    kind: $(g.kind)
    construct: $(repr(g.construct))
    location: $(repr(g.location))
    fn_name: $(g.fn_name)
    arg_types: $(repr(g.arg_types))
    first_seen: $first_seen
    ---

    # Gap `$id` — $(g.construct)

    **Category:** `$(g.category)` &nbsp;•&nbsp; **Kind:** `$(g.kind)` &nbsp;•&nbsp; **Location:** `$(g.location)`

    ## Reproducer
    Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
    A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

    ```julia
    $repro
    ```

    ## Diagnostic
    ```
    $diag
    ```

    ## Work on this
    ```
    julia --project=test/fuzz test/fuzz/run.jl verify
    ```

    ## Analysis
    $(strip(analysis))
    """
end

# Extract a hand-authored `## Analysis` section (everything after the heading) so
# it survives re-records. Returns the placeholder if absent/empty.
function _extract_analysis(path::AbstractString)
    isfile(path) || return _ANALYSIS_PLACEHOLDER
    m = match(r"(?s)\n## Analysis\n(.*)$", read(path, String))
    m === nothing && return _ANALYSIS_PLACEHOLDER
    body = strip(m.captures[1])
    return isempty(body) ? _ANALYSIS_PLACEHOLDER : body
end

# Parse the `key: value` header block of a gap file into a Dict.
function _parse_header(path::AbstractString)
    hdr = Dict{String,String}()
    open(path) do io
        first = readline(io)
        first == "---" || return hdr
        for line in eachline(io)
            line == "---" && break
            m = match(r"^([a-z_]+):\s*(.*)$", line)
            m === nothing && continue
            hdr[m.captures[1]] = m.captures[2]
        end
    end
    return hdr
end

"""
    record_gap!(g::Gap; run_id="") -> String

Write/refresh the gap's file. Preserves across re-records:
  * `status` (a gap marked `fixed` is not silently reopened — `verify_gaps!` reconciles)
  * `first_seen`
  * the hand-authored `## Analysis` section (root-cause notes a fix loop adds)
so re-discovering the same gap never clobbers human/loop analysis. Returns the gap id.
"""
function record_gap!(g::Gap; run_id::AbstractString = "")
    isdir(LEDGER_DIR) || mkpath(LEDGER_DIR)
    id = _id(g)
    path = _path(id)
    status = "open"
    first_seen = run_id
    analysis = _ANALYSIS_PLACEHOLDER
    if isfile(path)
        hdr = _parse_header(path)
        status = get(hdr, "status", "open")
        first_seen = get(hdr, "first_seen", run_id)
        analysis = _extract_analysis(path)
    end
    write(path, _render(g, id, status, first_seen, analysis))
    return id
end

# --- Loading / verifying ---------------------------------------------------

"""
    load_gaps() -> Vector{Dict{String,String}}

Header dicts for every gap file (each gains a `"reproducer"` key with the code
block body and a `"_path"` key).
"""
function load_gaps()
    isdir(LEDGER_DIR) || return Dict{String,String}[]
    gaps = Dict{String,String}[]
    for f in sort(readdir(LEDGER_DIR))
        # Gap files are named "<12-hex-id>.md"; skip reference docs (INDEX.md,
        # STUBBED_METHODS.md, etc.) that share the directory.
        occursin(r"^[0-9a-f]{12}\.md$", f) || continue
        path = joinpath(LEDGER_DIR, f)
        hdr = _parse_header(path)
        hdr["_path"] = path
        hdr["reproducer"] = _extract_first_code_block(read(path, String))
        push!(gaps, hdr)
    end
    return gaps
end

open_gaps() = filter(g -> get(g, "status", "open") == "open", load_gaps())

# --- Leverage ranking (G3) ---------------------------------------------------
# Group OPEN gaps into coarse root-cause FAMILIES and rank by leverage
# (count × (tier+1)), so the loop fixes the highest-fan-in root first instead of
# the easiest shrink — e.g. ~10 abstract-Dict-key gaps share ONE root, so closing
# it clears the whole cluster. The family tag is a transparent keyword rollup over
# the construct; precise per-diagnostic-site dedup would need compile-time
# instrumentation (DEFERRED — in practice fixing a high-fan-in root dissolves its
# cluster, which is the point of ranking). Tier weight up-ranks frontier work so a
# lone T1/T2 gap isn't buried under T0 polish. See test/fuzz/LOOP.md §6.
const GAP_FAMILIES = [
    ("abstract-Dict key (Int-widen)", r"Dict\(.*Int(8|16|32)", 0),
    ("median / quantile",             r"median\(|quantile\(",   0),
    ("Complex display",               r"Complex",               2),
    ("Matrix / hvcat element",        r"Matrix|hvcat",          0),
    ("dynamic dispatch",              r"dispatch|dynamic",      1),
    ("closure dependency pass",       r"closure",               1),
]
_gap_family(g) = begin
    c = get(g, "construct", "")
    for (name, re, tier) in GAP_FAMILIES
        occursin(re, c) && return (name, tier)
    end
    ("other (singleton)", 0)
end

"""
    rank_gaps(; io=stdout) -> Vector

Print OPEN gaps grouped by root-cause family, ranked by leverage
(`count × (tier+1)`). The loop should work the top row first.
"""
function rank_gaps(; io = stdout)
    gaps = filter(g -> get(g, "status", "open") == "open", load_gaps())
    groups = Dict{Tuple{String,Int},Vector{String}}()
    for g in gaps
        push!(get!(groups, _gap_family(g), String[]), get(g, "id", "?"))
    end
    ranked = sort(collect(groups); by = kv -> -(length(kv.second) * (kv.first[2] + 1)))
    println(io, "Open-gap leverage ranking — $(length(gaps)) open · score = count × (tier+1)")
    for ((name, tier), ids) in ranked
        println(io, "  [score $(length(ids) * (tier + 1)) | $(length(ids))×T$tier]  $name")
        println(io, "        ", join(ids, "  "))
    end
    return ranked
end

function _extract_first_code_block(text::AbstractString)
    m = match(r"```julia\n(.*?)\n```"s, text)
    return m === nothing ? "" : m.captures[1]
end

function _set_status!(path::AbstractString, newstatus::AbstractString)
    text = read(path, String)
    write(path, replace(text, r"^status: .*$"m => "status: $newstatus", count = 1))
end

"""
    verify_gaps!(; verbose=true) -> (fixed, still_open)

Re-run every OPEN gap's reproducer. The reproducer's contract is "throws while
present, runs cleanly once fixed" — so a clean run flips the gap to `fixed`.
Returns the counts. This is the function a follow-up loop calls after a fix.
"""
function verify_gaps!(; verbose::Bool = true)
    fixed = 0
    oos = 0
    still = 0
    for g in load_gaps()
        # Re-check OPEN gaps (did a fix land? did strict now reject them?) and existing
        # OUT_OF_SUBSET gaps (is the strict reject still live, or did real support land?).
        st = get(g, "status", "open")
        (st == "open" || st == "out_of_subset") || continue
        repro = get(g, "reproducer", "")
        isempty(strip(repro)) && (st == "out_of_subset" ? (oos += 1) : (still += 1); continue)
        r = _run_reproducer(repro)
        if r === :fixed
            _set_status!(g["_path"], "fixed")
            fixed += 1
            verbose && println("  ✓ fixed: $(get(g, "id", "?")) — $(get(g, "construct", ""))")
        elseif r === :out_of_subset
            st == "out_of_subset" || _set_status!(g["_path"], "out_of_subset")
            oos += 1
            verbose && st != "out_of_subset" &&
                println("  ⊘ out-of-subset (loud strict reject): $(get(g, "id", "?")) — $(get(g, "construct", ""))")
        else
            # genuine open bug — if it was previously out_of_subset, reopen it
            st == "open" || _set_status!(g["_path"], "open")
            still += 1
        end
    end
    regenerate_index!()
    verbose && println("verify_gaps!: $fixed newly fixed, $oos out-of-subset, $still still open")
    return (fixed = fixed, out_of_subset = oos, still_open = still)
end

# Run a reproducer snippet in a fresh module. Returns true if it runs WITHOUT
# throwing (⇒ gap fixed), false if it throws (⇒ gap still present).
#
# CAVEAT (P2-batch22, gap 8a25857213ba post-mortem): evaluating into an
# anonymous module is NOT identical to the discovery context (sweep shards
# define programs in Main). Compile paths that branch on the defining module
# (e.g. auto-discovery's Main skip-list) can make a reproducer pass here while
# the same code traps in a script — which looked like flaky auto-closes. If a
# sweep re-finds a gap that verify keeps closing, suspect module sensitivity
# and re-probe the construct in a standalone `julia` script before trusting
# either verdict.
#
# A bare `Module()` has `Base` but NOT `include` (that's only injected for
# file/`module`-loaded modules), so we pre-load the harness ourselves via an
# ABSOLUTE path (pwd-independent) and neutralize any `include(...)` line the
# reproducer carries — making both old and new reproducers runnable regardless
# of where verify is invoked from.
const _PRELOAD = [joinpath(@__DIR__, f) for f in
                  ("harness.jl", "bridge.jl", "bridge_args.jl", "structpool.jl")]
function _run_reproducer(snippet::AbstractString)
    m = Module(gensym(:gap))
    try
        Core.eval(m, :(using WasmTarget))
        # Stdlibs the fuzz catalogue compiles against (Statistics/Dates/Random): a
        # stdlib reproducer (e.g. `median(...)`) references these, so WITHOUT importing
        # them the snippet can't resolve the function and the gap can NEVER auto-close —
        # a false-OPEN regardless of compiler progress (the code may compile fine). Load
        # them here so verify reflects reality. try-guarded so a missing stdlib (e.g. when
        # run from a leaner env) never aborts the whole reproducer.
        try; Core.eval(m, :(using Statistics, Dates, Random)); catch; end
        for f in _PRELOAD                              # full bridge stack — the universal
            Base.include(m, f)                         # reproducers depend on all of it
        end
        Core.eval(m, :(using .FuzzHarness))
        Core.eval(m, :(using .FuzzBridge))
        Core.eval(m, :(using .FuzzBridgeArgs))
        Core.eval(m, :(using .FuzzStructPool))
        Core.eval(m, :(FuzzStructPool.build_pool!()))  # idempotent; pool types appear in bodies
        Core.eval(m, :(include(args...) = nothing))    # neutralize reproducer's own includes
        ex = Meta.parseall(snippet)
        # P2-batch5: a reproducer that doesn't even PARSE can never auto-close —
        # it fails verify forever regardless of compiler progress. Surface it
        # loudly instead of silently counting it "still open".
        if ex isa Expr && any(a -> a isa Expr && a.head === :error, ex.args)
            @warn "gap reproducer has a SYNTAX ERROR (will never auto-close) — repair the snippet" snippet=first(snippet, 120)
            return :open
        end
        Core.eval(m, ex)
        return :fixed
    catch e
        # Strict-mode reclassification: if the reproducer fails because WT now LOUDLY
        # rejects the construct (a `WasmCompileError` — surfaced directly, or wrapped by
        # the bridge as `(:compile_error => WasmCompileError(...))`), the gap is
        # OUT-OF-SUBSET — a sound rejection, not an open bug. A trap/mismatch/validation
        # failure (no WasmCompileError) stays `:open`.
        return occursin("WasmCompileError", sprint(showerror, e)) ? :out_of_subset : :open
    end
end

# --- Index -----------------------------------------------------------------

"""
    regenerate_index!() -> String

Rewrite failures/INDEX.md, the dashboard a follow-up loop reads to pick the next
open gap. Returns the index path.
"""
function regenerate_index!()
    isdir(LEDGER_DIR) || mkpath(LEDGER_DIR)
    gaps = load_gaps()
    opn = filter(g -> get(g, "status", "open") == "open", gaps)
    fxd = filter(g -> get(g, "status", "open") == "fixed", gaps)
    oos = filter(g -> get(g, "status", "open") == "out_of_subset", gaps)

    bycat = Dict{String,Int}()
    for g in opn
        c = get(g, "category", "?")
        bycat[c] = get(bycat, c, 0) + 1
    end

    io = IOBuffer()
    println(io, "# WasmTarget Failure Ledger\n")
    println(io, "Auto-generated by `Ledger.regenerate_index!()`. Each gap is a committed,")
    println(io, "self-reproducing failure. A follow-up loop fixes the compiler, runs")
    println(io, "`verify_gaps!()`, and fixed gaps auto-close.\n")
    println(io, "**Open: $(length(opn)) &nbsp;•&nbsp; Fixed: $(length(fxd)) &nbsp;•&nbsp; Out-of-subset: $(length(oos)) &nbsp;•&nbsp; Total: $(length(gaps))**\n")
    if !isempty(oos)
        println(io, "_Out-of-subset = WT now **loudly rejects** the construct (a sound `WasmCompileError`, not a silent trap/wrong value). These are NOT open bugs — they're outside the supported subset; rewrite the source to be type-stable. See `STRICT_MODE_INVENTORY.md`._\n")
    end
    if !isempty(bycat)
        println(io, "Open by category: ", join(["`$k`: $v" for (k, v) in sort(collect(bycat))], " · "), "\n")
    end
    println(io, "## Open gaps\n")
    if isempty(opn)
        println(io, "_None — all known gaps fixed._\n")
    else
        println(io, "| id | category | construct | location |")
        println(io, "|----|----------|-----------|----------|")
        for g in opn
            println(io, "| [`$(get(g,"id","?"))`]($(get(g,"id","?")).md) | $(get(g,"category","?")) | $(get(g,"construct","")) | `$(get(g,"location",""))` |")
        end
        println(io)
    end
    if !isempty(fxd)
        println(io, "## Fixed gaps\n")
        for g in fxd
            println(io, "- [`$(get(g,"id","?"))`]($(get(g,"id","?")).md) — $(get(g,"construct",""))")
        end
    end
    path = joinpath(LEDGER_DIR, "INDEX.md")
    write(path, String(take!(io)))
    return path
end

end # module Ledger
