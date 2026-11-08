# The hill

The march is a hill climb: a program scores the compiler, and each agent makes one move that raises
the score without breaking a gate. `dev/climb/climb.py` runs the climb and computes the
score. Every climber, reviewer and auditor reads this file whole. `dev/CHARTER.md` still decides
what done means, and `dev/LEDGER.md` still holds every requirement: the hill is how the march gets
there without drifting and without burning the week's tokens in a day.

## The score

**S = the corpus cases that pass**: test/smoke.jl compiles the case, runs both modules (codegen's and
wasm-opt's) in node, and every answer equals native Julia's on this machine. That is the only thing
that raises S. Of the cases that do not pass:

- `outside`: Julia's trim verifier rejects the program (D32). This is a correct answer and cannot be
  climbed. It is left out of the denominator.
- `unported`: the compile reaches a definition WT has not written yet. Climb these.
- `errored` / `wrong`: a gate (below). Fix it first.

Moves are ranked by **holds**. A hold is the set of cases one rejection site stops: the same kind,
site and reason. A hold's size is how many cases its fix can unlock. `climb.py holds` prints them,
largest first, and a climber takes one.

The corpus does not reach every definition. After its holds come the **src tail's**: one hold per dart file for
the definitions `dev/src_progress.sh kinds` counts as not ported at the scored head (Internal and Guard "to
triage", and the gaps). A tail move must change src/ and bring a case that reaches what it ports (D12).

A hold whose failure is the runner's own gap ("the runner marshals no …", "the reader of its answer does not …")
is the judge failing to read an answer, not the compiler. It goes to a **keeper** (`dev/climb/keeper.md`), whose
move may change only `test/runner.jl` and `test/src/runner.jl`, ports Julia's own representation of the value,
and may flip no case to passing whose failure was not the runner's gap. An audit finding in any other protected
file is the lead's: it goes to the note for Dale, never to a move.

A move counts when a case of its hold passes, or stops at a deeper unported definition that the move
did not itself write. A new stub that moves a case is refusal 3, never progress. S is reported over
the corpus as it stood at launch; cases added since are counted apart.

Behind S, the scoreboard also reports src progress (D40, D46: bodies ported of anchored, never a stub
counted), the runtime library's gaps and the tokens spent. These are tie-breaks, never the climb.

## The gates (a move that breaks one never lands, whatever S gains)

| Gate | Checked by | Why (Dale) |
|---|---|---|
| G1 no case the move makes wrong or errored | the driver's own run of the hold's groups and a sentinel net | D9: "efficient because it fails fast and LOUD" |
| G2 no case that passed stops passing | the pass set, only growing: before landing on the groups run, over the whole corpus at the next score (a loss there is a fix-first hold) | 1.Q; the oscillation of 2026-10-28 |
| G3 the landing check green | `dev/ship.sh` → `dev/check.sh` | D13, D14 |
| G4 a blind fidelity review approves | `dev/climb/reviewer.md`, reviewer outside the climber, itself measured (below) | D1, D2, D45 |
| G5 the judge untouched | the driver refuses the diff | Theo's rule: never let the climber edit the eval |

G5 is the judge untouched:
- The judge's code and the rules may not change at all: every file directly under `test/` but the corpus and its
  times (the smoke, its runner, the src tests' driver and helpers), `dev/climb/`, the
  landing tooling, the depot, the progress counter, the hooks, the ratchet, the charter, the ledger,
  AGENTS.md, CI, Project and Manifest. `climb.py`'s PROTECTED list names each one.
- `test/smoke_corpus.jl` and `test/smoke_times.tsv` may only gain lines. An added line may not touch
  `GROUPS` or `XFAIL`, and may not rebind a name the corpus binds, read by Julia's parser
  (`dev/climb/corpus_names.jl`).
- `dev/formal/` may only gain new files. An existing model changes only by ruling.

G4 is the one gate a model judges, so it is measured like the score (Theo's eval of past failures):
`climb.py judge-eval` reverts small landed fixes of audit findings, each a defect an audit really found, and asks
the reviewer to refuse each revert, blind: each case is a parentless base and one change with a neutral message.
The set is fixed at its first run. Launch runs it during the first score. Under 80% refused, moves hold until the
lead tightens `reviewer.md` and the eval measures it again. Its verdict on each fix is reported,
never scored: a fix is no proof of a clean commit (its first run refused 6 of 6 fixes, two for the open A95S2 and
A96S2 that later audits found in them).

Agents are fenced, each layer measured by a probe agent (2026-11-08):
- Bash runs in Claude Code's sandbox. It writes the worktree and the git objects, never the git config, the
  hooks or the climb's state, which lives outside the repository.
- Every other tool runs only if its allowlist names it ("dontAsk"): Edit and Write only under the agent's worktree,
  and of Kaimon only `start_session`, `ex`, `manage_repl` and `check_eval`, for a climber alone.
- A climber's Kaimon Julia runs under the same kind of seatbelt, through a wrapper in the climb's state: it
  writes only its slot within GroupTherapyOrg and reaches no network but localhost.
- None lands: the pre-push hook passes only origin's `dev/ship.sh`, which refuses an agent's env and any climb
  slot the driver does not ship. The driver alone lands, and a commit reaching origin/wt2 that `dev/ship.sh`'s
  landing log does not name pauses the climb.

The driver re-runs every gate after every change a move makes, including a review's fix.

## The refusals: every way the march drifted before, refused by name

A reviewer refuses a move that does any of these. A climber that finds itself about to do one
stops and reports `blocked`.

1. **Invents.** It builds a piece with no pinned source. Port the nearest 1:1 match instead: dart2wasm
   at the pin, LLVM at its pin, or Julia's own C/Julia at its pin. If none fits, `blocked:no-counterpart`.
   (D1, D42, D45: "NEVER ever build a piece bespoke")
2. **Approximates Julia.** It answers a question Julia's compiler answers (a layout, a predicate, a
   dispatch, a payload) with its own guess. (D3)
3. **Calls a stub complete.** A body that only rejects, or a rejection-only path, is reported as a
   port. (D46)
4. **Hacks the test.** It routes a case around Base, writes a self-golden, mimics a stage, special-cases
   the corpus, or narrows what a case checks. (Dale 2026-10-28: "nothing in the test itself is a hack")
5. **Emits a plausible value past a gap.** A default, zero, null or catch-all stands where a located
   rejection belongs. (D9)
6. **Disguises a stopgap.** It calls a scan, allowlist, ratchet or test "by construction". (D6, D7)
7. **Keeps two paths.** It computes a fact a second time, or leaves the old path beside the new one.
   (D5: "NUKE everything else")
8. **Routes around a bug.** It works around the cause instead of fixing it at its source with a case
   that reaches it. (D12)
9. **Weakens a model.** It loosens a TLA+ invariant to fit the code. (D11)
10. **Leaves a hole in a sum.** It adds a wildcard or misses an arm over a closed sum. (D8)
11. **Judges floats by the wrong oracle.** It rules on a float lowering without native Julia on this
    FMA host as the answer. (2026-11-02: 14 wrong answers landed this way)
12. **Writes process instead of the port.** It edits tooling, prose, the ratchet or the audit log in a
    port move. (2026-11-01–02: 149 of 309 commits touched no src)

## The stages (the top of each hill is set before it is climbed)

1. **The port** (D43, MARCH 1.U). Climb S until every case outside `outside` passes and src progress
   reads its anchored total, Internal triage included.
2. **Fuzzing** (1.V). The seeded generator adds programs to the corpus (Julia, and JS-side interop),
   and S grows a new slope. Every `wrong` it finds is a G1 hold, fixed first.
3. **Drift re-audits** (1.W, run by a ruling when stage 2 tops out). A council scores each of the four audit areas 1 to 10 for fidelity,
   blind, cheapest member first: Opus scores every round, and Fable scores only a round in which Opus
   already gives every area 9 or more (D48). The stage is done when both give every area 9 or more in two
   consecutive rounds.
4. Only then, by Dale's ruling: Lean (1.X), bespoke Julia work (1.Y), and the speed hills (gate seconds,
   compile latency, 1.Z).

## The budget (how the climb lasts the week)

Measured 2026-11-01 10:00Z to 11-02 15:25Z: 838 M weighted tokens, each message counted once, burned the
week's limit in 29 h (spawned lanes, monitors and audits 82%, the resident lead 17%). A long-lived lane read about 450k tokens of context on
every call. (Weighted means cache reads at 0.1, cache writes at 1.25, output at 5.) So:

- **One move per agent.** A climber starts fresh with a brief of a few thousand tokens and only the
  tools it needs (an 8.6k baseline in place of 39k). It exits after one landing or one report.
- **Warm Julia, not fresh processes (D39).** A climber develops in its slot's Kaimon session, about 0.2 s
  a compile against 25 s for a fresh process. The slot and its session stay warm from one move to the
  next. A fresh process is for evidence only, and preflight refuses to launch while Kaimon is down.
- **No resident lead, no LLM monitors.** The driver is a program. The scoreboard and the map are
  programs, and the map is redrawn at every score, landing and audit (D29). Opus rules a stopped hold. Fable is called only when an Opus ruling escalates, at most
  twice a day (D48).
- **A governor.** The driver reads every session of the account from its transcripts (the climb's, a lead's,
  Dale's). It starts no move, and no step within a move, past the day's allowance (the week's limit ÷ 7,
  less a margin). Each run has its own cap.
- **Few retries.** A move resumes its climber at most twice, each resume under a small cap. A hold that stops
  three times is parked for Dale with the default taken. An infrastructure failure is retried
  mechanically and never sent for a ruling.
- **Cheap first.** A review runs one reviewer. A council adds its next member only when the cheaper
  one approves.
