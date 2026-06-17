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
using WasmTarget   # discovery_differential needs disable_cache!
using Statistics   # P4-stdlib: catalogue :stats entries resolve in Main
using Dates: isleapyear, daysinmonth   # P4-stdlib: :dates entries
using Supposition: Data

const FUZZ_DIR = @__DIR__
include(joinpath(FUZZ_DIR, "harness.jl"));     using .FuzzHarness
include(joinpath(FUZZ_DIR, "bridge.jl"));      using .FuzzBridge
include(joinpath(FUZZ_DIR, "bridge_args.jl")); using .FuzzBridgeArgs
include(joinpath(FUZZ_DIR, "catalogue.jl"));   using .FuzzCatalogue
include(joinpath(FUZZ_DIR, "structpool.jl"));  using .FuzzStructPool
include(joinpath(FUZZ_DIR, "generators.jl"));  using .FuzzGen
include(joinpath(FUZZ_DIR, "statements.jl"));  using .FuzzStatements
include(joinpath(FUZZ_DIR, "canon.jl"));       using .FuzzCanon
FuzzStructPool.build_pool!()   # deterministic (seeded) — same pool every process
include(joinpath(FUZZ_DIR, "oracle_policy.jl")); using .FuzzOraclePolicy
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
    # Narrow signed ints repr without their type (`repr(Int32(0)) == "0"`), which
    # would hand repro() an Int64 — wrap them so the literal round-trips typed.
    _lit(v) = v isa Union{Int8, Int16, Int32} ? "$(typeof(v))($(repr(v)))" : repr(v)
    inp = o.input === nothing ? "0" : _lit(o.input[1])
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
    _nat = try (:ok, repro(_c)); catch e; (:throw, e); end
    _rt = Core.Compiler.widenconst(Base.code_typed(repro, ($(T0),))[1][2])
    _rt === Union{} && (_rt = Int64)   # always-throws body: result never walked, any rettype compiles
    _rr = FuzzBridgeArgs.bridge_run_args(repro, ($(T0),), [(deepcopy(_x),)]; rettype = _rt$(optkw))
    _rr isa Vector || error("bridge could not run reproducer: " * string(_rr))
    _res = _rr[1]
    _pd = FuzzBridgeArgs.ismutable_shape($(T0)) ? FuzzBridge.descriptor($(T0))[1] : nothing
    _ok = _nat[1] === :throw ? (_res[1] === :trap) :
        (_res[1] === :ok &&
         FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
         (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
    _ok || error("WasmTarget gap$(tag) @ x=\$_x : native=\$(_nat[1] === :throw ? :throw : _nat[2]) wasm=\$(_res[1]) \$(_res[2])")
    """
end

function _record!(o::Outcome, ::Type{T0}, body; run_id) where {T0}
    # Dedup by ROOT CAUSE (M6): same canonical minimal body as an open gap →
    # don't open a second file.
    if FuzzCanon.canon_matchable(body) && FuzzCanon.canon_str(body) in _known_gap_canon()
        return "dup-of-open-gap"
    end
    construct = "$(o.category): `$(FuzzGen._body_repr(body))` :: $(T0)"
    diag = if o.category === :compile_error
        sprint(showerror, o.detail)
    else
        nat = o.native === nothing ? "?" : (o.native[1] === :throw ? "throw $(typeof(o.native[2]))" : repr(o.native[2]))
        wsm = o.wasm === nothing ? "?" : (o.wasm[1] === :trap ? "trap" : repr(o.wasm[2]))
        "at x=$(o.input === nothing ? "?" : repr(o.input[1])): native=$nat  wasm=$wsm"
    end
    g = Ledger.Gap(o.category, o.category, construct, "test/fuzz (generated)", "repro", "($(T0),)",
                   _reproducer(o, T0, body), diag)
    return Ledger.record_gap!(g; run_id = run_id)
end

# --- Discovery --------------------------------------------------------------
function fuzz_type(::Type{T0}; depth, max_examples, seed, run_id, dbdir = CORPUS_DIR,
                   gen = nothing) where {T0}
    gen = gen === nothing ? gen_program(T0; depth = depth) : gen
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
    if FuzzCanon.canon_matchable(body) && FuzzCanon.canon_str(body) in _known_gap_canon()
        return "dup-of-open-gap"
    end
    construct = "$(o.category): `$(FuzzGen._body_repr(body))` :: $(IN)→$(RET)"
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
    rotate_inputs!(rand(RandomDevice(), UInt64))   # G2b: vary inputs each sweep
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
    rotate_inputs!(rand(RandomDevice(), UInt64))   # G2b: vary inputs each sweep
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
# Known-gap matching is STRUCTURAL (M6): each open gap's minimal body is parsed
# and canonicalized (variables erased, call heads/literals kept); a candidate
# body hits a known gap iff one of its SUBTREES shares the canonical form. (The
# old substring match had a fatal hole: a short gap body like `x` matched every
# program.) Unparseable / pure-variable gap bodies are excluded from the set.
function _known_gap_canon()
    known = Set{String}()
    try
        for g in Ledger.open_gaps()
            m = match(r"`(.*)`", get(g, "construct", ""))   # construct: "<cat>: `<body>` :: <ty>"
            m === nothing && continue
            ex = try Meta.parse(m.captures[1]) catch; nothing end
            (ex !== nothing && FuzzCanon.canon_matchable(ex)) &&
                push!(known, FuzzCanon.canon_str(ex))
        end
    catch
    end
    return known
end
_hits_known_gap(body, known) = FuzzCanon.hits_canon(body, known)

function ci_fuzz_passes(; types = (Int64, Float64), depth = 2, max_examples = 30, seed = 0xCD)
    FuzzHarness.NODE_OK || return true   # skip cleanly where Node is unavailable
    rotate_inputs!(0)   # G2b: CI must stay deterministic — never rotate inputs here
    tmp = mktempdir()
    # seed the temp DB with the committed corpus so known counterexamples replay first
    if isdir(CORPUS_DIR)
        for f in readdir(CORPUS_DIR)
            startswith(f, ".") && continue   # skip .gitkeep and other non-DB files
            cp(joinpath(CORPUS_DIR, f), joinpath(tmp, f); force = true)
        end
    end
    known = _known_gap_canon()
    allpass = true
    for (i, T0) in enumerate(types)
        gen = gen_program(T0; depth = depth)
        db = Supposition.DirectoryDB(tmp)
        res = @check db=db rng=Xoshiro(seed + i) max_examples=max_examples function ci_prop(body = gen)
            property_holds(body, T0) || _hits_known_gap(body, known)   # known-open gaps don't fail the ratchet
        end
        something(res.result) isa Supposition.Fail && (allpass = false)
    end
    return allpass
end

# --- Discovery-mode differential: :trim (default) vs :legacy ----------------
# For each generated body where the DEFAULT (:trim) pipeline is clean
# (native == wasm), require the legacy pipeline to agree with native too.
# A failure shrinks to a minimal body where the two discovery modes diverge.
function _other_mode_agrees(body, ::Type{T0}; mode::Symbol = :legacy) where {T0}
    fn, _, _ = make_function(body, T0)
    samples = sample_inputs(T0)
    rt = try
        Core.Compiler.widenconst(only(Base.code_typed(fn, (T0,); optimize = true))[2])
    catch
        nothing
    end
    (rt isa Type && isconcretetype(rt) && FuzzBridge.bridge_supported(rt)) || return true
    natives = map(samples) do tup
        try
            (:ok, Base.invokelatest(fn, tup...))
        catch e
            (:throw, e)
        end
    end
    all(n -> n[1] === :ok, natives) || return true   # throwy bodies: out of scope here
    wres = FuzzBridge.bridge_run(fn, (T0,), samples; rettype = rt, discovery = mode)
    wres === :no_node && return true
    wres isa Vector || return false                  # compile/exec error under :trim only
    desc = FuzzBridge.descriptor(rt)[1]
    return all(zip(natives, wres)) do (n, w)
        w[1] === :ok && FuzzBridge.tree_matches(desc, n[2], w[2])
    end
end

function discovery_differential(; types = (Int64, Float64), depth = 2,
                                max_examples = 40, seed = 0xD15C,
                                exclude = (:median,))   # known trim residual (show/print machinery)
    FuzzHarness.NODE_OK || return true
    WasmTarget.disable_cache!()   # cache is keyed without discovery mode
    allpass = true
    for (i, T0) in enumerate(types)
        gen = gen_program(T0; depth = depth)
        res = @check rng=Xoshiro(seed + i) max_examples=max_examples function disc_prop(body = gen)
            any(h -> h in exclude, _call_heads(body)) && return true  # documented residuals
            differential(body, T0).category === :ok || return true   # default mode not clean → out of scope
            _other_mode_agrees(body, T0)
        end
        if something(res.result) isa Supposition.Fail
            allpass = false
            println("  ✗ $(T0): discovery modes diverge — see counterexample above")
        else
            println("  ✓ $(T0): :trim agrees with :legacy on $max_examples bodies (depth $depth)")
        end
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

# ============================================================================
# M6 — discovery at scale + the coverage matrix (the Phase-1-complete artifact)
# ============================================================================

# Scalar T0s the sweeps drive. Char is EXCLUDED while transport-blocked
# (gap b9d9c2d60d86) — Char still appears as an intermediate type everywhere.
const SWEEP_TYPES = (Int64, Float64, Int32, UInt8, Bool)

# The deterministic job list a parallel sweep partitions: expression-layer and
# statement-layer programs per scalar type × seed, struct→struct natural
# signatures over the pool, and vector signatures.
function _sweep_jobs(; seeds::Int = 4)
    jobs = Any[]
    for s in 1:seeds, T in SWEEP_TYPES
        push!(jobs, (:expr, T, s))
        push!(jobs, (:stmt, T, s))
    end
    for s in 1:max(1, seeds ÷ 2)
        for p in FuzzStructPool.POOL
            push!(jobs, (:nat, p.T, p.T, s))
        end
        for (IN, RET) in ((Vector{Int64}, Int64), (Vector{Int64}, Vector{Int64}),
                          (Vector{Float64}, Float64), (Vector{Float64}, Vector{Float64}),
                          (Tuple{Int64,Float64}, Tuple{Int64,Float64}))
            push!(jobs, (:nat, IN, RET, s))
        end
    end
    return jobs
end

function _run_job(job; depth, max_examples)
    tmp = mktempdir()
    try
        if job[1] === :expr
            _, T, s = job
            fuzz_type(T; depth = depth, max_examples = max_examples,
                      seed = 0xD15C0 + 7919s, run_id = "sweep-expr-$s", dbdir = tmp)
        elseif job[1] === :stmt
            _, T, s = job
            fuzz_type(T; depth = depth, max_examples = max_examples,
                      seed = 0x57A7 + 7919s, run_id = "sweep-stmt-$s", dbdir = tmp,
                      gen = FuzzStatements.gen_program_stmts(T; depth = depth))
        else
            _, IN, RET, s = job
            fuzz_natural(IN, RET; depth = depth, max_examples = max_examples,
                         seed = 0xA47 + 7919s, run_id = "sweep-nat-$s", dbdir = tmp)
        end
    catch e
        println("  job $job: error $(typeof(e))")
    end
end

"""
    sweep_full(; shard = nothing, seeds = 4, depth = 3, max_examples = 60,
                 time_budget = 0)

The full-universe discovery sweep. `shard = (i, n)` runs the i-th 1/n slice
(0-based) — `sweep_parallel` partitions across processes. `time_budget` (s)
stops cleanly before the next job once exceeded (0 = unbounded); discovery
is stochastic re-sampling, so a truncated sweep is still a valid sweep.
"""
function sweep_full(; shard = nothing, seeds::Int = 4, depth = 3, max_examples = 60,
                    time_budget::Int = 0)
    FuzzHarness.NODE_OK || (@warn "Node.js unavailable"; return)
    rotate_inputs!(rand(RandomDevice(), UInt64))   # G2b: vary inputs each sweep (per worker)
    jobs = _sweep_jobs(seeds = seeds)
    mine = [k for k in eachindex(jobs)
            if shard === nothing || (k - 1) % shard[2] == shard[1]]
    tag = shard === nothing ? "" : "[shard $(shard[1])] "
    t0 = time()
    for (j, k) in enumerate(mine)
        el = round(Int, time() - t0)
        if time_budget > 0 && el > time_budget
            println("$(tag)⏱ time budget $(time_budget)s exhausted — stopping at job $(j)/$(length(mine))")
            break
        end
        println("$(tag)job $(j)/$(length(mine)) $(jobs[k][1]) $(jobs[k][2]) (elapsed $(el)s)")
        flush(stdout)   # progress must be visible through file redirects
        _run_job(jobs[k]; depth = depth, max_examples = max_examples)
    end
end

"""
    sweep_parallel(; procs = max(2, Sys.CPU_THREADS ÷ 2 - 1), seeds = 4, ...)

Process-parallel discovery: N workers each run a disjoint job slice against
the SHARED ledger (ids are content-addressed, so concurrent distinct gaps
coexist); the orchestrator regenerates the index and reports new gaps.
"""
function sweep_parallel(; procs::Int = max(2, Sys.CPU_THREADS - 2), seeds::Int = 4,
                        depth = 3, max_examples = 60, time_budget::Int = 1800)
    before = Set(get(g, "id", "") for g in Ledger.load_gaps())
    file = joinpath(FUZZ_DIR, "run.jl")
    println("== parallel sweep: $procs workers, $(length(_sweep_jobs(seeds = seeds))) jobs, " *
            "time budget $(time_budget)s/worker ==")
    flush(stdout)
    t0 = time()
    cmds = [addenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) $file sweep-shard $(i) $(procs) $(seeds) $(depth) $(max_examples) $(time_budget)`)
            for i in 0:procs-1]
    ps = [run(pipeline(ignorestatus(c); stdout = stdout, stderr = stderr); wait = false) for c in cmds]
    foreach(wait, ps)
    Ledger.regenerate_index!()
    after = Ledger.load_gaps()
    newids = [get(g, "id", "") for g in after if !(get(g, "id", "") in before)]
    nopen = count(g -> get(g, "status", "open") == "open", after)
    println("\n== parallel sweep complete in $(round(Int, time() - t0))s: $nopen open, $(length(newids)) new ==")
    for g in after
        get(g, "id", "") in newids || continue
        println("  NEW [", get(g, "category", "?"), "] ", get(g, "id", "?"), " — ", first(get(g, "construct", ""), 110))
    end
end

# --- Coverage matrix: the checkable definition of Phase-1 coverage -----------
# For every catalogue entry: was it exercised, did it appear in a verified-
# passing program, or is it implicated in an open ledger gap? Regenerate with:
#     julia --project=test/fuzz test/fuzz/run.jl coverage
_sig(name::Symbol, arity::Int) = (name, arity)

function _body_sigs(x, acc = Set{Tuple{Symbol,Int}}())
    if x isa Expr
        if x.head === :call && !isempty(x.args) && x.args[1] isa Symbol
            push!(acc, _sig(x.args[1], length(x.args) - 1))
        elseif x.head === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
            push!(acc, _sig(Symbol(".", x.args[2].value), 1))
        end
        for a in x.args
            _body_sigs(a, acc)
        end
    end
    return acc
end

function write_coverage!(; per_type::Int = 120, depth = 3)
    FuzzHarness.NODE_OK || (@warn "Node.js unavailable"; return)
    seen = Set{Tuple{Symbol,Int}}()
    passed = Set{Tuple{Symbol,Int}}()
    for T in SWEEP_TYPES
        for gen in (gen_program(T; depth = depth),
                    FuzzStatements.gen_program_stmts(T; depth = depth))
            for _ in 1:(per_type ÷ 2)
                body = try Supposition.example(gen) catch; continue end
                sigs = _body_sigs(body)
                union!(seen, sigs)
                o = try differential(body, T) catch; continue end
                o.category === :ok && union!(passed, sigs)
            end
        end
    end
    gapsigs = Set{Tuple{Symbol,Int}}()
    for g in Ledger.open_gaps()
        m = match(r"`(.*)`", get(g, "construct", ""))
        m === nothing && continue
        ex = try Meta.parse(m.captures[1]) catch; nothing end
        ex === nothing && continue
        union!(gapsigs, _body_sigs(ex))
    end
    bymod = Dict{Symbol,Vector{Any}}()
    for e in FuzzGen.OPS
        push!(get!(bymod, e.mod, Any[]), e)
    end
    counts = Dict{Symbol,Int}()
    open(joinpath(FUZZ_DIR, "COVERAGE.md"), "w") do io
        println(io, "# Catalogue Coverage Matrix\n")
        println(io, "Regenerate: `julia --project=test/fuzz test/fuzz/run.jl coverage`\n")
        println(io, "Status per entry: `pass` seen in ≥1 verified-passing program · `gap` implicated")
        println(io, "in an open ledger gap · `seen` exercised without a passing witness yet ·")
        println(io, "`unseen` not sampled this run (sampling is stochastic — rerun with a higher")
        println(io, "budget before treating `unseen` as a coverage hole).\n")
        for mod in sort(collect(keys(bymod)))
            println(io, "## ", mod, "\n")
            println(io, "| op | args | ret | status |")
            println(io, "|---|---|---|---|")
            for e in bymod[mod]
                sg = _sig(e.name, length(e.argtypes))
                st = sg in gapsigs ? "gap" : sg in passed ? "pass" : sg in seen ? "seen" : "unseen"
                counts[Symbol(st)] = get(counts, Symbol(st), 0) + 1
                println(io, "| `", e.name, "` | `", join(e.argtypes, ", "), "` | `", e.ret, "` | ", st, " |")
            end
            println(io)
        end
        println(io, "**Totals:** ", join(("$(v) $(k)" for (k, v) in sort(collect(counts))), " · "))
    end
    println("coverage matrix → test/fuzz/COVERAGE.md  ", sort(collect(counts)))
end

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) >= 1 && ARGS[1] == "verify"
        verify()
    elseif length(ARGS) >= 1 && ARGS[1] == "coverage"
        write_coverage!()
    elseif length(ARGS) >= 1 && ARGS[1] == "sweep"
        # Optional second arg: per-worker time budget in seconds (default 1800).
        sweep_parallel(time_budget = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1800)
    elseif length(ARGS) >= 1 && ARGS[1] == "sweep-shard"
        i, n, seeds, depth, mex = parse.(Int, ARGS[2:6])
        tb = length(ARGS) >= 7 ? parse(Int, ARGS[7]) : 0
        sweep_full(shard = (i, n), seeds = seeds, depth = depth, max_examples = mex,
                   time_budget = tb)
    else
        run_fuzz()
    end
end
