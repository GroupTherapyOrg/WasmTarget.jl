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
  `L112` `L113` `L114` `L115` `L117` `L120` `L122` `L124` `L137` `L142` (a struct's layout is
  decided by its structure, one route per Array) `L143` (one rule turns a storage pointer into
  an index) `L150` (a module's host imports and its runtime are one list) `R20` `R21` `R29a`
  `R29b` `R37` `L152` (codegen reads a function's IR from the plan, not from `get_typed_ir`). Planned:
  dev/MARCH.md 13.0, 13.4, 13.17 — one path for each fact the audits found computed twice,
  and codegen's six remaining inference questions answered by the plan (dev/AUDIT.md P3, E3,
  E4, E5, A2C3, A2C4, A2E4, A3C1, A3C3, A3C4, A3C6, A3C8, A4C4, A4C5, A4C6, A4E5, A5E5,
  A5E8).
- **C2 · dart2wasm 1:1, through and through.** Every definition in `src/` carries a
  `parity(<file>.dart:<line> <Symbol>)` anchor to dart-lang/sdk `898a1e4b` that names the
  structure it copies, or a `parity(quarantine: <reason>)` naming the Julia-only necessity
  that forces it. Nothing else may exist: a mechanism dart does not have and Julia does not
  force is a defect even when every test passes. Checks: `L2` `L20` `L21` `L23` `L28` `L30`
  `L31` `L32` `L43` `L44` `L46` `L50` `L55` `L77` `L83` `L84` `L86` `L88` `L95` `L110` `L132`
  (anchors resolve: each cited line exists at the pinned commit and names the cited symbol; CI
  fetches the pinned sources and a missing checkout fails, never skips) `L149` (the builder
  holds no Julia compiler object) `R32` `R40` (no process-global compile state: one
  compilation's state lives on its Translator). Planned: dev/MARCH.md 13.7, 13.17 — inventions
  without a Julia necessity (dev/AUDIT.md A2B6, A2B8, A2C3).
- **C3 · Julia is the ground truth.** When Julia's compiler answers a question (a hash, a
  predicate, a layout, a dispatch result, an exception payload), the answer is ported, never
  approximated; Julia's own bodies compile instead of bespoke re-implementations. Checks:
  `L42` `L52` `L53` `L54` `L56` `L57` `L59` `L62` `L70` `L81` `L82` `L92` `L123` `L133` (each
  bespoke body in `STANDALONE_INTRINSIC_BODIES` is on an exact allowlist with the reason
  Julia's body cannot compile; `INVOKE_INTRINSICS` is deleted) `L138` (the differential oracle
  is bit-exact; a tolerance only where the native value comes from a named BLAS or LAPACK
  routine) `L140` (an overlay's BLAS/LAPACK reason is verified against Julia's own method)
  `L141` (a constant is interned by `===`, never by `isequal`) `R38` (each `@overlay` states
  why Julia's body cannot compile, or goes). Planned: dev/MARCH.md 13.3, 13.7, 13.14, 13.17 —
  the SimpleDiffEq tolerance answered by a native reference that rounds each muladd once
  (dev/AUDIT.md H3), the index test Julia makes (A2E6), a tuple's `Type{X}` element typed as
  tuple_tfunc types it (A5P1).
- **C4 · Strict in every regard.** Typed internal APIs: return types annotated, no `Any`
  outside named heterogeneous seams, every emitted value typed at its emission, and a
  constant's static type the type its emission pushes.
  Checks: `L9` `L35` `L49` `L74` `L136` `R17` `R30` `R31` (with Aqua and ExplicitImports in shard 0).
- **C5 · Wrong choices cannot land.** The Rust analogy: a wrong implementation is rejected at
  the edit site (load-time typing, the enforcing builder, the locks) or by the minute-scale
  lanes, never first by an hour-long run. Every lowering-registry entry is exercised by a lane
  case; a new entry without one fails; no known failure hides behind a skipped test or a
  missing wasm runtime. Checks: `L16` `L94` `L134` `R33` `R36`. Planned: dev/MARCH.md 13.3,
  13.16, 13.17 — a paused downstream job and the checks the audits found pinning text
  (dev/AUDIT.md M6, A2P9, A4B6, A4C7, A4P4, A4P6, A4P9, A5B6).
- **C6 · Correct or loud, and located.** No silent value, default, substitution or fabricated
  result; every rejection is attributed to its statement with the inline chain
  innermost-first. Checks: `L8` `L15` `L18` `L19` `L37` `L38` `L39` `L48` `L51` `L58` `L60`
  `L63` `L64` `L66` `L71` `L72` `L73` `L75` `L76` `L78` `L79` `L85` `L89` `L90` `L93` `L96`
  `L101` `L118` `L119` `L127` `L135` `L139` `L146` `L147` `R34` `R39` (no smoke xfail compiles
  and then answers wrong, traps, or returns what the harness cannot read). Planned:
  dev/MARCH.md 13.0, 13.1, 13.10, 13.14, 13.15, 13.17 — the exception stack across calls,
  the traps where Julia answers, and the audits' unlocated and lossy paths (dev/AUDIT.md A4E6, A3S1, A3S2, A3S3, A3P3, A3C7, M7, E9, A2C1,
  A2C2, A2E5, A3E6, A4P2, A5E3, A5E4, A5B1, A5B2, A5C4).
- **C7 · Valid by construction.** The builder models everything wasm validates and throws at
  the emitting line; nothing repairs, truncates or bypasses emitted bytes; wasm-tools is only
  the disagreement alarm. Checks: `L6` `L7` `L13` `L14` `L22` `L27` `L29` `L65` `L87` `L99` `L151` (every codegen builder has its module).
  Planned: dev/MARCH.md 13.17 — a function's results checked at every return, casts, nulls,
  struct.new and conversions typed by the module, no raw byte as a value type, one subtype
  relation in the builder, a validating initializer (dev/AUDIT.md A3B1–A3B11, A3B14, B5, A4B1–A4B5, A5B3, A5B9).
- **C8 · Formal methods through and through.** Every algorithmic component carries a TLA+
  model with a Broken variant TLC must reject; a change to a modeled algorithm changes the
  model first; a counterexample is a finding, never a reason to weaken an invariant. Checks:
  `L111` `L131` (dev/formal/README.md's Components table maps every algorithmic component to
  its model or states why it has none). Planned: dev/MARCH.md 13.17 — the exception stack's
  model across calls, the operand stack's if/else, and the closed-world model's pruning and
  hidden edges (dev/AUDIT.md A3B11, P4, A2C1).
- **C9 · Nothing stale, nothing bloated, nothing re-derived — anywhere in the repository.** No
  dead definition, fossil comment, retired name, campaign narration, or second computation of
  a fact the first already produced; the plan holds only open work and the history only short
  entries; every tracked file outside `src/` is consumed — by the build, a test, a lane, CI or
  the docs site, by path or by the loader that walks its directory — and none records finished
  work. Checks: `L4` `L106` `L107` `L108` `L109` `L121` `L129` `L130` `R35` `R3` `R5` `R7`
  `R14` `R15` `R27`. Planned: dev/MARCH.md 13.4, 13.5, 13.17 — the stale code and prose the
  audits found (dev/AUDIT.md B6, S6, L8, A2P10, A4B7, A4B8, A4C8, A4E7, A4P7).
- **C10 · Fast, precise feedback.** `bash dev/lanes.sh` gives one verdict in minutes; the full
  CI matrix runs on every march branch and is the landing gate (`dev/land.sh merge`); a
  failure names its site. Checks: `L144` (every instruction a statement emits maps to its
  source, so a trap at run time names its statement as a rejection at compile time does)
  `L145` (every throw carries the stack it was raised on, so an escaped exception names its
  throw site). Planned: dev/MARCH.md 13.15, 13.17 — an exception's type, every function named;
  one compile entry (dev/AUDIT.md A2C6); every throw's stack checked by its callers (A4B9 = A4P5); a check that `bash dev/lanes.sh` gives its verdict in
  minutes.
- **C0 · The charter holds.** Checks: `L125` (this file and the enforcement stack cite each
  other completely) `L126` (no ratchet declares a floor) `L128` (AGENTS.md, the one
  instructions file, stays current and lean) `L148` (every change is audited against this
  charter within 5 commits, `dev/AUDIT.md`). Planned: dev/MARCH.md 13.17 — L148 chains its
  entries and counts over the head that lands, and a check that every open finding is on the
  row its clause names (dev/AUDIT.md A2P5, A3P4).

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
