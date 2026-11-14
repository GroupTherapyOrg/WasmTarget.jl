# test/climb_l228.py — L228's behaviour (spec v17 Z6, the round-14 architect's finding 7): the climb's landing-check code
# of a tree (its dev/climb and dev/src_verdict.sh) CALLED on a scratch repository and state with planted measured
# checks, a planted score record and planted shard records, and what each call returns asserted. It prints one line a
# fault and nothing when every behaviour holds; test/parity_ratchet.jl's L228 runs it on the repository's tree, and its
# negative runs it on copies with one behaviour broken each, every one of which must print a fault.
#   python3 -I test/climb_l228.py <tree root>
import contextlib, json, os, subprocess, sys, tempfile, base64

root = os.path.abspath(sys.argv[1])
faults = []
def fault(why):
    faults.append(why)

tmp = tempfile.mkdtemp(prefix="l228-")
repo, state, locks = f"{tmp}/repo", f"{tmp}/state", f"{tmp}/locks"
for d in (repo, state, locks):
    os.makedirs(d)
g = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout.strip()
# the scratch repository: test files of known sizes, a check.sh naming the shards and D14's band, a src file
FILES = [f"t{i:02d}.jl" for i in range(12)]
os.makedirs(f"{repo}/test/src"); os.makedirs(f"{repo}/dev"); os.makedirs(f"{repo}/src")
for i, f in enumerate(FILES):
    open(f"{repo}/test/src/{f}", "w").write(f"# {f}\n" + "x" * (100 + 10 * i) + "\n")
open(f"{repo}/dev/check.sh", "w").write("SHARDS=5\nD14_RED=140\n")
open(f"{repo}/src/x.jl", "w").write("x = 1\n")
g("init", "-q"); g("config", "user.email", "l228@scratch"); g("config", "user.name", "l228")
g("add", "-A"); g("commit", "-q", "-m", "origin")
h = g("rev-parse", "HEAD")
open(f"{repo}/src/x.jl", "a").write("y = 2\n"); open(f"{repo}/test/src/t00.jl", "a").write("# the move's own\n")
g("add", "-A"); g("commit", "-q", "-m", "the move")
sha = g("rev-parse", "HEAD")
# the tree's driver runs from inside the scratch repository (core resolves git and its root from its own file's place),
# untracked, so the commits above are the repository's only history
import shutil
shutil.copytree(f"{root}/dev/climb", f"{repo}/dev/climb", ignore=shutil.ignore_patterns("__pycache__"))
os.environ["WT_CLIMB_STATE"] = state
os.chdir(repo); sys.path.insert(0, f"{repo}/dev/climb")
import door
door.LOCKS = locks
import core, measure as M, lander as L

# the score's record at h (each file 100 G, the warm-up 350 G) and the measured checks of both shapes: twelve landed
# checks a shape, predicted before they ran, their positive errors known
open(f"{state}/src-{h[:8]}.tsv", "w").write(f"head\t{h}\twarm\t350\n" + "".join(f"{f}\tpassed\t100.0\t0.0\t\n" for f in FILES))
open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h}))
ERRS = {True: [9.0, 6.0, -12.0, 2.0, 1.0, -3.0, 0.5, 4.0, 3.0, -1.0, 5.0, 2.5], False: [7.0, 3.0, -9.0, 1.0, 2.0, 0.0, 1.5, -2.0, 2.0, 1.0, 0.5, 4.5]}
with open(f"{state}/events.jsonl", "w") as ev:
    for shape in (True, False):
        for i, er in enumerate(ERRS[shape]):
            ev.write(json.dumps({"t": f"2026-11-12T{i:02d}:00:0{int(shape)}", "kind": "ship", "result": "LANDED:x", "check": 0,
                                 "path": round(100 + er, 1), "src_set": {"src_change": shape, "ran_cost": 1000.0, "predicted": {"path": 100.0}},
                                 "split": {"load": [17 if shape else 0, 200, 0, 0], "ratchet": [79, 400, 0, 0],
                                           "shards": [[80, 650, 0, 0]] * 5, "starts": [375.0] * 5},
                                 "probe": {"quiet": {"start": True, "end": True}}}) + "\n")
