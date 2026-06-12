---
id: e1cc83db76ea
status: fixed
category: runtime_trap
kind: runtime_trap
construct: "runtime_trap: `if isodd(Int8(0))\n    0x00\nelse\n    if getindex([true, true, true], length((0, 0)))\n        try\n            div(0x00, 0x00)\n        catch\n            0x00\n        end\n    else\n        0x00\n    end\nend` :: UInt8"
location: "test/fuzz (generated)"
fn_name: repro
arg_types: "(UInt8,)"
first_seen: sweep-stmt-4
---

# Gap `e1cc83db76ea` — runtime_trap: `if isodd(Int8(0))
    0x00
else
    if getindex([true, true, true], length((0, 0)))
        try
            div(0x00, 0x00)
        catch
            0x00
        end
    else
        0x00
    end
end` :: UInt8

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
repro(x::UInt8) = if isodd(Int8(0))
    0x00
else
    if getindex([true, true, true], length((0, 0)))
        try
            div(0x00, 0x00)
        catch
            0x00
        end
    else
        0x00
    end
end
_x = 0x00
_c = deepcopy(_x)
_nat = try (:ok, repro(_c)); catch e; (:throw, e); end
_rt = Core.Compiler.widenconst(Base.code_typed(repro, (UInt8,))[1][2])
_rt === Union{} && (_rt = Int64)   # always-throws body: result never walked, any rettype compiles
_rr = FuzzBridgeArgs.bridge_run_args(repro, (UInt8,), [(deepcopy(_x),)]; rettype = _rt)
_rr isa Vector || error("bridge could not run reproducer: " * string(_rr))
_res = _rr[1]
_pd = FuzzBridgeArgs.ismutable_shape(UInt8) ? FuzzBridge.descriptor(UInt8)[1] : nothing
_ok = _nat[1] === :throw ? (_res[1] === :trap) :
    (_res[1] === :ok &&
     FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
     (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
_ok || error("WasmTarget gap @ x=$_x : native=$(_nat[1] === :throw ? :throw : _nat[2]) wasm=$(_res[1]) $(_res[2])")
```

## Diagnostic
```
at x=0x00: native=0x00  wasm=trap
```

## Work on this
```
julia --project=test/fuzz test/fuzz/run.jl verify
```

## Analysis
_(No analysis yet. Add root-cause notes below the `## Analysis` heading — they are PRESERVED across re-records.)_

## Triage (P3 bugsmash)

Reproduces ONLY with the try/catch present (the truncated construct
without it passes both versions): `if isodd(K) ; C1 else (if cond(vec,
tuple-len); try div catch end else C2) end` — doubly-nested pre-try
branching where the inner region sits in the inner THEN arm and BOTH
other arms return constants. The outer isodd branch's dest points BEFORE
the enter (not a spanning candidate), so dispatch picks the inner branch;
the pre-segment then contains the outer branch whose then-arm return
placement crosses the structure. Next: dump regions/branch dests, walk
the branch-split guards for this shape (likely needs the outermost-
spanning definition extended to GotoIfNots whose TAKEN path exits the
region range entirely).

## Triage 2 (byte-level, P3 bugsmash)

MINIMAL repro (both versions):
`if getindex([true,true,true], 2); try div(0x00,0x00) catch; 0x00 end else 0x00 end`
Routes: single region + has_exit_branch (generate_try_catch_stackified,
P2-batch21 machinery; exit_idx = the spanning GotoIfNot, pre_blocks
truncated before it). WAT at trap (offset 0x3d0):
  array_get 15 → local 20; br 1; end;          ← bounds-ok path
  ref.null any; global.set; throw 0; return; end  ← boundserror arm
  block; UNREACHABLE                              ← br 1 LANDS HERE → trap
The boundscheck diamond's dead `unreachable` (IR stmt after the throw)
is emitted AT the continuation point inside a fresh block — the bounds-ok
`br 1` lands on it. Block-depth bookkeeping breaks in the TRUNCATED pre
subset (block containing exit_idx keeps stmts before it, terminator
nothing). Suspect: the boundscheck-jump/dead-region logic in
generate_stackified_flow treats the truncated block's missing terminator
as fall-through into the dead `unreachable` region instead of skipping
it. Next: dump pre_blocks boundaries for the minimal repro and walk
stackified's dead_regions/boundscheck_jumps for the truncated subset.
