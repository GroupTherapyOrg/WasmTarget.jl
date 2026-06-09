# ============================================================================
# Fuzz entrypoint — the self-fulfilling discover → shrink → document loop
# ============================================================================
#
# Run from the repo root with the fuzz environment:
#
#     julia --project=test/fuzz test/fuzz/run.jl                 # discover + document
#     julia --project=test/fuzz test/fuzz/run.jl verify          # re-check open gaps, auto-close fixed
#
# Discovery: for each numeric universe, Supposition generates well-typed
# expression trees, the differential oracle checks native-vs-wasm, and on a
# mismatch Supposition SHRINKS to a minimal counterexample. Each distinct minimal
# failure is:
#   * persisted to the Supposition DirectoryDB (test/fuzz/corpus) — replayed first
#     on the next run, so a fix is verified automatically; and
#   * documented as a ledger gap (test/fuzz/failures/<id>.md) with a self-contained
#     reproducer a follow-up loop can run, fix, and auto-close via `verify`.

using Supposition, Random
using Supposition: Data

const FUZZ_DIR = @__DIR__
include(joinpath(FUZZ_DIR, "harness.jl"));     using .FuzzHarness
include(joinpath(FUZZ_DIR, "bridge.jl"));      using .FuzzBridge
include(joinpath(FUZZ_DIR, "bridge_args.jl")); using .FuzzBridgeArgs
include(joinpath(FUZZ_DIR, "catalogue.jl"));   using .FuzzCatalogue
include(joinpath(FUZZ_DIR, "structpool.jl"));  using .FuzzStructPool
include(joinpath(FUZZ_DIR, "generators.jl"));  using .FuzzGen
FuzzStructPool.build_pool!()   # deterministic (seeded) — same pool every process
include(joinpath(FUZZ_DIR, "property.jl"));     using .FuzzProperty
include(joinpath(FUZZ_DIR, "ledger.jl"));       using .Ledger

const CORPUS_DIR = joinpath(FUZZ_DIR, "corpus")

# --- Build a self-contained reproducer for a gap ----------------------------
# Contract: the snippet THROWS while the gap is present and RUNS CLEANLY once
# fixed. Universal across the whole universe: args/results cross via the
# bit-exact bridge, pool-struct types are rebuilt deterministically, and
# mutation parity is re-checked for mutable arguments.
function _reproducer(o::Outcome, ::Type{T0}, body; var::Symbol = :x) where {T0}
    bodystr = FuzzGen._body_repr(body)
    if o.category === :compile_error
        return """
        using WasmTarget
        include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
        FuzzStructPool.build_pool!()
        repro($(var)::$(T0)) = $(bodystr)
        WasmTarget.compile(repro, ($(T0),))   # raises while the gap is present
        """
    end
    inp = o.input === nothing ? "0" : repr(o.input[1])
    optkw = o.category === :optimizer_unsound ? ", opt=$(repr(o.detail[2]))" : ""
    tag = o.category === :optimizer_unsound ? " (wasm-opt $(o.detail[2]))" : ""
    return """
    using WasmTarget
    include(joinpath("test", "fuzz", "harness.jl"));     using .FuzzHarness
    include(joinpath("test", "fuzz", "bridge.jl"));      using .FuzzBridge
    include(joinpath("test", "fuzz", "bridge_args.jl")); using .FuzzBridgeArgs
    include(joinpath("test", "fuzz", "structpool.jl"));  using .FuzzStructPool
    FuzzStructPool.build_pool!()
    repro($(var)::$(T0)) = $(bodystr)
    _x = $(inp)
    _c = deepcopy(_x)
    _nat = try (:ok, repro(_c)) catch e (:throw, e) end
    _rt = Base.widenconst(Base.code_typed(repro, ($(T0),))[1][2])
    _res = FuzzBridgeArgs.bridge_run_args(repro, ($(T0),), [(deepcopy(_x),)]; rettype = _rt$(optkw))[1]
    _pd = FuzzBridgeArgs.ismutable_shape($(T0)) ? FuzzBridge.descriptor($(T0))[1] : nothing
    _ok = _nat[1] === :throw ? (_res[1] === :trap) :
        (_res[1] === :ok &&
         FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
         (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
    _ok || error("WasmTarget gap$(tag) @ x=\$_x : native=\$(_nat[1] === :throw ? :throw : _nat[2]) wasm=\$(_res[1]) \$(_res[2])")
    """