c = core.cfg()
def expect_margin(shape):
    pos = sorted((e for e in ERRS[shape][-c["src_margin_checks"]:] if e > 0), reverse=True)
    return min(c["src_margin_max_s"], max(c["src_margin_min_s"], round(3 * (pos[1] if len(pos) > 1 else 0.0), 1)))

# 1. src_target: D14's band less three times the second-largest positive error of the shape's last landed checks
for shape in (True, False):
    t, info = M.src_target(140, shape)
    if abs(t - (140 - expect_margin(shape))) > 0.05:
        fault(f"src_target(140, {shape}) returns {t}, where D14's band less the measured margin is {140 - expect_margin(shape)}")

# 2. src_set: the move's own file, a share of the ring under src_target's target, its prediction within it
ss = M.src_set(h, sha, None)
want_t = 140 - expect_margin(True)
if ss.get("why"):
    fault(f"src_set made no set: {ss['why'][:200]}")
else:
    files = M.src_handed(ss, h, sha)
    if "t00.jl" not in ss.get("own", []):
        fault("src_set leaves out the move's own test file")
    if ss.get("target") != want_t:
        fault(f"src_set cuts its share to {ss.get('target')}, not src_target's {want_t}")
    if not ss.get("share"):
        fault("src_set takes no file of the ring though files fit its target")
    if (ss.get("predicted") or {}).get("path", 1e9) > want_t:
        fault(f"src_set's set predicts {(ss.get('predicted') or {}).get('path')} s, past the target {want_t}")
    if not set(files) <= set(FILES):
        fault("src_set hands a file the commit does not hold")

# 3. the lander's record reading: exactly the set, or no verified record
item = {"hold": "l228", "hold_id": "l228", "branch": "ready/l228"}
if L.verified_rows(item, {"t00.jl": "passed"}, ["t00.jl", "t01.jl"]) is not None:
    fault("the lander verifies records that miss a file of the set handed")
if L.verified_rows(item, {"t00.jl": "passed", "t01.jl": "failed"}, ["t00.jl", "t01.jl"]) != ["t00.jl"]:
    fault("the lander's verified record is not the files the records report green")
if L.verified_rows(item, {"t00.jl": "passed", "t09.jl": "passed"}, ["t00.jl"]) is not None:
    fault("the lander verifies records that name a file outside the set handed")

# 4. the origin-red rule: a red outside the move's own that origin reads red is origin's (uncharged), else the move's
@contextlib.contextmanager
def no_slot(kind, first=False):
    yield
L.julia_slot = no_slot
L.src_locate = lambda red, head, role="score": {f: "filed" for f in red}
L.git = lambda *a, **k: h if a[:2] == ("rev-parse", f"origin/{core.MARCH}") else core.git(*a, **k)
ss4 = {"own": ["t00.jl"], "ran": ["t00.jl", "t01.jl"]}
L.src_red_at = lambda fs, at, task, role="score": {f: ("failed", "red at origin") for f in fs}
if L.origin_red(item, None, ss4, {"t00.jl": "passed", "t01.jl": "failed"}) is not True:
    fault("an innocent move is charged for a file red at origin's head (R3)")
L.src_red_at = lambda fs, at, task, role="score": {f: ("passed", "") for f in fs}
# spec v18 Q3: one rule for what does not reproduce at origin's head: the item's first such red checks it again,
# uncharged; the same red on its second check is the move's own
if L.origin_red(item, None, ss4, {"t00.jl": "passed", "t01.jl": "failed"}) is not True:
    fault("a red that origin's head reads green stops the move at its first occurrence (spec v18 Q3)")
if L.origin_red(dict(item, rechecked=True), None, ss4, {"t00.jl": "passed", "t01.jl": "failed"}) is not False:
    fault("a red that origin's head reads green, again on the move's second check, is not the move's own")
if L.origin_red(item, None, ss4, {"t00.jl": "failed"}) is not False:
    fault("a red of the move's own file is not the move's own")

# 5. dev/src_verdict.sh: exactly the set; a known red at its own listed failing tests, a new failure beside them; a void
def verdict(setlines, *shards):
    d = tempfile.mkdtemp(dir=tmp)
    open(f"{d}/set", "w").write("# head x\n" + "".join(l + "\n" for l in setlines))
    args = []
    for k, (rc, rec) in enumerate(shards):
        open(f"{d}/r{k}", "w").write(rec); args += [str(rc), f"{d}/r{k}"]
    return subprocess.run(["bash", f"{root}/dev/src_verdict.sh", f"{d}/set", *args], capture_output=True, text=True).returncode
