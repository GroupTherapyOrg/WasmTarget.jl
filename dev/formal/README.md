# The formal layer

Model checking is the third enforcement layer beside the locks (syntactic, `test/parity_ratchet.jl`)
and the differential oracle (behavioral, native vs wasm). It exists for the claims neither of those
can exhaust — "for every CFG in the class", "under any discovery order", "no two selectors
collide" — the classes WasmTarget's real bugs lived in. The pattern is JuliaLang/julia's
`doc/src/devdocs/scheduler-wakeup/SchedulerWake.tla` (a TLA+ model of the scheduler wake handshake,
authored with Claude for #61826, checked by TLC over every interleaving); WasmTarget goes one step
further and gates on it.

## Files

| File | Role |
|---|---|
| `<Name>.tla` | the model of the ACTUAL Julia algorithm, read from source; its header says what is abstracted and why that suffices, names the modeled function, and cites the dart anchor (or the quarantine reason) |
| `MC<Name>.tla` / `MC<Name>.cfg` | a small instance: `TypeOK`, the claim invariants/properties, a deadlock check |
| `MC<Name>[Variant]Broken.cfg` | a deliberately wrong variant (a CONSTANT flag mirroring a realistic bug class) that TLC MUST reject — a model no wrong variant can violate proves nothing |
| `run_tlc.sh` | runs every `MC*.cfg`; fails if a Broken instance passes or a positive one fails; fetches TLC v1.7.4 to `~/.cache/wasmtarget` if absent |

The modeled Julia function carries a one-line `# formal(dev/formal/<Name>.tla): <claim>` anchor;
L111 keeps every model paired with its instance, a Broken variant, and an anchor. `formal.yml`
runs the harness on every push.

## Rules

- A change to a modeled algorithm updates the model FIRST and lands with TLC green.
- A new protocol or algorithm is modeled spec-first; the code is checked against the model.
- A TLC counterexample against the real algorithm is a finding: reproduce it in Julia, fix the
  algorithm, keep the invariant. Never weaken an invariant to make TLC pass. (ConsultChain → L113;
  ClassIdDispatch → the dispatch guards; Stackifier's Broken instance is the `b9f4d229` miscompile.)
- Keep instances small enough for CI (seconds to a couple of minutes). If exhaustive enumeration at
  the size that contains a witness is intractable, the Broken instance uses a fixed witness CFG and
  the positive instance stays exhaustive at the tractable size (Stackifier: N=4 exhaustive; N=5 is
  not CI-tractable).
- Commit messages for algorithmic fixes narrate the protocol: the exact shape that breaks, the
  invariant, and why the fix restores it.

## Running

```
bash dev/formal/run_tlc.sh            # every instance
WORKERS=auto bash dev/formal/run_tlc.sh
java -cp ~/.cache/wasmtarget/tla2tools.jar tlc2.TLC -workers auto -config MCStackifier.cfg -deadlock MCStackifier.tla
```
