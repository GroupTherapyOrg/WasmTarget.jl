# test/climb_l228.py — L228's behaviour (spec v17 Z6, the round-14 architect's finding 7): the climb's landing-check code
# of a tree (its dev/climb and dev/src_verdict.sh) CALLED on a scratch repository and state with planted measured
# checks, a planted score record and planted shard records, and what each call returns asserted. It prints one line a
# fault and nothing when every behaviour holds; test/parity_ratchet.jl's L228 runs it on the repository's tree, and its
# negative runs it on copies with one behaviour broken each, every one of which must print a fault.
#   python3 -I test/climb_l228.py <tree root> [--only <section>]
#
# THE RUNNER (the owner's rule since 2026-10: no hang, ever; a stage has a hard limit that names the case): this file is
# a prologue and numbered sections (`# <n>. ...`). The runner runs each section in a child process of its own (the
# prologue, the sections its `#: needs` line names, then itself), under a hard limit (`#: limit <s>`, else
# SECTION_LIMIT_S), killed with its process group past it; a section past its limit, or one that exits other than 0, is
# a fault naming it, never a wait. A child's output goes to files, never a pipe, so nothing it starts can hold the
# caller's pipe open. `--only <n>` runs that section alone: a planted break names its section (test/parity_ratchet.jl's
# BOUNDED_BREAKS), and the lock's negative runs only it on its copy, so the negative costs the breaks' sections, never
# (breaks) x (the harness). A section that waits by design (a lock, a backoff, a poll) takes its wait from an injected
# clock or a limit of its own under test, so its time stays in seconds.
import contextlib, json, os, re, signal, subprocess, sys, tempfile, time, base64

SECTION_LIMIT_S = 60   # a section's hard limit: intent, every section in seconds (the longest about 8 s on 2026-11-14,
                       # at background QoS); band 30-120: past it the section is a fault naming it, a hang or a blow-up
SECTIONS_AT_ONCE = 4   # sections run at once: intent, the harness in about its longest section's time; band 1-4, the
                       # machine's four performance cores (a section is mostly a wait, a child about 50 MB)
# the runner's own negative (test/parity_ratchet.jl) sets WT_L228_LIMIT_S to a few seconds, so a planted hang costs its
# limit and no more
LIMIT_OVERRIDE = os.environ.get("WT_L228_LIMIT_S")

def _chunks(src):
    """(the prologue, {n: (its text, needs, limit)}): the prologue runs from `root = ...` to the first section; each
    section from its `# <n>. ` line to the next or to the end."""
    body = src[src.index("\nroot = ") + 1:]
    marks = list(re.finditer(r"^# (\d+)\. ", body, re.M))
    secs = {}
    for i, m in enumerate(marks):
        text = body[m.start():marks[i + 1].start() if i + 1 < len(marks) else len(body)]
        needs = [int(x) for x in re.findall(r"\d+", (re.search(r"^#: needs ([\d, ]+)", text, re.M) or [None, ""])[1])]
        lim = re.search(r"^#: limit (\d+)", text, re.M)
        secs[int(m.group(1))] = (text, needs, int(lim.group(1)) if lim else SECTION_LIMIT_S)
    return body[:marks[0].start()], secs