row = lambda f, o, why="", c="passed": f"started\t{f}\nrow\t{f}\t{o}\t1\t{base64.b64encode(why.encode()).decode()}\t{c}\n"
canary = "started\t~canary\nrow\t~canary\tpassed\t0\t\n"
W = "test/src/t01.jl:3 test: f(1) == 2"
if verdict(["t00.jl", "t01.jl"], (0, row("t00.jl", "passed") + canary)) != 1:
    fault("dev/src_verdict.sh stands a check in which a file of the set has no row")
if verdict(["t00.jl", "# known t01.jl\ttest/src/t01.jl:3 test", "t01.jl"], (1, row("t00.jl", "passed") + row("t01.jl", "failed", W) + canary)) != 0:
    fault("dev/src_verdict.sh reads a known red at its own first failing test as the change's red")
W2 = W + "\ntest/src/t01.jl:40 test: g(1) == 3"
if verdict(["t00.jl", "# known t01.jl\ttest/src/t01.jl:3 test", "t01.jl"], (1, row("t00.jl", "passed") + row("t01.jl", "failed", W2) + canary)) != 14:
    fault("dev/src_verdict.sh reads a new failure in a known red's file as the known red's (spec v18 Q1)")
W3 = W + "\ntest/src/t01.jl:3 test: f(2) == 3"   # a second failure at the line the known red lists (a looped @test)
if verdict(["t00.jl", "# known t01.jl\ttest/src/t01.jl:3 test", "t01.jl"], (1, row("t00.jl", "passed") + row("t01.jl", "failed", W3) + canary)) != 14:
    fault("dev/src_verdict.sh reads a second failure at a known red's line as the known red's (spec v19 Q1: a multiset)")
if verdict(["t00.jl", "t01.jl"], (1, row("t00.jl", "passed") + row("t01.jl", "failed", W) + canary)) != 14:
    fault("dev/src_verdict.sh does not read a new red as red on test files")
if verdict(["t00.jl", "t01.jl"], (0, row("t00.jl", "passed") + row("t01.jl", "passed", c="failed:eA==") + canary)) != 15:
    fault("dev/src_verdict.sh does not void a process whose canary run as a file read wrong")
forged = "started\tt00.jl\nstarted\tt01.jl\nrow\tt01.jl\tpassed\t0\t\tpassed\nrow\tt00.jl\tpassed\t1\t\tpassed\n"
if verdict(["t00.jl", "t01.jl"], (0, forged + canary)) != 15:
    fault("dev/src_verdict.sh stands records whose block grammar is broken (a file writing a sibling's row, spec v18 Q3)")
if verdict(["t00.jl", "t01.jl"], (0, row("t00.jl", "passed") + canary + row("t01.jl", "passed"))) != 15:
    fault("dev/src_verdict.sh stands a file's block written after the canary's row (spec v19 Q2)")
if verdict(["t00.jl"], (1, row("t00.jl", "passed") + canary)) != 15:
    fault("dev/src_verdict.sh does not read a void process (exit 1, every row passed) as void")

# 6. no landing check waits for a quiet machine (throughput P0, the owner's "STOP pausing EVER"): lander._land starts
# the check whatever its probe reads; D14's band judges a check only when the machine was quiet at its start and its
# end (lander.quiet, the probe and the power reading stood in), dev/d14_judge.sh asking the lander when the check read
# red on the band alone; a check not quiet at either end lands on correctness alone and its time is unjudged, moving
# neither the margin nor checks_measured. dev/ship.sh is a stand-in keeping its contract (its result and verdict files,
# the judge called on the check's status as ship.sh calls it); the judge is this tree's. door.reap, the one door action
# _land takes, is stood in: nothing here reaches a build user
import contextlib as _cl
busy6 = {"p_idle": 10.0, "e_idle": 10.0, "pressure": 1, "swapins": 0, "decompressions": 0}
quiet6 = {"p_idle": 99.0, "e_idle": 99.0, "pressure": 1, "swapins": 0, "decompressions": 0}
slot6 = f"{tmp}/slot6"; os.makedirs(f"{slot6}/.wtd")
shutil.copy(f"{root}/dev/d14_judge.sh", f"{tmp}/d14_judge.sh")
open(f"{slot6}/.wtd/ship.lander.sh", "w").write(
    'printf "%s %s\\n" "$FAKE_CRC" "$FAKE_PATH" > "$WT_CHECK_RESULT"\n'
    f'rc=$(bash "{tmp}/d14_judge.sh" "$FAKE_CRC")\n'
    'case "$rc" in 0) echo "LANDED $WT_SHIP_EXPECT" > "$WT_SHIP_RESULT" ;; 10) echo "D14 $FAKE_PATH" > "$WT_SHIP_RESULT" ;;\n'
    '  14) echo "OWN tests" > "$WT_SHIP_RESULT" ;; *) echo "OTHER check-$rc" > "$WT_SHIP_RESULT" ;; esac\n')
