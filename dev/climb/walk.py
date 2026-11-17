"""dev/climb/walk.py <state copy> <commit> [<item ref> ...]: the lander's next round replayed with the driver of THIS tree
(the clone it is run from) on a copy of the climb's state, `commit` taken as origin's head: for each item, the queue's
(each ready item's sha in the copy's ready.json) and the ones named, cherry-picked onto `commit` in this clone, and two
of its own made here (a src move editing the lightest scored test file; a change to the harness's inputs):
checks_measured() -> predict (both classes) -> src_set -> what the lander would do before the check (src_refused:
lands, held for a split, held as the predictor's, dropped as its own). It prints one line an item and exits 1 when any
item would be refused, held or dropped. dev/driver_evidence.sh runs it inside the check profile.

It never touches the live climb: it refuses a state copy that is the live state (core.STATE's default) or a door root
that is the live TOP, runs the driver with door.TOP a scratch root (as test/climb_l228.py's prologue does), and writes
only its state copy, its scratch and this clone's refs."""
import os
import subprocess
import shutil
import sys
import tempfile

def main(argv):
    if len(argv) < 2 or argv[0] in ("-h", "--help"):
        print(__doc__); return 2
    state, commit, extra = os.path.abspath(argv[0]), argv[1], argv[2:]
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    live_state = os.path.join(os.path.dirname(repo), ".wt-climb")
    common = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True,
                            text=True).stdout.strip()
    # the live state by identity (the repository's own state directory, or any directory named as the climb names its
    # state), never by a path's prefix
    if os.path.exists(live_state) and os.path.samefile(state, live_state) or ".wt-climb" in os.path.realpath(state).split(os.sep) or \
            not os.path.isfile(os.path.join(state, "events.jsonl")):
        print(f"walk: refused: {state} is the live state or holds no events.jsonl; give a copy of its files"); return 2
    if os.path.realpath(common) != os.path.realpath(os.path.join(repo, ".git")):
        print(f"walk: refused: {repo} is a worktree (its common dir {common}); run from a clone"); return 2
    g = lambda *a: subprocess.run(["git", "-C", repo, "-c", "user.name=walk", "-c", "user.email=walk@localhost", *a],
                                  capture_output=True, text=True, check=True).stdout.strip()
    h = g("rev-parse", f"{commit}^{{commit}}")
    os.environ["WT_CLIMB_STATE"] = state
    sys.path.insert(0, here)
    import door
    # the live door's root is door.TOP's own value, read before it is redirected (WT_L228_LIVE_TOP stands in for it in
    # dev/driver_evidence.sh's landing-shaped layout alone, a scratch root the live climb never names); the scratch root
    # is a new directory of this run's, so it is never the live one, and the test is by identity: a TMPDIR under the
    # live root (a landing's: /Users/Shared/wt-climb/u/_wtland/tmp) holds scratch roots that are not the live one
    # (2026-11-15 03:11:53Z: a prefix test refused every walk of a landing's harness and dropped 67b171a2)
    live = os.environ.get("WT_L228_LIVE_TOP") or door.TOP
    door.TOP = tempfile.mkdtemp(prefix="walk-top-")
    try:
        if os.path.exists(live) and os.path.samefile(door.TOP, live):
            print("walk: refused: the door's root is the live TOP"); return 2
        return replay(state, commit, extra, here, repo, g, h)
    finally:
        shutil.rmtree(door.TOP, ignore_errors=True)   # its scratch root, whatever the replay did

