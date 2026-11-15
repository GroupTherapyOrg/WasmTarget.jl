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
    def _run(_n):   # one section's child: (its fault lines, each named by its section, and its seconds)
        _out = []
        _lim, _t0 = min(_secs[_n][2], int(LIMIT_OVERRIDE)) if LIMIT_OVERRIDE else _secs[_n][2], time.time()
        # the child's scratch is the runner's, made here and removed here however the child ends (its limit's SIGKILL
        # included, which no exit handler of the child's survives: 2026-11-15 03:11Z, a landing user's tmp kept one)
        _scratch = tempfile.mkdtemp(prefix="l228-")
        try:
            return _child(_n, _lim, _t0, _scratch)
        finally:
            import shutil as _shr
            _shr.rmtree(_scratch, ignore_errors=True)
    def _child(_n, _lim, _t0, _scratch):
        _out = []
        with tempfile.TemporaryDirectory(prefix="l228-run-") as _d:
            with open(f"{_d}/out", "wb") as _o, open(f"{_d}/err", "wb") as _e:
                _p = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), sys.argv[1], "--section", str(_n)],
                                      stdin=subprocess.DEVNULL, stdout=_o, stderr=_e, start_new_session=True,
                                      env=dict(os.environ, L228_SECTION_TMP=_scratch))
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
        _out += [f"section {_n}: {_l}" for _l in _lines]   # every fault line names its section
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
_g = {"__name__": "__l228_section__", "__file__": os.path.abspath(__file__), "__section__": _n}   # the section run
exec(compile("import contextlib, json, os, re, signal, subprocess, sys, tempfile, time, base64\n" + _pro + "".join(_secs[k][0] for k in _secs[_n][1]) + _secs[_n][0] +
             "\nfor f in faults:\n    print(f)\n"
             # its scratch removed at its exit (B1: a child's tmp is its own; 2,500 of them, 5 GB, leaked in a day)
             "import shutil as _sh_\n_sh_.rmtree(tmp, ignore_errors=True)\n", f"climb_l228 section {_n}", "exec"), _g)
sys.exit(0)

root = os.path.abspath(sys.argv[1])
faults = []
def fault(why):
    faults.append(why)

tmp = os.environ.get("L228_SECTION_TMP") or tempfile.mkdtemp(prefix="l228-")   # the runner's (removed by it), else its own
repo, state, locks = f"{tmp}/repo", f"{tmp}/state", f"{tmp}/locks"
for d in (repo, state, locks):
    os.makedirs(d)
g = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout.strip()
# the scratch repository: test files of known sizes, a check.sh naming the shards and D14's band, a src file
FILES = [f"t{i:02d}.jl" for i in range(12)]
os.makedirs(f"{repo}/test/src"); os.makedirs(f"{repo}/dev"); os.makedirs(f"{repo}/src")
for i, f in enumerate(FILES):
    open(f"{repo}/test/src/{f}", "w").write(f"# {f}\n" + "x" * (100 + 10 * i) + "\n")
open(f"{repo}/dev/check.sh", "w").write("SHARDS=5\nD14_RED=180\nD14_RED_HARNESS=300\nD14_PACK=140\n")
open(f"{repo}/src/x.jl", "w").write("x = 1\n")
# the ratchet's list of the harness's inputs, which the lander's class of a check reads (dev/climb/l228scope.py)
os.makedirs(f"{repo}/test", exist_ok=True)
open(f"{repo}/test/parity_ratchet.jl", "w").write('const L228_INPUTS = ("dev/climb/", "dev/src_verdict.sh", "dev/d14_judge.sh", '
                                                  '"dev/formal/run_tlc.sh", "dev/formal/NoListenTLC.java", "dev/check.sh", "dev/ship.sh", '
                                                  '"dev/merge_packages.sh", "test/climb_l228.py")\n')
g("init", "-q")
# the driver is copied in untracked below: no section's commit carries it (a commit that did would touch the harness's
# inputs, and its check's class would be the harness's)
open(f"{repo}/.git/info/exclude", "a").write("dev/climb/\n")
g("config", "user.email", "l228@scratch"); g("config", "user.name", "l228")
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
# the door's ONE root, a scratch one (door.locks_dir: its locks, its window and its run directories, TOP/in, all follow
# TOP): never the live climb's. On 2026-11-14 this harness moved door.LOCKS alone, and its door.using()'s entry removed
# the live climb's TOP/in/measure.* run directories at 16:43:46Z (climb-1's measurement lost). The harness refuses to
# start on a root the live climb uses (root_refusal) unless it is the landing user inside a sandbox: its landing check,
# which can write nothing of TOP. Read from the kernel, never from a variable a caller sets: this process's effective
# uid against the owner of the landing user's home, and sandbox_check() of this process. The live root is door.TOP's own
# value, read here before it is redirected below (one source: dev/climb/setup-users.sh's root, door.py's literal)
LIVE_TOP = door.TOP
def landing_sandboxed():
    import ctypes
    try:
        if os.geteuid() != os.stat(f"{LIVE_TOP}/u/_wtland").st_uid:
            return False
        f = ctypes.CDLL("/usr/lib/libSystem.B.dylib").sandbox_check
        f.restype, f.argtypes = ctypes.c_int, [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        return f(os.getpid(), None, 0) == 1   # SANDBOX_FILTER_NONE: 1 when this process runs under a profile
    except OSError:
        return False
def root_refusal(top, gens=True):
    """Why this harness may not use `top` as the door's root, or None: the live TOP, or (with `gens`) a root holding a
    role generation a live process other than this one wrote, i.e. a root some running climb uses."""
    users = []
    for gp in (__import__("glob").glob(f"{top}/locks/.role-*.gen") if gens else ()):
        with contextlib.suppress(OSError, ValueError, ProcessLookupError):
            pid = int(open(gp).read().split("-")[0])
            if pid != os.getpid():
                try:
                    os.kill(pid, 0)
                except PermissionError:
                    pass
                users.append(f"{os.path.basename(gp)} (pid {pid})")
    if (os.path.realpath(top) == os.path.realpath(LIVE_TOP) or users) and not landing_sandboxed():
        return (f"the door's root {top} is a live climb's ({', '.join(users) or 'the live TOP'}): this harness runs on a "
                "scratch root, or as the landing user inside its check profile")
    return None
door.TOP = tmp   # its locks, f"{tmp}/locks", follow
assert door.locks_dir() == locks
why = root_refusal(door.TOP)
if why:
    print(f"climb_l228: refused: {why}"); sys.exit(0)
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
                                 "split": {"load": [17 if shape else 0, 200, 0, 0], "ratchet": [79, 400, 0, 0], "l228": "none",
                                           "shards": [[80, 650, 0, 0]] * 5, "starts": [375.0] * 5},
                                 "probe": {"quiet": {"start": True, "end": True}}}) + "\n")
c = core.cfg()
def expect_margin(shape):
    pos = sorted((e for e in ERRS[shape][-c["src_margin_checks"]:] if e > 0), reverse=True)
    return min(c["src_margin_max_s"], max(c["src_margin_min_s"], round(3 * (pos[1] if len(pos) > 1 else 0.0), 1)))

# 1. src_target: D14's packing ceiling (D14_PACK) less three times the second-largest positive error of the shape's last landed checks
for shape in (True, False):
    t, info = M.src_target(140, shape)
    if abs(t - (140 - expect_margin(shape))) > 0.05:
        fault(f"src_target(140, {shape}) returns {t}, where D14_PACK less the measured margin is {140 - expect_margin(shape)}")

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
def land6(crc, path, readings, power=(True, False, 90, 96, 0)):
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
            ("a busy start, its tests green, 190 s", 10, 190, [busy6, busy6], (True, False, 90, 96, 0), ("LANDED", "unjudged")),
            ("quiet at its start and its end, 150 s", 10, 150, [quiet6, quiet6], (True, False, 90, 96, 0), ("D14", "red")),
            ("a busy start, one test failing", 14, 90, [busy6, busy6], (True, False, 90, 96, 0), ("OWN", None)),
            ("in Low Power Mode on battery, the cores idle, 170 s", 10, 170, [quiet6, quiet6], (False, True, 80, None, None), ("LANDED", "unjudged"))):
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
# repeat counts from one; a backoff that is not a driver fault (the load counter's plant's, fixed seconds) waits whatever the driver. The
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
    core.back_off("lander", "plant", why="plant", secs=600, note_at=0)
    core.driver_tree = lambda: "3" * 40
    if not core.waits("lander"):
        fault("a plant's backoff, which is no driver fault, ended when the driver changed")
    core.recovered("lander", "plant")
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

# 16. the test files the landings' shares leave unrun are run by a job of their own whatever else runs (climb.src_gap
# through climb.py src-gap: climb.src_gap_once, started by the lander's round: lander.src_gap_spawn): after a landing,
# files standing unrun and no src record at origin's head, the job runs the src part there once, as the measure role
# (the verify lane, never the score's lock, which a score's compile holds for hours); not again at that head, not where
# the head has its src record, not when no file stands unrun; the lander's round starts it when due, even when the
# bound stops the round, and not otherwise; the score tick runs it no more. What they reach beyond is stood in
import climb as C
names16 = ("alarms", "scored_heads", "fetch", "unlogged_landings", "scoreboard_once", "src_part", "power_ok", "pause",
           "week_half", "token_refused", "src_unverified")
real16 = {k: getattr(C, k) for k in names16}
realm16, reall16 = {"src_unverified": M.src_unverified}, {k: getattr(L, k) for k in ("pause", "waits", "power_ok", "reconcile",
    "fixfirst_overdue", "fixfirst_binds", "src_unverified", "unverified_binds", "src_gap_spawn", "l228_sweep_due")}
popen16 = L.subprocess.Popen
try:
    head16 = g("rev-parse", "HEAD")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", head16)
    ran16, behind16 = [], [2]
    C.alarms = C.fetch = lambda *a, **k: None
    C.unlogged_landings = lambda: []
    C.scored_heads = lambda *a: [{"sha": head16, "t": core.stamp()}]   # scored just now: no score is due
    C.scoreboard_once = lambda h_: ran16.append(("score", h_))
    C.src_part = lambda h_, role="score": ran16.append(("src", h_, role))
    C.power_ok, C.pause, C.week_half, C.token_refused = (lambda: True), (lambda: False), (lambda: True), (lambda: False)
    C.src_unverified = M.src_unverified = lambda h_: (behind16[0], ["t00.jl"])
    for f16 in (M.SRC_GAP, M.SRC_LATEST):
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(state, f16))
    rc16 = (C.src_gap_once(), C.src_gap_once())
    if ran16 != [("src", head16, "measure")] or rc16 != (0, 3):
        fault(f"with files unrun since a landing the src-gap job ran {ran16} (exits {rc16}), not the src part once at "
              "origin's head as the measure role")
    os.remove(os.path.join(state, M.SRC_GAP)); ran16.clear()
    core.save_json(M.SRC_LATEST, {"head": head16}); C.src_gap_once()
    os.remove(os.path.join(state, M.SRC_LATEST)); behind16[0] = 0; C.src_gap_once()
    if ran16:
        fault(f"the src-gap job ran {ran16} where the head has its src record, or no file stands unrun")
    behind16[0] = 2; C.score_tick()
    if ran16:
        fault(f"the score tick ran {ran16}: the gap is the src-gap job's alone")
    # the lander's round: the job started when due (a process of its own), even when the bound stops the round
    spawned16 = []
    L.l228_sweep_due = lambda o: False   # its git would run through the Popen stand-in below; section 38 holds it
    L.subprocess.Popen = lambda argv, **k: spawned16.append(argv[-1]) or "p16"
    p16 = (L.src_gap_spawn(head16), (behind16.__setitem__(0, 0), L.src_gap_spawn(head16))[1])
    L.subprocess.Popen = popen16
    if p16 != ("p16", None) or spawned16 != ["src-gap"]:
        fault(f"the lander's start of the src-gap job: {p16}, {spawned16} (started when due, not otherwise, expected)")
    calls16 = []
    L.pause, L.waits, L.power_ok, L.reconcile = (lambda: False), (lambda *a: False), (lambda: True), (lambda: None)
    L.fixfirst_overdue, L.fixfirst_binds, L.unverified_binds = (lambda: []), (lambda o: None), (lambda b, f: None)
    L.src_unverified = lambda h_: (10 ** 6, ["t00.jl"])   # past the bound: the round lands nothing
    L.src_gap_spawn = lambda o: calls16.append(o)
    if L.land_round() != 3 or calls16 != [head16]:
        fault(f"a lander's round held by the bound started the src-gap job {calls16} times at {head16[:8]} (once expected)")
except Exception as e:
    fault(f"the src-gap job raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.subprocess.Popen = popen16
    for k, v in real16.items():
        setattr(C, k, v)
    for k, v in reall16.items():
        setattr(L, k, v)
    M.src_unverified = realm16["src_unverified"]
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

for f in faults:
    print(f)

# 17. a landing's model checker reads the pinned jar and makes no network call (door.pins, dev/formal/run_tlc.sh): pins
# mirrors Dale's tla2tools.jar into TOP/pins when its sha256 is the one the landing tree's run_tlc.sh pins, and removes a
# copy of another hash; inside a landing (CHECK_LANDING) run_tlc.sh refuses a missing jar or one of another hash,
# naming it, and never calls curl. TOP and HOME are scratch directories, the checkouts' copies stood in, and curl on
# run_tlc.sh's PATH a stand-in that records a call
real17 = {k: getattr(door, k) for k in ("TOP", "HOME", "clone_tree")}
try:
    top17, home17, tree17 = f"{tmp}/top17", f"{tmp}/home17", f"{tmp}/tree17"
    os.makedirs(f"{home17}/.cache/wasmtarget"); os.makedirs(f"{tree17}/dev/formal"); os.makedirs(top17)
    jar17 = b"PK the pinned jar\n"
    import hashlib as _h17
    pin17 = _h17.sha256(jar17).hexdigest()
    run17 = open(f"{root}/dev/formal/run_tlc.sh").read()
    m17 = re.search(r"^TLA2TOOLS_SHA256=[0-9a-f]{64}", run17, re.M)
    if not m17:
        fault("dev/formal/run_tlc.sh pins no TLA2TOOLS_SHA256: the jar's identity is written nowhere")
    else:
        open(f"{tree17}/dev/formal/run_tlc.sh", "w").write(run17.replace(m17.group(0), f"TLA2TOOLS_SHA256={pin17}"))
    open(f"{home17}/.cache/wasmtarget/tla2tools.jar", "wb").write(jar17)
    door.TOP, door.HOME, door.clone_tree = top17, home17, lambda src, dst: dst
    door.pins(tree17)
    got17 = open(f"{top17}/pins/tla2tools.jar", "rb").read() if os.path.exists(f"{top17}/pins/tla2tools.jar") else None
    if got17 != jar17:
        fault(f"door.pins did not mirror the jar the landing tree pins into TOP/pins ({'nothing there' if got17 is None else 'another file'})")
    open(f"{home17}/.cache/wasmtarget/tla2tools.jar", "wb").write(b"PK another jar\n")
    open(f"{top17}/pins/tla2tools.jar", "wb").write(b"PK a stale copy\n")
    door.pins(tree17)
    if os.path.exists(f"{top17}/pins/tla2tools.jar"):
        fault("door.pins left or mirrored a jar of another hash than the landing tree pins")
    # run_tlc.sh inside a landing: a missing jar, then one of another hash, each refused, named, and no curl
    os.makedirs(f"{tmp}/bin17"); open(f"{tmp}/bin17/curl", "w").write(f'#!/bin/sh\ntouch "{tmp}/curl17.called"\nexit 1\n')
    os.chmod(f"{tmp}/bin17/curl", 0o755)
    for what17, jar, says17 in (("missing", f"{tmp}/none17.jar", "run_tlc: no tla2tools.jar at"),
                                ("of another hash", f"{home17}/.cache/wasmtarget/tla2tools.jar", "is not tla2tools.jar v1.7.4 (sha256")):
        r17 = subprocess.run(["bash", f"{tree17}/dev/formal/run_tlc.sh"], capture_output=True, text=True, timeout=30,
                             env=dict(os.environ, CHECK_LANDING="1", TLA2TOOLS_JAR=jar, PATH=f"{tmp}/bin17:/usr/bin:/bin"))
        if r17.returncode == 0 or says17 not in r17.stdout + r17.stderr or os.path.exists(f"{tmp}/curl17.called"):
            fault(f"run_tlc.sh inside a landing with a jar {what17}: exit {r17.returncode}, curl "
                  f"{'called' if os.path.exists(f'{tmp}/curl17.called') else 'not called'}: {(r17.stdout + r17.stderr).strip()[-200:]}")
except Exception as e:
    fault(f"the model checker's jar raised {type(e).__name__}: {str(e)[:240]}")
finally:
    for k, v in real17.items():
        setattr(door, k, v)

# 18. TLC runs inside a landing's sandbox, and the sandbox still binds and connects nothing (dev/formal/NoListenTLC.java,
# run_tlc.sh): the tree's run_tlc.sh, copied beside a two-instance model of this section's own (MCProbe: no model of
# dev/formal is read, so a change to a model of the compiler is no input of this harness and its landing is judged in
# the ordinary class; the formal stage of dev/check.sh checks the models a change touches), checks a model to "ok" and its Broken instance to its violation inside the door's
# `check` profile, and from the same profile a bind and a connect (to localhost and to an outside address) are each
# refused by the sandbox. Outside a sandbox the profile is the tree's own (door.profile(kind="check")), applied by
# sandbox-exec; inside a landing, where a sandbox cannot be nested, they run in the profile the landing runs in
#: limit 150
try:
    nested18 = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                              capture_output=True).returncode != 0
    home18 = f"{tmp}/home18"; os.makedirs(f"{home18}/tmp")
    jar18 = os.environ.get("TLA2TOOLS_JAR") or os.path.expanduser("~/.cache/wasmtarget/tla2tools.jar")
    # the JDK's own bin, never /usr/bin's stubs (they look the JDK up through java_home, which a sandbox refuses): the
    # PATH's when it holds one (land_job puts it first), else java_home's
    w18 = shutil.which("javac") or ""
    jdk18 = os.path.dirname(w18) if w18 and not w18.startswith("/usr/bin/") else \
        os.path.join(subprocess.run(["/usr/libexec/java_home"], capture_output=True, text=True).stdout.strip(), "bin")
    pre18 = [] if nested18 else ["/usr/bin/sandbox-exec", "-f", door.profile(f"{tmp}/check18.sb", [home18], kind="check")]
    env18 = {"HOME": os.environ["HOME"] if nested18 else home18, "TMPDIR": f"{home18}/tmp", "LANG": "en_US.UTF-8",
             "CHECK_LANDING": "1", "TLA2TOOLS_JAR": jar18, "PATH": f"{jdk18}:/usr/bin:/bin",
             "DEVELOPER_DIR": "/Library/Developer/CommandLineTools", "TLC_ONLY": "MCProbe.cfg MCProbeBroken.cfg",
             "TLC_HEAVY": "MCProbe.cfg",   # its dealing list names this directory's instances (run_tlc.sh refuses others)
             "TLC_WORKERS": "1"}   # two instances of a few states: one worker (auto spent every core's time)
    f18 = f"{tmp}/formal18"; os.makedirs(f18)
    for n18 in ("run_tlc.sh", "NoListenTLC.java"):
        shutil.copy(f"{root}/dev/formal/{n18}", f"{f18}/{n18}")
    open(f"{f18}/Probe.tla", "w").write("---- MODULE Probe ----\nEXTENDS Naturals\nCONSTANT Limit\nVARIABLE x\n"
                                         "Init == x = 0\nNext == x < 3 /\\ x' = x + 1\nSpec == Init /\\ [][Next]_x\n"
                                         "Bounded == x <= Limit\n====\n")
    open(f"{f18}/MCProbe.tla", "w").write("---- MODULE MCProbe ----\nEXTENDS Probe\n====\n")
    open(f"{f18}/MCProbe.cfg", "w").write("SPECIFICATION Spec\nCONSTANT Limit = 3\nINVARIANT Bounded\nCHECK_DEADLOCK FALSE\n")
    open(f"{f18}/MCProbeBroken.cfg", "w").write("\\* expect: Bounded\nSPECIFICATION Spec\nCONSTANT Limit = 1\nINVARIANT Bounded\n"
                                                 "CHECK_DEADLOCK FALSE\n")
    if not os.path.isfile(jar18):
        fault(f"no tla2tools.jar at {jar18}: TLC cannot be run inside the profile here")
    else:
        r18 = subprocess.run(pre18 + ["/bin/bash", f"{f18}/run_tlc.sh"], capture_output=True, text=True,
                             env=env18, stdin=subprocess.DEVNULL, timeout=120)
        o18 = r18.stdout + r18.stderr
        if r18.returncode != 0 or not re.search(r"^  ok   MCProbe\.cfg +ok ", o18, re.M) or \
                not re.search(r"^  ok   MCProbeBroken\.cfg +violation of Bounded", o18, re.M):
            which18 = "the landing's" if nested18 else "the tree's"
            fault(f"TLC inside the check profile ({which18}): exit {r18.returncode}: {o18.strip()[-300:]}")
    probe18 = ("import socket, errno\n"
               "def t(f):\n"
               "    s = socket.socket()\n"
               "    try: f(s); return 'allowed'\n"
               "    except OSError as e: return 'refused' if e.errno == errno.EPERM else f'not by the sandbox: {e}'\n"
               "    finally: s.close()\n"
               "print(t(lambda s: s.bind(('0.0.0.0', 0))), t(lambda s: s.connect(('127.0.0.1', 9))), t(lambda s: s.connect(('1.1.1.1', 443))))\n")
    p18 = subprocess.run(pre18 + ["/usr/bin/python3", "-I", "-c", probe18], capture_output=True, text=True, env=env18,
                         stdin=subprocess.DEVNULL, timeout=60)
    if p18.stdout.split() != ["refused"] * 3:
        fault(f"the check profile: a bind, a connect to localhost and one outside read {p18.stdout.strip() or p18.stderr.strip()[-200:]}, not each refused")
