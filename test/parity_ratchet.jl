# ============================================================================
# parity_ratchet.jl — the machine checks of dev/CHARTER.md, the definition of done: every
# lock and ratchet, and the per-clause status the run prints last.
#
# Makes "clean up as you go" MECHANICAL: every structural-disease metric from the
# 2026-07-01 census is counted here with a precise pattern and compared against the
# committed baseline (dev/parity_baseline.toml).
#
#   RATCHET metrics may only go DOWN.  count > baseline  ⇒  FAIL.
#   LOCKS pass only at 0.               count != 0       ⇒  FAIL (A3P9).
#   The baseline holds exactly the ratchets: a ratchet with no baseline line, or a
#   baseline key that names no ratchet                   ⇒  FAIL (A12P5).
#
# When a commit legitimately lowers a count, tighten the baseline IN THE SAME COMMIT:
#     WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl
# (update mode still FAILS on any increase — a ratchet never loosens; a ratchet at 0 becomes a
# lock by moving its definition from METRICS to LOCKS, and the baseline records ratchets only:
# update mode rewrites it with every ratchet's count, recording a new one and dropping a key
# that names none, a reviewable diff).
#
# Run standalone (seconds, exit 0/1):   julia --project=. test/parity_ratchet.jl
# Also included by runtests.jl as a @testset, on the shard its _wt_qa dealing gives it.
# ============================================================================
module ParityRatchet

# NO deps (not even stdlib TOML — the test env doesn't declare it; a `using TOML` here
# LoadError'd shard 0 inside Pkg.test). The baseline is a flat TOML-shaped file of
# `[section]` + `key = int` lines; the two 10-line helpers below read/write exactly that.

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SRC = joinpath(ROOT, "src")
const BASELINE_PATH = joinpath(ROOT, "dev", "parity_baseline.toml")


# Each file is read once per run: the locks read the tree as it is when the run starts, and ~200
# of them walking src/ line by line read every file ~40 times (the gate's budget, L194).
const _LINES = Dict{String,Vector{String}}()
_file_lines(path::AbstractString)::Vector{String} = get!(() -> readlines(path), _LINES, String(path))

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
        # omitted and its ratchet reported MISSING. A key before any `[section]` is kept
        # under "" so that run() reports it as naming no ratchet (A12P5).
        elseif (m = match(r"^(\w+)\s*=\s*(\d+)(?:\s+#.*)?$", s)) !== nothing
            local d = get!(out, section, Dict{String,Int}())
            # a key twice would keep its last line, so a second, larger line would loosen its
            # ratchet silently (TOML forbids it): refused, as the run refuses a STRAY key (A13P18)
            haskey(d, m.captures[1]) && error("$(path): [$(section)] $(m.captures[1]) appears twice; delete one line")
            d[m.captures[1]] = parse(Int, m.captures[2])
        end
    end
    return out
end

# the ratchets' values only: a lock's value is 0 by definition (A3P9), so none is recorded
function _write_baseline(path::String, metrics::Dict{String,Int})
    open(path, "w") do io
        println(io, "# dev/parity_baseline.toml — enforced by test/parity_ratchet.jl.")
        println(io, "# RATCHETS only: counts may only DECREASE. A lock passes only at 0 and is not recorded.")
        println(io, "# Tighten via: WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl")
        for (name, d) in (("metrics", metrics),)
            println(io, "\n[", name, "]")
            for k in sort!(collect(keys(d)))
                println(io, k, " = ", d[k])
            end
        end
    end
end


# ---- R30/R31 (Phase 12.I): parser-based, not regex-based ---------------------
# Both walk Meta.parseall's AST rather than grep patterns: a return-type
# annotation or a field's declared type can span lines, hide behind a `where`
# clause, or sit inside a macrocall — none of which a line-oriented regex sees
# reliably. Shared by R30 and R31 below.


# Prose files are read line-ending-agnostic: a Windows checkout may carry CRLF, and a check
# that silently parses nothing there is a check that silently passes or fails by platform.
_text(path::String)::String = replace(read(path, String), "\r\n" => "\n")
_lines(path::String)::Vector{String} = String.(split(chomp(_text(path)), '\n'))
# the smoke cases as the locks read them: the driver, test/smoke.jl, and its corpus, test/smoke_corpus.jl
_smoke_text()::String = _text(joinpath(ROOT, "test", "smoke.jl")) * "\n" * _text(joinpath(ROOT, "test", "smoke_corpus.jl"))

# ---- dev/CHARTER.md support --------------------------------------------------
const CHARTER_PATH = joinpath(ROOT, "dev", "CHARTER.md")


"""
    unconsumed_files_outside_src() -> Vector{String}

Tracked files outside `src/` that nothing consumes (dev/CHARTER.md C9): a file is consumed
when a tracked file that is not prose names it (a `.md` only by its full path; the plan,
the history and the changelog name files without consuming them), when a loader walks its
directory, or when it is a repository convention file or a directory's README.
"""
function unconsumed_files_outside_src()::Vector{String}
    convention = Set(["Project.toml", "LICENSE.md", "CHANGELOG.md", "AGENTS.md",
        ".gitignore", ".gitattributes", "release-please-config.json",
        ".release-please-manifest.json", "docs/Project.toml", "docs/input.css"])
    # directories a loader walks, each with the files that loader consumes: run_tlc.sh (the
    # models and their instances), the docs site's file routing, Pkg's [extensions], GitHub Actions,
    # and Pkg's loading of legacy/, WT1 as its own package (its module file, its [extensions]). Anything else in them is consumed by nothing.
    walked = ("dev/formal/" => r"\.(tla|cfg)$", "docs/src/" => r"", "ext/" => r"\.jl$", ".github/workflows/" => r"\.ya?ml$",
              "legacy/" => r"")
    not_consumers = Set(["dev/MARCH.md", "dev/HISTORY.md", "CHANGELOG.md"])
    files = String.(split(readchomp(Cmd(`git ls-files`; dir=ROOT)), '\n'))
    texts = Dict(f => _text(joinpath(ROOT, f)) for f in files
                 if !(f in not_consumers) && isfile(joinpath(ROOT, f)))
    bad = String[]
    for f in files
        startswith(f, "src/") && continue
        (f in convention || basename(f) == "README.md" ||
         any(((d, rx),) -> startswith(f, d) && occursin(rx, f), walked)) && continue
        needle = endswith(f, ".md") ? f : basename(f)
        any(((g, t),) -> g != f && !endswith(g, ".md") && occursin(needle, t), texts) || push!(bad, f)
    end
    return bad
end


"""
Why AGENTS.md is not current and lean — dev/CHARTER.md C0. It is the one agent-instructions
file (a CLAUDE.md beside it is a second, drifting copy); it holds only timeless rules and
pointers, so it is short, everything it names exists, and it carries no status vocabulary
(dates, phase names, "currently"/"as of"/"remaining" — status lives in dev/MARCH.md and in
this harness's output, where it is measured instead of remembered).
"""
# AGENTS.md's size (A33E6): its hand-written lines, the ledger block's two markers among them, at most
# AGENTS_HAND_CAP; the block at most one line per live requirement of dev/LEDGER.md; so the whole at
# most AGENTS_HAND_CAP plus one line per live requirement, a bound that grows with the ledger and still
# shows a stale or duplicated row
const AGENTS_HAND_CAP = 60
function agents_size_faults(lines::AbstractVector{<:AbstractString}, live::Int)::Vector{String}
    local out = String[]
    local b = findfirst(==(AGENTS_LEDGER_BEGIN), lines)
    local e = findfirst(==(AGENTS_LEDGER_END), lines)
    local block = (b === nothing || e === nothing || e < b) ? 0 : e - b - 1
    local hand = length(lines) - block
    hand <= AGENTS_HAND_CAP || push!(out, "AGENTS.md has $hand hand-written lines (cap $AGENTS_HAND_CAP)")
    block <= live || push!(out, "AGENTS.md's ledger block has $block lines for $live live requirements: one line each")
    length(lines) <= AGENTS_HAND_CAP + live ||
        push!(out, "AGENTS.md has $(length(lines)) lines, past $AGENTS_HAND_CAP plus one per live requirement ($live)")
    return out
end

# L128's negative test: planted files each answer as stated
function agents_size_negatives_missed()::Vector{String}
    local file(h, n) = vcat(fill("h", h), n < 0 ? String[] : vcat([AGENTS_LEDGER_BEGIN], ["- **D$i** r" for i in 1:n], [AGENTS_LEDGER_END]))
    local cases = [("the hand-written cap with one line per requirement", file(58, 5), 5, 0),
                   ("one hand-written line too many", file(59, 5), 5, 2),
                   ("a duplicated requirement line", file(50, 6), 5, 1),
                   ("no block, past the cap", file(61, -1), 5, 1),
                   ("the bound growing with the ledger", file(40, 30), 30, 0)]
    local out = String[]
    for (what, lines, live, want) in cases
        length(agents_size_faults(lines, live)) == want || push!(out, "negative missed: $what")
    end
    return out
end

function agents_md_violations()::Vector{String}
    v = String[]
    isfile(joinpath(ROOT, "CLAUDE.md")) && push!(v, "CLAUDE.md exists — AGENTS.md is the one instructions file")
    path = joinpath(ROOT, "AGENTS.md")
    isfile(path) || return push!(v, "AGENTS.md is missing")
    lines = _lines(path)
    local live = count(ledger_live, first(ledger_rows(isfile(LEDGER_PATH) ? _text(LEDGER_PATH) : "")))
    append!(v, agents_size_faults(lines, live))
    for (i, l) in enumerate(lines)
        length(l) <= 100 || push!(v, "AGENTS.md:$i is $(length(l)) chars (cap 100)")
        for m in eachmatch(r"\b20\d\d-\d\d\b|\bPhase \d+|\b(?:currently|as of|remaining|so far|recently|TODO|FIXME)\b"i, l)
            push!(v, "AGENTS.md:$i status vocabulary: \"$(m.match)\"")
        end
    end
    txt = _text(path)
    for m in eachmatch(r"(?<![\w/.])((?:src|test|dev|ext|docs|\.github)/[\w./*-]*[\w/])", txt)
        p = m.captures[1]
        occursin('*', p) && continue
        (isfile(joinpath(ROOT, p)) || isdir(joinpath(ROOT, p))) || push!(v, "AGENTS.md names $p, which does not exist")
    end
    ids = Set(_short_id(first(q)) for q in vcat(METRICS, LOCKS))
    for m in eachmatch(r"\b([LR]\d+[a-z]?)\b", txt)
        m.captures[1] in ids || push!(v, "AGENTS.md cites $(m.captures[1]), which is no check")
    end
    corpus = join((read(joinpath(d, f), String) for root in (SRC, joinpath(ROOT, "test"), joinpath(ROOT, "dev"))
                   for (d, _, fs) in walkdir(root) for f in fs if endswith(f, ".jl") || endswith(f, ".sh")), "\n")
    for m in eachmatch(r"\b(WT_[A-Z_]+)\b", txt)
        occursin(m.captures[1], corpus) || push!(v, "AGENTS.md names $(m.captures[1]), which nothing reads")
    end
    pm = match(r"\b([0-9a-f]{40})\b", _text(joinpath(ROOT, "dev", "PARITY_MASTER.md")))
    for m in eachmatch(r"\b([0-9a-f]{40})\b", txt)
        (pm !== nothing && m.captures[1] == pm.captures[1]) || push!(v, "AGENTS.md pins $(m.captures[1][1:8]), dev/PARITY_MASTER.md does not")
    end
    return v
end

"""The clauses of dev/CHARTER.md: clause id => (text, cited short check ids like "L110"/"R29a")."""
function charter_clauses()::Vector{Pair{String,Tuple{String,Vector{String}}}}
    out = Pair{String,Tuple{String,Vector{String}}}[]
    isfile(CHARTER_PATH) || return out
    txt = _text(CHARTER_PATH)
    sec = match(r"## The clauses\n(.*?)\n## "s, txt)
    sec === nothing && return out
    for m in eachmatch(r"^- \*\*(C\d+) ·(.*?)(?=^- \*\*C\d+ ·|\z)"ms, sec.captures[1])
        body = m.captures[2]
        push!(out, m.captures[1] => (body, [c.captures[1] for c in eachmatch(r"`([LR]\d+[a-z]?)`", body)]))
    end
    return out
end

_short_id(id::AbstractString) = (m = match(r"^([LR]\d+[a-z]?)_", id); m === nothing ? String(id) : String(m.captures[1]))


# ---- strict means by construction (dev/CHARTER.md C0, L201) --------------------------------------
# The clauses whose checks the standard classifies: the compiler's code and its models, and the
# charter's own clause, C0, which reads CLOSED only on constructions like the others (A29S2).
const STRICT_SCOPE = ("C0", "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8")
# The clauses whose every cited lock is classified (2026-10-21); C1 to C3 classify theirs before
# they close, since L201 reads an unclassified lock in a clause with no Planned text as a violation.
const STRICT_CLASSIFIED = ("C0", "C4", "C5", "C6", "C7", "C8")
# Every lock a classified clause cites, by what decides it, and for a construction the definition in
# src that is the construction. :construction: that definition makes the wrong choice inexpressible
# through WT's interfaces, and its assertion lives in src beside it, the load-time check the definition
# registers (`construction_check(::Val{<definition>})`); the lock is `ConstructionLock(:<definition>)`,
# which only calls that check, so no lock of a construction reads any text (L201 checks the lock's type
# and name in this table, by reflection). :behavior: a run decides
# it (the differential lanes, a test of an algorithm). :stopgap: the lock finds the wrong choice by
# reading WT's source, an allowlist or a count, so it can still be written and compiled, whatever
# definition holds the rule. A ratchet (an R check, a lock or not) is a stopgap by its kind and has no
# entry. Neither behavior nor a stopgap closes a clause.
const STRICT_KINDS = Dict{String,Tuple{Symbol,String}}(
    # C0: the charter holds. Each check reads text: the charter, this file, AGENTS.md, the plan, the
    # audit log or src (A29S2); none is a construction, so C0 reads OPEN with its Planned text
    "L125" => (:stopgap, ""), "L126" => (:stopgap, ""), "L128" => (:stopgap, ""), "L148" => (:stopgap, ""),
    "L154" => (:stopgap, ""), "L201" => (:stopgap, ""), "L202" => (:stopgap, ""), "L203" => (:stopgap, ""),
    # the ledger's (L204 to L207): each reads the ledger, the charter, the plan, AGENTS.md or this file
    "L204" => (:stopgap, ""), "L205" => (:stopgap, ""), "L206" => (:stopgap, ""), "L207" => (:stopgap, ""),
    # the rebuild's first constructions (dev/MARCH.md 1.A2c): the rejections a closed sum (C6), and
    # no open abstract type passing for a closed one (C5, A33S1); C4, C7 and C8's arrive with theirs
    "L218" => (:construction, "Rejection"), "L219" => (:construction, "check_no_open_abstract"),
)


# Each :construction's precedent, the mechanism another language holds it by (`<ecosystem>: <mechanism>[,
# <anchor>]`: Rust's sealed enums and exhaustive match, dart's sealed classes and switches, wasm's
# types), and how Julia's differs; L201 refuses a construction without both, and a precedent for any
# other entry. A construction with no precedent anywhere is an invention and waits for Dale.
const STRICT_PRECEDENTS = Dict{String,Tuple{String,String}}(
    "L218" => ("rust: enum + exhaustive match; dart: sealed class + exhaustive switch",
               "a Union of concrete structs that subtype nothing, its every kind handled and nothing else, checked when the package loads, since Julia checks no match at compile time"),
    "L219" => ("dart: sealed class against abstract class; rust: enum against trait",
               "Julia's abstract types are open by language, so an abstract type that is neither a registered construction nor a dart abstract class's mirror refuses the package's load"),
)

# whether a precedent reads `<ecosystem>: <mechanism>`, the ecosystem lowercase
strict_precedent_ok(p::AbstractString)::Bool = occursin(r"^[a-z][a-z0-9+_-]*: \S", p)

# a :construction's lock: it holds the definition's name and only calls the check src registers beside
# that definition, construction_check(::Val{<definition>}) (the construction's macro defines it there;
# loading WasmTarget is the price of the first construction). A missing check is a MethodError, loud.
# precedent(rust: `const _: () = assert!(..)` and `#[derive]` checks live with the item; dart: the
# analyzer checks a sealed class's switches where it is declared)
struct ConstructionLock
    definition::Symbol
end
function (c::ConstructionLock)()::Int
    local wt = Base.require(Base.PkgId(Base.UUID("9f3a1415-1112-405b-ae89-c61daf9872bd"), "WasmTarget"))
    local n = Base.invokelatest(getfield(wt, :construction_check), Val(c.definition))
    local missed = construction_negatives_missed(wt, c.definition)
    foreach(x -> println("    ✗ ", x), missed)
    return n + length(missed)
end

# a construction's always-run negative (L207): plants its src check must refuse, each run through
# that check, and the definitions it must pass; a construction with no plants here is a fault
function construction_negatives_missed(wt::Module, definition::Symbol)::Vector{String}
    local out = String[]
    local V = getfield(wt, :ConstructionViolation)
    local refuses(f) = try; Base.invokelatest(f); false; catch e; e isa V; end
    local passes(f) = try; Base.invokelatest(f) == 0; catch; false; end
    if definition === :Rejection
        local closed = getfield(wt, :check_closed_sum)
        local m = Module(:RejectionPlant)
        Core.eval(m, quote
            struct A; end; struct B; end; abstract type Open end; struct C <: Open; end
            h(::A) = 1; h(::B) = 2
            g(::A) = 1; g(::B) = 2; g(::Int) = 3
            k(::A) = 1; k(::C) = 2
            only_a(::A) = 1
        end)
        passes(() -> closed(Union{m.A, m.B}, m.h)) || push!(out, "negative missed: a closed sum with every kind handled fails its check")
        refuses(() -> closed(Union{m.A, m.B}, m.only_a)) || push!(out, "negative missed: a kind with no handler passes")
        refuses(() -> closed(Union{m.A, m.B}, m.g)) || push!(out, "negative missed: a handler for a type outside the sum passes")
        refuses(() -> closed(Union{m.A, m.C}, m.k)) || push!(out, "negative missed: a kind subtyping an open abstract type passes")
        refuses(() -> closed(m.A, m.h)) || push!(out, "negative missed: a sum that is no Union passes")
    elseif definition === :check_no_open_abstract
        local noopen = getfield(wt, :check_no_open_abstract)
        local bad = Module(:OpenPlant); Core.eval(bad, :(abstract type Bad end))
        local good = Module(:MirrorPlant)
        Core.eval(good, :(Core.@doc "parity(ir/types.dart:12 ValueType) the dart class" abstract type Good end))
        local sub = Module(:SubPlant); Core.eval(sub, Expr(:toplevel, :(module Sub; abstract type Hidden end; end)))
        refuses(() -> noopen(bad)) || push!(out, "negative missed: an open abstract type passes")
        passes(() -> noopen(good)) || push!(out, "negative missed: a dart abstract class's mirror with its parity anchor fails")
        refuses(() -> noopen(sub)) || push!(out, "negative missed: an open abstract type in a submodule passes")
        local par = Module(:ParamPlant); Core.eval(par, :(abstract type Open{T} end))
        refuses(() -> noopen(par)) || push!(out, "negative missed: a parametric open abstract type (a UnionAll binding) passes")
    else
        push!(out, "the construction $definition has no plants in construction_negatives_missed")
    end
    return out
end

# the thunk of lock `id` in LOCKS, or nothing
function strict_lock_thunk(id::AbstractString)
    for (k, (_, f)) in LOCKS
        _short_id(k) == id && return f
    end
    return nothing
end

# what a check is under the standard: a ratchet is a stopgap; a lock is what STRICT_KINDS says, or
# :unclassified
_strict_kind(id::AbstractString, kinds::Dict{String,Tuple{Symbol,String}})::Symbol =
    startswith(id, "R") ? :stopgap : haskey(kinds, id) ? first(kinds[id]) : :unclassified

# each check that a clause of STRICT_SCOPE with no Planned text (one the charter block reads CLOSED)
# cites and that is not a construction, as "<clause> cites <check> (<kind>)"
# why a clause is OPEN (none: CLOSED), given the ratchets' and the locks' counts by full id: a check it
# cites that is missing, a ratchet (at 0 too, until it is a lock), a broken lock, a stopgap or behavior
# check of a clause the standard classifies, its Planned text, and no check at all: a clause citing
# nothing is never CLOSED, since "every check it cites holds" holds of none (A32S2)
function clause_open_reasons(cid::AbstractString, body::AbstractString, ids::AbstractVector{<:AbstractString},
                             current_m::AbstractDict{String,Int}, current_l::AbstractDict{String,Int})::Vector{String}
    local byshort = Dict(_short_id(k) => k for k in vcat(collect(keys(current_m)), collect(keys(current_l))))
    local open_ = String[]
    isempty(ids) && push!(open_, "no check")
    for i in ids
        local k = get(byshort, i, nothing)
        k === nothing && (push!(open_, "$i?"); continue)
        haskey(current_m, k) && push!(open_, current_m[k] > 0 ? "$i=$(current_m[k])" : "$i (at 0, not yet a lock)")
        haskey(current_l, k) && current_l[k] != 0 && push!(open_, "$i BROKEN")
    end
    if cid in STRICT_SCOPE
        for i in ids
            local sk = startswith(i, "L") ? _strict_kind(i, STRICT_KINDS) : :construction
            (sk === :stopgap || sk === :behavior) && push!(open_, "$i $sk")
        end
    end
    occursin("Planned:", body) && push!(open_, "planned check")
    return open_
end

function strict_violations(clauses, kinds::Dict{String,Tuple{Symbol,String}})::Vector{String}
    out = String[]
    for (cid, (body, ids)) in clauses
        (cid in STRICT_SCOPE && !occursin("Planned:", body)) || continue
        isempty(ids) && push!(out, "$cid cites no check and has no Planned text: CLOSED on nothing")
        for i in ids
            local k = _strict_kind(i, kinds)
            k === :construction || push!(out, "$cid cites $i ($k)")
        end
    end
    return out
end

# the table's own faults: a lock a classified clause cites with no entry, an entry no classified
# clause cites, an entry for a ratchet, a kind other than the three, a construction whose lock is not
# ConstructionLock of the definition it names, and a stopgap or behavior naming one (a name is a
# construction's alone)
function strict_table_faults(clauses, kinds::Dict{String,Tuple{Symbol,String}};
                             lock::Function=strict_lock_thunk,
                             precedents::Dict{String,Tuple{String,String}}=STRICT_PRECEDENTS)::Vector{String}
    out = String[]
    local cited = Set{String}()
    for (cid, (_, ids)) in clauses
        cid in STRICT_CLASSIFIED || continue
        for i in ids
            push!(cited, i)
            startswith(i, "L") && !haskey(kinds, i) && push!(out, "$cid cites $i, which STRICT_KINDS does not classify")
        end
    end
    for (k, (v, name)) in kinds
        k in cited || push!(out, "STRICT_KINDS classifies $k, which no clause of $(join(STRICT_CLASSIFIED, ' ')) cites")
        startswith(k, "R") && push!(out, "STRICT_KINDS classifies the ratchet $k, a stopgap by its kind")
        v in (:construction, :behavior, :stopgap) || push!(out, "STRICT_KINDS gives $k the kind $v")
        if v === :construction
            local f = lock(k)
            (f isa ConstructionLock && !isempty(name) && f.definition === Symbol(name)) ||
                push!(out, "$k is a construction whose lock is not ConstructionLock(:$name): a construction's lock only calls its definition's check")
        end
        if v === :construction
            local pr = get(precedents, k, ("", ""))
            strict_precedent_ok(pr[1]) || push!(out, "$k is a construction with no precedent `<ecosystem>: <mechanism>`")
            isempty(strip(pr[2])) && push!(out, "$k is a construction that does not say how Julia's differs from its precedent")
        end
        v !== :construction && !isempty(name) && push!(out, "$k is $v and names `$name`: only a construction names one")
    end
    for k in keys(precedents)
        (haskey(kinds, k) && first(kinds[k]) === :construction) ||
            push!(out, "STRICT_PRECEDENTS gives $k a precedent, but it is no construction")
    end
    return out
end

# L201's negative test, run with it: planted clauses each verdict must answer as stated, and a
# planted table whose eight faults it must find
function strict_negatives_missed()::Vector{String}
    local k = Dict{String,Tuple{Symbol,String}}("L1" => (:construction, "_emit!"), "L2" => (:stopgap, ""),
                                                "L3" => (:behavior, ""))
    plant(cid, body, ids) = Pair{String,Tuple{String,Vector{String}}}[cid => (body, String[ids...])]
    local cases = [
        ("a stopgap lock in a clause with no Planned text", plant("C4", " T. Checks: ", ["L1", "L2"]), 1),
        ("a behavior check in a clause with no Planned text", plant("C8", " T. Checks: ", ["L1", "L3"]), 1),
        ("a ratchet in a clause with no Planned text", plant("C7", " T. Checks: ", ["L1", "R9"]), 1),
        ("an unclassified lock in a clause with no Planned text", plant("C1", " T. Checks: ", ["L4"]), 1),
        ("a stopgap in a clause with Planned text", plant("C5", " T. Checks: Planned: 13.1", ["L2", "R9"]), 0),
        ("constructions alone", plant("C6", " T. Checks: ", ["L1"]), 0),
        ("a clause outside the scope", plant("C9", " T. Checks: ", ["L2", "R9"]), 0),
        ("a clause with no Planned text that cites nothing", plant("C4", " T. Checks: ", String[]), 1),
    ]
    local out = String[]
    for (what, cl, want) in cases
        length(strict_violations(cl, k)) == want || push!(out, "negative missed: $what")
    end
    # L5 unclassified; L6, R2, L1x, L7 and L8 uncited; R2 a ratchet; L1x a kind other than the three;
    # L7 a construction whose lock is a function that may read anything; L8 a stopgap that names one.
    # L1's lock is ConstructionLock(:_emit!).
    local planted_lock(id) = id == "L1" ? ConstructionLock(:_emit!) : () -> 0
    # precedents: L1's is whole; L7 has none (two faults: no precedent, no Julia difference); L6, a
    # stopgap, is given one (a fault)
    local planted_precedents = Dict{String,Tuple{String,String}}(
        "L1" => ("rust: sealed enum + exhaustive match", "Julia checks the match when the package loads"),
        "L6" => ("rust: enum", "none"))
    local tf = strict_table_faults(plant("C4", " T.", ["L1", "L5"]),
                                   Dict{String,Tuple{Symbol,String}}("L1" => (:construction, "_emit!"),
                                        "L6" => (:stopgap, ""), "R2" => (:stopgap, ""), "L1x" => (:strict, ""),
                                        "L7" => (:construction, "no_definition_has_this_name!"),
                                        "L8" => (:stopgap, "_emit!")); lock=planted_lock,
                                   precedents=planted_precedents)
    length(tf) == 13 || push!(out, "negative missed: the table's faults ($(length(tf)) of 13)")
    (strict_precedent_ok("dart: sealed class + switch, constants.dart:30") && !strict_precedent_ok("Rust enum") &&
     !strict_precedent_ok("")) || push!(out, "negative missed: a precedent's form")
    # a construction's lock naming another definition is refused too
    local other = strict_table_faults(plant("C4", " T.", ["L1"]), Dict{String,Tuple{Symbol,String}}("L1" => (:construction, "WasmValType"));
                                      lock=planted_lock, precedents=Dict("L1" => ("rust: newtype", "a struct")))
    length(other) == 1 || push!(out, "negative missed: a ConstructionLock naming another definition")
    # the verdict: a clause whose Planned text is dropped and that cites no check stays OPEN; one citing
    # a passing lock closes; one citing a broken lock or a ratchet stays OPEN (A32S2)
    local m0 = Dict{String,Int}("R9_x" => 0)
    local l0 = Dict{String,Int}("L1_x" => 0, "L2_x" => 1)
    local dropped = replace(" T. Checks: none yet. Planned: 1.S.", "Planned:" => "")
    (!isempty(clause_open_reasons("C9", dropped, String[], m0, l0)) &&
     isempty(clause_open_reasons("C9", " T. Checks: ", ["L1"], m0, l0)) &&
     !isempty(clause_open_reasons("C9", " T. Checks: ", ["L2"], m0, l0)) &&
     !isempty(clause_open_reasons("C9", " T. Checks: ", ["R9"], m0, l0))) ||
        push!(out, "negative missed: the clause verdict (a clause citing nothing reads CLOSED)")
    return out
