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
  Legacy (WT1's checks, retired with the rebuild's switch: they measured WT1's source, which
  `legacy/` keeps only as the agreement oracle): L1 L3 L5 L10 L11 L12 L17 L24 L25 L26 L34 L36
  L40 L41 L45 L47 L61 L67 L68 L69 L80 L91 L97 L98 L100 L102 L103 L104 L112 L113 L114 L115 L117
  L120 L122 L124 L137 L142 L143 L150 R20 R21 R29a R29b R37 L152 L170 L171 L174 L175 L176 L177
  L178 L179 L180 L181 L182 L183 L184 L185.
  Planned: dev/MARCH.md 1.A9, 1.A10, 1.C — two translators the only Type-to-wasm methods, NIR
  Julia's one inference, the type chain computed once on the translator.
- **C2 · dart2wasm 1:1, through and through.** Every definition in `src/` carries a
  `parity(<file>.dart:<line> <Symbol>)` anchor to dart-lang/sdk `898a1e4b` that names the
  structure it copies, or a `parity(quarantine: <reason>)` naming the Julia-only necessity
  that forces it. Nothing else may exist: a mechanism dart does not have and Julia does not
  force is a defect even when every test passes.
  Legacy (retired with the switch): L2 L20 L21 L23 L28 L30 L31 L32 L43 L44 L46 L50 L55 L77 L83
  L84 L86 L88 L95 L110 L132 L149 R32 R40.
  Planned: dev/MARCH.md 1.A3, 1.A4, 1.A5, 1.A6, 1.A7, 1.E — `src/` generated file for file from
  the pinned SDK, every definition anchored at load, the anchors resolved at the pin, the
  subset Julia's verifier's, dispatch by signature in the quarantine.
- **C3 · Julia is the ground truth.** When Julia's compiler answers a question (a hash, a
  predicate, a layout, a dispatch result, an exception payload), the answer is ported, never
  approximated; Julia's own bodies compile instead of bespoke re-implementations.
  Legacy (retired with the switch): L42 L52 L53 L54 L56 L57 L59 L62 L70 L81 L82 L92 L123 L133
  L138 L140 L141 R38.
  Planned: dev/MARCH.md 1.A7, 1.A10, 1.C, 1.E — Julia's trim verifier, Julia's typed IR, Julia's
  answers for layouts and dispatch, each quarantined definition naming its Julia API.
- **C4 · Strict in every regard.** Typed internal APIs: return types annotated, no `Any`
  outside named heterogeneous seams, every emitted value typed at its emission, and a
  constant's static type the type its emission pushes.
  Legacy (retired with the switch): L9 L35 L49 L74 L136 R17 R30 R31.
  Planned: dev/MARCH.md 1.A8 — typed signatures and no `Any` field, checked when the package loads.
