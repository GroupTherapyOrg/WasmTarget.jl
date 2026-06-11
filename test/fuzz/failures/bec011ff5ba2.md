---
id: bec011ff5ba2
status: fixed
category: runtime_trap
kind: runtime_trap
construct: "PASSING a const-global non-isbits Vector as a callee argument traps; reading its length directly works since v0.3.1 (residual of ffd3d052c6a4) (WASMMAKIE R-002)"
location: "WASMMAKIE draw layer (no_dash)"
fn_name: repro
arg_types: "(Int64,)"
first_seen: wasmmakie-r002
---

# Gap `bec011ff5ba2` — PASSING a const-global non-isbits Vector as a callee argument traps; reading its length directly works since v0.3.1 (residual of ffd3d052c6a4) (WASMMAKIE R-002)

**Category:** `runtime_trap` &nbsp;•&nbsp; **Kind:** `runtime_trap` &nbsp;•&nbsp; **Location:** `WASMMAKIE draw layer (no_dash)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
const EMPTYV2 = Float64[]
@noinline consume(v::Vector{Float64}, x::Int64) = Int64(length(v)) + x
repro(x::Int64) = consume(EMPTYV2, x)
_nat = try (true, repro(Int64(0))) catch; (false, nothing) end
_r = FuzzHarness.compile_and_run_vec(repro, (Int64,), [(Int64(0),)])[1]
_ok = _nat[1] ? (_r[1] === :ok && _nat[2] == _r[2]) : (_r[1] === :trap)
_ok || error("WasmTarget gap: native=$(_nat[1] ? _nat[2] : :throw) wasm=$_r")
```

## Diagnostic
```
native=0 wasm=trap when the const-global flows through an argument
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
