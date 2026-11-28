# The WasmTarget.jl charter

This is the definition of done for the rebuild (PR #128) and the standard for every change
after it. It outranks every task list, phase plan, agent brief and commit message. A task
is worth doing only to the extent that it closes a clause below; an exit check that
does not close a clause is not an exit. The ratchet reads this file (L125): every check in the
enforcement stack must be cited by a clause, and every check a clause cites must exist.

Changes to this file are made at Dale's direction only. Agents may propose a change in a
report; they never make one to fit where their work stopped.

## Intent (Dale's words)

> A CLEAN and PERFECT foundation for all future agent-driven development … dart2wasm's
> battle-tested structure followed VERBATIM; the Julia compiler is the ground truth;
> NOTHING ever reinvents the wheel … as STRICT as possible in EVERY regard … NO stale code,
> NO bloat, NO parallel/confusing pathways, NOTHING dart2wasm doesn't do … the Rust
> analogy: the structure itself makes whole classes of mistakes impossible. (2026-09-01)

> Correct ≠ parity. A passing differential test means SOUND, not DART-FAITHFUL. Don't be OK
> settling. (2026-06-29)

> If dart doesn't provide a 1-1 port, then the Julia compiler ITSELF, along with another
> language like Rust or C#, should be enough for us to port from. (2026-10-28) · NEVER ever
> build a piece bespoke, but rather find a near 1-1 match and then port it, like we did for
> dart and the LLVM stackifier. (2026-10-29)

> We should ALSO port dart's TEST set, with Julia as the ground truth. (2026-10-22) · Do NOT
> allow stubs to be called complete. (2026-10-29)

> WT must be FULLY valid by construction. (2026-07-07) · Formal methods through and
> through. (2026-09-02) · ALWAYS fix the root issue. (2026-06-28)

## Where every definition comes from: port, never invent

A definition in `src/` is a port. Its source is the first of these that answers the question,
each read at its pinned commit (dev/PARITY_MASTER.md), each pin cited where the definition is
written and resolved when the package loads:

1. **dart2wasm and wasm_builder** (dart-lang/sdk `898a1e4b`): the structure, file for file.
   `src/` mirrors `lib/` and `lib/src/`; every definition there carries `@parity`.
2. **Julia itself** (julia at the pinned 1.12 commit, with its pinned dependencies such as
   utf8proc): every behavior, and everything Julia forces that dart has no counterpart for.
   This covers Julia's compiler (inference, the trim verifier, the optimized IR WasmTarget
   reads), Base, and Julia's own C runtime: a foreign call or builtin a program reaches lowers
   to the port of the C function Julia's codegen calls for it, in the one table of them, held in
   a closed world only where a statement reaches it. dart's `@patch` files correspond to Julia's
   overlay method tables, kept in one findable place. Every definition here carries
   `@quarantine pin"<citation>"`.
3. **LLVM** (llvm/llvm-project `7a941dfb`), where Julia delegates the answer to LLVM and dart
   has none: the stackifier, soft-promoted half precision, the atomics a single-threaded wasm
   target strips, the folds that delete a raise.
4. **A named production precedent** in another ecosystem, for a construction none of the
   above has: Rust, C#, GraalVM or another, each pinned before it is cited. A construction with no
   precedent anywhere is an invention, and an invention waits for Dale.

Two exact, reviewable lists hold the rest, and each only shrinks: `dev/quarantine_unpinned.txt`,
definitions still owing their pin (`@quarantine unpinned`), and
`dev/quarantine_no_counterpart.txt`, readers of WasmTarget's own formats, which no ecosystem
has, each admitted by the lead with its reason.

