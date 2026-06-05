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

export Gap, gap_id, record_gap!, verify_gaps!, regenerate_index!, open_gaps, load_gaps

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
    still = 0
    for g in load_gaps()
        get(g, "status", "open") == "open" || continue
        repro = get(g, "reproducer", "")
        isempty(strip(repro)) && (still += 1; continue)
        ok = _run_reproducer(repro)
        if ok
            _set_status!(g["_path"], "fixed")
            fixed += 1
            verbose && println("  ✓ fixed: $(get(g, "id", "?")) — $(get(g, "construct", ""))")
        else
            still += 1
        end
    end
    regenerate_index!()
    verbose && println("verify_gaps!: $fixed newly fixed, $still still open")
    return (fixed, still)
end

# Run a reproducer snippet in a fresh module. Returns true if it runs WITHOUT
# throwing (⇒ gap fixed), false if it throws (⇒ gap still present).
#
# A bare `Module()` has `Base` but NOT `include` (that's only injected for
# file/`module`-loaded modules), so we pre-load the harness ourselves via an
# ABSOLUTE path (pwd-independent) and neutralize any `include(...)` line the
# reproducer carries — making both old and new reproducers runnable regardless
# of where verify is invoked from.
const _HARNESS_PATH = joinpath(@__DIR__, "harness.jl")
function _run_reproducer(snippet::AbstractString)
    m = Module(gensym(:gap))
    try
        Core.eval(m, :(using WasmTarget))
        Base.include(m, _HARNESS_PATH)                 # defines m.FuzzHarness
        Core.eval(m, :(using .FuzzHarness))            # brings in compile_and_run
        Core.eval(m, :(include(args...) = nothing))    # neutralize reproducer's own include
        Core.eval(m, Meta.parseall(snippet))
        return true
    catch
        return false
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
    println(io, "**Open: $(length(opn)) &nbsp;•&nbsp; Fixed: $(length(fxd)) &nbsp;•&nbsp; Total: $(length(gaps))**\n")
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
