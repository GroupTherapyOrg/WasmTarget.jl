# ============================================================================
# Differential oracle — native Julia is ground truth; wasm must agree
# ============================================================================
#
# For a generated body, build `f(x::T0)`, evaluate it natively over edge-biased
# sample inputs (native is BOTH the oracle and the validity filter — if it throws
# at construction the program is discarded upstream), compile + run the same
# function in wasm, and compare per input. The classification:
#
#   match           native==wasm (values close), OR both error  → OK
#   wrong_value     both return, values differ                  → SOUNDNESS ALARM
#   runtime_trap    native returns, wasm traps                  → reachable gap
#   divergent_throw native throws, wasm returns                 → wasm over-accepts
#   compile_error   strict compile raised (value-stub)          → known-wrong op
#   optimizer_unsound  RAW wasm matches native but a binaryen-OPTIMIZED build
#                      (wasm-opt -Os / -O3) diverges            → OPTIMIZER ALARM
#
# Every program that the raw build gets RIGHT is re-run through the wasm-opt
# pipeline (`:size`=-Os, `:speed`=-O3); a behavioural change there means the
# optimizer broke semantics — exactly the kind of bug the strict guarantee must
# exclude. (We only opt-check raw-clean programs; a raw gap is reported first.)
#
# Float comparison: NaN==NaN and ±Inf match; otherwise exact or ULP-tolerant
# (wasm's libm ≠ openlibm for transcendentals).

module FuzzProperty

export differential, property_holds, Outcome
export differential_natural, property_holds_natural

using WasmTarget

# pulls in FuzzHarness + FuzzGen (included by the entrypoint before this file)
using ..FuzzHarness: compile_and_run, compile_and_run_vec
using ..FuzzBridge: bridge_run, descriptor, tree_matches, tree_decode, bridge_supported
using ..FuzzBridgeArgs: bridge_run_args, args_supported, ismutable_shape
using ..FuzzGen: make_function, sample_inputs, make_function_natural, vector_inputs
# Float-match tolerances live in the HASH-PINNED frozen oracle policy (loop_guard.sh
# guards it) so the autonomous /loop can't widen them to bury a divergence.
using ..FuzzOraclePolicy: ORACLE_RTOL, ORACLE_ATOL

struct Outcome
    category::Symbol            # :ok :wrong_value :runtime_trap :divergent_throw :compile_error :skip
    src::String                 # function source
    input::Any                  # failing input tuple (or nothing)
    native::Any                 # (:ok,v)/(:throw,e) at the failing input
    wasm::Any                   # (:ok,v)/(:trap,msg) at the failing input
    detail::Any                 # raw extra (exception, body, …)
end

function vals_match(a, b)
    # Elementwise (NaN-aware) for vectors — `[NaN] == [NaN]` is false, so a plain
    # `==` would flag identity-on-NaN as a divergence (false positive).
    if a isa AbstractVector && b isa AbstractVector
        length(a) == length(b) || return false
        return all(vals_match(x, y) for (x, y) in zip(a, b))
    elseif a isa AbstractFloat || b isa AbstractFloat
        fa = float(a); fb = float(b)
        (isnan(fa) && isnan(fb)) && return true
        (isinf(fa) && isinf(fb) && sign(fa) == sign(fb)) && return true
        fa == fb && return true
        return isapprox(fa, fb; rtol = ORACLE_RTOL, atol = ORACLE_ATOL)
    end
    return a == b
end

function classify(nv, wv, cmp = vals_match)
    nstat, _ = nv
    wstat, _ = wv
    if nstat === :ok && wstat === :ok
        return cmp(nv[2], wv[2]) ? :match : :wrong_value
    elseif nstat === :ok && wstat === :trap
        return :runtime_trap
    elseif nstat === :throw && wstat === :ok
        return :divergent_throw
    else
        return :match   # both error → acceptable (catalogued in STUBBED_METHODS.md)
    end
end

# wasm-opt levels every raw-clean program is re-checked against (binaryen).
const OPT_LEVELS = (:size, :speed)   # -Os, -O3