end

# --- Discovery --------------------------------------------------------------
function fuzz_type(::Type{T0}; depth, max_examples, seed, run_id, dbdir = CORPUS_DIR) where {T0}
    gen = gen_program(T0; depth = depth)
    db = Supposition.DirectoryDB(dbdir)
    res = @check db=db rng=Xoshiro(seed) max_examples=max_examples function diff_prop(body = gen)
        property_holds(body, T0; check_opt = true)   # discovery also hunts wasm-opt unsoundness
    end
    r = something(res.result)
    if r isa Supposition.Fail
        ce = getfield(r, 1)                 # NamedTuple (body = <minimal expr>,)
        minimal = first(values(ce))
        o = differential(minimal, T0; check_opt = true)   # re-derive full details (incl. opt) on the minimal body
        id = _record!(o, T0, minimal; run_id = run_id)
        println("  ✗ $(T0): $(o.category) — minimal `$(minimal)` → gap $id")
        return (false, o.category)
    else
        println("  ✓ $(T0): no counterexample in $max_examples examples (depth $depth)")
        return (true, :ok)
    end
end

function run_fuzz(; types = (Int64, Float64), depth = 3, max_examples = 200, seed = 0xC0FFEE)
    FuzzHarness.NODE_OK || (@warn "Node.js not available — fuzzer cannot execute wasm"; return)
    run_id = string("run-", seed, "-d", depth)
    println("== WasmTarget differential fuzz ($(run_id)) ==")
    for (i, T0) in enumerate(types)
        fuzz_type(T0; depth = depth, max_examples = max_examples, seed = seed + i, run_id = run_id)
    end
    Ledger.regenerate_index!()
    op = Ledger.open_gaps()
    println("ledger: $(length(op)) open gap(s) → test/fuzz/failures/INDEX.md")
end

# --- Natural-signature discovery (any supported arg type via the bridge) -----
_reproducer_natural(o::Outcome, ::Type{IN}, body) where {IN} = _reproducer(o, IN, body; var = :v)

function _record_natural!(o::Outcome, ::Type{IN}, ::Type{RET}, body; run_id) where {IN,RET}
    construct = "$(o.category): `$(body)` :: $(IN)→$(RET)"
    diag = if o.category === :compile_error
        sprint(showerror, o.detail)
    else
        nat = o.native === nothing ? "?" : (o.native[1] === :throw ? "throw $(typeof(o.native[2]))" : repr(o.native[2]))
        wsm = o.wasm === nothing ? "?" : (o.wasm[1] === :trap ? "trap" : repr(o.wasm[2]))
        "at v=$(o.input === nothing ? "?" : repr(o.input[1])): native=$nat  wasm=$wsm"
    end
    g = Ledger.Gap(o.category, o.category, construct, "test/fuzz (natural)", "repro", "($(IN),)",
                   _reproducer_natural(o, IN, body), diag)
    return Ledger.record_gap!(g; run_id = run_id)
end

function fuzz_natural(::Type{IN}, ::Type{RET}; depth, max_examples, seed, run_id, dbdir) where {IN,RET}
    gen = gen_natural(IN, RET; depth = depth)
    db = Supposition.DirectoryDB(dbdir)
    res = @check db=db rng=Xoshiro(seed) max_examples=max_examples function nat_prop(body = gen)
        property_holds_natural(body, IN; check_opt = true)   # discovery also hunts wasm-opt unsoundness
    end
    r = something(res.result)
    if r isa Supposition.Fail
        minimal = first(values(getfield(r, 1)))
        o = differential_natural(minimal, IN; check_opt = true)
        id = _record_natural!(o, IN, RET, minimal; run_id = run_id)
        println("  ✗ $(IN)→$(RET): $(o.category) — `$(minimal)` → gap $id")
        return false
    else
        println("  ✓ $(IN)→$(RET): clean ($max_examples ex, depth $depth)")
        return true
    end
