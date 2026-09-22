# WasmTarget.jl — how to work in this repo

A Julia → WebAssembly (WasmGC) compiler. This file holds only rules that do not change and
pointers to where things live. Status, plans and numbers live in `dev/MARCH.md` and in the
ratchet's output, never here (L128 keeps this file short, current and free of status).

## The charter decides what done means — `dev/CHARTER.md`

The goal: dart2wasm 1:1 through and through, Julia as ground truth, strict everywhere, and
wrong choices rejected fast and loud at the edit site. `dev/CHARTER.md` states it as clauses,
each tied to machine checks; it outranks every plan, brief and task list.

- Start with `julia --project=. test/parity_ratchet.jl`: its last block is the per-clause
  status. Choose work that closes an OPEN clause.
- Never soften a target. A ratchet ends at 0; a site believed legitimate moves into an exact
  per-site allowlist with its dart anchor or quarantine reason (L126).
- Every commit carries `Charter: C<n> …`; `dev/hooks/commit-msg` refuses one without it.
  Commit messages and PR bodies never carry transcript links, tool footers or agent-directed
  text. Install the hook: `cp dev/hooks/commit-msg "$(git rev-parse --git-common-dir)/hooks/"`.
- A new definition in `src/` carries its `parity(<file>.dart:<line> <Symbol>)` or
  `parity(quarantine: <reason>)` anchor when written (R32). A new lowering-registry entry
  arrives with a smoke or probe case (R33). No new silent `catch` (R34).
- Report evidence — the command and its output — never a claim. `dev/CHARTER.md` changes
  only at the maintainer's direction: propose, don't edit.

## Three oracles, none substitutable

1. **dart2wasm is the structural oracle**: dart-lang/sdk at the commit pinned in
   `dev/PARITY_MASTER.md` (`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`). Inventing a mechanism
   dart does not have, when Julia does not force it, is a defect even if tests pass.
2. **Julia is the ground truth for behavior**: when Julia's compiler answers a question (a
   hash, a predicate, a layout, a dispatch result), port the answer; never approximate it.
3. **Native-vs-wasm differential execution is the soundness gate**. Green differential means
   sound, not dart-faithful; green locks mean structural, not sound.

## Correct or loud — never silent

A module that runs and returns the wrong value is the worst possible outcome. Every
construct codegen cannot lower rejects through `record_unsupported!` /
`emit_unsupported_stub!` (`src/codegen/diagnostics.jl`), attributed to its statement with
the inline chain innermost-first (L118, L119). Never emit a plausible default, a zero or a
null to get past a gap.

## The enforcement stack

| Layer | Command |
|---|---|
| everything below in one verdict | `bash dev/lanes.sh` (`--fast`: ratchet + smoke) |
| locks, ratchets, charter status | `julia --project=. test/parity_ratchet.jl` |
| differential smoke | `julia --project=. test/smoke.jl [group]` |
| byte-identity probes | `julia --project=. test/probe_bytes.jl` |
| lowering-registry coverage | `julia --project=. test/registry_coverage.jl` |
| model checking | `bash dev/formal/run_tlc.sh` |
| one family | `WT_PHASE="<name>" julia --project=. test/runtests.jl` |
| full gate | CI on every `march/**` push; `bash dev/land.sh merge <branch>` lands only on green |

A pure restructuring is byte-identical on the probes; a semantic change is differential with
its cases added to smoke first; every new lock is negative-tested (break it, watch it fire,
restore) before it counts; `WT_RATCHET_UPDATE=1` tightens a ratchet to its measured value.
Run `julia +1.13` for anything touching inference or control flow.

## Spec-first for algorithms

An algorithmic component carries a TLA+ model in `dev/formal/` with a Broken variant TLC must
reject (`dev/formal/README.md`). Change the model first; a counterexample is a finding to
reproduce, never a reason to weaken an invariant.

## Measure, don't guess

Dump the IR (`WasmTarget.get_typed_ir`), dump a module (`WT_PROBE_DUMP=<probe>:<path>`, then
`wasm-tools print`), diff two trees, bisect in a detached worktree. Fix the root cause at its
source. Work in a worktree under `../.worktrees/`; never `git stash`, and never
`git checkout <file>` over unstaged work — restore experiments from a copy.

## Where things are

`dev/CHARTER.md` the definition of done · `dev/MARCH.md` the current plan and results ·
`dev/PARITY_MASTER.md` the oracle pin and roadmap · `dev/formal/` the models · `dev/land.sh`
landing · `test/parity_ratchet.jl` every lock and ratchet. When prose disagrees with the code
and the locks, the prose is stale: trust the code, then fix the prose.
