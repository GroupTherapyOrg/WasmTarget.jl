"""dev/l228_sweep.py <root> [--select <base>] [--out <json>]: L228's behaviour harness and its breaks, run as the ratchet's
L228 lock runs them (test/parity_ratchet.jl bounded_behaviour_negatives_missed), with no Julia:

- the tree: test/climb_l228.py on a copy of exactly L228_INPUTS (a file the harness reads and the list lacks fails);
- every break of BOUNDED_BREAKS (or, with --select, the ones dev/climb/l228scope.py selects from the diff since
  <base>), each planted once in a copy of its own and run with --only <its section>: caught only by a fault of that
  section, never by a crash or a limit; each break's anchor asserted to match its file once, run or not;
- the runner's two plants at RUNNER_PLANT_AT (a hang read past its limit, a CPU burn read past 3.5 CPU-seconds).

Read from the ratchet's own text (L228_INPUTS, BOUNDED_BREAKS, RUNNER_PLANT_AT), never a copy of them. Run inside the
check profile (dev/driver_evidence.sh wraps it in one; the climb's sweep after a driver landing runs it as the landing
user inside its own: measure.l228_sweep). It reaches no door, no launch.sh and no sudo. Its exit: 0 when everything
read as it should, 1 otherwise; --out writes {"tree": [...], "missed": [...], "anchors": [...], "runner": [...],
"ran": n, "of": n, "cpu_s": x, "wall_s": x}."""
import concurrent.futures as cf
import json
import os
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import threading
import time

AT_ONCE = 4   # breaks at a time: the ratchet's BREAKS_AT_ONCE

def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__); return 0
    root = os.path.abspath(argv[0])
    base = argv[argv.index("--select") + 1] if "--select" in argv else None
    out_path = argv[argv.index("--out") + 1] if "--out" in argv else None
    sys.path.insert(0, os.path.join(root, "dev", "climb"))
    import l228scope as S
    cpu = lambda: (lambda r: r.ru_utime + r.ru_stime)(resource.getrusage(resource.RUSAGE_CHILDREN))
    c0, t0 = cpu(), time.time()
    text = open(os.path.join(root, "test", "parity_ratchet.jl")).read()
    m = re.search(r"^const L228_INPUTS = \(([^)]*)\)", text, re.M)
    inputs = re.findall(r'"([^"]+)"', m.group(1))
    brks = S.bounded_breaks(text)
    sel = [i for i, _ in S.breaks(root, base)] if base else list(range(1, len(brks) + 1))

    def copy():
        d = tempfile.mkdtemp(prefix="l228-sweep-")
        for p in inputs:
            rel = p.rstrip("/")
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            (shutil.copytree if os.path.isdir(os.path.join(root, rel)) else shutil.copy)(os.path.join(root, rel), os.path.join(d, rel))
        return d

    def harness(d, *extra, env=None):
        return subprocess.run([sys.executable, "-I", os.path.join(d, "test", "climb_l228.py"), d, *extra], capture_output=True,
                              text=True, env=env, stdin=subprocess.DEVNULL)

    res = {"tree": [], "missed": [], "anchors": [], "runner": [], "ran": len(sel), "of": len(brks)}
    for w, path, a, _, _ in brks:   # every anchor once, run or not (the ratchet's l228_anchor_faults)
        f = os.path.join(root, path)
        n = open(f).read().count(a) if os.path.isfile(f) else 0
        if n != 1:
            res["anchors"].append(f'L228\'s break "{w}": its anchor matches {path} {n} times, not once')
    d = copy()
    r = harness(d)
    shutil.rmtree(d, ignore_errors=True)
    res["tree"] = [l for l in r.stdout.splitlines() if l.strip()]
    lock = threading.Lock()

    def one(i):
        w, path, a, b, sec = brks[i - 1]
        d = copy()
        f = os.path.join(d, path)
        t = open(f).read()
        if t.count(a) != 1:
            shutil.rmtree(d, ignore_errors=True)
            return   # its anchor fault is above
        open(f, "w").write(t.replace(a, b))
        r = harness(d, "--only", str(sec))
        shutil.rmtree(d, ignore_errors=True)
        o = r.stdout.strip()
        with lock:
            if not o:
                res["missed"].append(f"L228's behaviour negative missed: {w} (section {sec})")
            elif "passed its limit" in o or " exited " in o:
                res["missed"].append(f"L228's break {w} caught only by a crash or a limit: {o[:200]}")

    with cf.ThreadPoolExecutor(max_workers=AT_ONCE) as ex:
        list(ex.map(one, sel))
    m = re.search(r'^const RUNNER_PLANT_AT = "((?:[^"\\]|\\.)*)"', text, re.M)
    if not m:
        res["runner"].append("the ratchet names no RUNNER_PLANT_AT")
    else:
        at = S.jl(m.group(1))
        for name, plant in (("hang", at + '    __import__("time").sleep(600)\n'),
                            ("burn", at + '    _t = __import__("time").process_time()\n    while __import__("time").process_time() - _t < 4:\n        pass\n')):
            d = copy()
            f = os.path.join(d, "dev", "climb", "measure.py")
            t = open(f).read()
            if t.count(at) != 1:
                res["runner"].append(f"the runner's {name} cannot plant: RUNNER_PLANT_AT matches {t.count(at)} times")
                shutil.rmtree(d, ignore_errors=True); continue
            open(f, "w").write(t.replace(at, plant))
            c1, t1 = cpu(), time.time()
            r = harness(d, "--only", "1", env=dict(os.environ, WT_L228_LIMIT_S="3") if name == "hang" else None)
            dt, burnt = time.time() - t1, cpu() - c1
            shutil.rmtree(d, ignore_errors=True)
            if name == "hang" and not ("section 1 passed its limit of 3 s" in r.stdout and dt < 30):
                res["runner"].append(f"the runner's hang read {r.stdout.strip()[:160]!r} after {dt:.1f} s")
            if name == "burn" and burnt < 3.5:
                res["runner"].append(f"the runner's burn read {burnt:.1f} CPU-s")
    res["cpu_s"], res["wall_s"] = round(cpu() - c0, 1), round(time.time() - t0, 1)
    bad = res["tree"] + res["missed"] + res["anchors"] + res["runner"]
    print(f"l228_sweep: the tree {'clean' if not res['tree'] else 'reads ' + '; '.join(res['tree'])[:300]}; "
          f"{len(sel)} of {len(brks)} breaks, {len(res['missed'])} missed; {len(res['anchors'])} anchor fault(s); the runner's "
          f"plants {'caught' if not res['runner'] else '; '.join(res['runner'])}; {res['cpu_s']} CPU-s, {res['wall_s']} s")
    for x in bad:
        print("  " + x)
    if out_path:
        with open(out_path, "w") as f:
            json.dump(res, f)
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