end

# ---- L202: every closed sum or construction in src carries its precedent (dev/CHARTER.md C0) -----
const PRECEDENT_RX = r"precedent\([a-z][a-z0-9+_-]*: [^()]+\)"

# the text that documents the definition at line `i`: the line itself, a docstring directly above it,
# and the contiguous comment lines above that
function precedent_block(lines::AbstractVector{<:AbstractString}, i::Int)::String
    local block = String[lines[i]]
    local j = i - 1
    if j >= 1 && endswith(rstrip(lines[j]), "\"\"\"")
        local k = strip(lines[j]) == "\"\"\"" ? j - 1 : j
        while k >= 1 && !startswith(lstrip(lines[k]), "\"\"\"")
            k -= 1
        end
        k >= 1 || return join(block, '\n')
        append!(block, lines[k:j])
        j = k - 1
    end
    while j >= 1 && startswith(lstrip(lines[j]), "#")
        push!(block, lines[j])
        j -= 1
    end
    return join(block, '\n')
end

# the definitions in one file L202 asks a precedent of, as "<file>:<line> <name>" with no precedent:
# every closed sum (an @enum, a `@closed` sum) and every definition a construction names; an abstract
# type is an open hierarchy, neither, and carries its parity(...) alone
function precedent_missing(path::AbstractString, lines::AbstractVector{<:AbstractString},
                           names::AbstractVector{<:AbstractString})::Vector{String}
    local out = String[]
    local named = [Regex("^\\s*(?:@inline\\s+)*(?:function|macro|struct|mutable struct|const)\\s+\\Q" * n * "\\E(?![\\w!])") for n in names]
    for (i, l) in enumerate(lines)
        local m = match(r"^\s*(?:@enum\s+(\w+)|@closed\s+(?:abstract type\s+|(?:mutable\s+)?struct\s+|const\s+)?(\w+))", l)
        local name = m === nothing ? nothing : something(m[1], m[2])
        if name === nothing
            local hit = findfirst(rx -> occursin(rx, l), named)
            hit === nothing || (name = names[hit])
        end
        name === nothing && continue
        occursin(PRECEDENT_RX, precedent_block(lines, i)) || push!(out, "$path:$i $name")
    end
    return out
end

# every closed sum or construction in src without its precedent
function precedent_missing_in_src()::Vector{String}
    local names = String[d for (k, (v, d)) in STRICT_KINDS if v === :construction]
    local out = String[]
    for (dir, _, files) in walkdir(SRC), f in files
        endswith(f, ".jl") || continue
        local path = joinpath(dir, f)
        append!(out, precedent_missing(relpath(path, ROOT), split(_text(path), '\n'), names))
    end
    return out
end

# L202's negative test: planted definitions each answer as stated
function precedent_negatives_missed()::Vector{String}
    local cases = [
        ("an @enum with its precedent in its docstring", "\"\"\"\n    K\n\nprecedent(rust: enum)\n\"\"\"\n@enum K A B", 0),
        ("an @enum without one", "\"\"\"\n    K\n\nparity(quarantine: x)\n\"\"\"\n@enum K A B", 1),
        ("a @closed sum with a trailing precedent", "@closed abstract type T end  # precedent(dart: sealed class, misc.dart:57)", 0),
        ("a @closed sum without one", "@closed abstract type T end", 1),
        ("an open abstract type, asked nothing", "abstract type T end", 0),
        ("a named construction with its precedent in a comment above", "# precedent(rust: typestate builder)\nfunction mk!(x)", 0),
        ("a named construction without one", "function mk!(x)", 1),
        ("a precedent with no ecosystem", "@enum K A B  # precedent(sealed classes)", 1),
    ]
    local out = String[]
    for (what, text, want) in cases
        length(precedent_missing("t.jl", split(text, '\n'), ["mk!"])) == want || push!(out, "negative missed: $what")
    end
    return out
end

# ---- L203: an audit entry over src asks "stopgap in disguise" and "precedent" (dev/CHARTER.md C0) -
# the first dev/AUDIT.md entry the rule binds (the entries before it predate it)
const L203_FIRST_ENTRY = 30

# the entries from L203_FIRST_ENTRY on whose range changes src and that lack either line, by number
function audit_lines_missing(entries::AbstractVector{<:AbstractString}; touches_src::Function)::Vector{String}
    local out = String[]
    for (n, e) in enumerate(entries)
        n >= L203_FIRST_ENTRY || continue
        local r = match(r"\(([0-9a-f]{7,40})(?:~1)?\.\.([0-9a-f]{7,40})", e)
        r === nothing && (push!(out, "entry $n names no range"); continue)
        touches_src(r.captures[1], r.captures[2]) || continue
        occursin(r"(?m)^\s*(?:- )?stopgap in disguise:", e) || push!(out, "entry $n has no `stopgap in disguise:` line")
        occursin(r"(?m)^\s*(?:- )?precedent:", e) || push!(out, "entry $n has no `precedent:` line")
    end
    return out
end

# whether git's range a..b changes src or ext (no git history fails, never skips: true)
function audit_range_touches_src(a::AbstractString, b::AbstractString)::Bool
    local cmd = `git -C $ROOT log --format=%H $a..$b -- src ext`
    local o = try
        readchomp(cmd)
    catch
        return true
    end
    return !isempty(o)
end

# L203's negative test: planted entries each answer as stated
function audit_lines_negatives_missed()::Vector{String}
    local pad = fill("## entry (aaaaaaa..bbbbbbb)", L203_FIRST_ENTRY - 1)
    local good = "## e (aaaaaaa..bbbbbbb)\n- stopgap in disguise: none\n- precedent: rust: enum"
    local cases = [
        ("an entry over src with both lines", vcat(pad, good), true, 0),
        ("an entry over src missing both", vcat(pad, "## e (aaaaaaa..bbbbbbb)\nResolution: x"), true, 2),
        ("an entry over src missing the precedent line", vcat(pad, "## e (aaaaaaa..bbbbbbb)\nstopgap in disguise: none"), true, 1),
        ("an entry that changes no src", vcat(pad, "## e (aaaaaaa..bbbbbbb)"), false, 0),
        ("an entry before the rule", vcat(pad[1:end-1], "## e (aaaaaaa..bbbbbbb)"), true, 0),
    ]
    local out = String[]
    for (what, entries, src, want) in cases
        length(audit_lines_missing(entries; touches_src=(a, b) -> src)) == want || push!(out, "negative missed: $what")
    end
    return out
end

# ---- L154's findings: an open finding sits on its row (dev/CHARTER.md C0, A32E3) ---------------------
# the findings an audit entry's Resolution leaves open, each with the row it names: in each sentence or
# `;` clause naming `on <row>` (a MARCH row 1.<x> or a ledger row D<n>), every finding ID it holds
function open_findings(entry::AbstractString)::Vector{Tuple{String,String}}
    local out = Tuple{String,String}[]
    local i = findfirst("Resolution:", entry)
    i === nothing && return out
    for seg in split(entry[first(i):end], r"(?<=[;.])\s+")
        local r = match(r"\bon (?:MARCH )?(1\.[A-Za-z0-9]+|D\d+)\b", seg)
        r === nothing && continue
        for f in eachmatch(r"\b(A\d+[A-Z]\d+)\b", seg)
            push!(out, (String(f[1]), String(r[1])))
        end
    end
    return out
end

# the faults: a finding not on the row its entry names, unless a later commit's `Fixes:` line names it,
# and a row named that does not exist
function findings_off_row(pairs::Vector{Tuple{String,String}}, rows::AbstractDict{String,String},
                          fixed::AbstractSet{String})::Vector{String}
    local out = String[]
    for (f, r) in pairs
        # a finding a commit fixes is closed, its row free to leave with it
        f in fixed && continue
        haskey(rows, r) || (push!(out, "$f is left open on $r, which is no row"); continue)
        occursin(Regex("\\b" * f * "\\b"), rows[r]) ||
            push!(out, "$f is left open on $r, which does not hold it, and no commit's Fixes: line names it")
    end
    return out
end

# the findings the latest dev/AUDIT.md entry leaves open, off their rows: the rows of dev/MARCH.md and
# dev/LEDGER.md, the fixes the `Fixes:` lines of the commits after the entry's own (no history: a fault)
function findings_off_row_here()::Vector{String}
    local audit = joinpath(ROOT, "dev", "AUDIT.md")
    isfile(audit) || return String[]
    local entries = split(_text(audit), r"\n(?=## )")
    length(entries) < 2 && return String[]
    local rows = Dict{String,String}()
    for f in ("MARCH.md", "LEDGER.md"), l in split(_text(joinpath(ROOT, "dev", f)), '\n')
        local m = match(r"^\| (1\.[A-Za-z0-9]+|D\d+) \|", l)
        m === nothing || (rows[String(m[1])] = String(l))
    end
    local fixed = Set{String}()
    try
        local c = readchomp(`git -C $ROOT log -1 --format=%H -- dev/AUDIT.md`)
        for l in split(readchomp(`git -C $ROOT log $c..HEAD --format=%B`), '\n')
            startswith(l, "Fixes:") && union!(fixed, String[x.match for x in eachmatch(r"\bA\d+[A-Z]\d+\b", l)])
        end
    catch
        return ["no git history: the findings' fixes cannot be read"]
    end
    return findings_off_row(open_findings(last(entries)), rows, fixed)
end

# L154's negative test: planted entries, rows and fixes each answer as stated
function findings_negatives_missed()::Vector{String}
    local entry = "## e (a..b)\nA1B1 x.\n\nResolution: this entry and A9Z9's fix land as one. A1B1 and A1B2 are open on MARCH 1.S; A1B3 on 1.L, with A0B4; A1B5 on D3."
    local rows = Dict("1.S" => "| 1.S | C0 | A1B1 A1B2 |", "1.L" => "| 1.L | C10 | A1B3 A0B4 |", "D3" => "| D3 | A1B5 |")
    local cases = [("every finding on its row", rows, Set{String}(), 0),
                   ("a finding off its row", merge(rows, Dict("1.S" => "| 1.S | C0 | A1B1 |")), Set{String}(), 1),
                   ("a finding off its row that a commit fixes", merge(rows, Dict("1.S" => "| 1.S | C0 | A1B1 |")), Set(["A1B2"]), 0),
                   ("a row that does not exist", Dict(k => v for (k, v) in rows if k != "D3"), Set{String}(), 1),
                   ("a fixed finding whose row left with it", Dict(k => v for (k, v) in rows if k != "D3"), Set(["A1B5"]), 0)]
    local out = String[]
    length(open_findings(entry)) == 5 || push!(out, "negative missed: the open findings read ($(length(open_findings(entry))) of 5)")
    for (what, r, fx, want) in cases
        length(findings_off_row(open_findings(entry), r, fx)) == want || push!(out, "negative missed: $what")
    end
    return out
end

# ---- the requirements ledger (L204 L205 L206): Dale's requirements, dev/LEDGER.md's rows, each tied
# to the checks that enforce it (dev/CHARTER.md C0) ---------------------------------------------------
const LEDGER_PATH = joinpath(ROOT, "dev", "LEDGER.md")
const LedgerRow = NamedTuple{(:id, :n, :words, :date, :why, :by, :band, :rule),
                             Tuple{String,Int,String,String,String,String,String,String}}

# the ledger's rows in order, and the table lines that do not split into its seven cells
function ledger_rows(text::AbstractString)::Tuple{Vector{LedgerRow},Vector{String}}
    local rows = LedgerRow[]
    local faults = String[]
    for l in split(text, '\n')
        local m = match(r"^\| (D(\d+)) \| (.*) \|\s*$", l)
        m === nothing && continue
        local c = split(m[3], " | ")
        length(c) == 6 || (push!(faults, "$(m[1]) has $(length(c) + 1) cells, not 7 (no cell holds ` | `)"); continue)
        push!(rows, LedgerRow((String(m[1]), parse(Int, m[2]), String(c[1]), String(c[2]), String(c[3]),
                               String(c[4]), String(c[5]), String(c[6]))))
    end
    return rows, faults
end

ledger_live(r::LedgerRow)::Bool = !occursin(r"superseded: D\d+", r.by)

# a number with its unit (seconds, minutes, lines, chars, a percentage, commits, landings, jobs,
# times): a budget, a target, a cap or a limit, which states its intent and band (L205)
const QUANT_RX = r"(?<![\w.])(?:[1-9]\d*(?:\.\d+)?|0\.\d+)(?:\s|-)?(?:s|seconds?|minutes?|min|ms|lines?|chars?|%|commits?|landings?|jobs?|times)(?!\w)"
has_intent_and_band(s::AbstractString)::Bool = occursin(r"\bintent: \S", s) && occursin(r"\bband: \S", s)

# the ledger's faults, given this file's checks (short ids), the charter's clauses (id => the checks
# each cites), whether a path exists, and dev/MARCH.md's row numbers
function ledger_faults(rows::Vector{LedgerRow}, checks::AbstractSet{String}, clauses::AbstractDict{String,Vector{String}},
                       path_ok::Function, march::AbstractSet{String})::Vector{String}
    local out = String[]
    isempty(rows) && return push!(out, "dev/LEDGER.md holds no row")
    local live = Set(r.id for r in rows if ledger_live(r))
    local served = Set{String}()
    for (i, r) in enumerate(rows)
        r.n == i || push!(out, "row $i is $(r.id): the IDs run D1, D2, … in order, none deleted or renumbered")
        occursin(r"[\"“]", r.words) || push!(out, "$(r.id): Dale's words are not quoted")
        occursin(r"^20\d\d-\d\d-\d\d(?:, 20\d\d-\d\d-\d\d)*$", r.date) || push!(out, "$(r.id): its date `$(r.date)` is not YYYY-MM-DD[, …]")
        strip(r.why) in ("", "—") && push!(out, "$(r.id) says no why")
        local n = 0
        for t in eachmatch(r"`([^`]+)`", r.by)
            local k = String(t[1])
            (startswith(k, "planned: ") || startswith(k, "superseded: ")) && continue
            n += 1
            if occursin(r"^[LR]\d+[a-z]?$", k)
                k in checks ? (r.id in live && push!(served, k)) :
                    push!(out, "$(r.id) cites $k, which is no check of test/parity_ratchet.jl")
            elseif occursin(r"^C\d+$", k)
                haskey(clauses, k) ? (r.id in live && union!(served, clauses[k])) :
                    push!(out, "$(r.id) cites $k, which is no clause of dev/CHARTER.md")
            elseif occursin('/', k) && !endswith(k, ".md")
                path_ok(k) || push!(out, "$(r.id) cites $k, which does not exist")
            else
                push!(out, "$(r.id) cites `$k`, neither a check, a clause nor a test, hook, script or workflow")
            end
        end
        for p in eachmatch(r"planned: (\d+\.[0-9A-Za-z]+)", r.by)
            n += 1
            String(p[1]) in march || push!(out, "$(r.id) is planned on dev/MARCH.md $(p[1]), which is no row")
        end
        for s in eachmatch(r"superseded: (D\d+)", r.by)
            n += 1
            (String(s[1]) in live && s[1] != r.id) || push!(out, "$(r.id) is superseded by $(s[1]), which is no live row")
        end
        n == 0 && push!(out, "$(r.id) names no check, no `planned: <MARCH row>` and no `superseded: D<n>`")
        if r.id in live
            strip(r.rule) in ("", "—") && push!(out, "$(r.id) is live and has no rule for agents")
            occursin(QUANT_RX, r.words * " " * r.rule) && !has_intent_and_band(r.band) &&
                push!(out, "$(r.id) states a number without its intent and band")
        else
            strip(r.rule) == "—" || push!(out, "$(r.id) is superseded and still carries a rule for agents")
        end
    end
    for k in sort!(collect(checks))
        k in served || push!(out, "$k serves no requirement: no live row of dev/LEDGER.md cites it or a clause that cites it")
    end
    return out
end

# the ledger as the repository holds it: its faults, the charter naming it
function ledger_faults_here()::Vector{String}
    local text = isfile(LEDGER_PATH) ? _text(LEDGER_PATH) : ""
    local rows, out = ledger_rows(text)
    occursin("dev/LEDGER.md", _text(CHARTER_PATH)) || push!(out, "dev/CHARTER.md does not name dev/LEDGER.md")
    local checks = Set{String}(_short_id(first(p)) for p in vcat(METRICS, LOCKS))
    local clauses = Dict{String,Vector{String}}(c => ids for (c, (_, ids)) in charter_clauses())
    local march = Set{String}(String(m[1]) for m in eachmatch(r"^\| (\d+\.[0-9A-Za-z]+) \|"m, _text(joinpath(ROOT, "dev", "MARCH.md"))))
    append!(out, ledger_faults(rows, checks, clauses, p -> ispath(joinpath(ROOT, p)), march))
    return out
end

# L204's negative test: planted ledgers each answer as stated
function ledger_negatives_missed()::Vector{String}
    local head = "| ID | w | d | y | e | b | r |\n|---|---|---|---|---|---|---|\n"
    local row(id, by; words = "\"x\"", date = "2026-10-21", why = "y", band = "—", rule = "do x.") =
        "| $id | $words | $date | $why | $by | $band | $rule |"
    local base = [row("D1", "`L1` `C1`"), row("D2", "`C2` `test/smoke.jl`")]
    local function faults(lines)
        local r, f = ledger_rows(head * join(lines, '\n'))
        return length(f) + length(ledger_faults(r, Set(["L1", "L2", "R3"]), Dict("C1" => ["L2"], "C2" => ["R3"]),
                                                p -> p == "test/smoke.jl", Set(["13.28"])))
    end
    local cases = [
        ("a whole ledger, a planned and a superseded row among it",
         vcat(base, row("D3", "`planned: 13.28`"), row("D4", "`superseded: D1`"; rule = "—")), 0),
        ("a row citing no check of this file", vcat(base, row("D3", "`L9`")), 1),
        ("a row citing no clause", vcat(base, row("D3", "`C7`")), 1),
        ("a row citing a missing file", vcat(base, row("D3", "`test/none.jl`")), 1),
        ("a row citing prose", vcat(base, row("D3", "`dev/MARCH.md`")), 1),
        ("a row planned on no MARCH row", vcat(base, row("D3", "`planned: 13.99`")), 1),
        ("a row superseded by no row", vcat(base, row("D3", "`superseded: D9`"; rule = "—")), 1),
        ("a row that names nothing", vcat(base, row("D3", "noted")), 1),
        ("a deleted row", vcat(base, row("D4", "`L1`")), 1),
        ("unquoted words", vcat(base, row("D3", "`L1`"; words = "x")), 1),
        ("a date in no form", vcat(base, row("D3", "`L1`"; date = "Oct 21")), 1),
        ("a live row with no rule for agents", vcat(base, row("D3", "`L1`"; rule = "—")), 1),
        ("a superseded row with a rule", vcat(base, row("D3", "`superseded: D1`")), 1),
        ("a number without its band", vcat(base, row("D3", "`L1`"; words = "\"60 s TOPS\"")), 1),
        ("a number with its band", vcat(base, row("D3", "`L1`"; words = "\"60 s TOPS\"", band = "intent: minutes; band: 120 s")), 0),
        ("a check that serves no row", base[1:1], 1),
        ("a table line of six cells", vcat(base, "| D3 | \"x\" | 2026-10-21 | y | `L1` | — |"), 1),
    ]
    local out = String[]
    for (what, lines, want) in cases
        faults(lines) == want || push!(out, "negative missed: $what")
    end
    isempty(first(ledger_rows(""))) && length(ledger_faults(LedgerRow[], Set{String}(), Dict{String,Vector{String}}(), p -> true, Set{String}())) == 1 ||
        push!(out, "negative missed: an empty ledger")
    return out
end

# the checks whose description states a number with its unit but not its intent and band (L205)
quantities_without_band(descs)::Vector{String} = String[id for (id, d) in descs if occursin(QUANT_RX, d) && !has_intent_and_band(d)]

# L205's negative test: planted descriptions each answer as stated
function quantity_negatives_missed()::Vector{String}
    local cases = [("a budget with no intent or band", "the run takes at most 60 s", 1),
                   ("a budget with both", "the run takes at most 60 s; intent: minutes; band: red past 120 s", 0),
                   ("a cap with only its intent", "at most 90 lines; intent: lean", 1),
                   ("a percentage with no band", "more than 15% slower fails", 1),
                   ("a zero count", "asks inference 0 times", 0),
                   ("no number", "every lock is cited", 0),
                   ("a number with no unit", "the 41 probes", 0)]
    local out = String[]
    for (what, d, want) in cases
        length(quantities_without_band(["X" => d])) == want || push!(out, "negative missed: $what")
    end
    return out
end

# AGENTS.md's ledger block: the lines between its markers, each live row's rule for agents in order
const AGENTS_LEDGER_BEGIN = "<!-- ledger:begin -->"
const AGENTS_LEDGER_END = "<!-- ledger:end -->"
ledger_agents_lines(rows::Vector{LedgerRow})::Vector{String} = String["- **$(r.id)** $(r.rule)" for r in rows if ledger_live(r)]

# whether AGENTS.md's ledger block is exactly the ledger's rules (L206): its faults, the block it
# should hold printed when it differs
function agents_ledger_faults(agents::AbstractString, rows::Vector{LedgerRow})::Vector{String}
    local ls = split(agents, '\n')
    local i = findfirst(==(AGENTS_LEDGER_BEGIN), ls)
    local j = findfirst(==(AGENTS_LEDGER_END), ls)
    (i === nothing || j === nothing || j < i) && return ["AGENTS.md has no `$AGENTS_LEDGER_BEGIN` … `$AGENTS_LEDGER_END` block"]
    local want = ledger_agents_lines(rows)
    String.(ls[i+1:j-1]) == want && return String[]
    return ["AGENTS.md's ledger block is not dev/LEDGER.md's rules; it holds exactly these lines:\n      " * join(want, "\n      ")]
end

# L206's negative test: planted files each answer as stated
function agents_ledger_negatives_missed()::Vector{String}
    local rows = LedgerRow[LedgerRow(("D1", 1, "\"a\"", "2026-10-21", "y", "`L1`", "—", "Do a.")),
                           LedgerRow(("D2", 2, "\"b\"", "2026-10-21", "y", "`superseded: D3`", "—", "—")),
                           LedgerRow(("D3", 3, "\"c\"", "2026-10-21", "y", "`L2`", "—", "Do c."))]
    local file(lines...) = join(["# t", AGENTS_LEDGER_BEGIN, lines..., AGENTS_LEDGER_END, "## x"], '\n')
    local cases = [("the rules in order", file("- **D1** Do a.", "- **D3** Do c."), 0),
                   ("a rule missing", file("- **D1** Do a."), 1),
                   ("a superseded rule listed", file("- **D1** Do a.", "- **D2** —", "- **D3** Do c."), 1),
                   ("the rules out of order", file("- **D3** Do c.", "- **D1** Do a."), 1),
                   ("a rule reworded", file("- **D1** Do a.", "- **D3** Do c, mostly."), 1),
                   ("no block", "# t\n- **D1** Do a.\n- **D3** Do c.", 1)]
    local out = String[]
    for (what, text, want) in cases
        length(agents_ledger_faults(text, rows)) == want || push!(out, "negative missed: $what")
    end
    return out
end

# ---- L207: every lock's negative runs in every gate, inside this file (dev/CHARTER.md C0) ----------
# this file read once per run (L207): its top-level functions (name => body), each check's thunk (short id =>
# its text, the lines after its key up to the next key or the table's end) and the functions of this
# file each function calls (name => names)
const _RATCHET_SOURCE = Ref{Union{Nothing,Tuple{Dict{String,String},Dict{String,String},Dict{String,Set{String}}}}}(nothing)
function ratchet_source()::Tuple{Dict{String,String},Dict{String,String},Dict{String,Set{String}}}
    _RATCHET_SOURCE[] === nothing || return _RATCHET_SOURCE[]
    local lines = split(_text(joinpath(ROOT, "test", "parity_ratchet.jl")), '\n')
    local defs = Dict{String,String}()
    local k = 1
    while k <= length(lines)
        local m = match(r"^function (\w+!?)\(", lines[k])
        if m !== nothing
            local e = findnext(==("end"), lines, k)
            e === nothing && break
            defs[m[1]] = join(lines[k:e], '\n')
            k = e + 1
            continue
        end
        # a callable struct's call method is a function of its type's name: a ConstructionLock in the
        # table calls what `function (c::ConstructionLock)()` calls
        local cm = match(r"^function \(\w+::(\w+)\)\(", lines[k])
        if cm !== nothing
            local e = findnext(==("end"), lines, k)
            e === nothing && break
            defs[cm[1]] = join(lines[k:e], '\n')
            k = e + 1
            continue
        end
        local s = match(r"^(\w+!?)\(.*\)(?:::\S+)?\s*=(?!=)", lines[k])
        s === nothing || (defs[s[1]] = lines[k])
        k += 1
    end
    local key = r"^    \"([LR]\d+[a-z]?)_\w+\" =>"
    local thunks = Dict{String,String}()
    local i = 1
    while i <= length(lines)
        local m = match(key, lines[i])
        m === nothing && (i += 1; continue)
        local j = i + 1
        while j <= length(lines) && !occursin(key, lines[j]) && lines[j] != "]"
            j += 1
        end
        thunks[m[1]] = join(lines[i+1:j-1], '\n')
        i = j
    end
    local calls = Dict{String,Set{String}}(f => callees(b, defs) for (f, b) in defs)
    return _RATCHET_SOURCE[] = (defs, thunks, calls)
