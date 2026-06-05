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
#
# Float comparison: NaN==NaN and ±Inf match; otherwise exact or ULP-tolerant
# (wasm's libm ≠ openlibm for transcendentals).

module FuzzProperty

export differential, property_holds, Outcome
export differential_natural, property_holds_natural

using WasmTarget

# pulls in FuzzHarness + FuzzGen (included by the entrypoint before this file)
using ..FuzzHarness: compile_and_run, compile_and_run_vec
using ..FuzzGen: make_function, sample_inputs, make_function_natural, vector_inputs

struct Outcome
    category::Symbol            # :ok :wrong_value :runtime_trap :divergent_throw :compile_error :skip
    src::String                 # function source
    input::Any                  # failing input tuple (or nothing)
    native::Any                 # (:ok,v)/(:throw,e) at the failing input
    wasm::Any                   # (:ok,v)/(:trap,msg) at the failing input
    detail::Any                 # raw extra (exception, body, …)
end

function vals_match(a, b)
    if a isa AbstractFloat || b isa AbstractFloat
        fa = float(a); fb = float(b)
        (isnan(fa) && isnan(fb)) && return true
        (isinf(fa) && isinf(fb) && sign(fa) == sign(fb)) && return true
        fa == fb && return true
        return isapprox(fa, fb; rtol = 1e-9, atol = 1e-12)
    end
    return a == b
end

function classify(nv, wv)
    nstat, _ = nv
    wstat, _ = wv
    if nstat === :ok && wstat === :ok
        return vals_match(nv[2], wv[2]) ? :match : :wrong_value
    elseif nstat === :ok && wstat === :trap
        return :runtime_trap
    elseif nstat === :throw && wstat === :ok
        return :divergent_throw
    else
        return :match   # both error → acceptable (catalogued in STUBBED_METHODS.md)
    end
end

"""
    differential(body, T0) -> Outcome

Run the full native-vs-wasm differential for one generated body. Returns the
first non-matching `Outcome`, or `Outcome(:ok, …)` if every sample matched.
"""
function differential(body, ::Type{T0}) where {T0}
    fn, _, src = make_function(body, T0)
    samples = sample_inputs(T0)

    natives = map(samples) do tup
        try
            (:ok, Base.invokelatest(fn, tup...))
        catch e
            (:throw, e)
        end
    end

    wres = compile_and_run(fn, (T0,), samples; strict = true)
    if wres === :no_node
        return Outcome(:skip, src, nothing, nothing, nothing, nothing)
    elseif wres isa Pair && wres.first === :compile_error
        return Outcome(:compile_error, src, samples[1], natives[1], (:trap, "compile"), wres.second)
    elseif wres isa Pair
        return Outcome(:skip, src, nothing, nothing, nothing, wres.second)
    end

    for (i, (nv, wv)) in enumerate(zip(natives, wres))
        cat = classify(nv, wv)
        cat === :match && continue
        return Outcome(cat, src, samples[i], nv, wv, body)
    end
    return Outcome(:ok, src, nothing, nothing, nothing, body)
end

"""
    property_holds(body, T0) -> Bool

The Supposition property: true iff native and wasm agree on every sample (or the
run is skipped). Returning false drives Supposition to shrink `body`.
"""
property_holds(body, ::Type{T0}) where {T0} =
    differential(body, T0).category in (:ok, :skip)

# --- Natural-signature differential (Vector/etc. args via marshalling bridge) ---
"""
    differential_natural(body, IN; var=:v) -> Outcome

Like `differential`, but the generated function takes a real `IN`-typed argument
(e.g. `Vector{Int64}`) marshalled across the bridge, evaluated over edge-biased
`vector_inputs`. The return type is whatever `body` infers to.
"""
function differential_natural(body, ::Type{IN}; var::Symbol = :v) where {IN}
    fn, _, src = make_function_natural(body, IN; var = var)
    samples = vector_inputs(eltype(IN))

    natives = map(samples) do tup
        try
            (:ok, Base.invokelatest(fn, tup...))
        catch e
            (:throw, e)
        end
    end

    wres = compile_and_run_vec(fn, (IN,), samples; strict = true)
    if wres === :no_node
        return Outcome(:skip, src, nothing, nothing, nothing, nothing)
    elseif wres isa Pair && wres.first === :compile_error
        return Outcome(:compile_error, src, samples[1], natives[1], (:trap, "compile"), wres.second)
    elseif wres isa Pair
        return Outcome(:skip, src, nothing, nothing, nothing, wres.second)
    end

    for (i, (nv, wv)) in enumerate(zip(natives, wres))
        cat = classify(nv, wv)
        cat === :match && continue
        return Outcome(cat, src, samples[i], nv, wv, body)
    end
    return Outcome(:ok, src, nothing, nothing, nothing, body)
end

property_holds_natural(body, ::Type{IN}; var::Symbol = :v) where {IN} =
    differential_natural(body, IN; var = var).category in (:ok, :skip)

end # module FuzzProperty
