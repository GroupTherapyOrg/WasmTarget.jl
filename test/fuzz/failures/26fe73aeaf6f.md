---
id: 26fe73aeaf6f
status: fixed
category: divergent_throw
kind: divergent_throw
construct: "divergent_throw: `pushfirst!(v, first(v))` :: Vector{Int64}→Vector{Int64}"
location: "test/fuzz (natural)"
fn_name: repro
arg_types: "(Vector{Int64},)"
first_seen: nat-2-d4
---

# Gap `26fe73aeaf6f` — divergent_throw: `pushfirst!(v, first(v))` :: Vector{Int64}→Vector{Int64}

**Category:** `divergent_throw` &nbsp;•&nbsp; **Kind:** `divergent_throw` &nbsp;•&nbsp; **Location:** `test/fuzz (natural)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
repro(v::Vector{Int64}) = pushfirst!(v, first(v))
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
_v = Int64[]
_nat = try (true, repro(deepcopy(_v))) catch; (false, nothing) end   # deepcopy: don't let mutation alias wasm's input
_r = FuzzHarness.compile_and_run_vec(repro, (Vector{Int64},), [(deepcopy(_v),)])[1]
_ok = _nat[1] ? (_r[1] === :ok && _m(_nat[2], _r[2])) : (_r[1] === :trap)
_ok || error("WasmTarget gap @ v=$_v : native=$(_nat[1] ? _nat[2] : :throw) wasm=$_r")
```

## Diagnostic
```
at v=Int64[]: native=throw BoundsError  wasm=[0]
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