real6 = {"probe": L.probe, "ship_cmd": L.ship_cmd, "reap": door.reap}
def land6(crc, path, readings, power=(True, False, 90)):
    """_land with the check's status `crc` and path, the probe reading `readings` in turn, the power reading `power`:
    (kind, D14 verdict, the probe record)."""
    seq = iter(readings)
    L.probe = lambda: dict(next(seq))   # a fresh reading each probe, as probe() returns
    L.ship_cmd = lambda slot: ["bash", f"{slot6}/.wtd/ship.lander.sh"]
    door.reap = lambda *a, **k: None
    core.POWER[0], core.POWER[1], core.POWER[2] = (lambda: power), 0.0, None
    with _cl.suppress(FileNotFoundError):
        os.remove(f"{state}/power.json")
    c6 = dict(core.cfg(), poll_s=dict(core.cfg()["poll_s"], scan=1))
    old = {k: os.environ.get(k) for k in ("FAKE_CRC", "FAKE_PATH")}
    os.environ.update(FAKE_CRC=str(crc), FAKE_PATH=str(path))
    try:
        pr, result, verdict, _ = L._land(slot6, {"rebased": {"commit": sha}, "hold": "p0-6"}, c6, lambda: None)
    finally:
        for k, v in old.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    return result[0], L.d14_verdict(pr, result[0], verdict[0]), pr
try:
    g("update-ref", "refs/remotes/origin/wt2", h)   # d14_red() reads origin's dev/check.sh
    for what, crc, path, readings, power, want in (
            ("a busy start, its tests green, 190 s", 10, 190, [busy6, busy6], (True, False, 90), ("LANDED", "unjudged")),
            ("quiet at its start and its end, 150 s", 10, 150, [quiet6, quiet6], (True, False, 90), ("D14", "red")),
            ("a busy start, one test failing", 14, 90, [busy6, busy6], (True, False, 90), ("OWN", None)),
            ("in Low Power Mode on battery, the cores idle, 170 s", 10, 170, [quiet6, quiet6], (False, True, 80), ("LANDED", "unjudged"))):
        kind6, v6, pr6 = land6(crc, path, readings, power)
        if (kind6, v6) != want:
            fault(f"a landing check {what}: {kind6}, D14 {v6}, quiet {pr6.get('quiet')}; want {want[0]}, D14 {want[1]} (throughput P0)")
    # an unjudged check never moves the margin, nor the measured checks
    before6, measured6 = M.src_target(140, False), len(M.checks_measured())
    kind6, v6, pr6 = land6(10, 200, [busy6, busy6])
    L.ship_event({"hold": "p0-6"}, pr6, kind6, sha, 10, 200.0, "", split={"load": [0, 200, 0, 0], "ratchet": [79, 400, 0, 0],
                 "shards": [[80, 650, 0, 0]] * 5, "starts": [375.0] * 5},
                 src_set_={"src_change": False, "ran_cost": 1000.0, "predicted": {"path": 100.0}})
    if M.src_target(140, False) != before6 or len(M.checks_measured()) != measured6:
        fault(f"an unjudged landing check moved the margin or the measured checks: {before6} -> {M.src_target(140, False)}, "
              f"{measured6} -> {len(M.checks_measured())} measured")