except Exception as e:
    fault(f"TLC inside the check profile raised {type(e).__name__}: {str(e)[:240]}")

# 19. a landing never restarts a measurement in flight (T5): a lander whose work under the verify lock uses no
# measuring role (julia_slot(first=True, stops=True), the landing's check) finds the measurement's processes stopped
# in place, and the measurement goes on when the lock comes back, nothing restarted. measure.watched drives a stand-in
# compile process (sh, one `started` record a case); the lander is a second process calling lander.land itself (its
# layer, its quiet window and its check stood in), so the landing's own `stops` is what is checked; the role's STOP and
# CONT (door.signal_role, sudo's) are stood in by the stand-in's; time scaled down, a case's budget (first_s) under the
# check's length, so a stop counted in the budget cuts the case; a stand-in left stopped once the lander is done is a
# fault named at once, and every stand-in the section stopped is continued and ended before it returns
#: limit 90
import signal as _sig19, textwrap as _tw19
real19 = {k: getattr(door, k) for k in ("home", "open_home", "tick", "reap", "signal_role")}
real_cfg19 = M.cfg
held19 = []
try:
    home19 = f"{tmp}/home19"; d19 = f"{tmp}/d19"; os.makedirs(d19)
    M.cfg = lambda: dict(real_cfg19(), watch_s=0.05, poll_s=dict(real_cfg19()["poll_s"], yield_=0.05, **{"yield": 0.05, "lock": 0.05}))
    door.home = lambda role: home19
    door.open_home = lambda role, rel: open(f"{home19}/{rel}", "rb") if os.path.exists(f"{home19}/{rel}") else None
    door.tick = lambda *a, **k: None
    door.reap = lambda *a, **k: None
    standin19 = {}
    def sig19(role, sig, landing=False):   # pkill's status, as door.signal_role returns it
        with contextlib.suppress(ProcessLookupError):
            os.kill(standin19["p"].pid, _sig19.SIGSTOP if sig == "STOP" else _sig19.SIGCONT)
            return 0
        return 1
    door.signal_role = sig19
    real_stopped19 = M.role_stopped   # the stop read back from the stand-in itself (the role's user has none here)
    M.role_stopped = lambda role: standin19.get("p") is None or standin19["p"].poll() is not None or \
        subprocess.run(["ps", "-o", "state=", "-p", str(standin19["p"].pid)], capture_output=True, text=True).stdout.strip().startswith("T")
    lander19 = _tw19.dedent(f"""
        import os, sys, time, subprocess
        os.environ["WT_CLIMB_STATE"] = {state!r}; os.chdir({repo!r}); sys.path.insert(0, {repo + "/dev/climb"!r})
        import door; door.TOP = {tmp!r}
        assert os.path.realpath(door.TOP) != os.path.realpath({LIVE_TOP!r}), "an actor on the live root"
        import contextlib
        import measure as M, lander as L
        real = M.cfg
        M.cfg = lambda: dict(real(), poll_s=dict(real()["poll_s"], **{{"yield": 0.05, "lock": 0.05, "landing_lock": 0.05}}))
        L.cfg = M.cfg
        M.ac_wait = lambda *a, **k: None
        M.landing_lock_held = lambda: False
        L.layer = lambda slot: None
        @contextlib.contextmanager
        def quiet():
            yield lambda: None
        L.quiesced = quiet
        pidfile, n, hold, go = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
        print("ready", flush=True)   # the driver loaded: its checks wait for the measurement to be under way
        while not os.path.exists(go):
            time.sleep(0.02)
        pid = int(open(pidfile).read())
        def check(slot, item, c, scan, handed=None):   # lander._land: the probe and the check, both locks held
            # ps by PATH: a landing's is TOP/tools/bin's plain copy (/bin/ps is setuid, which a sandbox refuses)
            st = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            print("held", (st or "gone")[0], round(time.time(), 2), flush=True)
            time.sleep(hold)
            return None, None, None, ""
        L._land = check
        for i in range(n):
            L.land({tmp!r}, {{"hold": "l228-19"}})
        """)
    open(f"{tmp}/lander19.py", "w").write(lander19)
    def measure19(cases, case_s, n_checks, hold, after):
        """watched on a stand-in of `cases` cases; a lander of n_checks checks of `hold` s each, from `after` s in:
        (the watch's process count, its kills, its seconds, the lander's lines, whether the lander still ran at the end)"""
        rel = f"m/c{len(held19)}/compile"; os.makedirs(f"{home19}/{rel}", exist_ok=True)
        fd = os.open(f"{locks}/.julia-verify.lock", os.O_CREAT | os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX)
        M.HELD_SLOT["verify"] = fd
        labels = [f"a/{i:02d}" for i in range(cases)]
        # each case CPU work (a loop until its own process time has advanced case_s), so a stopped stand-in makes no
        # progress, as a stopped compile makes none (a sleep would run out while it is stopped)
        script = ("import os, time\nrec = os.environ['REC']\n"   # its labels the run's own (WT_SMOKE_ONLY), as smoke.jl's
                  "for l in open(os.environ['WT_SMOKE_ONLY']).read().split():\n"
                  "    open(rec, 'a').write('started\\t' + l + '\\n')\n"
                  "    t = time.process_time()\n"
                  f"    while time.process_time() - t < {case_s}:\n"
                  "        pass\n"
                  "open(rec, 'a').write('ended\\n')\n")
        def start(env, log_):
            standin19["p"] = subprocess.Popen([sys.executable, "-I", "-c", script], env=dict(os.environ, REC=env["WT_SMOKE_COMPILED"],
                                                                                          WT_SMOKE_ONLY=env["WT_SMOKE_ONLY"]),
                                              stdout=log_, stderr=subprocess.STDOUT, start_new_session=True)
            return standin19["p"]
        k = len(held19)
        lout, gofile, pidfile = f"{tmp}/lander19.{k}.out", f"{tmp}/go19.{k}", f"{tmp}/pid19.{k}"
        open(lout, "w").close()
        lp = [subprocess.Popen([sys.executable, "-I", f"{tmp}/lander19.py", pidfile, str(n_checks), str(hold), gofile],
                               stdout=open(lout, "w"), stderr=subprocess.STDOUT) if n_checks else None]
        while lp[0] is not None and "ready" not in open(lout).read() and lp[0].poll() is None:   # the lander loaded first
            time.sleep(0.05)
        def go():
            while "p" not in standin19 or standin19["p"].poll() is not None and not os.path.exists(pidfile):
                time.sleep(0.01)
            open(pidfile, "w").write(str(standin19["p"].pid))
            time.sleep(after)
            open(gofile, "w").close()
        import threading as _th19
        standin19.pop("p", None)
        th = _th19.Thread(target=go); th.start()
        t0 = time.time()
        res = {}
        def run():
            try:
                res["out"] = M.watched(start, "measure", d19, rel, "compile", labels, FIRST19, var="WT_SMOKE_COMPILED",
                                       keep_done=True, yields=True)
                if res["out"][3]:   # its records refused (a stop counted in the load's budget reads as a stall there)
                    res["err"] = RuntimeError(f"the watch refused the measurement: {res['out'][3][:200]}")
            except Exception as e:
                res["err"] = e
        wt = _th19.Thread(target=run); wt.start()
        try:
            stuck = None   # the lander done and the stand-in still stopped: never continued (no CONT)
            while wt.is_alive():
                wt.join(0.2)
                p_ = standin19.get("p")
                if lp[0] is not None and lp[0].poll() is not None and p_ is not None and p_.poll() is None and \
                        subprocess.run(["ps", "-o", "state=", "-p", str(p_.pid)], capture_output=True, text=True).stdout.strip().startswith("T"):
                    stuck = stuck or time.time()
                    if time.time() - stuck > 3:
                        res["stuck"] = True
                        os.kill(p_.pid, _sig19.SIGKILL)   # its watch then sees it end
                else:
                    stuck = None
            if "err" in res:
                raise res["err"]
            if res.get("stuck"):
                raise RuntimeError("a paused measurement's processes were not continued after the check that paused them")
            out = res["out"]
        finally:
            secs = time.time() - t0
            th.join()
            p_ = standin19.get("p")
            if p_ is not None and p_.poll() is None:   # nothing of the section outlives it, stopped or not
                with contextlib.suppress(ProcessLookupError):
                    os.kill(p_.pid, _sig19.SIGCONT); os.kill(p_.pid, _sig19.SIGKILL)
            running = lp[0] is not None and lp[0].poll() is None
            M.HELD_SLOT.pop("verify", None)
            with contextlib.suppress(OSError):   # the lock let go before the lander is waited for
                fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
            if lp[0] is not None:
                lp[0].wait(60)
        lines = [l.split() for l in open(lout).read().splitlines() if l.startswith("held")]
        held19.append(lines)
        return out[2], out[1], secs, lines, running
    import fcntl
    FIRST19 = 12.0   # a case's budget here (no label timed): under the check's 15 s, so a stop counted in it cuts the case,
    # and far over a case's 0.6 CPU-seconds (a 0.8-CPU-second case took over 4 s of wall at background QoS on a busy
    # machine, 2026-11-14, and a 4-s budget killed a/02 in the landing check's sandbox with nothing broken); after a stop
    # the case in flight outlasts the watch's next tick, as a stopped compile's case does, so a stop counted in its
    # budget cuts it (at 0.3 CPU-seconds the next case's record could come first on a loaded machine: that break missed)
    # one check mid-measurement: the measurement pays the check's time alone, nothing restarted
    # (the lander's process takes a second or two to load the driver: the stand-ins outlast that); the same
    # measurement with no check first, its time the one the check's is weighed against. Section 22 needs this one's
    # helpers alone: its scenarios run when it is the section run (__section__)
    if __section__ != 19:
        raise StopIteration
    _, _, base19, _, _ = measure19(4, 0.6, 0, 0, 0.0)
    n19, k19, s19, l19, _ = measure19(4, 0.6, 1, 15.0, 0.4)
    # no restart is the process count (n19: one process) and nothing killed; the wall bound only catches a measurement
    # held past the check, and it scales with the machine's pace as base19 measured it (both are wall on a shared
    # machine: 2026-11-15 05:10Z, at a load of 12-24, 25.4 s and 27.2 s against no-check runs of 4.0 s and 9.2 s, a
    # fixed 3-s slack read a busy machine as a fault in 1 run of 3, and the sweep after a driver landing files a fault
    # there as a fix-first)
    if n19 != 1 or k19 or not l19 or l19[0][1] != "T" or s19 > 15.0 + 2.5 * base19 + 3.0:
        fault(f"a check mid-measurement: {n19} process(es) (1 expected: no restart), kills {k19}, the stand-in "
              f"{'stopped' if l19 and l19[0][1] == 'T' else 'running'} under the check ({l19}), {s19:.1f} s where it took {base19:.1f} s with no check, for a 15-s check")
    # a paused measurement whose driver is killed holds nothing: its back mark is a dead process's, and a mark whose pid
    # another process now holds (its start time not the writer's) is not that process's (the review's F5); each is
    # removed by the taker that reads it
    for what19, mark19 in (("a dead pid", f"999999 {door.BOOT} 0 next"), ("a reused pid", f"{os.getppid()} {door.BOOT} 1 next")):
        with open(M.back_mark("verify"), "w") as f19:
            f19.write(mark19 + "\n")
        if M.back_held("verify") or M.back_held("verify", first=True, stops=True) or os.path.exists(M.back_mark("verify")):
            fault(f"a back mark of {what19} holds the verify lock's takers back, or is left for the next to read")
        with contextlib.suppress(FileNotFoundError):
            os.remove(M.back_mark("verify"))
except StopIteration:   # section 22's: the helpers alone
    pass
except Exception as e:
    import traceback
    fault(f"the measurement paused in place raised {type(e).__name__}: {str(e)[:200]} {traceback.format_exc()[-300:]}")
finally:
    if __section__ == 19:
        M.cfg, M.role_stopped = real_cfg19, real_stopped19
        for k, v in real19.items():
            setattr(door, k, v)

# 20. a measurement's own directory is its holder's (L1, measure.measure_dir through measure.judged as smoke() calls it):
# a second measurement of the same role and task (the lander's rebased check of the base a slot measures, another
# slot's) begun and ended inside the first leaves the first's file; each removes its own when it ends; a dead holder's
# directory is removed and a live holder's kept
try:
    seen20 = {}
    def first20(w):
        seen20["a"] = w
        open(f"{w}/modules.tsv.blk", "w").write("module\n")
        M.judged("measure", "base-l228", h, {}, lambda w2: (seen20.__setitem__("b", w2), ({}, None))[1])
        seen20["kept"] = os.path.exists(f"{w}/modules.tsv.blk")
        return {}, None
    M.judged("measure", "base-l228", h, {}, first20)
    a20, b20 = seen20.get("a", ""), seen20.get("b", "")
    if not seen20.get("kept") or a20 == b20:
        fault(f"a measurement of the same base begun and ended inside another removed or shared the other's directory ({os.path.basename(a20)}, {os.path.basename(b20)})")
    if not a20 or os.path.exists(a20) or not b20 or os.path.exists(b20):
        fault("a measurement left its own directory behind when it ended")
    root20 = f"{tmp}/m20"; os.makedirs(root20)
    dead20 = os.path.join(root20, f"measure-base-l228@{os.getpid()}-{door.BOOT - 1}-dead")
    live20 = os.path.join(root20, f"measure-base-l228@{os.getppid()}-{door.BOOT}-live")
    os.makedirs(dead20); os.makedirs(live20)
    with M.measure_dir("measure", "base-l228", root20):
        pass
    if os.path.exists(dead20) or not os.path.exists(live20):
        fault(f"measure_dir: a dead holder's directory {'kept' if os.path.exists(dead20) else 'removed'}, a live holder's "
              f"{'kept' if os.path.exists(live20) else 'removed'}")