def replay(state, commit, extra, here, repo, g, h):
    import door
    import core
    import measure as M
    import lander as L
    g("update-ref", f"refs/remotes/origin/{core.MARCH}", h)
    rec = M.src_latest(h)
    if rec is None:
        print(f"walk: no score's src record at {h[:10]} or before it in the state copy: nothing can be replayed"); return 1
    hs, warm, rows = rec
    ch = M.checks_measured()
    print(f"walk: origin {h[:10]}, the score of {hs[:10]}; checks_measured(): " +
          ", ".join(f"{e['t'][11:19]} {e.get('result', '')[:12]} {e['path']} s (ratchet {e['split'].get('ratchet', [None])[0]}, "
                    f"{e['split'].get('l228') or 'no class'})" for e in ch))
    for k in (False, True):
        p, _ = M.predict({}, warm, False, 5, ch, harness=k)
        print(f"walk: no test file, {'the harness class' if k else 'no harness'}: {p['path']} s (ratchet {p['ratchet']}; {p['model']})")
    def apply_onto(at, ref):   # a ref cherry-picked onto `at`, or `patch:<file>` (a commit's format-patch) applied
        g("checkout", "-q", "-f", "--detach", at)
        try:
            if ref.startswith("patch:"):
                g("am", "-q", "--3way", ref[len("patch:"):])
            else:
                g("cherry-pick", "--allow-empty", "--keep-redundant-commits", ref)
            return g("rev-parse", "HEAD"), None
        except subprocess.CalledProcessError as e:
            for op, mark in (("cherry-pick", "CHERRY_PICK_HEAD"), ("am", "rebase-apply")):
                if os.path.exists(os.path.join(repo, ".git", mark)):
                    subprocess.run(["git", "-C", repo, op, "--abort"], capture_output=True)
            return None, (e.stderr or "").strip()[:120]
    def pick(name, ref):   # onto h; an item that applies onto neither h nor h's parent (origin) is its own, not h's
        sha, err = apply_onto(h, ref)
        if sha is not None:
            return sha, None
        if apply_onto(f"{h}~1", ref)[0] is None:
            return None, f"{name}: applies onto neither {h[:10]} nor its parent, origin: the item's own conflict, not this commit's ({err})"
        return None, f"{name}: does not apply onto {h[:10]}, and does onto its parent: THIS commit's conflict ({err})"
    def make(name, edits):   # each edit of a file the tree has, added by name, committed onto h
        g("checkout", "-q", "-f", "--detach", h)
        for rel, fn in edits.items():
            p = os.path.join(repo, rel)
            if os.path.isfile(p):
                open(p, "w").write(fn(open(p).read()))
                g("add", "-f", rel)
        g("commit", "-q", "--allow-empty", "-m", f"walk: {name}")
        return g("rev-parse", "HEAD")
    items = [(f"queued {x.get('hold_id')}", x["sha"]) for x in core.state_json("ready.json", [])] + \
        [(f"named {os.path.basename(r) if r.startswith('patch:') else r}", r) for r in extra]
    light = min((f for f, r in rows.items() if r[0] == "passed" and r[1] is not None), key=lambda f: rows[f][1], default=None)
    made = []
    if light:
        made.append(("a src move editing test/src/" + light, make("a src move", {f"test/src/{light}": lambda t: t + "# walk\n",
                                                                                  "src/WasmTarget.jl": lambda t: t + "# walk\n"})))
    made.append(("a change to the harness's inputs (dev/climb/HILL.md)", make("a harness change", {"dev/climb/HILL.md": lambda t: t + "<!-- walk -->\n"})))
    red = 0
    for name, ref in items + made:
        sha, why = (ref, None) if (name, ref) in made else pick(name, ref)
        if sha is None:
            print(f"walk: {why}"); red += "THIS commit's" in why; continue
        ss = M.src_set(h, sha, None)
        if ss.get("why"):
            print(f"walk: {name}: no set ({ss['why'][:160]})"); red += 1; continue
        ou, b0, pr = ss["own_unscored"], ss["base"], ss["predicted"]
        if not ss.get("refuse"):
            out = "lands (its check is run)"
        elif ss.get("base_over"):
            out = "HELD as the predictor's (no test file passes the line)"
        elif ss.get("origin_heavy"):
            out = f"HELD for a split ({[f for f, _, _ in ss['origin_heavy']]})"
        else:
            out = "DROPPED as its own"
        red += not out.startswith("lands")
        handed = M.src_handed(ss, h, sha) if out.startswith("lands") else None
        # the set the check is handed (an empty one: no shard runs, dev/check.sh); the synthetic harness item is the
        # empty-set case only while nothing is unscored (2026-11-15 02:20:43Z: a model commit's empty set read void)
        hand = "" if handed is None else f"; handed {len(handed)} file(s)" + (" (an empty set: the check runs no shard)" if not handed else "")
        if (name, ref) in made and ss["harness"] and handed:
            hand += f" (NOT the empty-set case: {len(ss['unscored'])} unscored, {len(ss['own'])} own)"
        print(f"walk: {name} ({sha[:10]}): class {'harness' if ss['harness'] else 'none'}, line {ss['band']} s; known costs "
              f"{ou['path']} s (ratchet {ou['ratchet']}, load {ou['load']}), no file {b0['path']} s, with estimates {pr['path']} s; "
              f"share {len(ss.get('share') or [])}; own {ss['own']}; unscored {len(ss['unscored'])}{hand}; -> {out}")
    g("checkout", "-q", "-f", "--detach", h)
    print(f"walk: {len(items) + len(made)} item(s), {red} refused, held, dropped or not replayable")
    return 1 if red else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
