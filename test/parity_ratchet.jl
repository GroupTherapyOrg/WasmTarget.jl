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
# of them walking src/ line by line read every file ~40 times (the landing check's minute, dev/check.sh).
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
const STRICT_CLASSIFIED = ("C0", "C2", "C3", "C4", "C5", "C6", "C7", "C8")
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
    "L208" => (:stopgap, ""), "L209" => (:behavior, ""),
    # the rebuild's first constructions (dev/MARCH.md 1.A2c): the rejections a closed sum (C6), and
    # no open abstract type passing for a closed one (C5, A33S1); C4, C7 and C8's arrive with theirs
    "L218" => (:construction, "Rejection"), "L219" => (:construction, "check_no_open_abstract"),
    # the file map, the anchors and the quarantine (C2): src/julia/parity.jl
    "L210" => (:construction, "include_dart"), "L211" => (:construction, "parity"), "L212" => (:construction, "quarantine"),
    # the strict subset's typestate (C6, dev/MARCH.md 1.A7): src/julia/subset.jl
    "L220" => (:construction, "ClosedWorld"), "L224" => (:stopgap, ""),
    # NIR's closed sums (C5, dev/MARCH.md 1.A10): src/julia/nir.jl
    "L221" => (:construction, "NirStmt"), "L222" => (:construction, "NirValue"),
    "L213" => (:construction, "check_anchors_resolve"),
    # each mirror of a Julia form names the form, verified by converting a sample (C3, A39S1)
    "L225" => (:construction, "check_mirrors"),
    # dart2wasm's test set mapped (C2, dev/LEDGER.md D41): a check over test/dart_tests.toml
    "L226" => (:stopgap, ""),
    # the closed sums matched exhaustively (C5) and the typed signatures and fields (C4)
    "L217" => (:construction, "closed"), "L214" => (:construction, "check_typed_signatures"),
    "L215" => (:construction, "check_typed_fields"),
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
    "L210" => ("dart: part/part of, a library naming each file it holds; rust: mod, a crate's files reachable only through its declarations",
               "Julia's include takes any path, so include_dart admits the pin table's files alone and the files it loaded are checked against the directory listing when the package loads"),
    "L211" => ("rust: the deny missing_docs lint, every item documented or the crate does not build",
               "nothing in Julia requires a definition to say where it comes from, so @parity checks the anchor and the name where it is written and the totality check refuses, by reflection over the method table and the bindings, any definition outside src/julia no @parity spans when the package loads"),
    "L221" => ("rust: enum + exhaustive match; dart: sealed class + exhaustive switch",
               "a Union of concrete structs, one per form of Julia's optimized IR, that subtype nothing, @closed, stmt_form an @exhaustive match over it, checked where it is written and when the package loads, since Julia checks no match at compile time"),
    "L222" => ("rust: enum + exhaustive match; dart: sealed class + exhaustive switch",
               "a Union of the four concrete operand forms of Julia's optimized IR, a literal held as Julia's own Core.Const, @closed, value_form an @exhaustive match over it, checked where it is written and when the package loads"),
    "L220" => ("rust: typestate with a private constructor, the value made by one function of its module",
               "Julia has no private constructors, so ClosedWorld's sole constructor takes a token only subset.jl holds, and both constructors' method tables are checked by reflection when the package loads"),
    "L213" => ("dart: the analyzer resolves every identifier to its declaration or the program does not compile; rust: rustdoc denies broken intra-doc links",
               "nothing in Julia resolves a name in another language's source, so @parity reads the pinned dart line where the anchor is written and the load checks every anchor, both where the pinned checkout exists, and the lock requires the checkout"),
    "L217" => ("rust: enum + match, its missing arm error E0004; dart: sealed class + exhaustive switch",
               "Julia has neither a match statement nor an exhaustiveness check, and marks no Union as a sum: @closed checks a sum's kinds where it is written, @exhaustive checks a match's arms against them there, and the load refuses a Union binding without @closed and re-checks every match"),
    "L214" => ("typescript: noImplicitAny; dart: the always_specify_types lint",
               "Julia accepts an untyped parameter as Any, so the load reads every method signature of each ported @parity definition"),
    "L215" => ("typescript: strictNullChecks; dart: sound null safety",
               "Julia's field types may hold Any or nothing by declaration alone, so the load reads each ported struct's field types, and a field holding nothing against the pinned dart class's T? where the checkout exists"),
    "L225" => ("rust: a mirror type's From<Form> impl, its source type named in the impl and checked by the compiler",
               "a mirror holds a projection of its Julia form, not the form, so the form it names is checked by converting a sample of that form, built by Julia's own constructors, when the package loads"),
    "L212" => ("rust: unsafe with clippy's undocumented_unsafe_blocks, every block saying why",
               "Julia has no keyword marking Julia-only code, so @quarantine checks the necessity and resolves the Julia API where it is written and the totality check refuses any src/julia definition no @quarantine spans when the package loads"),
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
    if definition in (:Rejection, :NirStmt, :NirValue, :closed, :check_typed_signatures, :check_typed_fields)
        append!(out, sum_negatives_missed(wt, definition, refuses, passes))
    elseif definition === :check_no_open_abstract
        local noopen = getfield(wt, :check_no_open_abstract)
        local bad = Module(:OpenPlant); Core.eval(bad, :(abstract type Bad end))
        local good = Module(:MirrorPlant)
        Core.eval(good, Meta.parse("import WasmTarget: @parity"))
        Base.include_string(good, "@parity \"wasm_builder/lib/src/ir/type.dart:12 ValueType\" abstract type ValueType end", "/plant/src/wasm_builder/ir/type.jl")
        local sub = Module(:SubPlant); Core.eval(sub, Expr(:toplevel, :(module Sub; abstract type Hidden end; end)))
        refuses(() -> noopen(bad)) || push!(out, "negative missed: an open abstract type passes")
        passes(() -> noopen(good)) || push!(out, "negative missed: a dart abstract class's mirror carrying @parity fails")
        local doc = Module(:DocPlant)
        Core.eval(doc, :(Core.@doc "parity(wasm_builder/lib/src/ir/type.dart:12 ValueType) the dart class" abstract type ValueType end))
        refuses(() -> noopen(doc)) || push!(out, "negative missed: a docstring naming a parity anchor exempts an open abstract type")
        # A34S4's sealed half: a dart sealed class's mirror is a @closed sum, never an open abstract type
        local form(line, def) = Base.invokelatest(getfield(wt, :_form_fault), [line], 1, def) === nothing
        form("sealed class ElementSegment implements Serializable {}", :(abstract type ElementSegment end)) &&
            push!(out, "negative missed: an open abstract type mirrors a dart sealed class")
        form("sealed class ElementSegment implements Serializable {}", :(@closed const ElementSegment = Union{A, B})) ||
            push!(out, "negative missed: a @closed sum mirroring a dart sealed class is refused")
        form("abstract class ValueType {", :(@closed const ValueType = Union{A, B})) &&
            push!(out, "negative missed: a @closed sum mirrors a dart class that is not sealed")
        form("abstract class ValueType {", :(abstract type ValueType end)) || push!(out, "negative missed: an abstract dart class's mirror is refused")
        # ruling (a): an abstract kind of a sealed sum, directly or through another, is a @closed sum
        # of its subclasses; an abstract class with no sealed ancestor, or a concrete kind, is not
        local hier = ["sealed class R {}", "abstract class D extends R {}", "abstract class Q {}",
                      "abstract class E extends D {}", "class F extends R {}"]
        local hform(ln) = Base.invokelatest(getfield(wt, :_form_fault), hier, ln, :(@closed const X = Union{A, B})) === nothing
        (hform(2) && hform(4)) || push!(out, "negative missed: a @closed sum at an abstract kind of a sealed sum is refused")
        hform(3) && push!(out, "negative missed: a @closed sum at an abstract class with no sealed ancestor passes")
        hform(5) && push!(out, "negative missed: a @closed sum at a concrete kind of a sealed sum passes")
        refuses(() -> noopen(sub)) || push!(out, "negative missed: an open abstract type in a submodule passes")
        local par = Module(:ParamPlant); Core.eval(par, :(abstract type Open{T} end))
        refuses(() -> noopen(par)) || push!(out, "negative missed: a parametric open abstract type (a UnionAll binding) passes")
    elseif definition === :ClosedWorld
        local sole = getfield(wt, :check_sole_constructor)
        local f = "/plant/src/julia/typestate.jl"
        local plant(code) = (local m = Module(:TypestatePlant); Base.include_string(m, code, f); m)
        local base = "struct Tok; Tok() = new(); end\nstruct W; x::Int; W(::Tok, x::Int) = new(x); end\n"
        local good = plant(base)
        passes(() -> sole(good.W, good.Tok, f)) || push!(out, "negative missed: a sole constructor taking the file's token fails")
        local outer = plant(base * "W(x::Int) = W(Tok(), x)\n")
        refuses(() -> sole(outer.W, outer.Tok, f)) || push!(out, "negative missed: a second constructor, one any caller can use, passes")
        local notok = plant("struct Tok; Tok() = new(); end\nstruct W; x::Int; W(x::Int) = new(x); end\n")
        refuses(() -> sole(notok.W, notok.Tok, f)) || push!(out, "negative missed: a constructor that takes no token passes")
        refuses(() -> sole(good.W, good.Tok, "/plant/src/julia/elsewhere.jl")) || push!(out, "negative missed: a constructor defined in another file passes")
        local tok2 = plant(base * "Tok(::Int) = Tok()\n")
        refuses(() -> sole(tok2.W, tok2.Tok, f)) || push!(out, "negative missed: a token with a second constructor passes")
    elseif definition === :check_mirrors
        append!(out, mirror_negatives_missed(wt, refuses, passes))
    elseif definition in (:include_dart, :parity, :quarantine, :check_anchors_resolve)
        append!(out, parity_negatives_missed(wt, definition, refuses, passes))
    else
        push!(out, "the construction $definition has no plants in construction_negatives_missed")
    end
    return out
end

