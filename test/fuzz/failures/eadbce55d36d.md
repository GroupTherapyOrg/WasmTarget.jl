---
id: eadbce55d36d
status: fixed
category: compile_error
kind: compile_error
construct: "compile_error: `if 0 in [0, 0, 0]\n    Int8(0) == Int8(0)\nelse\n    begin\n        v_be = cor([0.0, 0.0, 0.0], [0.0, 0.0, 0.0])\n        true\n    end\nend` :: Bool"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Bool,)"
first_seen: sweep-stmt-1
---

# Gap `eadbce55d36d` — compile_error: `if 0 in [0, 0, 0]
    Int8(0) == Int8(0)
else
    begin
        v_be = cor([0.0, 0.0, 0.0], [0.0, 0.0, 0.0])
        true
    end
end` :: Bool

**Category:** `compile_error` &nbsp;•&nbsp; **Kind:** `compile_error` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "structpool.jl")); using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Bool) = if 0 in [0, 0, 0]
    Int8(0) == Int8(0)
else
    begin
        v_be = cor([0.0, 0.0, 0.0], [0.0, 0.0, 0.0])
        true
    end
end
WasmTarget.compile(repro, (Bool,))   # raises while the gap is present
```

## Diagnostic
```
WasmValidationError: wasm-tools rejected the emitted compiled module
error: func 2 failed to validate

Caused by:
    0: type mismatch: expected a type but nothing on stack (at offset 0xc05)


emitted code at the failing offset:
(;@bf2   ;)                                                                                                    local.set 25
(;@bf4   ;)                                                                                                    local.get 25
(;@bf6   ;)                                                                                                    i32.eqz
(;@bf7   ;)                                                                                                    br_if 3 (;@53;)
(;@bf9   ;)                                                                                                    unreachable
(;@bfa   ;)                                                                                                    unreachable
(;@bfb   ;)                                                                                                    i32.eqz
(;@bfc   ;)                                                                                                    br_if 0 (;@56;)
(;@bfe   ;)                                                                                                    global.get 97
(;@c00   ;)                                                                                                    local.set 2
(;@c02   ;)                                                                                                    br 2 (;@54;)
(;@c04   ;)                                                                                                    end
(;@c05   ;)                                                                                                    ref.is_null
(;@c06   ;)                                                                                                    i32.eqz
(;@c07   ;)                                                                                                    local.set 27
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
**FIXED 2026-06-22 (wt-soundness-loop-4).** `cor` cluster — root cause + fix in
[`3fd2f07bfc5c`](3fd2f07bfc5c.md): `WasmInterpreter` disabled concrete-eval
unconditionally, so `Statistics.cor`'s `one(float(nonmissingtype(eltype)))` leaked as
`dynamic` dispatch on Type values → `unreachable` stub → empty-stack validation error.
Fixed by making `concrete_eval_eligible` overlay-aware. Auto-closed via `run.jl verify`.
