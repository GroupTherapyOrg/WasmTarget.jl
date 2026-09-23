#!/usr/bin/env python3
"""Resolve a conflicted dev/parity_baseline.toml: union of keys per section, the MINIMUM value
per key (ratchets only decrease, so both sides' tightenings hold; locks are exact zeros).
Usage: python3 dev/merge_baseline.py dev/parity_baseline.toml"""
import re, sys
path = sys.argv[1]
text = open(path).read()
sides = {"ours": [], "theirs": []}
out_common = []
state = None
for line in text.splitlines():
    if line.startswith("<<<<<<<"): state = "ours"; continue
    if line.startswith("=======") and state == "ours": state = "theirs"; continue
    if line.startswith(">>>>>>>"): state = None; continue
    (sides[state] if state else out_common).append(line)
vals, section, order = {}, None, []
header = []
for line in out_common + sides["ours"] + sides["theirs"]:
    pass
def feed(lines):
    global section
    for line in lines:
        s = line.strip()
        m = re.match(r"^\[(\w+)\]$", s)
        if m:
            section = m.group(1); vals.setdefault(section, {}); continue
        m = re.match(r"^(\w+)\s*=\s*(\d+)", s)
        if m and section:
            k, v = m.group(1), int(m.group(2))
            vals[section][k] = min(v, vals[section].get(k, v))
# walk the file in order so a key inside a conflict block inherits the section it sits in
section = None
state = None
for line in text.splitlines():
    if line.startswith(("<<<<<<<", "=======", ">>>>>>>")): continue
    feed([line])
head = [l for l in text.splitlines() if l.startswith("#") and not l.startswith(("<<<", ">>>"))][:3]
with open(path, "w") as io:
    io.write("\n".join(head) + "\n")
    for sec in ("locks", "metrics"):
        io.write(f"\n[{sec}]\n")
        for k in sorted(vals.get(sec, {})):
            io.write(f"{k} = {vals[sec][k]}\n")
print("resolved", path, {s: len(v) for s, v in vals.items()})