# L224's negative: plants written as real methods, whose lowered code is what Julia produces, each
# making a W or reaching the token by another road than the maker (A36S3, A37S1, A38), and a clean
# package passed; the maker is its one Method, captured before a second method joins its function
function closed_world_makers_negatives_missed(wt::Module)::Vector{String}
    local out = String[]
    local V = getfield(wt, :ConstructionViolation)
    local maker = getfield(wt, :check_sole_maker)
    local base = "struct Tok; Tok() = new(); end\nstruct W; x::Int; W(::Tok, x::Int) = new(x); end\nmake(x::Int)::W = W(Tok(), x)\nuse(w::W)::Int = w isa W ? (w::W).x : 0\n"
    local plant(extra, defs) = (local m = Module(:MakersPlant); Base.include_string(m, base * extra, "/plant/src/julia/makers.jl"); foreach(d -> Core.eval(m, d), defs); m)
    local verdict(m, mk) = try; Base.invokelatest(maker, m, Base.invokelatest(getglobal, m, :W), Base.invokelatest(getglobal, m, :Tok), (mk,), (), ()); :passes; catch e; e isa V ? :refused : :other; end
    local clean = plant("", Expr[])
    verdict(clean, only(methods(Base.invokelatest(getglobal, clean, :make)))) === :passes || push!(out, "negative missed: the maker alone making a W, W named as a type elsewhere, fails")
    for (what, extra, defs) in [
            ("a call of the token and W beside the maker", "s() = W(Tok(), 1)\n", Expr[]),
            ("M.W(M.Tok(), ...), lowered as getproperty", "a() = (@__MODULE__).W((@__MODULE__).Tok(), 1)\n", Expr[]),
            ("getfield with literal names", "b() = getfield(@__MODULE__, :W)(getfield(@__MODULE__, :Tok)(), 1)\n", Expr[]),
            ("eval splatted through _apply_iterate", "c() = Core.eval((@__MODULE__, :(W(Tok(), 1)))...)\n", Expr[]),
            ("eval as invokelatest's argument", "d() = Base.invokelatest(Core.eval, @__MODULE__, :(W(Tok(), 1)))\n", Expr[]),
            ("the token by a computed name", "e() = getfield(@__MODULE__, Symbol(\"To\", \"k\"))()\n", Expr[]),
            ("a jl_new_struct foreigncall", "f() = ccall(:jl_new_struct, Any, (Any, Any...), W, 1)\n", Expr[]),
            ("a real :new, its type in its own statement", "", [:(g() = $(Expr(:new, :W, 1)))]),
            ("a real :splatnew", "", [:(h(t) = $(Expr(:splatnew, :W, :t)))])]
        local m = plant(extra, defs)
        verdict(m, only(methods(Base.invokelatest(getglobal, m, :make)))) === :refused || push!(out, "negative missed: $what passes")
    end
    local two = plant("", Expr[])
    local m1 = only(methods(Base.invokelatest(getglobal, two, :make)))
    Base.include_string(two, "make(x::String)::W = W(Tok(), 2)\n", "/plant/src/julia/makers.jl")
    verdict(two, m1) === :refused || push!(out, "negative missed: a second method added to the maker's function passes")
    return out
end

# the file map's, the anchors' and the quarantine's plants (src/julia/parity.jl): fixed source each
# check or macro must refuse or pass, loaded into fresh modules under /plant/src (outside WT's src, so
# only the plants' own rules apply) or, for the location rules, under WT's own src/julia and src/
function parity_negatives_missed(wt::Module, definition::Symbol, refuses::Function, passes::Function)::Vector{String}
    local out = String[]
    local V = getfield(wt, :ConstructionViolation)
    local src = getfield(wt, :SRC)
    local plant(name) = (local p = Module(name); Core.eval(p, Meta.parse("import WasmTarget: @parity, @quarantine, @unported")); p)
    # a load the macros refuse at its line: the LoadError Julia wraps the refusal in, unwrapped
    local refused_load(code, file) = try
        Base.include_string(plant(:LoadPlant), code, file); false
    catch e
        while e isa LoadError; e = e.error; end
        e isa V
    end
    if definition === :include_dart
        local dir = mktempdir()
        mkpath(joinpath(dir, "julia")); mkpath(joinpath(dir, "wasm_builder", "ir"))
        foreach(f -> write(joinpath(dir, f), "\n"), ("translator.jl", "WasmTarget.jl", joinpath("julia", "x.jl"), joinpath("wasm_builder", "ir", "type.jl")))
        local check = getfield(wt, :check_include_dart)
        passes(() -> check(dir, ["dart2wasm/lib/translator.dart", "wasm_builder/lib/src/ir/type.dart"])) || push!(out, "negative missed: the directory's files, each included, fail")
        refuses(() -> check(dir, ["dart2wasm/lib/translator.dart"])) || push!(out, "negative missed: a file loaded other than by include_dart passes")
        refuses(() -> check(dir, ["dart2wasm/lib/translator.dart", "wasm_builder/lib/src/ir/type.dart", "dart2wasm/lib/types.dart"])) || push!(out, "negative missed: an included dart file with no source passes")
        refuses(() -> getfield(wt, :include_dart)("dart2wasm/lib/dart2wasm.dart")) || push!(out, "negative missed: a dart file outside the pin table includes")
        rm(dir; recursive = true)
        # two passes: a method naming a type a later file declares loads; two declarations that need
        # each other refuse; one name in two modules (dart's import prefixes) loads in both
        local two = getfield(wt, :_load_two_pass!)
        local files = mktempdir()
        local file(name, code) = (local p = joinpath(files, name); write(p, code); p)
        local a = file("a.jl", "@parity \"dart2wasm/lib/translator.dart:1 Translator.useB\" use_b(b::B)::Int = 1\n")
        local b = file("b.jl", "@parity \"dart2wasm/lib/types.dart:1 B\" struct B\n    c::C\n    B(c::C) = new(c)\nend\n@parity \"dart2wasm/lib/types.dart:9 C\" struct C\n    C() = new()\nend\n")
        local fwd = plant(:ForwardPlant)
        passes(() -> (two(Tuple{Module,String}[(fwd, a), (fwd, b)]); Base.invokelatest(() -> fwd.use_b(fwd.B(fwd.C())))) == 1 ? 0 : 1) ||
            push!(out, "negative missed: a method naming a type a later file declares does not load")
        # a method an earlier file adds to a function a later file's marked definition binds loads
        local impl = file("impl.jl", "@parity \"dart2wasm/lib/types.dart:3 C.serialize\" Main.ForwardFnPlant.serialize(c::Main.ForwardFnPlant.C)::Int = 2\n")
        local decl = file("decl.jl", "@parity \"dart2wasm/lib/types.dart:9 C\" struct C\n    C() = new()\nend\n@parity \"dart2wasm/lib/translator.dart:5 Translator.serialize\" serialize(x::Int)::Int = 1\n")
        local fwdfn = Core.eval(Main, :(module ForwardFnPlant; import WasmTarget: @parity, @unported; end))
        passes(() -> (two(Tuple{Module,String}[(fwdfn, impl), (fwdfn, decl)]); Base.invokelatest(() -> fwdfn.serialize(fwdfn.C())) == 2 ? 0 : 1)) ||
            push!(out, "negative missed: a method an earlier file adds to a function a later file binds does not load")
        # a package's member function defined only from its prefixed library (`WasmBuilder.f` in an ir
        # file): declared in the package module, loaded, and counted as made by its marked definition
        local host = Module(:PackageHostPlant)
        Core.eval(host, Meta.parse("import WasmTarget: @parity, @quarantine, @unported"))
        Base.include_string(host, "@quarantine \"a package\" Core.Module module PkgQ\nimport WasmTarget: @parity, @unported, @quarantine\n" *
            "@quarantine \"a prefixed library\" Core.Module module IR\nimport WasmTarget: @parity, @unported\nimport ..PkgQ\nend\nend\n", "/plant/src/julia/pk.jl")
        local pkgq = Base.invokelatest(getproperty, host, :PkgQ)
        local irf = file("ir_member.jl", "@parity \"wasm_builder/lib/src/ir/types.dart:1 Types.serializeIr\" PkgQ.serialize_ir(x::Int)::Int = 1\n")
        passes(() -> (two(Tuple{Module,String}[(pkgq.IR, irf)]); Base.invokelatest(() -> pkgq.serialize_ir(1)) == 1 ? Base.invokelatest(getfield(wt, :check_parity), pkgq, files) : 1)) ||
            push!(out, "negative missed: a package member defined only from its prefixed library does not load or is counted unmarked")
        # a mutable struct's `const f::T` field orders its declaration after T's
        local mut = file("mut.jl", "@parity \"dart2wasm/lib/types.dart:1 B\" mutable struct B\n    const c::C\n    B(c::C) = new(c)\nend\n@parity \"dart2wasm/lib/types.dart:9 C\" struct C\n    C() = new()\nend\n")
        local mutp = plant(:MutableConstPlant)
        passes(() -> (two(Tuple{Module,String}[(mutp, mut)]); Base.invokelatest(() -> mutp.B(mutp.C()).c isa mutp.C) ? 0 : 1)) ||
            push!(out, "negative missed: a mutable struct's const field does not order its declaration after the field's type")
        local cyc = file("c.jl", "@parity \"dart2wasm/lib/types.dart:1 B\" struct B\n    c::C\n    B(c::C) = new(c)\nend\n@parity \"dart2wasm/lib/types.dart:9 C\" struct C\n    b::B\n    C(b::B) = new(b)\nend\n")
        refuses(() -> two(Tuple{Module,String}[(plant(:CyclePlant), cyc)])) || push!(out, "negative missed: two declarations that need each other load")
        local pkg = plant(:PackagePlant)
        Core.eval(pkg, :(module IR; import WasmTarget: @parity, @unported; end))
        local outer = file("o.jl", "@parity \"wasm_builder/lib/src/builder/instructions.dart:1 TryTableCatch\" struct TryTableCatch\n    ir::IR.TryTableCatch\n    TryTableCatch(ir::IR.TryTableCatch) = new(ir)\nend\n")
        local inner = file("i.jl", "@parity \"wasm_builder/lib/src/ir/instruction.dart:1 TryTableCatch\" struct TryTableCatch\n    TryTableCatch() = new()\nend\n")
        passes(() -> (two(Tuple{Module,String}[(pkg, outer), (pkg.IR, inner)]); Base.invokelatest(() -> fieldtype(pkg.TryTableCatch, 1) === pkg.IR.TryTableCatch) ? 0 : 1)) ||
            push!(out, "negative missed: one name in a package and its prefixed library's module does not load in both")
        rm(files; recursive = true)
        local modof(k) = Base.invokelatest(getfield(wt, :_module_of), k)
        (modof("wasm_builder/lib/src/ir/type.dart") === wt.WasmBuilder.IR && modof("wasm_builder/lib/src/builder/module.dart") === wt.WasmBuilder &&
         modof("dart2wasm/lib/util.dart") === wt.Dart2Wasm.Util && modof("dart2wasm/lib/js/runtime_generator.dart") === wt.Dart2Wasm.JS &&
         modof("dart2wasm/lib/target.dart") === wt.Dart2Wasm) || push!(out, "negative missed: a dart file loads into another module than its package's or prefixed library's")
    elseif definition === :parity
        local m = plant(:ParityPlant)
        Base.include_string(m, """
            @parity "dart2wasm/lib/translator.dart:10 Translator" struct Translator; Translator() = new(); end
            @parity "dart2wasm/lib/translator.dart:20 Translator.translateType" @unported function translate_type(t::Translator, n::Int) end
            @parity "dart2wasm/lib/translator.dart:30 Translator.isStruct" is_struct(t::Translator)::Bool = (local f = () -> true; f())
            """, "/plant/src/translator.jl")
        passes(() -> getfield(wt, :check_parity)(m, "/plant/src")) || push!(out, "negative missed: definitions each carrying @parity fail")
        local stub = try; Base.invokelatest(() -> m.translate_type(m.Translator(), 1)); nothing; catch e; e; end
        (stub isa getfield(wt, :RejectionError) && Base.invokelatest(==, stub.rejection, Base.invokelatest(getfield(wt, :Unported), "dart2wasm/lib/translator.dart:20 Translator.translateType"))) ||
            push!(out, "negative missed: an @unported stub does not reject with its @parity's anchor")
        local bare = plant(:BarePlant)
        Base.include_string(bare, "@parity \"dart2wasm/lib/types.dart:5 isNullable\" is_nullable(x::Int) = x\nhelper(x::Int) = x\n", "/plant/src/types.jl")
        refuses(() -> getfield(wt, :check_parity)(bare, "/plant/src")) || push!(out, "negative missed: a method with no @parity passes")
        local root = plant(:RootPlant)
        Base.include_string(root, "const ROOT = 1\n", "/plant/src/WasmTarget.jl")
        refuses(() -> getfield(wt, :check_parity)(root, "/plant/src")) || push!(out, "negative missed: a binding no definition marks passes")
        refused_load("@parity \"dart2wasm/lib/dart2wasm.dart:1 main\" main() = 0", "/plant/src/x.jl") || push!(out, "negative missed: an anchor outside the pin table loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart Translator\" struct Translator; Translator() = new(); end", "/plant/src/x.jl") || push!(out, "negative missed: an anchor with no line loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart:9 Translator.translateType\" translateType(x::Int) = x", "/plant/src/x.jl") || push!(out, "negative missed: a name not the rule's loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart:9 Translator\" struct Translator; Translator() = new(); end", joinpath(src, "julia", "plant.jl")) || push!(out, "negative missed: @parity in src/julia loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart:9 Translator\" struct Translator; Translator() = new(); end", joinpath(src, "plant.jl")) || push!(out, "negative missed: @parity in a src file include_dart did not load loads")
        refused_load("@unported f(x::Int) = nothing", "/plant/src/x.jl") || push!(out, "negative missed: @unported outside @parity loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart:9 Translator.foo\" @unported foo(x::Int) = x", "/plant/src/x.jl") || push!(out, "negative missed: an @unported stub with a body loads")
        # identity: a Base method written on the line of a marked definition is made by no definition
        local sameline = plant(:SameLinePlant)
        Base.include_string(sameline, "@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator; Translator() = new(); end; Base.length(t::Translator) = 0\n", "/plant/src/translator.jl")
        refuses(() -> getfield(wt, :check_parity)(sameline, "/plant/src")) || push!(out, "negative missed: a method on a marked definition's line, made by none, passes")
        # @enum: the methods Julia writes for a registered enum are its; an unregistered one refuses
        local enum = plant(:EnumPlant)
        Base.include_string(enum, "@parity \"dart2wasm/lib/translator.dart:1 Kind\" @enum Kind kind_a kind_b\n", "/plant/src/translator.jl")
        passes(() -> getfield(wt, :check_parity)(enum, "/plant/src")) || push!(out, "negative missed: a registered @enum's own methods fail")
        local bare_enum = plant(:BareEnumPlant)
        Base.include_string(bare_enum, "@enum Kind kind_a kind_b\n", "/plant/src/translator.jl")
        refuses(() -> getfield(wt, :check_parity)(bare_enum, "/plant/src")) || push!(out, "negative missed: an unregistered @enum passes")
        # names: a dart keyword name is var"<name>", Object's toString and hashCode are Base.show and Base.hash
        local keyword = plant(:KeywordPlant)
        Base.include_string(keyword, "@parity \"wasm_builder/lib/src/builder/exports.dart:1 ExportsBuilder.export\" var\"export\"(x::Int) = x\n" *
            "@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator; Translator() = new(); end\n" *
            "@parity \"dart2wasm/lib/translator.dart:2 Translator.toString\" Base.show(io::IO, t::Translator) = print(io, 0)\n" *
            "@parity \"dart2wasm/lib/translator.dart:3 Translator.hashCode\" Base.hash(t::Translator, h::UInt) = h\n", "/plant/src/x.jl")
        refused_load("@parity \"wasm_builder/lib/src/builder/exports.dart:1 ExportsBuilder.export\" export_(x::Int) = x", "/plant/src/x.jl") ||
            push!(out, "negative missed: a keyword name spelled with a trailing _ loads")
        refused_load("@parity \"dart2wasm/lib/translator.dart:2 Translator.toString\" to_string(x::Int) = x", "/plant/src/x.jl") ||
            push!(out, "negative missed: toString spelled to_string, not Base.show, loads")
        # anchor_of: a definition's anchor read from the registry by the object it binds, one or none
        local anchor_of(f) = Base.invokelatest(getfield(wt, :anchor_of), f)
        (try; anchor_of(Base.invokelatest(getproperty, m, :translate_type)) == "dart2wasm/lib/translator.dart:20 Translator.translateType"; catch; false; end) ||
            push!(out, "negative missed: anchor_of does not read a definition's anchor from the registry")
        refuses(() -> anchor_of(Base.sin)) || push!(out, "negative missed: anchor_of answers for a function no @parity defines")
        local snake(s) = Base.invokelatest(getfield(wt, :snake), s)
        (snake("toJSON") == "to_json" && snake("i32Const") == "i32_const" && snake("_translateType") == "_translate_type" && snake("HTMLParser") == "html_parser") ||
            push!(out, "negative missed: the snake rule")
    elseif definition === :check_anchors_resolve
        # a dart file at a planted pin: each declaration form, and lines that declare something else
        local dart = """
            class Translator {
              Translator(this.x);
              final int x;
              int translateType(int t) => t;
              bool get isStruct => true;
              bool operator ==(Object o) => true;
              Translator.named();
            }

            extension on Translator {
              void helper() {}
            }

            // translateType, in a comment
            int topLevel(int x) => x;
            """
        local lines = split(chomp(dart), '\n'; keepempty = true) .|> String
        local declares(ln, s) = Base.invokelatest(getfield(wt, :_declares), lines, ln, s) === nothing
        (declares(1, "Translator") && declares(2, "Translator") && declares(3, "Translator.x") && declares(4, "Translator.translateType") &&
         declares(5, "Translator.isStruct") && declares(6, "Translator.==") && declares(7, "Translator.named") && declares(11, "helper") &&
         declares(15, "topLevel")) || push!(out, "negative missed: a dart declaration form does not resolve")
        declares(5, "Translator.translateType") && push!(out, "negative missed: an anchor moved a line resolves")
        declares(11, "Translator.translateType") && push!(out, "negative missed: an anchor in another declaration's body resolves")
        declares(14, "translateType") && push!(out, "negative missed: an anchor at a comment resolves")
        declares(40, "topLevel") && push!(out, "negative missed: an anchor past the file's end resolves")
        declares(4, "Translator") && push!(out, "negative missed: a member's line resolves as its class")
        local sdk = mktempdir()
        mkpath(joinpath(sdk, "pkg", "dart2wasm", "lib")); write(joinpath(sdk, "pkg", "dart2wasm", "lib", "translator.dart"), dart)
        mkpath(joinpath(sdk, ".git")); write(joinpath(sdk, ".git", "HEAD"), "0123456789012345678901234567890123456789\n")
        local good = plant(:ResolvePlant)
        Base.include_string(good, "@parity \"dart2wasm/lib/translator.dart:4 Translator.translateType\" @unported function translate_type(t::Int) end\n", "/plant/src/translator.jl")
        local moved = plant(:MovedPlant)
        Base.include_string(moved, "@parity \"dart2wasm/lib/translator.dart:5 Translator.translateType\" @unported function translate_type(t::Int) end\n", "/plant/src/translator.jl")
        local check = getfield(wt, :check_anchors_resolve)
        passes(() -> check(good, sdk)) || push!(out, "negative missed: an anchor that resolves fails")
        refuses(() -> check(moved, sdk)) || push!(out, "negative missed: an anchor moved a line passes the load's check")
        Base.invokelatest(getfield(wt, :_head_commit), sdk) == "0123456789012345678901234567890123456789" ||
            push!(out, "negative missed: a checkout's HEAD is misread")
        rm(sdk; recursive = true)
        local pm = match(r"\b([0-9a-f]{40})\b", _text(joinpath(ROOT, "dev", "PARITY_MASTER.md")))
        (pm !== nothing && pm.captures[1] == getfield(wt, :PIN)) || push!(out, "src/julia/parity.jl's PIN is not the commit dev/PARITY_MASTER.md pins")
    else
        local m = plant(:QuarantinePlant)
        Base.include_string(m, "@quarantine \"Julia's vectors\" Base.Vector f(x::Vector{Int}) = [y for y in x]\n", "/plant/src/julia/q.jl")
        passes(() -> getfield(wt, :check_quarantine)(m, "/plant/src")) || push!(out, "negative missed: definitions each carrying @quarantine fail")
        Base.include_string(m, "g(x::Int) = x\n", "/plant/src/julia/r.jl")
        refuses(() -> getfield(wt, :check_quarantine)(m, "/plant/src")) || push!(out, "negative missed: a src/julia method with no @quarantine passes")
        refused_load("@quarantine \"why\" Base.no_such_api h(x::Int) = x", "/plant/src/julia/q.jl") || push!(out, "negative missed: an API that does not resolve loads")
        refused_load("@quarantine \"why\" push! h(x::Int) = x", "/plant/src/julia/q.jl") || push!(out, "negative missed: an unqualified API loads")
        refused_load("@quarantine \" \" Base.push! h(x::Vector{Int}) = push!(x, 1)", "/plant/src/julia/q.jl") || push!(out, "negative missed: an empty necessity loads")
        refused_load("@quarantine \"why\" Base.push! h(x::Vector{Int}) = push!(x, 1)", joinpath(src, "plant.jl")) || push!(out, "negative missed: @quarantine outside src/julia loads")
        refused_load("@quarantine \"why\" Base.push! h(x::Vector{Int}) = length(x)", "/plant/src/julia/q.jl") || push!(out, "negative missed: an API the definition does not reference loads")
        local body = plant(:ModuleBodyPlant)
        Base.include_string(body, "@quarantine \"a type\" Core.DataType struct T end\n@quarantine \"a module\" Core.Module module Sub\nimport ..T\nBase.length(x::T) = 0\nend\n", "/plant/src/julia/q.jl")
        refuses(() -> getfield(wt, :check_quarantine)(body, "/plant/src")) || push!(out, "negative missed: an unmarked method in a marked module's body passes")
    end
    return out