# Run ONE build variant of `fn` over `samples` and return the first non-matching
# Outcome (or `Outcome(:ok,…)` if every sample matched). `runner` is the scalar
# or vector harness; `opt` is `false` (raw) or a wasm-opt level.
# `cmp(native, payload)` decides ok-vs-ok agreement; `dec(payload)` renders the
# wasm payload for DIAGNOSTICS (the bridge returns descriptor trees, not values).
function _run_variant(fn, argtypes, samples, natives, body, src, runner, opt;
                      cmp = vals_match, dec = identity)
    wres = runner(fn, argtypes, samples; strict = true, opt = opt)
    if wres === :no_node || wres === :unsupported
        return Outcome(:skip, src, nothing, nothing, nothing, nothing)
    elseif wres isa Pair && wres.first === :compile_error
        return Outcome(:compile_error, src, samples[1], natives[1], (:trap, "compile"), wres.second)
    elseif wres isa Pair
        return Outcome(:skip, src, nothing, nothing, nothing, wres.second)
    end
    for (i, (nv, wv)) in enumerate(zip(natives, wres))
        cat = classify(nv, wv, cmp)
        cat === :match && continue
        wd = wv[1] === :ok ? (:ok, dec(wv[2])) : wv
        return Outcome(cat, src, samples[i], nv, wd, body)
    end
    return Outcome(:ok, src, nothing, nothing, nothing, body)
end

# Re-check raw-clean program through the wasm-opt pipeline. Returns an
# `:optimizer_unsound` Outcome on the first opt level that diverges, else nothing.
function _opt_check(fn, argtypes, samples, natives, body, src, runner; cmp = vals_match, dec = identity)
    for lvl in OPT_LEVELS
        o = _run_variant(fn, argtypes, samples, natives, body, src, runner, lvl; cmp = cmp, dec = dec)
        o.category in (:ok, :skip, :compile_error) && continue
        return Outcome(:optimizer_unsound, o.src, o.input, o.native, o.wasm, (body, lvl, o.category))
    end
    return nothing
end

"""
    differential(body, T0) -> Outcome

Run the full native-vs-wasm differential for one generated body. Checks the RAW
build, then (if raw is clean) the wasm-opt builds. Returns the first non-matching
`Outcome`, or `Outcome(:ok, …)` if every sample matched on every variant.
"""
function differential(body, ::Type{T0}; check_opt::Bool = false) where {T0}
    fn, _, src = make_function(body, T0)
    samples = sample_inputs(T0)

    # Full-bridge path (args AND results bit-exact, mutation parity) whenever
    # the signature is inside the bridge universe — which covers every type the
    # generator can request, including pool structs / tuples / Char args.
    rt0 = try
        Core.Compiler.widenconst(only(Base.code_typed(fn, (T0,); optimize = true))[2])
    catch
        nothing
    end
    if rt0 isa Type && isconcretetype(rt0) && bridge_supported(rt0) && args_supported(T0)
        return _differential_args(fn, (T0,), samples, body, src, rt0; check_opt = check_opt)
    end

    natives = map(samples) do tup
        try
            (:ok, Base.invokelatest(fn, tup...))
        catch e
            (:throw, e)
        end
    end

    # Bit-exact bridge transport whenever the inferred return type is in the
    # bridge universe (it always is for today's scalar generator — this RETIRES
    # the JSON-decimal-text result path); legacy JSON transport otherwise.
    rt = try
        Core.Compiler.widenconst(only(Base.code_typed(fn, (T0,); optimize = true))[2])
    catch
        nothing
    end
    if rt isa Type && isconcretetype(rt) && bridge_supported(rt)
        desc = descriptor(rt)[1]
        runner = (f, at, s; strict = true, opt = false) ->
            bridge_run(f, at, s; rettype = rt, strict = strict, opt = opt)
        cmp = (n, t) -> tree_matches(desc, n, t)
        dec = t -> tree_decode(desc, t)
    else
        runner, cmp, dec = compile_and_run, vals_match, identity
    end
    raw = _run_variant(fn, (T0,), samples, natives, body, src, runner, false; cmp = cmp, dec = dec)
    (raw.category === :ok && check_opt) || return raw
    opt = _opt_check(fn, (T0,), samples, natives, body, src, runner; cmp = cmp, dec = dec)
    return opt === nothing ? raw : opt
end

"""
    property_holds(body, T0) -> Bool

The Supposition property: true iff native and wasm agree on every sample (or the
run is skipped). Returning false drives Supposition to shrink `body`.
"""
property_holds(body, ::Type{T0}; check_opt::Bool = false) where {T0} =
    differential(body, T0; check_opt).category in (:ok, :skip)

