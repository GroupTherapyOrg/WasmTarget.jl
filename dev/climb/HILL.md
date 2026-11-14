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
- `unported`: the compile reaches a definition WT has not written yet, or WasmTarget rejects the reader of
  its answer. Climb these.
- `judge-gap`: the judge's wire has no leaf kind for the answer or an argument (a new leaf kind is the judge's
  edit, the lead's hand). Counted apart and left out of the denominator; no climber, no G1; one note to the lead
  for each kind (`judge_gaps`).
- `errored` / `wrong`: a gate (below). Fix it first. An outcome is decided by its cause (spec v17 Y2,
  test/verdict.jl's `RunResult` carries it): `wrong` only where a module's answer is not native's (`_matches`) or
  the two modules disagree; a line missing or a call past its budget is `errored`.

Moves are ranked by **holds**. A hold is the set of cases one rejection site stops: the same kind,
site and reason shape (the Julia types and values a reason names are cut out). A hold's size is how many
cases its fix can unlock. `climb.py holds` prints them, largest first, and a climber takes one.

The corpus does not reach every definition. After its holds come the **src tail's**: for the definitions
`dev/src_progress.sh kinds` counts as not ported at the scored head (Internal and Guard "to triage", and the
gaps), one hold per class's next `tail_chunk`, in dart's order. A tail move must change src/ and add a corpus case
that passes (D12). The half that cannot be forged is measured: each passing case the move adds, run at the base
with the move's corpus (origin's src compiles it), stops at one of the hold's definitions. Whether each definition
is now ported is read by no candidate process (item 10): its reviewer is given the definitions and confirms each is
ported with a body, and a definition left unported is a hold again at the next score, whose kinds origin's code
prints.

A **fix-first** hold is measured or it is refused: G2's lost cases, which its move must make pass, or an audit
finding whose why starts with its path:line, which its move must touch within `fixfirst_lines` lines. Any other
entry of the climb's `fixfirst.json` is skipped with a note naming it (A4); an audit finding about a commit's message,
trailers or process (its `about`, which the auditor must give), one that names no line, or one in a file no move may
change (G5) goes to the note for Dale instead (`lander.audit_route`; door-probe rows).

**The score's src part** runs first, before its smoke: every test file of ported code (test/src_tests.jl's walk of
test/src) at origin's head, in one process of origin's own harness as a landing's check runs each file (the `check`
profile; the one process dev/check.sh declares, `SRC_PROCESS_ENV` and `SRC_PROCESS`, which its shards start and the
score reads at the commit, spec v17 Z7), at default QoS under the score's lock (so never beside a check, and its
instructions counted on the cores a check's shards run on), watched as a measurement's cases are (each file's
`started` and `row` records, `WT_SRC_RECORDS`; its budget learned from origin's commits; a lander waiting served at a
file's boundary). Its record, `src-<head>.tsv`, holds each file's outcome, cost and seconds and the run's warm-up (the newest
`SRC_KEEP` heads' records and plans kept, as STATE/ship keeps its newest `SHIP_KEEP` attempts' files: spec v17 Z7); a
green run is stamped with the landings its COMMIT holds (`core.landings_at`), never those landed while it ran, and a
landing's window index counts landings, never commits; a
run that writes no result records nothing and the head is not verified (D9). A file red there is run again alone, every
such file in one process; one green alone, or one red at the very commit whose own run recorded it green, reads
differently alone and in its run: a note for Dale naming both runs, and a **flaky** known red. Each still red is
bisected over origin's first-parent commits since it last ran green (a score's run or the files a landing's check
reported it ran green: each file's newest green run, one map, `src-green.json`), one process a step for the files
sharing a range (`measure.src_red_at`, the one answer to "is this file red at this commit", and `src_locate`). A file
located to a landing is a **src-test fix-first**, naming its first test that did not pass; the entry names that landing's
hold, whose moves run the file while the entry stands. The known reds are ONE registry, the src-test fix-first entries (`measure.src_reds`), each
keyed by its first non-passing test, so a different failure of a file is a new red; a located red is left out of the
shares until its fix lands, and only a landing whose check ran its file green clears it; a flaky one runs in every
landing's set and is counted by `src_unverified` until it passes twice (a score's run or a landing's check). A score
that runs a located red green resolves it. A known red (a G2 loss, a src-test red, flaky or located) stands at most
`fixfirst_max_landings` landings after it is filed: past that the lander admits fix-first moves alone, one note.
A fault of any kind in the src part is `src-failed` with its traceback and one note, and the smoke runs still.

The runner is the judge's (spec v18 P2: `test/runner.jl` and `test/src/runner.jl` are in JUDGE_READ, no move
edits anything on the verdict's path, and the keeper role is gone). A shape the runner cannot call or read (a
reference argument, a result of several values, an import it does not give, no such entry) is written as its own
wire line, `gap <text>`, and booked `runner-gap`: counted apart, no G1, no climber, one note to the lead when the
set of shapes changes; a marshalling change is the lead's hand. A NEW leaf kind (a value the
judge's wire has no kind for: "the judge's wire has no leaf kind for …"), and a reader's arity ("the judge reads a
tuple's leaves …"), are the judge's edit, the lead's hand (`test/verdict.jl`'s `LEAF_TYPES` and `Leaves`, spec v16 X1).
What native Julia answered is captured by `test/oracle.jl` alone (`answer_of`, the one code that calls a case's
function, and the record of its answer), which no move changes: a value of a primitive type is kept as its bytes and
its type, a singleton and a thrown exception as their type, any other value as its type alone, and every type by its
structure (`type_path`: its module's name, its own name and its parameters, read by field access, never by `show`, and
found again by `getglobal` and `Core.apply_type` alone, the type found checked to be the one named). So a new leaf
kind (`test/verdict.jl`'s table) reads the answers already captured as they are (probed: the store's tests
round-trip a String, a Vector, nested tuples, a corpus singleton, a throw, an `Int16` and a bound String argument through
the records; a type resolved from what `show` prints instead found `Int64` for a corpus type whose `show` printed
`Int64`, and ran that `show`, where the path found the type itself and ran nothing).
An audit finding in any other file no move may change goes to the note for Dale, who batches such fixes as commits
made by hand (D52); the climb never waits on them.

A move counts when a case of its hold passes, or stops at another definition (its file and name) that the base
already had while a hunk of the diff overlaps the lines of the definition it stopped at before (the definition's
top-level form, read by Julia's parser, `dev/climb/spans.jl`; a dart anchor's, the form whose @parity cites it),
never its name somewhere in the diff's text. A reworded rejection at the same definition, a new stub that moves a
case (refusal 3), or a stop moved by a change elsewhere is no progress. S is reported over the corpus as it stood
at launch; cases added since are counted apart.

Behind S, the scoreboard also reports src progress (D40, D46: bodies ported of anchored, never a stub
counted), the runtime library's gaps and the tokens spent. These are tie-breaks, never the climb.

## The gates (a move that breaks one never lands, whatever S gains)