except Exception as e:
    fault(f"a measurement's own directory raised {type(e).__name__}: {str(e)[:240]}")

# 21. a slot's move that the driver failed backs off as a driver fault (slots.finish(driver=True), core.back_off): its
# first wait driver_fault_backoff_s, not retry_backoff_s, and it ends when the driver's code changes; an infra outcome
# that is not the driver's (driver=False) waits retry_backoff_s whatever the driver. The driver's tree is stood in
import slots as SL21
real21 = {"tree": core.driver_tree, "sltree": SL21.driver_tree, "unclaim": SL21.unclaim}
try:
    SL21.unclaim = lambda h_: None
    core.driver_tree = SL21.driver_tree = lambda: "1" * 40   # slots names it from core, as the driver's tree
    h21 = {"key": "l228-21", "id": "l22821"}
    SL21.finish(h21, "infra", "climb-21", "the driver: planted", driver=True)
    e21 = core.state_json("backoff.json", {}).get("slot:climb-21", {})
    left21 = e21.get("until", 0) - time.time()
    if not e21.get("driver") or not (0 < left21 <= core.cfg()["driver_fault_backoff_s"] + 5):
        fault(f"a slot's driver fault backs off {round(left21)} s naming driver {e21.get('driver')!r}: not driver_fault_backoff_s naming the driver's tree")
    if not core.backed_off("slot", "climb-21"):
        fault("a slot's driver fault did not back the slot off")
    core.driver_tree = lambda: "2" * 40
    if core.backed_off("slot", "climb-21"):
        fault("a slot waits out a driver fault of a driver it no longer runs")
    core.recovered("slot", "climb-21")
    SL21.finish(h21, "infra", "climb-21", "the slot's Kaimon: planted", driver=False)
    e21 = core.state_json("backoff.json", {}).get("slot:climb-21", {})
    core.driver_tree = lambda: "3" * 40
    if e21.get("driver") or not core.backed_off("slot", "climb-21"):
        fault(f"an infra outcome that is not the driver's backed off as a driver fault: {e21}")
    core.recovered("slot", "climb-21")
except Exception as e:
    fault(f"a slot's driver fault raised {type(e).__name__}: {str(e)[:240]}")
finally:
    core.driver_tree, SL21.driver_tree, SL21.unclaim = real21["tree"], real21["sltree"], real21["unclaim"]

# 22. landings in a row never starve a paused measurement (T5, back_mark): checks back to back, each finds the
# measurement stopped or done, and it finishes while they go on, within about one check a case (between two checks it
# runs at least to its next case). Section 19's stand-ins and lander (its helpers, as section 19 left them in place)
#: needs 19
#: limit 90
try:
    # the claim itself, by a live process of its own (a paused measurement's, written in its name): `next` holds the
    # lander's stopping check off a free lock and `wait` does not; either holds a non-stopping first taker (MRetake's
    # guard in formal(dev/formal/MeasureLocks.tla)); the claim gone, the lander takes it
    claimer = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(60)"])
    try:
        fd22 = os.open(f"{locks}/.julia-score.lock", os.O_CREAT | os.O_RDWR)
        seen22 = []
        for claim, first, stops in (("next", True, True), ("wait", True, True), ("next", True, False), ("wait", True, False)):
            open(M.back_mark("score"), "w").write(f"{claimer.pid} {door.BOOT} {door.proc_start(claimer.pid)} {claim}")
            took = M.take_lock(fd22, "score", first=first, stops=stops)
            if took:
                fcntl.flock(fd22, fcntl.LOCK_UN)
            seen22.append((claim, stops, took))
        os.remove(M.back_mark("score"))
        took = M.take_lock(fd22, "score", first=True, stops=True)
        if took:
            fcntl.flock(fd22, fcntl.LOCK_UN)
        seen22.append(("none", True, took))
        if seen22 != [("next", True, False), ("wait", True, True), ("next", False, False), ("wait", False, False), ("none", True, True)]:
            fault(f"a paused measurement's claim against the lander's first take (claim, stops, taken): {seen22}")
        os.close(fd22)
    finally:
        claimer.kill(); claimer.wait()
    n19, k19, s19, l19, run19 = measure19(8, 0.15, 30, 0.1, 0.0)
    t19 = sum(x[1] == "T" for x in l19)
    if n19 != 1 or k19 or any(x[1] not in ("T", "g", "Z") for x in l19) or not run19 or t19 > 8 + 3:
        fault(f"checks back to back: {n19} process(es), kills {k19}, the stand-in's states under the checks "
              f"{''.join(x[1] for x in l19)} (T stopped; g gone, Z ended), the measurement "
              f"{'finished while the checks went on' if run19 else 'finished only once they stopped'}, after {t19} checks "
              f"found it stopped (8 cases: at most 11) ({s19:.1f} s)")