# --- Natural-signature differential (Vector/etc. args via marshalling bridge) ---
"""
    differential_natural(body, IN; var=:v) -> Outcome

Like `differential`, but the generated function takes a real `IN`-typed argument
(e.g. `Vector{Int64}`) marshalled across the bridge, evaluated over edge-biased
`vector_inputs`. The return type is whatever `body` infers to.
"""
function differential_natural(body, ::Type{IN}; var::Symbol = :v, check_opt::Bool = false) where {IN}
    fn, _, src = make_function_natural(body, IN; var = var)
    samples = vector_inputs(eltype(IN))

    rt = try
        Core.Compiler.widenconst(only(Base.code_typed(fn, (IN,); optimize = true))[2])
    catch
        nothing
    end
    # P2-batch26 (gap 56af911c52b2): a rettype CONTAINING Union{} (e.g.
    # Vector{Union{}} from `map` with an always-throwing closure) is
    # degenerate — the value can only ever be an empty container, whose
    # native/wasm representations are unrelatable across the JS boundary.
    # The throwing (non-empty) path already compares correctly as
    # throw ↔ trap, so these programs carry no differential evidence. Skip.
    # (rt === Union{} itself — the whole body always throws — stays testable.)
    _contains_bottom(@nospecialize T) = T === Union{} ||
        (T isa DataType && any(p -> p isa Type && _contains_bottom(p), T.parameters))
    if rt isa Type && rt !== Union{} && _contains_bottom(rt)
        return Outcome(:skip, src, nothing, nothing, nothing, nothing)
    end
    if rt isa Type && isconcretetype(rt) && bridge_supported(rt) && args_supported(IN)
        return _differential_args(fn, (IN,), samples, body, src, rt; check_opt = check_opt)
    end

    # Legacy fallback (return type outside the bridge universe).
    # Run native on DEEPCOPIES — mutating ops (push!/sort!/…) must not corrupt the
    # samples that wasm marshals next, or we'd compare native(mutated) vs wasm(pristine).
    natives = map(samples) do tup
        try
            (:ok, Base.invokelatest(fn, deepcopy(tup)...))
        catch e
            (:throw, e)
        end
    end

    raw = _run_variant(fn, (IN,), samples, natives, body, src, compile_and_run_vec, false)
    (raw.category === :ok && check_opt) || return raw
    opt = _opt_check(fn, (IN,), samples, natives, body, src, compile_and_run_vec)
    return opt === nothing ? raw : opt
end

# ── Full-bridge differential: arbitrary supported args AND returns, WITH
# mutation parity — wasm must mutate its arguments exactly like native does.
function _differential_args(fn, argtypes::Tuple, samples, body, src, rt::Type; check_opt::Bool)
    rdesc = descriptor(rt)[1]
    pdescs = Any[ismutable_shape(T) ? descriptor(T)[1] : nothing for T in argtypes]
    # Native runs on its OWN deepcopies, which we KEEP — they are the expected
    # post-call argument states for the mutation-parity comparison.
    natpairs = map(samples) do tup
        c = deepcopy(tup)
        v = try
            (:ok, Base.invokelatest(fn, c...))
        catch e
            (:throw, e)
        end
        (v, c)
    end
    function variant(opt)
        wres = bridge_run_args(fn, argtypes, samples; rettype = rt, opt = opt)
        (wres === :no_node || wres === :unsupported) &&
            return Outcome(:skip, src, nothing, nothing, nothing, nothing)
        wres isa Pair && wres.first === :compile_error &&
            return Outcome(:compile_error, src, samples[1], natpairs[1][1], (:trap, "compile"), wres.second)
        wres isa Pair && return Outcome(:skip, src, nothing, nothing, nothing, wres.second)
        for (i, (nv, npost)) in enumerate(natpairs)
            w = wres[i]
            nstat, wstat = nv[1], w[1]
            if nstat === :ok && wstat === :ok
                retok = tree_matches(rdesc, nv[2], w[2])
                mutok = all(j -> pdescs[j] === nothing ||
                                 tree_matches(pdescs[j], npost[j], w[3][j]), eachindex(pdescs))
                (retok && mutok) && continue
                wd = (:ok, retok ? "(ret ok; arg mutation diverged)" : tree_decode(rdesc, w[2]))
                return Outcome(:wrong_value, src, samples[i], nv, wd, body)
            elseif nstat === :ok && wstat === :trap
                return Outcome(:runtime_trap, src, samples[i], nv, (:trap, w[2]), body)
            elseif nstat === :throw && wstat === :ok
                return Outcome(:divergent_throw, src, samples[i], nv, (:ok, tree_decode(rdesc, w[2])), body)
            end
        end
        return Outcome(:ok, src, nothing, nothing, nothing, body)
    end
    raw = variant(false)
    (raw.category === :ok && check_opt) || return raw
    for lvl in OPT_LEVELS
        o = variant(lvl)
        o.category in (:ok, :skip, :compile_error) && continue
        return Outcome(:optimizer_unsound, o.src, o.input, o.native, o.wasm, (body, lvl, o.category))
    end
    return raw
end

property_holds_natural(body, ::Type{IN}; var::Symbol = :v, check_opt::Bool = false) where {IN} =
    differential_natural(body, IN; var = var, check_opt = check_opt).category in (:ok, :skip)

end # module FuzzProperty
