# The WasmTarget.jl charter

This is the definition of done for the rewrite (PR #122) and the standard for every change
after it. It outranks every task list, phase plan, agent brief and commit message. A task
is worth doing only to the extent that it closes a clause below; an exit check that
does not close a clause is not an exit. The ratchet reads this file (L125): every check in the
enforcement stack must be cited by a clause, and every check a clause cites must exist.

Changes to this file are made at Dale's direction only. Agents may propose a change in a
report; they never make one to fit where their work stopped.

## Intent (Dale's words, 2026-06-28 … 2026-09-22)

> A CLEAN and PERFECT foundation for all future agent-driven development … dart2wasm's
> battle-tested structure followed VERBATIM; the Julia compiler is the ground truth;
> NOTHING ever reinvents the wheel … as STRICT as possible in EVERY regard … NO stale code,
> NO bloat, NO parallel/confusing pathways, NOTHING dart2wasm doesn't do … the Rust
> analogy: the structure itself makes whole classes of mistakes impossible — anything
> implemented inappropriately becomes clear IMMEDIATELY. (2026-09-01)

> Correct ≠ parity. A passing differential test means SOUND, not DART-FAITHFUL. "Done"
> never applies while not at dart2wasm parity. Don't be OK settling. (2026-06-29)

> WT must be FULLY valid by construction. (2026-07-07) · Formal methods through and
> through. (2026-09-02) · ALWAYS fix the root issue. (2026-06-28)

> The most insanely strict and clean and robust and verified starting point … building
> this out further is seamless, comes with strict guarantees, efficient because it fails
> fast and LOUD, doesn't ALLOW wrong choices in the same way that Rust's compiler doesn't,
> is FULLY 1-1 using dart2wasm as the oracle through and through … this should NEVER be
> sacrificed or forgotten … always at the forefront of everything the agents do and land.
> (2026-09-22)

## The clauses

Each clause is closed when every check it cites is a lock at 0 and every ratchet it cites
has reached 0 and been converted to a lock. `julia --project=. test/parity_ratchet.jl` ends
with the per-clause status. A clause is never closed by argument.

- **C1 · One path.** Every construct has exactly one lowering; every fact has exactly one
  source (one inference path, one numbering, one consult, one type chain, one IR reader).
  Checks: `L1` `L3` `L5` `L10` `L11` `L12` `L17` `L24` `L25` `L26` `L34` `L36` `L40` `L41`
  `L45` `L47` `L61` `L67` `L68` `L69` `L80` `L91` `L97` `L98` `L100` `L102` `L103` `L104`
  `L112` `L113` `L114` `L115` `L117` `L120` `L122` `L124` `R20` `R21` `R29a` `R29b`.
- **C2 · dart2wasm 1:1, through and through.** Every definition in `src/` carries a
  `parity(<file>.dart:<line> <Symbol>)` anchor to dart-lang/sdk `898a1e4b` that names the
  structure it copies, or a `parity(quarantine: <reason>)` naming the Julia-only necessity
  that forces it. Nothing else may exist: a mechanism dart does not have and Julia does not
  force is a defect even when every test passes. Checks: `L2` `L20` `L21` `L23` `L28` `L30`
  `L31` `L32` `L43` `L44` `L46` `L50` `L55` `L77` `L83` `L84` `L86` `L88` `L95` `L110`
  `R32`. Planned: anchors resolve — each cited line exists at the pinned commit and names
  the cited symbol (CI fetches the pinned sources; a missing checkout fails, never skips).
- **C3 · Julia is the ground truth.** When Julia's compiler answers a question (a hash, a
  predicate, a layout, a dispatch result, an exception payload), the answer is ported,
  never approximated; Julia's own bodies compile instead of bespoke re-implementations.
  Checks: `L42` `L52` `L53` `L54` `L56` `L57` `L59` `L62` `L70` `L81` `L82` `L92` `L123`.
  Planned: each bespoke lowering in `INVOKE_INTRINSICS` / `STANDALONE_INTRINSIC_BODIES` is
  either deleted (Julia's body compiles) or carries the reason Julia's body cannot.
- **C4 · Strict in every regard.** Typed internal APIs: return types annotated, no `Any`
  outside named heterogeneous seams, every emitted value typed at its emission.
  Checks: `L9` `L35` `L49` `L74` `R17` `R30` `R31` (with Aqua and ExplicitImports in shard 0).
- **C5 · Wrong choices cannot land.** The Rust analogy: a wrong implementation is rejected
  at the edit site (load-time typing, the enforcing builder, the locks) or by the
  minute-scale lanes, never first by an hour-long run. Every lowering-registry entry is
  exercised by a lane case; a new entry without one fails. Checks: `L16` `L94` `R33`.
- **C6 · Correct or loud, and located.** No silent value, default, substitution or
  fabricated result; every rejection is attributed to its statement with the inline chain
  innermost-first. Checks: `L8` `L15` `L18` `L19` `L37` `L38` `L39` `L48` `L51` `L58` `L60`
  `L63` `L64` `L66` `L71` `L72` `L73` `L75` `L76` `L78` `L79` `L85` `L89` `L90` `L93` `L96`
  `L101` `L118` `L119` `L127` `R34`.
- **C7 · Valid by construction.** The builder models everything wasm validates and throws at
  the emitting line; nothing repairs, truncates or bypasses emitted bytes; wasm-tools is only
  the disagreement alarm. Checks: `L6` `L7` `L13` `L14` `L22` `L27` `L29` `L65` `L87` `L99`.
- **C8 · Formal methods through and through.** Every algorithmic component carries a TLA+
  model with a Broken variant TLC must reject; a change to a modeled algorithm changes the
  model first; a counterexample is a finding, never a reason to weaken an invariant.
  Checks: `L111`. Planned: the list of algorithmic components, each mapped to its model.
- **C9 · Nothing stale, nothing re-derived.** No dead definition, fossil comment, retired
  name, campaign narration, or second computation of a fact the first already produced.
  Checks: `L4` `L106` `L107` `L108` `L109` `L121` `R3` `R5` `R7` `R14` `R15` `R27`.
- **C10 · Fast, precise feedback.** `bash dev/lanes.sh` gives one verdict in minutes; the
  full CI matrix runs on every march branch and is the landing gate (`dev/land.sh merge`);
  a failure names its site.
- **C0 · The charter holds.** Checks: `L125` (this file and the enforcement stack cite each
  other completely) `L126` (no ratchet declares a floor) `L128` (AGENTS.md, the one
  instructions file, stays current and lean).

## Rules that keep the goal from drifting

1. **The charter is the plan.** Work is chosen by the open clauses; `dev/MARCH.md` lists
   the work, this file decides what counts as done.
2. **Targets never soften.** A ratchet's only terminal state is 0. A site believed
   legitimate leaves a ratchet by moving into an exact, per-site allowlist carrying its dart
   anchor or quarantine reason — a reviewable diff — never by relabeling the ratchet a
   "floor" or its sites "legitimate" (L126).
3. **Every landing names what it closes.** Each commit after this charter carries a
   `Charter: C<n> …` trailer; `dev/hooks/commit-msg` refuses a commit without one and CI
   (`message-hygiene`) fails the PR.
4. **Correct ≠ parity.** A green differential never closes a C2 gap; a dart-faithful shape
   never excuses a wrong value.
5. **No parking.** A charter gap found during the work joins the plan; moving it out of
   the rewrite ("next march", "post-march finding") needs Dale's explicit decision.
6. **Evidence, not claims.** An agent's report counts only with the command and its output;
   the orchestrator re-measures, and CI on the exact head that lands is the gate.
7. **Root causes only.** A fix is at the source the fault comes from; a workaround that
   leaves the cause in place is not a fix and does not close anything.

## Drift found on 2026-09-22 (the audit that produced this file)

| Intent | What had happened | Now |
|---|---|---|
| dart 1:1 through and through | 1,099 of 1,134 top-level definitions carried no anchor; L110 checked only an anchor's syntax | C2, `R32` |
| Targets reached, not settled | R3, R5, R14, R15, R17 relabeled "legitimate floors" in their own descriptions while the plan said 0 | rule 2, `L126` |
| Fails fast and loud | 116 of 247 lowering-registry entries exercised by no fast-lane case (all 35 bespoke invoke lowerings among them); a broken lowering passed smoke and probes | C5, `R33`, the coverage lane |
| Correct or loud | 52 catch clauses in `src` swallowed a failure into a default, unmeasured | C6, `R34` |
| Every failure located | marked done while IR from `get_typed_ir` (outside the closed-world cache) carried no DebugInfo — every NIR line 0 | C6, `L127` |
| Nothing dart doesn't do | a runtime type object for every numbered type, parked as "post-march" | rule 5, C2 |
| The goal decides | a task list judged by its own exit checks | rule 1, this file |