end

# the functions of `defs` a text calls
callees(text::AbstractString, defs::AbstractDict{String,String})::Set{String} =
    Set{String}(String(c[1]) for c in eachmatch(r"\b(\w+!?)\(", text) if haskey(defs, c[1]))

# A lock's always-run negative is a function of this file named `<name>_negatives_missed`, planting
# fixed text the lock's own logic must answer, which the lock calls, directly or through functions of
# this file. A negative in test/lock_negatives.jl, or one run once by hand, counts for nothing: the
# gate's selection may skip that family, so its plant rots unseen (the L195 plant found red, 2026-10-21).

# whether a thunk reaches a function named `<name>_negatives_missed`, given this file's functions and
# their calls
function reaches_negative(thunk::AbstractString, defs::AbstractDict{String,String},
                          calls::AbstractDict{String,Set{String}})::Bool
    local seen = Set{String}()
    local todo = collect(callees(thunk, defs))
    while !isempty(todo)
        local f = pop!(todo)
        f in seen && continue
        push!(seen, f)
        endswith(f, "_negatives_missed") && return true
        append!(todo, calls[f])
    end
    return false
end

# the locks that owe their always-run negative, exactly; R45 counts them, so the list only shrinks: a
# lock leaves it in the commit that gives it its negative, and a lock added after it never joins it
const NEGATIVE_OWED = Set{String}(split("""
    L125 L126 L129 L130 L148 L153 L162 L163 L194 L195 L197 L198
"""))

# the faults of the lock table against NEGATIVE_OWED: a lock outside it with no always-run negative,
# an entry whose lock has one, an entry that names no lock
function negative_faults(locks::AbstractVector{String}, has::Function, owed::AbstractSet{String})::Vector{String}
    local out = String[]
    for id in locks
        local h = has(id)
        !h && !(id in owed) && push!(out, "$id has no negative that runs in every gate (a `<name>_negatives_missed()` it calls)")
        h && id in owed && push!(out, "$id has its always-run negative: it leaves NEGATIVE_OWED")
    end
    for id in sort!(collect(owed))
        id in locks || push!(out, "NEGATIVE_OWED names $id, which is no lock")
    end
    return out
end

# L207's negative test: planted tables and planted sources each answer as stated
function negative_rule_negatives_missed()::Vector{String}
    local has(id) = id in ("L1", "L3")
    local cases = [("a lock with its negative and a listed one owing it", ["L1", "L2"], Set(["L2"]), 0),
                   ("a new lock with no negative", ["L1", "L2", "L4"], Set(["L2"]), 1),
                   ("a listed lock that has its negative", ["L1", "L2", "L3"], Set(["L2", "L3"]), 1),
                   ("a listed id that is no lock", ["L1", "L2"], Set(["L2", "L9"]), 1)]
    local out = String[]
    for (what, locks, owed, want) in cases
        length(negative_faults(locks, has, owed)) == want || push!(out, "negative missed: $what")
    end
    local defs = Dict("helper" => "function helper()\n    x_negatives_missed()\nend", "x_negatives_missed" => "function x_negatives_missed()\nend",
                      "plain" => "function plain()\nend")
    local calls = Dict(f => callees(b, defs) for (f, b) in defs)
    (reaches_negative("() -> length(helper())", defs, calls) && reaches_negative("() -> length(x_negatives_missed())", defs, calls) &&
     !reaches_negative("() -> length(plain())", defs, calls) && !reaches_negative("() -> 0", defs, calls)) ||
        push!(out, "negative missed: reaching a negative, directly, through a function, or not")
    return out
end

# ---- the landing log (L197): `dev/land.sh merge` appends a line per landing to the main tree's
# dev/.loop/landings.tsv; these decide over its text and the march branch's history ----------------
const L197_START = "36e3966ebd22fce82f2688f039e236287bebdc00"   # the last landing before the log
const L197_TARGET = 300         # seconds of a landing's own mechanics, every change alike (Dale 2026-10-21: "a
                                # few minutes"; "wicked fast, not tens of minutes to hours"; A30E1)
const L197_BAND = 600           # the band's edge: a median past it is red, one between the target and it a
                                # landing in minutes still, never a failure (L205: a target is not a tripwire)
const L197_COLUMNS_V1 = "landed_at\tcommit\tauthor_at\tland_start\tgate_runs\tgate_wall_s\tland_wall_s\tedit_to_landed_s\tfiles\tinsertions\ttiming"
const L197_COLUMNS = L197_COLUMNS_V1 * "\town_s\tqueue_wait_s"   # A30E1: a landing's own time and its waits

# the seconds since 1970 of a `YYYY-MM-DDTHH:MM:SSZ` time (days from the civil date)
function _l197_epoch(s::AbstractString)::Int
    m = match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$", s)
    m === nothing && error("$(repr(s)) is not a UTC time YYYY-MM-DDTHH:MM:SSZ")
    y, mo, d, h, mi, se = parse.(Int, m.captures)
    y -= mo <= 2
    era = fld(y, 400); yoe = y - era * 400
    doe = yoe * 365 + yoe ÷ 4 - yoe ÷ 100 + (153 * (mo + (mo > 2 ? -3 : 9)) + 2) ÷ 5 + d - 1
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se
end

# the commits after L197_START up to the march tip, oldest first, each (sha, author time, paths, lines
# added), from `git log --reverse --no-merges --numstat --format='C %H %at'`, what dev/land.sh reads
function _l197_history(text::AbstractString)
    out = Tuple{String,Int,Vector{String},Int}[]
    for l in split(text, '\n')
        if startswith(l, "C ")
            f = split(l)
            push!(out, (String(f[2]), parse(Int, f[3]), String[], 0))
        elseif count(==('\t'), l) >= 2 && !isempty(out)
            a, _, p = split(l, '\t'; limit = 3)
            c = out[end]
            out[end] = (c[1], c[2], push!(c[3], String(p)), c[4] + (a == "-" ? 0 : parse(Int, a)))
        end
    end
    return out
end

# what the log gets wrong against the history (a sentence each), and the median's window: every
# landing has its line (the lines' commits in history order, the last the tip, and each line's files
# and insertions git's over its range, so a landing that wrote no line changes the next line's
# numbers), its author_at its range's earliest author time and its edit_to_landed_s landed_at less
# that, its own_s and queue_wait_s (A30E1) at least 0 and summing to edit_to_landed_s; and over the
# last 5 lines the upper median of each landing's own mechanics over L197_TARGET at most 1: own_s, its
# land's work less its wait for another landing's hold, never its waits (a line before A30E1, eleven
# fields, judged by land_wall_s, its land's start to its push); no excuse takes a landing out of it
const L197_JUDGED_FROM = 3     # the fewest lines in the window its median is judged over
function l197_check(log::AbstractString, hist; head::AbstractString = "")
    bad = String[]
    rows = [split(l, '\t') for l in split(log, '\n') if !isempty(l)]
    if !isempty(rows)
        join(rows[1], '\t') in (L197_COLUMNS, L197_COLUMNS_V1) || push!(bad, "the log's first line is not its header")
        rows = rows[2:end]
    end
    idx = Dict(h[1] => i for (i, h) in enumerate(hist))
    ratios = Tuple{String,Float64}[]
    k = 0
    for r in rows
        length(r) in (11, 13) || (push!(bad, "a line of $(length(r)) fields, not 13 (11 before A30E1): $(join(r, ' '))"); continue)
        c = String(r[2]); i = get(idx, c, 0)
        i == 0 && (push!(bad, "the line of $(first(c, 8)): no commit the march branch brought after $(first(L197_START, 8))"); continue)
        i > k || (push!(bad, "the line of $(first(c, 8)): out of the history's order"); continue)
        span = hist[k+1:i]
        paths = unique(reduce(vcat, (h[3] for h in span); init = String[]))
        ins = sum(h[4] for h in span); author = minimum(h[2] for h in span)
        from = first(k == 0 ? L197_START : hist[k][1], 8)
        (parse(Int, r[9]) == length(paths) && parse(Int, r[10]) == ins) ||
            push!(bad, "the line of $(first(c, 8)): $(r[9]) files and $(r[10]) insertions, where git's range from $from holds $(length(paths)) and $ins: a landing in it wrote no line")
        _l197_epoch(r[3]) == author || push!(bad, "the line of $(first(c, 8)): author_at $(r[3]) is not its range's earliest author time")
        e2l = parse(Float64, r[8])
        abs(e2l - (_l197_epoch(r[1]) - author)) <= 1 || push!(bad, "the line of $(first(c, 8)): edit_to_landed_s $(r[8]) is not landed_at less author_at")
        own = parse(Float64, length(r) == 13 ? r[12] : r[7])
        if length(r) == 13
            q = parse(Float64, r[13])
            (own >= 0 && q >= -1 && abs(own + q - e2l) <= 1) ||
                push!(bad, "the line of $(first(c, 8)): own_s $(r[12]) and queue_wait_s $(r[13]) do not split its edit_to_landed_s $(r[8])")
        end
        push!(ratios, (c, own / L197_TARGET))
        k = i
    end
    k == length(hist) || push!(bad, "$(length(hist) - k) commit(s) up to the march tip $(first(hist[end][1], 8)) landed with no line (dev/land.sh merge writes one per landing)")
    # the line of the commit being gated is never judged by its own gate: a landing's judgement after
    # its push runs on the landed head, whose line is already written
    window = last(filter(x -> x[1] != head, ratios), 5)
    # judged once the window holds at least 3 lines: a median of fewer is one landing's own number
    if length(window) >= L197_JUDGED_FROM
        s = sort(last.(window)); med = s[(length(s) + 2) ÷ 2]
        med <= L197_BAND / L197_TARGET || push!(bad, "the median own time of the last $(length(window)) landings, land start to push less the wait for others' holds, is $(round(med; digits = 2)) times its $L197_TARGET s target, past its band of $L197_BAND s ($(join((first(c, 8) * " " * string(round(x; digits = 2)) for (c, x) in window), ", "))): fix the loop's own mechanics")
    end
    return bad, window
end

# L197: a note for each of the last 5 landings whose own time passed the band (own_s, A30E1), naming it:
# a single slow landing is reported, never failed; the median of five judges the cadence (ledger D13)
function l197_slow_notes(log::AbstractString)::Vector{String}
    rows = [split(l, '\t') for l in split(log, '\n') if !isempty(l)]
    own = [(String(r[2]), parse(Float64, r[12])) for r in rows if length(r) >= 13 && r[12] != "own_s"]
    return ["$(first(c, 8)) took $(round(o; digits = 1)) s of its own, past the $L197_BAND-s band: reported, the median of five judges"
            for (c, o) in last(own, 5) if o > L197_BAND]
end

# L197: the excuses a tree holds, its directory dev/.loop/excuse/ and nothing else (name => text): no
# MARCH row, commit message or other text excuses a landing (A22E1)
l197_excuses(root::AbstractString) =
    (d = joinpath(root, "dev", ".loop", "excuse"); isdir(d) ? Dict(f => read(joinpath(d, f), String) for f in readdir(d)) : Dict{String,String}())

# L197: the excuses, the tracked files dev/.loop/excuse/<sha8> (name => text): each named for a landed
# commit's first 8 hex digits, one line naming a cause outside its change, `machine:`, `lock:` or
# `crossing:`, and its measurement (what is wrong, a sentence each)
function l197_excuse_problems(files::AbstractDict, landed::AbstractVector)
    bad = String[]
    for (name, text) in files
        occursin(r"^[0-9a-f]{8}$", name) || (push!(bad, "dev/.loop/excuse/$name: not named for a commit's first 8 hex digits"); continue)
        any(c -> startswith(c, name), landed) || push!(bad, "dev/.loop/excuse/$name: no landing of that commit")
        ls = filter(!isempty, split(text, '\n'))
        length(ls) == 1 && occursin(r"^(machine|lock|crossing): \S.{20,}", ls[1]) ||
            push!(bad, "dev/.loop/excuse/$name: not one line `machine|lock|crossing: <the measured cause>`")
    end
    return bad
end

# L197 (A25E1, A25E2): every excuse file held to its landing's measured steps by dev/loop_excuse.sh
# check, the one program `dev/land.sh land` writes a measured excuse with: what is wrong with each, a
# sentence each named for its file, and the names whose excuse passes, the only ones that leave the
# window; a landing with no line in the log or no steps (before steps.tsv) has nothing measured
function l197_excuse_measured(root::AbstractString, logp::AbstractString, stepsp::AbstractString, files::AbstractDict)
    bad = String[]
    ok = Set{String}()
    for (name, text) in files
        out = mktemp() do path, io
            write(io, text); close(io)
            readchomp(Cmd(Cmd(["bash", joinpath(root, "dev", "loop_excuse.sh"), "check", logp, stepsp, name, path]); dir = root))
        end
        probs = filter(!isempty, split(out, '\n'))
        foreach(q -> push!(bad, "dev/.loop/excuse/$name: $q"), probs)
        isempty(probs) && push!(ok, name)
    end
    return bad, ok
end

# L197 (A21E4): the landing log each landing carries in its own tree (dev/.loop/landings.log) against
# the main tree's git-ignored one: a line-by-line prefix of it (an earlier line edited afterwards
# differs), missing at most one landing that is HEAD or its ancestor (the tip's own line, which no
# tree can carry before it lands); `isanc(c)` says whether commit c is HEAD or its ancestor
function l197_carried(tracked::Vector, untracked::Vector, isanc)
    bad = String[]
    n = length(tracked)
    if n > length(untracked) || tracked != untracked[1:n]
        k = something(findfirst(i -> i > length(untracked) || tracked[i] != untracked[i], 1:n), n)
        push!(bad, "the landing log this tree carries (dev/.loop/landings.log) differs from the main tree's at its line $k: a line edited after it was carried")
        return bad
    end
    missing = [String(split(l, '\t')[2]) for l in untracked[n+1:end] if occursin(r"^[^\t]+\t[0-9a-f]{40}\t", l)]
    owed = filter(isanc, missing)
    length(owed) <= 1 || push!(bad, "the landing log this tree carries lacks $(length(owed)) landings this tree holds ($(join(first.(owed, 8), ", "))): only the tip's own may be missing")
    return bad
end

# L198: every line of the landing log says whether its landing's timing was judged, and how (what
# the log gets wrong, a sentence each)
function l198_check(log::AbstractString)
    bad = String[]
    for r in [split(l, '\t') for l in split(log, '\n') if !isempty(l)][2:end]
        t = length(r) >= 11 ? r[11] : ""
        t == "judged" || occursin(r"^unjudged( \([^()]*\))?$", t) || occursin(r"^(FAILED( [a-z0-9.@-]+)+|SLOWER( [a-z0-9.@-]+)+( OVER( [a-z0-9.@-]+)+)?|OVER( [a-z0-9.@-]+)+)$", t) ||
            push!(bad, "the line of $(first(r[min(2, end)], 8)): timing $(repr(t)), not judged, unjudged, FAILED <stages>, SLOWER <stages> or OVER <stages>")
    end
    return bad
end


# ---- METRIC DEFINITIONS (baselines live in dev/parity_baseline.toml) --------
# Each entry: id => (description, thunk). Patterns deliberately exclude the
# definition line (`function name`) so they count CALLERS.
const METRICS = [
    "R45_locks_owing_negatives" => ("the locks that owe their always-run negative, NEGATIVE_OWED, which L207 keeps exact: each gains a `<name>_negatives_missed()` that the ratchet stage runs on every landing, planting fixed text its logic must answer, and leaves the list in that commit (Dale 2026-10-21: a negative in a family the gate may skip rots unseen). dev/CHARTER.md C0. Terminal state 0",
        () -> length(NEGATIVE_OWED)),
]


