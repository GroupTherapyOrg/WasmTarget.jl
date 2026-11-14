# WasmTarget.jl — how to work in this repo

A Julia → WebAssembly (WasmGC) compiler. This file holds only rules that do not change and
pointers to where things live. Status, plans and numbers live in `dev/MARCH.md` and in the
ratchet's output, never here (L128 keeps this file short, current and free of status).

## Dale's requirements — `dev/LEDGER.md`

Each line is a row of the ledger, which holds Dale's words, the why and the checks that enforce it.
L206 generates this list from the ledger: every requirement an agent must honour is here.

<!-- ledger:begin -->
- **D1** Copy dart2wasm's structure at the pin; every src definition carries @parity or @quarantine.
- **D2** Green differential means sound, not dart-faithful; parity work is never cleanup.
- **D3** When Julia's compiler answers a question, port its answer; never approximate it.
- **D4** Where dart works around missing overloading, name by the MethodInstance signature.
- **D5** Compute each fact once at its one source; the commit adding it deletes every other path.
- **D6** Strict means the wrong choice cannot be written; a scan, allowlist or ratchet is a stopgap.
- **D7** A construction names its definition, precedent(<ecosystem>: ...) and how Julia differs.
- **D8** Match a closed sum with @exhaustive: no missing arm, no wildcard.
- **D9** Never emit a plausible default, zero or null past a gap; reject at its statement, located.
- **D10** The builder refuses invalid wasm at the emitting line; wasm-tools is only the alarm.
- **D11** Model an algorithm in dev/formal/ first, with a Broken variant; never weaken an invariant.
- **D12** Fix a bug at its source with a case that reaches it; never route around it.
- **D13** Land one small commit with bash dev/ship.sh; a landing takes minutes.
- **D14** bash dev/check.sh is a landing's evidence; it takes about a minute; never edit a budget.
- **D15** A speedup in src is a real fix to WT's algorithm, never a dev flag or test-only path.
- **D16** A landing runs bash dev/check.sh only; the full matrix runs at Closes: C<n>.
- **D17** A number in a check is a target with a band; a check firing inside its band is a bug.
- **D18** Each requirement Dale states becomes a row here with its check the same day.
- **D19** dev/CHARTER.md decides done; every commit names its clause; propose charter edits only.
- **D20** A ratchet ends at 0; a legitimate site moves to an exact allowlist, never a floor.
- **D21** Audit every change within 5 commits; fix findings first; an audit never holds a landing.
- **D22** Decide by the charter and act; a question for Dale carries the default you will take.
- **D23** Every landing goes to the one march branch, wt2; no other branch on origin.
- **D24** No transcript links, tool footers or agent-directed text in commits or PR bodies.
- **D25** AGENTS.md is the only instructions file: timeless rules and pointers, no status.
- **D26** Map the dart code and Julia's IR before writing; name the dart counterpart first.
- **D27** Spend no effort on downstream packages until the rebuild merges.
- **D29** Redraw the project map after every landing, audit and red closure matrix.
- **D30** Work in the plan's order: one source of truth and strict by construction come first.
- **D31** Run one Julia at a time; in the climb, a check with the climb's other Julia stopped.
- **D32** WT compiles the strict subset Julia's verifier defines; outside it, a located rejection.
- **D38** Each lock calls its own <name>_negatives_missed(), run by the ratchet stage in every gate.
- **D39** Start a lane with bash dev/lane.sh start <name>; develop in its live Kaimon session.
- **D40** The rebuild always has a lane porting compiler src; a status leads with src progress.
- **D41** Port dart's tests, Julia's answer the expected value; every dart test file has one entry.
- **D42** Without a dart port, port Julia's compiler and LLVM's (pinned); invent no algorithm.
- **D43** 100% port, then Julia and JS fuzzing, then drift re-audits; nothing bespoke before them.
- **D44** After the re-audits: assess Lean formalization; then bespoke work; then a fast WT package.
- **D45** Build nothing bespoke: port a near 1:1 match (dart, LLVM, Julia's C), pinned and anchored.
- **D46** A stub or rejection-only body is never complete; progress counts bodies only.
- **D47** Climb the hill (dev/climb/HILL.md): one fresh agent, one move, a score the judge keeps.
- **D48** Fable directs and decides; token-heavy work runs in spawned Opus or cheaper Claude agents.
- **D49** Delete a replaced or stale rule outright; never keep it marked superseded.
- **D50** In the climb, start no move while 4 approved commits wait to land.
- **D51** At week-half the climb's lander lands on, spending no tokens; the pause ends at the reset.
- **D52** A climb finding in a protected file waits in for-dale.md; the climb never waits on it.
- **D53** Every agent, Kaimon and Julia job of the climb runs as a build user, never as Dale.
- **D54** Climb agents use a setup-token in a file only Dale reads; a diff holding it is refused.
- **D55** After v6: councils to no blocker, a 12-hour burn-in of 8 landings, then the final verdict.
- **D56** While the climb runs, macOS installs nothing itself; a login notifies Dale to launch.
<!-- ledger:end -->

## How to work

- `dev/CHARTER.md` decides what done means. Start with `julia --project=. test/parity_ratchet.jl`:
  its last block is the per-clause status; choose work that closes an OPEN clause.
- Inside the climb (dev/climb/HILL.md) the brief decides the step; a climb agent never runs
  dev/ship.sh or dev/check.sh, and its clone has the commit hook its driver installed.
- Three oracles, none a stand-in for another: dart2wasm at the commit `dev/PARITY_MASTER.md` pins
  (`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`) for structure, Julia for behavior, and
  native-vs-wasm differential execution for soundness.
- Install the hook: `cp dev/hooks/commit-msg "$(git rev-parse --git-common-dir)/hooks/"`. A new
  lowering-registry entry arrives with a case; no new silent `catch`.
- Report evidence, the command and its output, never a claim. Measure: Julia's typed IR
  (`code_typed`, `Base.code_ircode`) and a module (`wasm-tools print`).
- `src/` mirrors dart2wasm's `lib/` and wasm_builder's `lib/src/` file for file; `src/julia/` holds
  what Julia forces. `legacy/` is WT1, the agreement oracle until its deletion rule (dev/MARCH.md
  1.F): never edit it.
- Work in a worktree under `../.worktrees/`; never `git stash`, never `git checkout <file>` over
  unstaged work. An audit (`dev/AUDIT.md`) reads its range in four areas: builder; collection and
  planning; emission and diagnostics; enforcement and prose.

## The enforcement stack

| Layer | Command |
|---|---|
| land: the lander checks it, about a minute | `python3 dev/climb/climb.py enqueue <ref> <title>` |
| full matrix at clause closure (`Closes: C<n>`), #128's merge head, dispatch | `bash dev/gate.sh` |
| CI, Formal models, Downstream: the same triggers, never a plain landing | `.github/workflows` |
| locks, ratchets, the ledger, charter status | `julia --project=. test/parity_ratchet.jl` |
| differential smoke | `julia --project=. test/smoke.jl [group]` |
| byte-identity probes | `julia --project=. test/probe_bytes.jl` |
| model checking | `bash dev/formal/run_tlc.sh` |
| one QA family | `WT_QA_ONLY="<file>.jl" julia --project=. test/runtests.jl` |

`climb.py enqueue` queues a commit; the lander alone rebases it onto origin/wt2, runs
`bash dev/check.sh` on the test set it chose and lands it (dev/ship.sh, never run by hand);
the full matrix runs only at clause closure (`bash dev/lanes.sh`, L153, L162).
A pure restructuring is byte-identical on the probes; a semantic change is differential, its cases
in smoke first; a new lock fires when broken before it counts; `WT_RATCHET_UPDATE=1` tightens one.

## Where things are

`dev/CHARTER.md` the definition of done · `dev/LEDGER.md` Dale's requirements · `dev/MARCH.md` the
plan · `dev/PARITY_MASTER.md` the oracle pin and scope · `dev/formal/` the models · `dev/ship.sh`
landing · `test/parity_ratchet.jl` every lock and ratchet · `dev/climb/HILL.md` the climb, its
score `python3 dev/climb/climb.py report`. When prose disagrees with the code
and the locks, the prose is stale: trust the code, then fix the prose.