Every move is judged by the difference from its own base: the driver measures the same cases at the base the move
started from (origin/wt2 then, cached by its hash for every slot) and on the move, each in a tree the driver owns
behind the door (below). The climb keeps **one table** of every case's latest row, each with the count of the origin
commit it was measured at (`git rev-list --count`); a score and a landing both write it, and a row replaces an older
one only, so a score of a head older than a landing never undoes that landing's rows. The table is the holds' and
G2's "before", and nothing else is (item 8: no pass set, no rows applied again).
**Every measurement writes no verdict from the code it measures** (item 7: a score, a base, a candidate and a
rebased check alike, R5-4): three roles behind the door, each in its own profile and directory and reaped before
the next, in this order. Native answers come first, every label's, compiled or not, before any compile: a landed
label's read from the store (the oracle, below), never computed, and each label the commit adds answered by
`measure.answer_labels`, the one definition of a native answer, exactly as a replay of that commit answers it: a fresh
native process of its own, which never loads src, loads the snapshot and that label's unit alone, calls that one case
once and exits. Compile loads the commit's src and writes each case's modules, or its outcome when it did not compile, which
may only be `unported`, `outside` or `errored` (any other is read as errored, R4); it shapes each case's readers by
that case's answer's shape (`WT_SMOKE_SHAPES`, the shapes' process's file: no value, spec v16 X1) and calls no case's function natively (R2: a body run there
ran before the later cases' compiles, so it could change what they compile; probed: a case that adds 5 to a global and
a later case answering that global plus 1 read passed when the compiling process ran the first body, module and
native both 6, and read wrong once it ran none, module 1 and native 6, a dependence one process a label now rules
out; a body that redefines `WasmTarget.compile` with `@eval` is one WasmTarget does not compile, `Expr(:copyast)`, so
the compiling process never ran it). Compare runs no corpus code, binds each answer to its case's modules, runs node
and writes the cases. The judging processes run corpus code a move may add (R7-1), so they read no module and no
compile record and run in the `native` profile: it executes Julia's install and sh alone (no node or Homebrew), and
its reads are an allowlist, its judging directory, its labels, its own directory and Julia's install, beside the root's listing, the locale and sh's choice of shell
(`door.NATIVE_READS`: each name found by bisection and then each removed in turn, the kernel logging no denial of
these runs), so no other file of the run, the compiling process's stdout `compile.log` among them, is readable (R8-1;
probed as `_wtm1`: a read of `../compile.log` from a judging directory failed with EPERM, where HEAD's hide-list
profile read it; node and `cat` refused). Each label the commit adds is answered in a process of its own. A judging
process writes its records to its stdout alone, a pipe the driver drains into a file of its own as it is written, and
prints everything else to stderr: `started <label>`, that case's block (its `answer` record and then its `group` and
`leaf` records, every one naming it, or one `noanswer`), and `ended` after the last; the driver keeps a block only
between its label's `started` and the next record, refuses a line outside its case's block, and reads nothing after
`ended` (no answers file is written at exit). So code that runs at exit, or in one case's call, writes no other case's
answer (probed with the red team's case whose `atexit` rewrote the plan, aimed at the pipe, and one whose body wrote
another case's block: het_tuple read wrong and the second was refused by name; a file of the process's own was
rewritten in place at exit before the driver read it, so the records are a pipe, never a file). Code that runs where
the corpus loads in that process is another matter: round 9's four forgeries read wrong or errored against these
records, where the plan's judge read `bomb_typed` passed, but the same forgery aimed at the `answer` records (a
`_started(::String)` defined at load that lowers het_tuple's native 9 to 8) read passed. The store below closes it
for every landed label: no process that loads the corpus computes a landed label's answer. The compiling process's records are held to the
same rule (R3): each case's block, its `module` and `rejected` lines and then one `compiled` or `row`, every one naming
the case in flight, is copied into the driver's own file as the driver reads it (never read again from the process's
file, which it can rewrite in place), and a line naming another case, one before the first `started`, one after its
block's end or a block with no end before the next `started` is refused as a lie, the measurement failing as the
measured code's (probed: code run at load registering an `atexit` that appended a forged frame for an unported case,
two modules returning native's answer and `compiled`, was refused by name, where the driver before the rule read that case
passed; the honest corpus unchanged). **The verdict is decided by judge files only** (spec v16 X1): no file a move may
edit is loaded in a process whose output is a verdict, and no process that runs code a move may edit is handed an
answer. A measurement after the native answers is three processes: the **compile** (`test/smoke.jl` with the measured
src) is handed each stored answer's SHAPE alone (`shapes_of`: the measured commit's own projection of the store, test/oracle_read.jl's `Shape(a)` written by
`shape_lines` in a process of its own in the `native` profile, its judge files alone, never a copy in the driver, so a
driver and a measured tree at different commits cannot disagree on it: the judge3 review's S1. A judge from before the
program (a move in flight on an older base) is projected by the first program origin's history holds (`shapes_judge`),
which is exact: the driver's own projection before it, byte for byte, each field the stored record's own re-encoded; any
failure of the shapes' part is the store's gap (OracleGap: the hold kept, never charged to the move: the judge4 re-check's
F1); the bound
String positions and their Strings, the count of wire arguments, the argument types' paths, each leaf group's type path,
capture kind and paths; never a native value, a leaf's value or an argument's value), and writes each case's modules and
the calls that read them (`call` records: a module, its entry, the case's wire arguments, which the corpus's own text
holds; `test/verdict.jl`'s `bind` and `plan`); the **run** (`test/runner.jl`, the judge's, and node) can reach
nothing but its own directory (spec v17 Y1): the driver copies `RUN_FILES` and the calls `run_input` composed into it,
and its `native` allowlist profile reads that directory, Julia's install, TOP/tools and `RUN_READS` (node's OpenSSL
configuration) alone, executes what TOP/tools holds (Julia, node, and the door's homeacl, nobootstrap and ps) and
/bin/sh and /bin/bash alone (spec v18 P6) and writes that directory alone (probed as `_wtm1`: an
open of the driver's tree, the compile's tree, another role's TOP/in, red's landimg file, the deps images and the
store, and an exec of Homebrew's node, each refused, where HEAD's `julia` kind opened four and ran node); its calls
are the compile's with the judge's fixtures interleaved at positions drawn each run, every module under a label drawn
as every other's, and patched copies of
`test/fixtures/runner_patch.wat` whose constants the driver draws and writes at the declared byte offsets, a trap
and a throw among them. The fixtures are the runner's regression test, never a defence against a runner that adapts
(spec v18 P2: the runner is the judge's, no move's): a fixture call names an export where a case's names `-`, and its
module is the frozen runner.wat or runner_patch.wat outside its slots, so a runner can tell them apart (the
architect's p1 and red's p3, round 15). It is handed no answer, no expected outcome and no plan, and writes each
call's RAW result in the judge's wire grammar (`ret <kind> <bits>`, a float as its integer bits; `exc`; `err`; `gap`, a
shape it cannot call or read), one fresh `WebAssembly.Instance` a call (a module compiled once), the export called from a wasm
wrapper so no float crosses JS; the **verdict** (`test/verdict.jl`, a judge file, in the `native` profile reading its
own directory alone, `VERDICT_FILES`: no runner, no node) checks the runner's fixtures where the driver's plan placed
them, each drawn fixture's wire from its own table (`place`, `fixture_wire`; any fixture not bit-exact
fails the part as the runner's, by name), takes the compile's records as its frame (each label it recorded is judged and
nothing else, its row keeps the compile's outcome), binds each stored answer to exactly that case's modules in their
order (`bind`, the compile's own binding, each compile the answer asks for popping the case's next record under its
key), checks the compile's calls are exactly the ones its answer's binding makes (`plan`: the same modules, entries and
wire arguments), decodes each call's raw line by its own table and compares bits at native's leaf kind (`_matches`):
a case with no answer, a module missing, one more than its answer asks for, a key that differs or calls that are not the
answer's is errored, located (probed with the red team's two forgeries of R3: their cases read errored and unported;
spec v16's probes in council/v16-report.md). The answers are written into the verdict's directory only after the
compile and the run are reaped. The judges' smoke, runner, verdict, capture (`test/oracle.jl`) and corpus come from git objects. One function watches all four
(`measure.watched`, O6-9): the compiling and the native process each flush `started <label>` before each case, the
driver stamps each record with its own clock as it reads it and times each case from one record to the next (R6-9:
no number a measured process reports is a budget's input, nor the seconds of a row the table keeps; a process's
first case, which pays its load, is not timed), and learns them only from measurements of origin's own commits (a base,
a score, `confirmed()`'s), never from a candidate's or a rebased run (A8-2; probed with the architect's stand-in: a slow
candidate taught nothing and a later hang was cut at its own 3-s budget by name, where HEAD learned the slow run and
cut the hang at the 40-s wall with no name). The driver reads every label a corpus registers with Julia's parser
(`test/corpus_loader.jl --labels`, the corpus loader's one reader of a registration, `registered`, which a unit's
load, `unit_paths` and the ratchet's L153, L226 and L227 read too; the snapshot and each unit file apart, a
registration whose group or a case is no literal refused; it reads the 166 groups and 1,949 labels of the snapshot,
as the regexes it replaced did: a list of labels, never a proof that the corpus loads, which the process that loads it
gives) and names each process's labels exactly; test/smoke.jl runs them in sorted order, so a `started` line
naming a label the run does not take, one already started or one out of that order is refused, the process reaped
and the measurement failed as the measured code's (R7-8, R7-9). A measurement is a row for every label it runs or no
result: a process cut with no case of its own in flight, between two cases or past its wall (one that stalls at its
load, before its first case, is the measured code's, its src or its corpus, its records refused by name)
(`wall_factor` x its load and its labels' learned seconds, `pkg_wall_s` for one never learned: the per-case budgets,
not the wall, bound a healthy run of any size; a lander's yield and the reload after it are outside it), is a
`measure-cut` naming the label in flight and the labels not reached, and nothing of it reaches the table, S or the
pass set: a score so cut is `score-failed`, a base or a rebased check the driver's failure, a candidate's
infrastructure (O8-1; probed with the operator's five 4-s cases past a 9-s wall: refused, naming g/c2 in flight and
g/c3, g/c4 not reached, no `scored` event and no table, where HEAD scored the two cases it reached as the head). A case with no new record for its
budget, or one in flight when its process ends (a segfault, an abort, jetsam: O9-3), is booked errored and named,
and the process started again without it (R5-10; probed with the operator's crash.py, the third of five cases ending
its process: g/c2 booked "the process ended during the case" and g/c3, g/c4 run, where HEAD's frame was g/c0, g/c1
and the score stuck): the first case and a
label the driver never timed get `pkg_wall_s`, a timed one max(`case_min_s`, `case_factor` x the longest the driver
saw it take), so a case is errored for time only past a budget learned or past the first-run wall (A7-1; probed
with a stand-in compiler: a 5-s case under a 3-s `case_min_s` passed at its first run and every run after, a run that
rejected it at once shortened nothing, a hang was cut at the first-run wall by name, and each lying `started` line
was refused, where HEAD booked the 5-s case errored at every run and kept the lies' records); the run and the verdict, which have no case records of their own, get `case_min_s` plus
`compare_module_s` a call (probed as `_wtm1`: a native case that looped was cut by name and booked errored, where
the old native run's wall was `smoke_wall_s`).

**The oracle: native answers are data, recorded once.** A label's native answer is the answer computed from the
corpus at the commit that added the label (for the corpus as it stands at bootstrap: at the bootstrap commit), in a
process of its own unit, recorded once by Dale's uid, and read — never recomputed — by every later measurement; the
compiling process calls no corpus body natively; a compile record and an answer line are kept only inside their own
case's block. Replay, the audit and the bootstrap are the same function. The store is `$STATE/oracle/`: one file per
unit, `<unit commit>.tsv`, its key line and then each label's records as `test/oracle.jl` writes them (`answer`,
`group`, `leaf`, or `noanswer`), and `index.tsv`, each label's unit, the sha256 of that unit's file and the git blob
of the corpus file whose text it answered. The answering program is one definition, `core.JUDGE_WRITE`: the judging
entry `test/smoke_judge.jl`, the capture's write half `test/oracle.jl` (`answer_of`, `answer_lines`, `type_path`, its
own module `WTOracle`) and `test/corpus_loader.jl`, which decides the program a unit's load makes and writes its
digest (spec v14 V2). It is used three ways and restated nowhere: G5 (no move's rule admits those files), the key (its
`judge` field the sha1 of their blobs: `judge_key`), and the answering process itself, which reads every file it loads
through one function (`_judge_read`, with `Base.include_callbacks` catching any other `include`) and prints the list
(`loads <label> <path>=<blob>;…`) before its case runs; the driver refuses an answer whose list is not exactly those
files at the store's judge, the snapshot and the label's unit (`loads_checked`). The judging process never loads
`test/runner.jl` (the run's), `test/smoke.jl` (the compiling side) or `test/verdict.jl` (the verdict), so an edit of
any replays nothing; the store's decoder (`read_answers`, `_restore`, `resolve_type_path`, the `Named` and `Opaque`
stand-ins, `read_shapes`) is `test/oracle_read.jl`'s, a judge file outside the key (no move's).
`test/runner.jl` is loaded in the run process alone, a child of its own wherever it runs (a measurement's run part,
standalone `test/smoke.jl`, and the test suite through `test/run_child.jl`, spec v17 Y5: no process that judges or
writes a test file's record loads it), which decodes no answer and writes no verdict, so what it does to
a judge module there changes no verdict (the scan that checked its methods, `_runner_sealed`, is deleted: spec v16 X1).
The key's fields (KEY_FIELDS):
`judge`; Julia's version and commit and the host (its architecture, CPU, fused multiply-add and word size) as a
process of the measuring role that loads no corpus and no src prints them (`test/smoke_judge.jl`'s `WT_SMOKE_KEY`);
the answering process as declared (`ANSWER_PROCESS`: its argv and its whole environment, `answer_key_env`); and the snapshot's blob (a snapshot edit is a key change, Dale's
rare act). Every store write (a freeze, `oracle-replay`, the audit's answers, the bootstrap) is keyed by one judge,
origin's (`store_judge`), the one every measurement reads under. A measurement reads every landed label from the store
under its own key and runs no process that loads a corpus for it; a label is landed only when origin's corpus
registers it from the source and the text the store's index line names (its unit file's last adding or changing
commit and that file's blob, or, for a snapshot label, the bootstrap, its text the key's: `landed_labels`), so a stored
answer serves only the text it answered: a snapshot case removed by hand whose label a unit registers again, with
another function, and a unit file edited in place are added labels, answered fresh, and their freeze replaces the
line (probed in a scratch state: v13/drv, v14/drv). Only the added labels are
computed, each by `answer_labels` in a process of its own. A landed label with no index line, a unit whose bytes are not the index's
sha256, or a unit under another key is a located failure of the measurement (`OracleGap`, D9): a base, a candidate or
a rebased check fails as the driver's, and a score books that label errored with why; it is never a recompute from the
live corpus, a pass, or a skip. A label the store holds as `noanswer` is errored with its why in every measurement
(probed in a scratch state with three of origin's labels: answered from the store, no native process ran, het_tuple and
bad_raw_string_runtime passed and typeof_str_is_String unported; with het_tuple's index line removed the measurement
raised "no frozen answer: oracle/index.tsv names no unit for it" in 8 s, before any compile; with one byte of the unit
changed it raised "not the bytes the index names (sha256 mismatch)" for its three labels; with a forgery in the
corpus that ran at load and lowered het_tuple's answer from 8 to 7 in the judging process's records, het_tuple passed on
its stored answer, where the driver before the store read neither fault, recomputed every label from the live corpus,
and read het_tuple wrong, native 7).
Every native answer comes from one function, `measure.answer_labels`, the one definition: a label's answer is what
`test/oracle.jl` captures when a fresh process of the measuring role in the `native` profile loads the snapshot and,
for a unit's label, that label's unit alone (its judging directory holds the answering program's files, the snapshot
and that unit, nothing else), calls that one case once at its world, writes its one record and exits
(`test/smoke_judge.jl` refuses to be named more than one label); a case killed past its budget or in flight when its process ended gets the driver's own `noanswer`, and a
process that ended before its case (its load failed) writes no answer, refused by name. A gate, a rebased check, a
freeze, a replay, the audit and the bootstrap all call it per label, so no other case's body runs in the process that
answers a label, and the judge's facts for that label (its case, its arguments, its world) are taken into a local list
before any body runs, with `W_JUDGE` a constant taken before the snapshot (probed: the red team's three-label unit
whose outer two bodies set the judge's world entry for the middle label, `fg/b`, stored 1 in one shared process in both
orders at 2a8978ef; answered alone it stores 2, and a judging process named three labels refuses to run). The
bootstrap (`climb.py oracle-bootstrap`, refused unless the climb is paused, under the verify lock) answers every label
of origin's corpus that way, one pair of processes a label (below), appending each label's records to `oracle/<at>.partial.tsv` as it is
answered, closed by its count line (`answered <label> <n>`) and fsynced, so a bootstrap killed or cut by a power loss
loses at most the label in flight: started again, it truncates the file after its last whole chunk (a cut tail
dropped, never read as an answer nor glued to the next) and answers only the labels it lacks (probed: killed between
two labels, inside one, and with the file torn inside its last chunk, it resumed to the bytes of an uninterrupted run).
**Two processes a label** (spec v16 X2; precedent(reproducible builds: Debian's reprotest)): every answer, at a gate,
a freeze, a replay, the audit and the bootstrap (`answer_labels`, the one definition), is computed by two fresh
processes run at once, the second varied in what a fair test must not read: another cwd, its own pid and clock by
nature, one environment variable the key does not hold (`PAIR_VAR`, `WT_ANSWER_PAIR`), other placeholders for who runs
it (HOME its own scratch, USER and LOGNAME `wtpair`: `PAIR_ENV`, spec v17 Y4; its uid is the first's, one role runs
both, so a body that reads its uid reads one value), its units' file at another path, and its own depot and scratch,
each process in a profile of its own that reads and writes its own scratch alone (and the judge's files, its labels
and its log), so neither can hand the other a draw (red 8d). A process of the pair that ends without its case (killed
past its budget, in flight when it ended, or ended before it) is the label's Booked noanswer, located, never stored
and never the measurement's failure (`ended_without`: one rule for either process, operator 7). Each must load exactly the keyed program (`loads_checked`), and their records
must be byte-equal; else the label is its body's own `noanswer`, "its answer depends on its process", naming the
first record that differs (event `answer-process-dependent`). The two run side by side (each single-threaded), so a
label's wall is the slower one's, not the sum: timed on AC under the timing lock on a quiet machine (spec v16 X7), 12
snapshot labels through answer_labels took 10.72 and 10.71 s a label as pairs against 10.66 and 10.62 s as one process
each (533f253e's driver), alternating: about 0.1 s a label, so the bootstrap's and a replay's cost below stands. Two processes find a
dependence only when it shows in their two runs: a hash order of two keys agrees by chance about half the time.
Every answer record is read by one wholeness rule in two readers (`measure.unit_blocks`, linear, and
`test/oracle_read.jl`'s `read_answers`): an `answer` and exactly the `group` and `leaf` records its counts name, a
unit label's `digest` last, or one `noanswer`; a block short of a count, a cut line, a foreign record, a second digest
or any record after the digest or the noanswer is dropped; both read one file of edge blocks
(`test/src/oracle_edge_blocks.tsv`, written by the capture's own writer) to the same verdict on each (the Julia
reader's test and `climb.py door-probe`'s reader rows; spec v14 V4). An answer's records past `answer_cap_bytes` are
refused by its judging process, a `noanswer` located, and by the driver's drain whatever the body writes: it copies a
native process's records up to `answer_cap_bytes` and a record's margin (`RECORD_MARGIN`, 1 MiB) and past it reads,
holds and stores nothing more, the case refused, located (probed: a body writing a 100 MB block for its own label
through the records stream was kept whole, the driver's peak RSS 511 MiB, before; refused at 17.8 MB, 39 MiB, after). Its processes run at
default QoS (`oracle_background`), one single-threaded process of about 9 s a label at a time, never beside a landing
check (the lander holds the verify and score locks): measured on AC (v11b, after the judge stopped compiling a closure
per snapshot case), 7.6 s a snapshot label's process and 8.8 s a unit label's at default QoS, 34.8 s and 45.3 s at
background QoS; the driver adds about 2.7 s a label, and 384 labels measured through the door took 10.6 s a label.
A landing freezes the labels it adds (`measure.freeze`, before the item leaves the queue): the landed commit's unit,
from the answers its rebased measurement computed (or its gate's, origin unmoved), by the function a replay runs,
byte for byte a replay's, when that measurement's corpus is the landed commit's, else by a replay (`answer_labels` on the landed commit); a unit
already there with the same bytes is no change. A lander killed between `landed` and the freeze leaves the item
queued, and the next round's reconcile books it again and freezes it once. A freeze whose label's process fails (its
load, its records refused, its answer program not the keyed one) books that label `noanswer` with the reason, located,
and the item leaves the queue: no item wedges the lander (spec v14 V5). Each reconcile also freezes, by its source
commit, every label origin's corpus registers that the store does not answer as origin registers it (a hand landing,
a freeze lost, a unit file edited in place: spec v14 V2); a snapshot edit is a key change (the key's `snapshot`
field), so every measurement fails, located, until the one replay (`climb.py oracle-replay`, with the climb paused,
under the verify lock), never served as stored (D9); the
index line of a label the corpus drops is removed (`oracle_drop`: its unit's file keeps its bytes), so a label
registered again later is answered fresh (probed on a scratch chain, a bootstrap, a commit adding a case and one changing a line: a lander killed between `landed` and the freeze left the item queued and its label unanswered, and the next round froze it, a second freeze running nothing; a label the store lost was replayed by the commit that added it; the changed line was named once for Dale; where the lander before this froze nothing, the item left the queue and the next measurement found no frozen answer).
The audit (`climb.py oracle-audit`, under the verify lock) checks the store against its definition: every unit's bytes
against the index, and a seeded sample of `oracle_audit_k` stored answers each answered again alone, in a process of
its own at its unit's commit, compared byte for byte; a difference names the label, its unit and both answers in a
note for Dale (a body that answers differently each time, a key the store failed to capture, or a unit edited with its
index) (probed: a stored answer changed from 5 to 4 with the index's sha256 rewritten to match, which every measurement reads as genuine, was found, "stored native Int64 4; replayed alone native Int64 5"; the store unchanged gave none; at k 0 nothing is found).

The cases: the hold's, every passing case of the hold's groups, a stratified sample (the
quickest passing case of every group), every corpus case added since the scored head. When origin has moved past an approved commit's base by its landing (by more than dev/AUDIT.md), the
lander measures one tree, the commit rebased onto origin by the one merge a landing makes (git's merge with origin's
packages merge driver, as dev/ship.sh's rebase runs it, and src/julia/packages.jl regenerated on a fresh depot when
that driver merged it; probed: an origin commit replayed onto a later one gave origin's own tree, where git's text
merge conflicted), under one hold of the measurement lock (its regeneration at background QoS), against the table; ship.sh lands that
very commit (`WT_SHIP_EXPECT`), whose parent is origin's head, so its rebase replays nothing and no merge driver or
regeneration runs in it, and origin having moved since is a refusal (`moved`) the lander measures again, never a
second merge; an audit's entry or a commit made by hand is replayed onto origin by the lander the same way, commit by
commit, never measured, under the verify lock (O8-4: its regeneration is Julia as `_wtland`; probed with a stubbed
replay: the lock held during it, where HEAD held none), and every replayed commit keeps its author and author date (D13 reads it) (A7-5, R6-8;
probed against a scratch remote: a commit whose parent was not origin's head was refused
`moved` before any rebase, where HEAD's ship.sh replayed it onto origin and ran its check); every label whose outcome there differs from the table is measured at origin itself before it is charged or
counted (A5-1, R5-12, O5-6): a loss origin shares is origin's (the table takes origin's row, a G2 fix-first is
filed, the item is not charged), and a case origin passes already is no progress of the item's. Once per origin
(the verdict kept on the item). Every case of its hold passing at origin, it is done by another landing and dropped
with no stop (D5); otherwise it is judged as a move is, progress included, worse goes back to its hold, and every
row the rebased run measured enters the table at its landing. A rebased run that writes no cases is run once more
before it is the move's (O14). A hold whose cases no longer stop at its key at the base is advanced and
skipped before any agent runs. So G2's net before a landing is the hold's groups and one passing case of every
other group (K3): a loss outside it is caught by the next full score, where it becomes a fix-first hold.

| Gate | Checked by | Why (Dale) |
|---|---|---|
| G1 no case the move makes wrong or errored | the driver's measurement, against the base | D9: "efficient because it fails fast and LOUD" |
| G2 no case that passed stops passing | the driver's measurement, against the base; over the whole corpus at the next score, against the table, where a loss is a fix-first hold | 1.Q; the oscillation of 2026-10-28 |
| G3 the landing check green | `dev/ship.sh` → `dev/check.sh`, run by the lander alone | D13, D14 |
| G4 a blind fidelity review approves | `dev/climb/reviewer.md`, reviewer outside the climber, itself measured (below) | D1, D2, D45 |
| G5 the judge untouched | the driver refuses the diff, at review and again at landing | Theo's rule: never let the climber edit the eval |

G5 is a positive rule (R14): the driver reads `base..sha` in the main repository with `git diff --raw -z
--no-renames` (no replace refs, no system attributes, no textconv or external diff), so a rename is a deletion and
an addition, each judged. Every entry must be a regular file of mode 100644 (a symlink, a gitlink, an executable
bit or a type change is refused) whose path the move's kind allows, changed only as its rule says; every other
entry is refused, named. The rules (`MOVE_RULES`, `dev/climb/core.py`), from the paths the climb's own landings
changed:
- a port move: `src/**.jl` and `test/src/**.jl` (not `test/src/runner.jl`, nor `test/src/corpus_loader_negatives.jl`,
  `test/src/oracle_read.jl` or `test/src/verdict.jl`, the judge's tests), any change; one new corpus unit,
  `test/corpus/<slug>.jl` (a new file, at most one a move; `test/smoke_corpus.jl` is no move's); `test/smoke_times.tsv`,
  added lines only; `dev/quarantine_unpinned.txt` and `dev/quarantine_no_counterpart.txt`,
  deleted lines only, each the line of a definition the same diff pins (L227); new `dev/formal/*.tla` and `*.cfg`
  files only (an existing model changes only by ruling). Names are ASCII letters, digits, `_`, `.`, `-` and `/`.
- an audit: added lines of `dev/AUDIT.md`, one commit.

**The corpus: the snapshot and its units.** The snapshot, `test/smoke_corpus.jl`, is the corpus as it stood at the
oracle's bootstrap, included into Main as it is; no move changes it (G5; a change of it is Dale's hand alone, named
for him as a key change, every measurement failing, located, until `climb.py oracle-replay`). Each later landing that adds
cases adds one unit file, `test/corpus/<slug>.jl` (a move adds exactly one, a new file, nothing else under the
corpus: G5), and `test/corpus_loader.jl` loads each unit, after the snapshot and in landing order, into a module of
its own, `Main.U_<slug>`. The order is git's: the first-parent order of the commits that added each unit file, read by
the loader's `unit_order` from git's log (the driver hands each judging process the measured commit's log, its argv
checked by the judge; a developer's or CI's `julia test/smoke.jl` runs the same git itself, a shallow clone refused;
a unit file the log does not name, a move's own, comes last). A unit sees Base, Core and, by name, what the snapshot
binds, never a name of the judge's and never another unit. Its load is a function of its text, Julia's build and the
snapshot, so every process that loads it (the answering one: no WasmTarget, `JULIA_LOAD_PATH=@stdlib`, its unit alone;
the compiling one: WasmTarget, `--project`, the units of every label it runs; G5's) loads the same program: every
read a load makes passes one function, `_reader!` (a GlobalRef, `getglobal`, `isdefinedglobal`, `get_binding_type`, a
dotted callee's `getproperty`, `getfield`, `nfields`, `sizeof`), as every write passes `_writer!`, and it admits a
binding of the unit's own module, a `const` binding of Base's or Core's modules or of the snapshot's names (Main is
read through as the snapshot's namespace alone: the fixed set of names Main binds after the snapshot less those
before it) whose value is the same in every process (a type, a function, a bits value but a pointer, a String, a
Symbol, an immutable of those, a module of Base's or Core's), and a field of a value the load made or of such an
immutable, never of a type or a module; Main's other names (`WasmTarget`, a unit's `U_<slug>`, the judge's), another
unit's or a package's module, a binding that is not const, and a const of a mutable value (`Base.DEPOT_PATH`,
`Base.LOAD_PATH`) are refused at the read, by name, so every branch a load takes and every operand a writer gets is
the same in every process. A method on another unit's function is refused; a body naming another unit, `U_<slug>`,
is refused by a scan of its operands, an early refusal and no guarantee (a body can compute such a name, or read
`Main`, and tell its process when a case calls it: RISKS (d), G4's). The load's digest says which program it made:
its writes in order (each writer's name and operands; a type by its structure, a TypeVar by its position, never its
name, which lowering takes from a process-global counter; a value by its bytes, a method by its lowered code and its
slots' names and flags; no address, path, world or process counter; and what it cannot write whole it refuses at the
write, located, never writes lossy: a pointer, a mutable object the load did not make, Main as a value, a value
nested past 48 levels, so the digest tells apart exactly the loads whose writes differ), written by the answering process in each of the unit's
labels' blocks (`digest <label> <sha-256> <writes> <entries>`) and kept by the store with the answer; the compiling
process compares its own load's digest with the stored one before it compiles a unit's label (the loader's
`digest_mismatch`, the one compare; an added label's two records meet there too), a difference the label errored,
"the program loaded here is not the program answered", naming the unit and its first differing write (D10's shape:
the read rule refuses, the digest only rings). A snapshot label has no unit and no digest: the snapshot is Dale's,
frozen (G5). A label's program is the snapshot plus its own unit in every process (spec v14 V1): a unit's methods on
functions it does not own (the snapshot's, Base's, `Core.kwcall`'s for a keyword method) are deleted once its world is
taken (`_retire_foreign!`), so each lives in its unit's world range alone, and a method on a function a unit does not
own takes, at some argument, only the unit's own values (`unreachable_without`, by structure: one of `OWN_ONLY_FORMS`,
a type the unit made or the Type of one, an invariant parameterisation with such a parameter (`Vector{_T}`, `Ref{_T}`,
`Pair{_T,Int}`), a Tuple with such an element, a where-bound of one, a Union of such; the decision and the refusal's
text read that one table, spec v16 X6; `Union{_T,Int}`, `Vararg{_T}` alone, `Type{<:_T}` and `Vector{<:_T}` stay
refused), so no other unit's or the snapshot's values reach it natively either; a process loads only the units of the labels it is named (`WT_SMOKE_ONLY`;
`unit_paths`), every unit when it is named none (the score, a standalone smoke), and the worlds agree, so a gate's
cost does not grow with the units landed; what a verdict rests on is the table of premises below. Each of its forms is loaded thus: its macros from a closed
table (Base's, none of which runs its arguments as it expands; `@eval` off it, and `@enum` refused by name: a new
enum case is Dale's to add to the snapshot, which holds ten); Julia's lowering of it (`Meta.lower`) in the unit's module; then the loader runs that lowered code itself,
one statement at a time (the stepper: it holds the SSA values and locals, and takes each branch by the value the
condition has), each statement run only once its real operands are checked: a call's real callee and real arguments
against closed lists (builtins that build or compare a value; builtins that read a binding or an object, admitted on
what `_reader!` admits; builtins that declare or set a binding or make or fill a
type, admitted only with the unit's own module, or a type the unit made in this load, as their real target; and the
generic functions a definition's lowering calls, `Core.Typeof`, `Core.TypeVar` and `Core.kwftype`, called at the
judge's world and carrying no unit's method, checked before and after every form; a dotted callee's binding read as
`_reader!` admits), every name a statement binds (1.12's `:const`, `:global` and `:globaldecl`, 1.13's
`Core.declare_const` and `Core.declare_global`, `setglobal!`, a function's `:method`: one reader) a fresh name of the
unit's, every `:method`'s callee, read from its real signature, no function of Core's, of Julia's compiler or of the
judge's, and that signature replacing no method and reachable only by a call that passes one of the unit's own types
(an early refusal of piracy, before the method exists); a definition statement (`:method`, `:const`, a global's
declaration, `:new` of a type the unit made) is then run by Julia itself as a thunk of that one statement, its
operands the values checked, so what Julia runs is exactly what was checked; every other statement kind is refused by
name (`Core.EnterNode`, a `try`, among them, and `PhiNode`, `PiNode`, `UpsilonNode`, `PhiCNode`, `:foreigncall`,
`:cfunction`, `:new_opaque_closure`, `:leave`, `:pop_exception`, `:copyast`, `:meta`, an unknown head), a form Julia
lowers to no thunk is matched by its head (a bare `global x` steps as the declaration it is, so it loads on 1.12 as on
1.13; `module`, `using`, `import`, `export` and `public` are each refused by its own name, 1.13's `Base._eval_import`
too; any other head as unknown), and a form past `STEP_BUDGET` statements is refused as a loop at load; then its methods are read back (no generator, no effect
override, each attributed to its form: one count over Julia's method table a load, each method in
the world range of the unit it falls in). A constant is stepped like any form (one evaluator of Julia's semantics,
the stepper: what lowering emits is what runs, `literal_pow` and `Val` for `2^-1` among it). Every call a form makes
at load is matched by its callee's identity against ONE table, `CALLEES` (spec v14 V3): each entry a kind (pure,
reader, writer, a definition's machinery, a constant's arithmetic, refused by name) and its one-line reason, anything
else refused by name with the rewrite a climber can make (dev/climb/climber.md lists the table from its own text,
`table_markdown`, checked by the loader's negatives); the machinery, `Core.TypeVar`, `Core.Typeof`, `Core.kwftype`,
`Core.UnionAll` (so `<:` sugar and `where` load) and the keyword slurp's `pairs(NamedTuple)`, runs at the judge's
world; a constant's arithmetic (Base's arithmetic, number conversions, `typemax`, `typemin`, `T[…]`'s `getindex` and
`[…]`'s `vect`, `literal_pow`) runs there on values of Base's alone (never a mutable Number: BigInt and BigFloat are
off it, and `big"…"` off the macro table, since their digits lie behind a pointer and their arithmetic reads MPFR's
process-global precision), an exception a located refusal; a constant is never `===` a mutable object of Base's
(`const _K = LOAD_PATH` is refused at its read), and never Main (Main is a read target for a snapshot name alone,
`Main.helper`, the stated deviation: no unit can name a snapshot function to extend it otherwise, `import` being
refused and the snapshot's names imported by `using`; as a value a writer takes it is refused at the write). A registration is read, never run:
its group and labels literals, its function a lambda (a definition, checked as one) or a function the unit defines,
each argument lowered and stepped the same way to a value of Base's, handed to the judge's `_g` or `_xf`, a label
registered twice refused. The worlds: the judge's and the compiler's own code run at the judge's
world, taken before the snapshot loads; a snapshot label is compiled and answered at the world after the snapshot, a
unit's label at the world just after its unit loaded (`WasmTarget.compile(f, types; world)`, which infers the program
and reads its bindings there, the world its `NirWorld` carries to every binding read; `test/oracle.jl`'s
`answer_of(…; world)`, which calls the case at that world and reads its answer at the judge's, by structure). G5 runs
the same loader over a move's unit (`corpus_loader.jl --check`, as the deps user, no WasmTarget) for an early refusal
by name; every measurement's process loads by it again. What then holds rests on four premises: (a) the loader runs
each lowered statement itself, checked with its real operands, its reads by `_reader!` (so a load is a function of
its text, Julia's build and the snapshot, the digest its alarm) and its writes by `_writer!`; (b) the builtins on the list run no Julia code; (c) world age hides
every method defined after a world from code running in it; (d) the effect lattice and a method's `generator` and
`purity` are Julia's own record of what inference may run. Probed (loader/p2, a stand-in judge and snapshot, each
form alone in a unit of its own, a process each): 71 forms, 61 refused by name (e3's and e5's: Union and Vararg piracy, `convert(::Type{T}) where T<:_A`, a bare and a dotted method of the snapshot's `helper`, `struct Any`, methods of the `TypeVar` constructor and of `Core.Typeof`, `Core.kwftype` with a keyword; a `Core.Compiler` method; a method of the judge's `_started`; `Main._started = 1` and `setglobal!`; `getproperty(::Module, ::Symbol)` replaced; round 9b's shadows; v10's hazardous forms; typed bindings, a computed `const`, a type inside a vector), 10 loaded (the real additions since 2026-11-01 written as a unit, v10's honest forms but its typed bindings, round 9b's `@enum _WtJ _judged _started _g`, which now binds those names in its unit and leaves the judge's `_started` as it was, arithmetic and Union constants, `global x::IOBuffer`), and after every one the judge's names, `Any`, `String` and the snapshot's names as before; where the loader checked after a unit's last form only, `Core.Typeof`'s method ran at the next definition, the `TypeVar` method crashed Julia, the `getproperty` replacement overflowed the stack and the snapshot's `helper(1)` read 3. In the real processes: a unit's methods on `hash`, `show`, `==`, `fieldname`, `fieldcount` and `ismutabletype` of its own type, each writing a file, wrote nothing during a smoke of its cases, where the judge's code at the latest world ran its `ismutabletype` 8 times inside WasmTarget's compile; a unit's `hash(::Type{_T})` that rewrote its case's answer as it was read left the answer 7, where the reading at the latest world stored its lie, 99; G5 refused a move changing the snapshot and one adding two unit files, which the path rule before admitted.
**The premises of a true verdict** (spec v14 V0): every input a verdict is made of, read from the code paths, and the
one place that fixes it (a key field of KEY_FIELDS, a refusal at a named function, the door's command line, G5), its
alarm, its negative or probe, or the accepted risk (RISKS' letter). An input nothing fixes is named so.

| input | fixed by | alarm | negative / probe | risk |
|---|---|---|---|---|
| **(a) the stored native answer** | | | | |
| Julia's build | key `julia` (`measure_key`: a process of the measure role that loads no corpus) | OracleGap; preflight's `store_ready` | v14/drv v5 (resume under another key; preflight) | |
| the host | key `host` | OracleGap | | |
| the process's argv, environment and Julia options | ONE declaration, `ANSWER_PROCESS` (spec v16 X3): the door's command is built from it (`process`) and so is key `env` (`answer_key_env`: its argv and its whole environment, `door.base_env`'s with it); the process prints its `ARGS`, its sorted `ENV` and every field of `Base.JLOptions()` in its `loads` record, and `loads_checked` refuses any difference from the declaration (the environment `door.process_env` gives, the Julia options the key process's same argv gives), by name | OracleGap (a declaration edit); the answer refused, named | v16 X3 (a planted variable, a flag) | |
| the answer's band, the units' log, the labels' file | declared inputs of `ANSWER_PROCESS` (`WT_SMOKE_ANSWER_CAP`'s value in key `env`; `WT_SMOKE_UNITS` and `WT_SMOKE_ONLY` named slots: the log is `UNIT_LOG_ARGV`'s output at the commit, the file the one label) | the answer refused, named | | |
| the depots it reads | `JULIA_DEPOT_PATH` names exactly two, no trailing `:` (whose expansion Julia decides: probed, its two bundled depots, never the user's ~/.julia): its fresh depot and Julia's bundled `share/julia` (`bundled_depot`), whose compiled stdlib caches hold Base64's (SHA is in the sysimage); without it Base64 is compiled, which spawns Julia's lld, which the `native` profile does not execute (probed as `_wtm1`) | the answer refused, named (`loads_checked` reads the value) | v16 X3 | |
| its process's identity (cwd, pid, clock, an extra variable, HOME, USER and LOGNAME, the units' path; never the uid, one role running both) | two processes a label, the second varied (spec v16 X2, v17 Y4), each in its own profile | `noanswer`, "its answer depends on its process" | v16 X2 (dict order, objectid, rand, time_ns) | (a), (d) |
| the answering program's files | `core.JUDGE_WRITE`: key `judge`, G5, `loads_checked` | OracleGap; the answer refused, named | v14/drv v2 (a keeper's line, a loader edit, a planted include) | |
| Julia's stdlib (SHA, Base64) | `JULIA_LOAD_PATH=@stdlib`, Julia's install: key `julia` | | | |
| the snapshot's text | key `snapshot`; G5; `loads_checked` | OracleGap | | (c) |
| the unit's text | the index line's source and blob (`landed_labels`); G5 (written once); `loads_checked` | answered fresh | v14/drv v2 (an edit in place) | |
| other units | the judging directory holds the label's unit alone; `loads_checked` | | | |
| the units' order | `UNIT_LOG_ARGV`, one definition (test/corpus_loader.jl's, which the driver reads), `--no-renames` (a rename is a deletion and an addition, as G5 reads it) | the judge refuses another argv | | |
| what the load reads | `_reader!` (refused at the read); the callee table, `CALLEES` | the digest (`_ladder`) | the loader's negatives | (b) |
| what the digest can state | `_canon!` refuses a pointer, an unmade mutable, Main, a value past 48 levels | | negatives bf, bi, main_value | |
| lowering's process-global counters | `_canon!` (a TypeVar by its position); gensyms are per module | the digest | the two-process test | |
| the label's world | the unit's world (`u.world`); `answer_of(…; world)` | | | |
| what the body does when called | nothing: a case is its own claim | G4 | reviewer.md | (a), (d) |
| the answer's size | `answer_cap_bytes`; the drain's cap (`RECORD_MARGIN`) | noanswer; `case-over-cap` | v14/drv v4 | |
| the records' framing | `watched`'s plan; one wholeness rule in two readers | the case refused | `test/src/oracle_edge_blocks.tsv` | |
| **(b) the compiled module** | | | | |
| the measured commit's src | what is measured | | | |
| Julia and the toolchain | `door.tools` at launch; the commit's Manifest and deps images | | | |
| the compiling side's judge files | G5 (`JUDGE_READ`, `JUDGE_WRITE`: `test/smoke.jl`, `test/verdict.jl`'s `bind` and `plan`, `test/oracle_read.jl`'s `read_shapes`); the compile loads no `test/runner.jl` | | v16 X1 (a keeper's `Core.eval` into the judge's modules: no compile loads it) | |
| what the compile is handed of an answer | its shape alone (`shapes_of`, the measured commit's `Shape(a)`: no leaf's value); the answers written for the verdict after the compile and the run are reaped. A shape still holds an aggregate's structure: its leaves' paths give a Vector's length and a String's ncodeunits (an empty Vector or String answer is entirely in its shape), and a type answer's type (spec v17 Y4, red 8b) | | test/src/verdict.jl (one binding, a shape and an answer) | G4's: src reads the corpus's argument literals and an aggregate's structure in its shape (RISKS (f)) |
| the unit's load | the digest compared in `_ladder` | errored, located | the two-process test | |
| other units in the process | Julia's world filter (every lookup on the verdict path, dispatch, inference and WT's `_methods_by_ftype(…, world)`, reads methods by world, and a deleted method's world range is closed) and `load_units` called once a process (spec v16 X3: every deletion precedes every compile and answer); `_retire_foreign!`; `unreachable_without`; `_max_args_refusal` (no foreign method raises its function's `max_args`, which a deletion would not lower). The method table's entry count after a retire is no verdict input: no verdict-path lookup reads the raw table (its readers were `_runner_sealed`, deleted, and the negatives' count) | a second `load_units`, refused | the negatives' ua/ub pair (and its second call) and retire test; v14/v1's compile probe | |
| `Main.U_<slug>`, a unit's module's binding | read by no load (`_binding_read`); a body computing the name | G4 | | (d) |
| the compile world | `WasmTarget.compile(f, T; world)` at the label's world | | | |
| WasmTarget's per-process caches | Julia's own validity (`_analysis_holds`; the world memo); the constants' names (`C<id>`) a compile's own counter, never the process's (spec v16 X5: they were a process-global counter, so a module's bytes depended on what the process compiled before it) | | test/src/globals.jl; the 106 probes; v16 X5 | (b) |
| a constant's memory past what its owner defines (an Array's capacity tail and popped isbits bytes, a Dict's unfilled slots) | one rule, `_live_memory`, each owner one function (src/julia/classes.jl, spec v15 W3, spec v16 X5): an Array its size's elements from its ref's offset (`_array_live_memory`, `_array_live_ref`), a Dict the slots `isslotfilled` marks, a Set its Dict's, a Dict's `slots` every byte; the owners one table, `MEMORY_OWNERS` (spec v17 Y6), each pinned to Julia's definition; an isbits Memory reached through no owner (bare, through a MemoryRef, IOBuffer's `data`, any other field) refused, located (`_unowned_memory`), an empty one or a boxed one (#undef the null) held whole; the rest the null, the all-zero bits or a singleton's value; a Memory held both whole and in part, or by two Arrays of different sizes, refused, located | ProgramError, located | test/src/constants.jl; v16 X5 (two processes) | |
| Julia's global code cache across the labels one process compiles | inference's own validity; a label's module compiled first and last in a process of 50 labels (v16 X3's probe, after X5) | | v16 X3 | (b) |
| **(c) the comparison** | | | | |
| node, and Julia, at a launch | pinned by `door.tools` at a launch (spec v16 X4, v17 Y1): node, nodejs.org's official build of ci.yml's major, its version and sha256 declared in `door.NODE_PIN` and nowhere else, installed under TOP/tools by `door.py tools --fetch-node` (a launch step Dale runs once a version: a download to a temp file, the sha256 checked, a mismatch refused) and taken by `pin_node` only when its recorded sha256 is the declared one, its major ci.yml's and its binary self-contained (`otool -L`: /usr/lib and /System alone; probed: an altered sha256 refused, v26.11.0 links CoreFoundation, Security, libc++ and libSystem), any other node refused, named, first on every build user's PATH and so the one node `node_binary` takes (NODE_MIN_MAJOR); Julia, the juliaup install of exactly the climb Manifest's `julia_version` for this host's architecture (`julia_install`; none installed: the launch refused, named; never juliaup's default channel); each version recorded once a launch from what was pinned (`tool_versions`: Julia's build, node's version from the copy's own node_version.h, tools.json and a `tools` event) and in each score's `scored` event; a gate compares base and candidate under one launch's tools | a tool change is in every row's judge key (`judge_id` hashes tools.json, spec v18 P4): its lost passes are the one rebase rule's, `score-rebased`, one note, no G2, at a score, a gate and the lander's rebased check alike; the base cache is keyed by (sha, judge_id) | v15/w2 (a faked node change); v16 X4 (a faked newer node on PATH after the pin; a Manifest naming an uninstalled Julia) | |
| what the run process can reach | its own directory (RUN_FILES and the composed calls, copied in by the driver), Julia's install, TOP/tools, RUN_READS and its own log (`part_log`: Julia under a profile that cannot read its stdout's file writes nothing to it, probed as `_wtm1`, so until v17 the verdict's own log, its fixture failure among it, was always empty), by the `native` allowlist profile; it executes what TOP/tools holds (Julia, node, and the door's homeacl, nobootstrap and ps) and /bin/sh and /bin/bash alone (spec v18 P6) (spec v17 Y1) | | v17 Y1 (as `_wtm1`: the tree, TOP/in, landimg, deps and the store refused, Homebrew's node refused; HEAD's `julia` kind read and ran them) | |
| the runner's run of a module | `test/runner.jl`, the judge's (G5, spec v18 P2), handed modules, calls and wire arguments alone; one fresh instance a call; a budget a call (spec v18 P3): node killed when a call gives no line within `RUN_BUDGET` (`NODE_START` more for a node's first), that call a hang, named, and a new node running the calls after it, so a hanging module costs its own call alone, never a fixture or a later case (red's round-15 p8: one hang first among the 126 cases is one errored row, where HEAD lost every line and read the run as the infrastructure's); floats as integer bits both ways (a wasm wrapper) | the judge's fixtures (`test/fixtures`, G5), interleaved by `run_input` at positions drawn each run, every label drawn, patched copies of `runner_patch.wat` with drawn constants, a trap and a throw among them: one not bit-exact fails the part, named, as the runner's, and so does a run that writes no line; while every file the run and its judgement read is origin's (`run_files_are_origins`), either is the infrastructure's (`run_part_failed`: `RunFailed`, a MeasureCut, `run-failed`, one note, no move charged, no stop; probed as `_wtm1` with no pinned node: the run wrote no line, which HEAD charged to the move). The run process's PATH is TOP/tools/bin alone (a PATH entry its profile refuses failed Julia's own `Sys.which`, EPERM) | test/src/runner.jl; test/src/verdict.jl (a passed-shaped, a quieting and an instance-sharing runner refused) | |
| the wire's grammar and leaf kinds | `test/verdict.jl` (G5): `read_raw`, `LEAF_TYPES`; a new leaf kind the judge's edit | a line no raw result reads: that case errored, named; an answer or argument of no leaf kind: `judge-gap` (spec v17 Y2) | test/src/verdict.jl | |
| the stored answer's decoding | `test/oracle_read.jl` (G5), loaded by the verdict by its owner | | test/src/oracle_read.jl | |
| the compare | `test/verdict.jl` (G5) alone: `_matches`, bits at native's leaf kind; the verdict process loads no `test/runner.jl`. A scalar answer that is a type is read in wasm by a reader the judge builds (spec v17 Y2; precedent dart's Expect.throws<T> and `is T`): a throw by `Catches` (`try _widened(); @noinline(F(a...)); 0 catch e; e isa T ? 1 : 2 end`, its leaf must be 1, the own modules a wasm exception; `_widened` may throw a value inference knows only as `Any`, behind a guard it cannot decide, so `the_exception` is `Any` and the one `isa` the module runs is T's, on the object F's own body threw across a real call (spec v20 F1: proved by the reader's IR run with F's throw replaced, and by WasmTarget's module with the thrown class rewritten, test/src/verdict.jl and test/src/runner.jl); a throw answer is read by its type alone: two exceptions of one type and different messages read alike), a singleton by `IsA` (`Core.compilerbarrier(:type, @noinline(F(a...))) isa T`, true, the own modules any result without a trap: `void` alone matches no answer; RISKS (h)); the shape names the type (`shape_lines`' last field). A reader's singleton leaf is typeasserted to that type, so its `void` is exact. One `judge` for the driver's verdict process and for standalone `test/smoke.jl`, which records its compiles as the compiling process does | | test/src/verdict.jl; v16 X1 (red's p1, the architect's p1 and p3); v17 Y2 (council/v17-report.md) | |
| **(d) what a score records** | | | | |
| the labels measured | the corpus's registrations (`corpus_labels`); a row for every label or none; a group or case name outside [A-Za-z0-9_./-] refused at its registration, located (`_label_refusal`, spec v17 Y4, red 8c: every record of a label is tab- and line-framed) | score-failed; the unit refused | test/src/corpus_loader_negatives.jl (label_tab, label_group) | |
| a row's provenance | each row names the stored answer it was judged against (its block's hash, `noanswer:` before a stored noanswer) and the judge's key (`judge_id`: the answering program's and the verdict's files, and the launch's tools.json: Julia's build, node's version and sha256), `Row.prov`, kept in the cases files and the table (spec v17 Y4); G2 counts a pass lost only between two rows of the same answer and judge, never a stored noanswer (`same_judgement`: `losses`, `regressions`, `confirmed`) | any other lost pass is a rebase: `score-rebased`, one note naming the labels, the table takes the rows, no G2 | v17 Y4 (council/v17-report.md: a replay turning a pass noanswer and a judge change, no G2; HEAD filed a fix-first no move could fix) | |
| a gap | one gap rule: OracleGap, `score-failed`, nothing recorded | one note | v14/drv v5 (gapscore) | (e) |
| a cut, a power loss (the power rule stops work: core.power_works) | MeasureCut; PowerCut | score-failed; power-wait | | |
| a driver-booked `noanswer` (a kill, a failed process, refused records) | never stored (`Booked`, refused by `oracle_write`, spec v16 X3): the label keeps no index line, the next lander start answers it again (`oracle_unanswered`), and until then each measurement's gap is that label's, located | the label errored, named | | |
| **(e) what a landing's check proves** | | | | |
| a test file's verdict (passed / failed) | test/src_tests.jl's record path (`_wt_red`: Test.get_test_counts over the file's testset, nested included), written by the process that ran the file; the judge's canary (test/src_canary.jl, G5) run last in every process through the same path, one testset that must read failed and one that must read passed; the process's exit status, which must agree with its rows; after EACH file F the canary's two tests run again AS F (F's name, F's testset path), their result F's row's sixth field, a wrong one voiding the process (spec v17 Z4); every test process runs in a tree without history (`git archive` of the commit, its parent's test/ beside it as WT_BASE_TREE), and a located culprit stands only when its file runs green at the culprit's parent | dev/check.sh red (`the shards' records are void`); the score's `src-void` | the architect's p6 (a file overriding Test.get_test_counts), lc's switch probe; red's round-14 p1 (a change keyed on a later file's name: void at that file), a test red by `git log` and one red by the date (flaky, never a culprit); two STOPGAPS by their kind, L228's reach checks (parsed src and test files: no Test internal, eval elsewhere, exit, record variable, .wtd, git, clock or date; an exact allowlist) | NOT fixed by construction, said plainly (round 13's S6, spec v17 Z4): a test file and the src it tests run in the process that records it, so they can change the harness for every file after it; the exit status, the canary at the end and the canary as each file catch a change that lasts to any of them, keyed on a file's name included; a TARGETED change that tells the canary from a real test some other way (its source file, its expressions) and lasts, or one that names the harness through a name built at run time, is caught only by G4 reading the move's diff (reviewer.md; RISKS (g)). One process per file was measured, not built: about 57 s a file, the score's src part about 3,570 s against 284-341 s, 11-12 times, and every landing's share as many times over |
| a test file's cost | the score's src part alone (the judge's harness at origin's code); a restarted process's first file unmeasured | | lc's O7 probe | a file can append to its own costs: costs order the shards and size the share, never decide membership |
| which tests a landing ran | the lander's set (`src_set`, `src_handed`, from origin's code and state: the move's own and its hold's located reds, the files the score did not read passed, the flaky known reds, the carried files and the ring's window, cut to D14's band less the measured margin and to no more G than the largest set that margin was measured on plus one file, the `gmax` bound), or no landing at all: with no score's record at origin's head nothing lands or climbs (`admits`), and a set that cannot be made leaves the item waiting with one note, never a check of every file (spec v18 Q2); handed by the door's run directory (`door.landing`), refused by dev/check.sh when its user can write it or it names another HEAD; the files run kept in the `ship` event and `src-green.json` | `src-unverified` (the lander holds) | L228; lc's scratch landings | the files outside the set run at the score |
| a red located to its landing | the score's src part (`src_score`), a red in a check outside the move's own run at origin's head (`src_red_at`), both located by `src_locate` (one process a step) to a fix-first | `fixfirst-age` (the lander lands fix-first alone) | lc's probes p1 and (b), (d) | a red stands until the next score finds it |

A unit's cases join an existing group or a new one; a new group's move adds its row to `test/smoke_times.tsv` (its
seconds on 1.12 and 1.13, a G5 `add`), since L153 holds that file to exactly the groups `registered` reads from the
snapshot and the units, and a smoke part (`WT_SMOKE_PART`) deals every group by its row, a group with none an error.
A climber writes in a unit what the loader admits (`climber.md`: for each refused form, what to write instead); a unit's body is judge code all the same, which `reviewer.md` judges: its loading is the loader's, its behaviour when its case runs the reviewer's.

G4 is the one gate a model judges, so it is measured like the score (Theo's eval of past failures):
`climb.py judge-eval` reverts small landed fixes of audit findings (at most `judge_lines` changed lines), each a
defect an audit really found, and asks the reviewer to refuse each revert, blind, in the form every round of the gate
has (`core.review`, A7-10): a neutral message, a fresh review (never an earlier round's findings), and what the
author states (a move's commit message and its answers to an earlier review; for a defect, a climber's stock claim)
given in the job as claims to check, never evidence; so the recall measured is the gate's as it gates: each case is reviewed in a
repository of its own, the tree before and one change with neutral messages, no other ref, dev/AUDIT.md and
dev/MARCH.md blanked, and origin's `dev/climb/` in both trees so the reviewer reads this file. Beside them it
reviews the climb's landed moves that a later audit passed, which it should approve, since recall alone cannot
tell a judge from one that refuses everything. The defect set (`judge_n`) only grows; a defect the reviewer
approves is reviewed once more before it counts; an empty review is left out, never a miss; each case's verdict is
kept by the judge and the case, so an eval the budget cut resumes where it stopped (A8), and a score tick runs at
most `judge_per_tick` of its reviews, the second review of a defect it approved counted too, the next tick resuming
(A6-8; probed with stubbed reviews: ten defects in ticks of 4, 4 and 2, where it ran all ten in one; and ten defects
each approved once ran 4 reviews a tick in five ticks, where HEAD ran 8 in a tick). The judge is
`reviewer.md` and this file's gates and refusals, hashed together: a change to the landing, the door or the
numbers here forces no eval (O7). While the judge differs from the one measured, or no eval exists, or it refused
under `judge_recall`, the climb does not idle (K4): every move needs two independent blind approvals, the second
reviewer told nothing of the first and run as the other slot's review user, which cannot read the first's home, with one note for Dale each time that state begins; an item needs the approvals
that held when it was approved (the lander runs no agent, item 11); the score tick runs the eval when it is stale,
and one reviewer suffices again when it passes; never a pause. Under
`judge_approval` of the clean moves approved, a note for Dale. A fix-first move's reviewer is given its finding
and confirms it resolved, and every reviewer is shown the test/src lines a move removes, as refusal-4 candidates.

The driver re-runs every gate after every change a move makes, including a review's fix. A move whose landing
check goes red on its own goes back to its hold as a stop: the next move starts fresh and passes every gate again.

## The door

**Dale's uid never executes anything an agent or a candidate wrote, and never runs an interpreting tool in a tree
they wrote: it moves data through one door** (`dev/climb/door.py`; precedent: Nix's build users). Every process that
loads repository code or acts on a model's output runs as a macOS build user that `dev/climb/setup-users.sh` made
(D-E): a slot's climber and its own Kaimon (`_wtk1`, `_wtk2`), a slot's reviewer and ruler (`_wtr1`, `_wtr2`), the
judge's eval and the audits (`_wtr3`), the measurements (`_wtm1`) and the score (`_wtm2`), the landing's check and
packages regeneration (`_wtland`), the dependency images (`_wtdep`). A build user has no login, no password, no
path into Dale's home (one ACE Dale's uid sets on it: list and search denied to the group), the climb's state or the
main repository, and no right to signal Dale's processes; it reads what the door mirrors under
`/Users/Shared/wt-climb` (Julia's install, the General registry's packages, the artifacts, the pinned checkouts and
the agents' `claude`, each an APFS clone keyed by version), refreshed at launch alone (`door.tools`), a landing's job
refreshing the pinned checkouts alone; each package version is mirrored by its slug, and a registry or global
environment whose hash differs is made again (O6-5; probed on scratch depots: a second version's slug, a newer
General and a changed environment reached the mirror, where the old per-name copy kept none of them). The agents' `claude` is chosen at launch: launch's preflight copies Dale's and
records its name in the state (`door.pin_claude`), every agent runs the recorded one (`door.claude_bin`), so an update
of Dale's changes nothing until the next launch, and the copy launched and the one before it are kept, no older one. The driver's own programs are a closed set
(`core.program`: git, the machine's readers, sudo, the notifier, and bash for origin's ship.sh alone), taken as argv
lists alone, a pipe as two processes, never a shell string (A6-11; probed: HEAD's scan of a string ran a `$(...)` as
Dale); a Julia, node or claude run as Dale raises at its line. One more process runs as Dale on origin's code: git's
merge driver for src/julia/packages.jl, which the lander's `git merge-tree` starts as `bash <state>/merge_packages.sh`,
origin's `dev/merge_packages.sh` written from git (`measure.rebased`, A8-8). Every subprocess of the driver's modules (core,
measure, lander, slots, climb) goes through `program()` (`core.sh`, `core.piped`, and the lander's Popen of ship.sh;
A7-8); `door.py`'s own calls (sudo, ps, sysctl, chmod, cp, the compiler of its two helpers, git as plumbing) are the
door's, run as Dale on paths no build user writes.

- **The repository's owner** (spec v18 P5, after a probe run from a worktree of the real repository destroyed its landing log): `COMMON/wt-climb-state` names the one state that owns the repository's logs and refs, written by `climb.py claim-repo` alone: by the repository's default state, or an overridden state in a clone's own .git (spec v19 P4), refused while the marker names another state that exists, and by an overridden state whenever it names another state at all (spec v20 F5: only the default state re-claims from an owner that is gone), or names none while the default state's directory exists (spec v20 G3). Every driver write under COMMON goes through `core.common_write` / `common_path(…, write=True)` and is refused, located, unless the marker names the running state: the lander's ship.sh (a landing appends wt-landings.tsv and pushes), a fetch of origin, a ready branch, a slot's bundle ref, the lander's and the regen worktrees. A scratch harness claims its own clone, never a worktree of the real repository (probed in a clone claimed by another state: the landing log's write, an enqueue's ready branch and a second claim each refused, where HEAD wrote both). The lead claims the real repository at launch.
- **In**: `give()` makes a run directory readable by its one user (an ACL), holding plain files and, with `repo()`, a
  bare repository of exactly the commits the run may see: origin's history for a slot, the measure and score users
  and the landing; two commits of their own (the tree before and the change, made by plumbing) for a reviewer, so
  no other ref or history is there to read: origin's history lives in `cache.git`, mode 700, its ACL (the slots,
  measure, score, land and deps) its only grant (`repo()` keeps it so; door-probe reads it as every user: probed, a
  review user's read of it failed, where at mode 755 it counted 3694 commits, R6-4). The user clones it into its home itself. A run directory goes when its
  role's `using()` ends, an exception's included, and `give()` refuses a role not in use (probed: `in/` as before
  after a run and after a run that raised); a run directory never outlives its use (spec v17 Y1): `using()`, holding
  the role's lock, removes every `in/<role>.*` on entry, and `give()` writes its files 0600 and its directories 0700
  (the ACL their one grant; probed: a driver SIGKILLed with a run directory given, its answers file in it, left it,
  and the next use of the role removed it before it began, where HEAD's next use left it and wrote its files 0644). A role's home keeps nothing between its uses (`door.KEEPS`; a slot keeps no Kaimon depot or config, which one move's agent could
  write for the next move's server to load, A7-9: Kaimon runs on the deps user's images, and a move's start costs the
  same as before, probed as `_wtk1` twice: Kaimon answered in 41 and 42 s and wrote nothing of its own, and the session
  loaded WasmTarget in 174 s both times, the clone's own depot, made by every move before too): `using()` removes
  everything else as the user on entry and prepares it, each entry's flags, ACLs and modes cleared first (its owner
  can make an rm fail) and the home's own mode (700) and ACL (Dale's read, set by `homeacl`: a run has no bootstrap, so
  `chmod +a` cannot name Dale) made again, and a measurement reads the status of its directory's removal (R7-5;
  probed as `_wtk2`: an immutable file in an append-only, deny-ACE, mode-500 directory and a home made 755 with no ACL
  were gone at the next use, where HEAD refused that use and every later one; each pass restores traversal before it
  clears flags, R8-4, and the passes repeat while each changes the tree (its listing with modes, flags and ACLs), never
  to a fixed count, R9-2: probed as `_wtk2`, a nest planted in the agent profile 64 directories deep, each immutable
  and of mode 000, was gone at the next use, where 16 passes refused four uses before they healed; a door-probe row
  plants it), and every role's git reads no global config
  (`GIT_CONFIG_GLOBAL=/dev/null`); probed: a planted `~/.gitconfig`, `~/.zshrc` and `claude/projects/*.jsonl` of a
  review user were gone at its next review, and without the clean they stayed and git read the planted config.
- **Run**: `sudo -n -u <user> env -i <explicit environment> nobootstrap`, at background QoS (at default: a landing's
  check, the oracle's answering processes while `oracle_background` is false, and the parts of a slot's or the lander's
  measurement while `measure_background` is false, one single-threaded process on a performance core, never beside a
  check), every file it writes capped at `file_cap_bytes` (RLIMIT_FSIZE on the door's line, so a run that prints
  in a loop cannot fill the disk Dale's work shares through a log of his: A6-5; probed as `_wtm1`, a 4200-MB write
  stopped at 4096 MB with SIGXFSZ, where it was written whole before), and a run's total writes bounded while it runs:
  every wait on a build user's run (`door.wait`, a measurement's watch, a land job's) takes one tick, `door.tick`, the
  disk, the power and the role's awake wall in one place (A8-8; a land job's wall is the role's awake time, no longer
  the raw clock), and reaps the role under `disk_free_gb` (the climb pausing with one note), and a land job copies back at most
  `land_outs` (R7-6; probed as `_wtm1`: a run and a watched process were reaped 5 s after the floor passed them, where
  HEAD's run went on to its end; 40 outputs of 8 MB copied back as 16, 128 MB). A quota volume for the homes (APFS
  `addVolume -quota`, root at setup) would bound them by construction: the owner's option, not built. Every run names
  its profile, a required argument (`door.argv`; A8-8: a call with none is a TypeError at its line; HEAD had 18 calls
  that omitted it): a profile file, or `door.NONE` for the door's own fixed commands alone, which run with no seatbelt
  (as their user, with no bootstrap): a home's clean and a path's wipe, a file put, a home's prepare, a measurement's
  and a job's directory made and its tree copied (`rm`, `mkdir`, `cp -Rc`, the kinds' copy), preflight's `true`, and
  door-probe's tries of the user boundary itself. Every other process runs inside a `(deny default)`
  seatbelt: `julia` (writes its own directory, never a `.git`,
  no network, no Mach lookup), `check` (the same, its clone's `.git` writable), `kaimon` (TCP on the slot's own port
  of localhost alone) or `agent` (`claude` and its tools: writes its home, connects to localhost's model proxy and
  its slot's Kaimon port alone, no Mach lookup). Probed: sudo keeps Dale's Mach bootstrap, and through it a build
  user with no profile submitted a job that ran as Dale, set his launchd environment, disabled and killed his jobs,
  drove Finder, launched an app and read his clipboard; a profile refuses most of that, but launchd answers print,
  getenv and disable without asking it, so `nobootstrap` (dev/climb/nobootstrap.c) starts every run, a slot's
  Kaimon and its sessions among them, with no bootstrap port; from inside a session `launchctl print` and `disable`
  of Dale's job are refused (probed). Claude Code's own sandbox is off: on this macOS no sandbox starts inside a profile
  that denies anything. The agent's only road out is `door.proxy()`, the driver's, its `ANTHROPIC_BASE_URL`: it
  admits the calls `claude -p` makes (`POST /v1/messages`) naming the run's own `--model` (`core.run_models`: observed
  through the proxy, claude-2.1.322 calls no other model, no small one; R10) and refuses any other with a 403, listed
  in the run's record; it adds the agents' token, which no build user's process holds (D-F; the agent's credential is
  a placeholder), forwards over verified TLS to api.anthropic.com, books each answer's `usage` at once in the
  governor's one spend source (in a `finally`, with its `admitted` row: a deadline cut, an idle timeout or a reset
  loses nothing the answer already carried, A8-3; probed with the architect's fake upstream: 100,000 input and 50,000
  cache-write tokens booked on a cut, a cut amid pings and a reset, where HEAD booked none; a cut now shuts the
  upstream's own socket, which http.client drops once it reads a closing response, so a pinging answer no longer
  reads on past its deadline), and asks the governor before each call, refusing every call once the week's half is
  spent by all the runs alive (R11; the day's allowance gates a move's start alone, O7-4), or once the run's own dollars pass its `--max-budget-usd`: its
  usage priced as the API bills an answer, each kind of token at the model's price (`price_usd`: input, output, a
  5-minute and a 1-hour cache write, a cache read; never the governor's weights); every run's dollars are compared
  with claude's own `total_cost_usd`, a ratio outside `price_band` a note (probed: eleven runs of Haiku, Opus, Sonnet
  and Fable read 1.0000, where the governor's weights read 1.37 to 1.57; a wrong price in a scratch state read 0.50
  and wrote the note). It admits only what the run's claude
  sends: top-level keys of an allowlist alone (`door.BODY_KEYS`, the ten keys observed through the proxy on the
  climber's argv on Opus at efforts high and low and on the climber's, reviewer's and auditor's on Haiku, R8-6; probed:
  `service_tier` and `speed` refused, where HEAD passed both; a door-probe row), so no `mcp_servers`, `container`,
  service tier or speed, no server tool (a `tools` entry with a `type`), content blocks of an
  allowlist alone (`door.BLOCKS`, each `source` base64, a tool_result's content read the same way: observed through the
  proxy on the climber's, reviewer's and auditor's argv, claude-2.1.322, each reading a PNG and a PDF; R7-3; probed: an
  image or a document sourced by url, top-level or in a tool_result, is a 403, where HEAD forwarded both), no body
  with a key twice,
  and at most `proxy_in_flight` calls at once (observed: claude -p opens one; a 429 past it, which claude retries);
  every usage value of an answer is booked (R6-6; probed with no token: each such body a 403, where the proxy
  before forwarded each). It cannot hold a run or swell the driver (R6-5): a body past `proxy_body_bytes` is a 413,
  unread, and one with no decimal Content-Length or any Transfer-Encoding a 400 (411 with no length), unread, its
  read never past the cap (R7-2; door-probe rows; probed: a 600-MB stream with Content-Length -1 answered 400 at once,
  the driver +9 MB, where HEAD read it whole, +1316 MB); a call's one deadline is `proxy_request_s` of its role's awake time, so a landing's stop never cuts an
  agent's call (none is paid twice) and no write times out; leaving a run waits `proxy_join_s` for calls still
  answering, then shuts them; a reviewer's, ruler's or auditor's user is reaped before its proxy is left, and a
  slot's is stopped by its move (probed with the red team's clients: a 600-MB body 413 with the driver +9 MB, where
  it grew 762 MB; a trickling client let the run go in 30.1 s, where it held it 115 s). An agent's Bash writes no stream the driver reads: its stdout and
  stderr are a file of `claude`'s, not `claude`'s own pipes (probed with `lsof`, R13). A 401 or 403 the API answers
  a run's call is the token's, never the run's (O6-8): one note for Dale ("the agents' token is refused: run `claude
  setup-token`") and no agent runs until the token file is written again; launch's preflight makes one max_tokens:1
  call with the token through a proxy (Claude Code's system line, which the API requires of a subscription token) and
  refuses the launch on any answer but 200 (probed: with a bogus token a `claude` run as `_wtr1` read 401, one note,
  and the next run was not started; HEAD ran it again, no note; the real token's call answered 200).
- **Out**: `take()` reads a file of a user's home after its processes are stopped or reaped, every path component
  opened without following a link and without waiting (a FIFO's open waits for a writer a reaped user never brings,
  R6-1), and a file refused before a byte is read unless it is regular, under a cap (`cases_cap_bytes` for a
  measurement's cases; a judging process's records, half a GB for a full score, come through its stdout, a pipe the
  driver drains into a file of its own under `file_cap_bytes`, `drain`, never whole in the driver's memory, A7-6,
  R8-1). The test set a landing's check runs and the costs that order its
  shards are the lander's, from origin's code and state (`hand_set`), given by the door to the land job's run directory,
  which its user reads and cannot write (`door.landing`; dev/check.sh refuses a set its own user can write or one made for
  another HEAD); no landing writes a cost (R6: the table each landing's own processes rewrote is deleted). It and its kin are the only
  opens of a path a build user can write: `list_home()` (a land job's outputs) and `copy_home()` (the dependency and
  Kaimon images, copied while the deps user's run still holds the role and is reaped, each file cloned from the
  descriptor so opened; a link or any other entry refused). A non-regular output is the run's own fault, located. A climber's commit comes back as a git bundle,
  fetched into the main repository with fsck on: exactly one commit on its base, or the move is refused;
  uncommitted work is not kept. `reap()` kills every process of a user (`kill -1` as that user) until `ps` finds
  none, before and after every use (`using()`, one driver process a role at a time, whatever state it serves: the
  role's lock is in `TOP/locks` beside the user it guards, so a scratch state's probe waits for the real climb's use
  and never reaps or cleans it, O7-2; probed: a scratch use waited out the real one's 4 s, where HEAD entered at once).
  Every lock on a resource every state shares lives there (`door.lock_fd`, O8-2, A8-6, R8-2): the roles', the landing
  window's and its record's, the two measurement locks and the lander's marks on them, the dependency images' and the
  agent probe's; the directory is mode 700 and each file 600 (the door's own makedirs, and setup-users.sh), so no
  build user can open one, and so none can flock it (a door-probe row as every user; probed: a slot's agent held
  review3's lock and every use of it waited past its limit, where now its open fails and review3 stays free; and a
  scratch state's measurement held the real lander off for 5 s, where HEAD's lander took both locks at once beside
  it). `preflight` and `door.py tools`, which change TOP, take every role's lock at once, refuse while any is in
  use, and hold them all until they return, so no role is taken meanwhile (`door.hold_roles`, A9-5). A killed
  driver's orphan, a build user's process whose role's lock no process holds, is reaped at a launch (preflight, every
  role held), at a resume (`launch.sh resume`) and by the heartbeat each minute (`climb.py reap-orphans`;
  `door.reap_orphans` takes each free role's lock without waiting, so a role in use is never touched), one
  `orphan-reaped` event naming the role and the pids (spec v14 V6; probed with `_wtm2`). A note for Dale is written
  under the state lock and sent after it is released, osascript within `step_wall_s`, its failure an event
  (`core.for_dale`, the one place; probed: the power note was sent with the lock held and no timeout before). Preflight also
  removes the lock files older drivers kept elsewhere, which nothing reads (the state's `.julia-*`, `.role-*`,
  `.deps` and `.agent-probe` locks of v8, the `stops-*.json` beside TOP's locks of v7b, A9-4).
  Launch removes only the run directories under `in/` whose role no process uses (each is named `<role>.<run>`;
  probed: HEAD's removed a live use's); only the real state's launch prunes older claude copies (probed: HEAD's
  scratch pin deleted the real climb's claude and every move then failed closed), and older node and Julia copies:
  TOP/tools keeps the launch's node and Julia and the one before (`door.prune_tools`, the state's tools-pins.json,
  spec v17 Y6; probed in a scratch TOP: a scratch launch removed nothing, the real one kept 26.11.0 and 25.1.0).
- **Measurements**: three roles as the measure user (or the score user), each in its own profile and directory,
  reaped between them (The gates, above). The dependency images are built by the deps user from a Manifest's
  registry packages alone (Pkg, offline); a resolve the climb's Manifest needs runs there too. The climb's Manifest
  is the driver's own: launch copies the main tree's into the state (`env/Manifest.toml`) with the hash of origin's
  Project.toml it was copied for, and the driver reads that copy alone, never Dale's working file; when origin's
  Project.toml is no longer that one, the climb pauses with one note for Dale (O6-5; probed in a scratch state: the
  resolve's input followed a line planted in the copy, and a changed hash paused with one note over two calls).
- **Kaimon**: each slot runs its own `kaimon --headless` as its user on its own port (`kaimon_port`), its config and
  cache in that user's home, strict with a key made for the move (the climber's in an MCP config file in its own
  home, never an argv), its one project the slot's clone, started with the move and reaped with it: no session
  of the climb's reaches Dale's Kaimon, and Dale's `projects.json` is never written. Kaimon's own images are built
  once per their Manifests by the deps user with localhost open (HTTP.jl and ZMQ bind ephemeral ports while they
  precompile: registry code, no repository code), KaimonGate in the very load stack a session of the base uses
  (an image is valid for the stack it was built in), and read beneath each slot's depot.
- **The landing**: under `WT_CLIMB_DRIVER`, origin's `dev/ship.sh` fetches the pins with origin's
  `dev/fetch_julia.sh` (Julia's and utf8proc's, the pin derived from it; the land job mirrors those alone, so a landing starts no build user's process but the
  landing's: probed by sampling `ps` through a land job, against the old refresh that started five other users'),
  and runs the check (`door.py land-check`; a climb landing regenerates nothing there, A7-5) as `_wtland` in its
  own clone, depot and caches, the depot a fresh one every land job (A8-1: `_wtland` keeps nothing, so one
  candidate's check plants nothing in the next's; probed: a pkgimage one land job planted in its first depot was in
  the next one's under HEAD, gone now) over a warm layer of origin's own images (`door.land_layer`: the project's
  path packages, test/DartCorpus and dev/SkeletonImage compiled from origin's landed head by `_wtland` in its clone,
  the path every check's clone has, since Julia accepts a path package's image only for the package at the path it
  was built from; made by the lander right after each landing, of the head it made, under its verify lock alone, so
  the next landing's check finds it and builds nothing on its critical path with both measurement locks held (round 9's
  architect; probed with the real `land_round` and `land()`, two landings: each layer built after its landing holding
  verify alone, where HEAD built each before its check holding score and verify; one is built before a check only when
  no landing made it since launch), once per origin head and Manifest, copied under `TOP/landimg`, which no build user writes; the one before it is kept, older ones removed),
  so a change outside src/ loads origin's images and one inside pays WasmTarget's precompile in the judged load as
  before (measured on AC, a test/src change on climb-prep's head: the layer made in 189 s, 49 MB; the check green,
  134 s on the critical path, load 0, ratchet 81, 151 s wall, against v8's warm-depot check of the same shape, load 0,
  ratchet 81, 148 s at the older rates); their printed output to a log of the
  scratch and their outputs copied back, their exit status the job's (75 when the door itself failed); it parses
  nothing as Dale, and asks the line stop and the hold again before each push. The push is Dale's. D40's progress
  row a climb landing writes (ship.sh's landed hook, the common dir's wt-progress.tsv) is read from the check's
  ratchet output, which the landing user wrote running the landed commit's src: no process that runs none of it can
  count it (dev/src_progress.sh loads WasmTarget to read its kinds), so that row's source is the check, G3's trust
  (R6-11).
- **Probes**: `climb.py door-probe` (every launch, no tokens): as each user a write into the state and the main
  `.git`, a read of `~/.ssh`, `~/Documents`, Dale's home and `~/.gitconfig` and another user's home, `kill -0` of
  the driver and a crontab each fail; inside the `julia` profile a connect to 127.0.0.1:2828 and outside, `open`,
  an AppleEvent and `launchctl submit` (each would run a command as Dale) fail while Julia runs; `reap()` leaves nothing after a setsid child that
  ignores TERM and a detached node child; `take()` of a FIFO, a socket and a directory a build user planted each
  raises within a second (with the old blocking open, the FIFO's row fails; probed); inside the `agent` profile its proxy refuses a call off its list and a model
  not its run's (403) and forwards its run's (no token: the API's 401); no build user reads a variable Dale set in
  his launchd environment (`launchctl getenv` answers 0 and nothing with no bootstrap, so its value is the test); the
  `native` profile runs Julia and refuses node, any other program and a read off its allowlist (R7-1, R8-1); `clean()` removes an
  entry its user made immutable, append-only, denied and unwritable (R7-5); the agent's proxy refuses an image sourced by
  url, top-level and in a tool_result (R7-3), and a negative length, a chunked body and no length within a second,
  unread (R7-2); each build user's flock of a role's lock fails, since it cannot open one (R8-2); `clean()` removes an
  immutable file under directories each immutable and of mode 000 (R8-4); the proxy refuses a top-level key off its
  list (R8-6); `clean()` removes, in one use, a nest 64 deep of immutable directories of mode 000 (R9-2; with the old
  16-pass WIPE the row failed and three more uses were refused). 234 rows held on 2026-11-10 (v10), each new one shown
  failing on HEAD or the profile it replaces.
  `climb.py agent-probe` (per claude the launch chose, `agent_probe_usd` a run; R12) shows only what needs a model, each judged
  from what the driver holds, never the agent's word or its transcript: it answered (its proxy's admitted calls), its
  Bash, Edit and Write ran (the tools `claude` sent its proxy as run, and the files each made, in its commit), it
  committed (its bundle), it reached its slot's Kaimon and `ex` answered 2 (the driver reads the global back from the
  session), and Julia loaded WasmTarget in its clone (Julia's hash of a fresh word, computed again by the session); its
  clone loads WasmTarget first, so a new claude's probe passes cold. No slot starts a move until it passed; the lander
  never waits on it. It runs as the asking slot's user, one at a time under a lock of its own (read again once held:
  probed, two slots asking at once ran one probe), and one that failed runs again on its backoff, at most
  `agent_probe_runs` runs a claude version, Dale told after the last (O6-3). Its record carries a hash of what the
  probe is (`slots.probe_blob`: agent_probe's source, the calls and the body rule its proxy admits, the agent
  profile's text), and the gate compares it, so a record of another probe never passes (A7-3; probed on a copy of the
  real state's v6 record: refused and the probe run again, where HEAD passed it on the claude version alone).
- **What rests on something else** (RISKS): what the oracle (above) and the corpus loader close, and what they leave.
  Closed by the store, the native role and the block rules: a line landed later changes no landed label's answer (no
  process that loads a corpus computes one; each is read from the store under its key, a gap or a mismatch a located
  failure), the compiling process calls no case's function (R2), and a compile record or an answer record is kept
  only in its own case's block (R3, R8-1). Closed by the loader and the pinned worlds (the corpus, above): no form a
  move adds runs code as it loads; a unit's load reads only what every process holds alike (`_reader!`), so the
  program answered is the program compiled, and the digest checks it (a difference errors the label, located); a
  unit's methods reach no label landed before it (its compile and its answer at its
  own world), and no judge's or compiler's code (at the judge's world), so an earlier-landed line aimed at a later
  case reaches it only through what that case's own program calls; and a case's body inferred in the compiling process
  sees no unit landed after its own. Left: (a) **a body's behaviour in its own answer processes**: a case's function,
  and what it calls, runs when that case is answered (at its landing; a replay or the audit at its commit), in two
  processes that share only the environment the key fixes (Julia's build, the host, `ANSWER_PROCESS`) and the file system
  the `native` profile admits (the judging directory, Julia's install); an answer that differs between the two is the
  label's `noanswer` (spec v16 X2), and what the body does with what the two share is the case's own claim, which G4's
  review and G1 judge; (b) **Julia's own bugs**:
  the loader's premises are Julia's (its lowering, its builtins, world age, its effects and generator records), so a
  bug in subtyping, in world age or in effect inference is a hole the loader cannot see; (c) **the bootstrap's
  trust**: the snapshot, the corpus as it stood at the bootstrap, is the oracle's definition and is loaded as it is
  (the loader judges units alone); the lines landed before the climb were written under human review, and the nine
  commits since 2026-11-01 (57 added lines) were read by a scan for `eval`, IO and global writes (none), not by G4.
  (d) **a body decides its own native answer in its processes**: it is the case; one pair of processes a label means
  no other case's body runs where it is answered, and G4 reads the body for whether it is a fair test. What the two
  processes do not share (their cwd, pid and clock, `PAIR_VAR`, the units' path, an address, a hash of a unit's
  type, an RNG's draw) shows as a `noanswer` when the two runs differ; what they share and the compiling process does
  not (`isdefined(Main, :WasmTarget)`, `LOAD_PATH`, another unit's module by a computed name) a body can still read:
  the load's read rule and the body scan for `U_<slug>` do not cover what a body does when it is called; G4 refuses
  such a body by name (reviewer.md). (e) **a key change** (any field of KEY_FIELDS: `judge`, the answering program's files, `test/smoke_judge.jl`,
  `test/oracle.jl` and `test/corpus_loader.jl`; `julia`; `host`; `env`; `snapshot`, the snapshot's blob) makes every
  measurement fail, located (an `OracleGap` naming the field and the replay; a score books `score-failed`, records
  nothing and files no G2, one note: one gap rule for every measurement), and the launch's preflight refuses while the
  store does not answer origin's landed labels under the key the build users run (`store_ready`), until the one
  replay: with the climb paused, `climb.py oracle-replay` answers every label of origin's corpus again under origin's
  key, one process a label, each written in its source's unit (the bootstrap's, and each unit's commit), resumable
  label by label as the bootstrap is (its partial file kept only under the same whole key line, else started over,
  said) and waiting until work may run (core.power_works); measured, the bootstrap of 1,949 labels took 16,890 s (v12, at default QoS), so a replay of
  the store as it stands costs about 4.7 h; an edit of the decoder (`test/oracle_read.jl`), the
  runner (`test/runner.jl`), the compiling side (`test/smoke.jl`) or the verdict (`test/verdict.jl`) changes no key
  and needs no replay (probed in a scratch state: v14/drv). (f) **the compiling process holds the corpus** (G4's): it
  is handed no answer (spec v16 X1), but the measured src runs where the corpus is loaded, so it can read a case's
  argument literals (they are in the checkout) and run a case natively, and a src that compiled a case to its native
  value would read passed; and it is handed each answer's shape, which holds an aggregate's structure (a Vector's
  length and a String's ncodeunits are the count of its leaf paths, the type parameters of the readers it compiles,
  `Leaves`, `_pick`; an empty Vector or String answer is entirely in its shape) and a type answer's type (spec v17
  Y4, red 8b); G4's review reads a src change for exactly that, and one that names `Leaves` or `_pick`. (g) **a test file runs where its verdict
  is recorded** (round 13's S6): test/src_tests.jl runs a shard's or the score's files one after another in one
  process and records each through `Test`'s own counts, so a test file can change the harness for itself and the
  files after it (`Test`'s internals, the record variables, `Core.eval` into the harness's module, `exit`), and the
  src it tests runs in the same process. What narrows it (spec v17 Z4): the exit status read against the rows; the
  judge's canary run last AND as each file after it (test/src_canary.jl `_wt_canary`, G5: a change keyed on a later
  file's name voids the process at that file); a process with no history (`git archive`) whose located culprit
  stands only when its file runs green at the culprit's parent (a test red by the date or by history is flaky,
  never a culprit); and two parser STOPGAPS (L228's reach checks: the plain spellings in src and test files). NOT
  fixed by construction: a targeted change that tells the canary from a real test some other way and lasts, or
  that names the harness through a name built at run time, is caught only by G4 reading the move's diff, which
  refuses a test file or a src change that touches any of them (reviewer.md). One process a file would close it
  and costs about 57 s a file (a score's src part ~3,570 s against 284-341 s, 11-12 times, lc's measure of
  2026-11-11): not built. (h) **a type reader reads what Julia leaves unknown** (spec v20 F1): a throw reader's caught
  value is `Any` at its source, so it reads the thrown object's own type. Two things it does not read (spec v20 G4,
  the round-18 architect's nits 1 and 2): an F Julia infers never to throw and free of effects has its call deleted
  (a call-site `@noinline` does not stop dead-code removal), so the reader answers 0 without running F, read `wrong`
  against the leaf's 1, never passed (reachable only through a false effect claim: sound inference never calls an F
  nothrow that native saw throw); and where Julia infers a singleton answer's F to return one constant, every use of
  the result, the IsA reader's included, is that constant, F's wasm result is `void`, so a miscompiled F has no other
  singleton to return through it, and the reader, whose call to F stays, still tells a return from a trap or a throw.
  An agent's Bash reaches its model through
  the proxy (no token: the proxy adds it), so it can spend up to its run's `--max-budget-usd` at the proxy's count,
  which is claude's own count while the prices hold (`price_band`); the runs alive at once can pass the room by the calls already admitted when it is reached (the
  governor is asked before a call, and a call's cost is known only from its answer), Bash's calls made in parallel
  among them; a build user once run with Dale's bootstrap keeps a `distnoted agent` that launchd restarts after every
  reap until a reboot (only its user's Mach lookups reach it, and every door run has none); an agent's Bash can kill
  its `claude`, which yields no answer (infrastructure, never a verdict); the clocks inside a stopped process (Kaimon's,
  a session's, `claude`'s own) see a landing's stop as time passed once resumed, which can end a tool call or a session
  (infrastructure at worst, never a verdict: every verdict is the driver's measurement); G3 is produced by processes that load the candidate's
  src, and so are the critical path's seconds the check reports (its class is check.sh's exit status, but a candidate
  whose tests pass can inflate the stages' counts into a D14 red, which costs it its own landing and no stop); G4 is a model.
- **No setuid program in a profile**: macOS refuses a sandboxed process the exec of any setuid program, even under
  `(allow default)`, and `/bin/ps` is one; Kaimon reads a session's liveness with `ps -o state= -p`, so with it every
  session read as dead and its gate was never matched. The mirror's `tools/bin/ps`, first on every user's PATH, is
  `/bin/ps` with no setuid bit and no entitlements (`door.plain_ps`). It reads what the kernel's process table gives
  any user (a pid, its user, command, nice, and `Z` for a zombie, which is all Kaimon's check reads) and nothing
  macOS's ps reads through task_for_pid, which only root may call: `time` reads 0:00.00, `pri` 0, and `state` `?` for
  a live process, even as Dale with no profile (probed). So no CPU time is read through `ps`: the one CPU reader,
  dev/cpu_seconds.pl (test/dart_limit.jl's watchdog and dev/corpus.sh's shards), reads it by libproc's proc_pid_rusage
  (probed as `_wtm1`: a busy process 3 s in read 3 s there and 0:00.00 through `ps`), which a process may make of one of its own user and, in a profile,
  of its own sandbox (`process-info*`); probed as `_wtland` in the check and julia profiles, a busy plant was cut at
  its 1-CPU-s limit, where the `ps` reading never cut it. xcrun's shims
  (`/usr/bin/clang`) run the Command Line Tools (`DEVELOPER_DIR`): Dale's xcode-select names Xcode.app, whose
  xcodebuild a profile refuses, so the check's instruction counter could not build its plant (probed). Probed: in the
  `kaimon` profile as `_wtk1` a session started in 26 s and `1 + 1` answered 2 cold and warm.

## Landing (one path, one shipper)

- **The one exception, the first landing** (spec v18 Q7, v19 Q3): the commit that puts the switched check on origin is
  landed by hand, once, by the steps of "The first landing" below:
  - a fenced check of every file, recorded;
  - the full matrix;
  - one direct push of exactly that commit, on the owner's written word;
  - one landing-log row with lane `owner-first-landing`;
  - `claim-repo`;
  - the first score before any climb move.
  No waiver code exists for it, and no band changes.
- **The lander is the only process that runs `dev/ship.sh`.** An approved move is queued with its sha (fetched
  from the slot's clone into the main repository), its patch-id, its base, its labels and its delta, and its slot
  goes back to origin/wt2. An audit and a commit made by hand (`climb.py enqueue <ref> <title>`) queue the same
  way; a hand fix of a known red (`climb.py enqueue <ref> --fixes <key>`) is queued on that fix-first entry's hold, so
  its check runs the red's file and its landing clears the entry, and it alone is admitted while a red is overdue. No slot starts a move while `queue_cap` commits wait (D50).
  A hand commit never bundles src with harness work: `enqueue` refuses an item whose commits change `src/` beside
  a path no move may change (the harness, the judge's files, the rules), naming both sets (`measure.bundled`,
  A106E2; door-probe rows), so src lands in a commit of its own, under its own message and clauses.
- **Each round** the lander resolves what a killed round left (a queued patch already on origin: the landed event
  is written before the item leaves the queue, so a landing has that one source; an audit entry on origin with its
  findings unfiled), then takes the queue in order: its gates read again in the main repository (G5 kept on the
  item by its sha, O5-12), the pinned sha checked out, `dev/ship.sh --admissible` asked (its cheap refusals, the line
  stop among them; `SHIP_MAX` too is read from origin's ship.sh), a critical memory pressure a wait, and only then
  the rebased measurement when origin moved, the quiet probe and the check. **The lander runs no agent** (item 11):
  the judge's eval (when stale) and the audits (when `audit_every` landings wait unaudited, D21; an audit only
  enqueues) run from the score tick, never at week-half or past the day's allowance (an audit is exempt from the
  allowance alone, K5), so the week's half, the budget or the agent probe never stops a landing (D51). The
  lander's measurements are served first on the one measurement lock (its mark holds the slots back while it waits, and
  a measurement in flight yields at its next part); G5's corpus parse runs as the deps user, never behind a
  measurement (A6-6); a wait past
  `lock_wait_s`, the lander's, a slot's or the scoreboard's, is a note and waits on, never a backoff or a charge:
  each holder has its own wall.
- **The quiet probe.** It is a measurement, never a gate (throughput P0, the owner's "STOP pausing EVER", 2026-11-13):
  the lander starts every check whatever the probe reads. D14's band judges a check's cost, and only a check that began
  and ended on a quiet machine is evidence of it: `lander.quiet`, the one definition (the probe within `p_idle`,
  `e_idle`, `swapins_max`, `decompressions_max`, the pressure under critical, and Low Power Mode off), read at the
  check's start and at its end. A check that read red on the band alone asks the lander (`dev/d14_judge.sh`, called by
  dev/ship.sh on the check's status before its push): quiet at both ends, it is a D14 red as before (the D14 backoff,
  the hourly cap and the counts apply to these alone); not quiet at either end, it lands on correctness alone (every
  test, the ratchet and the canaries passed: the band is check.sh's last verdict) and its time is `unjudged`, read by
  neither the margin, nor `checks_measured`, nor the near-band note, nor `d14_binds` (`core.judged_check`). No
  measurement runs beside a check (ruling 1): the lander takes both measurement locks first,
  the score's and then the verify lock (O7-5: never the verify lock held idle behind a score's part), its mark served before any other taker, and holds them through the probe and the
  check; a measurement it waits on yields its lock between its parts (a compile at its next case's boundary, its
  finished cases kept and the rest run again after; between its three roles; the score's kinds after its smoke),
  each part's seconds an event (`smoke-part`), so a landing waits one part, never a whole score. **The locks'
  order** (spec v17 Y3), the one order every process takes the climb's locks in, asserted where each is taken
  (`door.LOCK_ORDER`, `door.assert_order`, in `door.using`, `measure.julia_slot` and `measure.yield_slot`; a lock out of
  order is refused, `LockOrder`, before any wait): a slot's role (held across its move), a review's role, the score's
  measurement lock, the verify lock, ship.sh's landing lock (origin's script's; the driver only waits on it), the
  landing's window (`door.open_window`), the dependency images' lock (`measure.deps`), one measuring role (measure,
  score, land, deps), and last the state lock (`core.locked`), held for a write alone: the order is total and each is
  asserted where the driver takes it, no lock taken under the state lock (spec v18 P6; probed in a clone: the verify
  lock under the state lock and the window inside a measuring role refused, where HEAD took both). A process takes a lock only while every lock it holds is earlier, so no two processes wait on
  each other; a yield takes its measurement lock again, so no yield happens while a measuring role is held: each of
  smoke()'s parts takes its own use of the role and leaves it before the next (what a part hands the next is kept in
  the driver's own directory, never a run directory; the base cache's file is merged with what is on it when written,
  under a lock of its own held for the write alone, so neither of two writers drops the other's rows; a landed head's
  base file is seeded from its own landing's rows when the landed tree is the tree measured, the measuring driver's
  dev/climb is the head's and each row names the head's judge, `measure.seed_base`, throughput T3(i)), and a compile's
  yield at a case's boundary leaves the role's use
  for its wait (`door.released`: the role's lock let go and taken again; when another use came between, which the
  role's generation, written by every taker, shows, the part's directories are made again, or, with no way to make
  them, the part is cut, `RoleLost`). Probed with the operator's rolecycle cases (council/v17-report.md): 0 deadlocks in
  50 trials of each, where HEAD's arrangement waited out `role_wait_s`. Then every build
  user's processes but the landing's and the two measuring users' (by user, door.stop_role) and macOS's Photos and
  media analysis are stopped, each stop recorded first, and every wall the driver keeps on such a role counts its
  awake time alone (`door.awake`: door.run's walls, a run's `task_wall_s`, a Kaimon call's `kaimon_http_s`, a session's
  warm and a Kaimon's start), so the driver's own stop is never a run's timeout, an infra fault or a refusal (ruling
  11). Every wall and case budget the driver keeps reads one clock, `door.CLOCK` (time.monotonic, here
  mach_absolute_time, which stops while the machine sleeps: probed, it read 61,637 s less than the wall clock since
  this boot, the sleeps' sum), so a lid closed is never a run's timeout or a case's budget (O7-1; probed with the
  operator's sleep, a 600-s jump of the wall clock mid-case: nothing booked, where HEAD booked the case errored and
  awake() read 600 s). One record holds a landing's stops, `TOP/locks/window.json` beside the users it guards: its
  owner and boot, its start, each role it covers and whether it stopped it, the daemons it stopped and each role's
  past windows; it is the awake clock's, the start gate's and the orphan resume's one source, one window at a time
  across every state (its owner holds `window.lock`), and an open window whose owner is not alive is closed for every
  reader (A7-4, R7-10; probed: a dead owner's hour-old window left `awake()` at 2 s of 2 and a 1-s wall cut a 6-s
  process, where HEAD's open stop read 0 and the wall waited 6 s). The cores are sampled
  for `probe_s`, and only performance cores at least `p_idle`% idle, efficiency cores at least `e_idle`% idle, and a
  machine not paging now (at most `swapins_max` pages swapped in and `decompressions_max` decompressed over the same
  window; the pressure level refuses at critical alone and is recorded, O5-3) get the check. Each check's `ship`
  event holds its probe (with the stopped processes' resident memory), what the machine paged while the check ran
  (vm_stat's pageouts, swapouts, swapins and decompressions over it), the critical path its stages reported, its
  split (each stage's judged seconds and their three terms, the wall: check.sh's `check-split.out`, carried by ship.sh) and
  D14's verdict on it, so the burn-in reads whether reds follow memory (O6-7; probed with a stub check), and these
  bands are re-derived from them; the median of the last five green checks past `near_band` of D14's band is a note once, again only when it
  rises `near_band_step` more (O5-11); a busy machine holds no check (throughput P0: the probe is the measurement of
  whether the check's time is judged, never a wait).
  Nothing is stopped during a wait, only during the probe and the check, and every stopped process is recorded
  in the window's record, so a killed owner's are resumed by the next climb process to start. Every pid the climb records
  (a stop's owner, a claim, the lander's mark, the quiet window's owner) carries this boot's time, and one test
  (`door.alive`) reads a pid of an earlier boot as dead; ship.sh's landing lock is dead when its directory predates
  the boot (O6-11), and launch.sh's pid files, ship.sh's lane lock, its landing lock and its queue tickets record
  `<pid> <boot>`, tested the same way, by ship.sh's `alive_rec` and the driver's `landing_lock_held` alike (O8-6: an
  older ship.sh's pid alone counts in the boot its file was made; probed: a lock or a ticket of an earlier boot whose
  pid a live process holds read dead, where HEAD's `kill -0` read both alive and its driver could not read the new
  record) (O7-6;
  probed: a live process holding a pid recorded in an earlier boot was not signalled by `launch.sh stop` and freed the
  lane lock, where HEAD sent TERM and KILL to its group and refused the lane `busy`). While the window is open no
  process of a quieted role starts or resumes itself: a new run, a session's start and a move's resume of its own
  slot wait at one gate (`door.after_window`, in `popen` and `signal_role`) until the lander, the window's live owner,
  closes it (probed: a slot's resume and run asked 2 s into a 10-s window ran at its end; before, it ran beside it).
- **The result** is what `dev/ship.sh` writes, `<KIND> <arg>`, to a file the lander names in its own state
  (`$WT_SHIP_RESULT`), and the check's verdict, its exit status (`dev/check.sh` names each: 0 green, 1 its own red, 10
  D14, 11 the hard limit, 12 the line stop, 13 a hold) and the critical path its stages reported, which ship.sh writes
  to a second such file (`$WT_CHECK_RESULT`); a red's class is the step of the rebase that failed and that status. The
  lander reads those files and no line of output: the check's output goes to `.wtd/check.log`, never into ship.sh's,
  since a test prints what it likes (R6-2, R6-7). No file is OTHER. LANDED is booked only when origin/wt2, fetched,
  holds the sha it names (else OTHER), by the pushed commit, its delta advancing the hold's cases at once. D14 (a check red on its time alone): approved work is never sent back for time (A7-2,
  O7-3, R7-4): the item keeps its queue place, its approvals, its rebased verdict and tree, and is tried again after
  the lander's `d14_backoff_s`; while `queue_cap` items wait the slots idle and spend nothing; one note for Dale each
  time the share of the last `d14_share` checks read red on D14's time passes its share, or falls back, naming their
  critical paths and Dale's band, and an alarm when checks run and no `landed` event follows them for `alarm_s`
  (probed with the real land_round and a stubbed red check: the item kept its place and its rebased tree, no drop, no
  stop, no re-climb, one note at the tenth check and none at the eleventh; HEAD dropped it and its hold re-climbed). A rebase conflict on origin:
  back to its hold, no stop counted (the queue's order). ship.sh's one retry an hour: the next item. A changed
  ship.sh (stale-ship), a held lane, the line stop, or origin moved past the commit measured (`moved`, measured again):
  the next round. NETWORK (fetch or push): the lander backs off
  with a note, the item kept. OTHER (ship.sh's or the door's own fault: no result, a door failure): retried on `other_tries` rounds, then back to its hold with no stop, the lander backing off. A red of its own, or a
  refusal: back to its hold. A PAUSE file (`launch.sh pause`, or an alarm's: a patch landed other than approved, a
  push around the driver) stops the lander as it stops the slots and the audits. Half the week's limit is no pause
  (D51): it is a state the driver computes from the spend, under which no agent runs (so neither a K4 review nor an
  audit); the lander lands on, spending no tokens, the rogue-push check and the alarms run, and agents run again
  when the week resets. `launch.sh stop` ends a running ship.sh with the lander.
- **A landing's test set** (the landing-check ruling). A landing's check runs the set the lander computes before it from
  origin's records alone (`measure.src_set`, `src_handed`) and hands through dev/ship.sh to the door's run directory:
  the move's own test files (the diff's A and M under test/src) and those of the src-test reds standing for its hold, and the files the
  last score did not run green, none ever cut; and the share, filled under THIS landing's target (round 14's T2): the
  files the last landing could not take first, then the score's ring (its files in path order with their costs, the
  one thing a score fixes) from its position, each taken while the set predicts within the target; a ring file that
  does not fit is passed over and carried to head the next landing's, and the position advances past the last file
  taken (`src-ring.json`, written when the landing lands). The target is D14's band less a margin
  computed live by `measure.src_target`, never set by hand, per shape, one-sided, robust and bounded (spec v17 Z5):
  three times the SECOND-largest positive error (judged over predicted) of the last `src_margin_checks` checks of the
  landing's shape that were predicted before they ran, not ended by the power rule, and passed and landed or read red on D14's band alone
  (spec v18 Q5: the errors that cross the band are the ones the margin must see; a check red on its tests teaches
  nothing), between `src_margin_min_s` and `src_margin_max_s`, `src_margin_start_s` until that many exist, a note to
  Dale once per crossing of the cap; and no set is admitted larger in G than the largest set those errors were measured
  on by more than one file. The `ship` event keeps the target and margin it used. A test reads no history (spec v17 Z4): the score's src part, R3's run and every bisect step run in a `git archive` tree of the commit, its history removed once the base is made; a landing check's shards run with `GIT_DIR` naming no repository (the ratchet beside them keeps the tree's `.git`: it reads git, and its plants make scratch repositories); the base a test is measured against is made by the driver's or check.sh's own git and handed as `WT_BASE_TREE`. A located culprit stands only when the same locate runs the file green at the culprit's parent: a file red there too goes to the flaky rule. Each landing
  moves the position at least one ring file, so every file is considered within the landings whose capacities at their own
  targets together cover T, and a carried one runs at the first landing whose target holds it; one no target holds is
  run by the score, the lander holding at `src_unverified_max` landings with a file unrun. With no score's record at
  origin's head nothing lands or climbs (`admits`: the first score comes first), and a set that cannot be made leaves
  the item waiting with one note, never a check of every file (spec v18 Q2). `predict` lays the files by longest processing time over the
  shards, each shard read as c0 + its G / g: c0 the median of the checks' measured shard starts (each shard's time to
  its first claimed file, `start.<k>` in the split) plus the warm-up its first file pays (the score's `warm`), g fitted
  alone to those checks (their shards' judged seconds against the score's costs of the files they ran, their starts
  and their warm-ups), each from the predicted shape's own last five checks (the other shape's while it has fewer than
  `src_shape_checks_min`); the slowest shard at least the mean plus the checks' imbalance, beside their ratchet and the
  load of the checks of the same shape (every check loads WasmTarget in its judged load stage). A launch has priors,
  never every file (round 14's T3): until the checks hold a term, `predict` reads its declared prior (`src_prior_g`,
  `src_prior_start_g`, `src_prior_load_s`, `src_prior_ratchet_s`, `src_prior_imbalance_s`, measured on this machine)
  and names it in the prediction's `model`; g and the start are replaced once a shape has `src_shape_checks_min`
  checks, the load at a shape's first, the ratchet and the imbalance at the first check of either, and the margin is
  `src_margin_start_s` until `src_margin_checks` predicted checks exist
  stage). A test file a landing could not take and whose lone-shard prediction passes its target is named
  (`src-unfit`, one note each time the set changes): never silently the score's alone (R2); splitting it is the
  lead's move. Before the check, a move
  whose own and unscored files alone predict past D14's band is refused as its own, located; a check past the band with
  an own file no score has costed is the move's own red, never a D14 wait. A check red on its test files alone (its exit
  14) whose red files are all outside the move's own is run at origin's head in one process (`src_red_at`, R3, R10): red
  there, origin's: located at once (`src_locate`, the fix-first filed, the file into R) and the item checked again
  without it, uncharged; green there, the move's own red, as before, unless a file read so twice within
  `fixfirst_max_landings` landings (src-differs.json keeps each file's landing counts, those outside the window dropped;
  spec v17 Z7) (the note, R until it passes twice). A known red that runs in the set (a src-test fix-first entry) is named in the handed set with its every failing test (`# known`, spec v18 Q1), and a row red only there is the known red's, never the change's: the check stands, the item lands and the entry ages in landings (`dev/src_verdict.sh`, the one reading of the shards' records; spec v17 Z1); a different first failure is a new red. The lander's loop waits on every `lander:*` backoff through one predicate (`core.waits`). A landing proves exactly its set (spec v17 Z2): every handed file has exactly one row across the shards, or the check is red naming the files, and the lander refuses records that are not exactly the set. A void process (its canary read wrong, or its exit status disagrees with its rows) is a red of the process, located as a red is (spec v17 Z3): the check exits 15 with the void shards' files, and the lander runs those outside the move's own at origin's head; void there, `src_void_split` narrows them, one process a half, to the file whose presence voids it, `src_locate` locates it over commits, its fix-first is filed and the item goes on uncharged; at a score the same, with a note, and the other files run again without it. The `ship` event keeps the set, its prediction and the judged split; a landing's green run of exactly
  its set is kept (`src-green.json`). The lander lands nothing while `src_unverified_max` landings stand with a test file
  unrun green since (`measure.src_unverified`, the known reds aside), one note for Dale.
- **D13 reads red for every climb landing**, by construction: `dev/ship.sh` bands the median of the last five
  landings' edit-to-landed (a 300-s target, red past 600 s), and a climb move's edit-to-landed spans its climber, its
  measurement, its review and its wait in the queue, half an hour and more. What D13 measures for the climb is
  Dale's to say (A84E3: changing what a band measures is his; K6); until he does, the red line is expected and is
  no finding about the move.

### The first landing: the steps, for the lead to run on the owner's written word

The switched dev/check.sh runs a landing's test set as the climb's lander hands it, and no lander can hand one before
the switch is on origin. So the one commit that puts it there, C1, is pushed by hand, once (the round-15 architect's
finding 6; the round-16 operator's checklist, which these steps follow). There is no waiver code and no band
change: D14 reads this check red (about 195 s, every file), and the owner's word admits that one commit. Nothing
here is run by the driver. A step that writes runs from a `git clone` with its own .git, except where it names the
real repository or state. A step that imports the driver from the real repository runs with the default state only,
never WT_CLIMB_STATE.

0. **The owner's word.**
   - The C10 edit, its ratchet reading L125 green on C0.
   - The landing log, one of two:
     - (a) the reconstructed log (`<scratchpad>/landlog/wt-landings.reconstructed.tsv`), which names all 53 commits of
       `launch-base`..e9a8a883 (a6363d6d..e9a8a883), so `launch-base` stays;
     - (b) a fresh log, which needs `launch-base` set to C1 (step 6), or the first tick reads those 53 commits as a push
       around the driver and pauses for good.
1. **C0, the squashed commit** onto origin's wt2:
   - `git merge-base --is-ancestor origin/wt2 C0`, and `git rev-list --count origin/wt2..C0` is 1;
   - its message carries `Closes: C10`, the `Charter-change:` line and `Charter: C10`;
   - `bash -n dev/check.sh dev/ship.sh dev/climb/launch.sh` passes.
2. **The fenced check of every file**, in a clone at C0. The set is
   `{ echo "# head $(git rev-parse HEAD)"; git ls-files 'test/src/*.jl' | sed 's#^test/src/##'; } > <set>`, then
   `chmod 444 <set>`. Run `WT_SRC_SET=<set> CHECK_BASE=HEAD~1 CHECK_LANDING=1 bash dev/check.sh 2>&1 | tee <rec>/check.log`
   (CHECK_LANDING=1: test/src_tests.jl refuses a run on the performance cores that is not a landing's check).
   - Exit 10 (D14 alone) is expected; any other code stops here.
   - Then `cp .wtd/check-path.out .wtd/check-split.out .wtd/src_records.*.out <rec>/` and `shasum -a 256 <rec>/*`.
   - Every file of the set has one `passed` row, and every canary is right.
3. **The full matrix** at C0: `bash dev/gate.sh` green (D16), its output kept beside step 2's.
4. **C1** is C0 with the evidence in its message: the record's path and sha256 lines, the judged seconds and the
   matrix's run. `git rev-parse C0^{tree}` equals `git rev-parse C1^{tree}`.
5. **One direct push**, on the owner's written word: `git push origin C1:wt2`.
   - Before: `git rev-parse origin/wt2` is C1's parent, and no loop is alive (`bash dev/climb/launch.sh stop`).
   - After: `git fetch origin && git rev-parse origin/wt2` is C1.
   - NOT reversible (D23).
6. **The landing log**, before any driver process starts. Do (a) or (b), then append the one row below.
   - (a) `cp <scratchpad>/landlog/wt-landings.reconstructed.tsv "$(git rev-parse --path-format=absolute --git-common-dir)/wt-landings.tsv"`.
   - (b) Start a fresh log, and run `git rev-parse C1 > <the real state>/launch-base`.
   - The row, in dev/ship.sh's format:
     `printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short C1)" <seconds from C1's first commit to now> <seconds since the push began> owner-first-landing >> "$(git rev-parse --path-format=absolute --git-common-dir)/wt-landings.tsv"`.
   - Check, read only, in the driver tree with the default state:
     `python3 -c 'import sys; sys.path.insert(0, "dev/climb"); import climb; print(climb.unlogged_landings())'` prints
     `[]`. A non-empty list stops here: a resume would pause at the first tick.
7. **`python3 dev/climb/climb.py claim-repo`** with the default state, before ANY other driver process.
   - It prints `claimed <common> for <the real state>`.
   - Without it, every driver write under the common dir is refused.
8. **The node:** `python3 dev/climb/door.py tools --fetch-node`, then `python3 dev/climb/door.py tools`.
   - NODE_PIN's sha256, re-hashed, and `otool -L` naming /usr/lib and /System alone.
   - Before step 13, since the judge's key hashes the tools.
9. **The state's cleanup**, PAUSE kept and no loop alive:
   - ready.json's unpinned items (reconcile salvages them; remove the file first to keep none);
   - the dead keeper files;
   - the `sw-probe` refs and the `lc-land` worktree record in the real repository;
   - `<common>/wt-held` read;
   - stale branches deleted once their commits are carried.
10. **The driver worktree and the door probe:** the first `sync_driver` makes `.worktrees/climb-driver`. Then
    `python3 dev/climb/climb.py door-probe` there (never `launch.sh probe`, which spends tokens) reads every row
    `held`.
11. **The store:** `caffeinate -s python3 dev/climb/climb.py oracle-bootstrap` from the driver worktree, after
    `git fetch origin` (it keys origin/wt2, which is C1), PAUSE present and on AC.
    - About 4.7 h, resumable.
    - Done when preflight passes `store_ready`.
12. **The watcher**, from `.worktrees/climb-driver` (this step and every one after it): `bash dev/climb/launch.sh watch-install`.
13. **The first full score**, on AC, from `.worktrees/climb-driver`:
    `bash dev/climb/launch.sh resume && bash dev/climb/launch.sh`.
    - Never `slots: 0` in the state's config.json before spec v20 F2 has landed: launch.sh's `seq 0` printed `1 0` and
      started `climb-1` and `climb-0`. No slot climbs before the first score anyway (`core.admits`, below).
    - `core.admits` lands and climbs nothing until `src-latest.json`'s head is C1 (spec v18 Q2), and the score needs
      nothing it refuses.
    - Done when `src-latest.json` names C1.
    - Expect no `score-rebased` (the first score has no table of earlier rows to rebase) and no `src-failed`.
14. **The judge eval and the agent probe**, from `.worktrees/climb-driver`, when the week's budget admits agents
    (`python3 dev/climb/climb.py budget` exits 0): `bash dev/climb/launch.sh probe`.
15. **The supervised burn-in**, from `.worktrees/climb-driver`, starts at the first `src-latest.json` for C1 once
    `python3 dev/climb/climb.py budget` exits 0 (a budget over the week's line waits, PAUSE kept, and the burn-in's
    clock starts at that exit): at least 6 landings in 12 h (or 8 in 16 h).
    - Recorded: every `ship` (set, target, margin, predicted against judged), `yielded`, `src-recheck`,
      `src-origin-void`, `src-origin-red`, `src-own-red`, `src-known-red`, `run-failed`, `rogue-push`,
      `score-rebased`, the gap notes, `land-skipped` and `alarm`.
    - Forced once each:
      - a landing during the score's src part;
      - a known red plus a second failure in its file;
      - a shard killed mid-file;
      - the node removed for one score;
      - a power cut in R3;
      - `kill -9` of the lander after `landed`;
      - a move whose calls all hang.

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
  tools it needs (an 8.6k baseline in place of 39k). It exits after one commit or one report.
- **Warm Julia, not fresh processes (D39).** A climber develops in its slot's Kaimon session, about 0.2 s a
  compile against 25 s for a fresh process. The driver starts the slot's own Kaimon and session and loads WasmTarget
  in it while it measures the base, in parallel; both end with the move. A climber's own smoke runs its hold's cases alone
  (`.wtd/hold-cases.txt`), and it runs no baseline: the driver hands it the base rows.
- **No climber on a dead hold.** The base measurement covers every case of the hold; a hold none of whose cases
  still stops at its key is advanced and skipped, never climbed.
- **One iteration per process, landed code only.** Each slot, the lander and the scoreboard are loops in
  `launch.sh` that run one move, round or look per process from the driver's own worktree, fast-forwarded to
  origin/wt2 first: the climb runs only what landed, and never stops for a restart. One process per loop (a lock),
  and a launch refuses while a recorded loop is alive (its command line this script's; a recorded pid that another
  program now holds is removed, with a note). Each iteration first asks the disk: under `disk_free_gb` free the climb
  pauses with one note (O6-10), and launch removes the run directories a killed driver left under the door's `in/`. A launch runs
  `preflight` once (it ends the old landing scripts' stale loops and waits for them), and `preflight` refuses while any
  loop of the climb runs (its lock held), so run by hand beside a live climb it touches nothing (O7-8, A7-7; probed with
  the lander's lock held: refused before any step, where HEAD cleared `in/`, re-pinned claude, re-mirrored the
  toolchain and called the token). **Awake and loud** (O5-8, O5-9, D-H, O6-6): each loop stamps
  `logs/<loop>.stamp` at every iteration and every step of progress (an event, a poll of a run it waits on, a
  measured case's record, a wait on a lock: `core.beat`), and `launch.sh` starts a heartbeat that touches
  `~/Library/Application Support/wt-climb/heartbeat` every minute while every loop's stamp is younger than its
  `loop_stale_s` and none has failed five times in a row, holding a power assertion of its own (`caffeinate <flags> -w
  <the heartbeat>`, its flags asked each minute of `climb.py power-hold`, spec battery1 B2: with `battery_runs`, `-i -s`
  while work may run, on battery too, and none while the power rule stops work, so an emptying battery is never held
  awake, O9-2; with it off `-s`, on AC alone; a driver that cannot answer keeps the flags it had; a closed lid still
  sleeps the Mac), so the Mac does not idle to sleep under the climb and one dead or hung loop stops it (probed: a lander
  stamp 40 min old stopped the heartbeat, which the old one, alive while any loop lived, touched); every git network
  call of the driver, its loops and the ship.sh it runs is cut under `git_low_speed` (git reads it from the
  environment the driver sets), and every wait on a lock of the climb's is bounded (a role's by `role_wait_s`, the
  dependency images' too, the agent probe's, the state's by `state_lock_s`), past it an event and the loop's backoff;
  a loop's fifth failure in a row is a note written by bash, which needs no driver module. **Power** (O8-3, R8-5, O9-1, spec battery1 B1):
work runs by one rule, `core.power_works`: on AC; or, with `battery_runs` (Dale 2026-11-13: "keep gping with or
without battery"; 2026-11-13: "STOP pausing EVER"), on battery with the charge at or above `battery_floor_pct`, Low
Power Mode on or off. Low Power Mode halves the machine's rate, so a landing check in it is not quiet: judged on
correctness alone, its time unjudged (the quiet probe, throughput P0), never a hold. A charge under the floor waits
(the battery emptying would cut a landing or a push, a real loss); with
`battery_runs` false the climb runs on AC alone, as before. One reading of the power source, Low Power Mode and the
battery's charge (`core.power_read`, pmset's own words, at most once a second; `core.power_ok` the rule over it) is
taken at every tick where the disk is asked and by each loop before it starts work. A change of (source, Low Power
Mode, the charge at or above the floor) counts only once the new reading has held `power_settle_s` (O9-2: the adapter flapped 117 times in six minutes on 2026-11-08): the reading that
differs is kept in `power.json` with when any process first saw it, dropped when any process reads the settled one
again, and settled once it has held, which writes the event (`power`, with the charge and whether work runs) and at
most one note for Dale per direction per `alarm_s`, the directions being work on AC, work on battery and waiting
(under the floor: plug in). Probed (`v10/p3/flap.py`, the operator's, on a simulated
clock: `pmset -g log`'s own timeline read every 5 s): each burst wrote one note and one event, the settle to AC once it
stopped (the windows' other note is a real battery period before each burst), where HEAD wrote 30 and 6; two real
unplugs 20 minutes apart wrote one note per direction, where HEAD wrote four (`twice.py`). While the rule stops work
no move, measurement, score or landing check starts: each loop's start reads it, and `julia_slot`, which every
measurement and check holds, waits until work may run before it starts anything (`ac_wait`, at most `task_wall_s` of
awake time). A measurement or check in flight when the rule comes to stop work ends (`power-cut`, naming the label in
flight, or the hold for a check), never a verdict, a learned time or a D14 row (`d14_binds` and `near_band` count no
check the rule ended); one in flight when the source changes from AC to battery with Low Power Mode off above the
floor is not ended (nothing about its timing changed). Its `PowerCut` is handled in one place, `core.on_ac`, never as a failure: it books `power-wait`, with no
backoff, no `base-failed` or `lander-error` and no note beyond the power note. A loop's iteration (a score, the
lander's round with its rebased check, a land check) ends there, and the loop starts nothing until work may run. A
move keeps its commit and its slot's use: its gate (the bundle, G5, the measurement) and its base measurement wait
and run again, the wait bounded by `task_wall_s` from the first cut, past which the move ends as infrastructure. When the rule
stops work the lander stops ship.sh only while ship.sh's step (`$WT_SHIP_STEP`) is `regen` or `check`, never at the push or after it,
since a stop between the push and the landed hook would leave a landing its log does not name; a landing that completed
stands. Agent runs in flight finish. Probed (`v10/p2/power.py`, a stubbed reader, a scratch state): three cuts of the
lander's rebased check wrote three `power-wait`s, no backoff and no note, where HEAD backed off three times and noted
"lander failed 3 times"; a move whose gate was cut ran its gate again on AC on the same commit and was queued (rc 0),
and one left on battery past `task_wall_s` ended as infrastructure, where HEAD booked the move infrastructure at the
first cut; a base cut by battery was measured again with no alarm, where HEAD wrote `base-failed`; a check on battery
at its push ran to `LANDED`, and one at its check was stopped with no verdict, where HEAD stopped both. Earlier
(v9, p3): a slot, the lander and the score tick started nothing on battery, a compile in flight ended at the change
and learned nothing, and ten D14 reds that saw battery wrote no note (those probes ran the AC-only rule). Probed
(battery1, `core.POWER[0]` stubbed, a scratch state in a clone): on battery with Low Power Mode off at 80% work runs and a measurement in flight is not cut (door.tick), where 4945cf3b cut it; in Low Power Mode, and at 15% (also crossing from 80%), work waits, the first note naming the setting to change and the second the floor; the 117 flaps of 2026-11-08, twice within `alarm_s`, write two notes and five events with either battery reading; `power-hold` reads `-i -s` while work runs and nothing while it waits; with `battery_runs` false every one of these reads as 4945cf3b's, line for line (`battery/probe.out`).
  `launch.sh watch-install` installs a launchd agent whose script lives outside ~/Documents (a launchd job is denied
  the protected folders, and Dale grants no Full Disk Access): after every login, and when the heartbeat is
  `watch_stale_s` old, it posts a notification telling Dale to run `launch.sh`; within `watch_stale_s` of the
  machine's last wake (`kern.waketime`) a stale heartbeat is the sleep's and the verdict waits for its next run
  (probed with a planted wake 60 s back: no note, and with one 2 h back the note; HEAD noted both). The climb never starts itself: a
  reboot waits for Dale's FileVault password, and automatic macOS installs are off while it runs. Every note for
  Dale is a notification too. A launch refused for any reason is a note through the driver's alarms, at most one in
  `alarm_s` each. The stall alarm counts from the launch's own stamp, and is silent at the week's half, while a
  slot waits for the day's budget (O6), and while the slots idle by rule: `queue_cap` items waiting, a D14 wait or its
  binding, battery (O8-5; probed: no `stall` with the queue full, where HEAD wrote it beside its cause's own notes).
- **No resident agent, no LLM monitors.** The driver is a program. The scoreboard and the map are
  programs, and the map is redrawn at every score, landing and audit (D29). Opus rules a stopped hold. Fable is called only when an Opus ruling escalates, at most
  `fable_per_day` a day (D48). The models and the budget are not set by config (D14, D48).
- **A governor.** The driver reads every session of the account (the climb's and any run by hand, Dale's included):
  an agent's spend from `spend.jsonl`, where its run's proxy appends each answer's usage the moment it reads it
  (`core.book`, the one spend source, one line per answer under a flock), every other session's from its transcript
  (item 15), each read once through a cache that keeps `spend_window_days` alone and is written only when an offset or
  a day changed (O7-7; probed on a copy of the real cache: 299 entries became 282, 879 KB 788, and calls with nothing
  new wrote nothing, where HEAD grew it to 311 and rewrote it at every call). Each proxy asks the governor (`room()`) before every call, so the runs alive at once share one room and
  none is given it whole (R11). It starts no move past the day's allowance: the week's limit times `week_pause`, spread over
  seven days (K7, O9), so the nights after a heavy day still climb; a move it admitted runs to its end, its calls gated
  by the week's half and each run's own cap alone, so the day's crossing never cuts a move and loses what it spent
  (O7-4; probed: past the crossing a started move's next run and its proxy's calls were admitted and the next move did
  not start, where HEAD refused the run and its calls), and at half the
  week's limit no agent runs until the week resets (D51). An audit (about 0.6M) and the agent probe are exempt from the
  day's allowance (K5); never from the week's half. Each run has its own cap. A slot's wait for the budget is an
  event when it begins and when it ends, never each round (A13).
  **While `budget_holds` is false none of these holds anything** (Dale 2026-11-13, the account past the day's
  allowance and 4.3M short of the week's half: "dont worry about token keep going", then "STOP pausing EVER"): the
  governor counts and reports as above, Dale is told once at the week's half, each run keeps its own cap, and no move,
  call, eval or audit waits or is refused for the account's spend. Setting it true restores every hold of this item.
- **Few retries.** A move resumes its climber at most `resumes_per_move` times, each resume under a small cap. A
  climber's own `blocked:*` is ruled at once, but its `blocked:infra` is the driver's, no stop, when the driver sees
  Kaimon, the session or the depot down (O5-5; the session asked `1 + 1` by its key, never "any process of its user",
  which launchd's own agents answer: they are named once, `door.LAUNCHD_AGENTS`, and left out of every count that is
  judged, R6-10); a driver's refusal or a review that did not approve is `refused`,
  ruled only when the hold reaches its park (A7): `stops_per_hold` stops since it was last parked, one more at each
  of `park_steps` cases. There Opus rules, its ruling kept for the hold's next climber, and the hold is parked for
  Dale with the default taken; a score or a landing that
  changes its cases unparks it. An empty agent answer is retried once; twice empty, a failure of the driver's own
  or a budget refusal is no stop and parks nothing, a climber's resume included, and a run past `task_wall_s` (its
  user reaped, a slot's Kaimon with it) is infrastructure at once, never resumed; a hung Kaimon call errors to the
  agent after `kaimon_http_s` (`MCP_TOOL_TIMEOUT`, O6-12) (O6-4; probed with stubs: a resume
  the governor refused ended the move `budget`, an empty one `infra`, neither a stop); a base measurement of origin that fails is the driver's, one
  note and the slot's backoff, never the hold's (O5). One wrapper holds every loop's iteration, the slots', the
  lander's, the scoreboard's and the audit's: any exception, a subprocess's timeout among them, is an event and a
  backoff of `retry_backoff_s`, doubled each time it repeats (`backoff_cap_s` at most), which ends when the driver's
  own code changes (`core.running`: the fault may be the code a landing replaced), with one note for Dale at
  the third in a row (the second for an audit, the first for the network); no move or landing for `alarm_s` is a
  note too. A score that loses more than `score_loss_band` of the table's passing cases is run again before it counts.
- **Cheap first.** A review runs one reviewer. A council adds its next member only when the cheaper
  one approves.

<!-- defaults:begin -->
The driver's numbers, generated from dev/climb/defaults.py, where each states its intent and band:
`slots` 2, `climber_model` "claude-opus-5-5" (locked), `climber_effort` "high", `reviewer_effort` "high",
`ruler_model` "claude-opus-5-5" (locked), `fable_model` "claude-fable-5-1" (locked), `fable_per_day` 2 (locked),
`week_weighted` 838000000.0 (locked), `margin` 0.85 (locked), `week_pause` 0.5 (locked), `budget_holds` false (locked),
`claude_home` "", `task_cap_usd` 25.0, `resume_cap_usd` 8.0,
`token_file` "~/Library/Application Support/wt-climb/agent-token", `agent_probe_usd` 0.5, `agent_probe_runs` 3,
`bundle_cap_bytes` 67108864,
`price_usd` {"claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_write_5m": 5.0, "cache_write_1h": 8.0, "cache_read": 0.2}, "claude-fable-5-1": {"input": 10.0, "output": 50.0, "cache_write_5m": 12.5, "cache_write_1h": 20.0, "cache_read": 0.5}, "claude-sonnet-5-5": {"input": 2.0, "output": 10.0, "cache_write_5m": 2.5, "cache_write_1h": 4.0, "cache_read": 0.1}, "claude-haiku-5-5": {"input": 0.1, "output": 0.5, "cache_write_5m": 0.125, "cache_write_1h": 0.2, "cache_read": 0.01}},
`price_band` [0.95, 1.05], `resumes_per_move` 3, `stops_per_hold` 3, `park_steps` [50, 100, 200],
`queue_cap` 4 (locked), `task_wall_s` 5400, `audit_every` 5 (locked), `score_every_landings` 3, `score_every_s` 7200,
`retry_backoff_s` 1800, `backoff_cap_s` 28800, `alarm_s` 21600, `power_settle_s` 60, `battery_runs` true,
`battery_floor_pct` 20, `oracle_audit_k` 8, `oracle_background` false, `measure_background` false, `lock_wait_s` 3600,
`score_loss_band` 0.02, `judge_n` 10, `judge_lines` 150, `judge_recall` 0.8, `judge_approval` 0.5, `judge_per_tick` 4,
`wall_factor` 3, `case_min_s` 900, `case_factor` 20, `watch_s` 5, `compare_module_s` 10, `kaimon_port` 2840,
`kaimon_http_s` 120, `kaimon_start_s` 900, `session_warm_s` 1800, `p_idle` 85, `e_idle` 60, `probe_s` 15,
`swapins_max` 2000, `decompressions_max` 400000, `near_band` 0.85, `near_band_step` 5, `d14_backoff_s` 1200,
`d14_share` [10, 0.6], `other_tries` 3, `ship_kill_s` 3600, `watch_stale_s` 600, `disk_free_gb` 20,
`file_cap_bytes` 4294967296, `cases_cap_bytes` 268435456, `answer_cap_bytes` 16777216, `fetch_tries` [5, 3, 4],
`tail_chunk` 6, `base_keep_s` 172800, `fixfirst_lines` 3, `fixfirst_max_landings` 6, `src_unverified_max` 6,
`src_shape_checks_min` 2, `src_prior_g` {"src": 11.0, "outside": 10.7}, `src_prior_start_g` 375,
`src_prior_load_s` {"src": 17, "outside": 0}, `src_prior_ratchet_s` 89, `src_prior_imbalance_s` 9,
`src_margin_min_s` 10, `src_margin_checks` 10, `src_margin_start_s` 25, `src_margin_max_s` 40, `pkg_wall_s` 1800,
`kinds_wall_s` 1800, `admissible_wall_s` 600, `parse_wall_s` 300, `loader_wall_s` 600, `proxy_in_flight` 1,
`proxy_body_bytes` 33554432, `proxy_request_s` 1200, `proxy_join_s` 30, `git_low_speed` [1000, 60],
`loop_stale_s` {"scoreboard": 1800, "lander": 1800, "climb": 1800},
`role_wait_s` {"slot": 10800, "review": 10800, "measure": 49800, "score": 49800, "land": 5400, "deps": 3600},
`state_lock_s` 600, `step_wall_s` 60, `tree_wall_s` 600, `kaimon_poll_s` 30, `kaimon_ping_s` 10,
`poll_s` {"kaimon_up": 5, "scan": 10, "lock": 5, "landing_lock": 20, "yield": 2, "land_job": 5},
`land_outs` {"files": 32, "file_bytes": 67108864, "total_bytes": 134217728}, `term_grace_s` 30, `spend_window_days` 8,
`stops_keep_s` 86400.
<!-- defaults:end -->
