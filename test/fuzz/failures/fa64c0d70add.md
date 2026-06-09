---
id: fa64c0d70add
status: fixed
category: wrong_value
kind: wrong_value
construct: "wrong_value: `Float64(9223372036854775807)` :: Float64"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Float64,)"
first_seen: ci-bounded-0xCD
---

# Gap `fa64c0d70add` — wrong_value: `Float64(9223372036854775807) + x` :: Float64

**Category:** `wrong_value` &nbsp;•&nbsp; **Kind:** `wrong_value` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
repro(x::Float64) = Float64(9223372036854775807) + x
_m(a, b) = (a isa AbstractFloat || b isa AbstractFloat) ?
    ((isnan(a) && isnan(b)) || (isinf(a) && isinf(b) && sign(a) == sign(b)) ||
     a == b || isapprox(float(a), float(b); rtol = 1e-9, atol = 1e-12)) : (a == b)
_x = 0.0
_threw = try repro(_x); false catch; true end
_r = FuzzHarness.compile_and_run(repro, (Float64,), [(_x,)])[1]
_ok = _threw ? (_r[1] === :trap) : (_r[1] === :ok && _m(repro(_x), _r[2]))
_ok || error("WasmTarget gap @ x=\$_x : native=\$(_threw ? :throw : repro(_x)) wasm=\$_r")
```

## Diagnostic
```
at x=0.0: native=9.223372036854776e18  wasm=-9223372036854775616
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
**SPURIOUS — harness artifact, not a codegen bug. No compiler change was made.**
The wasm module computed `Float64(typemax(Int64)) = 2^63` correctly all along.
The divergence was in the differential harness's *decode* path: with JSON.jl
**0.21** on the Julia side (the env Pkg.test resolved while compat was widened to
`"0.21, 1"`), `JSON.parse` silently wraps the integer literal `9223372036854776000`
(JS's rendering of the f64 `2^63`, which exceeds `typemax(Int64)`) into the garbage
`Int64 -9223372036854775616` — exactly the "wasm" value in the diagnostic above.
JSON 1.x parses it as a `BigInt` and `vals_match` compares it correctly. Fixed by
pinning `JSON = "1"` in Project.toml (the 0.21 compat was never valid; the repo had
deliberately migrated to JSON 1.x in commit 5d82291). Auto-closed by `verify` once
the env was corrected. Lesson for the oracle bridge (ROADMAP §3E): any wasm result
that round-trips through decimal text is exposed to serializer semantics — prefer
tagged/bit-exact encodings for numerics.