end

# the closed sums', the exhaustive matches' and the typed definitions' plants (src/julia/construction.jl
# and parity.jl): fixed source each macro or check must refuse or pass, loaded into fresh modules
function sum_negatives_missed(wt::Module, definition::Symbol, refuses::Function, passes::Function)::Vector{String}
    local out = String[]
    local V = getfield(wt, :ConstructionViolation)
    local plant(code, file = "/plant/src/julia/sums.jl") = begin
        local m = Module(:SumPlant)
        Core.eval(m, Meta.parse("import WasmTarget: @parity, @quarantine, @unported, @closed, @exhaustive"))
        Base.include_string(m, code, file)
        m
    end
    local refused_load(code, file = "/plant/src/julia/sums.jl") = try
        plant(code, file); false
    catch e
        while e isa LoadError; e = e.error; end
        e isa V
    end
    local kinds = "struct A; x::Int; end\nstruct B; end\nstruct C; end\n"
    if definition in (:Rejection, :NirStmt, :NirValue)
        # each is a @closed sum with its @exhaustive match: the plants are @closed's
        local good = plant(kinds * "@closed const S = Union{A, B}\n")
        Base.invokelatest(() -> (good, :S) in getfield(wt, :CLOSED_SUMS)) || push!(out, "negative missed: a @closed sum is not recorded")
        refused_load("abstract type Open end\nstruct D <: Open end\n" * kinds * "@closed const S = Union{A, D}\n") || push!(out, "negative missed: a kind subtyping an open abstract type passes")
        refused_load("abstract type Open end\nstruct D <: Open end\n@closed const S = Union{Open, D}\n") || push!(out, "negative missed: an abstract kind passes")
        refused_load(kinds * "@closed const S = Union{A, Undefined}\n") || push!(out, "negative missed: an undefined kind passes")
        refused_load(kinds * "@closed const S = A\n") || push!(out, "negative missed: a sum that is no Union passes")
        refused_load(kinds * "@closed const S = Union{A}\n") || push!(out, "negative missed: a sum of one kind passes")
    elseif definition === :closed
        local sum = kinds * "@closed const S = Union{A, B, C}\n"
        local good = plant(sum * "f(s::S) = @exhaustive s::S begin\n (a::A) => a.x\n B => -1\n C => -2\nend\n")
        (Base.invokelatest(() -> (good.f(good.A(7)), good.f(good.B()), good.f(good.C()))) == (7, -1, -2)) ||
            push!(out, "negative missed: an exhaustive match does not take each kind's arm")
        passes(() -> getfield(wt, :check_closed)(good)) || push!(out, "negative missed: a closed sum with its exhaustive match fails")
        refused_load(sum * "f(s::S) = @exhaustive s::S begin\n A => 1\n B => 2\nend\n") || push!(out, "negative missed: a match missing an arm loads")
        refused_load(sum * "f(s::S) = @exhaustive s::S begin\n A => 1\n B => 2\n C => 3\n _ => 4\nend\n") || push!(out, "negative missed: a wildcard arm loads")
        refused_load(sum * "f(s::S) = @exhaustive s::S begin\n A => 1\n B => 2\n x => 3\nend\n") || push!(out, "negative missed: an arm naming no kind loads")
        refused_load(sum * "f(s::S) = @exhaustive s::S begin\n A => 1\n B => 2\n C => 3\n A => 4\nend\n") || push!(out, "negative missed: a kind with two arms loads")
        refused_load(sum * "f(s::S) = @exhaustive s::S begin\n (a) => 1\nend\n") || push!(out, "negative missed: an untyped binder loads")
        refused_load(kinds * "const U = Union{A, B}\nf(s::U) = @exhaustive s::U begin\n A => 1\n B => 2\nend\n") || push!(out, "negative missed: a match over an unclosed Union loads")
        local nested_ok = try
            local nested = plant(kinds * "@closed const In = Union{A, B}\n@closed const Out = Union{In, C}\ng(s::Out) = @exhaustive s::Out begin\n A => 1\n B => 2\n C => 3\nend\n")
            Base.invokelatest(() -> (nested.g(nested.B()), nested.g(nested.C()))) == (2, 3)
        catch
            false
        end
        nested_ok || push!(out, "negative missed: a closed sum holding a sealed subclass's closed sum does not match its leaves")
        local open_ = plant(kinds * "const U = Union{A, B}\n")
        refuses(() -> getfield(wt, :check_closed)(open_)) || push!(out, "negative missed: a Union binding no @closed declares passes")
        local stale = plant(sum)
        Base.invokelatest(() -> push!(getfield(wt, :MATCHES), (stale, :S, [:A, :B], "plant:1")))
        refuses(() -> getfield(wt, :check_closed)(stale)) || push!(out, "negative missed: a recorded match short of its sum's kinds passes")
    elseif definition === :check_typed_signatures
        local f = "/plant/src/translator.jl"
        local check = getfield(wt, :check_typed_signatures)
        local typed = plant("@parity \"dart2wasm/lib/translator.dart:10 Translator.translateType\" translate_type(t::Int, v::Vector{Int}) = t\n" *
                            "@parity \"dart2wasm/lib/translator.dart:20 Translator.isStruct\" @unported function is_struct(t) end\n", f)
        passes(() -> check(typed)) || push!(out, "negative missed: a ported method with every parameter typed fails")
        (try; plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n    n::Int\nend\n", f); false; catch e; while e isa LoadError; e = e.error; end; e isa V; end) ||
            push!(out, "negative missed: a ported struct leaning on Julia's default constructors loads")
        (try; plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n    n::Int\n    Translator(n::Int) = new(n)\n    Translator() = new(0)\nend\n", f); false; catch e; while e isa LoadError; e = e.error; end; e isa V; end) ||
            push!(out, "negative missed: a ported struct with two inner constructors loads")
        passes(() -> check(plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n    n::Int\n    Translator(n::Int) = new(n)\nend\n", f))) ||
            push!(out, "negative missed: a ported struct with its one typed inner constructor fails")
        refuses(() -> check(plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n    n::Int\n    Translator(n) = new(n)\nend\n", f))) ||
            push!(out, "negative missed: an untyped constructor written in a struct's body passes")
        refuses(() -> check(plant("@parity \"dart2wasm/lib/translator.dart:10 Translator.translateType\" translate_type(t, v::Int) = t\n", f))) ||
            push!(out, "negative missed: an untyped parameter passes")
        refuses(() -> check(plant("@parity \"dart2wasm/lib/translator.dart:10 Translator.translateType\" translate_type(t::T) where {T} = t\n", f))) ||
            push!(out, "negative missed: an unbounded type variable passes")
        refuses(() -> check(plant("@parity \"dart2wasm/lib/translator.dart:10 Translator.translateType\" translate_type(t::Int, rest...) = t\n", f))) ||
            push!(out, "negative missed: a bare Vararg passes")
    else
        local check = getfield(wt, :check_typed_fields)
        local f = "/plant/src/translator.jl"
        local sdk = mktempdir()
        mkpath(joinpath(sdk, "pkg", "dart2wasm", "lib"))
        write(joinpath(sdk, "pkg", "dart2wasm", "lib", "translator.dart"), "class Translator {\n  final int? maybeCount;\n  final int count;\n}\n")
        local struct_(fields) = plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n$fields\n    Translator(x...) = new(x...)\nend\n", f)
        passes(() -> check(struct_("    maybe_count::Union{Nothing,Int}\n    count::Int"), sdk)) || push!(out, "negative missed: typed fields, the nullable one dart's T?, fail")
        refuses(() -> check(struct_("    count::Any"), sdk)) || push!(out, "negative missed: a field holding Any passes")
        refuses(() -> check(struct_("    count::Vector{Any}"), sdk)) || push!(out, "negative missed: a field holding Any as a parameter passes")
        refuses(() -> check(struct_("    count::Union{Nothing,Int}"), sdk)) || push!(out, "negative missed: a field holding nothing that dart declares non-nullable passes")
        refuses(() -> check(struct_("    other::Union{Nothing,Int}"), sdk)) || push!(out, "negative missed: a nullable field dart does not declare passes")
        # the class's own entry alone: an outer constructor anchored at another dart line names the type too
        write(joinpath(sdk, "pkg", "dart2wasm", "lib", "translator.dart"), "class Translator {\n  final int? maybeCount;\n  final int count;\n  Translator(this.maybeCount, this.count);\n}\n")
        local withctor = plant("@parity \"dart2wasm/lib/translator.dart:1 Translator\" struct Translator\n    maybe_count::Union{Nothing,Int}\n    count::Int\n    Translator(x...) = new(x...)\nend\n" *
                               "@parity \"dart2wasm/lib/translator.dart:4 Translator\" Translator(count::Int) = Translator(nothing, count)\n", f)
        passes(() -> check(withctor, sdk)) || push!(out, "negative missed: a struct's fields are read against its constructor's anchor, not its class's")
        rm(sdk; recursive = true)
    end
    return out
end

# the mirrors' plants (src/julia/parity.jl check_mirrors): two quarantined mirrors of Julia forms in a
# fresh module, a converter and their samples; each fault planted alone must refuse
function mirror_negatives_missed(wt::Module, refuses::Function, passes::Function)::Vector{String}
    local out = String[]
    local plant(ssa_api, conv_ssa, samples, extra = "") = begin
        local m = Module(:MirrorPlant)
        Core.eval(m, Meta.parse("import WasmTarget: @parity, @quarantine, @unported, @closed, @exhaustive"))
        Core.eval(m, :(import WasmTarget))
        Base.include_string(m, """
            @quarantine "a mirror" $ssa_api struct MSSA
                id::Int
            end
            @quarantine "a mirror" Core.Argument struct MArg
                n::Int
            end
            @quarantine "a sum" Core.Union @closed const MVal = Union{MSSA, MArg}
            @quarantine "a converter" Core.SSAValue function conv(x, at::String)::MVal
                x isa Core.SSAValue && return $conv_ssa
                return MArg(x.n)
            end
            WasmTarget.mirror_samples!(conv, :MVal, $samples)
            $extra
            """, "/plant/src/julia/mirrors.jl")
        m
    end
    local check(m) = getfield(wt, :check_mirrors)(m)
    local both = "MSSA => Core.SSAValue(1), MArg => Core.Argument(2)"
    passes(() -> check(plant("Core.SSAValue", "MSSA(x.id)", both))) || push!(out, "negative missed: mirrors naming their forms, each converting back, fail")
    refuses(() -> check(plant("Core.Argument", "MSSA(x.id)", both))) || push!(out, "negative missed: a mirror naming the wrong form passes")
    refuses(() -> check(plant("Core.SSAValue", "MArg(x.id)", both))) || push!(out, "negative missed: a sample converting to another mirror passes")
    refuses(() -> check(plant("Core.SSAValue", "MSSA(x.id)", both, "@quarantine \"a mirror\" Core.GotoNode struct MGoto\n    label::Int\nend"))) ||
        push!(out, "negative missed: a mirror's claim with no sample passes")
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
        # a clause citing nothing is no violation here: clause_open_reasons, the one verdict, reads it OPEN
        ("a clause with no Planned text that cites nothing", plant("C4", " T. Checks: ", String[]), 0),
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
    local named = [Regex("^\\s*(?:@quarantine\\s+\"[^\"]*\"\\s+\\S+\\s+|@parity\\s+\"[^\"]*\"\\s+)?(?:@inline\\s+)*(?:function|macro|struct|mutable struct|const)\\s+\\Q" * n * "\\E(?![\\w!])") for n in names]
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
    local fixed = audit_fixes(ROOT, first(split(last(entries), '\n')))
    fixed === nothing && return ["no git history: the findings' fixes cannot be read"]
    return findings_off_row(open_findings(last(entries)), rows, fixed)
end

# the findings the `Fixes:` lines of the commits after an entry's own name: its own the commit that
# added its heading to dev/AUDIT.md, not the last to touch the file, so a later edit elsewhere in the
# log hides no fix (2026-10-28: a header edit hid A40E1's); an entry not yet committed has no fix
# after it; nothing when there is no history
function audit_fixes(root::AbstractString, heading::AbstractString)::Union{Nothing,Set{String}}
    local fixed = Set{String}()
    try
        local c = readchomp(`git -C $root log -1 --format=%H -S$heading -- dev/AUDIT.md`)
        isempty(c) && return fixed
        for l in split(readchomp(`git -C $root log $c..HEAD --format=%B`), '\n')
            startswith(l, "Fixes:") && union!(fixed, String[x.match for x in eachmatch(r"\bA\d+[A-Z]\d+\b", l)])
        end
    catch
        return nothing
    end
    return fixed
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
    # the fixes after an entry, on a scratch repository: a fix lands after the entry, then an edit of the
    # log's header; the fix is still read, and one before the entry is not
    mktempdir() do t
        local g = (args...) -> Base.run(pipeline(`git -C $t -c user.email=l@l -c user.name=l -c commit.gpgsign=false $args`; stdout = devnull, stderr = devnull))
        local log = joinpath(t, "dev", "AUDIT.md")
        g("init", "-q"); mkpath(dirname(log))
        write(log, "# log\n"); g("add", "dev/AUDIT.md"); g("commit", "-qm", "c0\n\nFixes: A0B9")
        write(log, "# log\n\n## e1 (a..b)\n"); g("commit", "-qam", "entry")
        write(joinpath(t, "f"), "x"); g("add", "f"); g("commit", "-qm", "fix\n\nFixes: A1B2")
        write(log, "# the log\n\n## e1 (a..b)\n"); g("commit", "-qam", "header")
        audit_fixes(t, "## e1 (a..b)") == Set(["A1B2"]) || push!(out, "negative missed: a fix after the entry, then a header edit")
        audit_fixes(t, "## e2 (b..c)") == Set{String}() || push!(out, "negative missed: an entry not yet committed")
    end
    return out
end

# ---- L209: one Co-Authored-By trailer per commit (dev/LEDGER.md D24, A35E4) ----------------------
# the hook's verdict on a planted message: true when dev/hooks/commit-msg accepts it
function hook_accepts(message::String)::Bool
    local f = tempname()
    write(f, message)
    local ok = success(pipeline(`sh $(joinpath(ROOT, "dev", "hooks", "commit-msg")) $f`; stderr = devnull))
    rm(f; force = true)
    return ok
end

# L209's negative test: the hook refuses two trailers (one indented), accepts one
function trailer_negatives_missed()::Vector{String}
    local out = String[]
    local base = "fix: x\n\nCharter: C0 (x)\n\nCo-Authored-By: A <a@b>\n"
    hook_accepts(base) || push!(out, "negative missed: the hook refuses a message with one Co-Authored-By trailer")
    hook_accepts(base * "    Co-Authored-By: A <a@b>\n") && push!(out, "negative missed: the hook accepts an indented second trailer")
    hook_accepts(base * "Co-authored-by: B <c@d>\n") && push!(out, "negative missed: the hook accepts a second trailer in another case")
    return out
end

# ---- L208: the rebuild's src progress, printed after every landing (dev/LEDGER.md D40) ---------------
# dev/src_progress.sh's output for planted numbers, or for this tree with none
src_progress(args::String...)::String = read(`bash $(joinpath(ROOT, "dev", "src_progress.sh")) $args`, String)

# the line of dev/ship.sh that prints, after its push, the src progress line its check's ratchet printed
const SHIP_SRC_LINE = raw"    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0"

# L208's negative test: four src-less landings print no note, five print it, the line keeps its form
function src_progress_negatives_missed()::Vector{String}
    local out = String[]
    occursin("note:", src_progress("10", "2", "4")) && push!(out, "negative missed: four src-less landings printed the note")
    occursin("note:", src_progress("10", "2", "5")) || push!(out, "negative missed: five src-less landings printed no note")
    startswith(src_progress("10", "2", "0"), "src: 2 of 10 anchored dart definitions ported") || push!(out, "negative missed: the line's form")
    return out
end

# ---- L226: dart2wasm's test set, ported with Julia as the ground truth (dev/LEDGER.md D41) ----------
# test/dart_tests.toml gives every .dart file under the three test roots at the pin one entry: behavior
# (the smoke cases porting it), structural (the property its golden pins), not portable (why) or a
# helper (the entries it serves); the files are read from the pinned commit's tree in the checkout
# L213 reads, so a file added at the pin or an entry dropped fails
const DART_TESTS_PATH = joinpath(ROOT, "test", "dart_tests.toml")
const DART_TEST_ROOTS = ("pkg/dart2wasm/test/", "tests/web/wasm/", "tests/language/")
# each kind's fields besides `kind`, exactly
const DART_TEST_FIELDS = Dict("behavior" => ["what", "cases"], "structural" => ["what", "property", "cases"],
                              "not_portable" => ["what", "reason"], "helper" => ["what", "of"])
const DartTestEntry = Pair{String,Dict{String,Union{String,Vector{String}}}}

# the entries of a map's text in order, and its faults as a text: a line that is no header, field,
# comment or blank, a value that is no one-line string or list of strings, a header or field twice
function dart_test_entries(text::AbstractString)::Tuple{Vector{DartTestEntry},Vector{String}}
    local entries = DartTestEntry[]
    local faults = String[]
    local seen = Set{String}()
    for (i, l) in enumerate(split(text, '\n'))
        local s = strip(l)
        (isempty(s) || startswith(s, '#')) && continue
        local h = match(r"^\[\"([^\"]+)\"\]$", s)
        if h !== nothing
            h[1] in seen && push!(faults, "test/dart_tests.toml:$i: [\"$(h[1])\"] appears twice")
            push!(seen, h[1])
            push!(entries, String(h[1]) => Dict{String,Union{String,Vector{String}}}())
            continue
        end
        local f = match(r"^(\w+) = (.*)$", s)
        if f === nothing || isempty(entries)
            push!(faults, "test/dart_tests.toml:$i: neither a header, a field of an entry, a comment nor blank: $s")
            continue
        end
        local d = last(entries[end])
        haskey(d, f[1]) && push!(faults, "test/dart_tests.toml:$i: $(f[1]) appears twice in [\"$(first(entries[end]))\"]")
        if (sv = match(r"^\"([^\"]*)\"$", f[2])) !== nothing
            d[f[1]] = String(sv[1])
        elseif occursin(r"^\[(?:\s*\"[^\"]*\"\s*(?:,\s*\"[^\"]*\"\s*)*)?\]$", f[2])
            d[f[1]] = String[String(m[1]) for m in eachmatch(r"\"([^\"]*)\"", f[2])]
        else
            push!(faults, "test/dart_tests.toml:$i: $(f[1]) is no one-line string or list of strings")
        end
    end
    return entries, faults
end

# the faults of a map against the .dart files at the pin and the smoke corpus's case keys
function dart_test_faults(entries::AbstractVector{DartTestEntry}, files::AbstractVector{String},
                          cases::AbstractSet{String})::Vector{String}
    local out = String[]
    local named = Set{String}(first.(entries))
    for (key, d) in entries
        local at = "[\"$key\"]"
        any(r -> startswith(key, r), DART_TEST_ROOTS) || push!(out, "$at is under no dart test root ($(join(DART_TEST_ROOTS, ", ")))")
        if endswith(key, "/")
            any(f -> startswith(f, key), files) || push!(out, "$at names no directory of .dart files at the pin")
        elseif !(key in files)
            push!(out, "$at names no .dart file at the pin")
        end
        local kind = get(d, "kind", "")
        if !(kind isa String) || !haskey(DART_TEST_FIELDS, kind)
            push!(out, "$at has the kind $(repr(kind)), not one of $(join(sort!(collect(keys(DART_TEST_FIELDS))), ", "))")
            continue
        end
        local want = DART_TEST_FIELDS[kind]
        for k in sort!(collect(keys(d)))
            k == "kind" || k in want || push!(out, "$at, $kind, carries $k")
        end
        for k in want
            local v = get(d, k, nothing)
            local list = k in ("cases", "of")
            if v === nothing || (list ? !(v isa Vector{String}) : !(v isa String) || isempty(strip(v)))
                push!(out, "$at, $kind, has no $(list ? "list" : "text") $k")
            elseif k == "cases"
                foreach(c -> c in cases || push!(out, "$at names the smoke case $c, which test/smoke_corpus.jl does not hold"), v)
            elseif k == "of"
                isempty(v) && push!(out, "$at, a helper, serves no entry")
                foreach(e -> (e in named && e != key) || push!(out, "$at serves $e, which is no other entry"), v)
            end
        end
    end
    # each file covered by exactly one entry: its own path, or a directory's holding it
    for f in files
        local by = [k for k in named if k == f || (endswith(k, "/") && startswith(f, k))]
        length(by) == 1 || push!(out, isempty(by) ? "$f, a dart test file at the pin, has no entry in test/dart_tests.toml" :
                                                      "$f is covered by $(length(by)) entries: $(join(sort!(by), ", "))")
    end
    return out
end

# the .dart files under the three roots at the pin, read from the pinned commit's tree in the checkout of
# dart-lang/sdk at ~/.cache/wasmtarget/dart-sdk (dev/fetch_dart_sdk.sh; a blob-less fetch holds the tree),
# or nothing when that checkout holds no such commit
function dart_test_files_at_pin()::Union{Vector{String},Nothing}
    local pm = match(r"\b([0-9a-f]{40})\b", _text(joinpath(ROOT, "dev", "PARITY_MASTER.md")))
    pm === nothing && return nothing
    local dir = joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk")
    isdir(dir) || return nothing
    local io = IOBuffer()
    success(pipeline(`git -C $dir ls-tree -r --name-only $(pm[1]) -- $DART_TEST_ROOTS`; stdout = io, stderr = devnull)) || return nothing
    return sort!(filter(f -> endswith(f, ".dart"), String.(split(String(take!(io)), '\n'; keepempty = false))))
end

# a smoke corpus's case keys, `<group>/<case>`: each `_c("<key>"` line, each case `("<name>",` of a
# `_g`/`_xf` group, and `<group>/*` for a group its generator file builds (`_lazy_g`/`_lazy_xf`)
function corpus_case_keys(text::AbstractString)::Set{String}
    local keys = Set{String}()
    local group = ""
    for l in eachline(IOBuffer(text))
        local p = match(r"^\s*_c\(\s*\"([^\"]+)\"", l)
        p === nothing || (push!(keys, p[1]); continue)
        local lz = match(r"^\s*_lazy_(?:g|xf)\(\s*\"([^\"]+)\"", l)
        lz === nothing || (push!(keys, lz[1] * "/*"); group = ""; continue)
        local g = match(r"^\s*_(?:g|xf)\(\s*\"([^\"]+)\"", l)
        g === nothing || (group = g[1]; continue)
        local c = match(r"^\s*\(\s*\"([^\"]+)\"\s*,", l)
        c === nothing || isempty(group) || push!(keys, group * "/" * c[1])
    end
    return keys
end
smoke_case_keys()::Set{String} = corpus_case_keys(_text(joinpath(ROOT, "test", "smoke_corpus.jl")))

# this tree's faults, and its counts printed
function dart_tests_faults_here()::Vector{String}
    isfile(DART_TESTS_PATH) || return ["test/dart_tests.toml is missing"]
    local entries, out = dart_test_entries(_text(DART_TESTS_PATH))
    local files = dart_test_files_at_pin()
    files === nothing && return vcat(out, ["no checkout of dart-lang/sdk holding the pinned commit at ~/.cache/wasmtarget/dart-sdk: bash dev/fetch_dart_sdk.sh"])
    append!(out, dart_test_faults(entries, files, smoke_case_keys()))
    local n(kind) = count(e -> get(last(e), "kind", "") == kind, entries)
    local ported = count(e -> get(last(e), "kind", "") == "behavior" && !isempty(get(last(e), "cases", String[])), entries)
    println("    · dart tests at the pin: $(length(files)) files in $(length(entries)) entries: $(n("behavior")) behavior ($ported ported), ",
            "$(n("structural")) structural, $(n("not_portable")) not portable, $(n("helper")) helpers")
    return out
end

# L226's negative test: a planted map, its files and cases, and each plant answering as stated
function dart_tests_negatives_missed()::Vector{String}
    local files = ["pkg/dart2wasm/test/a_test.dart", "tests/language/d/x_test.dart", "tests/language/d/y_test.dart", "tests/web/wasm/h.dart"]
    local cases = Set(["dart_web/a"])
    local base = """
        # a planted map
        ["pkg/dart2wasm/test/a_test.dart"]
        kind = "behavior"
        what = "w"
        cases = ["dart_web/a"]

        ["tests/language/d/"]
        kind = "not_portable"
        what = "w"
        reason = "r"

        ["tests/web/wasm/h.dart"]
        kind = "helper"
        of = ["pkg/dart2wasm/test/a_test.dart"]
        what = "w"
        """
    local faults(text, fs = files) = (r = dart_test_entries(text); length(r[2]) + length(dart_test_faults(r[1], fs, cases)))
    local plants = [
        ("a whole map", base, files, 0),
        ("a dart test file at the pin with no entry", base, vcat(files, "tests/web/wasm/new_test.dart"), 1),
        ("an entry naming no file at the pin", base * "[\"tests/web/wasm/gone_test.dart\"]\nkind = \"not_portable\"\nwhat = \"w\"\nreason = \"r\"\n", files, 1),
        ("a file covered by its own entry and its directory's", base * "[\"tests/language/d/x_test.dart\"]\nkind = \"not_portable\"\nwhat = \"w\"\nreason = \"r\"\n", files, 1),
        ("a ported entry naming a case the corpus does not hold", replace(base, "[\"dart_web/a\"]" => "[\"dart_web/zzz\"]"), files, 1),
        ("a not portable entry with no reason", replace(base, "reason = \"r\"\n" => ""), files, 1),
        ("a structural entry with no property", replace(base, "kind = \"behavior\"" => "kind = \"structural\""), files, 1),
        ("an unknown kind", replace(base, "kind = \"behavior\"" => "kind = \"ported\""), files, 1),
        ("a helper serving no entry", replace(base, "of = [\"pkg/dart2wasm/test/a_test.dart\"]" => "of = [\"tests/web/wasm/x_test.dart\"]"), files, 1),
        ("a line that is no field", base * "kind behavior\n", files, 1),
        ("a header twice", base * "[\"tests/web/wasm/h.dart\"]\n", files, 2),
        ("a field the kind does not carry", replace(base, "reason = \"r\"\n" => "reason = \"r\"\ncases = []\n"), files, 1),
        ("an entry under no root", base * "[\"tests/corelib/z_test.dart\"]\nkind = \"not_portable\"\nwhat = \"w\"\nreason = \"r\"\n", vcat(files, "tests/corelib/z_test.dart"), 1),
    ]
    local out = String[]
    for (what, text, fs, want) in plants
        local got = faults(text, fs)
        got == want || push!(out, "negative missed: $what gives $got faults, not $want")
    end
    local e = first(dart_test_entries(base))
    (length(e) == 3 && last(e[1])["cases"] == ["dart_web/a"] && last(e[2])["reason"] == "r") ||
        push!(out, "negative missed: the planted map's entries read back")
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
    L125 L126 L129 L130 L153 L162
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


# ---- L148: the audit log (dev/AUDIT.md), its entries chained; the lag a report (dev/LEDGER.md D21) ----
# the commits past the last audited one that an audit is due after (Dale 2026-09-30: every 5 commits)
const AUDIT_LAG_TARGET = 5
const AUDIT_AREAS = ("Area: builder", "Area: collection and planning", "Area: emission and diagnostics",
                     "Area: enforcement and prose")

audit_entries(txt::AbstractString) = split(txt, r"\n(?=## )")[2:end]
# the commit the last entry naming one was audited through, or nothing
function audit_last_through(txt::AbstractString)
    local last = nothing
    for e in audit_entries(txt)
        local m = match(r"audited through ([0-9a-f]{8,40})", e)
        m === nothing || (last = String(m.captures[1]))
    end
    return last
end

# the faults of an audit log: no entry; an entry missing an area or its Resolution, naming no commit
# it was audited through, or one that is no ancestor of HEAD (`isancestor`); an entry whose range
# does not start where the one before it was audited through (a rewritten history fails, A2P5)
function audit_log_faults(txt::AbstractString, isancestor::Function)::Vector{String}
    local entries = audit_entries(txt)
    isempty(entries) && return ["dev/AUDIT.md holds no entry"]
    local out = String[]
    local prev = nothing
    for e in entries
        local h = first(split(e, '\n'))
        for area in AUDIT_AREAS
            occursin(area, e) || push!(out, "$h: no `$area`")
        end
        occursin("Resolution:", e) || push!(out, "$h: no `Resolution:`")
        local m = match(r"audited through ([0-9a-f]{8,40})", e)
        m === nothing && (push!(out, "$h: names no commit it was audited through"); continue)
        local sha = String(m.captures[1])
        isancestor(sha) || push!(out, "$h: $sha is no ancestor of HEAD")
        if prev !== nothing
            local r = match(r"\(([0-9a-f]{7,40})(?:~1)?\.\.", e)
            (r !== nothing && (startswith(prev, r.captures[1]) || startswith(r.captures[1], prev))) ||
                push!(out, "$h: its range does not start at $(first(prev, 8)), the entry before it")
        end
        prev = sha
    end
    return out
end

# L148's negative test: a chained log holds; a broken chain, a missing area and a commit off HEAD fire
function audit_log_negatives_missed()::Vector{String}
    local body = join(AUDIT_AREAS, "\n") * "\nResolution: none open.\n"
    local e1 = "## one — audited through aaaaaaaa (0000000..aaaaaaaa)\n" * body
    local e2 = "## two — audited through bbbbbbbb (aaaaaaaa..bbbbbbbb)\n" * body
    local anc = sha -> sha in ("aaaaaaaa", "bbbbbbbb")
    local out = String[]
    isempty(audit_log_faults("# log\n\n" * e1 * "\n" * e2, anc)) || push!(out, "negative missed: a chained log reads faulty")
    isempty(audit_log_faults("# log\n\n" * e1 * "\n" * replace(e2, "(aaaaaaaa.." => "(cccccccc.."), anc)) &&
        push!(out, "negative missed: a broken chain")
    isempty(audit_log_faults("# log\n\n" * replace(e1, "Area: builder\n" => ""), anc)) && push!(out, "negative missed: an area left out")
    isempty(audit_log_faults("# log\n\n" * e1 * "\n" * e2, sha -> sha == "aaaaaaaa")) && push!(out, "negative missed: a commit off HEAD")
    audit_last_through("# log\n\n" * e1 * "\n" * e2) == "bbbbbbbb" || push!(out, "negative missed: the last entry's commit")
    return out
end

# the smoke dealing's durations (test/smoke_times.tsv, which deals gate.yml's smoke parts): exactly the
# groups (smoke.jl's, its lazy ones and those of the files it includes), each measured on both
# versions; the faults counted
function smoke_dealing_faults()::Int
    local bad = 0
    local smk_main = read(joinpath(ROOT, "test", "smoke.jl"), String)
    local smk_src = join([smk_main; [read(joinpath(ROOT, "test", m[1]), String)
                                     for m in eachmatch(r"^include\(joinpath\(@__DIR__, \"([^\"]+)\"\)\)"m, smk_main)]], '\n')
    local want = Set{String}(m[1] in ("g", "lazy_g") ? m[2] : "xfail " * m[2]
                             for m in eachmatch(r"^_(g|xf|lazy_g|lazy_xf)\(\"([^\"]+)\""m, smk_src))
    local got = String[]
    for ln in eachline(joinpath(ROOT, "test", "smoke_times.tsv"))
        (isempty(ln) || startswith(ln, '#')) && continue
        local f = split(ln, '\t'; limit = 3)
        (length(f) == 3 && tryparse(Float64, f[1]) !== nothing && tryparse(Float64, f[2]) !== nothing) || (bad += 1; continue)
        push!(got, String(f[3]))
    end
    return bad + length(symdiff(want, Set(got))) + (length(got) - length(Set(got)))
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
    "L153_the_gate_runs_what_ci_runs" => ("the full matrix runs every test family CI runs on Julia 1.12, validated (WT_VALIDATE=1, as CI's Unix shards), and smoke on 1.13, at clause closure (Dale 2026-10-21: large-scale runs happen only when a full clause is closed out: a push of the march branch, wt2, whose head commit carries `Closes: C<n>`, which dev/hooks/commit-msg refuses unless the ratchet reads C<n> CLOSED; workflow_dispatch; gate.yml's closure job decides and every other job waits on it), never holding a landing (fast is first, strict is final: Dale 2026-10-20; a landing's evidence is `bash dev/check.sh`, run by `bash dev/ship.sh`): dev/lanes.sh's default run (not --fast; its comment lines not counted) stops at the first red lane (both smokes and TLC side by side first) and has the whole Pkg.test suite as two concurrent shards (WT_SHARD=0,2 and 1,2), smoke on Julia 1.13, and WT1's smoke over the one corpus on both versions (legacy/test/smoke.jl, the agreement oracle legacy/'s deletion rule reads, dev/MARCH.md 1.G). No lane of that run is skipped green: it runs the probes and the suite only when the default `julia` is 1.12, the formal lane only when `java` runs, and smoke on 1.13 only without a JULIA= override and with `julia +1.13` installed, and each of those skips prints FAIL and sets the run red; and every lane runs on CI's wasm engine, the Node major ci.yml's node-version names (batch 108 passed on Node 25 and trapped on CI's Node 22). `dev/lanes.sh --lane <name> [--part i/N]` runs one lane of that same run, every other lane a no-op, its skips still red; .github/workflows/gate.yml is that run on CI's runners, one job per lane through it: every lane the default run has, each split lane with every part 0..N-1 of one N, `julia` 1.12 and `julia +1.13` from juliaup as the script calls them, Node from ci.yml's node-version, fail-fast, every TLC instance (--all), none of the lanes' own variables (WT_*, TLC_*) set by the workflow, and triggered exactly by a push of the march branch (dev/ship.sh's MARCH, wt2) or workflow_dispatch, the one branch on origin (Dale 2026-10-28): `dev/ship.sh` pushes the march branch and no other ref, a landing's one push (so a landed head whose commit carries `Closes: C<n>` gets the run, in its head's own concurrency group in each workflow, which a later landing's push never cancels; no march/<branch> per landing, Dale 2026-10-21), and `bash dev/gate.sh` pushes nothing: it finds the Gate run of a wt2 commit and prints its verdict (the final full gate before PR #128 merges, on the merge head landed with `Closes: C<n>`), and no gate-fast workflow exists; ci.yml, formal.yml and downstream.yml trigger exactly as gate.yml does (a wt2 push, workflow_dispatch, formal.yml's nightly schedule beside; no pull request, whose branch every landing pushes, A23E4; no branches-ignore), each job with no `needs:` under the closure predicate, so a plain landing runs none of them; the closure predicate is one text in gate.yml's run-name, its closure job and those jobs (a dispatch or schedule, or a pushed head with a line `Closes: C<digit>…`, grep's `^Closes: C[0-9]+` spelt for an expression, A23E6); AGENTS.md says so, its table a row of its own; and test/smoke_times.tsv, which deals the smoke parts, lists exactly smoke's groups and xfail groups (smoke.jl's and those of the files it includes), each with a number of seconds for 1.12 and for 1.13 (smoke's dealing errors on a missing file, a duration that is no number and a group with none, dev/AUDIT.md A17P9). Batch 101 passed ratchet, probes and smoke on both versions, then broke a runtests family on CI (2026-10-07); until 2026-10-20 a push waited for this run and CI's (~2 h a landing; dev/CHARTER.md C10)",
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
            # the closure predicate (A23E4, A23E6): a dispatch or schedule, or a pushed head
            # with a line `Closes: C<digit>…`, grep's '^Closes: C[0-9]+' spelt for an expression (the
            # message after a newline holds a newline, `Closes: C` and a digit), one text in gate.yml's
            # run-name, its closure job and every job with no `needs:` of ci.yml, formal.yml and downstream.yml
            # the march branch, dev/ship.sh's MARCH, the one branch whose push triggers the workflows (one
            # branch on origin: Dale 2026-10-28), each run of its push in that head's own concurrency group
            local ship = read(joinpath(ROOT, "dev", "ship.sh"), String)
            local mm = match(r"^MARCH=([A-Za-z0-9._-]+)$"m, ship)
            local march = mm === nothing ? "?" : String(mm[1])
            local trig = "\non:\n  push:\n    branches: ['$march']\n  workflow_dispatch:\n"
            local own_group = "\${{ github.ref == 'refs/heads/$march' && github.sha || github.ref }}\n  cancel-in-progress: true\n"
            local P = "github.event_name != 'push' || " *
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
                      # a landed head reaches gate.yml by the landing's one push, the march branch's: no other ref
                      count(r"\bgit\b[^\n]*\bpush\b", ship) == 1 && occursin(raw"  if git push -q origin HEAD:$MARCH; then", ship) && !occursin("refs/heads/", ship),
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
                      # ... and on the march branch alone
                      occursin(trig * "\n", gate) && occursin(own_group, gate) &&
                          !occursin(r"^\s*(pull_request|schedule|workflow_run|workflow_call):"m, gate),
                      # ci.yml's, formal.yml's and downstream.yml's triggers are gate.yml's (march
                      # branch pushes, a dispatch; no pull request, no branches-ignore, no inline push),
                      # each job with no `needs:` under the closure predicate
                      pinned_push...,
                      occursin("\n| CI, Formal models, Downstream: the same triggers, never a plain landing | `.github/workflows` |\n", agents),
                      # dev/gate.sh pushes nothing: it finds the run a wt2 push started; no gate-fast workflow
                      !occursin(r"\bgit\b[^\n]*\bpush\b", _code(joinpath(ROOT, "dev", "gate.sh"))) &&
                          occursin(raw"  run=$(api gh run list --branch \"$MARCH\"", read(joinpath(ROOT, "dev", "gate.sh"), String)) &&
                          !isfile(joinpath(wf, "gate-fast.yml")),
                      smoke_dealing_faults() == 0])
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
    "L148_changes_are_audited" => ("every change is audited against the charter soon after it lands, beside the work, never holding a landing (AGENTS.md, the anti-drift audit; Dale 2026-09-30, restated 2026-10-28: audits run beside the work and never block a landing, dev/LEDGER.md D21): every dev/AUDIT.md entry names the commit it audited through, an ancestor of HEAD, each entry's range starts at the one before it (the entries chain, A2P5), and every entry covers the four areas (builder; collection and planning; emission and diagnostics; enforcement and prose) with its findings and how each was resolved; the audit lag, the commits past the last entry's, merges not counted, is printed, never a failure. With no git history the check fails, never skips; intent: every change is read against the charter soon after it lands; band: within 5 commits of the head, its edge a printed note, never a failure. Behavior, run here: four planted logs answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local audit = joinpath(ROOT, "dev", "AUDIT.md")
            isfile(audit) || return 1
            local anc = sha -> success(`git -C $ROOT merge-base --is-ancestor $sha HEAD`)
            local v = vcat(audit_log_faults(_text(audit), anc), audit_log_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            local last = audit_last_through(_text(audit))
            if last !== nothing && anc(last)
                local lag = parse(Int, readchomp(`git -C $ROOT rev-list --count --no-merges $last..HEAD`))
                println("    · audit lag: $lag commit(s) past the last entry's $(first(last, 8)) (target: at most $AUDIT_LAG_TARGET; ",
                        lag > AUDIT_LAG_TARGET ? "an audit is due, " : "", "a report, never a failure: D21)")
            end
            length(v)
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
    "L205_quantities_state_intent_and_band" => ("a number in a check is a target with its intent and band, never a tripwire (Dale 2026-10-21, a gate run blocked at 61 s against an under-a-minute goal: \"misinterpreted stupidly\"): every lock or ratchet whose description states a budget, a target, a cap or a limit as a number with its unit (QUANT_RX: seconds, minutes, lines, chars, a percentage, commits, landings, jobs, times) states its `intent:` and `band:` there, and fails only outside the band; intent: Dale's numbers say what he wants; band: each check's own, stated beside its number. Behavior, run here: seven planted descriptions answer as stated (dev/CHARTER.md C0)",
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
    "L218_rejections_a_closed_sum" => ("the rejections are a closed sum by construction (dev/MARCH.md 1.A2c, Dale 2026-10-21: strict means the wrong choice cannot be written): src/julia/reject.jl's `Rejection` is a `@closed` `Union` of five concrete structs (Unported, Unquarantined, OutsideSubset, InvalidModule, Internal) that subtype nothing, so no module adds a kind without editing that line, and `_reason` is an `@exhaustive` match over it, one arm per kind; construction_check(::Val{:Rejection}) asserts both when WasmTarget loads, then every match over the package's sums (check_sum_matched), and this lock only calls it, with its plants (sum_negatives_missed: a kind under an open abstract type, an abstract kind, an undefined kind, a sum of one kind and a sum that is no Union each refused by @closed, a sum of concrete kinds recorded) (dev/CHARTER.md C6)",
        ConstructionLock(:Rejection)),
    "L219_no_open_hierarchy_passes_for_closed" => ("no open hierarchy passes for a closed one (dev/AUDIT.md A33S1): every abstract type WasmTarget or a submodule defines is a registered construction (construction_check(::Val{<name>}) has a method) or a dart abstract class's mirror whose definition carries `@parity` (an entry of the registry naming it, src/julia/parity.jl), so a closed sum is a `Union` or an `@enum` by its type, never by its comment; construction_check(::Val{:check_no_open_abstract}) asserts it last when WasmTarget loads (check_no_open_abstract, by reflection over the module's bindings), and this lock only calls it, with its plants (an open abstract type and one in a submodule each refused, a dart mirror with its anchor passed) (dev/CHARTER.md C5)",
        ConstructionLock(:check_no_open_abstract)),
    "L221_nir_statements_a_closed_sum" => ("NIR's statements are a closed sum of Julia's optimized IR forms by construction (dev/MARCH.md 1.A10; ledger D3: Julia's IR is the ground truth, never re-guessed): src/julia/nir.jl's `NirStmt` is a `Union` of one concrete struct per statement form of Julia's optimized IR (call, invoke, new, foreigncall, boundscheck, the GC preservation pair, leave, pop_exception, the_exception, loopinfo, throw_undef_if_not, cfunction, invoke_modify, goto, gotoifnot, return, unreachable, phi, pi, enter, upsilon, phic, nothing, a GlobalRef read), each holding Julia's own operands, that subtype nothing, `@closed`, and `stmt_form` an `@exhaustive` match over it, one arm per kind; construction_check(::Val{:NirStmt}) asserts both when WasmTarget loads, then every match over the package's sums (check_sum_matched), and this lock only calls it, with its plants (sum_negatives_missed, as L218's: a kind under an open abstract type, an abstract kind, an undefined kind, a sum of one kind and a sum that is no Union each refused by @closed, a sum of concrete kinds recorded) (dev/CHARTER.md C5)",
        ConstructionLock(:NirStmt)),
    "L222_nir_operands_a_closed_sum" => ("NIR's operands are a closed sum of Julia's optimized IR operand forms by construction (dev/MARCH.md 1.A10): src/julia/nir.jl's `NirValue` is a `Union` of NirSSA, NirArgument, NirGlobal and NirConst, a literal held as Julia's own `Core.Const`, that subtype nothing, `@closed`, and `value_form` an `@exhaustive` match over it; construction_check(::Val{:NirValue}) asserts both when WasmTarget loads (check_sum_matched), and this lock only calls it, with its plants (sum_negatives_missed, as L218's) (dev/CHARTER.md C5)",
        ConstructionLock(:NirValue)),
    "L220_closed_world_typestate" => ("every stage after the strict subset's check takes the ClosedWorld Julia's trim verifier accepted, by construction (dev/MARCH.md 1.A7, ledger D32): src/julia/subset.jl's ClosedWorld has one constructor method, which takes the token _SubsetToken, and the token one constructor method, both defined in subset.jl, so compile's next stage, compile_world, takes a ClosedWorld only a holder of the token makes; construction_check(::Val{:ClosedWorld}) asserts it when WasmTarget loads (check_sole_constructor, by reflection over both method tables), and this lock only calls it, with its plants (construction_negatives_missed: a second constructor, a constructor taking no token, a constructor defined in another file and a token with a second constructor each refused, a sole constructor taking the file's token passed). Who may call the constructor is no construction in Julia, which has no module privacy: L224 reads it, a stopgap (dev/CHARTER.md C6)",
        ConstructionLock(:ClosedWorld)),
    "L224_closed_world_makers" => ("no method of WasmTarget but check_subset names _SubsetToken or makes a ClosedWorld, read in every method's lowered code when the package loads (check_closed_world_makers, check_sole_maker: each operand resolved to its binding through SSA statements, getproperty and getfield of a module; a call of ClosedWorld, a :new or :splatnew of either, a jl_new_struct foreigncall; outside WasmTarget's reflection files, an @generated method, an eval, include_string or include in any operand position, or a module lookup by a computed name refuses the load; the maker matched as its one Method). A stopgap by its kind, never a construction: Julia has no module privacy, so the wrong choice stays writable and this read finds it, and package extensions lie outside it (dev/AUDIT.md A36S3, A37S1, A38). Behavior: closed_world_makers_negatives_missed plants ten roads past the maker as real methods, each refused, and a clean package passed (dev/CHARTER.md C6)",
        () -> begin
            local wt = Base.require(Base.PkgId(Base.UUID("9f3a1415-1112-405b-ae89-c61daf9872bd"), "WasmTarget"))
            local v = vcat(Base.invokelatest(getfield(wt, :check_closed_world_makers)) == 0 ? String[] : ["check_closed_world_makers is not 0"],
                           closed_world_makers_negatives_missed(wt))
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L210_file_map" => ("a file of src/ outside src/julia loads only through `include_dart(\"<file>.dart\", ...)` (Dale: dart2wasm 1:1 file for file, dev/LEDGER.md D1): each path a key of the pin table DART_FILES, its path under the pinned sdk's pkg/, loaded into its module (DART_MODULES: one per dart package, Dart2Wasm and WasmBuilder, and one per library dart imports under a prefix, WasmBuilder.IR, Dart2Wasm.Util and Dart2Wasm.JS, declared in src/julia/packages.jl), in two passes, every file's type declarations first, each after those its supertype and field types name, two declarations that need each other refused, then the rest; when WasmTarget has loaded the files it loaded are exactly the .jl files under src/ outside src/julia, src/WasmTarget.jl aside, read from the directory listing, never from text, every directory an include dependency by its listing; construction_check(::Val{:include_dart}) asserts it when WasmTarget loads (check_include_dart), and this lock only calls it, with its plants (a file loaded otherwise and an included file with no source each refused, a dart file outside the pin table refused by include_dart, a directory whose every file is included passed; a method naming a type a later file declares loaded, two declarations that need each other refused, one name in a package and its prefixed library's module loaded in both, each key's module) (dev/CHARTER.md C2)",
        ConstructionLock(:include_dart)),
    "L211_anchor" => ("every definition outside src/julia carries `@parity \"<file>.dart:<line> <Symbol>\"`, the dart definition it copies at the pin (Dale: dart2wasm 1:1 through and through, dev/LEDGER.md D1): the macro refuses, at the definition's line, an anchor not of that form or whose file is no key of DART_FILES, a file in src/julia or one include_dart did not load, and a Julia name other than the one rule's (snake; a dart operator, toString or hashCode the Base function DART_BASE names alone; a Julia keyword name written var\"<name>\"), and expands `@unported` into a body rejecting with the anchor; when WasmTarget has loaded, every method it or a module under it defines is matched by identity to the definition whose evaluation made it (the world its evaluation spanned), and lies in that definition (its file, a body Julia gives no location, or the methods Julia's @enum writes for the enum it declares), and every binding is a marked definition's, by reflection over the method table and the bindings; construction_check(::Val{:parity}) asserts it (check_parity), and this lock only calls it, with its plants (an unmarked method, an unmarked binding, a Base method on a marked definition's line, an unregistered @enum, an anchor outside the pin table or with no line, a name not the rule's, a keyword name with a trailing _, toString as to_string, @parity in src/julia or in a file include_dart did not load, @unported outside @parity or with a body each refused; marked definitions, a registered @enum, var\"export\" and Base.show and Base.hash for toString and hashCode passed, and an @unported stub rejecting with its anchor; the snake rule; anchor_of reading a definition's anchor by the object it binds and refusing an unmarked one) (dev/CHARTER.md C2)",
        ConstructionLock(:parity)),
    "L212_quarantine" => ("every definition in src/julia carries `@quarantine \"<necessity>\" <Module.api>`, what Julia forces and dart lacks and the Julia API it relies on (Dale: the Julia compiler is the ground truth, dev/LEDGER.md D3): the macro refuses, at the definition's line, an empty necessity, an API that is not a qualified name, does not resolve, or that the definition's own text does not reference (a name, qualified name or GlobalRef resolving to it, or the form that stands for it: a module for Core.Module, a type declaration for Core.DataType, an interpolated string for Base.string), and a file under src/ outside src/julia; when WasmTarget has loaded, every method it defines in src/julia is matched by identity to the @quarantine definition whose evaluation made it and lies in it, a marked module's body holding none but Julia's eval and include, and every binding is a marked definition's, by reflection; the registry's own definitions carry it too, registered through the functions the macro expands to; construction_check(::Val{:quarantine}) asserts it (check_quarantine), and this lock only calls it, with its plants (an unmarked src/julia method, an unmarked method in a marked module's body, an unresolvable, unqualified or unreferenced API, an empty necessity and @quarantine outside src/julia each refused, marked definitions passed) (dev/CHARTER.md C2)",
        ConstructionLock(:quarantine)),
    "L213_anchors_resolve" => ("every anchor resolves at the pin (Dale: dart2wasm the structural oracle through and through, dev/LEDGER.md D1): the dart line an @parity anchor names declares its symbol at the commit dev/PARITY_MASTER.md pins, read from the checkout of dart-lang/sdk at ~/.cache/wasmtarget/dart-sdk (dev/fetch_dart_sdk.sh; CI fetches it): `X` a top-level declaration at column 0 or X's unnamed constructor in its body, `X.m` a member at column 2 of X's body, a bare `m` a member of an unnamed extension; where the checkout exists @parity refuses an anchor that does not resolve at the definition's line, the load checks every anchor of WasmTarget, and construction_check(::Val{:check_anchors_resolve}) requires the checkout, so this lock, which only calls it, fails without one; with its plants (an anchor moved a line, one in another declaration's body, at a comment, past the end and a member's line read as its class each refused; every declaration form resolving; a planted checkout's HEAD read; PIN the pinned commit) (dev/CHARTER.md C2)",
        ConstructionLock(:check_anchors_resolve)),
    "L225_mirrors_name_their_form" => ("each mirror of a Julia form names the form it mirrors (Dale: the Julia compiler is the ground truth, dev/LEDGER.md D3; audit 39, A39S1): a quarantined type declaration whose Julia API its text does not reference is a mirror's claim (NIR's NirSSA names Core.SSAValue, NirCall Core.Expr, NirGoto Core.GotoNode, ...), recorded where it is written; when WasmTarget loads, every claim has a sample of exactly that form, built by Julia's own constructors and registered with its converter (mirror_samples!), every sample's mirror names the sample's type and comes back from converting it, and every registered sum's kinds each have a sample (NirValue, NirStmt); construction_check(::Val{:check_mirrors}) asserts it (check_mirrors), and this lock only calls it, with its plants (a mirror naming the wrong form, a sample converting to another mirror and a claim with no sample each refused; mirrors naming their forms passed) (dev/CHARTER.md C3)",
        ConstructionLock(:check_mirrors)),
    "L217_closed_sums_matched_exhaustively" => ("every Union WasmTarget binds is a @closed sum and every match over one is @exhaustive (Dale: \"we don't allow certain broken wasm patterns\", closed sums and an exhaustive match, dev/LEDGER.md D8): `@closed const X = Union{...}` refuses, where it is written, a sum of fewer than two kinds or a kind that is not a concrete type defined above it subtyping nothing; `@exhaustive v::X begin (k::K) => ... end` refuses a sum not @closed above it and a missing, extra, repeated, wildcard `_` or untyped-binder arm, and expands into an isa chain over the asserted subject; when WasmTarget loads construction_check(::Val{:closed}) refuses a Union binding no @closed declares and re-checks every recorded match against its sum (check_closed), and this lock only calls it, with its plants (an unclosed Union binding, a stale match record and each refused arm form; an exhaustive match taking each kind's arm) (dev/CHARTER.md C5)",
        ConstructionLock(:closed)),
    "L214_typed_signatures" => ("every method of a ported @parity definition declares each parameter (Dale: strict means the wrong choice cannot be written, dev/LEDGER.md D6): none untyped (Any), an unbounded type variable or a bare Vararg, read from each method's signature in the method table when WasmTarget loads; an @unported stub and a quarantined definition (a Julia API's own types, the charter's named seam) are exempt; construction_check(::Val{:check_typed_signatures}) asserts it, and this lock only calls it, with its plants (an untyped parameter, an unbounded type variable and a bare Vararg each refused; a typed method and an untyped stub passed) (dev/CHARTER.md C4)",
        ConstructionLock(:check_typed_signatures)),
    "L215_typed_fields" => ("no field of a ported @parity struct holds Any, and a field holds nothing only where the dart class declares it T? (Dale: one source of truth, the field's type dart's, dev/LEDGER.md D5): read from each struct's field types when WasmTarget loads, the nullable fields against the pinned dart class where the checkout exists; a quarantined struct carries a Julia API's types, the charter's named seam; construction_check(::Val{:check_typed_fields}) asserts it, and this lock only calls it, with its plants (a field of Any, one of Vector{Any}, a nullable field dart declares non-nullable and one dart does not declare each refused; typed fields with dart's T? passed) (dev/CHARTER.md C4)",
        ConstructionLock(:check_typed_fields)),
    "L207_every_negative_runs_every_gate" => ("every lock's negative runs in every gate, inside this file (Dale 2026-10-21, after test/lock_negatives.jl's L195 plant rotted unseen until a landing touched that file): a lock calls, directly or through functions of this file, a function named `<name>_negatives_missed` that plants fixed text its own logic must answer, so the ratchet stage runs it on every landing; a negative in a family the gate's selection may skip counts for nothing. Every lock outside NEGATIVE_OWED has one; NEGATIVE_OWED lists exactly the locks that owe theirs, none with one and none that is no lock, and R45 counts it, so the list only shrinks and a new lock never joins it. Behavior, run here: four planted tables and four planted sources answer as stated (dev/CHARTER.md C0)",
        () -> begin
            local defs, thunks, calls = ratchet_source()
            local locks = String[_short_id(first(p)) for p in LOCKS]
            local v = vcat(negative_faults(locks, id -> reaches_negative(get(thunks, id, ""), defs, calls), NEGATIVE_OWED),
                           negative_rule_negatives_missed())
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L208_src_keeps_moving" => ("the rebuild always has a lane porting compiler src, and a status leads with src progress (Dale 2026-10-21: \"how are things going? still in setup or actually building the src code??\"): `dev/ship.sh` prints dev/src_progress.sh's line after every landing, the one the landing's check ran it for (this lock, in the ratchet dev/check.sh runs), which prints the dart definitions src/ anchors and ports, read from WasmTarget's @parity registry, an @unported stub anchored and not ported (A35S1; 1.A4's generator defines the in-scope total; until legacy/ exists src/ is WT1's, so the rebuild's counts none) and the landings since src/ last changed, and from the fifth consecutive landing that changes nothing under src/ a note; intent: setup never passes for building; band: a note from 5 src-less landings on, never a failure. Here: land runs the program, this tree's line is printed, and the program on planted numbers (4 landings print no note, 5 print it) (dev/CHARTER.md C0)",
        () -> begin
            local v = src_progress_negatives_missed()
            local o = src_progress()
            foreach(l -> println("    · ", l), split(rstrip(o), '\n'))
            startswith(o, "src: ") || push!(v, "dev/src_progress.sh printed no src line")
            occursin(SHIP_SRC_LINE, read(joinpath(ROOT, "dev", "ship.sh"), String)) ||
                push!(v, "dev/ship.sh does not print the src progress line after its landing")
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L209_one_coauthor_trailer" => ("a commit carries one Co-Authored-By trailer (A35E4: bb2c2fee, 3b3a0a0c and edf2327b each carried a second, indented one; dev/LEDGER.md D24): dev/hooks/commit-msg refuses a message with more than one, indented or in any case, and CI's message-hygiene refuses one from the commit that put the rule in the hook on. Behavior, run here: the hook on three planted messages, one trailer accepted, an indented second and a second in another case refused; and ci.yml holds the rule (dev/CHARTER.md C0)",
        () -> begin
            local v = trailer_negatives_missed()
            occursin("commits with more than one Co-Authored-By trailer:", read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)) ||
                push!(v, "CI's message-hygiene does not refuse a second Co-Authored-By trailer")
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    "L226_dart_tests_mapped" => ("dart2wasm's test set is ported with Julia as the ground truth (Dale 2026-10-22: \"we should ALSO port darts TEST set but with julia as the ground truth of course\", dev/LEDGER.md D41): every .dart file under pkg/dart2wasm/test, tests/web/wasm and tests/language at the commit dev/PARITY_MASTER.md pins, read from that commit's tree in the checkout at ~/.cache/wasmtarget/dart-sdk (dev/fetch_dart_sdk.sh), is covered by exactly one entry of test/dart_tests.toml, its own path or a directory's: behavior, naming the test/smoke_corpus.jl cases that port it (each existing, by corpus_case_keys), structural, stating the property its golden pins, not portable, stating why, or a helper, naming the entries it serves; every entry names a file or directory at the pin and carries exactly its kind's fields, so a new dart test file at the pin, a dropped entry or a stale one fails. A stopgap by its kind: a check over a map, the porting itself behavior the differential lane judges. Behavior, run here: dart_tests_negatives_missed plants a whole map and twelve faults, each answering as stated (dev/CHARTER.md C2)",
        () -> begin
            local v = vcat(dart_tests_faults_here(), dart_tests_negatives_missed())
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