end

# Natural-signature sweep: Vector inputs, multiple return types, many seeds (temp DBs).
function sweep_natural(; k::Int = 6, depth = 4, max_examples = 50)
    FuzzHarness.NODE_OK || (@warn "Node.js unavailable"; return)
    specs = [(Vector{Int64}, Int64), (Vector{Int64}, Vector{Int64}), (Vector{Int64}, Bool),
             (Vector{Float64}, Float64), (Vector{Float64}, Vector{Float64})]
    before = Set(get(g, "id", "") for g in Ledger.load_gaps())
    for s in 1:k
        run_id = string("nat-", s, "-d", depth)
        for (i, (IN, RET)) in enumerate(specs)
            tmp = mktempdir()
            try
                fuzz_natural(IN, RET; depth = depth, max_examples = max_examples,
                             seed = 0x9E3779B9 * s + i, run_id = run_id, dbdir = tmp)
            catch e
                println("  seed $s $(IN)→$(RET): sweep error $(typeof(e))")
            end
        end
    end
    Ledger.regenerate_index!()
    after = Ledger.load_gaps()
    newids = [get(g, "id", "") for g in after if !(get(g, "id", "") in before)]
    println("\n== natural sweep complete: $(length(after)) total, $(length(newids)) new ==")
    for g in filter(gg -> get(gg, "status", "open") == "open", after)
        println("  [", get(g, "category", "?"), "] ", get(g, "id", "?"), " — ", get(g, "construct", ""))
    end
end

# --- Inventory sweep: many independent seeds (temp DBs) to surface breadth ---
# Each seed explores with a FRESH temp DB so the committed corpus doesn't keep
# replaying the same known counterexample — this is how we find DISTINCT bugs
# before fixing any. Records each distinct gap to the real ledger.
function sweep(; k::Int = 8, types = (Int64, Float64), depth = 4, max_examples = 80)
    FuzzHarness.NODE_OK || (@warn "Node.js unavailable"; return)
    before = Set(get(g, "id", "") for g in Ledger.load_gaps())
    for s in 1:k
        run_id = string("sweep-", s, "-d", depth)
        for (i, T0) in enumerate(types)
            tmp = mktempdir()
            try
                fuzz_type(T0; depth = depth, max_examples = max_examples,
                          seed = 0x9E3779B9 * s + i, run_id = run_id, dbdir = tmp)
            catch e
                println("  seed $s $(T0): sweep error $(typeof(e))")
            end
        end
    end
    Ledger.regenerate_index!()
    after = Ledger.load_gaps()
    newids = [get(g, "id", "") for g in after if !(get(g, "id", "") in before)]
    println("\n== sweep complete: $(length(after)) total gap(s), $(length(newids)) new ==")
    for g in after
        get(g, "status", "open") == "open" || continue
        println("  [", get(g, "category", "?"), "] ", get(g, "id", "?"), " — ", get(g, "construct", ""))
    end
end

# --- Verify (re-run open gaps, auto-close fixed) ----------------------------
function verify()
    println("== verifying open gaps ==")
    Ledger.verify_gaps!()
end

# --- CI entry: bounded, deterministic, NO committed writes ------------------
# Replays the committed corpus first (regression ratchet), then a small fixed-seed
# budget, writing only to a temp DB. Returns true iff every check passes. Used by
# the in-suite fuzz testset so CI catches regressions without growing the corpus.
# Bodies of gaps already OPEN in the ledger. The bounded CI fuzz is a REGRESSION
# ratchet, not a discovery gate — re-discovering a KNOWN, already-triaged divergence
# must not turn the suite red (an active fuzzing project always has open gaps); only
# a NEW, unknown divergence should. (Fixed gaps are NOT skipped, so a regression of a
# fix still fails.) Deep discovery of new gaps happens in `run.jl` sweeps.
function _known_gap_bodies()
    bodies = Set{String}()
    try
        for g in Ledger.open_gaps()
            m = match(r"`(.*)`", get(g, "construct", ""))   # construct: "<cat>: `<body>` :: <ty>"
            m !== nothing && push!(bodies, m.captures[1])
        end
    catch
    end
    return bodies