except Exception as e:
    fault(f"checks back to back raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.cfg = real_cfg19
    for k, v in real19.items():
        setattr(door, k, v)

# 23. two slots and the lander in the review's F1 ordering, driven deterministically through the real julia_slot,
# door.using, watched, yield_slot and pause_in_place in three processes (formal(dev/formal/MeasureLocks.tla):
# MCMeasureLocksF1DeadlockBroken's trace): slot A measures; the lander's rebased check (REB: the verify lock without
# stops, the measure role) makes A yield, its role let go; slot B takes the free lock and the role while A's poll is held;
# the landing (lander.land itself, its layer, its quiet window and its check stood in) makes B pause in place; once the
# lander is done, A polls for a full 1.5 s while paused B's poll is held: A must not take the lock past B's claim (the
# F1 deadlock: A holding the lock and waiting on the role B holds, which the scaled role_wait turns into A's
# DoorError). The schedule is gates, not timing: each actor's yield and pause poll (its poll_s["yield"] sleep) waits on
# a gate file the section opens, and the lander waits on one before each round. Every process finishes; B's stand-in
# is stopped under the check and never restarted. The door's sudo steps (reap, clean, prepare, the role's STOP and CONT)
# are stood in by each process's own stand-in
#: limit 120
try:
    actor23 = __import__("textwrap").dedent(f"""
        import os, sys, time, json, signal, subprocess, contextlib
        os.environ["WT_CLIMB_STATE"] = {state!r}; os.chdir({repo!r}); sys.path.insert(0, {repo + "/dev/climb"!r})
        import door; door.TOP = {tmp!r}
        assert os.path.realpath(door.TOP) != os.path.realpath({LIVE_TOP!r}), "an actor on the live root"
        import core, measure as M, lander as L
        who, out, gates = sys.argv[1], sys.argv[2], sys.argv[3]
        GATED = 0.0777   # the yield and pause poll: a sleep of exactly this waits on this actor's gate
        real = M.cfg
        M.cfg = lambda: dict(real(), watch_s=0.05, poll_s=dict(real()["poll_s"], **{{"yield": GATED, "lock": 0.05, "landing_lock": 0.05}}))
        L.cfg = M.cfg
        class Clock:   # measure's time: its gated sleep waits for the gate
            def __getattr__(self, n):
                return getattr(time, n)
            def sleep(self, s):
                if s == GATED:
                    while not os.path.exists(f"{{gates}}/{{who}}"):
                        time.sleep(0.02)
                    s = 0.05
                time.sleep(s)
        M.time = Clock()
        M.ac_wait = lambda *a, **k: None
        M.landing_lock_held = lambda: False
        home = {tmp!r} + "/home23"
        door.home = lambda role: home
        door.open_home = lambda role, rel: open(f"{{home}}/{{rel}}", "rb") if os.path.exists(f"{{home}}/{{rel}}") else None
        door.tick = lambda *a, **k: None
        door.role_wait = lambda role: 12   # scaled: a stall on a role fails in seconds, as role_wait_s's 13.8 h would
        door.clean = door.prepare = lambda role: None
        st = {{}}
        def reap(role):
            p = st.get("p")
            if p is not None and p.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(p.pid, signal.SIGCONT); os.kill(p.pid, signal.SIGKILL)
                p.wait()
        door.reap = reap
        def sig(role, s, landing=False):
            p = st.get("p")
            if p is not None and p.poll() is None:
                os.kill(p.pid, signal.SIGSTOP if s == "STOP" else signal.SIGCONT)
                return 0
            return 1
        door.signal_role = sig
        M.role_stopped = lambda role: st.get("p") is None or st["p"].poll() is not None or \\
            subprocess.run(["ps", "-o", "state=", "-p", str(st["p"].pid)], capture_output=True, text=True).stdout.strip().startswith("T")
        log = lambda **kw: open(out, "a").write(json.dumps(dict(kw, who=who, t=round(time.time(), 2))) + "\\n")
        if who in ("A", "B"):
            n = int(sys.argv[4]); rel = f"m/{{who}}/compile"; os.makedirs(f"{{home}}/{{rel}}", exist_ok=True)
            labels = [f"a/{{i:02d}}" for i in range(n)]
            script = "".join(f'printf "started\\\\t{{l}}\\\\n" >> "$REC"; sleep 0.1; ' for l in labels) + 'printf "ended\\\\n" >> "$REC"'
            def start(env, log_):
                st["p"] = subprocess.Popen(["/bin/sh", "-c", script], env=dict(os.environ, REC=env["WT_SMOKE_COMPILED"]),
                                           stdout=log_, stderr=subprocess.STDOUT, start_new_session=True)
                open(out + "." + who + ".pid", "w").write(str(st["p"].pid))
                log(ev="start", pid=st["p"].pid)
                return st["p"]
            d = {tmp!r} + f"/d23{{who}}"; os.makedirs(d, exist_ok=True)
            try:
                with M.julia_slot("verify"):
                    log(ev="lock")
                    with door.using("measure"):
                        log(ev="role")
                        o = M.watched(start, "measure", d, rel, "compile", labels, 60, var="WT_SMOKE_COMPILED", keep_done=True,
                                      yields=True, rejoin=lambda: os.makedirs(f"{{home}}/{{rel}}", exist_ok=True))   # compile_dir's part
                log(ev="done", n=o[2], killed=sorted(o[1]))
            except Exception as e:
                log(ev="error", why=f"{{type(e).__name__}}: {{str(e)[:200]}}")
        else:   # the lander: a move's rebased check, then its landing, each when its gate opens
            def gate(g):
                while not os.path.exists(f"{{gates}}/{{g}}"):
                    time.sleep(0.02)
            gate("L1")
            with M.julia_slot("verify", first=True):
                with door.using("measure"):
                    log(ev="reb"); time.sleep(0.5)
            gate("L2")
            def states():
                o = {{}}
                for w in ("A", "B"):
                    with contextlib.suppress(OSError, ValueError):
                        pid = open(out + "." + w + ".pid").read()
                        o[w] = subprocess.run(["ps", "-o", "state=", "-p", pid], capture_output=True, text=True).stdout.strip()[:1] or "g"
                return o
            L.layer = lambda slot: None
            @contextlib.contextmanager
            def quiet():
                yield lambda: None
            L.quiesced = quiet
            def check(slot, item, c, scan, handed=None):
                log(ev="check", states=states()); time.sleep(0.5)
                return None, None, None, ""
            L._land = check
            L.land({tmp!r}, {{"hold": "l228-23"}})
            log(ev="landed")
        """)
    open(f"{tmp}/actor23.py", "w").write(actor23)
    os.makedirs(f"{tmp}/home23", exist_ok=True)
    out23, gates23 = f"{tmp}/run23.jsonl", f"{tmp}/gates23"
    open(out23, "w").close(); os.makedirs(gates23, exist_ok=True)
    def seen23(who, ev, limit=30):   # wait until `who` logged `ev` (or ended): the schedule's next step
        t_ = time.time()
        while time.time() - t_ < limit:
            evs = [json.loads(l) for l in open(out23).read().splitlines() if l.strip()]
            if any(e["who"] == who and e["ev"] in (ev, "error", "done") for e in evs):
                return True
            time.sleep(0.05)
        return False
    def open23(g):
        open(f"{gates23}/{g}", "w").close()
    procs23 = []
    try:
        procs23.append(subprocess.Popen([sys.executable, "-I", f"{tmp}/actor23.py", "A", out23, gates23, "40"]))
        seen23("A", "start")
        procs23.append(subprocess.Popen([sys.executable, "-I", f"{tmp}/actor23.py", "B", out23, gates23, "25"]))
        procs23.append(subprocess.Popen([sys.executable, "-I", f"{tmp}/actor23.py", "L", out23, gates23]))
        open23("L1")            # the rebased check: A yields (its poll held), the lander measures in the role
        seen23("B", "start")    # the lock free again, B (unheld) takes it and the role
        open23("A")             # A polls from now on
        open23("L2")            # the landing: B pauses in place
        seen23("L", "landed")
        time.sleep(1.5)         # A polls for 1.5 s while paused B's poll is held: with F1, A takes the lock past B's claim
        open23("B")
        t23 = time.time()
        for p in procs23:
            p.wait(timeout=max(1, 60 - (time.time() - t23)))
    except subprocess.TimeoutExpired:
        fault("two slots and the lander in F1's ordering did not finish in 60 s after the landing")
    finally:
        for p in procs23:
            if p.poll() is None:
                p.kill()
        for w in ("A", "B"):   # a stand-in left stopped is continued and ended: nothing of the section outlives it
            with contextlib.suppress(OSError, ValueError):
                pid = int(open(f"{out23}.{w}.pid").read())
                os.kill(pid, __import__("signal").SIGCONT); os.kill(pid, __import__("signal").SIGKILL)
    ev23 = [json.loads(l) for l in open(out23).read().splitlines() if l.strip()]
    done23 = {e["who"]: e for e in ev23 if e["ev"] in ("done", "error", "landed")}
    errs23 = [e for e in ev23 if e["ev"] == "error"]
    chk23 = [e for e in ev23 if e["ev"] == "check"]
    order23 = [e["who"] + ":" + e["ev"] for e in ev23]
    if errs23 or set(done23) != {"A", "B", "L"}:
        fault(f"two slots and the lander in F1's ordering: {errs23 or 'not every process finished'}; the order {order23}")
    elif not chk23 or chk23[0]["states"].get("B") != "T" or done23["B"].get("n") != 1:
        fault(f"F1's ordering: under the landing's check B's stand-in read {chk23[0]['states'] if chk23 else 'no check'} "
              f"(stopped, T, expected), B ran {done23['B'].get('n')} process(es) (1: never restarted); the order {order23}")
except Exception as e:
    fault(f"two slots and the lander raised {type(e).__name__}: {str(e)[:240]}")

# 24. a pause that ends without its lock never continues its processes (T5, the t5b review's must-fix;
# formal(dev/formal/MeasureLocks.tla): MAbort, ReapUnheld, MCMeasureLocksContUnheldBroken): a slot's measurement
# pauses in place for a landing (lander.land itself, its layer, its quiet window and its check stood in) and, while the
# lander's check holds the lock, its pause passes F7's limit; its stopped processes are reaped (door.reap's KILL,
# which reaches a stopped process), never continued first, and it restarts after the landing. The schedule is gates:
# the paused poll waits on one, the reap (stood in, KILL alone as door.reap) waits on another, and the check reads the
# stand-in's state once the reap has begun: `T` (stopped) is the only right reading. Section 25: the same pause ended
# by an exception while the lander holds the lock (launch.sh stop's TERM, which climb.py turns into SystemExit)
#: limit 90
def abort24(mode):
    """One run of the scenario (`limit` or `exc`): (its events, the fault lines it found)."""
    actor = __import__("textwrap").dedent(f"""
        import os, sys, time, json, signal, subprocess, contextlib
        os.environ["WT_CLIMB_STATE"] = {state!r}; os.chdir({repo!r}); sys.path.insert(0, {repo + "/dev/climb"!r})
        import door; door.TOP = {tmp!r}
        assert os.path.realpath(door.TOP) != os.path.realpath({LIVE_TOP!r}), "an actor on the live root"
        import core, measure as M, lander as L
        who, out, gates, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
        GATED = 0.0777   # the paused poll's sleep (poll_s["yield"]): it waits on this actor's gate
        real = M.cfg
        extra = dict(ship_kill_s=0, term_grace_s=0) if mode == "limit" and who == "M" else {{}}   # F7's limit at its first poll
        M.cfg = lambda: dict(real(), watch_s=0.05, **extra, poll_s=dict(real()["poll_s"], **{{"yield": GATED, "lock": 0.05,
                             "landing_lock": 0.05, **({{"land_job": 0}} if extra else {{}})}}))
        L.cfg = M.cfg
        class Clock:
            def __getattr__(self, n):
                return getattr(time, n)
            def sleep(self, s):
                if s == GATED:
                    while not os.path.exists(f"{{gates}}/{{who}}"):
                        time.sleep(0.02)
                    s = 0.05
                time.sleep(s)
        M.time = Clock()
        M.ac_wait = lambda *a, **k: None
        M.landing_lock_held = lambda: False
        home = {tmp!r} + "/home24" + mode
        door.home = lambda role: home
        door.open_home = lambda role, rel: open(f"{{home}}/{{rel}}", "rb") if os.path.exists(f"{{home}}/{{rel}}") else None
        door.tick = lambda *a, **k: None
        door.clean = door.prepare = lambda role: None
        log = lambda **kw: open(out, "a").write(json.dumps(dict(kw, who=who, t=round(time.time(), 2))) + "\\n")
        M.alarm = lambda name, title, text: log(ev="alarm", name=name)
        st = {{}}
        def state():
            p = st.get("p")
            return "g" if p is None or p.poll() is not None else \\
                subprocess.run(["ps", "-o", "state=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()[:1] or "g"
        def reap(role):   # door.reap: KILL alone (it reaches a stopped process); the paused role's, once the gate opens
            p = st.get("p")
            if p is not None and p.poll() is None:
                if st.pop("paused", False):
                    log(ev="reap", state=state())
                    while not os.path.exists(f"{{gates}}/R"):
                        time.sleep(0.02)
                with contextlib.suppress(ProcessLookupError):
                    os.kill(p.pid, signal.SIGKILL)
                p.wait()
        door.reap = reap
        def sig(role, s, landing=False):
            p = st.get("p")
            log(ev="sig", sig=s)
            if p is not None and p.poll() is None:
                st["paused"] = st.get("paused") or s == "STOP"
                os.kill(p.pid, signal.SIGSTOP if s == "STOP" else signal.SIGCONT)
                return 0
            return 1
        door.signal_role = sig
        M.role_stopped = lambda role: state() in ("T", "g")
        if who == "M":
            signal.signal(signal.SIGTERM, lambda s, f: sys.exit(128 + s))   # climb.py's: a TERM is SystemExit
            rel = f"m/M/compile"; os.makedirs(f"{{home}}/{{rel}}", exist_ok=True)
            labels = [f"a/{{i:02d}}" for i in range(12)]
            script = "".join(f'printf "started\\\\t{{l}}\\\\n" >> "$REC"; sleep 0.3; ' for l in labels) + 'printf "ended\\\\n" >> "$REC"'
            def start(env, log_):
                st["p"] = subprocess.Popen(["/bin/sh", "-c", script], env=dict(os.environ, REC=env["WT_SMOKE_COMPILED"]),
                                           stdout=log_, stderr=subprocess.STDOUT, start_new_session=True)
                open(out + ".M.pid", "w").write(str(st["p"].pid))
                log(ev="start", pid=st["p"].pid)
                return st["p"]
            d = {tmp!r} + "/d24" + mode; os.makedirs(d, exist_ok=True)
            try:
                with M.julia_slot("verify"):
                    with door.using("measure"):
                        o = M.watched(start, "measure", d, rel, "compile", labels, 60, var="WT_SMOKE_COMPILED", keep_done=True,
                                      yields=True, rejoin=lambda: os.makedirs(f"{{home}}/{{rel}}", exist_ok=True))
                log(ev="done", n=o[2], killed=sorted(o[1]))
            except BaseException as e:
                log(ev="exit" if isinstance(e, SystemExit) else "error", why=f"{{type(e).__name__}}: {{str(e)[:200]}}",
                    claim=os.path.exists(M.back_mark("verify")))
        else:   # the lander: one landing; its check reads the stand-in once the paused measurement's reap has begun
            L.layer = lambda slot: None
            @contextlib.contextmanager
            def quiet():
                yield lambda: None
            L.quiesced = quiet
            def check(slot, item, c, scan, handed=None):
                log(ev="check")
                t_ = time.time()
                while time.time() - t_ < 20 and not any(json.loads(l)["who"] == "M" and json.loads(l)["ev"] in ("reap", "done", "error", "exit")
                                                        for l in open(out).read().splitlines() if l.strip()):
                    time.sleep(0.02)
                with contextlib.suppress(OSError, ValueError):
                    pid = open(out + ".M.pid").read()
                    st_ = subprocess.run(["ps", "-o", "state=", "-p", pid], capture_output=True, text=True).stdout.strip()[:1] or "g"
                    log(ev="check-state", state=st_)
                return None, None, None, ""
            L._land = check
            L.land({tmp!r}, {{"hold": "l228-24"}})
            log(ev="landed")
        """)
    path = f"{tmp}/actor24.py"
    open(path, "w").write(actor)
    out, gates = f"{tmp}/run24{mode}.jsonl", f"{tmp}/gates24{mode}"
    os.makedirs(f"{tmp}/home24{mode}", exist_ok=True); os.makedirs(gates, exist_ok=True); open(out, "w").close()
    evs = lambda: [json.loads(l) for l in open(out).read().splitlines() if l.strip()]
    def seen(who, ev, limit=30):
        t_ = time.time()
        while time.time() - t_ < limit:
            if any(e["who"] == who and e["ev"] in (ev, "error", "done", "exit") for e in evs()):
                return True
            time.sleep(0.05)
        return False
    found, ps_ = [], []
    try:
        ps_.append(subprocess.Popen([sys.executable, "-I", path, "M", out, gates, mode]))
        seen("M", "start")
        ps_.append(subprocess.Popen([sys.executable, "-I", path, "L", out, gates, mode]))
        seen("L", "check")   # the landing holds the lock; the measurement is paused (its poll held)
        if mode == "limit":
            open(f"{gates}/M", "w").close()   # its poll runs: past the limit at once
        else:
            os.kill(ps_[0].pid, signal.SIGTERM)   # launch.sh stop's TERM while it waits without the lock
        seen("L", "check-state")
        open(f"{gates}/R", "w").close(); open(f"{gates}/M", "w").close()
        t_ = time.time()
        for p in ps_:
            p.wait(timeout=max(1, 45 - (time.time() - t_)))
    except subprocess.TimeoutExpired:
        found.append(f"a pause ended by {mode}: the processes did not finish within 45 s")
    finally:
        for p in ps_:
            if p.poll() is None:
                p.kill()
        with contextlib.suppress(OSError, ValueError):
            pid = int(open(f"{out}.M.pid").read())
            os.kill(pid, signal.SIGKILL)
    return evs(), found

def judge24(mode, ev, found):
    what = {"limit": "past F7's limit", "exc": "by an exception (TERM)"}[mode]
    order = [e["who"] + ":" + e["ev"] + (":" + e.get("sig", e.get("state", "")) if "sig" in e or "state" in e else "") for e in ev]
    cs = [e for e in ev if e["ev"] == "check-state"]
    fin = {e["who"]: e for e in ev if e["ev"] in ("done", "error", "exit", "landed")}
    if found:
        fault(f"{found[0]}; the order {order}")
    elif not cs or cs[0]["state"] != "T":
        fault(f"a pause ended {what} while the lander held the lock: under the landing's check the measurement's stand-in "
              f"read {cs[0]['state'] if cs else 'nothing'} (T, stopped until its reap, expected): its processes ran beside "
              f"the check; the order {order}")
    elif mode == "limit" and (fin.get("M", {}).get("ev") != "done" or fin["M"].get("n") != 2 or
                              not any(e["ev"] == "alarm" and e["name"] == "pause-verify" for e in ev)):
        fault(f"a pause past its limit: the measurement {fin.get('M')} (done, after one restart: 2 processes, expected) and "
              f"one `pause-verify` alarm; the order {order}")
    elif mode == "exc" and (fin.get("M", {}).get("ev") != "exit" or fin["M"].get("claim")):
        fault(f"a pause ended by an exception: the measurement {fin.get('M')} (SystemExit, its claim removed, expected); "
              f"the order {order}")
    elif fin.get("L", {}).get("ev") != "landed":
        fault(f"a pause ended {what}: the lander {fin.get('L')} (landed expected); the order {order}")

if __section__ == 24:
    try:
        judge24("limit", *abort24("limit"))
    except Exception as e:
        fault(f"a pause past its limit raised {type(e).__name__}: {str(e)[:240]}")

# 25. a pause ended by an exception while the lander holds its lock: its processes reaped, never continued (section 24's
# scenario, its paused measurement sent a TERM instead of its poll let past the limit)
#: needs 24
#: limit 90
try:
    judge24("exc", *abort24("exc"))
except Exception as e:
    fault(f"a pause ended by an exception raised {type(e).__name__}: {str(e)[:240]}")

# 26. the door has one root (door.locks_dir): a door whose LOCKS was moved apart from its TOP (the old harness's
# redirection, which on 2026-11-14 removed the live climb's TOP/in/measure.* run directories at a scratch use's entry)
# refuses at using(), give() and a measurement mark, and nothing under its TOP is touched; here both of its directories
# are scratch ones. And the harness's own refusal (root_refusal): a root holding a role generation a live process wrote
# is refused, one a dead process wrote is not, and the live TOP is refused unless this is the landing user inside a sandbox
#: limit 60
try:
    a26, b26 = f"{tmp}/top26", f"{tmp}/locks26"
    os.makedirs(f"{a26}/in/measure.someone"); open(f"{a26}/in/measure.someone/compile.log", "w").write("its log\n")
    script26 = __import__("textwrap").dedent(f"""
        import os, sys, json
        os.environ["WT_CLIMB_STATE"] = {state!r}; os.chdir({repo!r}); sys.path.insert(0, {repo + "/dev/climb"!r})
        import door
        door.TOP = {a26!r}; door.LOCKS = {b26!r}   # its locks moved, its root not
        door.reap = lambda role, tries=50: None
        door.clean = door.prepare = lambda role: None
        door.acl = lambda *a, **k: None
        import measure as M
        out = {{}}
        def give():
            door.HELD["measure"] = set(); door.give("measure", "x")
        for what, f in (("using", lambda: door.using("measure").__enter__()), ("give", give), ("mark", lambda: M.first_mark("verify"))):
            try:
                f(); out[what] = "ran"
            except door.DoorError as e:
                out[what] = "refused"
        print(json.dumps(out))
        """)
    r26 = subprocess.run([sys.executable, "-I", "-c", script26], capture_output=True, text=True, timeout=40)
    got26 = json.loads(r26.stdout.strip().splitlines()[-1]) if r26.stdout.strip() else r26.stderr.strip()[-300:]
    if got26 != {"using": "refused", "give": "refused", "mark": "refused"} or not os.path.exists(f"{a26}/in/measure.someone/compile.log"):
        fault(f"a door whose LOCKS was moved apart from its TOP: {got26} (each refused expected); its TOP's run directory "
              f"{'kept' if os.path.exists(f'{a26}/in/measure.someone/compile.log') else 'REMOVED'}")
    # the harness's refusal of a root a live climb uses
    sleeper26 = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(60)"])
    try:
        for name, pid in (("live", sleeper26.pid), ("dead", 999999)):
            os.makedirs(f"{tmp}/top26{name}/locks", exist_ok=True)
            open(f"{tmp}/top26{name}/locks/.role-measure.gen", "w").write(f"{pid}-1")
        sand26 = landing_sandboxed()
        seen26 = {"live": root_refusal(f"{tmp}/top26live") is not None, "dead": root_refusal(f"{tmp}/top26dead") is not None,
                  "the live TOP": root_refusal(LIVE_TOP, gens=False) is not None}
        if seen26 != {"live": not sand26, "dead": False, "the live TOP": not sand26}:
            fault(f"the harness's refusal of a live root (refused?): {seen26}, as the landing user in a sandbox: {sand26}")
    finally:
        sleeper26.kill(); sleeper26.wait()
except Exception as e:
    fault(f"the door's one root raised {type(e).__name__}: {str(e)[:240]}")

# 27. a move's measurement fault measures the same commit again (slots.remeasure, through slots.move_gate as climb()
# runs it): a fault of the driver's measurement (a FileNotFoundError of its run directory, a MeasureCut) is measured
# again, the climber's work kept; the same fault twice in a row goes on to the caller (the driver's own: a bug), as does
# any fault past task_wall_s from the first; a failure of the move's own (its problems, returned) and a power cut
# (on_ac's) are no fault of its
#: limit 60
import slots as SL27
real27 = SL27.cfg
try:
    out27 = {}
    calls = []
    def flaky27():
        calls.append(1)
        if len(calls) == 1:
            raise FileNotFoundError(2, "No such file or directory", "/x/in/measure.measure-t/compile.log")
        return (1, [], {"m/a": "passed"})
    out27["flaky"] = (SL27.move_gate(flaky27, {"key": "l228-27"}, "climb-9")(), len(calls))
    SL27.cfg = lambda: dict(real27(), task_wall_s=2)
    calls2 = []
    def same27():
        calls2.append(1); raise M.MeasureCut("the compile process of a measurement was cut: the same each time")
    try:
        SL27.remeasure(same27, "l228-27", "climb-9"); out27["same"] = ("returned", len(calls2))
    except M.MeasureCut:
        out27["same"] = ("raised", len(calls2))
    calls3 = []
    def drift27():
        calls3.append(1); raise OSError(f"a new fault each time: {len(calls3)}")
    try:
        SL27.remeasure(drift27, "l228-27", "climb-9"); out27["drift"] = "returned"
    except OSError:
        out27["drift"] = "raised" if len(calls3) > 2 else f"raised after {len(calls3)}"
    calls4 = []
    out27["own"] = (SL27.remeasure(lambda: (calls4.append(1), (0, ["its own problem"], {}))[1], "l228-27", "climb-9"), len(calls4))
    calls5 = []
    def cut27():
        calls5.append(1); raise core.PowerCut("the power rule stopped work")
    try:
        SL27.remeasure(cut27, "l228-27", "climb-9"); out27["power"] = "returned"
    except core.PowerCut:
        out27["power"] = ("raised", len(calls5))
    want27 = {"flaky": ((1, [], {"m/a": "passed"}), 2), "same": ("raised", 2), "drift": "raised",
              "own": ((0, ["its own problem"], {}), 1), "power": ("raised", 1)}
    if out27 != want27:
        fault(f"a move's measurement fault: {out27} (expected {want27})")
except Exception as e:
    fault(f"a move's measurement fault raised {type(e).__name__}: {str(e)[:240]}")
finally:
    SL27.cfg = real27

# 28. a landing's window never ends a climber's run (slots.through_pauses, door.paused_spans): the spans a window stopped
# a role, clipped to the run (and awake(), the walls' clock, the run's time less them); a run that ended without a
# commit after a window stopped it is resumed with the exact spans (pause_text), uncounted, at the move's cap
# (climber_cap), once per run a window stopped, ending at the first run no window stopped; a committed run, or one no
# window stopped, is not resumed. The window's record is stood in
#: limit 60
import slots as SL28
real28 = {"window": door._window, "clock": door.CLOCK}
try:
    door._window = lambda: {"done": {"slot1": [[100.0, 200.0], [300.0, 400.0]]}, "open": None, "roles": {}, "owner": None, "boot": 0}
    door.CLOCK = lambda: 350.0
    sp28, aw28 = door.paused_spans("slot1", 150.0), door.awake("slot1", 150.0)
    if sp28 != [(150.0, 200.0), (300.0, 350.0)] or abs(aw28 - 100.0) > 1e-9:
        fault(f"the spans a landing's window stopped a run since 150 (to 350): {sp28}, its awake time {aw28} "
              "([(150, 200), (300, 350)] and 100 expected)")
    def run28(outcomes, spans):
        """through_pauses over runs whose outcomes and stopped spans are given in order: (its answer, the texts it
        resumed with)"""
        o, s, texts = list(outcomes), list(spans), []
        cur = [s.pop(0)]
        def last():
            return cur[0]
        def again(text):
            texts.append(text); cur[0] = s.pop(0) if s else []
            return {"outcome": o.pop(0)}
        return SL28.through_pauses({"outcome": o.pop(0)}, last, again, "l228-28", "climb-9"), texts
    w1, w2 = [(100.0, 200.0)], [(300.0, 340.0)]
    got28 = {
        "stopped, then committed": run28(["gave-up", "committed"], [w1, []]),
        "stopped twice": run28(["gave-up", "gave-up", "gave-up"], [w1, w2, []]),
        "not stopped": run28(["gave-up"], [[]]),
        "committed though stopped": run28(["committed"], [w1]),
    }
    shape28 = {k: (v[0]["outcome"], len(v[1])) for k, v in got28.items()}
    want28 = {"stopped, then committed": ("committed", 1), "stopped twice": ("gave-up", 2), "not stopped": ("gave-up", 0),
              "committed though stopped": ("committed", 0)}
    if shape28 != want28:
        fault(f"a climber's runs past a landing's window (outcome, resumes): {shape28} (expected {want28})")
    t28 = got28["stopped, then committed"][1][0] if got28["stopped, then committed"][1] else ""
    if "stopped for a landing's check from" not in t28 or "(100 s)" not in t28 or "nothing is broken" not in t28:
        fault(f"the resume past a window does not name the stop and its seconds: {t28[:200]!r}")
    if SL28.climber_cap(True, False) is not None or SL28.climber_cap(False, True) is not None or \
            SL28.climber_cap(True, True) != SL28.cfg()["resume_cap_usd"]:
        fault("a resume past a landing's window capped as a counted resume (resume_cap_usd), or a first run so")
except Exception as e:
    fault(f"a climber's run past a landing's window raised {type(e).__name__}: {str(e)[:240]}")
finally:
    door._window, door.CLOCK = real28["window"], real28["clock"]

# 29. a plant the machine fails holds the item, never drops it (lander.held_result; dev/check.sh's 16, dev/ship.sh's
# `OTHER plant`): the load counter's plant failing is the machine's state, so the check exits 16, ship.sh names it OTHER
# plant (read from their texts: ship.sh is never run here), and the lander keeps the item queued with a backoff of
# driver_fault_backoff_s (lander:plant) where any other OTHER is retried and then dropped; NETWORK is held as before
#: limit 60
try:
    import time as _t29
    out29 = {k: L.held_result(*k, "the check's output") for k in (("OTHER", "plant"), ("OTHER", "check-1"), ("NETWORK", "fetch"),
                                                                    ("REFUSED", "held"), ("OWN", "check"))}
    want29 = {("OTHER", "plant"): True, ("OTHER", "check-1"): False, ("NETWORK", "fetch"): True, ("REFUSED", "held"): True,
              ("OWN", "check"): False}
    b29 = core.state_json("backoff.json", {}).get("lander:plant", {})
    left29 = b29.get("until", 0) - _t29.time()
    if out29 != want29 or not (0 < left29 <= core.cfg()["driver_fault_backoff_s"] + 5):
        fault(f"ship.sh's results the lander holds (held?): {out29} (expected {want29}); the plant's backoff {round(left29)} s "
              f"(driver_fault_backoff_s {core.cfg()['driver_fault_backoff_s']} expected)")
    chk29, ship29 = open(f"{root}/dev/check.sh").read(), open(f"{root}/dev/ship.sh").read()
    at29 = chk29.find("dev/tree_instructions.jl --plant > .wtd/tree_plant.out 2>&1 || {")
    blk29 = chk29[at29:].split("\n")[:6] if at29 >= 0 else []   # the plant's failure block: its own few lines
    end29 = next((l for l in blk29 if l.rstrip().endswith("}")), "")
    if at29 < 0 or "exit 16;" not in end29:
        fault("dev/check.sh's plant failure does not exit 16 (the machine's state, which the lander holds)")
    if not re.search(r'16\) echo "OTHER plant" ;;', ship29):
        fault("dev/ship.sh does not read the check's 16 as OTHER plant")
except Exception as e:
    fault(f"a plant the machine fails raised {type(e).__name__}: {str(e)[:240]}")
finally:
    core.recovered("lander", "plant"); core.recovered("lander")

# 30. a lander's rebase never leaves a generated block as the generator would not write it (measure.rebased): the move's
# one commit replayed onto origin by the real merge (git merge-tree with this tree's dev/merge_packages.sh, its blocks
# blanked) and src/julia/packages.jl's generated blocks then regenerated after EVERY replay, a new commit only when that
# changes the file. The generator is stood in (door.land_job: the block's names, those of the files under src/defs/,
# sorted and three a line), as the merge driver and git are not. Cases: the move alone edits the block, by hand and wrapped as the
# generator does not (2026-11-14 20:41:16Z: no merge driver ran, the block was not regenerated, and L210 dropped the
# approved move); both sides edit it (the driver blanks it); the replay already the generator's (no new commit); the
# generator ended by a signal (the machine's: ClimbError, which the lander's item_error holds) or refusing the tree
# (the commit's own)
#: limit 60
try:
    real30 = {"land_job": door.land_job, "environment": M.environment}
    START30, END30 = "# ---- the imports, written by dev/skeleton.jl write ----", "# ---- end of the imports ----"
    def gen30(names):
        rows = [", ".join(names[i:i + 3]) for i in range(0, len(names), 3)]
        return f"module X\n{START30}\nimport Y: " + ",\n    ".join(rows) + f"\n{END30}\nend\n"
    def file30(text, rel):
        os.makedirs(os.path.dirname(f"{repo}/{rel}"), exist_ok=True); open(f"{repo}/{rel}", "w").write(text)
    rc30 = [0]
    def land_job30(tree, script, log, out_files=(), wall=0, background=False, check=True):
        names = sorted(n.strip() for f_ in os.listdir(f"{tree}/src/defs") for n in open(f"{tree}/src/defs/{f_}") if n.strip())
        if rc30[0] == 0:
            open(f"{tree}/src/julia/packages.jl", "w").write(gen30(names))
        os.makedirs(f"{tree}/.wtd", exist_ok=True); open(f"{tree}/.wtd/regen.log", "w").write("the stand-in generator\n")
        return rc30[0]
    door.land_job, M.environment = land_job30, (lambda at: {})
    core.claim_repo()   # the scratch repository, the scratch state's own (the regen worktree is a write under it)
    shutil.copy(f"{root}/dev/merge_packages.sh", f"{repo}/dev/merge_packages.sh")
    file30("src/julia/packages.jl merge=wt-packages\n", ".gitattributes")
    base_names = ["a1", "a2", "a3", "a4"]
    file30("".join(n + "\n" for n in base_names), "src/defs/base.txt"); file30(gen30(base_names), "src/julia/packages.jl")
    g("add", "-A"); g("commit", "-qm", "base30"); b30 = g("rev-parse", "HEAD")
    def side30(name, defs, block, other=None):   # a commit on base30: its own names, its block as written by hand, a file
        g("checkout", "-q", "--detach", b30)
        file30("".join(n + "\n" for n in defs if n not in base_names), f"src/defs/{name}.txt")
        if block is not None:
            file30(block, "src/julia/packages.jl")
        if other:
            file30("x\n", other)
        g("add", "-A"); g("commit", "-qm", name); return g("rev-parse", "HEAD")
    hand30 = gen30(base_names).replace("a3,", "a3, a5,")   # a name added by hand to the first line: four on it
    got30 = {}
    # the move alone edits the block (origin's side another file): today's case
    o1 = side30("origin1", base_names, None, "src/other.jl")
    s1 = side30("move1", base_names + ["a5"], hand30)
    c1, why1 = M.rebased(b30, s1, o1)
    got30["the move's hand-wrapped block"] = g("show", f"{c1}:src/julia/packages.jl") == gen30(base_names + ["a5"]).strip() if c1 else why1
    # both sides edit the block: the driver blanks it, the regeneration writes it
    o2 = side30("origin2", base_names + ["a0"], gen30(base_names + ["a0"]))
    c2, why2 = M.rebased(b30, s1, o2)
    got30["both sides' blocks"] = g("show", f"{c2}:src/julia/packages.jl") == gen30(sorted(base_names + ["a0", "a5"])).strip() if c2 else why2
    # the replay already the generator's: no new commit (the merged tree's own)
    s3 = side30("move3", base_names + ["a5"], gen30(base_names + ["a5"]))
    c3, _ = M.rebased(b30, s3, o1)
    got30["already the generator's"] = bool(c3) and g("show", f"{c3}:src/julia/packages.jl") == gen30(base_names + ["a5"]).strip() \
        and g("rev-parse", f"{c3}^") == o1 and g("rev-parse", f"{c3}^{{tree}}") == g("merge-tree", "--write-tree", f"--merge-base={b30}", o1, s3).split()[0]
    # the generator ended by a signal: the machine's; refusing the tree: the commit's own
    rc30[0] = 137
    try:
        M.rebased(b30, s1, o1); got30["a signal's end"] = "returned"
    except core.ClimbError:
        got30["a signal's end"] = "the driver's"
    rc30[0] = 1
    c5, why5 = M.rebased(b30, s1, o1)
    got30["the generator refusing"] = "the commit's own" if c5 is None and why5 else f"{c5} {why5}"
    want30 = {"the move's hand-wrapped block": True, "both sides' blocks": True, "already the generator's": True,
              "a signal's end": "the driver's", "the generator refusing": "the commit's own"}
    if got30 != want30:
        fault(f"a lander's rebase and the generated blocks: {got30} (expected {want30})")
except Exception as e:
    fault(f"a lander's rebase and its generated blocks raised {type(e).__name__}: {str(e)[:240]}")
finally:
    door.land_job, M.environment = real30["land_job"], real30["environment"]

# 31. the score's parts run at the QoS score_background says (measure.part_background), a measurement's at
# measure_background's: each key read for its own role alone
#: limit 30
real31 = M.cfg
try:
    seen31 = {}
    for v in (False, True):
        M.cfg = lambda v=v: dict(real31(), score_background=v)
        seen31[v] = (M.part_background("score"), M.part_background("measure"))
    mb31 = real31()["measure_background"]
    if seen31 != {False: (False, mb31), True: (True, mb31)}:
        fault(f"the parts' QoS (background?) as score_background reads False and True, (score, measure): {seen31}")
except Exception as e:
    fault(f"the parts' QoS raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.cfg = real31

# 32. a test file too heavy for D14's band at origin holds a landing, never drops it (measure.src_set's origin_heavy,
# lander.src_refused), and a file is charged as it stands (measure.src_costs: recorded G x its size now / its size where
# the score measured it). On an origin whose score's record holds t00.jl past the band alone and t01.jl near it: a
# commit editing t00 is refused with t00 named origin's (the item held in its place, marked, never dropped); one
# shrinking t00 to a fiftieth fits (charged as it stands, not its old weight); one adding a large new file is not
# refused on its estimate, and is refused as its own (dropped) once a check has measured it past the band; one editing
# a light file is not refused; and the src-near note names t00 and t01, no other
#: limit 60
real32 = {"drop": L.drop}
try:
    checks32 = M.checks_measured()
    path32 = lambda G: M.predict({"f": G}, 350.0, True, 5, checks32, harness=False)[0]["path"]
    red32 = 180   # the fixture's D14_RED: a refusal and the src-near note read it, never D14_PACK
    big32 = next(G for G in range(200, 200000, 50) if path32(G) > red32 + 5)
    near32 = next(G for G in range(200, 200000, 10) if path32(G) >= 0.85 * red32 + 1)
    if path32(big32 / 50) > 0.85 * red32:
        fault(f"section 32's fixture: t00 shrunk to a fiftieth ({big32 / 50} G) would not fit")
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/test/src/t00.jl", "w").write("# t00\n" + "x" * 5000 + "\n")
    g("add", "-A"); g("commit", "-q", "-m", "origin32"); h32 = g("rev-parse", "HEAD")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h32)   # origin's head (d14_red reads its dev/check.sh)
    cost32 = {f: 100.0 for f in FILES}; cost32["t00.jl"], cost32["t01.jl"] = float(big32), float(near32)
    open(f"{state}/src-{h32[:8]}.tsv", "w").write(f"head\t{h32}\twarm\t350\n" + "".join(f"{f}\tpassed\t{cost32[f]}\t0.0\t\n" for f in FILES))
    open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h32}))
    def commit32(name, writes):
        g("checkout", "-q", "--detach", h32)
        for rel, text in writes.items():
            open(f"{repo}/{rel}", "w").write(text)
        g("add", "-A"); g("commit", "-q", "-m", name); return g("rev-parse", "HEAD")
    e_edit = commit32("edit", {"test/src/t00.jl": "# t00\n" + "x" * 5000 + "\n# one more case\n", "src/x.jl": "z = 3\n"})
    e_shrink = commit32("shrink", {"test/src/t00.jl": "# t00\n" + "x" * 100 + "\n", "src/x.jl": "z = 4\n"})
    e_new = commit32("new", {"test/src/t99.jl": "# t99\n" + "x" * 400000 + "\n", "src/x.jl": "z = 5\n"})
    e_light = commit32("light", {"test/src/t05.jl": "# t05 edited\n", "src/x.jl": "z = 6\n"})
    ss32 = {k: M.src_set(h32, c_, None) for k, c_ in (("edit", e_edit), ("shrink", e_shrink), ("new", e_new), ("light", e_light))}
    # the new file measured by a check (held_measured's record): a refusal reads it; on its estimate alone none does
    core.save_json(M.SRC_MEASURED, {"t99.jl": {"G": float(big32), "size": M.src_sizes(e_new)["t99.jl"]}})
    ss32["new, measured"] = M.src_set(h32, e_new, None)
    core.save_json(M.SRC_MEASURED, {})
    got32 = {k: (bool(v.get("refuse")), [f for f, _, _ in v.get("origin_heavy") or []]) for k, v in ss32.items()}
    want32 = {"edit": (True, ["t00.jl"]), "shrink": (False, []), "new": (False, []), "new, measured": (True, []), "light": (False, [])}
    if got32 != want32:
        fault(f"src_set's refusals (refused?, origin's heavy files): {got32} (expected {want32})")
    near_seen32 = core.state_json("alarms.json", {}).get("src-near")
    if near_seen32 != ["t00.jl", "t01.jl"]:
        fault(f"the src-near note named {near_seen32}, not t00.jl and t01.jl (past and near the band)")
    # the lander: held in its place for origin's file, dropped for its own
    dropped32 = []
    L.drop = lambda item, outcome, note, stop=True: dropped32.append((item["hold"], outcome))
    item32 = {"branch": "ready/l228-32", "hold": "l228-32", "hold_id": "l228-32", "sha": e_edit}
    core.update_json("ready.json", [], lambda q: q.append(dict(item32)))
    r32 = (L.src_refused(item32, ss32["edit"]), L.src_refused(item32, ss32["light"]), L.src_refused(dict(item32, hold="l228-32n"), ss32["new, measured"]))
    q32 = [x for x in core.state_json("ready.json", []) if x["branch"] == "ready/l228-32"]
    if r32 != (True, False, True) or dropped32 != [("l228-32n", "landing-red")] or not q32 or q32[0].get("split_held") != ["t00.jl"]:
        fault(f"the lander on a refused set: {r32} (held, not refused, dropped expected), drops {dropped32} (the new file's "
              f"alone), the held item {q32[0].get('split_held') if q32 else 'gone'} (in its place, t00.jl named)")
