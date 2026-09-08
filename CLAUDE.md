# WasmTarget.jl — how to work in this repo

A Julia → WebAssembly (WasmGC) compiler. Read this before changing `src/`.

## Three oracles, none substitutable

1. **dart2wasm is the structural oracle** — dart-lang/sdk at the pinned commit
   `898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e` (`dev/PARITY_MASTER.md`). Every structure in
   `src/codegen/` either carries a `parity(<file>.dart:<line> …)` anchor to it, or a
   `parity(quarantine: …)` anchor naming the Julia-only necessity it exists for. There is no
   third category — inventing a mechanism dart already has is a defect even if tests pass.
2. **Julia is the ground truth for behavior** — when Julia's own compiler answers a question
   (a hash, a type predicate, an element stride, a dispatch result), port that answer; never
   approximate it. "Internally consistent" is not correct: a natively-built constant embedded
   in a module must be readable by the module.
3. **Native-vs-wasm differential execution is the soundness gate** — `test/smoke.jl` and the
   `test/runtests.jl` families compare compiled output against the same function run natively.
   Green differential means SOUND, not dart-faithful. Green locks mean STRUCTURAL, not sound.

## Correct or loud — never silent

The worst outcome in this codebase is a module that runs and returns the wrong value. Every
construct codegen cannot lower rejects through `record_unsupported!` /
`emit_unsupported_stub!` (`src/codegen/diagnostics.jl`), which attributes the failure to its
SSA statement and prints the inline chain innermost-first. A bare
`throw(WasmCompileError(WasmDiagnostic(…)))` inside codegen is forbidden (L118); the single
per-statement entry wraps anything else as `WasmInternalError` with the same chain (L119).
Never emit a plausible default, a zero, or a null to get past a gap.

## The enforcement stack

| Layer | What it catches | Command |
|---|---|---|
| Locks + ratchets (`test/parity_ratchet.jl`, `dev/parity_baseline.toml`) | structural regressions; counts may only DECREASE, locks are exact zeros | `julia --project=. test/parity_ratchet.jl` |
| Differential smoke | wrong values, fast | `julia --project=. test/smoke.jl [group]` |
| Byte-identity probes (`test/probe_bytes.jl`) | a mechanism changed without behavior changing; non-reproducible bytes across processes and architectures | `julia --project=. test/probe_bytes.jl` |
| Model checking (`dev/formal/`) | algorithmic claims, exhausted over a bounded class | `bash dev/formal/run_tlc.sh` |
| Families | the area you touched | `WT_PHASE="<name>" julia --project=. test/runtests.jl` |
| Full gate | everything | CI matrix (1.12 + 1.13 × ubuntu/macos/windows) |

Rules: a pure restructuring must be **byte-identical** on the probes; a semantic change must be
**differential** with its cases added to smoke first; every new lock is **negative-tested**
(break it deliberately, watch it fire, restore) before it counts; a ratchet never loosens;
`WT_RATCHET_UPDATE=1` tightens a ratchet to its measured value. Run `julia +1.13` for anything
touching inference or control flow, and the probes under an x64 Julia when emission order can
change.

## Spec-first for algorithms

Components with an algorithmic claim carry a TLA+ model in `dev/formal/` (`<Name>.tla`, an
`MC<Name>` instance, and at least one `MC<Name>*Broken.cfg` that TLC **must** reject — a model
no wrong variant can violate proves nothing). Changing a modeled algorithm means updating the
model first and landing with TLC green. A TLC counterexample against the real algorithm is a
finding to reproduce in Julia, never a reason to weaken the invariant. `formal.yml` gates on it.

## Measure, don't guess

Root-cause with evidence, not hypothesis: dump the IR (`WasmTarget.get_typed_ir`), dump a
module (`WT_PROBE_DUMP=<probe>:<path>` then `wasm-tools print`), diff two trees, bisect in a
detached worktree. Commit messages state only what was measured. Fix the root cause at its
source; a workaround that leaves the cause in place is not a fix.

## Where things are

`dev/MARCH.md` — the current campaign: §0 end state, the phase results, and Phase 12, the
remaining task list. `dev/PARITY_MASTER.md` — the authoritative roadmap and audit stamp.
`dev/CERTIFICATION.md` — the dated source-to-source audit against dart2wasm.
`dev/formal/README.md` — the formal layer's rules. If prose here conflicts with the
implementation, the prose is stale — trust the code and the locks.