- **C5 · Wrong choices cannot land.** The Rust analogy: a wrong implementation is rejected at
  the edit site (load-time typing, the enforcing builder, a closed sum matched exhaustively when
  the package loads; a lock that scans is a stopgap, C0) or by the minute-scale
  lanes, never first by an hour-long run. Every lowering-registry entry is exercised by a lane
  case; a new entry without one fails; no known failure hides behind a skipped test or a
  missing wasm runtime.
  `L219` (no open hierarchy passes for a closed one: every abstract type in src a registered
  construction or a dart abstract class's mirror, refused at load otherwise).
  Legacy (retired with the switch): L16 L94 L134 L155 R33 R36 L190 L191 L192 R42 R43 R44.
  Planned: dev/MARCH.md 1.A8, 1.D — closed sums matched exhaustively at load, the lowering on
  the typed stack.
- **C6 · Correct or loud, and located.** No silent value, default, substitution or fabricated
  result; every rejection is attributed to its statement with the inline chain innermost-first.
  `L218` (the rejections a closed sum: a `Union` of concrete kinds, each handled, checked at load).
  Legacy (retired with the switch): L8 L15 L18 L19 L37 L38 L39 L48 L51 L58 L60 L63 L64 L66 L71
  L72 L73 L75 L76 L78 L79 L85 L89 L90 L93 L96 L101 L118 L119 L127 L135 L139 L146 L147 L156 R34
  R39.
  Planned: dev/MARCH.md 1.A7, 1.D, 1.Q — every unported path a located rejection, the smoke
  ladder derived from them, and no case going from passing back to loud.
- **C7 · Valid by construction.** The builder models everything wasm validates and throws at
  the emitting line; nothing repairs, truncates or bypasses emitted bytes; wasm-tools is only
  the disagreement alarm.
  Legacy (retired with the switch): L6 L7 L13 L14 L22 L27 L29 L65 L87 L99 L151 L164 L165 L166
  L167 L168 L169 L172 L173 R41.
  Planned: dev/MARCH.md 1.A4, 1.B — wasm_builder's ir, typestate builders and serializer, 1:1.
- **C8 · Formal methods through and through.** Every algorithmic component carries a TLA+
  model with a Broken variant TLC must reject; a change to a modeled algorithm changes the
  model first; a counterexample is a finding, never a reason to weaken an invariant.
  Legacy (retired with the switch): L111 L131.
  Planned: dev/MARCH.md 1.C, 1.D, 1.E — each phase's models re-pointed at the definitions it fills.
- **C9 · Nothing stale, nothing bloated, nothing re-derived — anywhere in the repository.** No
  dead definition, fossil comment, retired name, campaign narration, or second computation of
  a fact the first already produced; the plan holds only open work and the history only short
  entries; every tracked file outside `src/` is consumed — by the build, a test, a lane, CI or
  the docs site, by path or by the loader that walks its directory — and none records finished
  work. Checks: `L129` `L130`.
  Legacy (retired with the switch): L4 L106 L107 L108 L109 L121 R35 R3 R5 R7 R14 R15 R27.
  Planned: dev/MARCH.md 1.A6, 1.F — the skeleton derived and never drifting, `legacy/` deleted
  by its rule.
- **C10 · Fast, precise feedback.** Fast is first, strict is final (Dale, 2026-10-20): a
  landing's gate is `bash dev/gate.sh --block` on this machine, about a minute of wall (a 60-s
  target, red only past twice it: Dale 2026-10-21, a 61-s run is no failure of an under-a-minute
  goal), measured by the gate itself, which `dev/land.sh merge` lands on (its green record of the exact commit,
  made on a clean tree); the full CI matrix runs on every landed head and never holds a landing
  (its red is the next batch's first item: `dev/land.sh merge` refuses while the last landed
  head's matrix is red), and once, blocking, on PR #128's merge head; a
  failure names its site. Checks: `L153` (the full matrix runs every test family CI runs, on
  every landed head, non-blocking) `L162` (the full matrix, every lane of `dev/lanes.sh` on CI's
  runners, gives its verdict within its 20-minute budget per lane job) `L163` (the CI inner loop,
  `bash dev/gate.sh --fast`, is never a landing's gate) `L194` (the blocking gate: the ratchet, a
  fixed smoke core with the groups the change maps to and its own cases on 1.12 and 1.13, the
  probe core with the change's probes, the QA families its change selects (every changed one and
  those the locks cite as behavior for what it changes), TLC for the models it touches, side by
  side, each stage and the whole run on a budget, an evidence record per tree, the landing on
  that record alone, never while the last landed head's matrix is red)
  `L195` (its timing ratchet: a stage more than 1.5 times and 0.3 s slower than its best fails, one
  past 15% inside that band a note, unless
  the commit declares a correctness fix with its MARCH row; the budgets are targets red only past
  twice them, and a
  machine more than 1.5 times slower than its best leaves the timing unjudged, never a scaled
  pass, its checks and budgets still judged)
  `L197` (the full loop: `dev/land.sh land` rebases, holds the machine, gates and lands a change
  in one command, logging each landing's seconds from edit to landed; the median of the last five
  inside its band, a 300-s target for every change red only past 600 s: Dale 2026-10-21, minutes,
  never tens of minutes) `L198` (each landing records
  whether its timing was judged; `land` prints the unjudged streak, which a judged run resets).
  Legacy (retired with the switch): L144 L145 L157 L158 L159 L160 L161 L196.
  Planned: dev/MARCH.md 1.Q — the gate records each case's derived outcome, and a landing never
  turns a passing case loud.
- **C0 · The charter holds.** Strict means by construction (Dale, 2026-10-21): a clause of C0
  to C8 is CLOSED only when its guarantees hold by construction, WT's own interfaces unable to
  express the wrong choice (a type that cannot hold the wrong value; an interface with no
  method, field or switch for it; a closed sum matched exhaustively when the package loads; the
  builder refusing at the emitting line), each check naming the definition that is its
  construction, its assertion the check src registers beside that definition, the precedent it
  follows (another language's mechanism: Rust, dart, wasm, …) and how Julia's differs; a
  construction with no precedent anywhere is an invention, which waits for Dale. A check that finds the wrong choice at gate time (a
  scan of WT's source, an allowlist of exceptions, a ratchet at 0 or not, or a test that must
  reach it) is a stopgap, which keeps its clause OPEN with the Planned construction that
  retires it; the differential lanes stay the soundness gate and close no clause. Calling a check, a clause or a
  batch strict or CLOSED on a stopgap is a red flag. Dale's requirements are the rows of
  `dev/LEDGER.md`, each in his words with its why and the checks that enforce it; a requirement no
  check enforces yet names the MARCH row of its planned check. Checks: `L125` (this file and the enforcement stack cite each
  other completely) `L126` (no ratchet declares a floor) `L128` (AGENTS.md, the one
  instructions file, stays current and lean) `L148` (every change is audited against this
  charter within 5 commits, `dev/AUDIT.md`, its entries chained) `L154` (Planned text cites MARCH
  rows, never findings, every row naming its clauses; every finding the latest audit entry
  leaves open sits on the row it names until a commit's `Fixes:` line names it) `L201` (no clause reads CLOSED citing no check; no clause of
  C0 to C8 without Planned text cites a check test/parity_ratchet.jl's STRICT_KINDS does not
  classify as a construction, with its
  precedent, whose lock only calls the check src registers beside its definition; every lock C0 and
  C4 to C8 cite is classified) `L202` (every closed sum or construction in src, an @enum, a `@closed` sum or a
  definition a construction names, carries its `precedent(<ecosystem>: <mechanism>)`) `L203`
  (each audit entry over src carries its `stopgap in disguise:` and `precedent:` lines) `L204`
  (every ledger row cites a check, a clause, a test or its planned MARCH row, and every check serves
  a row) `L205` (a number in a check states its intent and band, and the check fails only outside
  the band) `L206` (AGENTS.md carries every live requirement, generated from the ledger) `L207`
  (every lock's negative runs in every gate, inside the ratchet stage) `R45` (the locks that owe
  theirs) `L208` (after every landing `land` prints the rebuild's src progress; landings that change
  nothing under src/ draw a note from the fifth in a row, never a failure).
  Planned: dev/MARCH.md 1.R, 1.S — the ledger's planned checks; each of these checks a
  construction, or Dale's ruling that a prose clause is checked by behavior.

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
   the orchestrator re-measures, and the blocking gate's record of the exact head that lands is
   the gate (C10).
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
