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
  an index) `L150` (WT's imports are one list; a module's runtime is generated from its
  imports) `R20` `R21` `R29a` `R29b` `R37` `L152` (codegen reads a function's IR, its callees'
  return types and its joins from the plan and asks no inference) `L170` (an :invoke calls its
  MethodInstance's function) `L171` (one consult for which methods Julia selects, asked by collection, planning and the
  vtable pre-pass; a statement's codegen asks it nowhere) `L174` (one reader of an operand's
  Julia type, value_type, Julia's argextype) `L175` (a global's binding resolved once, at the
  boundary) `L176` (one class set, closed_world_classes, read by the enrollment, the no-method
  records, the ambiguity search and the numbering) `L177` (one rule for a match that is one
  signature) `L178` (a value meets a sink through one conversion, typed by its own type: one
  widening check, no ladder, one box producer) `L179` (one TypeError builder, one `Type{X}`
  element rule, the type-object test over the static type, one class test) `L180` (one operator
  table, one conversion table, one width rule, one operand table, one loop-bounds definition)
  `L181` (one CFG, Julia's own, nir_cfg; one dominator computation) `L182` (a constant callee's
  one representation, its object, resolved once at the boundary) `L183` (one as-checker per
  target and static type) `L184` (one export namer; a compiled function named by its Julia
  identity, never a counter) `L185` (one query for the import at a function index).
  Planned: dev/MARCH.md 13.4, 13.17 — one path for each fact the audits found computed twice,
  and codegen's remaining inference questions answered by the plan.
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
  without a Julia necessity.
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
  the SimpleDiffEq tolerance answered by a native reference that rounds each muladd once, the
  index test Julia makes, a tuple's `Type{X}` element typed as tuple_tfunc types it.
- **C4 · Strict in every regard.** Typed internal APIs: return types annotated, no `Any`
  outside named heterogeneous seams, every emitted value typed at its emission, and a
  constant's static type the type its emission pushes.
  Checks: `L9` `L35` `L49` `L74` `L136` `R17` `R30` `R31` (with Aqua and ExplicitImports in shard 0).
  Planned: dev/MARCH.md 13.20 — each stopgap (C0) made a construction: no emission without its
  expected type, no input through which a drop or an invoke's argument re-guesses, no field
  typed `Any`, and no definition without its result type when the package loads.
- **C5 · Wrong choices cannot land.** The Rust analogy: a wrong implementation is rejected at
  the edit site (load-time typing, the enforcing builder, a closed sum matched exhaustively when
  the package loads; a lock that scans is a stopgap, C0) or by the minute-scale
  lanes, never first by an hour-long run. Every lowering-registry entry is exercised by a lane
  case; a new entry without one fails; no known failure hides behind a skipped test or a
  missing wasm runtime. Checks: `L16` `L94` `L134` `L155` `R33` `R36` `L190` (every body a
  change's emission alters is entered by a passing differential case, at function entry, no
  finer: the emission-diff check, in the non-blocking matrix on every landed head, gate.yml)
  `L191` (the numeric lowering
  tables generate their cases, one per type each key serves, dirty narrow operands among the
  inputs) `L192` (a scan of six forms, a parameter's default, a something/coalesce/get/get!
  fallback, a function's answers (its early returns, its fall-through value and its tail branch's
  arms), a value-position branch's arms (ternary or if/elseif/else), a branch and a short-circuit
  under a nothing test: each site that chooses a type, a register, a width, an index or a sentinel is on
  its exact allowlist or counted by R43; the guarantee against a wrong default is L190 and L191)
  `R42` (the numeric types the generated cases hold out) `R43` (the wrong defaults L192's scan
  finds) `R44` (the sites of WT's own Symbol classifications: a stopgap, retired at 0 when L199
  covers every classification).
  Planned: dev/MARCH.md 13.1, 13.3, 13.4, 13.14, 13.17, 13.20 — the checks the audits found
  pinning text, the numeric types the generated cases hold out, the wrong defaults, and each
  stopgap (C0) made a construction: WT's own classifications closed sums, a match over one
  refusing a missing arm or a catch-all when it expands (L199) and each NIR node type answering
  each member function itself, checked when the package loads (L200), each conversion deleting
  the Symbol path and every catch-all arm in its own commit; every lowering a rule that cannot
  exist without its witness; every translation one table.
