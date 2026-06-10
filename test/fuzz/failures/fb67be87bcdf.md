---
id: fb67be87bcdf
status: open
category: runtime_trap
kind: runtime_trap
construct: "runtime_trap: `try\n    div(0, x)\ncatch\n    x\nend` :: Int32"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Int32,)"
first_seen: sweep-stmt-1
---

# Gap `fb67be87bcdf` — runtime_trap: `try
    div(0, x)
catch
    x
end` :: Int32

**Category:** `runtime_trap` &nbsp;•&nbsp; **Kind:** `runtime_trap` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.
A follow-up loop fixes the compiler, then `verify_gaps!()` re-runs this to auto-close the gap.

```julia
using WasmTarget
include(joinpath("test", "fuzz", "harness.jl"));     using .FuzzHarness
include(joinpath("test", "fuzz", "bridge.jl"));      using .FuzzBridge
include(joinpath("test", "fuzz", "bridge_args.jl")); using .FuzzBridgeArgs
include(joinpath("test", "fuzz", "structpool.jl"));  using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Int32) = try
    div(0, x)
catch
    x
end
_x = Int32(0)
_c = deepcopy(_x)
_nat = try (:ok, repro(_c)); catch e; (:throw, e); end
_rt = Core.Compiler.widenconst(Base.code_typed(repro, (Int32,))[1][2])
_res = FuzzBridgeArgs.bridge_run_args(repro, (Int32,), [(deepcopy(_x),)]; rettype = _rt)[1]
_pd = FuzzBridgeArgs.ismutable_shape(Int32) ? FuzzBridge.descriptor(Int32)[1] : nothing
_ok = _nat[1] === :throw ? (_res[1] === :trap) :
    (_res[1] === :ok &&
     FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
     (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
_ok || error("WasmTarget gap @ x=$_x : native=$(_nat[1] === :throw ? :throw : _nat[2]) wasm=$(_res[1]) $(_res[2])")
```

## Diagnostic
```
at x=0: native=0  wasm=trap
```

## Diagnostic update (P2-batch4, 2026-06-09)
The div-by-zero trap is now a catchable DivideError (guarded intrinsic). The
reproducer still fails because its return type is `Union{Int32, Int64}`
(`div(0, x::Int32)` promotes to Int64; catch arm returns Int32) and
`bridge_run_args` returns `:unsupported` for small-Union returns. ROOT CAUSE
IS NOW BRIDGE TRANSPORT of Union primitive returns, not div codegen.

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