except Exception as e:
    fault(f"a test file too heavy at origin raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.drop = real32["drop"]
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")
    with contextlib.suppress(Exception):
        core.update_json("ready.json", [], lambda q: q.__setitem__(slice(None), [x for x in q if x.get("branch") != "ready/l228-32"]))

# 33. an estimate is never packed against nor dropped on (measure.src_costs, measure.src_set, lander.held_measured): a
# new test file no score has costed is charged the G per byte of the scored files its commit deletes (a split), else the
# highest G per byte of its directory's scored files, never the average, and a cost a check measured, scaled by size;
# a set whose own files hold an estimated one carries nothing from the ring (its position and its carried files kept);
# a check past D14's band with an estimated own file records the files' measured costs from its own records (a shard's
# first file less the warm-up) and holds the item in its place, never dropped; a file its records leave unmeasured is
# the driver's fault (item_error). 2026-11-14 22:35:31Z: the split of test/src/constants.jl was dropped for the
# lander's own under-estimate
#: limit 60
real33 = {"drop": L.drop, "item_error": L.item_error}
try:
    g("checkout", "-q", "--detach", h)
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)
    sz33 = M.src_sizes(h)
    cost33 = {f: 100.0 for f in FILES}; cost33["t00.jl"] = 1000.0   # t00: the dense one, ten times the others' G a byte
    open(f"{state}/src-{h[:8]}.tsv", "w").write(f"head\t{h}\twarm\t350\n" + "".join(f"{f}\tpassed\t{cost33[f]}\t0.0\t\n" for f in FILES))
    open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h}))
    def commit33(name, writes, rm=()):
        g("checkout", "-q", "--detach", h)
        for rel, text in writes.items():
            open(f"{repo}/{rel}", "w").write(text)
        for rel in rm:
            g("rm", "-q", rel)
        g("add", "-A"); g("commit", "-q", "-m", name); return g("rev-parse", "HEAD")
    s3 = sz33["t03.jl"]
    c_split = commit33("split", {"test/src/n1.jl": "#" * (2 * s3 - 1) + "\n"}, rm=("test/src/t03.jl",))
    c_new = commit33("new", {"test/src/n2.jl": "#" * 999 + "\n"})
    rows33 = {f: ("passed", cost33[f], 0.0, "") for f in FILES}
    got33 = {}
    got33["split: the deleted file's G a byte"] = round(M.src_costs(rows33, ["n1.jl"], c_split, h, ["t03.jl"])[0]["n1.jl"], 1)
    rate_max = max(cost33[f] / sz33[f] for f in FILES)
    got33["new: the densest of its directory"] = round(M.src_costs(rows33, ["n2.jl"], c_new, h)[0]["n2.jl"], 1)
    got33["measured, scaled"] = round(M.src_costs(rows33, ["n2.jl"], c_new, h, (), {"n2.jl": {"G": 50.0, "size": 500}})[0]["n2.jl"], 1)
    want33 = {"split: the deleted file's G a byte": round(100.0 / s3 * 2 * s3, 1), "new: the densest of its directory": round(rate_max * 1000, 1),
              "measured, scaled": 100.0}
    if got33 != want33:
        fault(f"an unscored file's cost: {got33} (expected {want33})")
    # nothing packed against an estimate: the ring's position and its carried files kept
    core.save_json(M.SRC_RING, {"hs": h[:10], "pos": 3, "carry": ["t05.jl", "t06.jl"]})
    ss33 = M.src_set(h, c_new, None)
    if ss33.get("est_own") != ["n2.jl"] or ss33.get("share") or ss33.get("pos_next") != 3 or ss33.get("dropped") != ["t05.jl", "t06.jl"]:
        fault(f"a set with an estimated own file: est_own {ss33.get('est_own')}, share {ss33.get('share')}, the ring's next position "
              f"{ss33.get('pos_next')} (3: its turn waits), carried {ss33.get('dropped')} (t05, t06 kept)")
    # a check past the band with an estimated own file: measured, recorded, held
    dropped33, errors33 = [], []
    L.drop = lambda item, outcome, note, stop=True: dropped33.append(outcome)
    L.item_error = lambda item, e: errors33.append(str(e)[:80])
    item33 = {"branch": "ready/l228-33", "hold": "l228-33", "hold_id": "l228-33", "sha": c_new, "rebased": {"commit": c_new}}
    core.update_json("ready.json", [], lambda q: q.append(dict(item33)))
    recs33 = "shard 1\nstarted\tn2.jl\nrow\tn2.jl\tpassed\t750.0\tYQ==\tpassed\nstarted\tt01.jl\nrow\tt01.jl\tpassed\t100.0\tYQ==\tpassed\nshard 2\n"
    L.held_measured(item33, dict(ss33, warm=350.0), recs33, "151")
    m33 = core.state_json(M.SRC_MEASURED, {}).get("n2.jl", {})
    q33 = [x for x in core.state_json("ready.json", []) if x["branch"] == "ready/l228-33"]
    if dropped33 or errors33 or m33.get("G") != 400.0 or m33.get("size") != M.src_sizes(c_new)["n2.jl"] or not q33 or q33[0].get("measured") != {"n2.jl": 400.0}:
        fault(f"a check past the band with an estimated own file: drops {dropped33}, errors {errors33}, recorded {m33} "
              f"(400 G: its shard's first file, 750 less the warm-up 350), the item {q33[0].get('measured') if q33 else 'gone'} (held)")
    L.held_measured(item33, dict(ss33, warm=350.0), "shard 1\n", "151")
    if dropped33 or len(errors33) != 1:
        fault(f"a check whose records measure no estimated own file: drops {dropped33}, driver faults {errors33} (one expected)")
