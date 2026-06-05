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
include(joinpath(FUZZ_DIR, "generators.jl"));  using .FuzzGen
include(joinpath(FUZZ_DIR, "property.jl"));     using .FuzzProperty
include(joinpath(FUZZ_DIR, "ledger.jl"));       using .Ledger

const CORPUS_DIR = joinpath(FUZZ_DIR, "corpus")

# --- Build a self-contained reproducer for a gap ----------------------------
# Contract: the snippet THROWS while the gap is present and RUNS CLEANLY once
# fixed. The match logic mirrors FuzzProperty.classify so reproducers stay
# faithful while depending only on WasmTarget + the harness.
function _reproducer(o::Outcome, ::Type{T0}, body) where {T0}
    inp = o.input === nothing ? "0" : repr(o.input[1])
    if o.category === :compile_error
        return """
        using WasmTarget
        repro(x::$(T0)) = $(body)
        WasmTarget.compile(repro, ($(T0),))   # raises while the value-stub gap is present
        """
    end
    return """
    using WasmTarget
    include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
    repro(x::$(T0)) = $(body)
    _m(a, b) = (a isa AbstractFloat || b isa AbstractFloat) ?
        ((isnan(a) && isnan(b)) || (isinf(a) && isinf(b) && sign(a) == sign(b)) ||
         a == b || isapprox(float(a), float(b); rtol = 1e-9, atol = 1e-12)) : (a == b)
    _x = $(inp)
    _threw = try repro(_x); false catch; true end
    _r = FuzzHarness.compile_and_run(repro, ($(T0),), [(_x,)])[1]
    _ok = _threw ? (_r[1] === :trap) : (_r[1] === :ok && _m(repro(_x), _r[2]))
    _ok || error("WasmTarget gap @ x=\$_x : native=\$(_threw ? :throw : repro(_x)) wasm=\$_r")
    """
end

function _record!(o::Outcome, ::Type{T0}, body; run_id) where {T0}
    construct = "$(o.category): `$(body)` :: $(T0)"
    loc = "test/fuzz (generated)"
    diag = if o.category === :compile_error
        sprint(showerror, o.detail)
    else
        nat = o.native === nothing ? "?" : (o.native[1] === :throw ? "throw $(typeof(o.native[2]))" : repr(o.native[2]))
        wsm = o.wasm === nothing ? "?" : (o.wasm[1] === :trap ? "trap" : repr(o.wasm[2]))
        "at x=$(o.input === nothing ? "?" : repr(o.input[1])): native=$nat  wasm=$wsm"
    end
    g = Ledger.Gap(o.category, o.category, construct, loc, "repro", "($(T0),)",
                   _reproducer(o, T0, body), diag)
    return Ledger.record_gap!(g; run_id = run_id)
end

# --- Discovery --------------------------------------------------------------
function fuzz_type(::Type{T0}; depth, max_examples, seed, run_id, dbdir = CORPUS_DIR) where {T0}
    gen = gen_program(T0; depth = depth)
    db = Supposition.DirectoryDB(dbdir)
    res = @check db=db rng=Xoshiro(seed) max_examples=max_examples function diff_prop(body = gen)
        property_holds(body, T0)
    end
    r = something(res.result)
    if r isa Supposition.Fail
        ce = getfield(r, 1)                 # NamedTuple (body = <minimal expr>,)
        minimal = first(values(ce))
        o = differential(minimal, T0)       # re-derive full details on the minimal body
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

# --- Natural-signature discovery (Vector args via the marshalling bridge) ----
function _reproducer_natural(o::Outcome, ::Type{IN}, body) where {IN}
    inp = o.input === nothing ? "$(IN)()" : repr(o.input[1])
    return """
    using WasmTarget
    include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
    repro(v::$(IN)) = $(body)
    function _m(a, b)
        if a isa AbstractVector && b isa AbstractVector
            length(a) == length(b) || return false
            return all(_m(x, y) for (x, y) in zip(a, b))
        elseif a isa AbstractFloat || b isa AbstractFloat
            return (isnan(a) && isnan(b)) || (isinf(a) && isinf(b) && sign(a) == sign(b)) ||
                   a == b || isapprox(float(a), float(b); rtol = 1e-9, atol = 1e-12)
        end
        return a == b
    end
    _v = $(inp)
    _nat = try (true, repro(deepcopy(_v))) catch; (false, nothing) end   # deepcopy: don't let mutation alias wasm's input
    _r = FuzzHarness.compile_and_run_vec(repro, ($(IN),), [(deepcopy(_v),)])[1]
    _ok = _nat[1] ? (_r[1] === :ok && _m(_nat[2], _r[2])) : (_r[1] === :trap)
    _ok || error("WasmTarget gap @ v=\$_v : native=\$(_nat[1] ? _nat[2] : :throw) wasm=\$_r")
    """
end

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
        property_holds_natural(body, IN)
    end
    r = something(res.result)
    if r isa Supposition.Fail
        minimal = first(values(getfield(r, 1)))
        o = differential_natural(minimal, IN)
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
    allpass = true
    for (i, T0) in enumerate(types)
        gen = gen_program(T0; depth = depth)
        db = Supposition.DirectoryDB(tmp)
        res = @check db=db rng=Xoshiro(seed + i) max_examples=max_examples function ci_prop(body = gen)
            property_holds(body, T0)
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