The three oracles never stand in for one another: dart2wasm for structure, native Julia for
behavior, and native-versus-wasm differential execution for soundness. Where Julia leaves an
answer to the host (a NaN's payload, an address), the oracle compares only what Julia's source
defines.

## The clauses

Each clause is closed when every check it cites is a lock at 0 and every ratchet it cites
has reached 0 and been converted to a lock. `julia --project=. test/parity_ratchet.jl` ends
with the per-clause status. A clause is never closed by argument.

- **C1 · One path.** Every construct has exactly one lowering; every fact has exactly one
  source (one inference path, one numbering, one table of runtime ports, one reader of a
  binding, one reader of where a statement was written, one type chain). The commit adding a
  source deletes every other path to the fact.
  Planned: dev/MARCH.md 1.A9, 1.C — two translators the only Type-to-wasm methods, Julia's one
  inference, the type chain computed once on the translator.
- **C2 · Ported, never invented.** Every definition in `src/` comes from the sources above, in
  their order, and says so where it is written: `@parity "<file>.dart:<line> <Symbol>"` or an
  LLVM anchor outside `src/julia/`; `@quarantine pin"<citation>" "<necessity>" <Julia API>` in
  `src/julia/`, or `unpinned` while the debt list names it. Nothing else may exist: a mechanism
  dart does not have and Julia does not force is a defect even when every test passes.
  `L210` (a file of `src/` outside `src/julia/` loads only through `include_dart` from the pin
  table, and the files it loaded are the directory's, checked at load) `L211` (every definition
  outside `src/julia/` carries `@parity`, its anchor, file and Julia name checked where it is
  written, every method and binding covered at load) `L212` (every `src/julia/` definition
  carries `@quarantine`, its Julia API resolved where it is written, every method and binding
  covered at load) `L213` (every anchor's line declares its symbol at the pin, read from the
  pinned checkout where the anchor is written and at load, the gate requiring the checkout)
  `L226` (every dart2wasm test file at the pin has one entry of test/dart_tests.toml: ported to
  named smoke cases, structural with its property, not portable with its reason, or a helper; a
  check over a map).
  Planned: dev/MARCH.md 1.A4, 1.A5, 1.A6, 1.E, 1.T — `src/` generated file for file from
  the pinned SDK and never drifting from it, dispatch by signature in the quarantine, dart's tests
  ported with Julia's answers.
- **C3 · Julia is the ground truth.** When Julia answers a question (a hash, a predicate, a
  layout, a dispatch result, an exception and its payload, a runtime function's effect), the
  answer is ported from Julia's own source, never approximated; Julia's own bodies compile
  instead of bespoke re-implementations, and an expected value in a test is native Julia's.
  `L225` (each mirror of a Julia form names the form it mirrors, checked at load by converting a
  sample built by Julia's own constructors).
  Planned: dev/MARCH.md 1.C, 1.E, 1.T — Julia's answers for layouts and dispatch, each
  quarantined definition naming its Julia API, and the expected value of every ported dart test
  native Julia's.
- **C4 · Strict in every regard.** Typed internal APIs: return types annotated, no `Any`
  outside named heterogeneous seams, every emitted value typed at its emission, and a
  constant's static type the type its emission pushes.
  `L214` (every parameter of a ported definition's methods declared, checked at load) `L215` (no
  field of a ported struct holds `Any`, and one holds `nothing` only where dart declares it `T?`,
  checked at load).
  Planned: dev/MARCH.md 1.B, 1.D — every emitted value typed at its emission and a constant's
  static type the type its emission pushes, on the typed builder and the typed stack.
- **C5 · Wrong choices cannot land.** The Rust analogy: a wrong implementation is rejected at
  the edit site (load-time typing, the enforcing builder, a closed sum matched exhaustively when
  the package loads; a lock that scans is a stopgap, C0) or by the minute-scale landing check,
  never first by an hour-long run. Every lowering-registry entry is exercised by a case; no known
  failure hides behind a skipped test or a missing wasm runtime.
  `L219` (no open hierarchy passes for a closed one: every abstract type in src a registered
  construction or a dart abstract class's mirror, refused at load otherwise) `L217` (every Union
  a `@closed` sum, every match over one `@exhaustive`, its arms checked where it is written and
  again at load) `L221` `L222` (NIR's statements and operands closed sums of Julia's optimized IR
  forms, each kind handled, checked at load).
  Planned: dev/MARCH.md 1.D — the lowering on the typed stack.
- **C6 · Correct or loud, and located.** WasmTarget compiles the strict subset Julia's own trim
  verifier defines. Inside it, every program's answer is native Julia's; outside it, a rejection
  located at its statement with the inline chain innermost-first. No silent value, default,
  substitution or fabricated result; a path the program cannot take at compile time ends at a
  located run-time fatal, never a plausible value.
  `L218` (the rejections a closed sum: a `Union` of concrete kinds, each handled, checked at load)
  `L220` (the strict subset's typestate: every stage after Julia's trim verifier takes the
  ClosedWorld only a holder of its token makes, its sole constructor checked at load) `L224` (no
  method of WasmTarget but check_subset makes one, a stopgap read of lowered code, Julia having no
  module privacy).
  Planned: dev/MARCH.md 1.D, 1.Q — every unported path a located rejection, the smoke
  ladder derived from them, and no case going from passing back to loud.
- **C7 · Valid by construction.** The builder models everything wasm validates and throws at
  the emitting line; nothing repairs, truncates or bypasses emitted bytes; wasm-tools is only
  the disagreement alarm.
  Planned: dev/MARCH.md 1.A4, 1.B — wasm_builder's ir, typestate builders and serializer, 1:1.
- **C8 · Formal methods through and through.** Every algorithmic component carries a TLA+
  model with a Broken variant TLC must reject, and the definition that implements it names its
  model; a change to a modeled algorithm changes the model first; a counterexample is a finding,
  never a reason to weaken an invariant.
  Planned: dev/MARCH.md 1.C, 1.D, 1.E — each phase's models re-pointed at the definitions it fills.
- **C9 · Nothing stale, nothing bloated, nothing re-derived — anywhere in the repository.** No
  dead definition, fossil comment, retired name, campaign narration, or second computation of
  a fact the first already produced; the plan holds only open work and the history only short
  entries; every tracked file outside `src/` is consumed — by the build, a test, a lane, CI or
  the docs site, by path or by the loader that walks its directory — and none records finished
  work. Checks: `L129` `L130`.
  Planned: dev/MARCH.md 1.A6, 1.F — the skeleton derived and never drifting, `legacy/` deleted
  by its rule.
- **C10 · Fast, precise feedback.** Fast is first, strict is final (Dale, 2026-10-20). A
  landing is a commit the climb's lander lands after its blocking check on this machine passes
  on the exact head that lands: WasmTarget loads, so every construction checks itself; the
  ratchet passes; the test files the lander chose before the check pass; TLC checks every model
  the change touches. The check targets about a minute of wall, its band set by the lead from
  measured checks (its band in dev/check.sh, the lander's rules in dev/climb/HILL.md), and a known red
  is located to its landing and fixed first. The full CI matrix runs at clause closure and never
  holds a landing, and once, blocking, on PR #128's merge head; a failure names its site.
  Checks: `L153` (the full matrix runs every test family CI runs, at clause closure,
  non-blocking; a landing pushes the march branch alone) `L162` (the full matrix, every lane of
  `dev/lanes.sh` on CI's runners, gives its verdict within its 20-minute budget per lane job)
  `L227` (a change that deletes a test file or drops a smoke or probe case names each in its
  message, `Removes-test: <what> — <reason>`) `L228` (a landing's check runs the test set the
  climb's lander chose before it, from origin's code and state, and nothing else; its target is
  derived from measured checks, never set by hand).
  Planned: dev/MARCH.md 1.Q — each case's derived outcome recorded, and a landing never turns a
  passing case loud.
- **C11 · The port is complete.** Done means 100% ported (Dale, 2026-10-28): every in-scope
  definition of dart2wasm and wasm_builder at the pin ported with a body, and every supplementary
  port dart has no counterpart for; a definition whose body only rejects is a stub and is never
  counted ported (2026-10-29); every climbable case of the corpus (test/smoke_corpus.jl and
  dart's ported tests) passes against native Julia, with 0 wrong and 0 errored, and every case
  outside the strict subset is a located rejection naming its reason. Then, in order and never
  before it: robust native-versus-wasm fuzzing, full drift re-audits, and only then anything
  bespoke to Julia. The rebuild's src progress line, which L208 prints after every landing,
  counts the port: ported with a body, stubs, guards and gaps apart. The work is the plan's rows
  for the 100% port, then fuzzing, then the drift re-audits.
- **C0 · The charter holds.** Strict means by construction (Dale, 2026-10-21): a clause of C0
  to C8 is CLOSED only when its guarantees hold by construction, WT's own interfaces unable to
  express the wrong choice (a type that cannot hold the wrong value; an interface with no
  method, field or switch for it; a closed sum matched exhaustively when the package loads; the
  builder refusing at the emitting line), each check naming the definition that is its
  construction, its assertion the check src registers beside that definition, the precedent it
  follows (another language's mechanism: Rust, dart, wasm, …) and how Julia's differs; a
  construction with no precedent anywhere is an invention, which waits for Dale. A check that
  finds the wrong choice at gate time (a scan of WT's source, an allowlist of exceptions, a
  ratchet at 0 or not, or a test that must reach it) is a stopgap, which keeps its clause OPEN
  with the Planned construction that retires it; the differential lanes stay the soundness gate
  and close no clause. Calling a check, a clause or a batch strict or CLOSED on a stopgap is a
  red flag. Dale's requirements are the rows of `dev/LEDGER.md`, each in his words with its why
  and the checks that enforce it; a requirement no check enforces yet names the MARCH row of its
  planned check. Checks: `L125` (this file and the enforcement stack cite each other completely)
  `L126` (no ratchet declares a floor) `L128` (AGENTS.md, the one instructions file, stays
  current and lean) `L148` (every change is audited against this charter beside the work,
  `dev/AUDIT.md`, its entries chained, the lag past 5 commits a printed note, never a held
  landing) `L154` (Planned text cites MARCH rows, never findings, every row naming its clauses;
  every finding the latest audit entry leaves open sits on the row it names until a commit's
  `Fixes:` line names it) `L201` (no clause reads CLOSED citing no check; no clause of C0 to C8
  without Planned text cites a check test/parity_ratchet.jl's STRICT_KINDS does not classify as a
  construction, with its precedent, whose lock only calls the check src registers beside its
  definition; every lock C0 and C4 to C8 cite is classified) `L202` (every closed sum or
  construction in src, an @enum, a `@closed` sum or a definition a construction names, carries
  its `precedent(<ecosystem>: <mechanism>)`) `L203` (each audit entry over src carries its
  `stopgap in disguise:` and `precedent:` lines) `L204` (every ledger row cites a check, a
  clause, a test or its planned MARCH row, and every check serves a row) `L205` (a number in a
  check states its intent and band, and the check fails only outside the band) `L206` (AGENTS.md
  carries every live requirement, generated from the ledger) `L207` (every lock's negative runs
  in every gate, inside the ratchet stage) `R45` (the locks that owe theirs) `L208` (after every
  landing `dev/ship.sh` prints the rebuild's src progress; landings that change nothing under src/
  draw a note from the fifth in a row, never a failure) `L209` (a commit
  carries one Co-Authored-By trailer, the hook and CI refusing a second).
  Planned: dev/MARCH.md 1.R, 1.S — the ledger's planned checks; each of these checks a
  construction, or Dale's ruling that a prose clause is checked by behavior.

## Rules that keep the goal from drifting

1. **The charter is the plan.** Work is chosen by the open clauses; `dev/MARCH.md` lists
   the work, this file decides what counts as done.
2. **Targets never soften.** A ratchet's only terminal state is 0. A site believed
   legitimate leaves a ratchet by moving into an exact, per-site allowlist carrying its dart
   anchor or quarantine reason — a reviewable diff — never by relabeling the ratchet a
   "floor" or its sites "legitimate" (L126).
3. **Every landing names what it closes.** Each commit carries a `Charter: C<n> …` trailer;
   `dev/hooks/commit-msg` refuses a commit without one and CI (`message-hygiene`) fails the PR.
4. **Correct ≠ parity.** A green differential never closes a C2 gap; a dart-faithful shape
   never excuses a wrong value.
5. **No parking.** A charter gap found during the work joins the plan; moving it out of
   the rebuild needs Dale's explicit decision.
6. **Evidence, not claims.** An agent's report counts only with the command and its output;
   the orchestrator re-measures, and the landing check on the exact head that lands is the
   landing's evidence (C10).
7. **Root causes only.** A fix is at the source the fault comes from; a workaround that
   leaves the cause in place is not a fix and does not close anything. A check that crashes or
   misreads valid code is fixed in the check, never routed around.
