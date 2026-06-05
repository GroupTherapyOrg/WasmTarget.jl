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
function fuzz_type(::Type{T0}; depth, max_examples, seed, run_id) where {T0}
    gen = gen_program(T0; depth = depth)
    db = Supposition.DirectoryDB(CORPUS_DIR)
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

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) >= 1 && ARGS[1] == "verify"
        verify()
    else
        run_fuzz()
    end
end
