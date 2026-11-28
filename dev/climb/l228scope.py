"""What a landing's check runs of the L228 behaviour harness, read from git and the trees alone (the standard library,
so test/parity_ratchet.jl's L228 lock and the climb's lander read one implementation):

- `harness(repo, base, head)`: whether a check of `head` runs the harness at all, the class its check is judged in
  (dev/check.sh: D14_RED_HARNESS, not D14_RED) and predicted in (measure.predict's ratchet term). The ratchet's rule
  (l228_scope, which decides it inside the check and writes it there for check.sh): a file the change touches since
  its merge base is one of L228_INPUTS (read from the commit's own ratchet, the one list) or the ratchet itself, or
  its range closes a clause (`Closes: C<n>`). WT_RATCHET_FULL, the scope's third trigger, is never set in a landing.
- `breaks(root, base)`: which of BOUNDED_BREAKS a check of the tree at `root` runs, its index (1-based, the ratchet's
  order) with why: a break whose entry is new or changed; whose section's text in test/climb_l228.py (or a section it
  needs, or the prologue every section runs) changed; or whose anchor lies in a definition the change touches (the
  top-level statement of a .py file that holds it, by Python's own parser, whose source leaves a trailing comment out,
  so a comment alone selects nothing; any other file, the whole file). Every other
  break's anchor is still asserted to match once (the ratchet, at no run's cost), and every break runs at the full
  sweep after a driver landing (climb.py src-gap: measure.l228_sweep), a miss there a fix-first.

    python3 -I dev/climb/l228scope.py <repo> <base> <head>   prints harness or none
    python3 -I dev/climb/l228scope.py breaks <root> <base>   prints `<index> <why>` per break the tree runs"""
import ast
import re
import subprocess
import sys

def _git(repo, *a, check=True):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=check).stdout

def harness(repo, base, head):
    text = _git(repo, "show", f"{head}:test/parity_ratchet.jl")
    m = re.search(r"^const L228_INPUTS = \(([^)]*)\)", text, re.M)
    if not m:
        raise ValueError(f"{head[:10]}:test/parity_ratchet.jl names no L228_INPUTS: the check's class cannot be read")
    inputs = re.findall(r'"([^"]+)"', m.group(1))
    mb = _git(repo, "merge-base", base, head).strip()
    changed = [f for f in _git(repo, "diff", "--name-only", mb, head).splitlines() if f]
    closes = re.search(r"(?m)^Closes: C\d", _git(repo, "log", "--format=%B", f"{mb}..{head}")) is not None
    return closes or any(f == "test/parity_ratchet.jl" or any(f.startswith(p) for p in inputs) for f in changed)

# ---- which breaks a check runs
_JL = re.compile(r'\\(.)')
def jl(x):
    """A Julia string literal's text."""
    return _JL.sub(lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "$": "$"}.get(m.group(1), "\\" + m.group(1)), x)

BREAK_RE = re.compile(r'\(\s*"((?:[^"\\]|\\.)*)",\s*"([^"]+)",\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*(\d+)\)', re.S)

def bounded_breaks(ratchet_text):
    """BOUNDED_BREAKS of a ratchet's text, in order: [(what, path, anchor, plant, section)], their texts unescaped."""
    if "const BOUNDED_BREAKS = (" not in ratchet_text:
        return []
    s = ratchet_text[ratchet_text.index("const BOUNDED_BREAKS = ("):ratchet_text.index("function bounded_behaviour_negatives_missed")]
    return [(jl(w), p, jl(a), jl(b), int(n)) for w, p, a, b, n in BREAK_RE.findall(s)]

def sections(harness_text):
    """(the prologue, {n: (text, needs)}) of test/climb_l228.py's text, as its runner splits it."""
    marks = list(re.finditer(r"^# (\d+)\. ", harness_text, re.M))
    if not marks:
        return harness_text, {}
    out = {}
    for i, m in enumerate(marks):
        t = harness_text[m.start():marks[i + 1].start() if i + 1 < len(marks) else len(harness_text)]
        needs = [int(x) for x in re.findall(r"\d+", (re.search(r"^#: needs ([\d, ]+)", t, re.M) or [None, ""])[1])]
        out[int(m.group(1))] = (t, needs)
    return harness_text[:marks[0].start()], out

def _segments(text, anchor):
    """The source of each top-level statement of a Python text that the anchor's span overlaps, or None when the
    anchor is not there once or the text does not parse."""
    if text.count(anchor) != 1:
        return None
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    a0 = text[:text.index(anchor)].count("\n") + 1
    a1 = a0 + anchor.count("\n")
    return [ast.get_source_segment(text, n) or "" for n in tree.body if n.lineno <= a1 and (n.end_lineno or n.lineno) >= a0]

def breaks(root, base):
    """[(index, why)] of the breaks a check of the tree at `root` runs, measured from its merge base with `base`; the
    head side is the tree's working files (a check's tree is its commit)."""
    mb = _git(root, "merge-base", base, "HEAD").strip()
    at_base = lambda f: _git(root, "show", f"{mb}:{f}", check=False)
    def now(f):
        try:
            return open(f"{root}/{f}").read()
        except OSError:
            return ""
    rb, rh = bounded_breaks(at_base("test/parity_ratchet.jl")), bounded_breaks(now("test/parity_ratchet.jl"))
    pb, sb = sections(at_base("test/climb_l228.py"))
    ph, sh_ = sections(now("test/climb_l228.py"))
    if pb != ph:
        return [(i, "the harness's prologue changed") for i in range(1, len(rh) + 1)]
    changed_sec = {n for n in set(sb) | set(sh_) if sb.get(n, ("",))[0] != sh_.get(n, ("",))[0]}
    old = set(rb)
    texts = {}
    out = []
    for i, (w, path, a, b, sec) in enumerate(rh, 1):
        if (w, path, a, b, sec) not in old:
            out.append((i, "its entry is new or changed")); continue
        secs = {sec, *sh_.get(sec, ("", []))[1]}
        if secs & changed_sec:
            out.append((i, f"section {min(secs & changed_sec)}'s text changed")); continue
        if path not in texts:
            texts[path] = (at_base(path), now(path))
        tb, th = texts[path]
        if tb == th:
            continue
        if path.endswith(".py"):
            seg = _segments(th, a)
            if seg is None or any(s not in tb for s in seg):
                out.append((i, f"the definition holding its anchor in {path} changed")); continue
        else:
            out.append((i, f"{path} changed"))
    return out

if __name__ == "__main__":
    if sys.argv[1:2] == ["breaks"]:
        for i, why in breaks(sys.argv[2], sys.argv[3]):
            print(i, why)
    else:
        print("harness" if harness(*sys.argv[1:4]) else "none")
