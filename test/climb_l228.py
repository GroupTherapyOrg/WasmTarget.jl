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
                                           "shards": [[80, 650, 0, 0]] * 5, "starts": [375.0] * 5}}) + "\n")
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

for f in faults:
    print(f)
