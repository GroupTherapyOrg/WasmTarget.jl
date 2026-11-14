"""Whether a check of a commit runs the L228 behaviour harness: the class its check is judged in (dev/check.sh:
D14_RED_HARNESS, not D14_RED) and predicted in (measure.predict's ratchet term). The rule is the ratchet's
(test/parity_ratchet.jl l228_scope, which decides it inside the check and writes it there for check.sh): a file the
change touches since its merge base is one of L228_INPUTS (read from the commit's own ratchet, the one list) or the
ratchet itself, or its range closes a clause (`Closes: C<n>`). WT_RATCHET_FULL, the scope's third trigger, is never set
in a landing. Standard library alone, so L228's scope negative runs it on its own scratch histories beside l228_scope
and refuses any disagreement (test/parity_ratchet.jl l228_scope_negatives_missed).

    python3 -I dev/climb/l228scope.py <repo> <base> <head>   prints harness or none"""
import re
import subprocess
import sys

def harness(repo, base, head):
    git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout
    text = git("show", f"{head}:test/parity_ratchet.jl")
    m = re.search(r"^const L228_INPUTS = \(([^)]*)\)", text, re.M)
    if not m:
        raise ValueError(f"{head[:10]}:test/parity_ratchet.jl names no L228_INPUTS: the check's class cannot be read")
    inputs = re.findall(r'"([^"]+)"', m.group(1))
    mb = git("merge-base", base, head).strip()
    changed = [f for f in git("diff", "--name-only", mb, head).splitlines() if f]
    closes = re.search(r"(?m)^Closes: C\d", git("log", "--format=%B", f"{mb}..{head}")) is not None
    return closes or any(f == "test/parity_ratchet.jl" or any(f.startswith(p) for p in inputs) for f in changed)

if __name__ == "__main__":
    print("harness" if harness(*sys.argv[1:4]) else "none")
