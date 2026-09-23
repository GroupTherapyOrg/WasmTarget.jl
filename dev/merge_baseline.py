#!/usr/bin/env python3
"""Resolve a conflicted dev/parity_baseline.toml during a merge, rebase or cherry-pick: the
union of keys per section, the MINIMUM value per key (ratchets only decrease, so both sides'
tightenings hold; locks are exact zeros).

The minimum is only meaningful between two counts of the same counter. When the two sides
disagree on a key's value and test/parity_ratchet.jl defines that key differently on the two
sides (its entry, or a helper function the entry calls), the counts are not comparable: the
script refuses, names the keys, and changes nothing. Such a key is restated by measuring it on
the merged tree (WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl after taking the
larger value by hand).

Usage (from the repository root, with the conflict in progress):
    python3 dev/merge_baseline.py dev/parity_baseline.toml"""
import os, re, subprocess, sys

RATCHET = "test/parity_ratchet.jl"


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def other_side():
    gitdir = git("rev-parse", "--git-dir").stdout.strip()
    for head in ("MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"):
        if os.path.exists(os.path.join(gitdir, head)):
            return head
    sys.exit("merge_baseline: no merge, rebase or cherry-pick in progress — refusing")


def definitions(rev):
    """key -> the text that defines its count: the key's entry plus every helper it calls."""
    src = git("show", f"{rev}:{RATCHET}").stdout
    helpers = {}
    for m in re.finditer(r"^function (\w+)\(.*?^end\b", src, re.M | re.S):
        helpers[m.group(1)] = m.group(0)
    for m in re.finditer(r"^(\w+)\(([^)]*)\)\s*=.*$", src, re.M):
        helpers.setdefault(m.group(1), m.group(0))
    starts = list(re.finditer(r'^\s*"([LR]\w+)" => \(', src, re.M))
    defs = {}
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(src)
        entry = src[m.start():end]
        called = sorted(set(re.findall(r"\b(\w+)\(", entry)) & set(helpers))
        defs[m.group(1)] = entry + "".join(helpers[h] for h in called)
    return defs


path = sys.argv[1]
text = open(path).read()
vals, sides = {}, {"ours": {}, "theirs": {}}
section, state = None, None
for line in text.splitlines():
    if line.startswith("<<<<<<<"):
        state = "ours"; continue
    if line.startswith("=======") and state == "ours":
        state = "theirs"; continue
    if line.startswith(">>>>>>>"):
        state = None; continue
    s = line.strip()
    m = re.match(r"^\[(\w+)\]$", s)
    if m:
        section = m.group(1); vals.setdefault(section, {}); continue
    m = re.match(r"^(\w+)\s*=\s*(\d+)", s)
    if m and section:
        k, v = m.group(1), int(m.group(2))
        if state:
            sides[state][k] = v
        vals[section][k] = min(v, vals[section].get(k, v))

disputed = sorted(k for k in sides["ours"].keys() & sides["theirs"].keys()
                  if sides["ours"][k] != sides["theirs"][k])
if disputed:
    theirs = other_side()
    ours_defs, theirs_defs = definitions("HEAD"), definitions(theirs)
    restate = [k for k in disputed if ours_defs.get(k) != theirs_defs.get(k)]
    if restate:
        sys.exit("merge_baseline: counter definition differs between HEAD and " + theirs +
                 " for " + ", ".join(f"{k} ({sides['ours'][k]} vs {sides['theirs'][k]})" for k in restate) +
                 " — the minimum would compare two different counters; restate each by measuring it on the merged tree")

head = [l for l in text.splitlines() if l.startswith("#")][:3]
with open(path, "w") as io:
    io.write("\n".join(head) + "\n")
    for sec in ("locks", "metrics"):
        io.write(f"\n[{sec}]\n")
        for k in sorted(vals.get(sec, {})):
            io.write(f"{k} = {vals[sec][k]}\n")
print("resolved", path, {s: len(v) for s, v in vals.items()})