except Exception as e:
    fault(f"the landing check without a quiet gate raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.probe, L.ship_cmd, door.reap = real6["probe"], real6["ship_cmd"], real6["reap"]
    with _cl.suppress(Exception):
        g("update-ref", "-d", "refs/remotes/origin/wt2")

# 7. the lander's rebased check (the judge5 re-check's S1, the judge6a re-check's F1, F2): every label the rebased
# candidate changes, and every case of origin's the table lacks, is judged against origin's own row of the round, so a
# pass the move loses is G2 whatever judge the table's row carries; a table label origin's corpus no longer registers is
# the move's own; and a fault of the driver's judging an item is bounded, the round going on to the next item.
# lander.rebased_check(item) is CALLED for a move whose base origin moved past: measure_candidate, confirmed,
# regressions and judge_move real; what measures (rebased, smoke, measure_base) or reaches the door stubbed
open(f"{repo}/src/z.jl", "w").write("z = 3\n")
g("checkout", "-q", "-b", "origin6", h); g("add", "src/z.jl"); g("commit", "-q", "-m", "origin moved"); h6 = g("rev-parse", "HEAD")
g("checkout", "-q", "-")
L.git = lambda *a, **k: h6 if a[:2] == ("rev-parse", f"origin/{core.MARCH}") else core.git(*a, **k)
os.makedirs(f"{state}/deltas", exist_ok=True)
J0, J1, A6 = "1" * 40, "2" * 40, "a" * 40
rec6 = {}
M.julia_slot = no_slot
M.rebased = lambda b, s, onto: ("c" * 40, None)
M.advance = lambda rows, at, why: rec6.setdefault("advanced", []).extend(r[0] for r in rows)
M.file_g2 = lambda lost, at: None
L.stratified = lambda: set()
L.unqueue = lambda it, **kw: rec6.setdefault("unqueued", []).append(kw)
L.drop = lambda it, outcome, note, stop=True: rec6.setdefault("dropped", []).append((outcome, stop))
def rebased6(table_rows, origin_rows, cand_rows, corpus):
    rec6.clear()
    L.table = lambda: {l: (M.Row(r, (A6, j)), 1) for l, (r, j) in table_rows.items()}
    M.labels_at = lambda at, overlay=None: set(corpus)
    M.measure_base = lambda at, diff, locked_=False: {l: M.Row(origin_rows[l], (A6, J1)) for l in diff if l in origin_rows}
    M.smoke = lambda role, labels, task, at, known=None, keep=None, **k: ({l: M.Row(r, (A6, J1)) for l, r in cand_rows.items()}, None)
    item6 = {"kind": "move", "base": h, "sha": sha, "hold": "l228-6", "hold_id": "l2286", "labels": sorted(cand_rows)}
    return L.rebased_check(item6)
P, U = lambda l: (l, "passed", 1.0, ""), lambda l: (l, "unported", 1.0, "unported: the dart definition x")
bad6, _ = rebased6({"g/a": (P("g/a"), J0)}, {"g/a": P("g/a")}, {"g/a": U("g/a")}, {"g/a"})
if not any(p.startswith("G2 lost g/a") for p in bad6):
    fault("a rebased move's loss of a pass to unported lands when the table's row is of another judge (judge5 S1)")
bad6, _ = rebased6({}, {"g/b": P("g/b")}, {"g/b": U("g/b")}, {"g/b"})
if not any(p.startswith("G2 lost g/b") for p in bad6):
    fault("a rebased move's loss of origin's pass the table lacks (a hand landing's case) lands (judge6a F2)")
try:
    bad6, _ = rebased6({"g/c": (P("g/c"), J1)}, {}, {"g/c": U("g/c")}, set())
    if bad6 or not any("rebased" in kw for kw in rec6.get("unqueued", [])):
        fault(f"a table label origin's corpus dropped, which the move adds back, is not judged as the move's new case: {bad6}")
except Exception as e:
    fault(f"a table label origin's corpus dropped, which the move adds back, raises out of the rebased check (judge6a F1): {e!r}")
# the bounded item rule: the driver's fault judging an item, other_tries times, is a drop uncharged, never a raise
rec6.clear()
itm = {"hold": "l228-6", "hold_id": "l2286", "sha": sha, "branch": "ready/l2286"}
for n in range(core.cfg()["other_tries"]):
    L.item_error(dict(itm, errors=n), core.ClimbError("planted: a re-measure wrote no row"))
if rec6.get("dropped") != [("landing-failed", False)] or len(rec6.get("unqueued", [])) != core.cfg()["other_tries"] - 1:
    fault(f"the lander's bound on a driver fault judging an item is not other_tries faults then a drop uncharged: {rec6}")
landsrc = open(f"{repo}/dev/climb/lander.py").read()
if len(__import__("re").findall(r"(?<!def )item_error\(item, e\)", landsrc)) < 4:   # its four call sites, not its def
    fault("the lander's round leaves a step before its landing (item_problems, admissible, rebased_check, landing_set) "
          "whose fault aborts every round with the items behind it waiting")

# 8. the shapes' charge (the judge5 re-check's S2; the judge6a re-check's F3, F4): a record the shapes' program refuses
# is the move's only when the refusal names one of the measured corpus's added labels and the stored answers read alone;
# a stored record refused, or a run ended without a refusal (a kill), is OracleGap, never charged; a git failure choosing
# the program is OracleGap, and a judge without test/oracle_read.jl gets the first program on origin's history.
# measure.shapes_of and shapes_judge CALLED; the program's run (shapes_run, the door's) stubbed by a stand-in that
# refuses a block holding `zz` with the program's own words, or is killed on demand
def blk(l, v="1"):
    return (f"answer\t{l}\tx\t-\t-\t-\tbits,x,{v}\tk\tk\t-\n").encode()
runs7, judge7 = [], M.shapes_judge   # the real one, kept for its own checks below
def stand_in(role, task, js_at, answers, kill=False):
    runs7.append(answers.count(b"answer\t"))
    if kill and len(runs7) == 1:
        return None, "signal (9): Killed: 9"
    bad = [l for l, b in M.unit_blocks(answers).items() if b"zz" in b]
    return (None, f"ERROR: LoadError: test/oracle_read.jl: {len(bad)} answer(s) this judge does not read, e.g. {sorted(bad)[0]}: "
                  "its answer record does not read") if bad else (b"shape\n", "")
def charge7(stored, added, kill=False):
    runs7.clear()
    M.shapes_run = lambda role, task, js_at, answers: stand_in(role, task, js_at, answers, kill)
    M.shapes_judge = lambda s_: "f" * 40
    try:
        shapes, why = M.shapes_of("measure", "t", "e" * 40, stored, added)
        return "charged" if shapes is None else "shapes", why or ""
    except M.OracleGap as e:
        return "gap", str(e)
good7 = blk("g/s1") + blk("g/s2")
if charge7(good7, blk("g/m1") + blk("g/m2", "zz"))[:1] != ("charged",) or "g/m2" not in charge7(good7, blk("g/m1") + blk("g/m2", "zz"))[1]:
    fault("a move's own added answer the shapes' program refuses is not charged to the move, naming it (judge5 S2)")
if charge7(blk("g/s1") + blk("g/s2", "zz"), blk("g/m1"))[0] != "gap":
    fault("a stored answer the shapes' program refuses is charged to the move (judge5 S2)")
if charge7(good7, blk("g/m1"), kill=True)[0] != "gap":
    fault("a healthy move is charged when the shapes' program's first run is killed without a refusal (judge6a F4)")
if charge7(good7, blk("g/m1"))[0] != "shapes" or runs7 != [3]:
    fault("an answer set the program reads costs more than one run, or reads as no shapes")
try:
    judge7("0" * 40)
    fault("shapes_judge of a sha that is no commit answers, where git failed (judge6a F3)")
except M.OracleGap:
    pass
except Exception as e:
    fault(f"shapes_judge of a sha that is no commit raises {type(e).__name__}, not OracleGap (judge6a F3)")
open(f"{repo}/test/oracle_read.jl", "w").write("# the first shapes' program\n" + M.SHAPES_PROGRAM + "\n")
g("checkout", "-q", "-b", "origin7", h); g("add", "test/oracle_read.jl"); g("commit", "-q", "-m", "the program"); h7 = g("rev-parse", "HEAD")
g("update-ref", f"refs/remotes/origin/{core.MARCH}", h7); g("checkout", "-q", "-")
try:
    if judge7(h) != h7:
        fault("a judge without test/oracle_read.jl does not get the first shapes' program on origin's history (judge6a F3)")
except Exception as e:
    fault(f"a judge without test/oracle_read.jl raises {type(e).__name__} instead of getting the first program (judge6a F3)")

for f in faults:
    print(f)