except Exception as e:
    fault(f"an estimate's own section raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.drop, L.item_error = real33["drop"], real33["item_error"]
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")
    with contextlib.suppress(Exception):
        core.update_json("ready.json", [], lambda q: q.__setitem__(slice(None), [x for x in q if x.get("branch") != "ready/l228-33"]))

# 34. D14's red line is the one each check was judged on (dev/check.sh: D14_RED, or D14_RED_HARNESS when its ratchet ran
# the L228 harness, its split's `band`): check_verdict reads the line, the ship event keeps it, and the near-band note
# reads each check against its own line, so five harness checks at 250 s of 300 are no note and five at 160 s of 180 are
#: limit 30
try:
    v34 = os.path.join(tmp, "check34")
    open(v34, "w").write("0 250\nload 17 200.0 0.0 0.0\nwall 290\nband 300\nl228 harness\n")
    rc34, p34, sp34 = L.check_verdict(v34)
    if (rc34, p34, (sp34 or {}).get("band"), (sp34 or {}).get("l228")) != (0, 250, 300, "harness"):
        fault(f"check_verdict read ({rc34}, {p34}, band {(sp34 or {}).get('band')}, l228 {(sp34 or {}).get('l228')}), "
              "not (0, 250, band 300, l228 harness)")
    q34 = {"quiet": {"start": True, "end": True}}
    L.ship_event({"hold": "l228-34"}, dict(q34), "LANDED", "x", 0, 250, "", sp34, None)
    e34 = [e for e in core.events() if e.get("hold") == "l228-34"][-1]
    if (e34.get("d14") or {}).get("band") != 300:
        fault(f"the ship event kept D14's band {(e34.get('d14') or {}).get('band')}, not the 300 its check was judged on")
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)   # d14_red reads origin's dev/check.sh (D14_RED=180)
    def near34(path, band):
        with open(f"{state}/events.jsonl", "w") as ev:
            for i in range(5):
                ev.write(json.dumps({"t": f"2026-11-14T{i:02d}:00:00", "kind": "ship", "result": "LANDED:x", "check": 0, "path": path,
                                     "d14": {"verdict": "green", "band": band}, "probe": q34}) + "\n")
        core.update_json("alarms.json", {}, lambda a: a.pop("near-band-state", None))
        L.near_band()
        return any(e.get("name") == "near-band" for e in core.events() if e["kind"] == "alarm")
    got34 = (near34(250, 300), near34(160, 180))
    if got34 != (False, True):
        fault(f"the near-band note on five harness checks at 250 s of 300 and five at 160 s of 180: {got34} (no note, a note)")
except Exception as e:
    fault(f"D14's red line per check raised {type(e).__name__}: {str(e)[:240]}")
finally:
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

# 35. a check's ratchet is predicted from its own class's checks (measure.predict: a check whose ratchet runs the L228
# harness and one whose ratchet does not are two populations, a check that recorded no class left out), an item's class
# is read from its diff (l228scope) and its refusal reads that class's red line, and a refusal no test file makes is held
# as the predictor's, never dropped as the commit's. Today's history exactly: at 23:15:34Z the two judged checks read a
# ratchet of 89 s (22:35:31Z, the split) and 265 s (23:02:50Z, its ratchet ran the harness), neither recording a class;
# their median, 265, went into every prediction, and an item with no own and no unscored test file was dropped
#: limit 60
real35 = {"drop": L.drop}
try:
    c35 = core.cfg()
    def check35(t, path, rat, cls):
        sp = {"load": [0, 0, 0, 0], "ratchet": [rat, 600.0, 22.0, 170.0], "shards": [[80, 650, 0, 0]] * 5, "starts": [375.0] * 5}
        if cls:
            sp["l228"] = cls
        return {"t": t, "kind": "ship", "result": f"D14:{path}", "check": 10, "path": path, "split": sp,
                "src_set": {"src_change": False, "ran_cost": 1000.0, "predicted": {"path": 115.0}},
                "probe": {"quiet": {"start": True, "end": True}}}
    def history35(cls_a, cls_b):
        with open(f"{state}/events.jsonl", "w") as ev:
            ev.write(json.dumps(check35("2026-11-14T22:35:31", 151, 89, cls_a)) + "\n")
            ev.write(json.dumps(check35("2026-11-14T23:02:50", 265, 265, cls_b)) + "\n")
    def rts35():
        ch = M.checks_measured()
        return tuple(M.predict({}, 350.0, False, 5, ch, harness=k)[0]["ratchet"] for k in (False, True))
    history35(None, None)
    got35 = rts35()
    if got35 != (c35["src_prior_ratchet_s"], c35["src_prior_ratchet_harness_s"]):
        fault(f"on today's two judged checks with no class recorded the ratchet term reads {got35} (without, with the "
              f"harness), not the priors ({c35['src_prior_ratchet_s']}, {c35['src_prior_ratchet_harness_s']}): a check of "
              "unknown class is left out, never mixed")
    history35("none", "harness")
    if rts35() != (89, 265):
        fault(f"with their classes recorded the ratchet term reads {rts35()}, not (89, 265): each class its own checks")
    # an item of each class on today's history: a src move with no test file, a change to the harness's inputs
    history35(None, None)
    def commit35(at, name, writes):
        g("checkout", "-q", "--detach", at)
        for rel, text in writes.items():
            open(f"{repo}/{rel}", "w").write(text)
        g("add", "-A"); g("commit", "-q", "-m", name); return g("rev-parse", "HEAD")
    c_src = commit35(h, "src35", {"src/x.jl": "z = 35\n"})
    c_drv = commit35(h, "drv35", {"dev/check.sh": open(f"{repo}/dev/check.sh").read() + "# 35\n"})
    ss_src, ss_drv = M.src_set(h, c_src, None), M.src_set(h, c_drv, None)
    got = {"a src move": (ss_src.get("harness"), ss_src.get("band"), bool(ss_src.get("refuse")), (ss_src.get("own_unscored") or {}).get("ratchet")),
           "a harness change": (ss_drv.get("harness"), ss_drv.get("band"), bool(ss_drv.get("refuse")), (ss_drv.get("own_unscored") or {}).get("ratchet"), ss_drv.get("share"))}
    want = {"a src move": (False, 180, False, c35["src_prior_ratchet_s"]),
            "a harness change": (True, 300, False, c35["src_prior_ratchet_harness_s"], [])}
    if got != want:
        fault(f"the sets of today's items (class, red line, refused?, ratchet[, share]): {got} (expected {want})")
    # a refusal no test file makes (the line under the load and the ratchet alone): held as the predictor's, never dropped
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/dev/check.sh", "w").write("SHARDS=5\nD14_RED=60\nD14_RED_HARNESS=300\nD14_PACK=50\n")
    g("add", "-A"); g("commit", "-q", "-m", "origin35"); h35 = g("rev-parse", "HEAD")
    open(f"{state}/src-{h35[:8]}.tsv", "w").write(f"head\t{h35}\twarm\t350\n" + "".join(f"{f}\tpassed\t100.0\t0.0\t\n" for f in FILES))
    open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h35}))
    c_e = commit35(h35, "empty35", {"src/x.jl": "z = 36\n"})
    ss_e = M.src_set(h35, c_e, None)
    dropped35 = []
    L.drop = lambda item, outcome, note, stop=True: dropped35.append(outcome)
    item35 = {"branch": "ready/l228-35", "hold": "l228-35", "hold_id": "l228-35", "sha": c_e}
    core.update_json("ready.json", [], lambda q: q.append(dict(item35)))
    r35 = L.src_refused(item35, ss_e)
    q35 = [x for x in core.state_json("ready.json", []) if x["branch"] == "ready/l228-35"]
    held35 = [e for e in core.events() if e["kind"] == "land-held-predictor" and e.get("hold") == "l228-35"]
    if not (ss_e.get("refuse") and ss_e.get("base_over")) or r35 is not True or dropped35 or not q35 or not q35[0].get("predictor_held") or len(held35) != 1:
        fault(f"a refusal with no own or unscored file (refuse {ss_e.get('refuse')}, base_over {ss_e.get('base_over')}): "
              f"src_refused {r35}, drops {dropped35}, the item {'kept' if q35 else 'gone'} "
              f"{q35[0].get('predictor_held') if q35 else ''}, {len(held35)} land-held-predictor event(s) (held, one)")
except Exception as e:
    fault(f"a check's class raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.drop = real35["drop"]
    with contextlib.suppress(Exception):
        core.update_json("ready.json", [], lambda q: q.__setitem__(slice(None), [x for x in q if x.get("branch") != "ready/l228-35"]))

# 36. a case newly a gap, or newly outside, is admitted by the lead's ruling for that label and that kind alone
# (measure.admit_gap, `climb.py admit-gap`, gap-admits.json, read by measure.regressions): unadmitted it is refused
# with the command that admits it; admitted, refused no more; another kind of gap for the same label, or a wrong or
# errored reading, still refused (G1 stays G1); a malformed kind or an empty reason refused at the command; and the
# admission is seen at a score that reads the gap and ended (an event) when a score then reads anything else, when the
# case leaves the corpus, or when no score has read it so within gap_admit_max_s. 2026-11-14 23:21:31Z and 23:58:19Z:
# hold f96199579c's correct port was refused twice "newly a gap (needs a ruling)" and nothing read a ruling
#: limit 30
try:
    J36 = ("a" * 40, "j36")
    R36 = lambda l, o, w="": M.Row((l, o, 1.0, w), J36)
    W36 = ("(its 1723 leaves of Bool) the judge builds no reader of more than LEAVES_MAX = 1000 leaves, and this case's "
           "answer has more")
    before36 = {l: R36(l, "unported", "unported at x") for l in ("g/a", "g/b", "g/c")}
    after36 = {"g/a": R36("g/a", "judge-gap", W36), "g/c": R36("g/c", "outside"),
               "g/b": R36("g/b", "judge-gap", "the judge's wire has no leaf kind for Foo (a new leaf kind is the judge's edit)")}
    h36 = {"key": "k36", "cases": ["x/y"]}
    kind36 = M.gap_kind("judge-gap", W36)
    if kind36 != "judge-gap: no reader of more than LEAVES_MAX":
        fault(f"the kind of a gap past LEAVES_MAX reads {kind36!r}, not 'judge-gap: no reader of more than LEAVES_MAX'")
    p36 = M.regressions(h36, set(before36), before36, after36)
    if len(p36) != 3 or any(sum(f" {l} " in p_ + " " or f" {l}:" in p_ for p_ in p36) != 1 for l in ("g/a", "g/b", "g/c")) \
            or not any(f"climb.py admit-gap g/a '{kind36}'" in p_ for p_ in p36):
        fault(f"unadmitted, the three cases newly gaps or outside read {p36} (each refused, g/a's naming its admit command)")
    for bad36 in ((kind36, "  "), ("judge-gap", "a reason"), ("wrong", "a reason")):
        try:
            M.admit_gap("g/a", *bad36); fault(f"admit-gap took {bad36} (a malformed kind or an empty reason)")
        except core.ClimbError:
            pass
    M.admit_gap("g/a", kind36, "a correct port of LLVM's expandSADDSUBO; the judge's leaf bound is the lead's to raise")
    M.admit_gap("g/c", "outside", "ruled outside the subset")
    p36b = M.regressions(h36, set(before36), before36, after36)
    if len(p36b) != 1 or "g/b" not in p36b[0]:
        fault(f"admitted g/a (that kind) and g/c (outside): the refusals read {p36b}, not g/b's alone")
    other36 = dict(after36, **{"g/a": R36("g/a", "judge-gap", "the judge's wire has no leaf kind for Bar (a new leaf kind ...)")})
    wrong36 = dict(after36, **{"g/a": R36("g/a", "wrong", "planted")})
    if not any("g/a" in p_ for p_ in M.regressions(h36, set(before36), before36, other36)):
        fault("an admission of one kind of gap admitted another kind for the same case")
    if not any(p_.startswith("G1 wrong g/a") for p_ in M.regressions(h36, set(before36), before36, wrong36)):
        fault("an admitted case that reads wrong is not G1")
    ev36 = [e for e in core.events() if e["kind"] == "gap-admitted"]
    if [e["label"] for e in ev36] != ["g/a", "g/c"]:
        fault(f"the admissions' events: {[e.get('label') for e in ev36]} (g/a, g/c)")
    # the admission at the scores: unseen while the port has not landed, seen at the gap, ended when the judge reads it
    row36 = lambda l, o, w="": (l, o, 1.0, w)
    M.settle_gap_admits({"g/a": row36("g/a", "unported"), "g/c": row36("g/c", "outside")})
    a36 = core.state_json(M.GAP_ADMITS, {})
    if set(a36) != {"g/a", "g/c"} or a36["g/a"]["seen"] or not a36["g/c"]["seen"]:
        fault(f"after a score before the port landed the admissions read {a36} (both kept, g/c seen, g/a not)")
    M.settle_gap_admits({"g/a": row36("g/a", "judge-gap", W36), "g/c": row36("g/c", "outside")})
    M.settle_gap_admits({"g/a": row36("g/a", "passed")})
    end36 = {e["label"]: e["why"] for e in core.events() if e["kind"] == "gap-admit-ended"}
    if core.state_json(M.GAP_ADMITS, {}) or set(end36) != {"g/a", "g/c"}:
        fault(f"after the judge read g/a and g/c left the corpus the admissions read {core.state_json(M.GAP_ADMITS, {})}, "
              f"ended {end36} (both ended)")
    M.admit_gap("g/d", "outside", "stale")
    core.update_json(M.GAP_ADMITS, {}, lambda a: a["g/d"].__setitem__("t", "2026-01-01T00:00:00+00:00"))
    M.settle_gap_admits({"g/d": row36("g/d", "unported")})
    if "g/d" in core.state_json(M.GAP_ADMITS, {}):
        fault("an admission no score read as its gap within gap_admit_max_s was kept")
except Exception as e:
    fault(f"a gap admitted by the lead's ruling raised {type(e).__name__}: {str(e)[:240]}")

# 37. a check red on D14's time alone, judged, its own files holding no estimate (lander.d14_judged_red): its own
# measured files past the line where no file is not, dropped as the commit's own naming the file; else the item waits
# on its own timer at the queue's tail (no lander-wide backoff), the round trying the items behind it, and is dropped
# uncharged at d14_tries. 2026-11-14 23:02:50Z: one item red at 265 s held the queue's head and idled the slots
#: limit 60
real37 = {k: getattr(L, k) for k in ("drop", "pause", "waits", "power_ok", "reconcile", "fixfirst_overdue", "fixfirst_binds",
                                      "src_unverified", "unverified_binds", "src_gap_spawn", "origin_scored", "admits", "land_tree")}
try:
    g("checkout", "-q", "--detach", h)
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)
    open(f"{repo}/test/src/t03.jl", "a").write("# 37\n"); g("add", "-A"); g("commit", "-q", "-m", "c37"); c37 = g("rev-parse", "HEAD")
    ss37 = M.src_set(h, c37, None)
    if ss37.get("why") or ss37.get("own") != ["t03.jl"] or ss37.get("harness") is not False:
        fault(f"section 37's fixture: the set {ss37.get('why') or (ss37.get('own'), ss37.get('harness'))}")
    rec37 = lambda G: f"shard 1\nstarted\tt03.jl\nrow\tt03.jl\tpassed\t{G}\tYQ==\tpassed\nshard 2\n"
    dropped37 = []
    L.drop = lambda item, outcome, note, stop=True: dropped37.append((item["hold"], outcome, stop, note))
    mk37 = lambda n: {"branch": f"ready/l228-37{n}", "hold": f"l228-37{n}", "hold_id": f"l228-37{n}", "sha": c37}
    core.save_json("ready.json", [mk37("a"), mk37("b")])
    # its own file, measured past the line: the commit's own, the file named
    L.d14_judged_red(mk37("a"), ss37, rec37(350.0 + 60000), "265")
    if len(dropped37) != 1 or dropped37[0][1] != "landing-red" or "test/src/t03.jl" not in dropped37[0][3]:
        fault(f"an own file measured past the line: drops {[(d[0], d[1]) for d in dropped37]} (l228-37a landing-red naming t03.jl)")
    # its own file light: the item waits at the tail on its own timer, no lander-wide backoff, then dropped uncharged
    dropped37.clear(); core.save_json("ready.json", [mk37("a"), mk37("b")])
    L.d14_judged_red(mk37("a"), ss37, rec37(350.0 + 100), "190")
    q37 = core.state_json("ready.json", [])
    if dropped37 or [x["hold"] for x in q37] != ["l228-37b", "l228-37a"] or not q37[1].get("not_before", 0) > time.time() \
            or q37[1].get("d14_tries") != 1 or "lander:d14" in core.state_json("backoff.json", {}):
        fault(f"a red its own light file did not make: drops {dropped37}, the queue {[(x['hold'], x.get('d14_tries')) for x in q37]} "
              f"(l228-37b first, l228-37a waiting at the tail), backoffs {sorted(core.state_json('backoff.json', {}))}")
    # the round tries the item behind it while it waits
    reached37 = []
    class Stop37(Exception):
        pass
    L.pause, L.waits, L.power_ok, L.reconcile = (lambda: False), (lambda *a: False), (lambda: True), (lambda: None)
    L.fixfirst_overdue, L.fixfirst_binds, L.unverified_binds = (lambda: []), (lambda o: None), (lambda b, f: None)
    L.src_unverified, L.src_gap_spawn, L.origin_scored = (lambda h_: (0, [])), (lambda o: None), (lambda: True)
    L.admits = lambda x, o=None, s=None: reached37.append(x["hold"]) or True
    def stop37():
        raise Stop37()
    L.land_tree = stop37
    core.save_json("ready.json", [q37[1], q37[0]])   # the waiting item first: the round passes it by
    try:
        L.land_round()
    except Stop37:
        pass
    if reached37 != ["l228-37b"]:
        fault(f"the round with a waiting item at the head reached {reached37}, not the item behind it")
    for n37, path37 in ((2, "191"), (3, "192")):
        it37 = next(x for x in core.state_json("ready.json", []) if x["hold"] == "l228-37a")
        L.d14_judged_red(it37, ss37, rec37(350.0 + 100), path37)
    if [(d[0], d[1], d[2]) for d in dropped37] != [("l228-37a", "landing-failed", False)]:
        fault(f"at d14_tries reds of the machine's: drops {[(d[0], d[1], d[2]) for d in dropped37]} (l228-37a, uncharged)")