end

# True if `sb` (a generated body, stringified) CONTAINS a known-open gap's body as a
# sub-expression — i.e. it fails for an already-tracked reason. Substring match so a
# new composition around a known-bad sub-expression (e.g. `Float64(typemax)`) is also
# tolerated; only a divergence with no known root turns the gate red.
_hits_known_gap(sb::AbstractString, known) = any(kb -> !isempty(kb) && occursin(kb, sb), known)

function ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
    FuzzHarness.NODE_OK || return true   # skip cleanly where Node is unavailable
    tmp = mktempdir()
    # seed the temp DB with the committed corpus so known counterexamples replay first
    if isdir(CORPUS_DIR)
        for f in readdir(CORPUS_DIR)
            startswith(f, ".") && continue   # skip .gitkeep and other non-DB files
            cp(joinpath(CORPUS_DIR, f), joinpath(tmp, f); force = true)
        end
    end
    known = _known_gap_bodies()
    allpass = true
    for (i, T0) in enumerate(types)
        gen = gen_program(T0; depth = depth)
        db = Supposition.DirectoryDB(tmp)
        res = @check db=db rng=Xoshiro(seed + i) max_examples=max_examples function ci_prop(body = gen)
            property_holds(body, T0) || _hits_known_gap(string(body), known)   # known-open gaps don't fail the ratchet
        end
        something(res.result) isa Supposition.Fail && (allpass = false)
    end
    return allpass
end

# --- Coverage metric: which ops are exercised + verified-passing ------------
const _COV_SEEN = Dict{Symbol,Int}()
const _COV_PASS = Dict{Symbol,Int}()

_call_heads(x) = (acc = Symbol[]; _walk_heads!(acc, x); acc)
function _walk_heads!(acc, x)
    if x isa Expr
        if x.head === :call && !isempty(x.args) && x.args[1] isa Symbol
            push!(acc, x.args[1])
        end
        for a in x.args
            _walk_heads!(acc, a)
        end
    end
    return acc
end

function _record_coverage!(body, passed::Bool)
    for s in _call_heads(body)
        _COV_SEEN[s] = get(_COV_SEEN, s, 0) + 1
        passed && (_COV_PASS[s] = get(_COV_PASS, s, 0) + 1)
    end
end

function coverage_report()
    allops = Set(e[1] for e in FuzzGen.OPS)
    seen   = Set(keys(_COV_SEEN))
    passed = Set(k for (k, v) in _COV_PASS if v > 0)
    println("== op-symbol coverage ==")
    println("  $(length(intersect(seen, allops)))/$(length(allops)) op symbols exercised; ",
            "$(length(intersect(passed, allops))) verified-passing")
    unseen = sort(collect(setdiff(allops, seen)); by = string)
    isempty(unseen) || println("  unseen:               ", join(unseen, ", "))
    failonly = sort(collect(setdiff(intersect(seen, allops), passed)); by = string)
    isempty(failonly) || println("  seen-but-never-passed: ", join(failonly, ", "))
end

# Generate n programs per type, run differential on each, record op coverage.
function coverage_sweep(; n::Int = 400, depth = 4, types = (Int64, Float64))
    FuzzHarness.NODE_OK || (@warn "Node.js unavailable"; return)
    empty!(_COV_SEEN); empty!(_COV_PASS)
    for T in types
        gen = gen_program(T; depth = depth)
        for _ in 1:n
            body = try; Supposition.example(gen); catch; continue; end
            o = try; differential(body, T); catch; continue; end
            o.category === :skip && continue
            _record_coverage!(body, o.category === :ok)
        end
    end
    coverage_report()
end

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) >= 1 && ARGS[1] == "verify"
        verify()
    elseif length(ARGS) >= 1 && ARGS[1] == "coverage"
        coverage_sweep()
    else
        run_fuzz()
    end
end