- **C6 · Correct or loud, and located.** No silent value, default, substitution or fabricated
  result; every rejection is attributed to its statement with the inline chain
  innermost-first. Checks: `L8` `L15` `L18` `L19` `L37` `L38` `L39` `L48` `L51` `L58` `L60`
  `L63` `L64` `L66` `L71` `L72` `L73` `L75` `L76` `L78` `L79` `L85` `L89` `L90` `L93` `L96`
  `L101` `L118` `L119` `L127` `L135` `L139` `L146` `L147` `L156` (every call of a host-declared
  import is counted) `R34` `R39` (no smoke xfail compiles and then answers wrong, traps, or
  returns what the harness cannot read).
  Planned: dev/MARCH.md 13.1, 13.10, 13.14, 13.17, 13.20 — the exception stack across calls,
  the traps where Julia answers, the audits' unlocated and lossy paths, and each stopgap (C0)
  made a construction where Julia has one, first the eleven catch-alls that answer only by
  convention, each a located rejection.
- **C7 · Valid by construction.** The builder models everything wasm validates and throws at
  the emitting line; nothing repairs, truncates or bypasses emitted bytes; wasm-tools is only
  the disagreement alarm. Checks: `L6` `L7` `L13` `L14` `L22` `L27` `L29` `L65` `L87` `L99` `L151` (every builder has its module)
  `L164` (one subtype relation, in the builder) `L165` (dart's storage types: no raw byte or
  packed type as a value type) `L166` (every operand typed by the module's own types) `L167`
  (every body is a builder the module made) `L168` (locals initialized before use) `L169`
  (module objects held by handle) `L172` (no instruction recorded in dead code)
  `L173` (one declaration path for a local, its type checked) `R41` (no local declared beside it).
  Planned: dev/MARCH.md 13.20 — each stopgap (C0) made a construction, and no operand a type
  can hold wrong: one type per opcode, each immediate a handle its declaration made, the locals
  list and the module's bytes out of codegen's reach, the heap and label kinds closed sums.
- **C8 · Formal methods through and through.** Every algorithmic component carries a TLA+
  model with a Broken variant TLC must reject; a change to a modeled algorithm changes the
  model first; a counterexample is a finding, never a reason to weaken an invariant. Checks:
  `L111` `L131` (dev/formal/README.md's Components table maps every algorithmic component to
  its model or states why it has none).
  Planned: dev/MARCH.md 13.20 — each stopgap (C0) made a construction: both checks read files
  today (the models' pairing, the components' table); a model's TLC run is behavior.
- **C9 · Nothing stale, nothing bloated, nothing re-derived — anywhere in the repository.** No
  dead definition, fossil comment, retired name, campaign narration, or second computation of
  a fact the first already produced; the plan holds only open work and the history only short
  entries; every tracked file outside `src/` is consumed — by the build, a test, a lane, CI or
  the docs site, by path or by the loader that walks its directory — and none records finished
  work. Checks: `L4` `L106` `L107` `L108` `L109` `L121` `L129` `L130` `R35` `R3` `R5` `R7`
  `R14` `R15` `R27`. Planned: dev/MARCH.md 13.4, 13.5, 13.17 — the stale code and prose the
  audits found.
- **C10 · Fast, precise feedback.** Fast is first, strict is final (Dale, 2026-10-20): a
  landing's gate is `bash dev/gate.sh --block` on this machine, at most 60 s of wall, measured
  by the gate itself, which `dev/land.sh merge` lands on (its green record of the exact commit,
  made on a clean tree); the full CI matrix runs on every landed head and never holds a landing
  (its red is the next batch's first item: `dev/land.sh merge` refuses while the last landed
  head's matrix is red), and once, blocking, on PR #122's merge head; a
  failure names its site. Checks: `L144` (every instruction a statement emits maps to its
  source, so a trap at run time names its statement as a rejection at compile time does)
  `L145` (every throw carries the stack it was raised on, so an escaped exception names its
  throw site) `L153` (the full matrix runs every test family CI runs, on every landed head,
  non-blocking) `L157` (every
  function is named where it is defined, so a trap in code the compiler generated names its
  function and construct) `L158` (one compile entry: every exported compile entry is one call
  of it, which alone reads the options and routes the caller's diagnostics ledger; compile_module
  below it is internal) `L159` (every byte
  of a function compiled from Julia IR maps to its statement or its definition, except a
  statement Julia gives no location of its own, which is unmapped, so a trap outside a statement
  names its function's definition) `L160` (an escaped exception names its type, through the
  source map's class names) `L161` (the statement lane counts a throw as matched only by a
  Julia exception of native's type) `L162` (the full matrix, every lane of `dev/lanes.sh` on CI's
  runners, gives its verdict within its 20-minute budget per lane job) `L163` (the CI inner loop,
  `bash dev/gate.sh --fast`, is never a landing's gate) `L194` (the blocking gate: the ratchet, a
  fixed smoke core with the groups the change maps to and its own cases on 1.12 and 1.13, the
  probe core with the change's probes, the QA families its change selects (every changed one and
  those the locks cite as behavior for what it changes), TLC for the models it touches, side by
  side, each stage and the whole run on a budget, an evidence record per tree, the landing on
  that record alone, never while the last landed head's matrix is red)
  `L195` (its timing ratchet: a stage more than 15% and 0.3 s slower than its best fails, unless
  the commit declares a correctness fix in its own `Timing:` line, naming the stage and its
  record; the budgets are literal walls, and a machine more than 1.5 times slower than its best
  leaves the timing unjudged, never a scaled pass, its checks and budgets still judged)
  `L197` (the full loop: `dev/land.sh land` rebases, holds the machine, gates and lands a change
  in one command, logging each landing's seconds from edit to landed; the median of the last five
  at most its target, 180 s when it changes src, 90 s otherwise) `L198` (each landing records
  whether its timing was judged; `land` prints the unjudged streak, which a judged run resets).
  Planned: dev/MARCH.md 13.18 and 13.24 and 13.25 and 13.26 and 13.27 — the ratchet stage's time to win back (L195).
- **C0 · The charter holds.** Strict means by construction (Dale, 2026-10-21): a clause of C1
  to C8 is CLOSED only when its guarantees hold by construction, WT's own interfaces unable to
  express the wrong choice (a type that cannot hold the wrong value; an interface with no
  method, field or switch for it; a closed sum matched exhaustively when the package loads; the
  builder refusing at the emitting line), each check naming the definition that is its
  construction. A check that finds the wrong choice at gate time (a
  scan of WT's source, an allowlist of exceptions, a ratchet at 0 or not, or a test that must
  reach it) is a stopgap, which keeps its clause OPEN with the Planned construction that
  retires it; the differential lanes stay the soundness gate and close no clause. Calling a check, a clause or a
  batch strict or CLOSED on a stopgap is a red flag. Checks: `L125` (this file and the enforcement stack cite each
  other completely) `L126` (no ratchet declares a floor) `L128` (AGENTS.md, the one
  instructions file, stays current and lean) `L148` (every change is audited against this
  charter within 5 commits, `dev/AUDIT.md`, its entries chained) `L154` (Planned text cites MARCH
  rows, and every finding sits on a row) `L201` (no clause of C1 to C8 without Planned text cites
  a check test/parity_ratchet.jl's STRICT_KINDS does not classify as a construction naming a
  definition src holds; every lock C4 to C8 cite is classified).

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