except Exception as e:
    import traceback
    fault(f"a judged D14 red raised {type(e).__name__}: {str(e)[:240]} {traceback.format_exc()[-300:]}")
finally:
    for k, v in real37.items():
        setattr(L, k, v)
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

# 38. every L228 break runs once a driver landing, after it lands (measure.l228_sweep_due, measure.l228_sweep, through
# the src-gap job): due at a head whose landings since the last swept head change an input of the harness, not at one
# that changes none; run as the landing user's job with no test set at background QoS (door.land_job, stood in, writing
# the result dev/l228_sweep.py writes); each fault filed a fix-first (`l228 ...`, a known red, the lead's hand: no
# climber's hold), the head recorded so it is swept once; a clean sweep clears the entries it no longer reads
#: limit 60
real38 = door.land_job
try:
    core.claim_repo()
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/dev/check.sh", "a").write("# 38\n"); g("add", "-A"); g("commit", "-q", "-m", "drv38"); d38 = g("rev-parse", "HEAD")
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/src/x.jl", "a").write("# 38\n"); g("add", "-A"); g("commit", "-q", "-m", "src38"); s38 = g("rev-parse", "HEAD")
    with contextlib.suppress(FileNotFoundError):
        os.remove(f"{state}/{M.L228_SWEEP}")
    due38 = (M.l228_sweep_due(d38), M.l228_sweep_due(s38))
    if due38 != (True, False):
        fault(f"the sweep due at a driver landing and at a src landing: {due38} (True, False expected)")
    calls38, res38 = [], {}
    def lj38(wt, script, log, outs, wall, background=False, check=True):
        calls38.append((script, check, background))
        os.makedirs(f"{wt}/.wtd", exist_ok=True)
        json.dump(res38, open(f"{wt}/.wtd/l228-sweep.json", "w"))
        return 0
    door.land_job = lj38
    miss38 = "L228's behaviour negative missed: a planted break (section 3)"
    res38.update({"tree": [], "missed": [miss38], "anchors": [], "runner": [], "ran": 110, "of": 110, "cpu_s": 1.0, "wall_s": 1.0})
    M.l228_sweep(d38)
    ff38 = [f for f in core.state_json("fixfirst.json", []) if f["key"].startswith("l228 ")]
    if [f["key"] for f in ff38] != [f"l228 {miss38}"] or not core.known_red(ff38[0]) or core.fixfirst_problem(ff38[0]) is not None:
        fault(f"a break the sweep missed filed {[(f['key'][:60], core.known_red(f)) for f in ff38]} (one l228 known red)")
    if any(x["key"].startswith("l228 ") for x in core.holds([])):
        fault("an L228 sweep's fault is offered to the climbers as a hold (the harness is the lead's hand)")
    if not calls38 or calls38[0][1:] != (False, True) or "dev/l228_sweep.py" not in calls38[0][0]:
        fault(f"the sweep's job: {calls38} (dev/l228_sweep.py, no test set, background QoS)")
    if M.l228_sweep_due(d38):
        fault("a head swept once is due again")
    res38.update({"missed": []})
    M.l228_sweep(d38)
    if any(f["key"].startswith("l228 ") for f in core.state_json("fixfirst.json", [])):
        fault("a clean sweep left the fault it no longer reads filed")
except Exception as e:
    import traceback
    fault(f"the sweep after a driver landing raised {type(e).__name__}: {str(e)[:240]} {traceback.format_exc()[-300:]}")
finally:
    door.land_job = real38

# 39. each estimated file's measured G is recorded from every check's own records, green or red (lander.record_measured,
# called after every check's verified rows): the next set charges it, scaled by size, not the estimate. 2026-11-15
# 00:24:26Z: three new files estimated at 10,087.7 G ran at about 2,850 G, and every landing paid the estimate
#: limit 30
try:
    g("checkout", "-q", "--detach", h)
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)
    open(f"{repo}/test/src/n39.jl", "w").write("#" * 999 + "\n"); g("add", "-A"); g("commit", "-q", "-m", "c39"); c39 = g("rev-parse", "HEAD")
    ss39 = M.src_set(h, c39, None)
    if "n39.jl" not in (ss39.get("estimated") or []):
        fault(f"section 39's fixture: n39.jl is not estimated ({ss39.get('estimated')})")
    est39 = M.src_costs({f: ("passed", 100.0, 0.0, "") for f in FILES}, ["n39.jl"], c39, h)[0]["n39.jl"]
    rec39, miss39 = L.record_measured({"hold": "l228-39", "sha": c39, "rebased": {"commit": c39}}, dict(ss39, warm=350.0),
                                      "shard 1\nstarted\tn39.jl\nrow\tn39.jl\tpassed\t400.0\tYQ==\tpassed\n")
    now39 = M.src_costs({f: ("passed", 100.0, 0.0, "") for f in FILES}, ["n39.jl"], c39, h, (), core.state_json(M.SRC_MEASURED, {}))[0]["n39.jl"]
    if rec39 != {"n39.jl": 50.0} or miss39 or abs(now39 - 50.0) > 0.01 or abs(est39 - 50.0) < 1:
        fault(f"a green check's measure of an estimated file: recorded {rec39} (50.0 G: 400 less the warm-up 350), "
              f"unmeasured {miss39}, then charged {now39} (the estimate was {est39})")
except Exception as e:
    fault(f"recording a measured cost raised {type(e).__name__}: {str(e)[:240]}")
finally:
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")

# 40. the replay of the lander's next round (dev/climb/walk.py, dev/driver_evidence.sh's third stage) on a copy of the
# state: it refuses the state itself when no copy (no events.jsonl), replays a named item and its own two (a src move,
# a harness change), each landing on this state, the harness change in the harness's class on its line; and an item
# the lander would hold (no test file under the line, an origin whose D14_RED is 30) reads HELD, the replay red
#: limit 60
try:
    g("checkout", "-q", "--detach", h)
    import shutil as _sh40
    st40 = f"{tmp}/state40"; _sh40.copytree(state, st40)
    w40 = lambda *a: subprocess.run([sys.executable, "-I", f"{repo}/dev/climb/walk.py", *a], capture_output=True, text=True, cwd=repo)
    r40 = w40(st40, h, sha)
    o40 = r40.stdout
    if r40.returncode != 0 or o40.count("-> lands") != 3 or "class harness, line 300 s" not in o40:
        fault(f"walk on the state copy: exit {r40.returncode}: {o40.strip()[-400:]} (three items landing, the harness change on 300 s)")
    # the landing's geometry: its TMPDIR lies under the live door's root (/Users/Shared/wt-climb/u/_wtland/tmp), so
    # every scratch root a walk makes is under it; the walk runs there and removes its scratch root (2026-11-15
    # 03:11:53Z: a prefix test refused it, and four walk-top-* stayed in the landing user's tmp)
    root40 = f"{tmp}/root40"; tmp40 = f"{root40}/u/_wtland/tmp"; os.makedirs(tmp40)
    g40 = subprocess.run([sys.executable, "-I", f"{repo}/dev/climb/walk.py", st40, h], capture_output=True, text=True, cwd=repo,
                         env=dict(os.environ, TMPDIR=tmp40, WT_L228_LIVE_TOP=root40))
    left40 = [x for x in os.listdir(tmp40) if x.startswith("walk-top-")]
    if g40.returncode != 0 or left40:
        fault(f"walk with its TMPDIR under the live root's stand-in: exit {g40.returncode}: {g40.stdout.strip()[-200:]}; "
              f"left {left40} (it runs, and removes its scratch root)")
    e40 = w40(f"{tmp}/none40", h)
    if e40.returncode != 2 or "refused" not in e40.stdout:
        fault(f"walk on no state copy: exit {e40.returncode} {e40.stdout.strip()[:160]} (refused)")
    open(f"{repo}/dev/check.sh", "w").write("SHARDS=5\nD14_RED=30\nD14_RED_HARNESS=300\nD14_PACK=20\n")
    g("add", "-A"); g("commit", "-q", "-m", "origin40"); h40 = g("rev-parse", "HEAD")
    open(f"{st40}/src-{h40[:8]}.tsv", "w").write(f"head\t{h40}\twarm\t350\n" + "".join(f"{f}\tpassed\t100.0\t0.0\t\n" for f in FILES))
    open(f"{st40}/src-latest.json", "w").write(json.dumps({"head": h40}))
    r40b = w40(st40, h40)
    if r40b.returncode != 1 or "HELD as the predictor's" not in r40b.stdout:
        fault(f"walk where no test file fits the line: exit {r40b.returncode}: {r40b.stdout.strip()[-300:]} (HELD, red)")
except Exception as e:
    fault(f"the replay raised {type(e).__name__}: {str(e)[:240]}")

# 41. a set the lander handed with no file (a change whose own files and share are none): a void reading of it is the
# check's fault, the driver's, held and tried again uncharged, never landing-red (lander.empty_set_void); and
# dev/src_verdict.sh reads a shard whose exit status is no number, or whose records are missing, as void, named, never a
# test that errors ("integer expression expected"). 2026-11-15 02:20:43Z: a model commit's empty set read void at five
# shards, src_verdict.sh line 68 erred four times, and the commit was dropped as its own
#: limit 30
real41 = {"item_error": L.item_error}
try:
    set41 = f"{tmp}/set41"; open(set41, "w").write("# head x\n")
    v41 = subprocess.run(["bash", f"{root}/dev/src_verdict.sh", set41, "", f"{tmp}/none41.out"], capture_output=True, text=True)
    if v41.returncode != 15 or "is no number" not in v41.stdout or "integer expression" in v41.stderr:
        fault(f"src_verdict on a shard with no exit status and no records: exit {v41.returncode}, {v41.stdout.strip()[:200]!r}, "
              f"stderr {v41.stderr.strip()[:120]!r} (void, named, no shell error)")
    errs41 = []
    L.item_error = lambda item, e: errs41.append(str(e)[:80])
    it41 = {"hold": "l228-41", "sha": "0" * 40, "branch": "ready/l228-41"}
    got41 = (L.empty_set_void(it41, "OWN", "void", {}, []), L.empty_set_void(it41, "OWN", "void", {}, ["t00.jl"]),
             L.empty_set_void(it41, "D14", "200", {}, []))
    if got41 != (True, False, False) or len(errs41) != 1:
        fault(f"a void reading of an empty set: {got41} (taken as the driver's only for OWN void on an empty set), "
              f"driver faults {errs41} (one)")
except Exception as e:
    fault(f"an empty handed set raised {type(e).__name__}: {str(e)[:240]}")
finally:
    L.item_error = real41["item_error"]

# 42. a score's rows are settled against the previous record before they are written (measure.settle_costs): a passed
# file src_run left unmeasured (a restarted process's first file) carries the previous record's cost, scaled, named;
# a measured cost past src_cost_jump of the previous with the size unchanged is a fault (an event, a note) and the
# previous cost is kept. 2026-11-15: classes.jl, unmeasured at the score of f1435467, was charged 3,723.4 G
#: limit 30
try:
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/src/x.jl", "a").write("# 42\n"); g("add", "-A"); g("commit", "-q", "-m", "c42"); h42 = g("rev-parse", "HEAD")
    open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h}))   # the previous record: the prologue's, every file 100 G
    rows42 = {"t00.jl": ("passed", None, 3.0, ""), "t01.jl": ("passed", 1000.0, 3.0, ""), "t02.jl": ("passed", 120.0, 3.0, ""),
              "t03.jl": ("failed", 90.0, 3.0, "a red")}
    got42 = M.settle_costs(rows42, h42)
    ev42 = {e["kind"]: e for e in core.events() if e["kind"] in ("src-cost-carried", "src-cost-jump")}
    if (got42["t00.jl"][1], got42["t01.jl"][1], got42["t02.jl"][1], got42["t03.jl"]) != (100.0, 100.0, 120.0, rows42["t03.jl"]) \
            or "carried from" not in got42["t00.jl"][3] or "t00.jl" not in ev42.get("src-cost-carried", {}).get("files", {}) \
            or "t01.jl" not in ev42.get("src-cost-jump", {}).get("files", {}):
        fault(f"settled rows {{f: (cost, why)}}: {({f: (r[1], r[3][:40]) for f, r in got42.items()})}, events {sorted(ev42)} "
              "(t00 carried 100.0, t01's jump refused for 100.0, t02 kept, a red untouched)")
except Exception as e:
    fault(f"settling a score's costs raised {type(e).__name__}: {str(e)[:240]}")

# 43. a landing-red's note leads with the check's own failure lines (lander.landing_reason: every ratchet `✗` line and
# the broken locks' names, never a lock's description), and drop() keeps a note's head, so the climber's handoff and
# the stopped event carry the reason. 2026-11-15: hold 17c2f6adf0 was dropped three times for one L227 `✗` line, each
# note the tail of the lock's description
#: limit 30
real43 = {}
try:
    f43 = f"{tmp}/failed43"; os.makedirs(f43)
    why43 = ("the change rewrites the debt-listed julia/parity.jl _cpp_declares and leaves its line in "
             "dev/quarantine_unpinned.txt: pin its source and delete the line")
    open(f"{f43}/ratchet.out", "w").write("L226_x     0  🔒 locked   # a\n    ✗ " + why43 + "\nL227_removed_tests_are_named     1  ❌ "
                                          "LOCK BROKEN (want 0)   # " + "a removal named " * 200 + "tion each refused, a definition gone\n")
    open(f"{f43}/check.log", "w").write("check: the ratchet fails (exit 1)\n")
    r43 = L.landing_reason("OWN", "check", "ship: a commit's check is red\nship-result: OWN check\n", f43)
    if not r43.startswith("✗ " + why43[:60]) or "broken: L227_removed_tests_are_named" not in r43 or "tion each refused" in r43:
        fault(f"the landing's reason reads {r43[:300]!r} (the ✗ line first, the lock by name, no description)")
    it43 = {"branch": "ready/l228-43", "hold": "l228-43", "hold_id": "l228-43", "sha": "0" * 40, "kind": "move"}
    core.update_json("ready.json", [], lambda q: q.append(dict(it43)))
    L.drop(it43, "landing-red", r43 + "\n" + "a long check output " * 200)
    st43 = [e for e in core.events() if e["kind"] == "stopped" and e.get("hold") == "l228-43"]
    ho43 = core.state_json("handoffs.json", {}).get("l228-43", "")
    if not st43 or "pin its source" not in st43[-1].get("note", "") or "pin its source" not in ho43:
        fault(f"the dropped move's note: stopped {(st43[-1].get('note', '')[:160] if st43 else 'none')!r}, handoff {ho43[:160]!r} "
              "(each carries the ✗ line)")
except Exception as e:
    fault(f"a landing's reason raised {type(e).__name__}: {str(e)[:240]}")