if __name__ == "__main__" and "--section" not in sys.argv:   # the runner
    _src = open(os.path.abspath(__file__)).read()
    _pro, _secs = _chunks(_src)
    _only = int(sys.argv[sys.argv.index("--only") + 1]) if "--only" in sys.argv else None
    if _only is not None and _only not in _secs:
        print(f"climb_l228: no section {_only}"); sys.exit(0)
    def _run(_n):   # one section's child: (its fault lines, its seconds)
        _out = []
        _lim, _t0 = min(_secs[_n][2], int(LIMIT_OVERRIDE)) if LIMIT_OVERRIDE else _secs[_n][2], time.time()
        with tempfile.TemporaryDirectory(prefix="l228-run-") as _d:
            with open(f"{_d}/out", "wb") as _o, open(f"{_d}/err", "wb") as _e:
                _p = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), sys.argv[1], "--section", str(_n)],
                                      stdin=subprocess.DEVNULL, stdout=_o, stderr=_e, start_new_session=True)
                try:
                    _rc = _p.wait(timeout=_lim)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(_p.pid, signal.SIGKILL)
                    _p.wait()
                    _rc = None
            _lines = [l for l in open(f"{_d}/out", errors="replace").read().splitlines() if l.strip()]
            _err = open(f"{_d}/err", errors="replace").read()
        if _rc is None:
            _out.append(f"section {_n} passed its limit of {_lim} s (a hang or a blow-up, never a result): "
                        f"{(_lines[-1] if _lines else _err.strip()[-200:]) or 'no output'}")
        elif _rc != 0:
            _out.append(f"section {_n} exited {_rc}: {_err.strip()[-300:]}")
        _out += _lines
        return _out, time.time() - _t0
    # SECTIONS_AT_ONCE children at a time (each has a scratch repository and state of its own; most of a section's time
    # is a wait on a process or a poll), their lines printed in the sections' order
    import concurrent.futures as _cf
    with _cf.ThreadPoolExecutor(max_workers=SECTIONS_AT_ONCE) as _ex:
        _res = dict(zip(_order := sorted(_secs) if _only is None else [_only], _ex.map(_run, _order)))
    for _n in _order:
        if os.environ.get("WT_L228_TIMES"):
            print(f"# section {_n}: {_res[_n][1]:.1f} s", file=sys.stderr)
        for _l in _res[_n][0]:
            print(_l)
    sys.exit(0)

_n = int(sys.argv[sys.argv.index("--section") + 1])   # a child: the prologue, the sections it needs, then itself
_pro, _secs = _chunks(open(os.path.abspath(__file__)).read())
_g = {"__name__": "__l228_section__", "__file__": os.path.abspath(__file__)}
exec(compile("import contextlib, json, os, re, signal, subprocess, sys, tempfile, time, base64\n" + _pro + "".join(_secs[k][0] for k in _secs[_n][1]) + _secs[_n][0] +
             "\nfor f in faults:\n    print(f)\n", f"climb_l228 section {_n}", "exec"), _g)
sys.exit(0)

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
measure_base9 = M.measure_base   # the real one: section 7 stands it in and leaves it so; section 9 calls it

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
#: needs 3
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
    c6 = dict(core.cfg(), poll_s=dict(core.cfg()["poll_s"], scan=0.05))   # the lander's poll injected tiny: a wait by design
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
#: needs 3, 4
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

# 9. a landed head's base seeded from its own landing's rows (throughput T3(i), measure.seed_base): nothing when the
# rows were measured on another tree or by a driver whose dev/climb is not the head's, no row of another judge; the
# seeded rows read by measure_base with no measurement; a base measured while a seed writes keeps both (base_write);
# and a candidate judged against the seeded rows (measure.regressions): a regression outside the hold refused, a case
# already broken at the base not charged
real_smoke9, real_tree9 = M.smoke, M.driver_tree
try:
    os.makedirs(f"{repo}/dev/climb", exist_ok=True)
    open(f"{repo}/dev/climb/marker9", "w").write("driver 1\n"); g("add", "-f", "dev/climb/marker9"); g("commit", "-qm", "c1")
    c1 = g("rev-parse", "HEAD")
    open(f"{repo}/dev/climb/marker9", "w").write("driver 2\n"); g("commit", "-qam", "c2")
    c2 = g("rev-parse", "HEAD")
    jid9 = M.judge_id(c1)
    mk9 = lambda l, o, j=jid9: M.Row((l, o, 1.0, ""), ("a" * 40, j))
    rows9 = [mk9("n/a", "passed"), mk9("n/b", "errored"), mk9("n/c", "passed", "f" * 40)]
    M.driver_tree = lambda: g("rev-parse", "c1:dev/climb".replace("c1", c1))   # the driver measuring is c1's
    path9 = M.base_path(c1, M.driver_tree())   # measure_base's file of c1
    for what, measured, driver in (("by a driver whose dev/climb is not the head's", c1, c2), ("on a tree not the landed one", c2, c1)):
        n9, why9 = M.seed_base(c1, rows9, measured, driver)
        if n9 or os.path.exists(path9):
            fault(f"seed_base took rows measured {what}: {n9} seeded ({why9})")
    n9, why9 = M.seed_base(c1, rows9, c1, c1)
    if n9 != 2:
        fault(f"seed_base from the landed tree and its own driver seeded {n9} rows, not the two of its judge ({why9})")
    asked9 = []
    def smoke9(role, only, task, sha_, **kw):   # a measurement during which the landing's seed writes another row
        asked9.append(set(only))
        M.seed_base(c1, [mk9("n/d", "passed")], c1, c1)
        return {l: mk9(l, "passed") for l in only}, None
    M.smoke = smoke9
    before9 = measure_base9(c1, {"n/a", "n/b"}, locked_=True)
    if asked9 or set(before9) != {"n/a", "n/b"}:
        fault(f"measure_base at a seeded head measured {asked9} for rows the seed holds, or read {sorted(before9)}")
    measure_base9(c1, {"n/a", "n/e"}, locked_=True)   # n/e measured while the seed writes n/d
    on9 = {r[0] for r in M.read_cases(path9)}
    if not {"n/a", "n/b", "n/d", "n/e"} <= on9:
        fault(f"a base measured while a seed wrote kept {sorted(on9)}: the measurement's and the seed's rows both belong")
    h9 = {"key": "k9", "cases": ["x/y"]}
    after9 = {"n/a": mk9("n/a", "wrong"), "n/b": mk9("n/b", "errored")}
    probs9 = M.regressions(h9, {"n/a", "n/b"}, before9, after9)
    if not any("n/a" in p_ for p_ in probs9) or any("n/b" in p_ for p_ in probs9):
        fault(f"a candidate judged against a seeded base: {probs9} (n/a, passing at the base, must be refused; n/b, broken there, not charged)")
