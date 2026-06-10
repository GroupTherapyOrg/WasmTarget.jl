---
id: 1bcba768a3ed
status: open
category: wrong_value
kind: wrong_value
construct: "wrong_value: `try\n    first([x, x, getindex([Int32(0), Int32(0), x], 0)])\ncatch\n    begin\n        acc_bc = x\n        i_bc = Int64(0)\n        while i_bc < Int64(1)\n            acc_bc = x\n            i_bc = i_bc + Int64(1)\n        end\n        acc_bc\n    end\nend` :: Int32"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(Int32,)"
first_seen: sweep-stmt-4
---

# Gap `1bcba768a3ed` — wrong_value: `try
    first([x, x, getindex([Int32(0), Int32(0), x], 0)])
catch
    begin
        acc_bc = x
        i_bc = Int64(0)
        while i_bc < Int64(1)
            acc_bc = x
            i_bc = i_bc + Int64(1)
        end
        acc_bc
    end
end` :: Int32

**Category:** `wrong_value` &nbsp;•&nbsp; **Kind:** `wrong_value` &nbsp;•&nbsp; **Location:** `test/fuzz (generated)`

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
    first([x, x, getindex([Int32(0), Int32(0), x], 0)])
catch
    begin
        acc_bc = x
        i_bc = Int64(0)
        while i_bc < Int64(1)
            acc_bc = x
            i_bc = i_bc + Int64(1)
        end
        acc_bc
    end
end
_x = Int32(1)
_c = deepcopy(_x)
_nat = try (:ok, repro(_c)); catch e; (:throw, e); end
_rt = Core.Compiler.widenconst(Base.code_typed(repro, (Int32,))[1][2])
_rt === Union{} && (_rt = Int64)   # always-throws body: result never walked, any rettype compiles
_rr = FuzzBridgeArgs.bridge_run_args(repro, (Int32,), [(deepcopy(_x),)]; rettype = _rt)
_rr isa Vector || error("bridge could not run reproducer: " * string(_rr))
_res = _rr[1]
_pd = FuzzBridgeArgs.ismutable_shape(Int32) ? FuzzBridge.descriptor(Int32)[1] : nothing
_ok = _nat[1] === :throw ? (_res[1] === :trap) :
    (_res[1] === :ok &&
     FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
     (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
_ok || error("WasmTarget gap @ x=$_x : native=$(_nat[1] === :throw ? :throw : _nat[2]) wasm=$(_res[1]) $(_res[2])")
```

## Diagnostic
```
at x=1: native=1  wasm=0
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_