# 44. the power rule reads the direction of charge (core.power_read, core.power_held, core.power_ok, core.power_line, P):
# at battery_floor_pct while the battery discharges, on battery or on an adapter under adapter_full_watts though the
# source reads AC, work is held until the floor plus battery_resume_margin_pct or a full adapter; a weak adapter
# charging, a full adapter, and plain battery above the floor hold nothing; the status line says which, and what the
# hold leaves running. 2026-11-14: a 30 W adapter took the battery from 81% to 5% under the climb while "on AC"
#: limit 30
real44 = {"sh": core.sh, "cfg": core.cfg, "POWER": list(core.POWER)}
try:
    # the reader: pmset's words, the adapter's wattage, ioreg's current (a negative one printed as its unsigned word)
    out44 = {"batt": "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t18%; discharging; (no estimate) present: true\n",
             "g": " lowpowermode         0\n", "adapter": " Wattage = 30W\n Current = 1490mA\n",
             "ioreg": '  |   "InstantAmperage" = 18446744073709550000\n  |   "Amperage" = 18446744073709550616\n'}
    def sh44(cmd, **k):
        o = {("pmset", "-g", "batt"): "batt", ("pmset", "-g"): "g", ("pmset", "-g", "adapter"): "adapter",
             ("ioreg", "-rn", "AppleSmartBattery"): "ioreg"}[tuple(cmd)]
        return subprocess.CompletedProcess(cmd, 0, out44[o], "")
    core.sh = sh44
    if core.power_read() != (True, False, 18, 30, -1000):
        fault(f"power_read of AC, 18%, a 30 W adapter, -1000 mA: {core.power_read()}")
    out44["adapter"] = " No adapter attached.\n"
    try:
        core.power_read(); fault("power_read on AC with a battery and no adapter's wattage: no ClimbError (D9)")
    except core.ClimbError:
        pass
    core.sh = real44["sh"]
    # the rule, each reading (ac, pct, watts, mA, held before) -> held
    for r44, want in (((True, 15, 30, -500, False), True), ((True, 15, 30, 300, False), False), ((True, 15, 60, -500, False), False),
                      ((True, 25, 30, 200, True), True), ((True, 30, 30, 200, True), False), ((True, 25, 96, -900, True), False),
                      ((False, 15, None, None, False), True), ((False, 50, None, None, False), False),
                      ((True, None, None, None, False), False), ((True, 35, 30, -800, False), False)):
        if core.power_held(*r44) != want:
            fault(f"power_held{r44} is {core.power_held(*r44)}, not {want}")
    # end to end: settled at once (power_settle_s 0), the reading stubbed
    core.cfg = lambda: dict(real44["cfg"](), power_settle_s=0)
    with contextlib.suppress(FileNotFoundError):
        os.remove(f"{state}/power.json")
    def ok44(reading):
        core.POWER[0], core.POWER[1], core.POWER[2] = (lambda: reading), 0.0, None
        core.power_ok(); core.POWER[1] = 0.0   # a change settles on its second reading
        return core.power_ok()
    seq44 = [((True, False, 50, 30, -900), True), ((True, False, 19, 30, -900), False), ((True, False, 25, 30, 400), False),
             ((True, False, 30, 30, 400), True), ((True, False, 19, 30, -900), False), ((True, False, 19, 67, -100), True),
             ((False, False, 60, None, None), True), ((False, True, 40, None, None), True)]
    got44 = [ok44(r) for r, _ in seq44]
    if got44 != [w for _, w in seq44]:
        fault(f"power_ok over a weak adapter's discharge, the margin, a full adapter, plain battery: {got44}, not {[w for _, w in seq44]}")
    ev44 = [e for e in core.events() if e["kind"] == "power"]
    if not any(e.get("watts") == 30 and e.get("ma") == -900 and e.get("runs") is False for e in ev44):
        fault(f"the power event of a weak adapter's hold names no watts, current or runs false: {ev44[-3:]}")
    held44 = core.power_line({"ac": True, "above": False, "runs": False}, (True, False, 19, 30, -900))
    runs44 = core.power_line({"ac": True, "above": True, "runs": True}, (True, False, 50, 30, 400))
    if "HELD at the floor" not in held44 or "until 30%" not in held44 or "agent runs in flight finish" not in held44 \
            or "discharging at -900 mA" not in held44 or "work runs" not in runs44 or "charging at 400 mA" not in runs44:
        fault(f"the status line: held {held44!r}; runs {runs44!r}")
except Exception as e:
    fault(f"the power rule raised {type(e).__name__}: {str(e)[:240]}")
finally:
    core.sh, core.cfg = real44["sh"], real44["cfg"]
    core.POWER[:] = real44["POWER"]

# 45. a restart's charge belongs to no file (measure.src_unmeasured, measure.src_stop_wanted, watched's `pauses`,
# measure.settle_costs over measure.src_kept): a src run a landing's check waits on stops in place, never restarted; a
# restarted process's files are all unmeasured; and an unmeasured file carries the cost of the newest kept record that
# MEASURED it, never a blank record's estimate. 2026-11-15: the score of c783ab62, restarted at classes.jl and again
# at closures.jl, charged code_generator.jl 543.2 G (185.3 G in one walk), and a record whose classes.jl was blank
# would have sent it to the densest-rate estimate though two kept records measured it
#: limit 30
real45 = {"cfg": M.cfg, "waits": M.lander_waits, "stops": M.lander_stops, "pause": M.pause_in_place,
          "door": {k: getattr(door, k) for k in ("home", "open_home", "tick", "reap")}}
try:
    # the restarted process's files, and the stop file only for a lander that needs the role or after a failed pause
    if (M.src_unmeasured(0, 0, ["a.jl", "b.jl", M.CANARY]), M.src_unmeasured(1, 0, ["c.jl", "d.jl", M.CANARY]),
            M.src_unmeasured(0, 1, ["e.jl"])) != (set(), {"c.jl", "d.jl"}, {"e.jl"}):
        fault(f"src_unmeasured: {M.src_unmeasured(1, 0, ['c.jl', 'd.jl', M.CANARY])} (every file of a restarted process)")
    M.lander_waits, M.lander_stops = (lambda k: True), (lambda k: True)
    want45 = (M.src_stop_wanted("verify", {"failed": False}), M.src_stop_wanted("verify", {"failed": True}))
    M.lander_stops = lambda k: False
    want45 += (M.src_stop_wanted("verify", {"failed": False}),)
    if want45 != (False, True, True):
        fault(f"src_stop_wanted (a stops lander, the same after a failed pause, a lander needing the role): {want45}, not (False, True, True)")
    # watched with `pauses`: a stand-in process walks five cases; the lander's mark stands in
    M.cfg = lambda: dict(real45["cfg"](), watch_s=0.05)
    home45 = f"{tmp}/home45"; d45 = f"{tmp}/d45"; os.makedirs(d45, exist_ok=True)
    door.home = lambda role: home45
    door.open_home = lambda role, rel: open(f"{home45}/{rel}", "rb") if os.path.exists(f"{home45}/{rel}") else None
    door.tick = lambda *a, **k: None
    reaped45 = []
    door.reap = lambda *a, **k: reaped45.append(1)
    labels45 = [f"a/{i:02d}" for i in range(5)]
    def start45(env, log_):
        script = "".join(f'printf "started\\t{l}\\n" >> "$REC"; sleep 0.15; ' for l in labels45) + 'printf "ended\\n" >> "$REC"'
        return subprocess.Popen(["/bin/sh", "-c", script], env=dict(os.environ, REC=env["WT_SMOKE_COMPILED"]), stdout=log_,
                                stderr=subprocess.STDOUT)
    for how, ret, want in (("paused", (0.2, True), {"failed": False, "reaped": False}),
                           ("refused", (None, True), {"failed": True, "reaped": False}),
                           ("reaped", (None, False), {"failed": True, "reaped": True})):
        calls45, waits45 = [], [True]
        M.lander_waits, M.lander_stops = (lambda k: waits45[0]), (lambda k: True)
        def pause45(role, kind, ret=ret):
            calls45.append(kind); waits45[0] = how != "paused"   # a served lander lets the lock go
            return ret
        M.pause_in_place = pause45
        rel45 = f"m/{how}/compile"; os.makedirs(f"{home45}/{rel45}", exist_ok=True)
        pz45 = {"failed": False, "reaped": False}
        out45 = M.watched(start45, "measure", d45, rel45, "compile", labels45, 60, var="WT_SMOKE_COMPILED", keep_done=True, pauses=pz45)
        if len(calls45) != 1 or pz45 != want or out45[1]:
            fault(f"watched with `pauses`, its pause {how}: pause_in_place called {len(calls45)} time(s) (once), the pause read "
                  f"{pz45} (want {want}), killed {out45[1]} (none)")
    # settle_costs: the newest kept record left t00.jl and t01.jl blank; an older one measured them
    g("checkout", "-q", "--detach", h)
    open(f"{repo}/src/x.jl", "a").write("# 45a\n"); g("add", "-A"); g("commit", "-q", "-m", "c45a"); h45a = g("rev-parse", "HEAD")
    open(f"{repo}/src/x.jl", "a").write("# 45b\n"); g("add", "-A"); g("commit", "-q", "-m", "c45b"); h45b = g("rev-parse", "HEAD")
    old45 = f"{state}/src-{h[:8]}.tsv"
    if not os.path.exists(old45):
        open(old45, "w").write(f"head\t{h}\twarm\t350\n" + "".join(f"{f}\tpassed\t100.0\t0.0\t\n" for f in FILES))
    os.utime(old45, (time.time() - 100, time.time() - 100))
    open(f"{state}/src-{h45a[:8]}.tsv", "w").write(f"head\t{h45a}\twarm\t350\n" + "".join(
        f"{f}\tpassed\t{'' if f in ('t00.jl', 't01.jl') else 100.0}\t0.0\t\n" for f in FILES))
    open(f"{state}/src-latest.json", "w").write(json.dumps({"head": h45a}))
    got45 = M.settle_costs({"t00.jl": ("passed", None, 3.0, ""), "t01.jl": ("passed", 1000.0, 3.0, ""),
                            "t02.jl": ("passed", 120.0, 3.0, "")}, h45b)
    if (got45["t00.jl"][1], got45["t01.jl"][1], got45["t02.jl"][1]) != (100.0, 100.0, 120.0) or h[:10] not in got45["t00.jl"][3]:
        fault(f"settled against the kept records (t00 and t01 blank in the newest): {({f: (r[1], r[3][:40]) for f, r in got45.items()})} "
              f"(t00 carried 100.0 from {h[:10]}, t01's jump refused against that record's 100.0, t02 kept)")
except Exception as e:
    fault(f"a restart's charge raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.cfg, M.lander_waits, M.lander_stops, M.pause_in_place = real45["cfg"], real45["waits"], real45["stops"], real45["pause"]
    for k, v in real45["door"].items():
        setattr(door, k, v)

# 46. a pause holds every role that needs the store's answers, and a landed commit's unfrozen unit is frozen before
# the measurement that needs it (measure.pause_wait in julia_slot, the score tick's pause, measure.store_answers,
# measure.freeze, measure.store_gap). 2026-11-15: PAUSE held the lander, the one step that froze 1ce099d1's unit (its
# freeze cut by the power rule at 07:17Z), while the score (07:41Z) and every measurement that needed the unit ran and
# failed, and the note said to renew the whole store "under the new key". Here: a loop's julia_slot waits while
# paused (Paused past task_wall_s) and a hand command's takes the lock under PAUSE; the score tick starts no score while
# paused; the lander's freeze and a slot measurement's freeze of the same unit, in two processes at once: exactly one
# replays and writes, the other reads it frozen; store_answers freezes the unit and reads again; the note says which
#: limit 60
import climb as C
real46 = {"loop": M.LOOP, "cfg": M.cfg, "ac": M.ac_wait, "ll": M.landing_lock_held,
          "c": {k: getattr(C, k) for k in ("alarms", "scored_heads", "fetch", "unlogged_landings", "scoreboard_once", "power_ok",
                                           "pause", "week_half", "token_refused", "backed_off")},
          "m": {k: getattr(M, k) for k in ("oracle_read", "oracle_unanswered", "freeze")}}
pause46 = f"{state}/PAUSE"
try:
    M.cfg = lambda: dict(real46["cfg"](), task_wall_s=0.5, poll_s=dict(real46["cfg"]()["poll_s"], lock=0.05))
    M.ac_wait, M.landing_lock_held = (lambda *a, **k: None), (lambda: False)
    open(pause46, "w").write("hand\n")
    M.LOOP = "climb-1"
    t46 = time.time()
    try:
        with M.julia_slot("verify"):
            fault("a loop's measurement took the lock while paused")
    except M.Paused:
        if time.time() - t46 > 5:
            fault(f"a loop's measurement waited {time.time() - t46:.1f} s on PAUSE, past task_wall_s (0.5 s)")
    M.LOOP = None   # a hand command (oracle-replay runs only under PAUSE)
    with M.julia_slot("verify"):
        pass
    M.LOOP = "climb-1"
    M.cfg = lambda: dict(real46["cfg"](), task_wall_s=30, poll_s=dict(real46["cfg"]()["poll_s"], lock=0.05))
    __import__("threading").Timer(0.3, lambda: os.remove(pause46)).start()
    t46 = time.time()
    with M.julia_slot("verify"):   # the pause lifted: it goes on
        pass
    if time.time() - t46 < 0.25:
        fault("a loop's measurement did not wait while paused")
    M.LOOP = real46["loop"]
    # the score tick: no score while paused
    ran46 = []
    C.alarms = C.fetch = lambda *a, **k: None
    C.unlogged_landings = lambda: []
    C.scored_heads = lambda *a: []   # nothing scored: a score is due
    C.scoreboard_once = lambda h_: ran46.append(h_)
    C.power_ok, C.week_half, C.token_refused, C.backed_off = (lambda: True), (lambda: True), (lambda: False), (lambda *a, **k: False)
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)
    C.pause = lambda: "hand"; C.score_tick()
    C.pause = lambda: None; C.score_tick()
    if ran46 != [h]:
        fault(f"the score tick started {len(ran46)} score(s) over a paused tick and an unpaused one (one, the unpaused)")
    # the note: a landed commit's unit not frozen is no key change
    key46 = {k: "x" for k in M.KEY_FIELDS}
    gap46 = str(M.store_gap({"u/a": M.NO_FROZEN + ": oracle/index.tsv names no unit for it"}, key46, {"u/a": "c" * 40}))
    other46 = str(M.store_gap({"u/a": M.NO_FROZEN + ": oracle/index.tsv names no unit for it"}, key46, {"u/a": None}))
    if M.REPLAY in gap46 or "cccccccccc" not in gap46 or "not frozen" not in gap46 or M.REPLAY not in other46:
        fault(f"the gap's note: an unfrozen unit's {gap46[-200:]!r}; a snapshot label's {other46[-120:]!r}")
    # store_answers: the unfrozen unit frozen, the store read again
    reads46, frozen46 = [], []
    def read46(labels, key):
        reads46.append(1)
        return ({}, {"u/a": M.NO_FROZEN + ": x"}) if len(reads46) == 1 else ({"u/a": b"rec"}, {})
    M.oracle_read = read46
    M.oracle_unanswered = lambda o: {"u/a": "c" * 40, "s/b": None}
    M.freeze = lambda c, **k: frozen46.append((c, k.get("first")))
    got46 = M.store_answers({"u/a"}, key46)
    if got46 != {"u/a": b"rec"} or frozen46 != [("c" * 40, False)] or len(reads46) != 2:
        fault(f"store_answers over an unfrozen unit: {got46}, froze {frozen46} (once, not first), read {len(reads46)} times (twice)")
    for k, v in real46["m"].items():
        setattr(M, k, v)
    # the lander's freeze and a slot measurement's of the same unit, at once: one replays, the other reads
    actor46 = __import__("textwrap").dedent(f"""
        import os, sys, time, json
        os.environ["WT_CLIMB_STATE"] = {state!r}; os.chdir({repo!r}); sys.path.insert(0, {repo + "/dev/climb"!r})
        import door; door.TOP = {tmp!r}
        assert os.path.realpath(door.TOP) != os.path.realpath({LIVE_TOP!r}), "an actor on the live root"
        import core, measure as M
        who, out = sys.argv[1], sys.argv[2]
        M.ac_wait, M.landing_lock_held = (lambda *a, **k: None), (lambda: False)
        M.added_labels = lambda full: {{"u/a": "1" * 40, "u/b": "2" * 40}}
        M.store_judge = lambda: "j"
        def answer(role, corpus_at, judge_at, labels, task, **k):
            open(out, "a").write(who + " replays\\n"); time.sleep(0.8)
            return {{l: b"rec" for l in labels}}, {{"judge": "j"}}
        M.answer_labels = answer
        def write(unit, blocks, key, blobs, replace=False):
            os.makedirs(os.path.dirname(M.ORACLE_INDEX), exist_ok=True)
            idx = M.oracle_index() if os.path.exists(M.ORACLE_INDEX) else {{}}
            idx.update({{l: (unit, "0" * 64, blobs[l]) for l in blocks}})
            core.write_atomic(M.ORACLE_INDEX, "".join(f"{{l}}\\t{{u}}\\t{{s}}\\t{{b}}\\n" for l, (u, s, b) in sorted(idx.items())))
        M.oracle_write = write
        while not os.path.exists(out + ".go"):
            time.sleep(0.01)
        got = M.freeze("c" * 40, role="measure", first=(who == "lander"))
        open(out, "a").write(who + " got " + ",".join(got) + "\\n")
        """)
    open(f"{tmp}/actor46.py", "w").write(actor46)
    with contextlib.suppress(FileNotFoundError):
        os.remove(M.ORACLE_INDEX)
    out46 = f"{tmp}/run46.txt"; open(out46, "w").close()
    p46 = [subprocess.Popen([sys.executable, "-I", f"{tmp}/actor46.py", w, out46]) for w in ("lander", "slot")]
    time.sleep(0.5); open(out46 + ".go", "w").close()
    for p in p46:
        p.wait(timeout=30)
    lines46 = open(out46).read().splitlines()
    idx46 = M.oracle_index()
    if sum(1 for l in lines46 if l.endswith("replays")) != 1 or sum(1 for l in lines46 if " got u/a,u/b" in l) != 2 \
            or {l: u for l, (u, _, _) in idx46.items()} != {"u/a": "c" * 40, "u/b": "c" * 40}:
        fault(f"two freezes of one unit at once: {lines46}, the index {idx46} (one replay, both read the unit, the index naming it)")
except Exception as e:
    fault(f"the pause and the freeze raised {type(e).__name__}: {str(e)[:240]}")
finally:
    M.LOOP, M.cfg, M.ac_wait, M.landing_lock_held = real46["loop"], real46["cfg"], real46["ac"], real46["ll"]
    for k, v in real46["c"].items():
        setattr(C, k, v)
    for k, v in real46["m"].items():
        setattr(M, k, v)
    with contextlib.suppress(FileNotFoundError):
        os.remove(pause46)
    with contextlib.suppress(Exception):
        g("update-ref", "-d", f"refs/remotes/origin/{core.MARCH}")