except Exception as e:
    fault(f"the base's seed raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.smoke, M.driver_tree = real_smoke9, real_tree9

# 10. a driver fault's backoff ends when the driver's code changes (core.running): the lander's loop, guarded, waits
# out a fault of its driver only while the driver is the tree that faulted; under a new driver the wait is over and a
# repeat counts from one; a backoff that is not a driver fault (D14's, fixed seconds) waits whatever the driver. The
# driver's tree is stood in (core.driver_tree); the loop is core.guarded itself
real_tree10 = core.driver_tree
try:
    def fault10():
        raise core.ClimbError("planted: a fault of the driver's code")
    core.driver_tree = lambda: "1" * 40
    if core.guarded("lander", fault10) != 3 or not core.waits("lander"):
        fault("a driver fault of the lander's round did not back the lander off")
    core.guarded("lander", fault10)
    n10 = core.state_json("backoff.json", {}).get("lander", {}).get("n")
    core.driver_tree = lambda: "2" * 40   # a landing changed dev/climb
    if core.waits("lander"):
        fault("the lander waits out a fault of a driver it no longer runs (a landing changed dev/climb)")
    core.guarded("lander", fault10)
    if n10 != 2 or core.state_json("backoff.json", {}).get("lander", {}).get("n") != 1 or not core.waits("lander"):
        fault(f"a driver fault under a new driver does not back off from one: n {n10} then "
              f"{core.state_json('backoff.json', {}).get('lander', {}).get('n')}")
    core.recovered("lander")
    core.back_off("lander", "d14", why="D14", secs=600, note_at=0)
    core.driver_tree = lambda: "3" * 40
    if not core.waits("lander"):
        fault("a D14 backoff, which is no driver fault, ended when the driver changed")
    core.recovered("lander", "d14")
except Exception as e:
    fault(f"the driver fault's backoff raised {type(e).__name__}: {str(e)[:240]}")
finally:
    core.driver_tree = real_tree10

# 11. a move's base costs nothing when it can (throughput T4, measure.base_choice, through slots.move): a slot takes
#: needs 3, 4, 7
# the newest head whose base file holds every label of the move under origin's judge, written by a driver of its own
# dev/climb tree, and measures nothing at its start (no lock, no smoke); one label short, it measures origin's head;
# a file of another driver's tree or a head under another judge is not taken. A regression against origin's head that
# the older base does not show is refused by the lander's rebased check (section 7's rebased6, the lander's own path).
# slots.move's door, clone and Kaimon steps are stood in; base_choice, measure_base and the base files are real
import slots as SL
real11 = {"tree": M.driver_tree, "smoke": M.smoke, "slot": M.julia_slot, "using": door.using,
          **{k: getattr(SL, k) for k in ("users", "labels_for", "environment", "deps", "agent_tree", "kaimon_up", "session",
                                         "already_advanced", "update_json")}}
try:
    os.makedirs(f"{repo}/dev/hooks", exist_ok=True); open(f"{repo}/dev/hooks/commit-msg", "w").write("#!/bin/sh\n")
    open(f"{repo}/src/t11.jl", "w").write("t = 1\n"); g("add", "src/t11.jl"); g("commit", "-qm", "x11"); x11 = g("rev-parse", "HEAD")
    open(f"{repo}/src/t11.jl", "a").write("t = 2\n"); g("commit", "-qam", "o11"); o11 = g("rev-parse", "HEAD")
    os.makedirs(f"{repo}/test", exist_ok=True)
    open(f"{repo}/test/oracle.jl", "w").write("# a judge edit\n"); g("add", "test/oracle.jl"); g("commit", "-qm", "j11"); j11 = g("rev-parse", "HEAD")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", o11)
    labels11 = {"m/a", "m/b", "m/c"}
    drv11 = "d" * 40
    M.driver_tree = lambda: drv11
    def file11(head, labels, drv=drv11):
        jid = M.judge_id(head)
        core.write_atomic(M.base_path(head, drv), M.cases_text([M.Row((l, "passed", 1.0, ""), ("a" * 40, jid)) for l in sorted(labels)]))
    file11(x11, labels11)
    smoked11, locked11, seen11 = [], [], []
    M.smoke = lambda role, only, task, sha_, **kw: (smoked11.append((sha_, set(only))), ({l: M.Row((l, "passed", 1.0, ""), ("a" * 40, M.judge_id(sha_))) for l in only}, None))[1]
    @contextlib.contextmanager
    def slot11(kind, first=False):
        locked11.append(kind); yield
    M.julia_slot = slot11
    door.using = lambda role: contextlib.nullcontext()
    SL.users = lambda name: ("_wtk1", "review1")
    SL.update_json = lambda *a, **k: None
    SL.environment = lambda sha_: {"Manifest.toml": "", "LocalPreferences.toml": ""}
    SL.deps = lambda sha_, man: "/nonexistent"
    SL.agent_tree = lambda *a, **k: f"{tmp}/clone11"
    SL.kaimon_up = lambda *a, **k: None
    SL.session = lambda *a, **k: "k11"
    SL.already_advanced = lambda h_, base_, rows: (seen11.append((base_, dict(rows))), True)[1]   # the move ends there
    def move11(labels):
        smoked11.clear(); locked11.clear(); seen11.clear()
        SL.labels_for = lambda h_: set(labels)
        r = SL.move({"id": "h11", "key": "k11", "cases": ["m/a"]}, "climb-1")
        return r, (seen11[0][0] if seen11 else None)
    r11, base11 = move11(labels11)
    if (r11, base11) != ("already-advanced", x11) or smoked11 or locked11:
        fault(f"a slot with a complete older base took {base11 and base11[:10]}, not {x11[:10]}, or measured {smoked11} or took {locked11} (T4)")
    r11, base11 = move11(labels11 | {"m/d"})
    if base11 != o11 or not smoked11 or smoked11[0][0] != o11:
        fault(f"a slot one label short of every older base took {base11 and base11[:10]} and measured {smoked11}, not origin's head {o11[:10]} (T4)")
    M.driver_tree = lambda: "e" * 40
    r11, base11 = move11(labels11)
    if base11 != o11:
        fault(f"a slot took {base11 and base11[:10]}'s base file, written by a driver of another dev/climb tree (T4)")
    M.driver_tree = lambda: drv11
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", j11)
    r11, base11 = move11(labels11)
    if base11 != j11:
        fault(f"a slot took {base11 and base11[:10]}, a head under another judge than origin's {j11[:10]} (T4)")
    # a regression only against origin's head: m/a broken at the older base, passing at origin, broken by the move
    E11 = lambda l: (l, "errored", 1.0, "planted")
    gate11 = M.regressions({"key": "k11", "cases": ["x/y"]}, {"m/a"}, {"m/a": M.Row(E11("m/a"), (A6, J1))}, {"m/a": M.Row(E11("m/a"), (A6, J1))})
    land11, _ = rebased6({"m/a": (P("m/a"), J1)}, {"m/a": P("m/a")}, {"m/a": E11("m/a")}, {"m/a"})
    if gate11 or not any("m/a" in p_ for p_ in land11):
        fault(f"a regression against origin's head alone: the older base's gate read {gate11} (none expected), the lander's "
              f"rebased check {land11} (a refusal naming m/a expected) (T4)")
except Exception as e:
    import traceback
    fault(f"the move's base (T4) raised {type(e).__name__}: {str(e)[:240]} {traceback.format_exc()[-300:]}")
finally:
    M.driver_tree, M.smoke, M.julia_slot, door.using = real11["tree"], real11["smoke"], real11["slot"], real11["using"]
    for k in ("users", "labels_for", "environment", "deps", "agent_tree", "kaimon_up", "session", "already_advanced", "update_json"):
        setattr(SL, k, real11[k])
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

# 12. a compiling process killed from outside (SIGKILL the watch did not send: jetsam, memory pressure) is the
# host's: no row, the measurement cut (MeasureCut, infra), its case measured again; a process that ends by itself
# during a case (its own exit; an abort's crash report would hold it for minutes) still books that case errored (O9-3). measure.watched itself, with a stand-in process (sh)
# writing its `started` record and then ending; the door's home, tick and reap stood in
real12, real_cfg12 = {k: getattr(door, k) for k in ("home", "open_home", "tick", "reap")}, M.cfg
try:
    M.cfg = lambda: dict(real_cfg12(), watch_s=0.05)   # the watch's poll injected tiny: a wait by design
    home12 = f"{tmp}/home12"; os.makedirs(f"{home12}/m/kill/compile", exist_ok=True); os.makedirs(f"{home12}/m/abort/compile", exist_ok=True); d12 = f"{tmp}/d12"; os.makedirs(d12, exist_ok=True)
    door.home = lambda role: home12
    door.open_home = lambda role, rel: open(f"{home12}/{rel}", "rb") if os.path.exists(f"{home12}/{rel}") else None
    door.tick = lambda *a, **k: None
    door.reap = lambda *a, **k: None
    def start12(how):
        def start(env, log_):
            mark = f"{d12}/ran-{how}"
            script = ('if [ -e "$MARK" ]; then exit 0; fi; : > "$MARK"; printf "started\\ta/x\\n" >> "$REC"; '
                      + ("kill -9 $$" if how == "kill" else "exit 3"))
            return subprocess.Popen(["/bin/sh", "-c", script], env=dict(os.environ, REC=env["WT_SMOKE_COMPILED"], MARK=mark),
                                    stdout=log_, stderr=subprocess.STDOUT)
        return start
    try:
        out12 = M.watched(start12("kill"), "measure", d12, "m/kill/compile", "compile", ["a/x"], 60, var="WT_SMOKE_COMPILED", keep_done=True)
        fault(f"a compiling process SIGKILLed from outside during its case booked {out12[1]}, not a cut (infra, no row)")
    except M.MeasureCut as e:
        if "SIGKILL" not in str(e):
            fault(f"a compiling process SIGKILLed from outside was cut, naming another cause: {str(e)[:200]}")
    out12 = M.watched(start12("abort"), "measure", d12, "m/abort/compile", "compile", ["a/x"], 60, var="WT_SMOKE_COMPILED", keep_done=True)
    if out12[1] != {"a/x": "the process ended during the case"}:
        fault(f"a compiling process that aborted during its case booked {out12[1]} (refused: {out12[3]}), not that case errored (O9-3)")
except Exception as e:
    fault(f"the watch of a killed process raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.cfg = real_cfg12
    for k, v in real12.items():
        setattr(door, k, v)

# 13. the report says the budget rule that runs: with budget_holds false it names no pause and no limit it does not
# hold; with it true, the week's pause and the limits (core.report itself, budget_holds stood in through cfg; the spend
# counters stood in, which read the account's transcripts under HOME: the harness reads none of the owner's)
real13 = {k: getattr(core, k) for k in ("cfg", "week_spend", "account_spend", "climb_spend", "allowance")}
try:
    core.week_spend, core.account_spend, core.climb_spend, core.allowance = (lambda: 1e6), (lambda d: 1e6), (lambda d: 1e6), (lambda: 9e6)
    for holds13 in (False, True):
        core.cfg = lambda h_=holds13: dict(real13["cfg"](), budget_holds=h_)
        r13 = core.report()
        said13 = "pauses at" in r13 or " of " + f"{real13['cfg']()['week_weighted'] / 1e6:.0f}M" in r13
        if said13 != holds13:
            fault(f"the report with budget_holds {holds13} {'says' if said13 else 'does not say'} the week's pause and limits: "
                  + next((l for l in r13.splitlines() if "week" in l), "no week line")[:200])
except Exception as e:
    fault(f"the report raised {type(e).__name__}: {str(e)[:240]}")
finally:
    for k, v in real13.items():
        setattr(core, k, v)

# 15. a queued item is one commit (lander.enqueue): the lander's test set is made for the item's commit and dev/ship.sh
# checks each commit in turn, so an item of two is refused before it is queued, naming why; one commit is not refused
# for its count
try:
    base15 = g("rev-parse", "HEAD")
    open(f"{repo}/src/t15.jl", "w").write("a = 1\n"); g("add", "src/t15.jl"); g("commit", "-qm", "a15"); a15 = g("rev-parse", "HEAD")
    open(f"{repo}/src/t15.jl", "a").write("b = 2\n"); g("commit", "-qam", "b15"); b15 = g("rev-parse", "HEAD")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", base15)
    for sha15, n15 in ((b15, 2), (a15, 1)):
        try:
            L.enqueue(sha15, "l228-15", "hand")
            why15 = None
        except core.ClimbError as e:
            why15 = str(e)
        refused15 = bool(why15) and "a queued item is one commit" in why15
        if refused15 != (n15 > 1):
            fault(f"an item of {n15} commit(s) {'was' if refused15 else 'was not'} refused for its count: {why15}")
except Exception as e:
    fault(f"the one-commit rule raised {type(e).__name__}: {str(e)[:240]}")
finally:
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")
    with contextlib.suppress(Exception):
        core.update_json("ready.json", [], lambda q: q.__setitem__(slice(None), [x for x in q if x.get("hold") != "l228-15"]))

# 16. the test files the landings' shares leave unrun are run between scores (climb.src_gap, through climb.score_tick):
# after a landing, files standing unrun and no src record at origin's head, the score tick runs the score's src part
# there once; not again at that head, not where the head has its src record, not when no file stands unrun. What the
# tick reaches beyond is stood in (the fetch, the alarms, the score, the src part itself)
import climb as C
names16 = ("alarms", "scored_heads", "fetch", "unlogged_landings", "scoreboard_once", "src_part", "power_ok", "pause",
           "week_half", "token_refused", "src_unverified")
real16 = {k: getattr(C, k) for k in names16}
try:
    head16 = g("rev-parse", "HEAD")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", head16)
    ran16, behind16 = [], [2]
    C.alarms = C.fetch = lambda *a, **k: None
    C.unlogged_landings = lambda: []
    C.scored_heads = lambda *a: [{"sha": head16, "t": core.stamp()}]   # scored just now: no score is due
    C.scoreboard_once = lambda h_: ran16.append(("score", h_))
    C.src_part = lambda h_: ran16.append(("src", h_))
    C.power_ok, C.pause, C.week_half, C.token_refused = (lambda: True), (lambda: False), (lambda: True), (lambda: False)
    C.src_unverified = lambda h_: (behind16[0], ["t00.jl"])
    for f16 in (C.SRC_GAP, M.SRC_LATEST):
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(state, f16))
    C.score_tick(); C.score_tick()
    if ran16 != [("src", head16)]:
        fault(f"with files unrun since a landing the score tick ran {ran16}, not the src part once at origin's head")
    os.remove(os.path.join(state, C.SRC_GAP)); ran16.clear()
    core.save_json(M.SRC_LATEST, {"head": head16}); C.score_tick()
    os.remove(os.path.join(state, M.SRC_LATEST)); behind16[0] = 0; C.score_tick()
    if ran16:
        fault(f"the score tick ran {ran16} where the head has its src record, or no file stands unrun")
except Exception as e:
    fault(f"the src part between scores raised {type(e).__name__}: {str(e)[:240]}")
finally:
    for k, v in real16.items():
        setattr(C, k, v)
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

for f in faults:
    print(f)