# ---- LOCKS (completed dimensions; exact match required) ---------------------
const LOCKS = [
    # ── dev/CHARTER.md (2026-09-22): the charter and the enforcement stack cite each other ──
    "L125_charter_is_the_definition_of_done" => ("dev/CHARTER.md exists; every check a clause cites exists here, and every lock and ratchet here is cited by exactly one clause (an uncited check is either obsolete or a clause is missing; a cited check that does not exist is a promise nobody keeps)",
        () -> begin
            clauses = charter_clauses()
            isempty(clauses) && return 1
            cited = String[]
            for (_, (_, ids)) in clauses; append!(cited, ids); end
            have = Set(_short_id(first(p)) for p in vcat(METRICS, LOCKS))
            missing_ = count(c -> c ∉ have, unique(cited))
            dup = length(cited) - length(unique(cited))
            uncited = count(h -> h ∉ Set(cited), have)
            missing_ + dup + uncited
        end),
    "L128_agents_md_current_and_lean" => ("AGENTS.md is the ONE agent-instructions file (no CLAUDE.md), at most 60 hand-written lines (the ledger block's markers among them), its ledger block (L206) at most one line per live requirement of dev/LEDGER.md, so the whole at most 60 plus one line per live requirement, a bound that grows with the ledger and still shows a stale or duplicated row (A33E6), every line at most 100 chars, names only paths, checks and WT_* switches that exist, pins the oracle commit dev/PARITY_MASTER.md pins, and carries no status vocabulary (dates, phase names, currently/as of/remaining) — status is measured here and planned in dev/MARCH.md, never remembered in the instructions; intent: every agent reads AGENTS.md whole and finds nothing stale or bloated (Dale 2026-09-22); band: at most 60 hand-written lines, 60 plus one per live requirement in all, and 100 chars a line, the caps the band's edge; the ledger block grows with the requirements, a line each, so leanness never fights the ledger. Behavior, run here: five planted files answer as stated (dev/CHARTER.md C0)",
        () -> (v = vcat(agents_md_violations(), agents_size_negatives_missed()); foreach(x -> println("    ✗ ", x), v); length(v))),
    "L130_every_file_outside_src_consumed" => ("every tracked file outside src/ is consumed: a tracked file that is not prose names it (a .md only by its path), a loader walks its directory, or it is a repository convention file or README (dev/CHARTER.md C9)",
        () -> length(unconsumed_files_outside_src())),
    "L153_the_gate_runs_what_ci_runs" => ("the full matrix runs every test family CI runs on Julia 1.12, validated (WT_VALIDATE=1, as CI's Unix shards), and smoke on 1.13, at clause closure (Dale 2026-10-21: large-scale runs happen only when a full clause is closed out: a push of the march branch, wt2, whose head commit carries `Closes: C<n>`, which dev/hooks/commit-msg and `dev/land.sh land` refuse unless the ratchet reads C<n> CLOSED; a gate/** push; workflow_dispatch; gate.yml's closure job decides and every other job waits on it), never holding a landing (fast is first, strict is final: Dale 2026-10-20; the landing's gate is `bash dev/gate.sh --block`, L194): dev/lanes.sh's default run (not --fast; its comment lines not counted) stops at the first red lane (both smokes and TLC side by side first) and has the whole Pkg.test suite as two concurrent shards (WT_SHARD=0,2 and 1,2), smoke on Julia 1.13, and WT1's smoke over the one corpus on both versions (legacy/test/smoke.jl, the agreement oracle legacy/'s deletion rule reads, dev/MARCH.md 1.G). No lane of that run is skipped green: it runs the probes and the suite only when the default `julia` is 1.12, the formal lane only when `java` runs, and smoke on 1.13 only without a JULIA= override and with `julia +1.13` installed, and each of those skips prints FAIL and sets the run red; and every lane runs on CI's wasm engine, the Node major ci.yml's node-version names (batch 108 passed on Node 25 and trapped on CI's Node 22). `dev/lanes.sh --lane <name> [--part i/N]` runs one lane of that same run, every other lane a no-op, its skips still red; .github/workflows/gate.yml is that run on CI's runners, one job per lane through it: every lane the default run has, each split lane with every part 0..N-1 of one N, `julia` 1.12 and `julia +1.13` from juliaup as the script calls them, Node from ci.yml's node-version, fail-fast, every TLC instance (--all), none of the lanes' own variables (WT_*, TLC_*) set by the workflow, and triggered exactly by a gate/** push, a push of the march branch (dev/land.sh's MARCH, wt2) or workflow_dispatch: `dev/land.sh merge` pushes the march branch and no other ref, a landing's one push (so a landed head whose commit carries `Closes: C<n>` gets the run, in its head's own concurrency group in each workflow, which a later landing's push never cancels; no march/<branch> per landing, Dale 2026-10-21), and `bash dev/gate.sh` pushes one to gate/<name> (the final full gate before PR #128 merges); ci.yml, formal.yml and downstream.yml trigger exactly as gate.yml does (a gate/** or wt2 push, workflow_dispatch, formal.yml's nightly schedule beside; no pull request, whose branch every landing pushes, A23E4; no branches-ignore), each job with no `needs:` under the closure predicate, so a plain landing runs none of them; the closure predicate is one text in gate.yml's run-name, its closure job and those jobs (a dispatch or schedule, a gate/** push, or a pushed head with a line `Closes: C<digit>…`, grep's `^Closes: C[0-9]+` spelt for an expression, A23E6); AGENTS.md says so, its table a row of its own. Batch 101 passed ratchet, probes and smoke on both versions, then broke a runtests family on CI (2026-10-07); until 2026-10-20 a push waited for this run and CI's (~2 h a landing; dev/CHARTER.md C10)",
        () -> begin
            _code(path) = join(filter(l -> !startswith(lstrip(l), "#"), split(read(path, String), '\n')), '\n')
            # the script's code, its comment lines dropped (a commented-out lane runs nothing)
            local lanes = _code(joinpath(ROOT, "dev", "lanes.sh"))
            local i = findfirst("if [ \$fast -eq 0 ]; then", lanes)
            i === nothing && return 3
            local gated = lanes[last(i):end]
            local agents = read(joinpath(ROOT, "AGENTS.md"), String)
            local wf = joinpath(ROOT, ".github", "workflows")
            local gate = isfile(joinpath(wf, "gate.yml")) ? _code(joinpath(wf, "gate.yml")) : ""
            # gate.yml's matrix (lane => its parts) against every lane the default run has: a
            # lane missing, a lane the script does not have, or a split lane missing a part
            local runs = Set(m[1] for m in eachmatch(r"(?:^|\s)lane ([a-z][a-z0-9.-]*)\s+(?:\$JULIA|julia|bash|suite)\b"m, lanes))
            local jobs = Dict{String,Vector{String}}()
            for m in eachmatch(r"^\s*- \{ lane: ([a-z0-9.-]+), part: '([0-9/]*)' \}\s*$"m, gate)
                push!(get!(jobs, m[1], String[]), m[2])
            end
            local whole = parts -> parts == [""] || (all(p -> occursin(r"^[0-9]+/[1-9][0-9]*$", p), parts) &&
                length(unique(map(p -> split(p, '/')[2], parts))) == 1 &&
                sort(map(p -> parse(Int, split(p, '/')[1]), parts)) == collect(0:parse(Int, split(parts[1], '/')[2]) - 1))
            local matrix_ok = length(runs) == 8 && keys(jobs) == runs && all(whole, values(jobs))
            # the closure predicate (A23E4, A23E6): a dispatch or schedule, a gate/** push, or a pushed head
            # with a line `Closes: C<digit>…`, grep's '^Closes: C[0-9]+' spelt for an expression (the
            # message after a newline holds a newline, `Closes: C` and a digit), one text in gate.yml's
            # run-name, its closure job and every job with no `needs:` of ci.yml, formal.yml and downstream.yml
            # the march branch, dev/land.sh's MARCH, the one branch beside gate/** whose push triggers the
            # workflows, each run of its push in that head's own concurrency group
            local mm = match(r"^MARCH=\$\{WT_MARCH_BRANCH:-([A-Za-z0-9._-]+)\}$"m, read(joinpath(ROOT, "dev", "land.sh"), String))
            local march = mm === nothing ? "?" : String(mm[1])
            local trig = "\non:\n  push:\n    branches: ['gate/**', '$march']\n  workflow_dispatch:\n"
            local own_group = "\${{ github.ref == 'refs/heads/$march' && github.sha || github.ref }}\n  cancel-in-progress: true\n"
            local P = "github.event_name != 'push' || startsWith(github.ref, 'refs/heads/gate/') || " *
                join(("contains(format('{0}{1}', fromJSON('\"\\n\"'), github.event.head_commit.message), format('{0}Closes: C$d', fromJSON('\"\\n\"')))" for d in 0:9), " || ")
            local pinned_push = map(("ci.yml", "formal.yml", "downstream.yml")) do f
                local c = _code(joinpath(wf, f))
                local js = split(last(split(c, "\njobs:\n"; limit = 2)), r"(?m)^(?=  [A-Za-z0-9_-]+:\s*$)"; keepempty = false)
                local roots = filter(j -> occursin(r"^  [A-Za-z0-9_-]+:\s*$"m, j) && !occursin(r"^    needs:"m, j), js)
                occursin(trig, c) && occursin(own_group, c) &&
                    !occursin(r"^\s*(pull_request|pull_request_target|workflow_run|workflow_call):"m, c) &&
                    count(r"^\s*push:"m, c) == 1 && !occursin("branches-ignore", c) && !occursin(r"^on:[ \t]*\S"m, c) &&
                    !isempty(roots) && all(j -> occursin(r"^  [A-Za-z0-9_-]+:\n    if: >-\n      \$\{\{ "m * P * " }}\n", j), roots)
            end
            count(!, [occursin("lane suite suite", gated),
                      occursin(raw"shards=\"0,2 1,2\"; [ \"$only\" = suite ] && [ -n \"$part\" ] && shards=\"$pi,$pn\"", lanes),
                      occursin(raw"  for s in $shards; do" * "\n" * raw"    WT_VALIDATE=1 WT_SHARD=\"$s\" $JULIA --project=. -e 'using Pkg; Pkg.test()' > \"$d/shard$s.log\" 2>&1 &", lanes),
                      occursin("lane smoke-1.13 julia +1.13 --project=. test/smoke.jl", gated),
                      occursin("\n| full matrix at clause closure (`Closes: C<n>`), #128's merge head, dispatch | `bash dev/gate.sh` |\n", agents),
                      # the full matrix only at clause closure (Dale 2026-10-21): the closure job decides, every other job waits on it,
                      # a `Closes: C<n>` line only on a tree whose ratchet reads C<n> CLOSED (the commit hook and the landing)
                      occursin("\n  closure:\n", gate) &&
                          occursin("          RUN: >-\n            \${{ " * P * " }}\n        run: |\n          if [ \"\$RUN\" = true ]; then\n", gate) &&
                          occursin("\nrun-name: >-\n  \${{ (" * P * ") && 'Gate closure' || 'Gate (no closure)' }}\n", gate) &&
                          count("    needs: closure\n    if: needs.closure.outputs.run == 'true'\n", gate) == 1,
                      occursin(raw"        printf '%s\n' \"$status\" | grep -qE \"^$c +.* CLOSED( |$)\" ||", read(joinpath(ROOT, "dev", "hooks", "commit-msg"), String)),
                      occursin(raw"            grep -qE \"^$c +.* CLOSED( |$)\" \"$rlog\" 2>/dev/null ||", read(joinpath(ROOT, "dev", "land.sh"), String)),
                      # a landed head reaches gate.yml by the landing's one push, the march branch's: no other ref
                      let l = read(joinpath(ROOT, "dev", "land.sh"), String)
                          count(r"\bgit\b[^\n]*\bpush\b", l) == 1 && occursin(raw"    git push -q origin \"$MARCH\"", l) && !occursin("refs/heads/march/", l)
                      end,
                      # the first red lane ends the run (batch 111: a 1.13 failure surfaced at minute 29)
                      occursin(raw"stop() { [ $fail -eq 0 ] || { echo \"LANES red\"; exit 1; }; }", lanes),
                      occursin(join([raw"lane ratchet  $JULIA --project=. test/parity_ratchet.jl", "stop"], '\n'), lanes),
                      occursin(join([raw"join_bg \"$d/s113\" \"$d/formal\"; rm -rf dev/formal/states", "stop"], '\n'), lanes),
                      occursin(join([raw"  stop", raw"  lane suite suite"], '\n'), gated),
                      # --lane runs one lane of the same run: every other lane is a no-op
                      occursin(raw"want() { [ -z \"$only\" ] || [ \"$only\" = \"$1\" ]; }", lanes),
                      occursin(join([raw"  local name=$1; shift", raw"  want \"$name\" || return 0"], '\n'), lanes),
                      # each skip fails the gate (A12P6): a default julia that is not 1.12 ...
                      occursin(join([
                          raw"  if ! want probes && ! want suite; then :",
                          raw"  elif $JULIA -e 'exit(VERSION.major == 1 && VERSION.minor == 12 ? 0 : 1)'; then",
                          raw"    lane probes $JULIA --project=. test/probe_bytes.jl",
                          raw"  else",
                          raw"    printf '  FAIL probes         (the default julia is not 1.12: the probes and the suite are 1.12 lanes; juliaup default 1.12)\n'; fail=1",
                          raw"  fi"], '\n'), gated),
                      # ... no working java ...
                      occursin(join([
                          raw"  if ! want formal; then :",
                          raw"  elif java -version >/dev/null 2>&1; then bg \"$d/formal\" lane formal bash dev/formal/run_tlc.sh",
                          raw"  else printf '  FAIL formal         (no working java: TLC needs one, brew install openjdk@17)\n'; fail=1; fi"], '\n'), gated),
                      # ... and a JULIA= override or no julia +1.13
                      occursin(join([
                          raw"  if ! want smoke-1.13; then :",
                          raw"  elif [ \"$JULIA\" != \"julia\" ]; then",
                          raw"    printf '  FAIL smoke-1.13     (the gate runs on the default julia, not %s)\n' \"$JULIA\"; fail=1",
                          raw"  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then",
                          raw"    bg \"$d/s113\" lane smoke-1.13 julia +1.13 --project=. test/smoke.jl",
                          raw"  else",
                          raw"    printf '  FAIL smoke-1.13     (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1",
                          raw"  fi"], '\n'), gated),
                      # the wasm engine is CI's: ci.yml's node-version, a Node of another major fails
                      occursin(join([
                          raw"NODE_MAJOR=$(sed -n \"s/^ *node-version: *'\{0,1\}\([0-9][0-9]*\).*/\1/p\" .github/workflows/ci.yml | head -1)",
                          raw"ci_node=\"$(brew --prefix \"node@$NODE_MAJOR\" 2>/dev/null)/bin\"",
                          raw"[ -x \"$ci_node/node\" ] && export PATH=\"$ci_node:$PATH\"",
                          raw"node_major=$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')",
                          raw"printf '  node %s (CI: %s)\n' \"$(node --version 2>/dev/null)\" \"$NODE_MAJOR\"",
                          raw"if [ -z \"$NODE_MAJOR\" ] || [ \"$node_major\" != \"$NODE_MAJOR\" ]; then",
                          raw"  printf '  FAIL node           (the wasm engine is not CI'\"'\"'s Node %s: brew install node@%s)\n' \"$NODE_MAJOR\" \"$NODE_MAJOR\"; fail=1",
                          raw"fi"], '\n'), lanes),
                      # gate.yml: the default run's lanes, each part of each split lane, one job each ...
                      matrix_ok,
                      occursin(raw"          bash dev/lanes.sh --lane ${{ matrix.lane }}${{ matrix.part != '' && format(' --part {0}', matrix.part) || '' }}${{ matrix.lane == 'formal' && ' --all' || '' }}", gate),
                      # ... the first red job cancels the rest ...
                      occursin("      fail-fast: true\n", gate) && !occursin("fail-fast: false", gate),
                      # ... `julia` 1.12 and `julia +1.13` as the script calls them ...
                      # (in every job that installs Julia)
                      count("      - name: Julia (juliaup)\n", gate) >= 1 &&
                          count(raw"          channel 1.12 && \"$J\" default 1.12" * "\n", gate) == count("      - name: Julia (juliaup)\n", gate),
                      occursin(raw"          if [ \"${{ matrix.lane }}\" = smoke-1.13 ] || [ \"${{ matrix.lane }}\" = legacy-1.13 ]; then channel 1.13; fi", gate),
                      # ... and WT1's smoke, the agreement oracle legacy/'s deletion rule reads, on both versions
                      occursin(join([raw"    bg \"$d/l113\" lane legacy-1.13 julia +1.13 --project=legacy legacy/test/smoke.jl",
                                     raw"    lane legacy julia --project=legacy legacy/test/smoke.jl",
                                     raw"    join_bg \"$d/l113\""], '\n'), gated),
                      # ... CI's Node major, read from ci.yml's node-version ...
                      # (every job's: a job of its own Node passed while another kept the line)
                      let majors = count("      - name: CI's Node major\n", gate),
                          reads = count(raw"          echo \"node=$(sed -n \"s/^ *node-version: *'\{0,1\}\([0-9][0-9]*\).*/\1/p\" .github/workflows/ci.yml | head -1)\" >> \"$GITHUB_OUTPUT\"", gate),
                          versions = filter(l -> occursin(r"^\s*node-version:", l), split(gate, '\n'))
                          majors >= 1 && reads == majors && length(versions) == majors &&
                              all(==(raw"          node-version: ${{ steps.ci.outputs.node }}"), versions)
                      end,
                      # ... no lane variable set by the workflow (the script sets them) ...
                      !occursin(r"\b(WT|TLC)_[A-Z_]+", gate),
                      # ... and on gate/** and the march branch, where ci.yml and formal.yml never run
                      occursin(trig * "\n", gate) && occursin(own_group, gate) &&
                          !occursin(r"^\s*(pull_request|schedule|workflow_run|workflow_call):"m, gate),
                      # ci.yml's, formal.yml's and downstream.yml's triggers are gate.yml's (gate/** and
                      # march branch pushes, a dispatch; no pull request, no branches-ignore, no inline push),
                      # each job with no `needs:` under the closure predicate
                      pinned_push...,
                      occursin("\n| CI, Formal models, Downstream: the same triggers, never a plain landing | `.github/workflows` |\n", agents)])
        end),
    "L162_the_gate_has_a_budget" => ("the full matrix gives its verdict in minutes, though it never holds a landing (L153): every lane of `bash dev/lanes.sh`'s default run on CI's runners (gate.yml, one job each) within a budget of 20 minutes per lane job, the lane job's `timeout-minutes: 20` exactly, so a slow lane and a hung one are both cut at the budget, red, and fail-fast cancels the rest, and gate.yml holds no other timeout; dev/gate.sh reads the budget from gate.yml's lane job (one source), prints the slowest lane job against it and marks a job past it; AGENTS.md's enforcement table names `bash dev/gate.sh` as the full matrix at clause closure (`Closes: C<n>`), on #128's merge head and on dispatch. The budget is admitted by five consecutive green runs on the final matrix, cold-cache runs (a new gate branch) among them, each with every lane job <= 0.95 B = 1140 s; it is lowered only, never raised: a lane past it is rebalanced or split first (Dale 2026-10-09, the gate \"~15-20 min\"); intent: a closure matrix gives its verdict while its red is still the next item; band: 20 minutes per lane job, GitHub's own timeout its edge (dev/CHARTER.md C10)",
        () -> begin
            local gate = read(joinpath(ROOT, ".github", "workflows", "gate.yml"), String)
            local sh = read(joinpath(ROOT, "dev", "gate.sh"), String)
            local agents = replace(read(joinpath(ROOT, "AGENTS.md"), String), r"\s+" => " ")
            local job(name) = (m = match(Regex("(?s)\\n  " * name * ":\\n(.*?)(?=\\n  [a-z][a-z-]*:\\n|\\z)"), gate); m === nothing ? "" : m.captures[1])
            local lane_t = [parse(Int, m[1]) for m in eachmatch(r"^    timeout-minutes: (\d+)\b"m, job("lane"))]
            count(!, [lane_t == [20],
                      length(collect(eachmatch(r"timeout-minutes:", gate))) == 1,
                      occursin("| full matrix at clause closure (`Closes: C<n>`), #128's merge head, dispatch | `bash dev/gate.sh` |", agents),
                      occursin(raw"budget=$(awk '/^  lane:$/ { inlane = 1; next } /^  [a-z][a-z-]*:$/ { inlane = 0 }", sh) &&
                          occursin(raw"inlane && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate.yml)", sh) &&
                          occursin(raw"-v B=\"$budget\"", sh) && occursin("PAST THE %d-MINUTE BUDGET", sh)])
        end),
    "L163_the_fast_lane" => ("the CI inner loop is never a landing's gate: `bash dev/gate.sh --fast` pushes a commit to gate-fast/<name>, never to gate/, where .github/workflows/gate-fast.yml runs the ratchet and smoke on Julia 1.12 and 1.13 through `dev/lanes.sh --lane <ratchet|smoke|smoke-1.13> [--part i/N]` and prints `FAST green` or `FAST red`; it runs no Julia on this machine, and dev/land.sh calls neither it nor `dev/lanes.sh --fast` (a landing's gate is `bash dev/gate.sh --block`, L194). gate-fast.yml's triggers are exactly a `gate-fast/**` push and workflow_dispatch; its matrix is exactly the ratchet, smoke parts 0..N-1 of one N and smoke-1.13 parts 0..M-1 of one M, with N and M the values its header states as measured, and 1 + N + M <= 20 (the account's concurrent runners); fail-fast; the lane job's timeout-minutes is the fast budget B_fast, which dev/gate.sh --fast reads from there (one source) and gate-fast.yml holds no other timeout; no WT_* or TLC_* variable is set by the workflow; ci.yml, formal.yml and gate.yml are not triggered by a gate-fast/** push; dev/gate.sh's own description of --fast calls it the CI inner loop, never a landing's gate; and test/smoke_times.tsv, which deals the smoke parts, lists exactly smoke's groups and xfail groups (smoke.jl's and those of the files it includes), each with a number of seconds for 1.12 and for 1.13 (smoke's dealing errors on a missing file, a duration that is no number and a group with none, where it dropped, skipped or took the median silently, dev/AUDIT.md A17P9) (dev/CHARTER.md C10)",
        () -> begin
            _code(path) = join(filter(l -> !startswith(lstrip(l), "#"), split(read(path, String), '\n')), '\n')
            local wf = joinpath(ROOT, ".github", "workflows")
            isfile(joinpath(wf, "gate-fast.yml")) || return 1
            local fast_raw = read(joinpath(wf, "gate-fast.yml"), String)
            local fast = _code(joinpath(wf, "gate-fast.yml"))
            local sh = read(joinpath(ROOT, "dev", "gate.sh"), String)
            local agents = replace(read(joinpath(ROOT, "AGENTS.md"), String), r"\s+" => " ")
            local v = 0
            # the triggers, exactly
            v += occursin("\non:\n  push:\n    branches: ['gate-fast/**']\n  workflow_dispatch:\n", fast) &&
                 count(r"^\s*push:"m, fast) == 1 && !occursin("branches-ignore", fast) ? 0 : 1
            # the matrix: the ratchet, smoke 0..N-1, smoke-1.13 0..M-1, with the N and M the header states
            local jobs = Dict{String,Vector{String}}()
            for m in eachmatch(r"^\s*- \{ lane: ([a-z0-9.-]+), part: '([0-9/]*)' \}\s*$"m, fast)
                push!(get!(jobs, m[1], String[]), m[2])
            end
            local stated = match(r"N = (\d+) and M = (\d+)", fast_raw)
            local N = stated === nothing ? -1 : parse(Int, stated[1])
            local M = stated === nothing ? -1 : parse(Int, stated[2])
            local parts(n) = String["$i/$n" for i in 0:n-1]
            v += (sort(collect(keys(jobs))) == ["ratchet", "smoke", "smoke-1.13"] && jobs["ratchet"] == [""] &&
                  sort(jobs["smoke"]) == sort(parts(N)) && sort(jobs["smoke-1.13"]) == sort(parts(M))) ? 0 : 1
            v += 1 + N + M <= 20 ? 0 : 1
            v += occursin("      fail-fast: true\n", fast) && !occursin("fail-fast: false", fast) ? 0 : 1
            # the budget: the lane job's timeout, the one gate.sh --fast reads, and no other timeout
            local lane_t = [parse(Int, m[1]) for m in eachmatch(r"^    timeout-minutes: (\d+)\b"m, fast)]
            v += length(lane_t) == 1 && length(collect(eachmatch(r"timeout-minutes:", fast))) == 1 ? 0 : 1
            v += occursin(raw"inlane && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate-fast.yml)", sh) ? 0 : 1
            v += occursin("bash dev/lanes.sh --lane \${{ matrix.lane }}\${{ matrix.part != '' && format(' --part {0}', matrix.part) || '' }}\n", fast) ? 0 : 1
            # no lane variable set by the workflow
            v += occursin(r"\b(WT|TLC)_[A-Z_]+", fast) ? 1 : 0
            # ci.yml, formal.yml and gate.yml never run on a gate-fast/** push
            for f in ("ci.yml", "formal.yml", "gate.yml")
                local c = _code(joinpath(wf, f))
                v += occursin("gate-fast", c) || occursin("'**'", c) || occursin("branches-ignore", c) ? 1 : 0
            end
            # gate.sh --fast pushes to gate-fast/ and never to gate/
            v += occursin("[ \$fast -eq 0 ] || { prefix=gate-fast; workflow=\"Gate fast\"; verdict=FAST; }", sh) &&
                 occursin("name=\$prefix/\${name//\\//-}", sh) ? 0 : 1
            v += occursin("#   bash dev/gate.sh --fast [<rev>] [<name>]   # the CI inner loop, never a landing's gate: pushes to", sh) ? 0 : 1
            local land = read(joinpath(ROOT, "dev", "land.sh"), String)
            v += occursin("--fast", land) ? 1 : 0
            # the smoke dealing's durations: exactly the groups (smoke.jl's, its lazy ones and those of
            # the files it includes), each measured on both versions
            local smk_main = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local smk_src = join([smk_main; [read(joinpath(ROOT, "test", m[1]), String)
                                             for m in eachmatch(r"^include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)"m, smk_main)]], '\n')
            local want = Set{String}(m[1] in ("g", "lazy_g") ? m[2] : "xfail " * m[2]
                                     for m in eachmatch(r"^_(g|xf|lazy_g|lazy_xf)\(\"([^\"]+)\""m, smk_src))
            local got = String[]
            for ln in eachline(joinpath(ROOT, "test", "smoke_times.tsv"))
                (isempty(ln) || startswith(ln, '#')) && continue
                local f = split(ln, '\t'; limit = 3)
                (length(f) == 3 && tryparse(Float64, f[1]) !== nothing && tryparse(Float64, f[2]) !== nothing) || (v += 1; continue)
                push!(got, String(f[3]))
            end
            v += length(symdiff(want, Set(got))) + (length(got) - length(Set(got)))
            v
        end),
    "L194_the_blocking_gate" => ("a landing's gate is the blocking gate on this machine, about a minute of wall, never a CI run (fast is first, strict is final: Dale 2026-10-20): `bash dev/gate.sh --block` runs dev/block.jl, which starts every stage at once, each the command a fresh check runs in a process of its own: the package load; the ratchet; smoke on test/block_groups.tsv's fixed core (`WT_SMOKE_EXACT=1`, its groups in the order named), on the groups the changed files map to there, and on the groups whose lines the change touches in test/smoke.jl and the case files it includes (a changed line in an included file's generators: every group the file defines), those also on `julia +1.13`, less the groups test/block_groups.tsv's matrix-only row names (none in the core; the non-blocking matrix runs them); the probe core of that file with the probes the change touches, by `WT_PROBE_ONLY`, the smokes on 1.12, the probes and the tests through this tree's warm runner under `--warm` (dev/block_runner.jl, one after another: a server per worktree holding the tree's code, revised before each request, refusing a request that would record a baseline, each request in Main reset to a fresh process's binding table, `using` list and lowering counter by its documented quarantined reset, its layout checked at start, each stating `block_runner: warm|cold (why) <blob>`, cold until its check (its file, arguments and WT_* variables) has run once on the code as it now is; its environment dev/runner_env at exact versions; the gate takes no other runner and refuses WT_BLOCK_RUNNER), each in a fresh process otherwise; TLC on the instances of the models the change touches (`TLC_ONLY`); and test/runtests.jl on the QA families and phases the change selects (`WT_QA_ONLY`, each run as its shard runs it, A19P1): every changed QA family, test/runtests.jl's changed families and phases, and the QA families test/block_groups.tsv's row of each changed file names, so a lock's behavior file runs before a landing that changes what it tests. dev/timing_best.toml's budgets: the whole run (`total`) at most 60 s and every stage's at most the total, the tests stage's 20 s under a warm runner (`tests@warm`), each a target of wall, never scaled (a machine more than 1.5 times slower than its best leaves the timing ratchet unjudged, never the checks or the budgets, L195); intent: the gate takes about a minute, so a landing takes minutes (Dale 2026-10-21: a 61-s run is no failure of an under-a-minute goal); band: a wall over its budget is a note, red only past BUDGET_BAND (2) times it, the whole run past 120 s; a changed file under src/ or ext/, or a changed test file no stage runs and no QA family is, with no row in test/block_groups.tsv fails the gate (a test file the change deletes runs nothing), and every src file has one, each row `<path><TAB><groups><TAB><QA families><TAB><1.13 groups>` (the 1.13 groups run on `julia +1.13` when the file changes: a file whose output prints Julia's own signatures or types names some, A19P9); every group the file names is a smoke group or xfail group, every probe a corpus probe and every family a QA family of test/runtests.jl; every line of code of a src file is in a piece (a definition's, keyed by its line so two methods of one name are two, each line of a multi-line `const` its own, any other form's, dev/AUDIT.md A20C12 = A19C1); the selections (the lines a diff touches, a deletion touching both sides of it; the smoke groups, probes, runtests families and phases and TLC instances those lines or files select; a file's row by longest match) are decisions over text that this lock runs on fixed diffs (A19P11); test/block_groups.tsv's `measured` row names the src tree the map was written for, and a change to src/ fails when that map is stale for it (more than STALE_PIECES = 8 of the pieces the change alters, keyed on its base's text, are pieces that moved between the measured tree and the change's base, whose map rows the selection may misread, the count and the re-record command printed; how far the base moved is a note, so a change in code no other landing moved passes however stale the map; a src file whose code the change leaves alone, Julia's own parse of both texts with line numbers and docstrings dropped being one expression, alters no piece, so a change of comments and docstrings alone passes; a map measured on the change's own src tree, a change carrying its re-recorded map, is fresh; A30E5; the rebuild's map written by hand, its `measured` row the change's own src tree, until WasmTarget lowers code a measurement can cover (dev/MARCH.md 1.D); a measured tree this repository does not hold; a changed line of code in no piece), as does any change to ext/ but its deletion, which no map measures (dev/AUDIT.md A20C13); a selection naming no group, probe, family or phase fails its own run (smoke's `no group named`, probe_bytes' `names no probe`, runtests' `WT_QA_ONLY names no QA family`, run_tlc.sh's `no instance`), never a green run of nothing. Every stage runs with no WT_*, TLC_* or WASMTARGET_* variable of the caller's, only the gate's own (`stage_env`; the record lists those removed and each stage's own, A19P3), and HEAD, the tree and its uncommitted state are read again after the stages: a change while they ran gives no verdict and no record. A run's verdict is red when the change fails (a check, an unmapped file, a budget or the timing ratchet), none when the machine cannot judge (its Julia, Node or Java, a tree changed during the run) green otherwise (exit 0, 1, 3), a run whose warm runner was cold (its first request, or the first after a revise) red only for a failing check and otherwise green with `timing = \"unjudged\"` (neither its budgets nor its bests judged: `dev/land.sh land` judges them by a warm run of the landed tree right after the landing, L198). The evidence record, one per run, dev/.block/<tree>-<n>.toml (git-ignored; never overwriting an earlier run's, A19P2), is written on a clean tree only; `dev/land.sh merge` lands a branch head only on a record of the change from the head's merge base with the march branch (the record's base; a `--base` or WT_MARCH_BRANCH that narrows the change selects less, A19P8), of fresh processes or of that commit's own runner (the record's runner, dev/block_runner.jl with its blob at the head, A19P4), and only when no record of its tree, in any worktree, is red (a red run stands, whatever ran after it) and the last one is green, of exactly that commit, made on a clean tree, from a clean main tree, and while the last closure matrix is not red: it reads gate.yml's newest run on a dispatch, a gate/** push or a push of the march branch whose head commit carries `Closes: C<n>` (read from the commit, `gh run list`), names it, refuses on a red one (the next item), lands with a WARNING written into the record while it has not finished or there is none, never waits for one and reads no other check; and `dev/land.sh land` refuses a change to legacy/ but its deletion whole, WT1 frozen as the agreement oracle (dev/MARCH.md 1.G) (dev/CHARTER.md C10)",
        () -> begin
            local sh = read(joinpath(ROOT, "dev", "gate.sh"), String)
            local blk = read(joinpath(ROOT, "dev", "block.jl"), String)
            local land = read(joinpath(ROOT, "dev", "land.sh"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local probe = read(joinpath(ROOT, "test", "probe_bytes.jl"), String)
            local corpus = read(joinpath(ROOT, "test", "probe_corpus.jl"), String)
            local tlc = read(joinpath(ROOT, "dev", "formal", "run_tlc.sh"), String)
            local v = 0
            v += occursin("if [ \"\${1:-}\" = --block ]; then shift; exec julia --startup-file=no dev/block.jl \"\$@\"; fi", sh) ? 0 : 1
            # every stage, started side by side
            for line in [raw"    ld = launch!(Stage(\"load\", setenv(`$jl --project=. -e 'using WasmTarget; print(VERSION)'`, stage_env()), logf(\"load\")))",
                         raw"    rat = launch!(Stage(\"ratchet\", setenv(`$jl -O0 --project=. test/parity_ratchet.jl`, stage_env()), logf(\"ratchet\")))",
                         raw"        launch!(Stage(\"smoke-core\", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $core`, smokeenv), logf(\"smoke-core\")))",
                         raw"            launch!(Stage(\"smoke-batch\", setenv(`$jl --project=. -L dev/block_jit.jl test/smoke.jl $batch`, batchenv), logf(\"smoke-batch\")))",
                         raw"        launch!(Stage(\"smoke-1.13\", setenv(`julia +1.13 --startup-file=no --project=. -L dev/block_jit.jl test/smoke.jl $smoke113`, smokeenv), logf(\"smoke-1.13\")))",
                         raw"    smoke113 = setdiff(unique(vcat(newgroups, v113)), matrix)",
                         raw"        append!(mapped, row[1]); append!(tests, row[2]); append!(v113, row[3])",
                         raw"    probe_env(c) = stage_env(Dict(\"WT_PROBE_ONLY\" => join(c, ' ')))",
                         raw"        launch!(Stage(\"tlc\", setenv(`bash dev/formal/run_tlc.sh`, stage_env(Dict(\"TLC_ONLY\" => join(tlc, ' '), \"TLC_WORKERS\" => \"2\"))), logf(\"tlc\")))",
                         raw"    smokeenv = stage_env(Dict(\"WT_SMOKE_TIMES\" => \"1\", \"WT_SMOKE_EXACT\" => \"1\"))",
                         raw"    batch = unique(setdiff(unique(vcat(mapped, newgroups)), core, matrix))",
                         raw"            append!(out, last.(spans))",
                         raw"    probes = unique(vcat(probe_core, touched_probes(base)))",
                         raw"    append!(fails, stale_map(moved, measured, filter(f -> !startswith(f, \"ext/\") || ispath(joinpath(ROOT, f)), changed), head_texts,",
                         raw"    stale = measured == head_src ? Set{String}() : pieces_moved(measured, gitok(\"rev-parse\", \"$base:src\") ? git(\"rev-parse\", \"$base:src\") : \"\")",
                         raw"        union!(own, change_pieces(f, bt, ht, git(\"diff\", \"-U0\", base, \"--\", f)))",
                         raw"    moved = stale === nothing ? nothing : length(intersect(stale, own))",
                         raw"    head_texts = Dict(f => read(joinpath(ROOT, f), String) for f in code_changed if isfile(joinpath(ROOT, f)))",
                         raw"    isempty(unmapped) || push!(fails, \"no row in test/block_groups.tsv for $(join(unmapped, \", \")): add one naming the smoke groups and QA families that exercise it\")",
                         raw"    foreach(wait, tasks)",
                         raw"        isempty(tests) || launch!(Stage(\"tests\", setenv(`$jl --project=. test/runtests.jl`, tests_env), logf(\"tests\")))",
                         raw"        isempty(tests) || push!(chain, Stage(\"tests\", setenv(`$runner test/runtests.jl`, tests_env), logf(\"tests\")))",
                         raw"    tests_env = stage_env(Dict(\"WT_QA_ONLY\" => join(tests, '\n')))",
                         raw"    unchanged || push!(efails, \"the tree changed while the stages ran (HEAD, or what is uncommitted): no verdict, rerun\")",
                         raw"    if clean && unchanged",
                         raw"            name in families && name != \"parity_ratchet.jl\" && (push!(tests, name); continue)",
                         raw"            f == \"test/runtests.jl\" && (append!(tests, touched_runtests(base)); continue)",
                         raw"        ok = s.exit == 0 && isempty(missing)"]
                v += occursin(line, blk) ? 0 : 1
            end
            # the budgets: the whole run at most 60 s, every stage within it
            local bt = read(joinpath(ROOT, "dev", "timing_best.toml"), String)
            local sec = match(r"(?s)\n\[budget\]\n(.*?)(?:\n\[|\z)", bt)
            local budgets = sec === nothing ? Dict{String,Float64}() :
                Dict(String(m[1]) => parse(Float64, m[2]) for m in eachmatch(r"^\"([a-z0-9.@-]+)\" = ([0-9.]+)$"m, sec[1]))
            local stages = ["total", "load", "ratchet", "smoke-core", "smoke-batch", "smoke-1.13", "probes", "tests", "tests@warm", "tlc", "case-median"]
            v += sort(collect(keys(budgets))) == sort(stages) ? 0 : 1
            v += get(budgets, "total", Inf) <= 60 && all(k -> get(budgets, k, Inf) <= get(budgets, "total", 0), stages) ? 0 : 1
            v += get(budgets, "tests@warm", Inf) <= 20 ? 0 : 1
            # each budget a target, red only past its band, BUDGET_BAND times it (L205)
            v += occursin("\nconst BUDGET_BAND = 2\n", blk) ? 0 : 1
            v += occursin(raw"    total > BUDGET_BAND * tb && push!(tfails, \"total: $(fmt(total)) s of wall, past the band of $(BUDGET_BAND * tb) s (the budget $tb s)\")", blk) ? 0 : 1
            v += occursin(raw"        if b !== nothing && wall > BUDGET_BAND * b" * "\n" *
                          raw"            push!(tfails, \"$name: $(fmt(wall)) s of wall, past its band of $(BUDGET_BAND * b) s (its budget $b s)\"); v = \"OVER BUDGET\"", blk) ? 0 : 1
            v += occursin(raw"    median_case <= BUDGET_BAND * b || push!(tfails, \"case-median:", blk) ? 0 : 1
            # no budget is scaled to pass: the scaled time is the ratchet's alone (A19P5)
            v += occursin(r"scaled <= b|total / factor <= tb|not blocking", blk) ? 1 : 0
            # the map: every src file has a row, every group and probe exists
            # smoke's groups: smoke.jl's and those of the case files it includes
            local smoke_all = join([smoke; [read(joinpath(ROOT, "test", m[1]), String)
                                            for m in eachmatch(r"^include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)"m, smoke)]], '\n')
            local groups = Set(m[1] for m in eachmatch(r"^_(?:g|xf|lazy_g|lazy_xf)\(\"([^\"]+)\""m, smoke_all))
            local cases = Set(m[1] for m in eachmatch(r"^_c\(\"([^\"]+)\""m, corpus))
            local rt = read(joinpath(ROOT, "test", "runtests.jl"), String)
            local families = Set(m[1] !== nothing ? String(m[1]) : String(m[2]) * "/" * String(m[3])
                                 for m in eachmatch(r"_wt_qa_include\((?:\"([^\"]+)\"|joinpath\(@__DIR__, \"([^\"]+)\", \"([^\"]+)\"\))\)", rt))
            local rows = Dict{String,Vector{String}}()
            for l in _file_lines(joinpath(ROOT, "test", "block_groups.tsv"))
                (isempty(strip(l)) || startswith(l, '#')) && continue
                local f = split(l, '\t')
                local names(x) = filter(!=("-"), String.(split(x)))
                if f[1] == "measured"
                    v += length(f) == 2 && occursin(r"^[0-9a-f]{40}$", f[2]) ? 0 : 1
                elseif f[1] in ("core", "probes", "matrix-only")
                    length(f) == 2 ? (rows[String(f[1])] = names(f[2])) : (v += 1)
                else
                    length(f) == 4 || (v += 1; continue)
                    rows[String(f[1])] = vcat(names(f[2]), names(f[4]))
                    v += count(t -> !(t in families), names(f[3]))
                end
            end
            v += haskey(rows, "core") && haskey(rows, "probes") ? 0 : 1
            v += occursin("    newgroups = setdiff(touched, matrix)\n    batch = unique(setdiff(unique(vcat(mapped, newgroups)), core, matrix))", blk) &&
                 occursin("            append!(f[1] == \"core\" ? core : f[1] == \"probes\" ? probes : matrix, names(f[2]))", blk) ? 0 : 1
            v += count(l -> startswith(l, "measured\t"), _file_lines(joinpath(ROOT, "test", "block_groups.tsv"))) == 1 ? 0 : 1
            for (k, gs) in rows
                v += count(g -> !(g in (k == "probes" ? cases : groups)), gs)
            end
            for (d, _, fs) in walkdir(SRC), f in fs
                endswith(f, ".jl") || continue
                local rel = replace(relpath(joinpath(d, f), ROOT), '\\' => '/')
                v += any(k -> k == rel || (endswith(k, "/") && startswith(rel, k)), keys(rows)) ? 0 : 1
            end
            # a selection naming nothing fails its own run
            v += occursin("        println(\"smoke: no group named \", join(unknown, \", \"))\n        exit(1)", smoke) ? 0 : 1
            v += occursin("isempty(unknown) || (println(\"probe_bytes: WT_PROBE_ONLY names no probe \", join(unknown, \", \")); return 1)", probe) ? 0 : 1
            v += occursin(raw"[[ \" ${cfgs[*]} \" == *\" $o \"* ]] || { echo \"TLC_ONLY names $o, which is no instance\" >&2; exit 1; }", tlc) ? 0 : 1
            v += occursin("        isempty(unknown) || (println(\"runtests: WT_QA_ONLY names no QA family \", join(unknown, \", \")); exit(1))", rt) ? 0 : 1
            # the record, on a clean tree only, and the landing on it alone
            v += occursin("    if clean && unchanged\n        open(io -> Base.invokelatest(TOML.print, io, record; sorted = true), path, \"w\")", blk) ? 0 : 1
            for line in [raw"    path = joinpath(RECORD_DIR, \"$tree-$n.toml\")",
                         raw"    verdict = run_verdict(fails, judged_tfails, efails, cold)",
                         raw"    return verdict == \"green\" ? 0 : verdict == \"red\" ? 1 : 3"]
                v += occursin(line, blk) ? 0 : 1
            end
            # a check's failure is red, never classed as the machine's or the runner's
            v += occursin(r"push!\((tfails|efails), \"(no row|ratchet|smoke|probes|tests|tlc: [^n])", blk) ? 1 : 0
            # a stage sees no WT_*, TLC_* or WASMTARGET_* variable but the gate's own (run, A19P3), and
            # every stage's Cmd is built from stage_env: no merge(ENV, ...) and no Cmd without setenv
            v += occursin(r"merge\(ENV", blk) ? 1 : 0
            local Bm = Module(:BlockEnv)
            try
                Base.include(Bm, joinpath(ROOT, "dev", "block.jl"))
                local e = withenv("WT_RATCHET_INCLUDED" => "1", "WT_SMOKE_PART" => "0/8", "WT_RATCHET_UPDATE" => "1",
                                  "TLC_DEEP" => "x", "WASMTARGET_X" => "1", "BLOCK_KEEP" => "k") do
                    Base.invokelatest(getglobal(Bm, :stage_env), Dict("WT_QA_ONLY" => "q"))
                end
                v += e == merge(Dict(k => v2 for (k, v2) in ENV if !any(p -> startswith(k, p), ("WT_", "TLC_", "WASMTARGET_"))), Dict("WT_QA_ONLY" => "q", "BLOCK_KEEP" => "k")) ? 0 : 1
                v += (try; Base.invokelatest(getglobal(Bm, :stage_env), Dict("WT_RATCHET_UPDATE" => "1")); false; catch; true; end) ? 0 : 1
                # the selections, run on fixed text (A19P11): a selection that silently picks nothing fails here
                local g = (n, a...) -> Base.invokelatest(getglobal(Bm, n), a...)
                local smoke_l = ["# harness", "_g(\"a\", Any[", "  case", "])", "helper() = 1", "_xf(\"b\", Any[", "  case", "])", "main()"]
                local corpus_l = ["# head", "_c(\"p1\", f1, (Int,))", "  x", "_c(\"p2\", f2, (Int,))", "  y"]
                local rt_l = ["x", "_wt_qa_include(\"a.jl\")", "_wt_qa_include(joinpath(@__DIR__, \"s\", \"t.jl\"))", "begin",
                              "    @pphase \"Phase 1: A\" begin", "  y", "    end", "    @pphase \"Phase 2: B\" begin", "  z",
                              "end  # end of phase-registration block", "tail"]
                local rows_ = ["src/" => (["g1"], ["t1"]), "src/a.jl" => (["g2"], String[]), "ext/" => (String[], String[])]
                v += count(!, [g(:hunk_lines, "@@ -3,2 +3,3 @@\n@@ -10 +11,0 @@\n@@ -20 +20 @@\n") == [3, 4, 5, 11, 12, 20],
                               g(:groups_touched, smoke_l, [3], true) == ["a"], g(:groups_touched, smoke_l, [5], true) == ["b"],
                               isempty(g(:groups_touched, smoke_l, [1], true)), isempty(g(:groups_touched, smoke_l, [9], true)),
                               g(:groups_touched, smoke_l, g(:hunk_lines, "@@ -5 +4,0 @@\n"), true) == ["a", "b"],
                               # an included case file: its generators feed every group it defines; a one-line group is its line
                               g(:groups_touched, ["gen() = 1", "_g(\"c\", gen())", "_g(\"d\", gen())"], [1], false) == ["c", "d"],
                               g(:groups_touched, ["gen() = 1", "_g(\"c\", gen())", "_g(\"d\", gen())"], [3], false) == ["d"],
                               isempty(g(:groups_touched, ["no_groups() = 1"], [1], false)),
                               g(:groups_touched, ["_g(\"c\", gen())", "_g(\"d\", Any[", "  x", "])"], [3], false) == ["d"],
                               g(:probes_touched, corpus_l, [3, 5, 1], ["p1\tabc", "p2\tdef"], [2]) == ["p1", "p2"],
                               isempty(g(:probes_touched, corpus_l, [1], String[], Int[])),
                               g(:runtests_touched, rt_l, [1, 2, 3, 6, 9, 11]) == ["a.jl", "s/t.jl", "Phase 1: A", "Phase 2: B"],
                               g(:tlc_select, ["dev/formal/Foo.tla", "dev/formal/nightly/Bar.tla", "src/x.jl", "dev/formal/MCBazBroken.cfg"],
                                 ["MCFoo.cfg", "MCFooDeep.cfg", "MCBar.cfg", "MCBaz.cfg"], ["MCFooDeep.cfg"]) == (["MCFoo.cfg", "MCBaz.cfg"], ["MCFooDeep.cfg"]),
                               g(:row_for, "src/a.jl", rows_) == (["g2"], String[]), g(:row_for, "src/b.jl", rows_) == (["g1"], ["t1"]),
                               g(:row_for, "test/x.jl", rows_) === nothing])
                # every line of code is in a piece: a multi-line const's lines each their own, any
                # other form's, a definition's by its line (A20C12)
                local tab = "x = 1\nconst MISC_OPS = Dict(\n    (A, B, :f) => g(1),   # c\n    (A, B, :h) =>\n        g(2),\n)\n"
                v += count(!, [g(:line_keys, tab, "src/t.jl")[3] == "src/t.jl:3", g(:line_keys, tab, "src/t.jl")[1] == "src/t.jl:L1#0",
                               g(:line_keys, "f(x) = 1\nf(x::Int) = 2\n", "src/t.jl")[2] == "src/t.jl:f@2#0"])
                # a stale map fails a change to src/: more than STALE_PIECES pieces of src moved between the
                # measured tree and the change's base, a measured tree unknown here, a changed line of code
                # in no piece (a module's own line, when the parse keys it to no form); a change to ext/ always; a change elsewhere never (A20C13)
                local mtab = "module M\nf(x) = 1\nend\n"
                local ns, ni = Dict{String,String}(), Dict{String,Vector{Int}}()
                v += count(!, [getglobal(Bm, :STALE_PIECES) == 8,
                               isempty(g(:stale_map, 8, "m", ["src/t.jl"], Dict("src/t.jl" => tab), Dict("src/t.jl" => [1, 3]))),
                               occursin("9 of the pieces it alters moved", only(g(:stale_map, 9, "m", ["src/t.jl"], Dict("src/t.jl" => tab), Dict("src/t.jl" => [1])))),
                               occursin("git rev-parse HEAD:src", only(g(:stale_map, 9, "m", ["src/t.jl"], ns, ni))),
                               length(g(:stale_map, nothing, "m", ["src/t.jl"], ns, ni)) == 1,
                               g(:stale_map, 0, "m", ["src/t.jl"], Dict("src/t.jl" => mtab), Dict("src/t.jl" => [1, 2])) ==
                                   (haskey(g(:line_keys, mtab, "src/t.jl"), 1) ? String[] :
                                    ["src/t.jl:1 is a line of code in no piece of the map (dev/block.jl line_keys)"]),
                               g(:stale_map, 0, "m", ["src/t.jl"], Dict("src/t.jl" => "x = 1\n"), Dict("src/t.jl" => [1])) == String[],
                               length(g(:stale_map, 0, "m", ["ext/E.jl"], ns, ni)) == 1,
                               isempty(g(:stale_map, 99, "m", ["test/x.jl", "dev/MARCH.md"], ns, ni))])
                # a red run's kind for the red history (A33E4): timing alone, or the ratchet on L148 or L197
                # alone, is queue time; any other failure is the change's own
                v += occursin("            open(RED_HISTORY, \"a\") do io\n", blk) && occursin("        if verdict == \"red\"\n", blk) ? 0 : 1
                v += count(!, [g(:red_kind, String[], "") == ("queue", "timing alone"),
                               g(:red_kind, ["ratchet"], "L197_the_loop_is_fast   1  ❌ LOCK BROKEN (want 0)\n") == ("queue", "ratchet on L197 alone"),
                               g(:red_kind, ["ratchet"], "L148_x 1 ❌ b\nL197_y 1 ❌ b\n") == ("queue", "ratchet on L148 L197 alone"),
                               first(g(:red_kind, ["ratchet"], "L194_x 1 ❌ b\nL197_y 1 ❌ b\n")) == "own",
                               first(g(:red_kind, ["ratchet", "tests"], "L197_y 1 ❌ b\n")) == "own",
                               first(g(:red_kind, ["ratchet"], "")) == "own"])
                # a removed test file or corpus case is named in the message, never silent (A33E1)
                local sc = "_g(\"num\", Any[\n    (\"add\", f, 1),\n    (\"mul\", f, 2),\n])\n_c(\"p1\", f, (Int,))\n"
                local none_ = Dict{String,Set{String}}()
                local lost = Dict("test/smoke_corpus.jl" => Set(["num/mul"]))
                v += count(!, [isempty(g(:probes_touched, String[], [0], String[], [0])),   # a file emptied whole: its hunk at line 0
                               g(:corpus_case_keys, sc) == Set(["num/add", "num/mul", "p1"]),
                               g(:corpus_case_keys, "_lazy_g(\"reg\", \"gen.jl\")\n    (\"x\", f, 1),\n") == Set(["reg/*"]),   # a lazy group is one key (audit 34)
                               g(:unnamed_removals, "x", String[], Dict("test/smoke_corpus.jl" => Set(["reg/*"]))) == ["test/smoke_corpus.jl:reg/*"],
                               g(:unnamed_removals, "x", ["test/lock_negatives.jl"], none_) == ["test/lock_negatives.jl"],
                               isempty(g(:unnamed_removals, "x\nRemoves-test: test/lock_negatives.jl — its plants move into the ratchet\n", ["test/lock_negatives.jl"], none_)),
                               g(:unnamed_removals, "Removes-test: test/lock_negatives.jl — \n", ["test/lock_negatives.jl"], none_) == ["test/lock_negatives.jl"],
                               g(:unnamed_removals, "x", String[], lost) == ["test/smoke_corpus.jl:num/mul"],
                               isempty(g(:unnamed_removals, "Removes-test: test/smoke_corpus.jl:num/mul — WT1-only\n", String[], lost)),
                               isempty(g(:unnamed_removals, "Removes-test: test/smoke_corpus.jl:* — the legacy lane runs them\n", String[], lost, Set(["test/smoke_corpus.jl"]))),
                               g(:unnamed_removals, "Removes-test: test/smoke_corpus.jl:* — a blanket over kept cases\n", String[], lost) == ["test/smoke_corpus.jl:num/mul"],   # audit 34
                               g(:unnamed_removals, "Removes-test: test/smoke_corpus.jl:num/add — another case\n", String[], lost) == ["test/smoke_corpus.jl:num/mul"]])
                # the budget counts the change's own pieces among the stale ones (A30E5): a change of comments
                # and docstrings alone alters no piece (Julia's parse, docstrings and line numbers dropped, is
                # unchanged), a code change alters the base's pieces its hunks touch, an added file none
                local d0 = "\"doc\"\nf(x) = 1\ng(x) = 2\n"
                v += count(!, [g(:code_unchanged, "f(x) = 1\n", "# a note\nf(x) = 1  # why\n"),
                               g(:code_unchanged, d0, replace(d0, "\"doc\"" => "\"\"\"\nanother doc\n\"\"\"")),
                               !g(:code_unchanged, d0, replace(d0, "g(x) = 2" => "g(x) = 3")),
                               !g(:code_unchanged, "f(x) = 1\n", "f(x) = (\n"),
                               !g(:code_unchanged, "f(x) = 1\n", "f(x) = 1\nh(x) = 0\n"),
                               g(:change_pieces, "src/t.jl", d0, replace(d0, "g(x) = 2" => "g(x) = 3"), "@@ -3 +3 @@\n") == Set(["src/t.jl:g@3#0"]),
                               isempty(g(:change_pieces, "src/t.jl", d0, replace(d0, "\"doc\"" => "\"new doc\""), "@@ -1 +1 @@\n")),
                               isempty(g(:change_pieces, "src/t.jl", "", d0, "@@ -0,0 +1,3 @@\n"))])
            catch err
                println("    ✗ dev/block.jl does not load for its environment rule: ", sprint(showerror, err))
                v += 1
            end
            v += occursin("\ndev/.block/\n", read(joinpath(ROOT, ".gitignore"), String)) ? 0 : 1
            for line in [raw"        for f in \"$w/dev/.block/$tree\"-*.toml; do [ -f \"$f\" ] && recs+=(\"$f\"); done",
                         raw"        grep -qx 'verdict = \"red\"' \"$f\" && { echo \"$f is red: a red run of this tree stands — refusing\"; grep -A8 '^failures' \"$f\"; exit 1; }",
                         raw"    grep -qx \"head = \\\"$head\\\"\" \"$rec\" || { echo \"$rec, the last record of this tree, is of another commit — refusing\"; exit 1; }",
                         raw"    grep -qx 'clean = true' \"$rec\" || { echo \"$rec was made on a tree with uncommitted changes — refusing\"; exit 1; }",
                         raw"    grep -qx 'verdict = \"green\"' \"$rec\" || { echo \"$rec, the last record of this tree, is not green ($(sed -n 's/^verdict_why = //p' \"$rec\")) — refusing\"; exit 1; }",
                         raw"    [ -z \"$(git status --porcelain --untracked-files=no)\" ] || { echo \"main tree has uncommitted changes — refusing\"; exit 1; }",
                         raw"    if [ -n \"$(git diff --name-only \"$tip\" HEAD -- legacy/)\" ] && [ -n \"$(git log -1 --format=%H \"$tip\" -- legacy)\" ] && [ -n \"$(git ls-tree -d HEAD legacy)\" ]; then",
                         raw"    bash dev/gate.sh --block"]
                v += occursin(line, land) ? 0 : 1
            end
            # the last closure matrix read, never waited for: gate.yml's newest run on a dispatch, a
            # gate/** push or a march branch head carrying `Closes: C<n>` (from the commit itself), red
            # refusing, unfinished or absent a WARNING in the record; no other check read
            for line in [raw"    prev=$(git -C \"$MAIN\" rev-parse \"$MARCH\")",
                         raw"        runs=$(gh run list --limit 200 --json databaseId,status,conclusion,workflowName,event,headBranch,headSha \\",
                         raw"                                and (.workflowName == \"Gate\" or .workflowName == \".github/workflows/gate.yml\"))]",
                         raw"           git -C \"$MAIN\" log -1 --format=%B \"$rsha\" 2>/dev/null | grep -qE '^Closes: C[0-9]+'; then",
                         raw"    completed:failure | completed:timed_out | completed:startup_failure)",
                         raw"        echo \"the last closure matrix is red, the next item (gate.yml run $mrun on $msha, $mconclusion): fix it first — refusing\"; exit 1 ;;",
                         raw"        printf '\n[landing]\nwarning = \"%s\"\n' \"$warning\" >> \"$rec\""]
                v += occursin(line, land) ? 0 : 1
            end
            v += length(collect(eachmatch(r"\$\(gh run list", land))) == 1 ? 0 : 1
            v += occursin(raw"    mb=$(git -C \"$MAIN\" merge-base \"$head\" \"$MARCH\")", land) &&
                 occursin(raw"    grep -qx \"base = \\\"$mb\\\"\" \"$rec\" ||", land) ? 0 : 1
            # the warm runner is this tree's, versioned, its reset the one quarantined mechanism (A19P4)
            local rn = read(joinpath(ROOT, "dev", "block_runner.jl"), String)
            for (txt, line) in [(rn, raw"const REFUSED = (\"WT_PROBE_RECORD\", \"WT_RATCHET_UPDATE\", \"WT_RECORD_TIMES\")"),
                                (rn, raw"        state = get(ran_on, key, -1) == version[] ? \"warm\" :"),
                                (rn, raw"        isempty(s) || (version[] += 1)"),
                                (rn, raw"        key = join(vcat(normpath(abspath(cwd, target)), args, sort([k * \"=\" * v for (k, v) in env if startswith(k, \"WT_\")])), '\0')"),
                                (rn, raw"        s isa String || !usings_changed() || (s = \"Main's `using` list differs from its start after the reset\")"),
                                (rn, raw"        frame(sock, 'e', \"block_runner: $state $BLOB\n\")"),
                                (rn, raw"    c1 == c2 > COUNTER0 || error("),
                                (rn, "# The reset (parity(quarantine: a Julia process has no API to give Main a fresh binding table;"),
                                (blk, raw"    haskey(ENV, \"WT_BLOCK_RUNNER\") && error("),
                                (blk, raw"    runner = \"--warm\" in args ? `julia --startup-file=no dev/block_runner.jl run` : ``"),
                                (blk, raw"                m[2] == runner_blob || push!(efails,"),
                                (blk, raw"    occursin(\"Precompiling\", read(ld.log, String)) && pushfirst!(rstates,"),
                                (land, raw"    [ -z \"$runner\" ] || [ \"$runner\" = \"dev/block_runner.jl $(git -C \"$MAIN\" rev-parse \"$head:dev/block_runner.jl\")\" ] ||")]
                v += occursin(line, txt) ? 0 : 1
            end
            # Main's table is stored only by reset_main!, and dev/runner_env pins every package exactly
            local rm_ = match(r"(?s)    function reset_main!\(\)\n.*?\n    end\n", rn)
            v += rm_ !== nothing && count("unsafe_store!", rn) == 4 && count("unsafe_store!", rm_.match) == 4 ? 0 : 1
            v += occursin(raw"        error(\"block_runner: a `using` added to Main is not taken back by storing its length at byte $USINGS_LEN_OFFSET (Julia $VERSION)\")", rn) ? 0 : 1
            local renv = read(joinpath(ROOT, "dev", "runner_env", "Project.toml"), String)
            local compat = match(r"(?s)\n\[compat\]\n(.*)", renv)
            v += compat !== nothing && occursin("Revise = \"=", compat[1]) &&
                 all(l -> occursin(r"^[A-Za-z]+ = \"=[0-9.]+\"$", l), filter(!isempty, split(compat[1], '\n'))) ? 0 : 1
            v += occursin(r"check-runs|actions/runs|gh run (view|watch)|gh api|gh pr checks"i, land) ? 1 : 0
            v
        end),
    "L195_the_timing_ratchet" => ("speed is held like strictness (Dale 2026-10-20, after Vasculature.jl's timing ratchet): dev/timing_best.toml holds the best wall seconds of each stage of the blocking gate whose work is fixed (load, ratchet, smoke-core, probes; under the warm runner (`--warm`) every stage holds a best of its own, `<stage>@warm`, smoke-core and probes included: the compiler's speed is held warm, against a best recorded from a warm run, never a cold one (A19P4); a stage with no best fails the gate outside `WT_TIMING_UPDATE=1`, which records it) and the best seconds of dev/block.jl's calibration, a fixed piece of compiler-like work (a new small function lowered, inferred and optimized) it times every quarter second throughout the run; a stage's wall over the machine factor (the calibration's median over its best, at least 1; an update records a run's lower quartile when faster and scales the bests it records by the factor that gives) more than 1.5 times AND more than 0.3 s above its best fails the gate (`slower`; past 15% and inside that band, `over_target`, a note in the record), so a stage that does more work or waits longer fails and a busier machine does not, unless the commit's message carries `Timing: correctness fix (MARCH 13.<n>)` naming a row the change itself adds to dev/MARCH.md (a `+` line of `git diff <base>..HEAD -- dev/MARCH.md` under a row number the base's MARCH does not have: an existing row, edited, exempts nothing, A20P26) that names the stages it leaves slower, which alone are exempt, and whose bests that run's update raises in the same diff (A19P7); intent: no change makes a fixed stage slower unnoticed, and the machine's own noise never fails a landing; band: a stage past 15% over its best is a note, one more than 1.5 times AND more than 0.3 s over it fails (audit 31: a ratchet stage at 23.7 s against its 20.4 s best flapped red and green at factor 1.0), a machine more than 1.5 times slower than its best leaves the timing unjudged; the budgets are targets red only past their band (L194), never scaled: a machine more than 1.5 times slower than its best while the stages ran (FACTOR_CAP, `capped`) leaves the run's timing ratchet unjudged, never a scaled pass: no stage is compared with its best (a slower stage a note, `timing_failures`), no best is recorded from it, every check still judged; a budget missed past the cap is the machine's by the cap's definition, so a run whose checks pass is green with its timing unjudged, the missed budgets named (`timing = \"unjudged (budget <stage> <wall> past cap, factor <f>)\"`) in its record (`dev/land.sh land` printing the unjudged streak, L198), a failing check or a missed budget red, a cold run (correctness only: no budget and no best judged) green with its timing unjudged; CI judges no timing, so the ratchet is judged here whenever the machine is quiet enough, recorded as unjudged otherwise; and under that cap a budget or best exceeded is red; no verdict only for a reason of the tools or the tree (a tool missing, the tree changed during the run), never for load (A19P2, A19P5). `WT_TIMING_UPDATE=1` runs the gate three times (update_main) and, only when all three are green with their timing judged on a clean tree on a quiet machine (load average at most the machine's CPUs), sets each ratcheted stage's best to the median of its three times (updated_bests), lowered only, raised only for a stage the commit's own exemption names, so one fast run sets no best, and writes each best's source into dev/timing_best.toml's [best_from] (its records, the commit they ran on, their machine factors; a rescaled best its own source and the update that rescaled it), every best having one (A20P20); a best is set only so, never by hand: one whose entry is not the median of an update's three records at machine factors within FACTOR_CAP (source_problem) bounds nothing, its want of a source a timing failure outside the update (judged on a warm run under the cap), and the update re-records it whichever way it moves, a rise still held to the base's (A20P25); a calibration lower than the best, the runs' median lower quartile, lowers every best in proportion in the same write. A change is judged by its own dev/timing_best.toml held to its base's (`git show <base>:dev/timing_best.toml`, A19P6): a budget or best of the base's removed, or raised (a best compared at one calibration, as best / calibration), fails the gate. Behavior, from dev/block.jl's own decisions: 11.6 s against a best of 10 s is slower, 11.4 s is not, 1.25 s against 1 s is not (0.25 s), 1.4 s is; the factor of a calibration twice its best is 2, of one faster than its best 1; a Timing line citing a MARCH row that does not exist raises. Negative-tested end to end: a sleep planted in the ratchet and an overrun of a lowered budget each turned the gate red (dev/CHARTER.md C10)",
        () -> begin
            local blk = read(joinpath(ROOT, "dev", "block.jl"), String)
            local bt = read(joinpath(ROOT, "dev", "timing_best.toml"), String)
            local v = 0
            v += occursin("const SLOWER_TARGET = 0.15\nconst SLOWER_FRACTION = 0.5\nconst SLOWER_SECONDS = 0.3\n", blk) ? 0 : 1
            v += occursin("const RATCHETED = (\"load\", \"ratchet\", \"smoke-core\", \"probes\")", blk) ? 0 : 1
            v += occursin("        if name in RATCHETED && ok && fixed && slower(scaled, bw)", blk) ? 0 : 1
            v += occursin("        timing_exemption(msg, git(\"diff\", \"\$base..HEAD\", \"--\", \"dev/MARCH.md\"),\n                         gitok(\"cat-file\", \"-e\", \"\$base:dev/MARCH.md\") ? git(\"show\", \"\$base:dev/MARCH.md\") : \"\")", blk) &&
                 occursin("    isempty(exempt_problem) || push!(fails, exempt_problem)", blk) &&
                 occursin("            if name in exempt_stages\n", blk) ? 0 : 1
            v += occursin("        scaled = wall / factor\n", blk) ? 0 : 1
            v += occursin("const FACTOR_CAP = 1.5\n", blk) && occursin("    capped = factor > FACTOR_CAP\n", blk) ? 0 : 1
            # past the cap a stage slower than its best is a note, never a failure, and no best is recorded; a budget still fails
            v += occursin("    judged_tfails = timing_failures(tfails, sfails, capped, cold)\n", blk) &&
                 occursin("    verdict = run_verdict(fails, judged_tfails, efails, cold)\n", blk) &&
                 occursin("    timing = cold ? \"unjudged (cold)\" :\n", blk) &&
                 occursin("                push!(sfails, \"\$name: more than 1.5 times and 0.3 s slower than its best: \$why\"); v = capped ? \"UNJUDGED\" : \"SLOWER\"", blk) &&
                 occursin("\"timing\" => timing,", blk) ? 0 : 1
            v += occursin("    cpus = length(Sys.cpu_info())\n    quiet = loadavg[1] <= cpus\n", blk) && !occursin("CPU_THREADS)", blk) && !occursin(r"\bbusy = ", blk) ? 0 : 1
            v += occursin("    bestkey(name) = !isempty(runner) ? name * \"@warm\" : name", blk) && !occursin("warm_stage", blk) ? 0 : 1
            # the update: three runs, every one green with its timing judged on a clean tree on a quiet
            # machine, then updated_bests, each best written with its source (A20P20)
            v += occursin("const UPDATE_RUNS = 3\n", blk) &&
                 occursin("        if r === nothing || !(r.verdict == \"green\" && r.timing == \"judged\" && r.clean && r.quiet)\n", blk) &&
                 occursin("    best, changes, how = updated_bests(timing[\"best\"], [r.fastest for r in runs], [r.calib for r in runs],", blk) &&
                 occursin("        best_from[k] = best_source(h, get(best_from, k, \"\"), [r.record for r in runs], runs[end].head, [r.factor for r in runs])\n", blk) &&
                 occursin("    write_best(timing[\"budget\"], best, best_cpu, best_from)\n", blk) &&
                 occursin("exit(get(ENV, \"WT_TIMING_UPDATE\", \"\") == \"1\" ? update_main(ARGS) : main(ARGS))", blk) &&
                 !occursin("write_best(budget, best, best_cpu)", blk) ? 0 : 1
            v += occursin("    quiet = loadavg[1] <= cpus\n    updating && !quiet && (updating = false;", blk) ? 0 : 1
            # a best not recorded fails the gate outside the update, which records it
            v += occursin(raw"                push!(fails, \"$bkey: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)\")", blk) ? 0 : 1
            v += occursin(raw"                    push!(fails, \"calibration: no best in dev/timing_best.toml (WT_TIMING_UPDATE=1 records it)\"))", blk) ? 0 : 1
            v += occursin("\n[best]\n", bt) && occursin("\n[budget]\n", bt) ? 0 : 1
            v += occursin("    loosened = isempty(base_text) ? String[] : timing_against_base(timing, Base.invokelatest(TOML.parse, base_text), exempt_stages)", blk) &&
                 occursin("    append!(fails, loosened)\n", blk) &&
                 occursin("            k == \"calibration\" || (out[k] = round(out[k] * cal / bcal; digits = 2); how[k] = :rescaled)", blk) ? 0 : 1
            # a best is set only by the update (A20P25): one whose source is not an update's median bounds
            # nothing, its want a timing failure outside the update, which re-records it whichever way it moves
            v += occursin("    best = Dict{String,Any}(k => v for (k, v) in timing[\"best\"] if k == \"calibration\" || !haskey(unsourced, k))\n", blk) &&
                 occursin("                push!(sfails, \"\$bkey: its best \$(unsourced[bkey]) (WT_TIMING_UPDATE=1 re-records it)\")", blk) &&
                 occursin("    rerecord = String[k for k in keys(timing[\"best\"]) if !isempty(source_problem(get(best_from, k, nothing)))]\n", blk) &&
                 occursin("        if !haskey(out, k) || w < out[k] || k in rerecord\n", blk) &&
                 occursin("    if isnan(bcal) || cal < bcal || \"calibration\" in rerecord\n", blk) ? 0 : 1
            # every best names where it came from (A20P20)
            local sec = name -> (m = match(Regex("\\n\\[" * name * "\\]\\n((?:\"[^\"\\n]+\" = [^\\n]*\\n?)*)"), bt);
                                 m === nothing ? Set{String}() : Set(String(x[1]) for x in eachmatch(r"^\"([^\"]+)\" = "m, m[1])))
            for k in sort(collect(setdiff(sec("best"), sec("best_from"))))
                println("    ✗ L195: dev/timing_best.toml's best $k has no [best_from] entry (WT_TIMING_UPDATE=1 writes it)"); v += 1
            end
            # the decisions, run
            local B = Module(:BlockDecisions)
            try
                Base.include(B, joinpath(ROOT, "dev", "block.jl"))
                local f = (n, a...) -> Base.invokelatest(getglobal(B, n), a...)
                v += count(!, [f(:slower, 15.1, 10.0), !f(:slower, 14.9, 10.0), !f(:slower, 1.25, 1.0), f(:slower, 1.6, 1.0), !f(:slower, 0.5, 0.25),
                               # past the 15% target and inside the 1.5-times band: a note (audit 31's 23.7 s against 20.4 s)
                               f(:over_target, 23.7, 20.4), !f(:slower, 23.7, 20.4), !f(:over_target, 11.4, 10.0), !f(:over_target, 15.1, 10.0),
                               !f(:slower, 100.0, NaN), f(:machine_factor, 0.04, 0.02) == 2.0, f(:machine_factor, 0.01, 0.02) == 1.0,
                               f(:timing_exemption, "Charter: C10\n", "+| 13.4 | C1 |", "") == ("", String[]),
                               f(:timing_exemption, "x\nTiming: correctness fix (MARCH 13.20)\n", "+| 13.20 | C6 | win back smoke-core and probes |", "| 13.4 | C1 | x |\n") ==
                                   ("correctness fix, MARCH 13.20 (smoke-core, probes)", ["smoke-core", "probes"]),
                               # a row the change does not add (context or an existing row), or one naming no stage, raises
                               (try; f(:timing_exemption, "Timing: correctness fix (MARCH 13.4)", " | 13.4 | C1 | smoke-core |", ""); false; catch; true; end),
                               (try; f(:timing_exemption, "Timing: correctness fix (MARCH 13.20)", "+| 13.20 | C6 | the time |", ""); false; catch; true; end),
                               (try; f(:timing_exemption, "Timing: correctness fix (MARCH 13.99)", "+| 13.4 | C1 | smoke-core |", ""); false; catch; true; end),
                               # an existing row, edited, is a `+` line yet exempts nothing: the number is the base's (A20P26, 36e3966e's form)
                               (try; f(:timing_exemption, "Timing: correctness fix (MARCH 13.18)", "+| 13.18 | C10 | gate: the ratchet stage grew; re-recorded |",
                                       "| 13.17 | all | x |\n| 13.18 | C10 | gate: the ratchet stage grew |\n"); false; catch; true; end),
                               f(:run_verdict, ["x"], String[], String[], false) == "red", f(:run_verdict, ["x"], String[], ["tools"], true) == "red",
                               f(:run_verdict, String[], ["over"], ["tools"], false) == "none", f(:run_verdict, String[], ["over"], String[], true) == "green",
                               f(:run_verdict, String[], ["over"], String[], false) == "red", f(:run_verdict, String[], String[], String[], false) == "green",
                               # past the cap a stage slower than its best is unjudged, a budget missed still fails
                               f(:timing_failures, ["budget"], ["slower"], false, false) == ["budget", "slower"], f(:timing_failures, ["budget"], ["slower"], true, false) == String[],
                               f(:timing_failures, String[], ["slower"], true, false) == String[], f(:timing_failures, String[], ["slower"], false, false) == ["slower"],
                               # a cold run's timing is judged by nothing: its budgets and bests are not failures
                               f(:timing_failures, ["budget"], ["slower"], false, true) == String[], f(:timing_failures, ["budget"], ["slower"], true, true) == String[],
                               # held to the base: a raised budget, a raised best, a removed one, a best raised by a lowered calibration fail; a lowered one passes
                               let tb(bu, be) = Dict("budget" => bu, "best" => be), base = tb(Dict("total" => 60, "smoke-core" => 58), Dict("calibration" => 0.004, "ratchet" => 10.0))
                                   isempty(f(:timing_against_base, base, base)) &&
                                   isempty(f(:timing_against_base, tb(Dict("total" => 60, "smoke-core" => 50), Dict("calibration" => 0.004, "ratchet" => 9.0)), base)) &&
                                   length(f(:timing_against_base, tb(Dict("total" => 60, "smoke-core" => 60), Dict("calibration" => 0.004, "ratchet" => 10.0)), base)) == 1 &&
                                   length(f(:timing_against_base, tb(Dict("total" => 60), Dict("calibration" => 0.004, "ratchet" => 10.0)), base)) == 1 &&
                                   length(f(:timing_against_base, tb(Dict("total" => 60, "smoke-core" => 58), Dict("calibration" => 0.004, "ratchet" => 10.5)), base)) == 1 &&
                                   length(f(:timing_against_base, tb(Dict("total" => 60, "smoke-core" => 58), Dict("calibration" => 0.002, "ratchet" => 10.0)), base)) == 1 &&
                                   isempty(f(:timing_against_base, tb(Dict("total" => 60, "smoke-core" => 58), Dict("calibration" => 0.002, "ratchet" => 5.0)), base))
                               end,
                               # the update's bests: the median of three, one fast run setting none; lowered only, raised for an
                               # exempt stage; a lower calibration rescaling the others first; how each was set (A20P19, A20P20)
                               let b0 = Dict{String,Any}("calibration" => 0.004, "ratchet@warm" => 10.0, "probes@warm" => 6.0), c3 = [0.004, 0.004, 0.004]
                                   first(f(:updated_bests, b0, c3, c3, Dict("ratchet@warm" => [9.0, 8.0, 20.0]), String[]))["ratchet@warm"] == 9.0 &&
                                   first(f(:updated_bests, b0, c3, c3, Dict("ratchet@warm" => [12.0, 11.0, 13.0]), String[]))["ratchet@warm"] == 10.0 &&
                                   first(f(:updated_bests, b0, c3, c3, Dict("ratchet@warm" => [12.0, 11.0, 13.0]), ["ratchet"]))["ratchet@warm"] == 12.0 &&
                                   first(f(:updated_bests, b0, c3, c3, Dict("probes@warm" => [7.0, 7.0, 7.0]), ["ratchet"]))["probes@warm"] == 6.0 &&
                                   last(f(:updated_bests, b0, c3, c3, Dict("ratchet@warm" => [9.0, 8.0, 20.0], "probes@warm" => [7.0, 7.0, 7.0]), String[])) == Dict("ratchet@warm" => :median) &&
                                   let (b, _, h) = f(:updated_bests, b0, [0.002, 0.002, 0.003], c3, Dict{String,Vector{Float64}}(), String[])
                                       b["calibration"] == 0.002 && b["probes@warm"] == 3.0 && h == Dict("calibration" => :median, "ratchet@warm" => :rescaled, "probes@warm" => :rescaled)
                                   end
                               end,
                               # a best's source: the median of the update's records on its commit, or its own source rescaled (A20P20)
                               f(:best_source, :median, "", ["3ee4c795-7", "3ee4c795-8", "3ee4c795-9"], "72dc53fb0000", [1.0, 1.04, 1.1]) ==
                                   "the median of records 3ee4c795-7 3ee4c795-8 3ee4c795-9 on 72dc53fb at machine factor 1.0 1.04 1.1",
                               f(:best_source, :rescaled, "the median of records a; rescaled by records b", ["c"], "d", [1.0]) ==
                                   "the median of records a; rescaled by records c on d at machine factor 1.0",
                               (try; f(:best_source, :rescaled, "", ["c"], "d", [1.0]); false; catch; true; end),
                               # a source is an update's median of three records within FACTOR_CAP; anything else is none (A20P25)
                               f(:source_problem, "the median of records 3ee4c795-7 3ee4c795-8 3ee4c795-9 on 72dc53fb at machine factor 1.0 1.04 1.1") == "",
                               f(:source_problem, "the median of records a1b2c3d4-1 a1b2c3d4-2 a1b2c3d4-3 on 72dc53fb at machine factor 1.0 1.0 1.0; rescaled by records x on y at machine factor 1.2") == "",
                               startswith(f(:source_problem, nothing), "has no"),
                               startswith(f(:source_problem, "one run, record 3ee4c795-6 on 72dc53fb at machine factor 1.0"), "is not the median"),
                               startswith(f(:source_problem, "the median of records 3ee4c795-7 on 72dc53fb at machine factor 1.0"), "is the median of 1 records"),
                               startswith(f(:source_problem, "the median of records 3ee4c795-7 3ee4c795-8 3ee4c795-9 on 72dc53fb at machine factor 1.0 1.54 1.1"), "was recorded past"),
                               startswith(f(:source_problem, "one run; rescaled by records a1b2c3d4-1 a1b2c3d4-2 a1b2c3d4-3 on 72dc53fb at machine factor 1.0 1.0 1.0"), "is not the median"),
                               # a best with no source is re-recorded either way; a calibration with none re-recorded rescales the rest
                               let b0 = Dict{String,Any}("calibration" => 0.004, "ratchet@warm" => 10.0), c3 = [0.004, 0.004, 0.004]
                                   first(f(:updated_bests, b0, c3, c3, Dict("ratchet@warm" => [14.0, 13.0, 15.0]), String[], ["ratchet@warm"]))["ratchet@warm"] == 14.0 &&
                                   let (b, _, h) = f(:updated_bests, b0, [0.005, 0.005, 0.005], c3, Dict{String,Vector{Float64}}(), String[], ["calibration"])
                                       b["calibration"] == 0.005 && b["ratchet@warm"] == 12.5 && h["ratchet@warm"] == :rescaled
                                   end
                               end])
            catch e
                println("    ✗ dev/block.jl does not load for its decisions: ", sprint(showerror, e))
                v += 1
            end
            v
        end),
    "L197_the_loop_is_fast" => ("the full loop, a change from its edit (the earliest author time of the commits a landing brings) to landed (the push of the march branch holding it), takes minutes, measured by the landing itself (Dale 2026-10-21: no strict batch resumes until it does): `dev/land.sh land`, run by a batch's agent in its worktree on its branch, refuses a dirty tree, holds the machine and the landing (dev/.block/HOLD in the main tree with its pid, the machine's one hold, the orchestrator's being the same file with owner 0: one landing at a time, and the agents' Julia scheduler starts no job at any priority while it exists), fetches and rebases onto the march tip (the ratchet baseline merged by dev/merge_baseline.py, any other conflict stopping it, naming the files), refuses a branch more than one commit ahead of the march tip (one landing is one commit, its own tree gated: `merge` judges the head alone, A24E1), refuses a commit with no `Charter:` line or one changing dev/CHARTER.md other than exactly as the maintainer authorised it, no authorisation standing open (A21E6): its `Charter-change: C<a> C<b> … authorised by Dale <date>` line (CHANGE_SED; several clauses in one commit, since L148 counts commits), the change's parent and new dev/CHARTER.md blobs listed with those clauses, as a set, and that date in the main tree's git-ignored dev/.block/charter_authorised (written after review, never by a landing commit; `authorised`), and every changed line in one of those clauses (CLAUSE_AWK, HUNK_AWK, `clause_in`); an edit only adding MARCH row numbers to a Planned citation, as L154 forces, exempt and named, a deleted citation or a deleted word never (EXEMPT_AWK), starts the tree's warm runner when absent (its package image built first in a process of its own, a failed start printing its first error), runs `bash dev/gate.sh --block --warm` to a verdict (a cold run followed by one more, a run with no verdict for another reason by one more after 20 s, a red stopping the landing with its record standing), then lands through `dev/land.sh merge`, its internal step and never a landing path of its own (it refuses unless the landing holding the hold called it, A21E5), which after its push appends the landing's line to the main tree's dev/.loop/landings.tsv (git-ignored; landed_at, commit, author_at, land_start, gate_runs, gate_wall_s, land_wall_s, edit_to_landed_s, files, insertions, timing, own_s, queue_wait_s), and prints each step's wall and `LOOP <own_s> of 300 s (own; queue wait <queue_wait_s> s)`. Here: the landing log each landing carries in its own tree (dev/.loop/landings.log, written by `land` into the branch's head before the gate, A21E4) is a line-by-line prefix of the main tree's git-ignored log, missing at most one landing this tree holds (the tip's own); every landing since 36e3966e has its line (the line of the commit being gated never judged by its own gate: a landing's judgement after its push runs on the landed head) (the lines' commits in the march branch's order, the last its tip, each line's files and insertions git's over its range, so a landing that wrote none changes the next line's numbers), its author_at its range's earliest author time, its edit_to_landed_s landed_at less author_at, split into own_s and queue_wait_s (A30E1, A33E4): own_s a landing's own mechanics, its land's start to its push less its wait for another landing's hold, plus each red of its own checks from its start to the next attempt's, read from the red history (the main tree's git-ignored dev/.loop/reds.tsv, a line per red run written by dev/block.jl with the change's author time, author and subject and whether it is the change's own, kept when a worktree is removed, A33E5), so its gate and its own reds count and the waits for other landings' holds, an audit window, a red on timing alone or on the ratchet's L148 or L197 alone, or a cancelled stack's author time do not; queue_wait_s the rest, reported as its own metric for the orchestrator; and over the last 5 lines, once at least 3 exist (L197_JUDGED_FROM: fewer are printed with the target and pass), the median of own_s inside its band (a line from before A30E1, eleven fields, judged by land_wall_s, its land's start to its push), no excuse taking a landing out of the window (intent: a landing takes minutes, never tens of minutes, Dale 2026-10-21, \"wicked fast, not tens of minutes to hours\"; band: one 300-s target for every change, L197_TARGET, red only past 600 s, L197_BAND, both this lock's literals, never raised); every excuse file (dev/.loop/excuse/<sha8>, one line `machine|lock|crossing: <the measured cause>`, which lifts a red timing's debt, L198, never a wait's, A30E1) is named for a landed commit, holds that one line, and is held to its landing's steps by dev/loop_excuse.sh check (A25E2): a line measured by `land` (written until A30E1, when the writer went) with its every step and refusal as measured and its own time within the target, a hand line's numbers that steps.tsv also measures (`waited N s`: the hold and the commit-to-start time; `N s waiting on the hold`; a step and its seconds) within 10 per cent. A checkout on CI (GITHUB_ACTIONS) has no landing log, the landing machine's: noted, nothing counted. Behavior, run here on fixed text: land.sh's charter programs, a two-clause Charter-change line read and matched to an authorisation listing its clauses in another order, a clause missing, added or a date changed refused, and a change in C0 refused under a line listing C4; a log whose lines cover the history passes; a landing with no line, a slower median of three, a line out of order and an uncovered tip each fail; two lines, one slower, are not judged; one slower of three passes; a single landing whose own_s passes the band is printed as a note naming it, never a failure (the median of five is the cadence, ledger D13); landings slower only by their queue waits pass on their own time, two of three past the band in their own time fail (a median landing of 700 s own fires it), two of three over the target inside the band pass, and the gated commit's own line leaves the window; a line before A30E1 judged by its land's wall; own_s and queue_wait_s that do not split the edit to landed, or a line of twelve fields, fail; the carried copy and the excuse files' form each checked; a change red only on L197 and then landed reads its land's own time, an own red its span to the next attempt, another change's red nothing; dev/loop_excuse.sh check on a scratch log and steps: a measured line passing, edited or for a red timing refused, a hand line with a wrong wait or a wrong hold refused and one with the right wait passing; land.sh holds no excuse writer; every lane develops in a live Kaimon session (Dale 2026-10-21, ledger D39): `land` refuses in its preflight a worktree with no live session, a Kaimon REPL record ~/.cache/kaimon/sock/<id>.json whose project_path is the worktree, whose socket exists and whose pid is alive (dev/kaimon_session.sh), printing the start_session call, a CI checkout exempt, and dev/lane.sh makes a lane's worktree from origin/wt2 with the main tree's Manifest.toml and a LocalPreferences.toml turning the precompile workload off and adds it to Kaimon's projects, every other entry kept (run on a scratch cache: no session, another tree's, a gone socket and a dead pid refuse, a live one passes); `land` prints `LOOP <s> of` the same target; .gitignore tracks the carried log and the excuse directory alone of dev/.loop. Negative-tested: a planted slow line, a malformed excuse file name and a raised target each fire it, and in test/lock_negatives.jl the check's tolerance dropped, and own_s computed with the hold's wait in it, a queue red counted as the change's own, land's session check dropped and a session of another tree taken each fire it, and a planted median over the target inside the band passes (dev/CHARTER.md C10)",
        () -> begin
            local v = 0
            local land = read(joinpath(ROOT, "dev", "land.sh"), String)
            local rx = read(joinpath(ROOT, "test", "parity_ratchet.jl"), String)
            for line in [raw"        set +e; bash dev/gate.sh --block --warm 2>&1 | tee \"$glog\"; st=${PIPESTATUS[0]}; set -e",
                         raw"    LAND_HOLDER=$$ LAND_START=$l_start LAND_OWN_RED=$own_red LAND_HOLD_WAIT=$hold_wait LAND_GATE_RUNS=$runs LAND_GATE_WALL=$gwall bash \"$W/dev/land.sh\" merge \"$br\"",
                         # a landing's own mechanics, never its waits (A30E1): from its change's first red gate run or its
                         # land's start, less its wait for another landing's hold; the waits written beside it
                         raw"    hold_wait=$last_step",
                         # a red attempt's carried landing log takes the tip's on the next rebase, carried again
                         raw"                git checkout --ours -- dev/.loop/landings.log && git add dev/.loop/landings.log",
                         raw"    want=$(git log -1 --format='%at %ae %s' HEAD)",
                         raw"    own_red=$( { sort -t \"$(printf '\t')\" -k1,1n \"$REDS\" 2>/dev/null || true; } | awk -F'\t' -v w=\"$want\" -v au=\"${want%% *}\" -v ls=\"$l_start\" \"$OWN_RED_AWK\")",
                         raw"    own=$(perl -e 'printf \"%.1f\", $ARGV[0] - $ARGV[1] - $ARGV[2] + $ARGV[3]' \"$landed\" \"$start\" \"${LAND_HOLD_WAIT:-0}\" \"${LAND_OWN_RED:-0}\")",
                         # merge is land's internal step alone: it runs only inside the landing holding the hold (A21E5)
                         raw"    [ -n \"${LAND_HOLDER:-}\" ] && [ \"$holder\" = \"$LAND_HOLDER\" ] && kill -0 \"$holder\" 2>/dev/null ||",
                         raw"    [ -z \"$(git status --porcelain)\" ] || { echo \"land: $W has uncommitted or untracked files — refusing\"; git status --short | awk 'NR <= 10'; exit 1; }",
                         raw"    until ( set -o noclobber; echo \"$$ $(iso \"$(now)\") $br\" > \"$HOLD\" ) 2>/dev/null; do",
                         raw"LOG=\"$MAIN/dev/.loop/landings.tsv\"",
                         raw"HOLD=\"$MAIN/dev/.block/HOLD\"",
                         raw"AUTHORISED=\"$MAIN/dev/.block/charter_authorised\"",
                         # the landing log through the previous landing carried in the landing's own tree (A21E4)
                         raw"        mkdir -p dev/.loop && cp \"$LOG\" dev/.loop/landings.log && git add dev/.loop/landings.log" * "\n" * raw"        git commit -q --amend --no-edit",
                         raw"        a=$(printf '%s\n' \"$msg\" | sed -n \"$CHANGE_SED\" | head -1)",
                         raw"        authorised \"$AUTHORISED\" \"$ob\" \"$nb\" \"$a\" ||",
                         raw"            clause_in \"$c\" \"${a% *}\" ||",
                         # one landing is one commit, its own tree gated (A24E1)
                         raw"    ahead=$(git rev-list --count \"$tip..HEAD\")" * "\n" * raw"    [ \"$ahead\" -eq 1 ] ||",
                         raw"        if [ \"$(git diff --word-diff=porcelain --word-diff-regex='[^[:space:]]+' \"$h^\" \"$h\" -- dev/CHARTER.md | awk \"$EXEMPT_AWK\")\" = yes ]; then",
                         raw"STEPS=\"$MAIN/dev/.loop/steps.tsv\"",
                         # a lane develops in a live Kaimon session: land refuses a worktree with none, in its preflight
                         raw"    ks=$(bash dev/kaimon_session.sh \"$W\") || { echo \"land: $ks — refusing\"; exit 1; }",
                         raw"    git push -q origin \"$MARCH\"" * "\n" * raw"    landed=$(now)"]
                v += occursin(line, land) ? 0 : 1
            end
            # the runner it starts builds the tree's package image first, in a process of its own (A20P23)
            v += occursin(raw"    built.exitcode == 0 || (println(stderr, \"block_runner: this tree's package does not load",
                          read(joinpath(ROOT, "dev", "block_runner.jl"), String)) ? 0 : 1
            # the targets are literals, never raised
            v += occursin("const L197_TARGET = 300 ", rx) && occursin("const L197_JUDGED_FROM = 3 ", rx) &&
                 occursin("const L197_BAND = 600 ", rx) ? 0 : 1
            # `land` prints the loop against the same target
            v += occursin(raw"    echo \"LOOP $(printf '%s' \"$line\" | cut -f12) of " * string(L197_TARGET) * raw" s (own; queue wait", land) ? 0 : 1
            # no excuse writer: a wait needs no excuse (A30E1)
            v += occursin("loop_excuse.sh write", land) ? 1 : 0
            v += occursin("\ndev/.loop/*\n!dev/.loop/landings.log\n!dev/.loop/excuse/\n", read(joinpath(ROOT, ".gitignore"), String)) ? 0 : 1
            try
                # land.sh's charter programs, run on fixed text (A21E6)
                local prog = name -> (m = match(Regex("\n" * name * "='([^']+)'\n"), land); m === nothing ? error("dev/land.sh has no $name") : String(m[1]))
                local runawk = (p, text; vars = String[]) -> mktemp() do path, io
                    write(io, text); close(io)
                    readlines(Cmd(vcat(["awk"], vars, [p, path])))
                end
                local cmap = runawk(prog("CLAUSE_AWK"), "intro\n- **C1 · one\n  two\n- **C10 · ten\n  more\n\n## next\n")
                local omap, nmap = tempname(), tempname()
                write(omap, "-\nC1\nC1\nC10\n"); write(nmap, "-\nC1\nC10\nC10\n")
                local hv = ["-v", "O=$omap", "-v", "N=$nmap"]
                local ex = t -> only(runawk(prog("EXEMPT_AWK"), t))
                v += count(!, [cmap == ["-", "C1", "C1", "C10", "C10", "-", "-"],
                               runawk(prog("HUNK_AWK"), "@@ -3 +3 @@\n"; vars = hv) == ["C1", "C10"],
                               runawk(prog("HUNK_AWK"), "@@ -2,1 +1,0 @@\n"; vars = hv) == ["C1"],
                               ex("+13.19,\n") == "yes", ex("-13.18\n+13.18,\n+13.19\n") == "yes", ex("+and\n+13.19\n") == "yes",
                               ex("-13.18\n") == "no", ex("-and\n") == "no", ex("+budget\n") == "no", ex("-13.18\n+13.19\n") == "no"])
                rm(omap; force = true); rm(nmap; force = true)
                # a change to several clauses as one commit: the Charter-change line's clauses and date, the
                # authorisation's clauses matched as a set, every changed line in one of them
                local csed = t -> readchomp(pipeline(Cmd(["sed", "-n", prog("CHANGE_SED")]); stdin = IOBuffer(t * "\n")))
                local shfn = name -> (m = match(Regex("\n" * name * "\\(\\) \\{\n.*?\n\\}\n", "s"), land); m === nothing ? error("dev/land.sh has no $name") : m.match)
                local shok = (name, args...) -> success(Cmd(["bash", "-c", shfn(name) * name * " \"\$@\"", "l197", args...]))
                local af = tempname()
                write(af, "ob1 nb1 C4 C0 2026-10-21\nob2 nb2 C10 2026-10-21\n")
                v += count(!, [csed("Charter-change: C0 C4 C5 authorised by Dale 2026-10-21") == "C0 C4 C5 2026-10-21",
                               csed("Charter-change: C10 authorised by Dale 2026-10-21") == "C10 2026-10-21",
                               csed("Charter-change: C0, C4 authorised by Dale 2026-10-21") == "",
                               csed("Charter-change: authorised by Dale 2026-10-21") == "",
                               shok("authorised", af, "ob1", "nb1", "C0 C4 2026-10-21"), shok("authorised", af, "ob2", "nb2", "C10 2026-10-21"),
                               !shok("authorised", af, "ob1", "nb1", "C0 2026-10-21"), !shok("authorised", af, "ob1", "nb1", "C0 C4 C5 2026-10-21"),
                               !shok("authorised", af, "ob1", "nb1", "C0 C4 2026-10-22"), !shok("authorised", af, "ob2", "nb1", "C0 C4 2026-10-21"),
                               !shok("authorised", af * ".none", "ob1", "nb1", "C0 C4 2026-10-21"),
                               # a line listing C4 while C0 changed refuses
                               !shok("clause_in", "C0", "C4"), shok("clause_in", "C4", "C0 C4"), shok("clause_in", "C10", "C1 C10"),
                               !shok("clause_in", "C1", "C10"), !shok("clause_in", "-", "C4")])
                rm(af; force = true)
                # behavior on fixed text: three commits, the second landing two; each line's own time (own_s)
                # beside its waits (queue_wait_s), the two splitting its edit to landed (A30E1)
                local t0 = _l197_epoch("2026-10-21T14:00:00Z")
                local hist = _l197_history("C aaaaaaaa11 $(t0)\n3\t1\tsrc/a.jl\n\nC bbbbbbbb22 $(t0 + 50)\n2\t0\tdev/x.md\n\nC cccccccc33 $(t0 + 400)\n1\t1\tdev/x.md\n")
                local e2l_of = (landed, author) -> _l197_epoch(landed) - _l197_epoch(author)
                local ln = (c, landed, author, f, i, own) -> join([landed, c, author, landed, "2", "40.0", "60.0",
                                                                   string(e2l_of(landed, author)) * ".0", f, i, "judged",
                                                                   string(own) * ".0", string(e2l_of(landed, author) - own) * ".0"], '\t')
                local ln1 = (c, landed, author, f, i, lw) -> join([landed, c, author, landed, "2", "40.0", lw,
                                                                   string(e2l_of(landed, author)) * ".0", f, i, "judged"], '\t')
                local B2 = ln("bbbbbbbb22", "2026-10-21T14:02:30Z", "2026-10-21T14:00:00Z", "2", "5", 60)
                local good = L197_COLUMNS * "\n" * B2 * "\n" * ln("cccccccc33", "2026-10-21T14:07:20Z", "2026-10-21T14:06:40Z", "1", "1", 40) * "\n"
                local slow = L197_COLUMNS * "\n" * B2 * "\n" * ln("cccccccc33", "2026-10-21T14:12:20Z", "2026-10-21T14:06:40Z", "1", "1", 340) * "\n"
                local gap = L197_COLUMNS * "\n" * ln("cccccccc33", "2026-10-21T14:07:20Z", "2026-10-21T14:00:00Z", "1", "1", 40) * "\n"
                local order = L197_COLUMNS * "\n" * ln("cccccccc33", "2026-10-21T14:07:20Z", "2026-10-21T14:00:00Z", "2", "6", 40) * "\n" *
                              ln("bbbbbbbb22", "2026-10-21T14:08:30Z", "2026-10-21T14:00:00Z", "2", "5", 40) * "\n"
                local partial = L197_COLUMNS * "\n" * B2 * "\n"
                # four commits: the median judged over three lines; c and d land 340 s after their edits
                local hist4 = _l197_history("C aaaaaaaa11 $(t0)\n3\t1\tsrc/a.jl\n\nC bbbbbbbb22 $(t0 + 50)\n2\t0\tdev/x.md\n\nC cccccccc33 $(t0 + 400)\n1\t1\tdev/x.md\n\nC dddddddd44 $(t0 + 600)\n1\t0\tdev/x.md\n")
                local three_at = (lc, ld, oc, od) -> L197_COLUMNS * "\n" * B2 * "\n" * ln("cccccccc33", lc, "2026-10-21T14:06:40Z", "1", "1", oc) * "\n" *
                                                     ln("dddddddd44", ld, "2026-10-21T14:10:00Z", "1", "1", od) * "\n"
                # c and d land 340 s after their edits (three), or 640 s (three_late), past the 600-s band
                local three = (oc, od) -> three_at("2026-10-21T14:12:20Z", "2026-10-21T14:15:40Z", oc, od)
                local three_late = (oc, od) -> three_at("2026-10-21T14:17:20Z", "2026-10-21T14:20:40Z", oc, od)
                local v1three = lw -> L197_COLUMNS_V1 * "\n" * ln1("bbbbbbbb22", "2026-10-21T14:02:30Z", "2026-10-21T14:00:00Z", "2", "5", lw) * "\n" *
                                      ln1("cccccccc33", "2026-10-21T14:12:20Z", "2026-10-21T14:06:40Z", "1", "1", lw) * "\n" *
                                      ln1("dddddddd44", "2026-10-21T14:15:40Z", "2026-10-21T14:10:00Z", "1", "1", lw) * "\n"
                v += count(!, [isempty(first(l197_check(good, hist))), length(last(l197_check(good, hist))) == 2,
                               # fewer than 3 lines in the window: not judged, a slower one included
                               isempty(first(l197_check(slow, hist))),
                               # two of three past the band in their own time: failed; one of three: passed; two of three
                               # over the 300-s target inside the 600-s band: minutes still, passed
                               !isempty(first(l197_check(three_late(640, 640), hist4))), isempty(first(l197_check(three_late(640, 40), hist4))),
                               isempty(first(l197_check(three(340, 340), hist4))),
                               length(last(l197_check(three(40, 40), hist4))) == 3,
                               # a single landing past the band is noted, never failed
                               only(l197_slow_notes(three(40, 40) * ln("eeeeeeee55", "2026-10-21T14:30:00Z", "2026-10-21T14:10:00Z", "1", "1", 700) * "\n")) ==
                                   "eeeeeeee took 700.0 s of its own, past the 600-s band: reported, the median of five judges",
                               isempty(l197_slow_notes(three(40, 40))),
                               # the median landing's own steps take 700 s, past the 600-s band: fired
                               !isempty(first(l197_check(three_at("2026-10-21T14:18:20Z", "2026-10-21T14:21:40Z", 700, 700), hist4))),
                               # past the band only by their waits (600 s each in queue_wait_s): judged by their own 40 s, passed
                               isempty(first(l197_check(three_late(40, 40), hist4))),
                               # the gated commit's own line is out of its own window
                               isempty(first(l197_check(three_late(640, 640), hist4; head = "dddddddd44"))),
                               # a line before A30E1 (eleven fields) judged by its land's wall
                               isempty(first(l197_check(v1three("60.0"), hist4))), !isempty(first(l197_check(v1three("700.0"), hist4))),
                               # own_s and queue_wait_s that do not split the edit to landed, and a line of twelve fields, fail
                               !isempty(first(l197_check(replace(good, "\t40.0\t0.0\n" => "\t40.0\t90.0\n"), hist))),
                               !isempty(first(l197_check(replace(good, "\t40.0\t0.0\n" => "\t40.0\n"), hist))),
                               !isempty(first(l197_check(gap, hist))),
                               !isempty(first(l197_check(order, hist))),
                               !isempty(first(l197_check(partial, hist))),
                               isempty(first(l197_check("", hist[1:0]))),
                               !isempty(first(l197_check("", hist))),
                               _l197_epoch("1970-01-01T00:00:00Z") == 0, _l197_epoch("2026-10-21T14:00:00Z") == 1792591200])
                # a change's own reds over the red history (A33E4): a red only on L197 (a queue red) adds
                # nothing, so a change red only on L197 and then landed reads its land's own time, low; an own
                # red counts from its start to the next attempt's; another change's red counts nothing
                local Wd = "1000 a@b fix: x"
                local orw = text -> only(runawk(prog("OWN_RED_AWK"), text; vars = ["-F", "\t", "-v", "w=$Wd", "-v", "au=1000", "-v", "ls=3000"]))
                v += count(!, [orw("1500\th\t$Wd\tqueue\tratchet on L197 alone\tr-1\n") == "0.0",
                               orw("1500\th\t$Wd\town\ttests\tr-1\n") == "1500.0",
                               orw("1500\th\t$Wd\town\ttests\tr-1\n2500\th\t$Wd\tqueue\ttiming alone\tr-2\n") == "1000.0",
                               orw("1500\th\t999 x@y other\town\ttests\tr-1\n") == "0.0"])
                # the carried copy (A21E4): a prefix missing only the tip's own line passes; an edited earlier
                # line, or two of this tree's landings missing, fail
                local cl = c -> "2026-10-21T14:00:00Z\t" * c * "\tx"
                local A = repeat("a", 40); local B = repeat("b", 40); local C = repeat("c", 40)
                local U = [L197_COLUMNS, cl(A), cl(B), cl(C)]
                v += count(!, [isempty(l197_carried(U, U, c -> true)), isempty(l197_carried(U[1:3], U, c -> true)),
                               !isempty(l197_carried(U[1:2], U, c -> true)), isempty(l197_carried(U[1:2], U, c -> c == B)),
                               !isempty(l197_carried([U[1], cl(A) * "y", U[3]], U, c -> true)), !isempty(l197_carried(String[], U, c -> true))])
                # the excuse files: one line of a kind outside the change, for a landed commit
                local ok_ex = "lock: waited 600 s behind two landings, then landed in 70 s"
                v += count(!, [isempty(l197_excuse_problems(Dict("aaaaaaaa" => ok_ex * "\n"), [A])),
                               !isempty(l197_excuse_problems(Dict("bbbbbbbb" => ok_ex), [A])),
                               !isempty(l197_excuse_problems(Dict("aaaaaaaa" => "slow, sorry"), [A])),
                               !isempty(l197_excuse_problems(Dict("aaaaaaaa" => ok_ex * "\n" * ok_ex), [A])),
                               !isempty(l197_excuse_problems(Dict("aaaaaaaa" => "change: the commit was large and compiled for long"), [A])),
                               !isempty(l197_excuse_problems(Dict("aaaa" => ok_ex), [A]))])
                # an excuse file (it lifts a red timing's debt, L198) held to its landing's steps by
                # dev/loop_excuse.sh check (A25E2), on a scratch landing log and steps: a hand line's numbers
                # within 10 per cent, a line measured by land (until A30E1) as measured, never for a red timing
                mktempdir() do t
                    local E = repeat("e", 40); local F = repeat("f", 40); local D = repeat("d", 40)
                    local lx = (c, landed, start, e2l, timing) -> join([landed, c, "2026-10-21T14:00:00Z", start, "1", "40.0", "60.0", e2l, "1", "1", timing], '\t')
                    local logp = joinpath(t, "landings.tsv"); local stepsp = joinpath(t, "steps.tsv")
                    write(logp, join([L197_COLUMNS_V1, lx(E, "2026-10-21T14:12:00Z", "2026-10-21T14:10:00Z", "720.0", "judged"),
                                      lx(F, "2026-10-21T14:10:00Z", "2026-10-21T14:00:05Z", "600.0", "judged"),
                                      lx(D, "2026-10-21T14:10:00Z", "2026-10-21T14:00:05Z", "600.0", "SLOWER ratchet@warm")], '\n') * "\n")
                    local st = (c, h) -> join(["$c\thold\t$h", "$c\trunner\t0.5", "$c\tgate-1\t40.0", "$c\tland\t8.0"], '\n')
                    write(stepsp, join([st(E, "0.1"), st(F, "500.0"), st(D, "500.0")], '\n') * "\n")
                    local sh = joinpath(ROOT, "dev", "loop_excuse.sh")
                    local ck = (name, text) -> mktemp() do path, io
                        write(io, text * "\n"); close(io)
                        readchomp(Cmd(Cmd(["bash", sh, "check", logp, stepsp, name, path]); dir = ROOT))
                    end
                    local lF = "lock: measured by dev/land.sh land: edit to landed 600.0 s; hold 500.0 s; runner 0.5 s; gate-1 40.0 s; its own 100.0 s of the 300 s target"
                    v += count(!, [isempty(ck("ffffffff", lF)),
                                   !isempty(ck("ffffffff", replace(lF, "hold 500.0 s" => "hold 50.0 s"))),
                                   !isempty(ck("dddddddd", lF)),
                                   !isempty(ck("eeeeeeee", "lock: waited 900 s behind the slot order before its land began")),
                                   isempty(ck("eeeeeeee", "lock: waited 600 s behind the slot order before its land began")),
                                   !isempty(ck("ffffffff", "lock: 50 s of its 600 s waiting on the one hold behind another landing"))])
                end
                # every lane develops in a live Kaimon session (dev/kaimon_session.sh), which `land` requires in
                # its preflight: on a scratch Kaimon cache, no session refuses, a session of another tree refuses,
                # one whose socket is gone or whose pid is dead refuses, a live one of this tree passes, and a CI
                # checkout runs none; dev/lane.sh makes a lane's worktree a Kaimon project, its other entries kept
                mktempdir() do t
                    local wt = mkpath(joinpath(t, "wt")); local other = mkpath(joinpath(t, "other")); local sk = mkpath(joinpath(t, "c", "sock"))
                    local ks = (env...) -> Base.run(pipeline(ignorestatus(addenv(`bash $(joinpath(ROOT, "dev", "kaimon_session.sh")) $wt $(joinpath(t, "c"))`,
                                                                                 "GITHUB_ACTIONS" => "", env...)); stdout = devnull)).exitcode
                    local sess = (id, tree, pid) -> (write(joinpath(sk, "$id.json"), "{\"pid\": $pid, \"session_id\": \"$id\", \"project_path\": \"$tree\", " *
                                                           "\"endpoint\": \"ipc://$(joinpath(sk, id)).sock\"}"); joinpath(sk, "$id.sock"))
                    local none = ks()
                    touch(sess("s1", other, getpid())); local elsewhere = ks()
                    local p2 = sess("s2", wt, getpid()); local nosock = ks()
                    touch(p2); local live = ks()
                    sess("s2", wt, 999999); local dead = ks()
                    v += count(!, [none == 1, elsewhere == 1, nosock == 1, live == 0, dead == 1, ks("GITHUB_ACTIONS" => "true") == 0])
                end
                local lanesh = read(joinpath(ROOT, "dev", "lane.sh"), String)
                v += occursin("git -C \"\$MAIN\" worktree add -q -b \"\$name\" \"\$WT\" \"origin/\$MARCH\"", lanesh) &&
                     occursin("\"launch_config\": {\"threads\": \"4\", \"startup_file\": False", lanesh) &&
                     occursin("ps = [p for p in d.get(\"projects\", []) if p.get(\"project_path\") != wt]", lanesh) ? 0 : 1
                if get(ENV, "GITHUB_ACTIONS", "") == "true"
                    println("    · L197: a CI checkout: the landing log is the landing machine's; nothing counted here")
                else
                    local mt = nothing; local cur = ""
                    for l in split(readchomp(`git -C $ROOT worktree list --porcelain`), '\n')
                        startswith(l, "worktree ") && (cur = l[10:end])
                        l == "branch refs/heads/wt2" && (mt = cur)
                    end
                    if mt === nothing
                        println("    ✗ L197: no worktree holds wt2, so there is no landing log to read")
                        v += 1
                    else
                        local tip = readchomp(`git -C $ROOT rev-parse wt2`)
                        local real = _l197_history(readchomp(`git -C $ROOT log --reverse --no-merges --numstat --format='C %H %at' $(L197_START)..$tip`))
                        local logp = joinpath(mt, "dev", ".loop", "landings.tsv")
                        local exfiles = l197_excuses(ROOT)
                        # every excuse file held to its landing's steps (A25E2); none takes a landing out of the window (A30E1)
                        local mbad, _ = l197_excuse_measured(ROOT, logp, joinpath(mt, "dev", ".loop", "steps.tsv"), exfiles)
                        local bad, window = l197_check(isfile(logp) ? read(logp, String) : "", real;
                                                       head = readchomp(`git -C $ROOT rev-parse HEAD`))
                        append!(bad, l197_excuse_problems(exfiles, first.(real)))
                        append!(bad, mbad)
                        # the copy each landing carries in its own tree (A21E4)
                        local tp = joinpath(ROOT, "dev", ".loop", "landings.log")
                        local lines_of = t -> String.(filter(!isempty, split(t, '\n')))
                        append!(bad, l197_carried(isfile(tp) ? lines_of(read(tp, String)) : String[],
                                                  isfile(logp) ? lines_of(read(logp, String)) : String[],
                                                  c -> success(`git -C $ROOT merge-base --is-ancestor $c HEAD`)))
                        foreach(b -> println("    ✗ L197: ", b), bad)
                        isfile(logp) && foreach(n -> println("    · L197 note: ", n), l197_slow_notes(read(logp, String)))
                        println("    · L197: $(length(real)) commits landed since $(first(L197_START, 8)); the window ",
                                isempty(window) ? "is empty" : join((first(c, 8) * " " * string(round(x; digits = 2)) for (c, x) in window), ", "),
                                length(window) < L197_JUDGED_FROM ? " (own time over its target, $L197_TARGET s: fewer than $L197_JUDGED_FROM lines, not judged)" : "")
                        v += length(bad)
                    end
                end
            catch e
                println("    ✗ L197: ", sprint(showerror, e))
                v += 1
            end
            v
        end),
    "L198_timing_is_recorded" => ("a landing whose timing the gate could not judge says so, and the streak of such landings is shown at every landing until a judged run ends it, never forgotten (Dale 2026-10-21; the machine's working floor is other work, so a cap that refused would stall the loop): the blocking gate leaves a run's timing ratchet unjudged on a machine more than FACTOR_CAP times slower than its best (L195: `timing = \"unjudged\"` in its record, `judged` otherwise), `dev/land.sh merge` writes the record's timing into the landing log's `timing` column (a record from before the rule judged), a cold run whose checks pass is green with its timing unjudged and `dev/land.sh land` lands on it, prints `LOOP <s> of 300 s` right after the push, then, still holding the machine, judges the timing by a warm run of the landed tree (`--base` the tip it landed on) and writes it into the landing's line: judged; unjudged (past the cap, with the reason its record gives); SLOWER <stages> and OVER <stages> for bests and budgets missed under the cap (the record's `timing_slower`, `timing_over`); FAILED <stages> for any check that failed, the ratchet's included (`checks_failed`; a lock red on the landed head though the cold run passed it, A21E1), its red record standing; after a line judged red the next landing lands on a judged green run (`land` runs the gate once more rather than land a cold run, and `merge` refuses a record whose timing is not judged) or carries the red landing's excuse file, dev/.loop/excuse/<sha8>, in its own tree (a cause outside the change, or a `Timing: correctness fix` row's), which lifts a timing debt, SLOWER or OVER, so no timing rule needs a quiet machine to be met; a FAILED debt no excuse lifts: the next landing lands only as a fix, green on a warm run (`land` runs a cold run once more, `merge` refuses a record whose runner_state is not warm, A21E1); `land` refuses a worktree whose Manifest.toml names other WasmTarget extensions than Project.toml (a stale manifest's image build fails, A20P23), printing the resolve command; and `land` prints the unjudged streak, `timing unjudged for N landing(s); judge on a quiet machine: bash dev/gate.sh --block --warm`: the log's last lines in a row whose timing is unjudged, counted newest first until one whose commit's tree has a green run with its timing judged recorded in any worktree. Here: those steps in dev/land.sh and dev/block.jl, every line of the main tree's landing log with a timing, and land.sh's own streak program run on fixed text: three unjudged lines after a judged one give those three newest first, a judged last line none, an empty log none; and its owed program: a last line SLOWER or FAILED names it, a judged or unjudged one and an empty log none; and its lift program on a scratch repository: a dev/MARCH.md row naming the red landing lifts nothing, its excuse file lifts SLOWER and OVER, never FAILED, nor another landing's debt. Negative-tested: the record's field, the streak's count, the owed program, the merge's refusal, a lift read from dev/MARCH.md's text, an excuse lifting a FAILED debt and the ratchet's check dropped from FAILED each broken fire it, and a planted SLOWER line made `dev/land.sh merge` refuse a cold-green record; intent: a landing whose timing nobody judged is seen at every landing until a judged run ends it; band: every unjudged landing counts, a judged red holds the next landing until it is judged or excused (dev/CHARTER.md C10)",
        () -> begin
            local v = 0
            local land = read(joinpath(ROOT, "dev", "land.sh"), String)
            local blk = read(joinpath(ROOT, "dev", "block.jl"), String)
            v += occursin("    timing = cold ? \"unjudged (cold)\" :\n", blk) && occursin("\"timing\" => timing, \"timing_failed\" => timing_failed,", blk) ? 0 : 1
            for line in [raw"    timing=$(sed -n 's/^timing = \"\(.*\)\"$/\1/p' \"$rec\"); timing=${timing:-judged}",
                         raw"\"$e2l\" \"$files\" \"$ins\" \"$timing\" \"$own\"",
                         raw"                [ -f \"$f\" ] && grep -qx 'verdict = \"green\"' \"$f\" && grep -qx 'timing = \"judged\"' \"$f\" && judged=1",
                         raw"        [ $judged -eq 0 ] || break",
                         raw"        echo \"land: timing unjudged for $unjudged landing(s); judge on a quiet machine: bash dev/gate.sh --block --warm\"",
                         raw"OWED_AWK='NR == 1 && $11 ~ /^(SLOWER|OVER|FAILED)/ { print substr($2, 1, 8) \" \" $11 }'",
                         raw"owed_lifted() { case \"${2#* }\" in FAILED*) return 1 ;; esac",
                         raw"                git cat-file -e \"$1:dev/.loop/excuse/${2:0:8}\" 2>/dev/null; }",
                         # a failed check's debt: only a fix, green on a warm run (A21E1)
                         raw"        grep -qx 'runner_state = \"warm\"' \"$rec\" ||",
                         raw"    owed=$(tail -n 1 \"$LOG\" 2>/dev/null | awk -F'\t' \"$OWED_AWK\" || true)" * "\n" * raw"    case \"${owed#* }\" in FAILED*)",
                         raw"    if [ -n \"$owed\" ] && [ \"$timing\" != judged ]; then" * "\n" * raw"        if owed_lifted \"$head\" \"$owed\"; then",
                         raw"    if [ -n \"$owed\" ] && owed_lifted HEAD \"$owed\"; then",
                         raw"               chk=$(field checks_failed)",
                         raw"    [ \"$want\" = \"$have\" ] ||",
                         raw"        0) if grep -q '^BLOCK green (timing unjudged: the run was cold' \"$glog\"; then",
                         raw"            set +e; bash dev/gate.sh --block --warm --base \"$tip\" 2>&1 | tee \"$glog\"; st=${PIPESTATUS[0]}; set -e",
                         raw"        awk -F'\t' -v OFS='\t' -v n=\"$n\" -v h=\"$head\" -v t=\"$verdict_t\" 'NR == n && $2 == h { $11 = t } { print }' \"$LOG\" > \"$LOG.new\""]
                v += occursin(line, land) ? 0 : 1
            end
            try
                # land.sh's streak program, run on fixed logs
                local m = match(r"for c in \$\(awk -F'\\t' '([^']+)' \"\$LOG\"\)", land)
                m === nothing && error("dev/land.sh has no streak program")
                local streak = log -> mktemp() do path, io
                    write(io, log); close(io)
                    split(readchomp(`awk -F'\t' $(m[1]) $path`))
                end
                local hd = L197_COLUMNS * "\n"
                local ln = (c, t) -> join(["2026-10-21T14:02:30Z", c, "2026-10-21T14:00:00Z", "2026-10-21T14:01:00Z", "1", "30.0", "90.0", "150.0", "1", "1", t], '\t') * "\n"
                local three = hd * ln("aaaaaaaa", "judged") * ln("bbbbbbbb", "unjudged") * ln("cccccccc", "unjudged") * ln("dddddddd", "unjudged")
                # the push is the landing: LOOP printed before the warm judgement, the hold released after it
                local iL = findfirst("    echo \"LOOP ", land); local iJ = findfirst(raw"    if [ $cold_green -eq 1 ]; then", land)
                local iR = findnext("    release\n", land, something(iJ, 1:1).stop)
                v += iL !== nothing && iJ !== nothing && iR !== nothing && iL.start < iJ.start < iR.start ? 0 : 1
                local om = match(r"\nOWED_AWK='([^']+)'\n", land)
                om === nothing && error("dev/land.sh has no owed program")
                local owed = log -> mktemp() do path, io
                    write(io, last(split(chomp(log), '\n'))); close(io)
                    readchomp(`awk -F'\t' $(om[1]) $path`)
                end
                v += count(!, [owed(three * ln("eeeeeeee", "SLOWER probes ratchet")) == "eeeeeeee SLOWER probes ratchet",
                               owed(three * ln("eeeeeeee", "OVER total")) == "eeeeeeee OVER total",
                               isempty(l198_check(three * ln("eeeeeeee", "SLOWER probes OVER total"))),
                               !isempty(l198_check(three * ln("eeeeeeee", "FAILED"))),
                               owed(three * ln("eeeeeeee", "FAILED smoke-core")) == "eeeeeeee FAILED smoke-core",
                               isempty(owed(three)), isempty(owed(three * ln("eeeeeeee", "judged"))), isempty(owed(hd)),
                               isempty(l198_check(three * ln("eeeeeeee", "SLOWER probes")))])
                v += count(!, [streak(three) == ["dddddddd", "cccccccc", "bbbbbbbb"],
                               isempty(streak(three * ln("eeeeeeee", "judged"))),
                               streak(three * ln("eeeeeeee", "judged") * ln("ffffffff", "unjudged")) == ["ffffffff"],
                               isempty(streak(hd)),
                               isempty(l198_check(three)), !isempty(l198_check(hd * ln("aaaaaaaa", "")))])
                # land.sh's lift program on a scratch repository (A22E1): a tree whose dev/MARCH.md names the
                # red landing lifts nothing; its excuse file lifts a timing debt (SLOWER, OVER), never a FAILED one
                local lm = match(r"\nowed_lifted\(\) \{.*?; \}\n"s, land)
                lm === nothing && error("dev/land.sh has no lift program")
                mktempdir() do t
                    local gitq = args -> Base.run(pipeline(`git -C $t -c user.name=l198 -c user.email=l198@localhost $args`; stdout = devnull, stderr = devnull))
                    gitq(`init -q`)
                    mkpath(joinpath(t, "dev", ".loop", "excuse"))
                    write(joinpath(t, "dev", "MARCH.md"), "| 13.99 | C10 | eeeeeeee was slower: its runner was cold | x |\n")
                    gitq(`add -A`); gitq(`commit -q -m row`)
                    local byrow = readchomp(`git -C $t rev-parse HEAD`)
                    write(joinpath(t, "dev", ".loop", "excuse", "eeeeeeee"), "lock: waited 600 s behind two landings, then landed in 70 s\n")
                    gitq(`add -A`); gitq(`commit -q -m file`)
                    local byfile = readchomp(`git -C $t rev-parse HEAD`)
                    local lifted = (c, o) -> success(Cmd(`bash -c $(lm.match * "owed_lifted \"\$1\" \"\$2\"") l198 $c $o`; dir = t))
                    v += count(!, [!lifted(byrow, "eeeeeeee SLOWER probes"), !lifted(byrow, "eeeeeeee OVER total"),
                                   lifted(byfile, "eeeeeeee SLOWER probes"), lifted(byfile, "eeeeeeee OVER total"),
                                   !lifted(byfile, "eeeeeeee FAILED ratchet"), !lifted(byfile, "ffffffff SLOWER probes")])
                end
                if get(ENV, "GITHUB_ACTIONS", "") != "true"
                    local mt = nothing; local cur = ""
                    for l in split(readchomp(`git -C $ROOT worktree list --porcelain`), '\n')
                        startswith(l, "worktree ") && (cur = l[10:end])
                        l == "branch refs/heads/wt2" && (mt = cur)
                    end
                    local logp = mt === nothing ? "" : joinpath(mt, "dev", ".loop", "landings.tsv")
                    local bad = isfile(logp) ? l198_check(read(logp, String)) : String[]
                    foreach(b -> println("    ✗ L198: ", b), bad)
                    v += length(bad)
                end
            catch e
                println("    ✗ L198: ", sprint(showerror, e))
                v += 1
            end
            v
        end),
    "L154_planned_cites_rows" => ("a clause's Planned text cites dev/MARCH.md rows, never findings, and every row names its clauses: no finding ID in any clause's Planned text; every row it cites exists; each row names in its Clause column exactly the clauses whose Planned cites it, and a row that names none (1.M the merge, 1.P post-merge) is cited by none; and every finding the latest dev/AUDIT.md entry's Resolution leaves open on a row (a MARCH row 1.<x> or a ledger row D<n>) sits on that row, until a commit after the entry's own carries a `Fixes:` line naming it, and every row it names exists (A32E3). Audits then lengthen MARCH rows and their own entries, not the charter (A3P4). Behavior, run here: a planted entry's five open findings, read, and four planted rows and fixes answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local rx = r"\b(A\d+[A-Z]\d+|[BEHMPS]\d+)\b"
            local rowid = r"\b1\.[A-Z]\d*[a-z]?\b"
            local charter = read(joinpath(ROOT, "dev", "CHARTER.md"), String)
            local plan = read(joinpath(ROOT, "dev", "MARCH.md"), String)
            local rows = Dict{String,Set{String}}()
            for l in split(plan, '\n')
                local m = match(r"^\| (1\.[A-Z]\d*[a-z]?) \| ([^|]*) \|", l)
                m === nothing && continue
                rows[m.captures[1]] = Set(String[x.match for x in eachmatch(r"C\d+", m.captures[2])])
            end
            local v = 0
            local cites = Dict{String,Set{String}}()
            for blk in split(charter, r"\n(?=- \*\*C\d+)")
                local h = match(r"^- \*\*(C\d+)", blk)
                h === nothing && continue
                local i = findfirst("Planned:", blk)
                i === nothing && continue
                local seg = blk[first(i):end]
                local j = findfirst("\n## ", seg)
                j === nothing || (seg = seg[1:first(j)])
                v += length(collect(eachmatch(rx, seg)))
                for r in eachmatch(rowid, seg)
                    haskey(rows, r.match) || (v += 1)
                    push!(get!(cites, r.match, Set{String}()), h.captures[1])
                end
            end
            for (r, cs) in rows
                cs == get(cites, r, Set{String}()) || (v += 1)
            end
            local f = vcat(findings_off_row_here(), findings_negatives_missed())
            foreach(x -> println("    ✗ ", x), f)
            v + length(f)
        end),
    "L148_changes_are_audited" => ("every change is audited against the charter before it lands (AGENTS.md, the anti-drift audit): every dev/AUDIT.md entry names the commit it audited through, an ancestor of HEAD, and each entry's range starts at the one before it (the entries chain, A2P5); the last is at most 5 commits behind HEAD, merges not counted, as dev/audit_window.sh counts it, the one program `dev/land.sh land` runs before its hold too (the march tip's last entry, or the landing's own when it adds the next one, as this lock judges the landing's rebased tree, the commits past it and the landing's own), so a landing into a full window refuses in its preflight, naming the audit to wait for, never after a gate run, and the entry that empties a full window lands (A31E1) (run here on a scratch repository: five commits past the entry fit, a sixth or the landing's own beyond five fills it, and in a full window a landing adding the next entry fits where one adding none is refused); and every entry covers the four areas (builder; collection and planning; emission and diagnostics; enforcement and prose) with its findings and how each was resolved. With no git history the check fails, never skips; intent: every change is read against the charter soon after it lands (Dale 2026-09-30); band: at most 5 commits behind the head, its edge (dev/CHARTER.md C0)",
        () -> begin
            local audit = joinpath(ROOT, "dev", "AUDIT.md")
            isfile(audit) || return 1
            local txt = read(audit, String)
            local entries = split(txt, r"\n(?=## )")[2:end]
            isempty(entries) && return 1
            local v = 0
            for e in entries
                for area in ("Area: builder", "Area: collection and planning",
                             "Area: emission and diagnostics", "Area: enforcement and prose")
                    occursin(area, e) || (v += 1)
                end
                occursin("Resolution:", e) || (v += 1)
            end
            # the entries chain: each one's range starts where the one before it was audited
            # through, and every audited-through commit is an ancestor of HEAD (a rewritten
            # history fails, never skips: A2P5)
            local prev = nothing
            local sha = nothing
            for e in entries
                local m = match(r"audited through ([0-9a-f]{8,40})", e)
                m === nothing && (v += 1; continue)
                sha = m.captures[1]
                success(`git -C $ROOT merge-base --is-ancestor $sha HEAD`) || (v += 1)
                if prev !== nothing
                    local r = match(r"\(([0-9a-f]{7,40})(?:~1)?\.\.", e)
                    (r !== nothing && (startswith(prev, r.captures[1]) || startswith(r.captures[1], prev))) || (v += 1)
                end
                prev = sha
            end
            sha === nothing && return v + 1
            success(`git -C $ROOT merge-base --is-ancestor $sha HEAD`) || return v   # counted above
            # the window, by the one program `dev/land.sh land`'s preflight runs too (dev/audit_window.sh):
            # the commits since the last audited one, merges not counted (a pull request's merge checkout
            # and a landed march branch count the same), at most its cap of 5, its last entry this lock's
            local wsh = joinpath(ROOT, "dev", "audit_window.sh")
            local w = split(readchomp(ignorestatus(`bash $wsh $ROOT`)))
            v += length(w) == 4 && w[1] == sha && w[3] == "5" && parse(Int, w[2]) <= 5 ? 0 : 1
            # land refuses a full window in its preflight, before the hold, by the same program
            local landsh = read(joinpath(ROOT, "dev", "land.sh"), String)
            v += occursin(raw"    if ! win=$(bash dev/audit_window.sh \"$W\"); then", landsh) ? 0 : 1   # again after the rebase
            v += occursin(raw"    if ! win=$(bash dev/audit_window.sh \"$W\" \"origin/$MARCH\" \"$(git rev-list --count --no-merges \"origin/$MARCH..HEAD\")\" HEAD); then", landsh) &&
                 occursin(raw"wait for audit #$((wentries + 1)) — refusing\"; exit 1", landsh) ? 0 : 1
            # behavior on a scratch repository: an entry audited through its first commit, then commits;
            # five past it fit, a sixth fills the window, and the landing's own commit counts; in a full
            # window a landing adding the next entry is counted from its own dev/AUDIT.md and fits, a
            # landing adding none is refused (A31E1)
            v += mktempdir() do t
                local g = (args...) -> Base.run(pipeline(`git -C $t -c user.email=l@l -c user.name=l -c commit.gpgsign=false $args`; stdout = devnull, stderr = devnull))
                g("init", "-q"); mkpath(joinpath(t, "dev"))
                write(joinpath(t, "f"), "0"); g("add", "f"); g("commit", "-qm", "c0")
                local c0 = readchomp(`git -C $t rev-parse HEAD`)
                write(joinpath(t, "dev", "AUDIT.md"), "# Audit\n\n## entry — audited through $(c0[1:8])\n")
                g("add", "dev/AUDIT.md"); g("commit", "-qm", "c1")
                for k in 2:5
                    write(joinpath(t, "f"), string(k)); g("commit", "-qam", "c$k")
                end
                local st = (args...) -> Base.run(pipeline(ignorestatus(`bash $wsh $t $args`); stdout = devnull)).exitcode
                local five = st(); local five_own = st("HEAD", "1")
                local c5 = readchomp(`git -C $t rev-parse HEAD`)
                write(joinpath(t, "dev", "AUDIT.md"), "# Audit\n\n## entry — audited through $(c0[1:8])\n\n## entry — audited through $(c5[1:8])\n")
                g("commit", "-qam", "audit"); local ca = readchomp(`git -C $t rev-parse HEAD`)
                g("reset", "-q", "--hard", c5)
                write(joinpath(t, "f"), "p"); g("commit", "-qam", "plain"); local cp = readchomp(`git -C $t rev-parse HEAD`)
                g("reset", "-q", "--hard", c5)
                local own_entry = st(c5, "1", ca); local own_plain = st(c5, "1", cp)
                write(joinpath(t, "f"), "6"); g("commit", "-qam", "c6")
                count(!, [five == 0, five_own == 1, own_entry == 0, own_plain == 1, st() == 1, st("HEAD", "0") == 1])
            end
            return v
        end),
    "L129_plan_holds_only_open_work" => ("dev/MARCH.md lists open work only — at most 60 lines, no finished row (`| done |`) and no results section — and dev/HISTORY.md stays an archive of short entries (at most 160 lines, each `## ` entry at most 25). Finished work leaves the plan in the commit that closes it; results live in commit messages and this harness's output; intent: the plan and the history stay short enough to read whole; band: the caps above, their edge (dev/CHARTER.md C9)",
        () -> begin
            v = String[]
            plan = _lines(joinpath(ROOT, "dev", "MARCH.md"))
            length(plan) <= 60 || push!(v, "dev/MARCH.md has $(length(plan)) lines (cap 60)")
            for (i, l) in enumerate(plan)
                (occursin(r"\|\s*done\s*\|"i, l) || occursin(r"^#+ .*\bresults?\b"i, l)) &&
                    push!(v, "dev/MARCH.md:$i holds finished work: $(first(l, 60))")
            end
            hist = _lines(joinpath(ROOT, "dev", "HISTORY.md"))
            length(hist) <= 160 || push!(v, "dev/HISTORY.md has $(length(hist)) lines (cap 160)")
            starts = [i for (i, l) in enumerate(hist) if startswith(l, "## ")]
            for (k, i) in enumerate(starts)
                n = (k < length(starts) ? starts[k + 1] : length(hist) + 1) - i
                n <= 25 || push!(v, "dev/HISTORY.md entry at line $i is $n lines (cap 25)")
            end
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    # ── the NIR boundary (frontend/nir.jl) is codegen's one reader of Julia's typed IR ──
    "L126_ratchets_terminate_at_zero" => ("dev/CHARTER.md rule 2: a ratchet's only terminal state is 0. No ratchet description may declare a floor or its sites legitimate/reclassified — a site that belongs moves into an exact per-site allowlist with its anchor, a reviewable diff",
        () -> count(p -> occursin(r"floor|legitimate|reclassif"i, first(last(p))), METRICS)),
    "L202_constructions_have_precedents" => ("every closed sum or construction in src carries its precedent, as every definition carries its parity anchor (R32): each @enum, each `@closed` sum and each definition a STRICT_KINDS construction names has `precedent(<ecosystem>: <mechanism>[, <anchor>])` on its line, in the docstring directly above it or in the comment lines above that (Rust's sealed enums and exhaustive match, dart's enums and sealed classes, wasm's types); an abstract type is an open hierarchy, neither a closed sum nor a construction, and carries its parity(...) alone; one with no precedent anywhere is an invention and waits for Dale (2026-10-21). Behavior, run here: eight planted definitions answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local v = vcat(precedent_missing_in_src(), precedent_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L203_audit_asks_disguise_and_precedent" => ("each dev/AUDIT.md entry from the L203_FIRST_ENTRY-th on whose range changes src or ext carries a `stopgap in disguise:` line (is a claimed construction a scan, an allowlist or a test?) and a `precedent:` line (which ecosystem holds each closed sum or construction it audits?); with no git history an entry counts as changing src (Dale 2026-10-21). Behavior, run here: five planted entries answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local audit = joinpath(ROOT, "dev", "AUDIT.md")
            local entries = isfile(audit) ? split(_text(audit), r"\n(?=## )")[2:end] : String[]
            local v = vcat(audit_lines_missing(entries; touches_src=audit_range_touches_src), audit_lines_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L204_requirements_are_checks" => ("Dale's requirements are the rows of dev/LEDGER.md, each in his words with its date, its why and the checks that enforce it (Dale 2026-10-21: \"MAKE SURE you actually bake our reqs INTO programmatic checks — not just hoping that memory works\"): dev/CHARTER.md names dev/LEDGER.md; its rows run D1, D2, … in order, none deleted or renumbered; each cites a check of this file, a clause of dev/CHARTER.md (every check that clause cites) or an existing test, hook, script or workflow by path, or names the dev/MARCH.md row where its planned check is written (`planned: <row>`, the row existing), or the live row that supersedes it; a live row carries its rule for agents, a row stating a number its intent and band; and every check of this file serves a live row, directly or through a clause the row cites: a check that serves no requirement is noise. Behavior, run here: seventeen planted ledgers and an empty one answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local v = vcat(ledger_faults_here(), ledger_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L205_quantities_state_intent_and_band" => ("a number in a check is a target with its intent and band, never a tripwire (Dale 2026-10-21, a gate run blocked at 61 s against an under-a-minute goal: \"misinterpreted stupidly\"): every lock or ratchet whose description states a budget, a target, a cap or a limit as a number with its unit (QUANT_RX: seconds, minutes, lines, chars, a percentage, commits, landings, jobs, times) states its `intent:` and `band:` there, and fails only outside the band, as the blocking gate's budgets are targets red past BUDGET_BAND times them (L194) and the loop's target is red past L197_BAND (L197); intent: Dale's numbers say what he wants; band: each check's own, stated beside its number. Behavior, run here: seven planted descriptions answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local v = vcat(String["$id states a number without its intent and band" for id in
                                  quantities_without_band([_short_id(k) => d for (k, (d, _)) in vcat(METRICS, LOCKS)])],
                           quantity_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L206_agents_md_carries_the_ledger" => ("AGENTS.md, the file every agent reads first, carries every live requirement of dev/LEDGER.md (Dale 2026-10-21: his desires were \"put into memory and lost or ignored by subagents\"): the lines between `<!-- ledger:begin -->` and `<!-- ledger:end -->` are exactly `- **D<n>** <rule for agents>` for each live row, in the ledger's order, so the list is generated from the ledger, and the lock prints the block it should hold when they differ. Behavior, run here: six planted files answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local agents = joinpath(ROOT, "AGENTS.md")
            local rows = first(ledger_rows(isfile(LEDGER_PATH) ? _text(LEDGER_PATH) : ""))
            local v = vcat(agents_ledger_faults(isfile(agents) ? _text(agents) : "", rows), agents_ledger_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L218_rejections_a_closed_sum" => ("the rejections are a closed sum by construction (dev/MARCH.md 1.A2c, Dale 2026-10-21: strict means the wrong choice cannot be written): src/julia/reject.jl's `Rejection` is a `Union` of five concrete structs (Unported, Unquarantined, OutsideSubset, InvalidModule, Internal) that subtype nothing, so no module adds a kind without editing that line, and every kind has its `_reason` and no other type has one; construction_check(::Val{:Rejection}) asserts it when WasmTarget loads (check_closed_sum), and this lock only calls it, with its plants (construction_negatives_missed: a kind with no handler, a handler outside the sum, a kind under an open abstract type and a sum that is no Union each refused, a sum fully handled passed) (dev/CHARTER.md C6)",
        ConstructionLock(:Rejection)),
    "L219_no_open_hierarchy_passes_for_closed" => ("no open hierarchy passes for a closed one (dev/AUDIT.md A33S1): every abstract type WasmTarget or a submodule defines is a registered construction (construction_check(::Val{<name>}) has a method) or a dart abstract class's mirror whose docstring carries `parity(<file>.dart:<line> <Symbol>)`, so a closed sum is a `Union` or an `@enum` by its type, never by its comment; construction_check(::Val{:check_no_open_abstract}) asserts it last when WasmTarget loads (check_no_open_abstract, by reflection over the module's bindings), and this lock only calls it, with its plants (an open abstract type and one in a submodule each refused, a dart mirror with its anchor passed) (dev/CHARTER.md C5)",
        ConstructionLock(:check_no_open_abstract)),
    "L207_every_negative_runs_every_gate" => ("every lock's negative runs in every gate, inside this file (Dale 2026-10-21, after test/lock_negatives.jl's L195 plant rotted unseen until a landing touched that file): a lock calls, directly or through functions of this file, a function named `<name>_negatives_missed` that plants fixed text its own logic must answer, so the ratchet stage runs it on every landing; a negative in a family the gate's selection may skip counts for nothing. Every lock outside NEGATIVE_OWED has one; NEGATIVE_OWED lists exactly the locks that owe theirs, none with one and none that is no lock, and R45 counts it, so the list only shrinks and a new lock never joins it. Behavior, run here: four planted tables and four planted sources answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local defs, thunks, calls = ratchet_source()
            local locks = String[_short_id(first(p)) for p in LOCKS]
            local v = vcat(negative_faults(locks, id -> reaches_negative(get(thunks, id, ""), defs, calls), NEGATIVE_OWED),
                           negative_rule_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L201_closed_cites_no_stopgap" => ("strict means by construction (Dale, 2026-10-21): a clause of C0 to C8 with no Planned text (one the charter block reads CLOSED) cites only constructions: no ratchet, no lock STRICT_KINDS classifies :stopgap (a scan of WT's source or the repository's text, an allowlist or a count, finding the wrong choice at gate time) or :behavior (a run that must reach it), and no lock it does not classify; C0 is inside the standard (A29S2), its eight checks stopgaps, so it reads OPEN with its Planned text; every lock C0 and C4 to C8 cite is classified, every entry names a lock one of them cites, and every :construction's lock is ConstructionLock of the definition it names, which only calls the check src registers beside that definition (construction_check), so a construction's lock reads no text: L201 checks the lock's type and name in this table by reflection, not its source (A29S1); and every :construction has its precedent in STRICT_PRECEDENTS, `<ecosystem>: <mechanism>`, with how Julia's differs, and no other entry has one (Dale 2026-10-21: a construction with no precedent anywhere is an invention). Behavior, run here: planted clauses (a stopgap, a behavior check, a ratchet or an unclassified lock with no Planned text fires; Planned text, constructions alone, or a clause outside the scope do not), a planted table's thirteen faults (a construction whose lock is a function, one with no precedent or no Julia difference, a precedent for a stopgap among them) and a ConstructionLock naming another definition (dev/CHARTER.md C0)",
        () -> begin
            local cl = charter_clauses()
            local v = vcat(strict_violations(cl, STRICT_KINDS), strict_table_faults(cl, STRICT_KINDS), strict_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
]


function run(; update::Bool=(get(ENV, "WT_RATCHET_UPDATE", "0") == "1"))
    baseline = _read_baseline(BASELINE_PATH)
    bm = get(baseline, "metrics", Dict{String,Int}())

    ok = true
    current_m = Dict{String,Int}()
    current_l = Dict{String,Int}()

    println("── parity ratchet (dev/CHARTER.md's locks and ratchets) ──")
    for (id, (desc, thunk)) in METRICS
        c = thunk()
        current_m[id] = c
        b = get(bm, id, nothing)
        # a ratchet with no baseline line bounds nothing: outside update mode it fails, and only
        # WT_RATCHET_UPDATE=1 records it, a reviewable diff of the baseline (A12P5)
        status = b === nothing ? (update ? "NEW(baseline): recorded by this update" :
                                  "❌ MISSING from dev/parity_baseline.toml (record it with WT_RATCHET_UPDATE=1)") :
                 c > b ? "❌ RATCHET BROKEN (+$(c - b))" :
                 c < b ? "▼ improved ($b→$c — tighten with WT_RATCHET_UPDATE=1)" : "= holding"
        b === nothing && !update && (ok = false)
        b !== nothing && c > b && (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", status, "   # ", desc)
    end
    for (id, (desc, thunk)) in LOCKS
        c = thunk()
        current_l[id] = c
        # a lock passes only at 0, whatever the baseline holds (A3P9)
        good = (c == 0)
        good || (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", good ? "🔒 locked" : "❌ LOCK BROKEN (want 0)", "   # ", desc)
    end
    # a baseline key that names no METRICS ratchet fails outside update mode: a lock is not
    # recorded (A3P9), and a key left by a renamed or deleted ratchet bounds nothing (A12P5)
    metric_ids = Set{String}(first(p) for p in METRICS)
    for sec in sort!(collect(keys(baseline))), k in sort!(collect(keys(baseline[sec])))
        (sec == "metrics" && k in metric_ids) && continue
        if update
            println("baseline key [", sec, "] ", k, " names no METRICS ratchet: dropped by this update")
        else
            println("❌ STRAY baseline key [", sec, "] ", k, ": names no METRICS ratchet, FAIL (delete the line; a lock is not recorded, A3P9)")
            ok = false
        end
    end


    # dev/CHARTER.md: the per-clause verdict. A clause is CLOSED only when every check it
    # cites is a passing lock (a cited ratchet keeps it open, at 0 too, until it moves to
    # LOCKS) and it names no planned check.
    println("── charter (dev/CHARTER.md) ──")
    allc = merge(current_m, current_l)
    byshort = Dict(_short_id(k) => k for k in keys(allc))
    for (cid, (body, ids)) in charter_clauses()
        title = strip(first(split(body, "."; limit=2)))
        title = replace(title, "*" => "")
        open_ = clause_open_reasons(cid, body, ids, current_m, current_l)
        println(rpad(cid, 4), rpad(first(title, 42), 44), isempty(open_) ? "CLOSED" : "OPEN  " * join(open_, " "))
    end
    if update
        if !ok
            println("refusing WT_RATCHET_UPDATE: a ratchet/lock is BROKEN (ratchets never loosen).")
        else
            _write_baseline(BASELINE_PATH, current_m)
            println("baseline tightened → ", BASELINE_PATH)
        end
    end
    return ok
end

end # module

# Standalone: exit 0/1. From runtests, include this file then assert
# `@test ParityRatchet.run()` inside a @testset (see runtests.jl's `_wt_qa("parity_ratchet.jl")` block).
if get(ENV, "WT_RATCHET_INCLUDED", "0") != "1"
    exit(ParityRatchet.run() ? 0 : 1)
end
