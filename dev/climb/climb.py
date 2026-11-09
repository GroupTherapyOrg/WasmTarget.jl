#!/usr/bin/env python3
"""dev/climb/climb.py — the climb's driver and its score (dev/climb/HILL.md).

The march as a hill climb (Dale 2026-11-04, D47). A program scores the compiler, and fresh agents make one
move each. The driver is a program, so no resident LLM lead and no LLM monitor spends tokens while it waits.

State lives outside the repository, in <dir of the repo>/.wt-climb: an agent's sandbox can write its worktree
and the git dir, never the judge's state. Agents run in Claude Code's sandbox with no push identity.

    python3 dev/climb/climb.py report              the scoreboard: src progress, S, the gates, the holds, the budget
    python3 dev/climb/climb.py holds [-n K]        the holds, largest first (--json for the driver's form)
    python3 dev/climb/climb.py record <tsv> <sha>  a full smoke run's cases become the head's score (G2's pass set grows)
    python3 dev/climb/climb.py regress <tsv>       exit 1 if <tsv> loses a passing case or has a wrong/errored one (G1, G2)
    python3 dev/climb/climb.py budget              the account's spend today and this week against the allowance
    python3 dev/climb/climb.py map [<out.html>]    the project map, drawn by this program (D29), no agent
    python3 dev/climb/climb.py preflight [--kill]  what launch needs: stale loops, paused lanes' work, origin, the budget
    python3 dev/climb/climb.py harvest             the paused lanes' unfinished work, queued as fix-first holds (once each)
    python3 dev/climb/climb.py score-tick          one look at origin/wt2: the rogue-push alarm, and a score when due
    python3 dev/climb/climb.py slot <climb-N>      one move (or an audit, on climb-1) in that slot, then exit
    python3 dev/climb/climb.py lander              one landing of the oldest approved commit that waits
    python3 dev/climb/climb.py once                one move in climb-1, then exit (a rehearsal)
    python3 dev/climb/climb.py audit               one audit of the landings since the last entry, now
    python3 dev/climb/climb.py judge-eval [-n N]   the reviewer's recall on N real past defects (reverted audit fixes)

Launch is dev/climb/launch.sh, which runs these in order.
Config: <state>/config.json overrides DEFAULTS key by key (the lead tunes it without a commit).
"""
import argparse, collections, contextlib, datetime, fcntl, glob, hashlib, html, json, os, re, shutil, signal, \
    subprocess, sys, threading, time, uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MARCH = "wt2"

class ClimbError(Exception):
    """A failed step of the driver: an event, never a dead thread (SystemExit is not an Exception)."""

def sh(cmd, cwd=None, timeout=None, env=None, check=False):
    r = subprocess.run(cmd, cwd=cwd or ROOT, capture_output=True, text=True, timeout=timeout,
                       env=env, shell=isinstance(cmd, str))
    if check and r.returncode != 0:
        raise ClimbError(f"{cmd if isinstance(cmd, str) else ' '.join(cmd)}: {(r.stderr or r.stdout).strip()[:400]}")
    return r

def git(*args, cwd=None, check=True):
    return sh(["git", *args], cwd=cwd, check=check).stdout.strip()

def fetch():
    """origin/wt2, retried: two slots, the scoreboard and ship.sh fetch side by side (ref-lock races)."""
    for i in range(5):
        if sh(["git", "fetch", "-q", "origin", MARCH]).returncode == 0:
            return
        time.sleep(3 + 4 * i)
    raise ClimbError("git fetch origin wt2 failed five times")

COMMON = git("rev-parse", "--path-format=absolute", "--git-common-dir")
REPO = os.path.dirname(COMMON) if os.path.basename(COMMON) == ".git" else COMMON
STATE = os.environ.get("WT_CLIMB_STATE") or os.path.join(os.path.dirname(REPO), ".wt-climb")   # the override: a dry run
WORKTREES = os.path.join(os.path.dirname(REPO), ".worktrees")
for d in ("runs", "claims", "briefs", "logs"):
    os.makedirs(os.path.join(STATE, d), exist_ok=True)

DEFAULTS = {
    "slots": 2,                                  # climbers at once (4 performance cores, one check at a time: D31)
    "climber_model": "claude-opus-5-5",          # D48: every agent runs on Opus (Dale 2026-11-04: Claude only)
    "climber_effort": "high",
    "reviewer_effort": "high",
    "ruler_model": "claude-opus-5-5",            # D48: Opus rules first; Fable is the escalation, called rarely
    "fable_model": "claude-fable-5-1",
    "fable_per_day": 2,                          # D48 (Dale 2026-11-04): "make fable use in the council minimal"
    "week_weighted": 8.38e8,                     # measured: 2026-11-01 10:00Z to 11-02 15:25Z, each message once, hit the limit
    "margin": 0.85,
    # Dale 2026-11-08: "warn me when we hit 50% usage [for the week] and when we do, please pause"
    "week_pause": 0.5,
    # the march account's transcripts: run the climb under that account's own CLAUDE_CONFIG_DIR, so the governor counts
    # its sessions alone (another account's sessions in the same directory would be counted against it)
    "claude_home": os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
    "task_cap_usd": 25.0,                        # --max-budget-usd of a fresh run (calibrate on day 1: `budget`)
    "resume_cap_usd": 8.0,                       # a resume re-creates its cache cold, so it gets its own small cap
    "resumes_per_move": 3,                       # tstack sol-loop's default: three review rounds a change
    "stops_per_hold": 3,                         # then the hold is parked for Dale, never retried for ever
    "task_wall_s": 5400,                         # no run outlives this (2026-10-28: hangs are never allowed)
    "audit_every": 5,                            # D21: every change read within 5 commits
    "score_every_landings": 3,                   # the scoreboard scores a head after this many landings, or …
    "score_every_s": 7200,                       # … this long since the last score, whichever first
    "smoke_wall_s": 10800,
    "kaimon_url": "http://localhost:2828/mcp",   # D39: every climber develops in a live Kaimon session (MCP)
}
BUDGET_KEYS = ("week_weighted", "margin", "week_pause")   # D14: a budget changes by a commit naming Dale's words, never by config

def cfg():
    c = dict(DEFAULTS)
    p = os.path.join(STATE, "config.json")
    if os.path.exists(p):
        c.update({k: v for k, v in json.load(open(p)).items() if k not in BUDGET_KEYS})
    return c

# G5: the judge and the rules. A move touching one is refused before review; ADD_ONLY files may only gain lines,
# and NEW_ONLY directories only gain files (a model's invariant is never loosened in a port move: refusal 9).
PROTECTED = [r"^dev/(?!formal/)", r"^dev/formal/run_tlc\.sh$",
             r"^test/(?!smoke_corpus\.jl$|smoke_times\.tsv$)[^/]+$",   # every driver and shared helper the check and smoke load (A97E2)
             r"^AGENTS\.md$", r"^\.github/", r"^\.gitignore$", r"^Project\.toml$",
             r"^Manifest\.toml$", r"^legacy/"]   # all of dev/: the tooling, the plan and the audit log are the driver's or a ruling's
ADD_ONLY = [r"^test/smoke_corpus\.jl$", r"^test/smoke_times\.tsv$"]
# the runner's own gaps (a type it does not marshal, a reader it cannot build) are the judge failing to read an answer,
# not the compiler: a keeper move ports them in the runner and its test alone, and may flip no other case (HILL.md)
RUNNER_FILES = ("test/runner.jl", "test/src/runner.jl")
# (a reader WasmTarget rejects is the compiler's gap until a ruling says otherwise: the reader is compiled by WT)
# ("does not read" is left out: the runner says it only of a reader WasmTarget rejects, a compiler gap, A98E5)
RUNNER_GAP_RE = re.compile(r"the runner (marshals no|reads a tuple's leaves)")
NEW_ONLY = [r"^dev/formal/"]

def now():
    return datetime.datetime.now(datetime.timezone.utc)

def stamp(t=None):
    return (t or now()).isoformat(timespec="seconds")

# ---------------------------------------------------------------- state, locked across threads and processes
_TLOCK = threading.RLock()
_DEPTH = threading.local()

@contextlib.contextmanager
def locked():
    """One lock over the state for every thread and every process of the climb (flock beside an RLock)."""
    with _TLOCK:
        d = getattr(_DEPTH, "n", 0)
        if d == 0:
            _DEPTH.fd = os.open(os.path.join(STATE, ".lock"), os.O_CREAT | os.O_RDWR)
            fcntl.flock(_DEPTH.fd, fcntl.LOCK_EX)
        _DEPTH.n = d + 1
        try:
            yield
        finally:
            _DEPTH.n -= 1
            if _DEPTH.n == 0:
                fcntl.flock(_DEPTH.fd, fcntl.LOCK_UN); os.close(_DEPTH.fd)

def event(kind, **kw):
    with locked(), open(os.path.join(STATE, "events.jsonl"), "a") as f:
        f.write(json.dumps({"t": stamp(), "kind": kind, **kw}) + "\n")

def events():
    p = os.path.join(STATE, "events.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

def state_json(name, default):
    p = os.path.join(STATE, name)
    return json.load(open(p)) if os.path.exists(p) else default

def save_json(name, obj):
    p = os.path.join(STATE, name)
    with locked():
        with open(p + ".tmp", "w") as f:
            json.dump(obj, f, indent=1)
        os.replace(p + ".tmp", p)

def update_json(name, default, fn):
    with locked():
        obj = state_json(name, default); fn(obj); save_json(name, obj)

# ---------------------------------------------------------------- the score
def read_cases(path):
    out = []
    for line in open(path):
        f = line.rstrip("\n").split("\t", 3)
        if len(f) >= 3:
            out.append((f[0], f[1], float(f[2] or 0), f[3] if len(f) > 3 else ""))
    return out

def _norm(s):
    s = re.sub(r"#\d+(#\d+)*", "#N", s)
    return re.sub(r"0x[0-9a-f]+", "0x…", s).strip()

UNPORTED_RE = re.compile(r"unported: the (dart|Julia-only) definition (.*)")
SITE_RE = re.compile(r"(internal error at|invalid module at) (\S+:\d+ \S+?)(:|,|\s|$)")

def unported_site(why):
    m = UNPORTED_RE.search(why)
    return re.split(r", | \| |; ", m.group(2))[0] if m else None

_INSTANCE_RE = re.compile(r"(?<![\w.])(?:[A-Z_][\w.]*(?:\{[^\s]*\})?|\S*[{(]\S*)")

def _shape(reason):
    """A reason with the Julia types and values it names cut to `…`: on 2026-11-08 one gap, translateStorageType of a
    primitive class, was eight holds (Ptr{UInt8} 148 cases, Ptr{Nothing} 21, Ptr{Int64} 20, …, 240 in all, half the
    failing corpus), each too small to rank."""
    return re.sub(r"(…[\s,]*)+", "… ", _INSTANCE_RE.sub("…", reason)).strip()

def hold_key(outcome, label, why):
    """One rejection site and reason: the cases one fix can unlock (HILL.md, 'holds')."""
    if outcome == "wrong":
        return "G1 wrong: " + label
    if outcome == "unported":
        m = UNPORTED_RE.search(why)
        if m:
            site = unported_site(why)
            head, sep, reason = site.partition(": ")
            return _norm(("unported " if m.group(1) == "dart" else "unquarantined ") + head + sep + _shape(reason))[:200]
        return _norm("unported (unparsed): " + why[:140])
    m = SITE_RE.search(why)   # an Internal or InvalidModule keyed on its dart site alone, not its per-instance text
    if m:
        return _norm("G1 " + m.group(1) + " " + m.group(2))[:200]
    return _norm(f"G1 {outcome}: " + why[:100])

def score(cases, base=None):
    c = collections.Counter(o for _, o, _, _ in cases)
    s = {"passed": c["passed"], "climbable": len(cases) - c["outside"], "outside": c["outside"], "unported": c["unported"],
         "wrong": c["wrong"], "errored": c["errored"], "total": len(cases)}
    if base:   # S over the corpus as it stood at launch; cases added since count apart (HILL.md)
        s["passed_base"] = sum(1 for l, o, _, _ in cases if o == "passed" and l in base)
        s["added"] = sum(1 for l, _, _, _ in cases if l not in base)
    return s

def head_cases():
    p = os.path.join(STATE, "head-cases.tsv")
    return read_cases(p) if os.path.exists(p) else []

def baseline():
    p = os.path.join(STATE, "baseline-labels.txt")
    return set(open(p).read().split()) if os.path.exists(p) else set()

# the src tail: definitions dev/src_progress.sh counts as not ported (D40, D46), each kind's meaning from its line
TAIL_KINDS = {
    "Internal": "its body rejects Internal where Julia's inference finds it never returns; the progress line counts it "
                "not ported, \"each to triage\"",
    "Guard": "it returns nothing past a guard that rejects Internal; the progress line counts it not ported, "
             "\"each to triage\"",
    "Unported": "it still rejects Unported or Unquarantined: a gap to fill"}

TAIL_CHUNK = 6   # one move's worth: the definitions of one class, in dart's order, at most this many

def src_tail():
    """The scored head's not-ported definitions, in holds of one class's next few: the port's tail that no corpus
    case reaches (HILL.md stage 1 ends only when src progress reads its anchored total)."""
    p = os.path.join(STATE, "head-kinds.tsv")
    files = collections.OrderedDict()
    if os.path.exists(p):
        for line in open(p):
            f = line.rstrip("\n").split("\t")
            kind = next((x for x in f[:2] if x in TAIL_KINDS), None)
            anchor = next((x for x in f[:2] if x not in TAIL_KINDS), "")
            if kind and anchor:
                path, _, rest = anchor.partition(":")
                sym = rest.split(" ", 1)[-1]
                files.setdefault((path, sym.split(".")[0] if "." in sym else ""), []).append((kind, anchor))
    chunks = []
    for (path, cls), defs in files.items():
        defs.sort(key=lambda d: int(re.match(r"\d*", d[1].partition(":")[2]).group() or 0))
        chunks += [(path, cls, defs[i:i + TAIL_CHUNK]) for i in range(0, len(defs), TAIL_CHUNK)]
    out = []
    for path, cls, defs in chunks:
        kinds = collections.Counter(k for k, _ in defs)
        why = (f"src tail: {len(defs)} definition(s) of {path}{' ' + cls if cls else ''} that src/ does not port yet; no corpus case reaches them. "
               + " ".join(f"{k} ({n}): {TAIL_KINDS[k]}." for k, n in kinds.items())
               + " A rejection-only body is never ported (D46, refusal 3). For each: read it and its anchor at the pin, "
               "port what the anchor's body does with a case that reaches it (D12), or report blocked:ruling with what "
               "you found. The definitions:\n" + "\n".join(f"- {a} ({k})" for k, a in defs[:60]))
        out.append({"key": f"src tail {defs[0][1]}" + (f" (+{len(defs) - 1})" if len(defs) > 1 else ""), "cases": [], "defs": [a for _, a in defs], "secs": 0.0, "why": why,
                    "tail": True})
    return out

def holds(cases=None):
    cases = head_cases() if cases is None else cases
    parked = state_json("parked.json", {})
    kept = set(state_json("keeper.json", []))
    unkept = set(state_json("not-keeper.json", []))
    groups = collections.OrderedDict()
    for label, outcome, secs, why in cases:
        if outcome in ("passed", "outside"):
            continue
        k = hold_key(outcome, label, why)
        g = groups.setdefault(k, {"key": k, "cases": [], "secs": 0.0, "why": why[:400],
                                  "keeper": bool(RUNNER_GAP_RE.search(why))})
        g["cases"].append(label); g["secs"] += secs
        inst = (unported_site(why) if outcome == "unported" else None) or why[:160]
        g.setdefault("instances", collections.Counter())[inst] += 1
    out = list(groups.values())
    for f in state_json("fixfirst.json", []):          # audit findings, G2 losses and harvests: fix first (D21)
        out.append({"key": f["key"], "cases": f.get("cases", []), "secs": 0.0, "why": f["why"], "fixfirst": True,
                    "require_pass": f.get("require_pass", False), "keeper": f.get("keeper", False)})
    out += src_tail()
    for h in out:
        h["n"] = len(h["cases"]) or len(h.get("defs", []))
        h["id"] = hashlib.sha1(h["key"].encode()).hexdigest()[:10]
        h["parked"] = parked.get(h["id"])
        h["keeper"] = (h.get("keeper") or h["id"] in kept) and h["id"] not in unkept   # a ruling's word on the runner
    # the gates, then fix-first findings, then the corpus (S), then the src tail S does not reach
    rank = lambda h: (0 if h["key"].startswith("G") else 1 if h.get("fixfirst") else 3 if h.get("tail") else 2, -h["n"], h["secs"])
    return sorted(out, key=rank)

def passset():
    p = os.path.join(STATE, "passset.txt")
    return set(open(p).read().split()) if os.path.exists(p) else set()

def regress(cases):
    labels = {l for l, _, _, _ in cases}
    passed = {l for l, o, _, _ in cases if o == "passed"}
    return sorted((passset() & labels) - passed), sorted(l for l, o, _, _ in cases if o in ("wrong", "errored"))

def record(path, sha):
    cases = read_cases(path)
    with locked():
        lost, bad = regress(cases)
        shutil.copy(path, os.path.join(STATE, "head-cases.tsv"))
        if not os.path.exists(os.path.join(STATE, "baseline-labels.txt")):
            open(os.path.join(STATE, "baseline-labels.txt"), "w").write("\n".join(sorted(l for l, _, _, _ in cases)) + "\n")
        ps = passset() | {l for l, o, _, _ in cases if o == "passed"}
        open(os.path.join(STATE, "passset.txt"), "w").write("\n".join(sorted(ps)) + "\n")
        s = score(cases, baseline())
        event("scored", sha=sha, **s, lost=len(lost))
        if lost:   # G2: one fix-first hold per set of lost cases, never one per scored head
            key = "G2 lost " + hashlib.sha1("\n".join(lost).encode()).hexdigest()[:8] + f": {len(lost)} passing case(s)"
            def add(ff):
                if not any(f["key"] == key for f in ff):
                    ff.append({"key": key, "cases": lost, "require_pass": True,
                               "why": f"these cases passed before and do not at {sha}; find the landing that lost them "
                                      "(git bisect between the last scored heads) and fix it at its source (D12)"})
            update_json("fixfirst.json", [], add)
    return s, lost, bad

def advance(path, sha):
    """The cases a landed move's measurement read, written into the scored head's cases (not the pass set) at once: a gap that unlocks
    few passes uncovers the next gap of the same cases (on 2026-11-09 the 256-case translateStorageType hold passed 5
    and moved 251 on, 74 to jl_string_ptr, 62 to a memoryref's ptr_or_offset), so its next layer is a hold now, for
    the next move, not after the next full score, an hour and a half on. The full score still decides S and G2."""
    if not os.path.exists(path):
        return 0
    new = {l: (l, o, s_, w) for l, o, s_, w in read_cases(path)}
    with locked():
        rows = [new.pop(l, (l, o, s_, w)) for l, o, s_, w in head_cases()] + list(new.values())
        with open(os.path.join(STATE, "head-cases.tsv.tmp"), "w") as f:
            f.write("".join(f"{l}\t{o}\t{s_}\t{w}\n" for l, o, s_, w in rows))
        os.replace(os.path.join(STATE, "head-cases.tsv.tmp"), os.path.join(STATE, "head-cases.tsv"))
        # never the pass set: G2 reads a full score's losses against it, and a score of a head older than this landing
        # would count its new passes lost (2026-11-09: a false G2 of 9 at d72ffacf). Only record() grows it.
    n = len(read_cases(path))
    event("advanced", sha=sha, cases=n)
    return n

# ---------------------------------------------------------------- the budget: the account's whole spend
def weighted(u):
    return (u.get("cache_read_input_tokens", 0) * 0.1 + u.get("cache_creation_input_tokens", 0) * 1.25
            + u.get("input_tokens", 0) + u.get("output_tokens", 0) * 5)

def transcript_usage(path, since=""):
    """The weighted tokens of one transcript's assistant messages at or after `since`, each message once."""
    seen, w = set(), 0.0
    with open(path, errors="ignore") as f:
        for line in f:
            if '"assistant"' not in line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            m = d.get("message") or {}
            if d.get("type") != "assistant" or (d.get("timestamp") or "") < since or m.get("id") in seen:
                continue
            seen.add(m.get("id")); w += weighted(m.get("usage") or {})
    return w

def account_spend(days=1):
    """Every session of the account on this machine (the climb's, Dale's, a lead's), by day, read incrementally:
    the weekly limit counts them all, so the governor does too."""
    home = os.path.join(cfg()["claude_home"], "projects")
    with locked():
        cache = state_json("spend-cache.json", {})
        for p in glob.glob(os.path.join(home, "**", "*.jsonl"), recursive=True):
            st = os.stat(p)
            if st.st_mtime < time.time() - 8 * 86400:
                continue
            ent = cache.get(p, {"off": 0, "days": {}, "seen": []})
            if st.st_size < ent["off"]:
                ent = {"off": 0, "days": {}, "seen": []}
            if st.st_size == ent["off"]:
                continue
            seen = set(ent["seen"])
            with open(p, "rb") as f:
                f.seek(ent["off"])
                for raw in f:
                    if not raw.endswith(b"\n"):
                        break
                    ent["off"] += len(raw)
                    if b'"assistant"' not in raw:
                        continue
                    try:
                        d = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    m = d.get("message") or {}
                    if d.get("type") != "assistant" or m.get("id") in seen:
                        continue
                    seen.add(m.get("id"))
                    day = (d.get("timestamp") or "")[:10]
                    ent["days"][day] = ent["days"].get(day, 0.0) + weighted(m.get("usage") or {})
            ent["seen"] = list(seen)[-2000:]
            cache[p] = ent
        save_json("spend-cache.json", cache)
    want = {(now() - datetime.timedelta(days=i)).date().isoformat() for i in range(days)}
    return sum(v for ent in cache.values() for d, v in ent["days"].items() if d in want)

def week_start():
    """The weekly limit resets on Sunday (2026-11-01 and 11-08): its window counted from Sunday 00:00Z, the earliest
    the reset can be, so the count errs high."""
    t = now()
    return (t - datetime.timedelta(days=(t.weekday() + 1) % 7)).date().isoformat()

def week_spend():
    account_spend(1)   # refreshes the cache
    start = week_start()
    return sum(v for ent in state_json("spend-cache.json", {}).values() for d, v in ent["days"].items() if d >= start)

def week_half():
    """Half the week's limit spent: the climb pauses and Dale is told (Dale 2026-11-08). Lifted only by hand."""
    w, lim = week_spend(), cfg()["week_weighted"] * cfg()["week_pause"]
    if w < lim:
        return False
    if not os.path.exists(os.path.join(STATE, "PAUSE")):
        open(os.path.join(STATE, "PAUSE"), "w").write(f"week-half: {w/1e6:.0f}M of {cfg()['week_weighted']/1e6:.0f}M this week\n")
        event("week-half", spent=round(w), limit=round(cfg()["week_weighted"]))
        for_dale("the climb paused at half the week's usage", f"This week (from {week_start()} 00:00Z) the account spent "
                 f"{w/1e6:.0f}M weighted tokens of the {cfg()['week_weighted']/1e6:.0f}M weekly limit measured on 2026-11-02. "
                 "Default taken: paused until `bash dev/climb/launch.sh resume`.")
    return True

def allowance():
    c = cfg()
    return c["week_weighted"] * c["margin"] / 7

def over_budget():
    return account_spend(1) >= allowance() or account_spend(7) >= cfg()["week_weighted"] * cfg()["margin"]

def log_usage(role, task, model, d, w=None):
    u = (d or {}).get("usage", {})
    with locked(), open(os.path.join(STATE, "usage.tsv"), "a") as f:
        f.write("\t".join([stamp(), role, task, model, f"{weighted(u) if w is None else w:.0f}",
                           f"{(d or {}).get('total_cost_usd', 0):.4f}", str((d or {}).get("num_turns", 0))]) + "\n")

def climb_spend(since):
    w = usd = 0.0
    p = os.path.join(STATE, "usage.tsv")
    if os.path.exists(p):
        for line in open(p):
            f = line.rstrip("\n").split("\t")
            if f[0] >= stamp(since):
                w += float(f[4]); usd += float(f[5])
    return w, usd

# ---------------------------------------------------------------- the report and the map
def progress_line():
    p = os.path.join(COMMON, "wt-progress.tsv")
    if not os.path.exists(p):
        return "src: no progress row yet"
    last = open(p).read().strip().splitlines()[-1].split("\t")
    m = re.search(r"src: (\d+) of (\d+)", last[-1])
    return f"src: {m.group(1)} of {m.group(2)} dart definitions ported with a body (at {last[1]})" if m else last[-1][:200]

def report(k=12):
    cases = head_cases()
    lines = [progress_line()]   # D40: a status leads with src progress
    sc = [e for e in events() if e["kind"] == "scored"]
    if cases:
        s = score(cases, baseline())
        lines.append(f"S = {s.get('passed_base', s['passed'])} of the launch corpus pass ({s['passed']} of {s['climbable']} climbable "
                     f"with {s.get('added', 0)} cases added since); wrong {s['wrong']}, errored {s['errored']}, unported "
                     f"{s['unported']}, outside {s['outside']}; at {sc[-1]['sha'] if sc else '?'}")
        if len(sc) > 1:
            lines.append("S over time: " + " → ".join(str(e.get("passed_base", e["passed"])) for e in sc[-8:]))
    else:
        lines.append("S: no scored head yet (the scoreboard's first run)")
    ev = events()
    landed = [e for e in ev if e["kind"] == "landed"]
    lines.append(f"landings: {len(landed)} by the climb, {sum(1 for e in landed if e['t'] >= stamp(now() - datetime.timedelta(days=1)))} in 24 h")
    cw, cu = climb_spend(now() - datetime.timedelta(days=1))
    lines.append(f"this week (from {week_start()}): {week_spend()/1e6:.0f}M of {cfg()['week_weighted']/1e6:.0f}M weighted "
                 f"({100 * week_spend() / cfg()['week_weighted']:.1f}%; the climb pauses at {100 * cfg()['week_pause']:.0f}%)")
    lines.append(f"budget: the account today {account_spend(1)/1e6:.0f}M of {allowance()/1e6:.0f}M weighted, 7 days "
                 f"{account_spend(7)/1e6:.0f}M of {cfg()['week_weighted']*cfg()['margin']/1e6:.0f}M; the climb's own 24 h {cw/1e6:.0f}M (${cu:.0f})")
    hs = holds(cases)
    lines.append(f"holds: {len(hs)} ({sum(1 for h in hs if h['parked'])} parked); the largest:")
    for h in hs[:k]:
        tag = " [parked]" if h["parked"] else " [claimed]" if os.path.exists(os.path.join(STATE, "claims", h["id"])) else ""
        lines.append(f"  {h['n']:4d}  {h['key'][:110]}{tag}")
    je = state_json("judge-eval.json", None)
    lines.append(f"judge: refused {je['recall']:.0%} of past defects, approved " + (f"{je['approval']:.0%} of clean moves" if je.get('approval') is not None else "no clean move yet") + f" ({je['t'][:10]})"
                 if je else "judge: not measured yet (`climb.py judge-eval`)")
    fd = os.path.join(STATE, "for-dale.md")
    if os.path.exists(fd) and open(fd).read().strip():
        lines.append("for Dale (defaults taken): " + fd)
    return "\n".join(lines)

def draw_map(out):
    cases = head_cases(); s = score(cases, baseline()) if cases else None
    sc = [e for e in events() if e["kind"] == "scored"]
    hs = holds(cases)[:25]
    landed = [e for e in events() if e["kind"] == "landed"][-15:]
    pts = [e.get("passed_base", e["passed"]) for e in sc][-60:] or [0]
    mx = max(max(pts), 1)
    poly = " ".join(f"{i * 600 / max(len(pts) - 1, 1):.1f},{120 - 110 * p / mx:.1f}" for i, p in enumerate(pts))
    esc = html.escape
    big = s.get("passed_base", s["passed"]) if s else "—"
    pct = f"{100 * s['passed'] / max(s['climbable'], 1):.1f}%" if s else "—"
    rows = "".join(f"<tr><td class=n>{h['n']}</td><td>{esc(h['key'])}</td><td>{'parked' if h['parked'] else ''}</td></tr>" for h in hs)
    lrows = "".join(f"<tr><td>{esc(e['t'][5:16])}</td><td>{esc(e.get('commit', '')[:8])}</td><td>{esc(e.get('hold', '')[:90])}</td><td class=n>+{e.get('unlocked', 0)}</td></tr>" for e in reversed(landed))
    doc = f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>WasmTarget Climb</title><style>
:root{{--bg:#14121a;--fg:#e8e4f0;--mut:#9a93ad;--acc:#b9a3ff;--card:#1e1b27;--line:#2c2838}}
@media (prefers-color-scheme: light){{:root:not([data-theme=dark]){{--bg:#faf8ff;--fg:#1d1a26;--mut:#6b6480;--acc:#6d4fd8;--card:#fff;--line:#e6e1f2}}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif;padding:24px 16px;max-width:1000px;margin:auto}}
h1{{font-size:20px;margin:0 0 4px}} .mut{{color:var(--mut)}} .big{{font-size:42px;font-weight:700;color:var(--acc)}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:14px 0;overflow-x:auto}}
table{{border-collapse:collapse;width:100%}} td{{padding:4px 8px;border-top:1px solid var(--line);vertical-align:top}} .n{{text-align:right;font-variant-numeric:tabular-nums}}
svg{{width:100%;height:130px}} polyline{{fill:none;stroke:var(--acc);stroke-width:2}}</style>
<h1>WasmTarget climb</h1><div class=mut>drawn {esc(stamp())} by dev/climb/climb.py · {esc(progress_line())}</div>
<div class=card><div class=big>{big} <span class=mut style="font-size:18px">cases of the launch corpus pass · {s['passed'] if s else '—'} of {s['climbable'] if s else '—'} climbable ({pct})</span></div>
<div class=mut>wrong {s['wrong'] if s else '—'} · errored {s['errored'] if s else '—'} · unported {s['unported'] if s else '—'} · outside the subset {s['outside'] if s else '—'} · added {s.get('added', 0) if s else '—'}</div>
<svg viewBox="0 0 600 125" preserveAspectRatio=none><polyline points="{poly}"/></svg><div class=mut>S per scored head</div></div>
<div class=card><b>Holds</b> <span class=mut>(cases one fix can unlock; gates and fix-first findings first)</span><table>{rows}</table></div>
<div class=card><b>Recent landings</b><table>{lrows}</table></div>
<div class="card mut">{esc(report(0)).replace(chr(10), '<br>')}</div>"""
    open(out, "w").write(doc)
    return out

# ---------------------------------------------------------------- agents
_SEV = {"type": "string", "enum": ["blocker", "should", "nit"]}
SCHEMA_CLIMB = {"type": "object", "required": ["outcome", "handoff"], "properties": {
    "outcome": {"type": "string", "enum": ["committed", "blocked:no-counterpart", "blocked:ruling", "blocked:infra", "gave-up"]},
    "commit": {"type": "string"}, "unlocked": {"type": "array", "items": {"type": "string"}},
    "still_failing": {"type": "array", "items": {"type": "string"}}, "counterpart": {"type": "array", "items": {"type": "string"}},
    "evidence": {"type": "array", "items": {"type": "string"}}, "handoff": {"type": "string"}}}
_FINDING = {"type": "object", "required": ["id", "severity", "claim"], "properties": {"id": {"type": "string"}, "severity": _SEV,
    "refusal": {"type": "integer"}, "file": {"type": "string"}, "line": {"type": "integer"}, "claim": {"type": "string"},
    "fix": {"type": "string"}, "status": {"type": "string", "enum": ["new", "open", "resolved"]}}}
SCHEMA_REVIEW = {"type": "object", "required": ["verdict", "fidelity", "findings"], "properties": {
    "verdict": {"type": "string", "enum": ["APPROVE", "CHANGES"]}, "fidelity": {"type": "integer"},
    "findings": {"type": "array", "items": _FINDING}}}
AUDIT_AREAS = (("builder", "builder"), ("collection_and_planning", "collection and planning"),
               ("emission_and_diagnostics", "emission and diagnostics"), ("enforcement_and_prose", "enforcement and prose"))
SCHEMA_AUDIT = {"type": "object", "required": ["topics", "areas", "stopgap", "precedent", "resolution", "findings"], "properties": {
    "topics": {"type": "string"}, "stopgap": {"type": "string"}, "precedent": {"type": "string"}, "resolution": {"type": "string"},
    "areas": {"type": "object", "required": [k for k, _ in AUDIT_AREAS], "properties": {k: {"type": "string"} for k, _ in AUDIT_AREAS}},
    "findings": {"type": "array", "items": {"type": "object", "required": ["id", "severity", "claim"], "properties": dict(
        _FINDING["properties"], severity={"type": "string", "enum": ["high", "medium", "low"]},
        requirement={"type": "string"}, fix_first={"type": "boolean"})}}}}
SCHEMA_RULING = {"type": "object", "required": ["ruling", "requeue", "escalate"], "properties": {"ruling": {"type": "string"},
    "keeper": {"type": "boolean"},
    "requeue": {"type": "boolean"}, "escalate": {"type": "boolean"}, "for_dale": {"type": "string"}, "ledger_row": {"type": "string"}}}

# the briefs, each a template the driver fills (their full paths, so the ratchet's L130 sees them consumed)
TEMPLATES = {"climber.md": "dev/climb/climber.md", "keeper.md": "dev/climb/keeper.md", "reviewer.md": "dev/climb/reviewer.md",
             "auditor.md": "dev/climb/auditor.md", "ruling.md": "dev/climb/ruling.md"}

def render(template, **kw):
    t = open(os.path.join(ROOT, TEMPLATES[template])).read()
    for k, v in kw.items():
        t = t.replace("{{" + k + "}}", str(v))
    return t

# An agent's fence (HILL.md G5), every layer measured on 2026-11-08 with a probe agent:
# - Claude Code's sandbox binds Bash: writes reach its cwd and the git objects, never the git config, the hooks or the
#   judge's state outside the repository.
# - The sandbox does not bind the file tools, so in "dontAsk" mode a tool runs only when the allowlist names it: Edit and
#   Write only under the agent's own worktree, and of Kaimon's 53 tools only the four a climber needs (agent_run,
#   pkg_add and edit_code are refused).
# - Push is refused by the pre-push hook (only origin's ship.sh pushes wt2), by ship.sh on a climb slot without the
#   driver's WT_CLIMB_DRIVER, and by the agent's env.
SANDBOX = json.dumps({"sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True, "allowUnsandboxedCommands": False}})
NO_PUSH = ["Bash(git push:*)", "Bash(bash dev/ship.sh:*)", "Bash(dev/ship.sh:*)", "Bash(bash dev/autoship.sh:*)"]
# D39: a climber's warm Julia. Kaimon's Julia runs outside the sandbox, so climber.md confines it to Julia questions.
KAIMON_TOOLS = ["mcp__kaimon__start_session", "mcp__kaimon__ex", "mcp__kaimon__manage_repl", "mcp__kaimon__check_eval"]

def agent_env():
    return dict(os.environ, WT_CLIMB_AGENT="1", GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1",
                GIT_CONFIG_KEY_0="remote.origin.pushurl", GIT_CONFIG_VALUE_0="file:///nonexistent/climb-agents-never-push")

def claude_cmd(model, effort, schema, tools, prompt, sid, cwd, resume=False, cap=None, kaimon=False):
    c = cfg()
    mcp = os.path.join(STATE, "mcp-kaimon.json" if kaimon else "mcp-none.json")
    with locked():
        json.dump({"mcpServers": {"kaimon": {"type": "http", "url": c["kaimon_url"]}} if kaimon else {}}, open(mcp + ".tmp", "w"))
        os.replace(mcp + ".tmp", mcp)
    root = "/" + os.path.abspath(cwd)   # "//abs/path": a permission rule's absolute path
    allowed = [f"{t}({root}/**)" if t in ("Edit", "Write") else t for t in tools] + (KAIMON_TOOLS if kaimon else [])
    cmd = ["claude", "-p", prompt, "--model", model, "--effort", effort, "--output-format", "json",
           "--json-schema", json.dumps(schema), "--tools", *tools, "--allowedTools", *allowed, "--disallowedTools", *NO_PUSH,
           "--strict-mcp-config", "--mcp-config", mcp, "--setting-sources", "project", "--settings", SANDBOX,
           "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections",
           "--permission-mode", "dontAsk", "--max-budget-usd", str(cap or c["task_cap_usd"])]
    cmd += ["--resume", sid] if resume else ["--session-id", sid]
    return cmd

def run_agent(role, task, cmd, cwd, sid):
    """One agent, its usage logged even when it times out or prints nothing parseable (read from its transcript)."""
    t0 = time.time()
    model = cmd[cmd.index("--model") + 1]
    sid = sid or cmd[cmd.index("--session-id") + 1]
    if week_half() or over_budget():   # every run, not only a move's first: a move never overshoots by its later steps
        event("budget-refused", role=role, task=task)
        return None, None
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=cfg()["task_wall_s"], env=agent_env(),
                           stdin=subprocess.DEVNULL)
        out, err = r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        out, err = "", "timeout"
    open(os.path.join(STATE, "runs", f"{task}.{role}.{int(t0)}.json"), "w").write(out)
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        d = None
    if d is None:
        tp = glob.glob(os.path.join(cfg()["claude_home"], "projects", "*", f"{sid}.jsonl"))
        w = sum(transcript_usage(p, stamp(datetime.datetime.fromtimestamp(t0, datetime.timezone.utc))) for p in tp)
        log_usage(role, task, model, None, w)
        event("agent-error", role=role, task=task, after=round(time.time() - t0), stderr=err[-300:])
        return None, None
    log_usage(role, task, model, d)
    so = d.get("structured_output")
    if so is None:
        try:
            so = json.loads(d.get("result", ""))
        except (json.JSONDecodeError, TypeError):
            so = None
    return so, d

_QUIET = {"n": 0, "stopped": []}
_QUIET_LOCK = threading.Lock()

@contextlib.contextmanager
def quiesced(slot):
    """While the driver lands a move, the other slots' Julia and the scoreboard's are stopped (SIGSTOP) and resumed
    after: a landing's check is at D14's band on an idle machine (139-157 s against a red past 140 s), and two
    climbers beside it made 171 s and 182 s. The landing slot's own Julia is never stopped: it shares the depot the
    check compiles into, and a stopped holder of its pidfile would hold the check (2026-10 pidfile deadlock)."""
    others = [os.path.join(WORKTREES, d) for d in os.listdir(WORKTREES) if re.fullmatch(r"climb-\d+", d)
              and os.path.join(WORKTREES, d) != os.path.abspath(slot)] + [os.path.join(STATE, "board")]
    with _QUIET_LOCK:
        _QUIET["n"] += 1
        if _QUIET["n"] == 1:
            for pid in sh(["pgrep", "-x", "julia"]).stdout.split():
                args = sh(["ps", "-o", "command=", "-p", pid]).stdout
                cwd = next((l[1:] for l in sh(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"]).stdout.splitlines()
                            if l.startswith("n")), "")
                if any(o in args or cwd == o or cwd.startswith(o + "/") for o in others):
                    with contextlib.suppress(ProcessLookupError, ValueError):
                        os.kill(int(pid), signal.SIGSTOP); _QUIET["stopped"].append(int(pid))
    try:
        yield
    finally:
        with _QUIET_LOCK:
            _QUIET["n"] -= 1
            if _QUIET["n"] == 0:
                for pid in _QUIET["stopped"]:
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGCONT)
                _QUIET["stopped"] = []

def slot_state(slot):
    """The one-commit, clean-tree invariant every step of a move holds the slot to."""
    commits = [l[2:] for l in git("cherry", f"origin/{MARCH}", "HEAD", cwd=slot).splitlines() if l.startswith("+")]
    return commits, git("status", "--porcelain", cwd=slot)

def review(task, slot, base, commit, prior=None):
    c = cfg()
    prompt = render("reviewer.md", WORKTREE=slot, COMMIT=commit, BASE=base)
    if prior:
        prompt += "\n\nPrevious round's findings and the climber's answers:\n" + json.dumps(prior, indent=1)
    so, _ = run_agent("review", task, claude_cmd(c["climber_model"], c["reviewer_effort"], SCHEMA_REVIEW,
                      ["Bash", "Read", "Grep", "Glob"], prompt, str(uuid.uuid4()), slot), slot, None)
    if git("rev-parse", "HEAD", cwd=slot) != commit or git("status", "--porcelain", cwd=slot):
        raise ClimbError("the reviewer changed the slot it was reviewing")
    return so

def approved(rv):
    return bool(rv) and rv.get("verdict") == "APPROVE" and not any(
        f.get("severity") in ("blocker", "should") and f.get("status") != "resolved" for f in rv.get("findings", []))

def added_lines(slot, path=None):
    args = ["diff", "-U0", f"origin/{MARCH}...HEAD"] + (["--", path] if path else [])
    return [l[1:] for l in git(*args, cwd=slot).splitlines() if l.startswith("+") and not l.startswith("+++")]

def g5(slot, keeper=False):
    """The judge untouched (HILL.md G5); a keeper move changes the runner and its test, and nothing else."""
    names = git("diff", "--name-only", f"origin/{MARCH}...HEAD", cwd=slot).splitlines()
    if keeper:
        return [f"{n} (a keeper move changes only {' and '.join(RUNNER_FILES)})" for n in names if n not in RUNNER_FILES]
    status = {}
    for l in git("diff", "--name-status", f"origin/{MARCH}...HEAD", cwd=slot).splitlines():
        f = l.split("\t")
        if len(f) >= 2:
            status[f[-1]] = f[0][0]
    bad = [n for n in names if any(re.search(p, n) for p in PROTECTED)]
    bad += [f"{n} (an existing model changes; models change only by ruling)" for n in names
            if any(re.search(p, n) for p in NEW_ONLY) and status.get(n, "M") != "A"]
    for n in names:
        if any(re.search(p, n) for p in ADD_ONLY):
            removed = [l for l in git("diff", "-U0", f"origin/{MARCH}...HEAD", "--", n, cwd=slot).splitlines()
                       if l.startswith("-") and not l.startswith("---") and l[1:].strip()]
            if removed:
                bad.append(f"{n} (removes or changes {len(removed)} line(s); it may only gain lines)")
            if n.endswith(".jl"):
                for l in added_lines(slot, n):
                    if re.search(r"\b(GROUPS|XFAIL)\b", l):
                        bad.append(f"{n} (an added line names GROUPS or XFAIL: {l.strip()[:80]})")
                # a name the corpus binds is never rebound, read by Julia's parser, not a regex (A97E2)
                base = os.path.join(slot, ".wtd", "corpus-base.jl")
                os.makedirs(os.path.dirname(base), exist_ok=True)
                open(base, "w").write(git("show", f"origin/{MARCH}:{n}", cwd=slot))
                r = sh(["julia", "--startup-file=no", os.path.join(ROOT, "dev", "climb", "corpus_names.jl"), base,
                        os.path.join(slot, n)], timeout=300)
                if r.returncode != 0:
                    bad.append(f"{n} (Julia's parser does not read it: {(r.stderr or r.stdout).strip()[-200:]})")
                for l in r.stdout.splitlines():
                    f = l.split("\t")
                    if f[0] == "rebind":
                        bad.append(f"{n} (rebinds {f[1]}, which the corpus binds {f[2]} time(s); {f[3]} after the move)")
                    elif f[0] == "form":
                        bad.append(f"{n} (adds a top-level {f[1]}, no definition or registration: {f[2]})")
    return bad

@contextlib.contextmanager
def julia_slot(kind):
    """The driver's heavy Julia, one of each kind at a time (D31): one verify and one score, each a single thread at
    background QoS, never beside a landing's check (it waits while ship.sh holds the landing lock). A score takes
    about an hour; under one lock with verify it would stall every move's measurement for that hour."""
    fd = os.open(os.path.join(STATE, f".julia-{kind}.lock"), os.O_CREAT | os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        while os.path.isdir(os.path.join(COMMON, "wt-landing-lock")):
            time.sleep(20)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def sentinels(k=8):
    """A net under every move: the k groups with the most passing cases per second on the scored head, so a
    change that breaks the corpus broadly is caught before it lands (G2 over the whole corpus holds at the next score)."""
    per = collections.defaultdict(lambda: [0, 0.0])
    for l, o, secs, _ in head_cases():
        g = per[l.split("/", 1)[0]]; g[1] += secs
        if o == "passed":
            g[0] += 1
    return [g for g, _ in sorted(per.items(), key=lambda kv: -kv[1][0] / max(kv[1][1], 0.5)) if per[g][0]][:k]

def verify(slot, h):
    """Charter rule 6: the driver re-measures the move itself: the hold's groups and the sentinel net, or the net
    alone for a hold no case reaches yet (an audit finding, a harvest, the src tail). The whole corpus is G2's at
    the next score, where a loss becomes a fix-first hold. Returns (unlocked, problems)."""
    groups = sorted({c.split("/", 1)[0] for c in h["cases"]} | set(sentinels()))
    full = not groups   # no scored head yet: the whole corpus
    out = os.path.join(slot, ".wtd", "verify-cases.tsv")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, JULIA_NUM_THREADS="1", WT_SMOKE_CASES=out)
    if groups and not full:
        env["WT_SMOKE_EXACT"] = "1"
        # only the hold's cases and the sentinel groups', and any case the corpus gained since the scored head: a hold
        # of 256 cases spans most groups, and running them whole took an hour a measurement (2026-11-09)
        known = [l for l, _, _, _ in head_cases()]
        sent = set(sentinels())
        only = set(h["cases"]) | {l for l in known if l.split("/", 1)[0] in sent}
        for name, labels in (("WT_SMOKE_ONLY", only), ("WT_SMOKE_KNOWN", known)):
            f = os.path.join(slot, ".wtd", name.lower() + ".txt")
            open(f, "w").write("\n".join(sorted(labels)) + "\n"); env[name] = f
    env["JULIA_DEPOT_PATH"] = sh(["bash", os.path.join(ROOT, "dev", "depot.sh"), "path", slot]).stdout.strip()
    with julia_slot("verify"):
        try:   # the slot's test/smoke.jl and runner: G5 has held them to origin's before this runs; its corpus may gain cases
            r = sh(["taskpolicy", "-b", "julia", "--project=.", "--startup-file=no", "test/smoke.jl",
                    *([] if full else groups)], cwd=slot, env=env, timeout=cfg()["smoke_wall_s"])
        except subprocess.TimeoutExpired:
            return [], ["the driver's smoke passed its hard limit"]
    if not os.path.exists(out):
        return [], ["the driver's smoke wrote no cases: " + (r.stdout + r.stderr)[-600:]]
    cases = read_cases(out)
    lost, _ = regress(cases)
    before = {l: (o, w) for l, o, _, w in head_cases()}
    hc = set(h["cases"])
    unlocked = sorted(l for l, o, _, _ in cases if o == "passed" and l in hc)
    added = "\n".join(added_lines(slot))
    # progress: a case passes, or stops at a deeper unported site the move did not itself write (a new stub that
    # moves a case is refusal 3, never progress)
    def progressed(l, o, w):
        if o == "passed":
            return True
        site = unported_site(w) if o == "unported" else None
        return bool(site) and hold_key(o, l, w) != h["key"] and site.split(" ")[0] not in added
    moved = [l for l, o, _, w in cases if l in hc and progressed(l, o, w)]
    problems = [f"G2 lost {l}" for l in lost]
    problems += [f"G1 {o} {l}: {w[:200]}" for l, o, _, w in cases
                 if o in ("wrong", "errored") and before.get(l, ("",))[0] not in ("wrong", "errored")]
    problems += [f"newly outside the subset (needs a ruling): {l}" for l, o, _, _ in cases
                 if o == "outside" and l in before and before[l][0] != "outside"]
    if h.get("keeper"):   # the runner reads more; it never passes a case whose failure was not its own gap
        problems += [f"a keeper move flips {l} to passing, whose failure was not the runner's: {before[l][1][:160]}"
                     for l, o, _, _ in cases if o == "passed" and l in before and before[l][0] != "passed"
                     and l not in hc and not RUNNER_GAP_RE.search(before[l][1])]
    if h.get("tail") and not git("diff", "--name-only", f"origin/{MARCH}...HEAD", "--", "src/", cwd=slot):
        problems.append("a src-tail move that changes nothing under src/")
    if h.get("require_pass"):
        problems += [f"G2 still not passing: {l}" for l in sorted(hc - set(unlocked))]
    elif hc and not moved:
        problems.append("no case of the hold passes or reaches a deeper unported site the move did not write")
    return unlocked, problems

# ---------------------------------------------------------------- slots and moves
def fence_kaimon(path, name):
    """A climber's Kaimon session is Julia outside Claude Code's sandbox (A97E1). Its julia_bin becomes a wrapper in
    the climb's state, which the agent cannot write, that runs Julia under macOS's sandbox (the seatbelt Claude
    Code's own sandbox uses): writes only under the slot within GroupTherapyOrg (so never the climb's state, the git
    refs or hooks, another worktree), and no network but localhost (so no push). Measured 2026-11-08: a slot write,
    a temp write and a depot compile pass; the state, the hooks and `git ls-remote origin` are refused. A session
    of the slot alive at a move's start is stopped, so each move's starts fenced. It runs at background QoS (taskpolicy -b),
    as all the climb's Julia does, so a warm session's compile never slows a landing's check on the performance
    cores (2026-11-08: a check ran 171 s, past D14's band, beside two climbers' sessions)."""
    org = os.path.dirname(REPO)
    sb, wrap = os.path.join(STATE, "fence", f"{name}.sb"), os.path.join(STATE, "fence", f"julia-{name}")
    os.makedirs(os.path.dirname(sb), exist_ok=True)
    home = os.path.expanduser("~")
    # an allowlist (A98E1): the slot, the session's own gate socket and log under Kaimon's cache, the temp dirs, and
    # Julia's logs, scratch spaces and juliaup state; no outbound connection but localhost, so no other session's
    # gate socket and no remote. Measured 2026-11-08 on a real Kaimon session: it starts and evaluates, writes its
    # slot, and is refused ~/.config/kaimon, another gate socket, `git ls-remote origin` and the climb's state.
    open(sb, "w").write(f"""(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "{path}") (subpath "{home}/.cache/kaimon/sock") (subpath "{home}/.cache/kaimon/sessions")
  (subpath "/private/var/folders") (subpath "/private/tmp") (subpath "{home}/.julia/logs") (subpath "{home}/.julia/juliaup")
  (subpath "{home}/.julia/scratchspaces") (literal "/dev/null") (regex #"^/dev/tty") (literal "/dev/ptmx") (subpath "/dev/fd"))
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
""")
    depot = sh(["bash", os.path.join(ROOT, "dev", "depot.sh"), "path", path]).stdout.strip()
    open(wrap, "w").write(f"#!/bin/sh\n# dev/climb/climb.py fence_kaimon: {name}'s Kaimon Julia, sandboxed\n"
                          f"JULIA_DEPOT_PATH=\"{depot}\" exec /usr/sbin/taskpolicy -b /usr/bin/sandbox-exec -f \"{sb}\" \"{shutil.which('julia')}\" \"$@\"\n")
    os.chmod(wrap, 0o755)
    proj = os.path.expanduser("~/.config/kaimon/projects.json")
    with locked():
        d = json.load(open(proj)) if os.path.exists(proj) else {"projects": []}
        ps = [p for p in d.get("projects", []) if p.get("project_path") != path]
        ps.append({"project_path": path, "enabled": True, "launch_config": {"threads": "4", "startup_file": False,
                   "instantiate": "auto", "julia_bin": wrap}})
        d["projects"] = ps
        json.dump(d, open(proj + ".tmp", "w"), indent=2); os.replace(proj + ".tmp", proj)
    # every move starts with no session of the slot's alive: a private session per move otherwise piles up (ten
    # resident Julias on 2026-11-08, beside D14's red checks), and a session restarted around the fence ends here
    # the pattern never starts with "--": pgrep read "--project=…" as its own flag and matched nothing, so sessions
    # piled up, twelve on 2026-11-08 with 10.9 of 12 GB of swap used, and every landing check went red on D14
    for line in sh(["pgrep", "-f", f"project={path}"]).stdout.split():
        with contextlib.suppress(ProcessLookupError, ValueError):
            os.kill(int(line), signal.SIGTERM)
    event("fenced", slot=name)

def slot_ready(name):
    """A climber's worktree at origin/wt2. Earlier work is kept on a salvage branch, never reset away; the
    branch's name is returned so the next climber starts from it."""
    path = os.path.join(WORKTREES, name)
    fetch()
    if not os.path.isdir(path):
        r = sh(["bash", "dev/lane.sh", "start", name])
        if r.returncode != 0:
            raise ClimbError(f"dev/lane.sh start {name}: {(r.stdout + r.stderr)[-300:]}")
        if re.fullmatch(r"climb-\d+", name):
            fence_kaimon(path, name)
        return path, None
    gd = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=path)
    for op, cmd in (("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick")):
        if os.path.exists(os.path.join(gd, op)):
            git(cmd, "--abort", cwd=path, check=False)
    salvage = None
    commits, dirty = slot_state(path)
    if dirty or commits:
        salvage = f"salvage/{name}-{now().strftime('%Y%m%dT%H%M%S')}"
        git("checkout", "-q", "-b", salvage, cwd=path)
        if dirty:
            git("add", "-A", cwd=path)
            git("commit", "-q", "--no-verify", "-m", f"wip(salvage): {name}'s uncommitted work, kept by dev/climb", cwd=path)
        event("salvaged", slot=name, branch=salvage)
    git("checkout", "-q", "--no-track", "-B", name, f"origin/{MARCH}", cwd=path)   # no upstream: no write to the shared .git/config, which two slots raced for
    if re.fullmatch(r"climb-\d+", name):
        fence_kaimon(path, name)
    return path, salvage

def claim(h, slot):
    p = os.path.join(STATE, "claims", h["id"])
    try:
        fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    os.write(fd, json.dumps({"slot": slot, "pid": os.getpid(), "t": stamp(), "key": h["key"]}).encode()); os.close(fd)
    return True

def unclaim(h):
    try:
        os.remove(os.path.join(STATE, "claims", h["id"]))
    except FileNotFoundError:
        pass

def reap_claims():
    """A claim whose process is gone frees its hold (a stopped or crashed driver leaves no hold unclimbable)."""
    for p in glob.glob(os.path.join(STATE, "claims", "*")):
        try:
            os.kill(json.load(open(p)).get("pid"), 0)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            os.remove(p); event("reaped", claim=os.path.basename(p))

def for_dale(title, text):
    with locked(), open(os.path.join(STATE, "for-dale.md"), "a") as f:
        f.write(f"\n## {stamp()} — {title}\n{text}\n")

def park(h, why, tell=True):
    update_json("parked.json", {}, lambda p: p.__setitem__(h["id"], {"key": h["key"], "why": why, "t": stamp()}))
    event("parked", hold=h["key"], why=why[:300])
    if tell:
        for_dale("parked: " + h["key"][:100], why[:1500] + "\nDefault taken: the hold waits; the climb goes on with the others.")

def fable_left():
    day = stamp(now().replace(hour=0, minute=0, second=0, microsecond=0))
    return cfg()["fable_per_day"] - sum(1 for e in events() if e["kind"] == "fable" and e["t"] >= day)

def rule(h, escalation, slot):
    """Opus rules first (D48); only a ruling that names itself beyond Opus goes to Fable, at most fable_per_day."""
    c = cfg()
    prior = "\n".join(f"- {x['ruling']}" for x in state_json("rulings.json", {}).get(h["id"], [])) or "(none)"
    prompt = render("ruling.md", WORKTREE=slot, ESCALATION=escalation, RULINGS=prior)
    tools = ["Bash", "Read", "Grep", "Glob"]
    so, _ = run_agent("ruling", h["id"], claude_cmd(c["ruler_model"], "high", SCHEMA_RULING, tools, prompt, str(uuid.uuid4()), slot), slot, None)
    if so and so.get("escalate"):
        if fable_left() > 0:
            event("fable", hold=h["key"])
            so2, _ = run_agent("ruling-fable", h["id"], claude_cmd(c["fable_model"], "high", SCHEMA_RULING, tools,
                               prompt + "\n\nOpus's ruling, which asked for yours:\n" + so["ruling"], str(uuid.uuid4()), slot), slot, None)
            so = so2 or so
        else:
            park(h, "Opus asked for Fable's ruling and today's Fable rulings are spent: " + so["ruling"][:1000]); return
    if not so:
        park(h, "the ruling run returned nothing; " + escalation[:600]); return
    update_json("rulings.json", {}, lambda r: r.setdefault(h["id"], []).append({"ruling": so["ruling"], "t": stamp()}))
    if so.get("for_dale") or so.get("ledger_row"):
        for_dale(h["key"][:100], so.get("for_dale", "") + (f"\nproposed ledger row: {so['ledger_row']}" if so.get("ledger_row") else ""))
    event("ruled", hold=h["key"], requeue=so["requeue"], keeper=bool(so.get("keeper")), ruling=so["ruling"][:300])
    if so.get("keeper") is not None and bool(so["keeper"]) != bool(h.get("keeper")):
        # the ruling moves the hold between a keeper (the runner's gap) and a climber (the compiler's), and back to the climb
        name, other = ("keeper.json", "not-keeper.json") if so["keeper"] else ("not-keeper.json", "keeper.json")
        update_json(name, [], lambda k: k.append(h["id"]) if h["id"] not in k else None)
        update_json(other, [], lambda k: k.remove(h["id"]) if h["id"] in k else None)
        update_json("parked.json", {}, lambda p: p.pop(h["id"], None))
        return
    if not so["requeue"]:
        park(h, so["ruling"], tell=False)

def finish(h, outcome, slot, note, salvage_hint=None):
    """A move that did not land: its handoff kept (with where its work is), and the hold ruled, retried or parked."""
    event("stopped", hold=h["key"], outcome=outcome, note=note[:600])
    hand = note[-2500:] + (f"\n\nThe last climber's commit stays on this slot's branch; the next move keeps it on a salvage "
                           f"branch (named in your brief): start from it if it is right." if salvage_hint else "")
    update_json("handoffs.json", {}, lambda hs: hs.__setitem__(h["id"], hand))
    stops = sum(1 for e in events() if e["kind"] == "stopped" and e.get("hold") == h["key"])
    # a hold that unlocks more earns more tries before it waits for Dale: 3 under 50 cases, then 4, 5, 6 at 200
    if stops >= cfg()["stops_per_hold"] + sum(h.get("n", 0) >= k for k in (50, 100, 200)):
        park(h, f"{stops} moves stopped without landing; the last: {outcome}: {note[:1200]}")
    elif outcome in ("gave-up", "budget"):
        pass                                  # once more, from the handoff
    elif outcome == "blocked:infra":
        if stops >= 2:
            park(h, f"infrastructure stopped two moves: {note[:1200]}")
        last = [e["outcome"] for e in events() if e["kind"] == "stopped"][-4:]
        if len(last) == 4 and all(o == "blocked:infra" for o in last):
            open(os.path.join(STATE, "PAUSE"), "w").write("four moves in a row stopped on infrastructure\n")
            for_dale("the climb paused itself", "Four moves in a row stopped on infrastructure (ship.sh, the check, git). "
                     f"The last: {note[:1200]}\nDefault taken: paused until `bash dev/climb/launch.sh resume`.")
    else:
        rule(h, f"outcome: {outcome}\n\n{note}", slot)
    unclaim(h)
    return outcome

def move(h, slot_name):
    """One climber, one hold: climb → G5 → the driver's measurement → review → land, or a ruling."""
    c = cfg()
    slot, salvage = slot_ready(slot_name)
    base = git("rev-parse", "--short", "HEAD", cwd=slot)
    task = f"{h['id']}-{int(time.time())}"
    caselines = "\n".join(f"- {l}" for l in h["cases"][:40]) or "- (no case reaches it yet: write one that does, D12)"
    if len(h["cases"]) > 40:
        caselines += f"\n- … and {len(h['cases']) - 40} more"
    hand = state_json("handoffs.json", {}).get(h["id"])
    if salvage:
        hand = (hand or "") + f"\n\nThis slot's earlier unlanded work is on the local branch {salvage} (`git log -p origin/{MARCH}..{salvage}`)."
    rl = state_json("rulings.json", {}).get(h["id"], [])
    brief = render("keeper.md" if h.get("keeper") else "climber.md", WORKTREE=slot, BRANCH=slot_name, BASE=base,
                   HOLD=f"**{h['key']}**\n\nWhy (the first case's rejection): {h['why']}" + (
                       "\n\nThe hold's distinct rejections (one gap, its instances; port the gap, not one instance):\n" +
                       "\n".join(f"- {n} × {r}" for r, n in h["instances"].most_common(15)) if len(h.get("instances", {})) > 1 else ""),
                   CASES=caselines, HANDOFF=f"## The last climber's handoff\n\n{hand}" if hand else "",
                   RULINGS="## Rulings on this hold (bound by these)\n\n" + "\n".join(f"- {x['ruling']}" for x in rl) if rl else "")
    open(os.path.join(STATE, "briefs", f"{task}.md"), "w").write(brief)
    event("climb", hold=h["key"], slot=slot_name, task=task)
    tools = ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]
    sid = str(uuid.uuid4())
    so, d = run_agent("climb", task, claude_cmd(c["climber_model"], c["climber_effort"], SCHEMA_CLIMB, tools, brief, sid, slot, kaimon=True), slot, sid)
    if not so:
        return finish(h, "gave-up", slot, "the climber returned no report (timeout, cap or error)", slot_name)
    if so["outcome"] != "committed":
        return finish(h, so["outcome"], slot, so.get("handoff", ""))
    resumes = 0
    def resume(ask):
        nonlocal resumes
        if resumes >= c["resumes_per_move"] or over_budget():
            return None
        resumes += 1
        so2, _ = run_agent("climb", task, claude_cmd(c["climber_model"], c["climber_effort"], SCHEMA_CLIMB, tools,
                           ask + "\nThen reply with the same JSON as before.", sid, slot, resume=True, cap=c["resume_cap_usd"], kaimon=True), slot, sid)
        return so2
    def gated():
        """Every gate the driver holds a commit to, re-run after every change to it."""
        commits, dirty = slot_state(slot)
        if len(commits) != 1 or dirty:
            return [], [f"one commit and a clean tree expected; found {len(commits)} commit(s), tree {'dirty' if dirty else 'clean'}"]
        bad = g5(slot, keeper=h.get("keeper", False))
        if bad:
            return [], ["G5: " + b for b in bad]
        return verify(slot, h)
    unlocked, problems = gated()
    if problems and not any(p.startswith("G5") for p in problems):
        so2 = resume("The driver re-measured your commit and found:\n" + "\n".join(f"- {p}" for p in problems[:30]) +
                     "\nFix each at its source and amend your one commit, or report blocked.")
        if so2 and so2["outcome"] == "committed":
            unlocked, problems = gated()
    if problems:
        event("refused", hold=h["key"], problems=problems[:20])
        return finish(h, "blocked:ruling", slot, "the driver's measurement refused the move:\n" + "\n".join(problems[:30]), slot_name)
    prior = None
    for rnd in (1, 2, 3):
        if over_budget():
            return finish(h, "budget", slot, "the day's allowance ran out mid-move; the commit is kept", slot_name)
        commit = git("rev-parse", "HEAD", cwd=slot)
        rv = review(task, slot, base, commit, prior)
        event("reviewed", hold=h["key"], round=rnd, verdict=(rv or {}).get("verdict"), fidelity=(rv or {}).get("fidelity"))
        if approved(rv):
            break
        so2 = resume("The fidelity review asks for changes. For each blocker or should: fix it at its source and amend "
                     "your one commit, or disagree with evidence (file:line, a command and its output). Nits: decline in "
                     "one line.\n\n" + json.dumps(rv, indent=1)) if rnd < 3 else None
        if not so2 or so2["outcome"] != "committed":
            return finish(h, "blocked:ruling", slot, "the review did not approve: " + json.dumps((rv or {}).get("findings", []))[:1500], slot_name)
        unlocked, problems = gated()
        if problems:
            return finish(h, "blocked:ruling", slot, "after the review's fixes the driver refused the move:\n" + "\n".join(problems[:30]), slot_name)
        prior = {"findings": (rv or {}).get("findings", []), "answers": so2}
    for attempt in (1, 2, 3):   # ship.sh rebases and checks
        try:
            with quiesced(slot):
                r = sh(["bash", "dev/ship.sh"], cwd=slot, timeout=3600, env=dict(os.environ, WT_CLIMB_DRIVER="1"))
        except subprocess.TimeoutExpired:
            return finish(h, "blocked:infra", slot, "dev/ship.sh passed its hour", slot_name)
        fetch()
        commits, _ = slot_state(slot)
        if r.returncode == 0 and not commits:
            break
        out = r.stdout + r.stderr
        failed = os.path.join(COMMON, "wt-ship-failed", slot_name)
        # the move's own fault (a test red, the ratchet failing, a rebase conflict) goes back to its climber once (G3);
        # a red on D14's time alone, or the tooling, is infrastructure, retried mechanically
        own = re.search(r"check: (src tests red|the ratchet fails)", out) and "D14" not in out
        if "D14" in out and not own:
            # approved and measured: a red on D14's time alone never costs the move (2026-11-08: approved moves were
            # parked after three such reds). Its commit waits on a ready branch for the lander; the slot climbs on.
            branch = f"ready/{h['id']}-{int(time.time())}"
            git("branch", "-f", branch, "HEAD", cwd=slot)
            update_json("ready.json", [], lambda q: q.append({"branch": branch, "hold": h["key"], "hold_id": h["id"],
                        "unlocked": len(unlocked), "fixfirst": bool(h.get("fixfirst")), "t": stamp()}))
            event("queued", hold=h["key"], branch=branch, why=out[-300:])
            unclaim(h)
            return "queued"
        if own and attempt < 3 and resumes < c["resumes_per_move"]:
            detail = "\n".join(sh(f"grep -hE 'Error During Test|Test Failed|LOCK BROKEN|✗|FieldError|MethodError' "
                                   f"{failed}/*.out 2>/dev/null | head -30").stdout.splitlines())
            so2 = resume("The landing check (G3) went red on your commit:\n" + out[-1200:] + "\n\nIts failures:\n" + detail +
                         "\n\nFix each at its source and amend your one commit, or report blocked.")
            if not so2 or so2["outcome"] != "committed":
                return finish(h, "blocked:ruling", slot, "the landing check went red on the move:\n" + out[-800:] + "\n" + detail[:1200], slot_name)
            unlocked, problems = gated()
            if problems:
                return finish(h, "blocked:ruling", slot, "after the check's fixes the driver refused the move:\n" + "\n".join(problems[:30]), slot_name)
            continue
        if attempt >= 2:
            return finish(h, "blocked:infra" if not own else "blocked:ruling", slot, "dev/ship.sh did not land: " + out[-1500:], slot_name)
    landed_move(h["key"], h["id"], git("rev-parse", "--short", "HEAD", cwd=slot), len(unlocked), slot_name, h.get("fixfirst"))
    advance(os.path.join(slot, ".wtd", "verify-cases.tsv"), git("rev-parse", "--short", "HEAD", cwd=slot))   # the next layer, now
    unclaim(h)
    return "landed"

def landed_move(key, hold_id, commit, unlocked, slot_name, fixfirst):
    event("landed", hold=key, hold_id=hold_id, commit=commit, unlocked=unlocked, slot=slot_name)
    draw_map(os.path.join(STATE, "map.html"))   # D29: after every landing
    if fixfirst:
        update_json("fixfirst.json", [], lambda ff: ff.__setitem__(slice(None), [f for f in ff if f["key"] != key]))
    update_json("handoffs.json", {}, lambda hs: hs.pop(hold_id, None))

def land_ready():
    """The lander: each approved commit that went red on D14's time alone is shipped again from its own worktree,
    the climb's other Julia stopped, oldest first, until it lands. ship.sh's own rule (one retry an hour on a D14
    red) is kept: a refusal waits. A conflict or a red of the move's own goes back to the climb with its branch."""
    q = state_json("ready.json", [])
    if not q:
        return
    item = q[0]
    slot = os.path.join(WORKTREES, "climb-land")
    if not os.path.isdir(slot):
        slot_ready("climb-land")
    fetch()
    git("checkout", "-q", "-f", "--no-track", "-B", "climb-land", item["branch"], cwd=slot)
    with quiesced(slot):
        r = sh(["bash", "dev/ship.sh"], cwd=slot, timeout=3600, env=dict(os.environ, WT_CLIMB_DRIVER="1"))
    fetch()
    out = r.stdout + r.stderr
    commits, _ = slot_state(slot)
    if r.returncode == 0 and not commits:
        landed_move(item["hold"], item["hold_id"], git("rev-parse", "--short", "HEAD", cwd=slot), item["unlocked"],
                    "climb-land", item.get("fixfirst"))
        git("branch", "-D", item["branch"], check=False)
    elif "D14" in out or "REFUSED" in out:
        event("land-wait", branch=item["branch"], why=out[-200:])
        return
    else:   # a conflict or a red of its own: back to the climb, its handoff naming the branch
        update_json("handoffs.json", {}, lambda hs: hs.__setitem__(item["hold_id"], (hs.get(item["hold_id"], "") +
                    f"\n\nAn approved commit for this hold is on the branch {item['branch']}; its landing failed: "
                    + out[-600:])[-2500:]))
        event("stopped", hold=item["hold"], outcome="blocked:ruling", note="the lander could not land it: " + out[-600:])
    update_json("ready.json", [], lambda qq: qq.__setitem__(slice(None), [x for x in qq if x["branch"] != item["branch"]]))

def audit_lag():
    heads = re.findall(r"^## .* audited through ([0-9a-f]{7,40})", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M)
    if not heads:
        return 0, None
    n = len(git("log", "--format=%h", f"{heads[-1]}..origin/{MARCH}", "--invert-grep", "--grep=^docs(audit)").splitlines())
    return n, heads[-1]

def audit_entry(so, rng, head):
    """The dev/AUDIT.md entry in L148's form, written by the driver from the auditor's fields, so its area labels,
    its commit and its Resolution are right by construction (audit 98's `Area: the builder` failed L148 twice)."""
    areas = "\n\n".join(f"Area: {label}. {so['areas'][k].strip()}" for k, label in AUDIT_AREAS)
    return (f"## {now().date().isoformat()} — audited through {head} ({rng}: {so['topics'].strip()})\n\n{areas}\n\n"
            f"stopgap in disguise: {so['stopgap'].strip()}\n\nprecedent: {so['precedent'].strip()}\n\n"
            f"Resolution: {so['resolution'].strip()}\n")

def audit():
    """D21: the landings since the last entry, read by one fresh auditor; its entry lands, its findings fix first.
    One audit at a time (a lock), in its own worktree."""
    c = cfg()
    fd = os.open(os.path.join(STATE, ".audit.lock"), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd); return
    try:
        slot, _ = slot_ready("climb-audit")
        log = git("log", "--format=%s", "-n", "600", cwd=slot).splitlines()
        nums = [int(m.group(1)) for l in log for m in [re.search(r"audit #(\d+)", l)] if m]
        n = (max(nums) + 1) if nums else 97
        _, prev = audit_lag()
        rng = f"{prev}..{git('rev-parse', '--short', 'HEAD', cwd=slot)}"
        saved = state_json("audit-saved.json", {})
        if saved.get("range", "").startswith(f"{prev}..") and "areas" in (saved.get("so") or {}):
            rng = saved["range"]   # a cut audit lands first, over its own range, under its own number (A98E7)
        commits = git("log", "--format=- %h %s", rng, "--invert-grep", "--grep=^docs(audit)", cwd=slot)
        if not commits:
            return
        saved = state_json("audit-saved.json", {})   # an audit whose landing was cut is landed again, not paid for twice
        so = saved.get("so") if saved.get("range") == rng and "areas" in (saved.get("so") or {}) else None
        if so is None:
            so, _ = run_agent("audit", f"audit{n}", claude_cmd(c["climber_model"], "high", SCHEMA_AUDIT, ["Bash", "Read", "Grep", "Glob"],
                              render("auditor.md", WORKTREE=slot, RANGE=rng, N=n, PREV=prev, COMMITS=commits), str(uuid.uuid4()), slot), slot, None)
            if so:
                save_json("audit-saved.json", {"range": rng, "so": so})
        if not so:
            event("audit-failed", n=n, range=rng); return
        if git("status", "--porcelain", cwd=slot):
            raise ClimbError("the auditor changed its worktree")
        with open(os.path.join(slot, "dev", "AUDIT.md"), "a") as f:
            f.write("\n" + audit_entry(so, rng, rng.split("..")[1]))
        git("add", "dev/AUDIT.md", cwd=slot)
        git("commit", "-q", "-m", f"docs(audit): audit #{n}: {rng}\n\nCharter: C0\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n", cwd=slot)
        with quiesced(slot):
            r = sh(["bash", "dev/ship.sh"], cwd=slot, timeout=3600, env=dict(os.environ, WT_CLIMB_DRIVER="1"))
        event("audited", n=n, range=rng, landed=r.returncode == 0, findings=len(so["findings"]))
        if r.returncode != 0:
            return   # kept in audit-saved.json: the next audit lands this one again
        save_json("audit-saved.json", {})
        lead = []
        def add(ff):
            for f in so["findings"]:
                if not (f.get("fix_first") or f.get("severity") in ("high", "medium")):
                    continue
                path = (f.get("file") or "").strip()
                text = f"{path}:{f.get('line')} {f.get('claim')} Fix: {f.get('fix')} ({f.get('requirement', '')})"
                if path not in RUNNER_FILES and any(re.search(p, path) for p in PROTECTED):
                    lead.append(f"- A{n} {f.get('id')}: {text}")   # the harness or the rules: no move can land it (G5)
                    continue
                ff.append({"key": f"audit A{n} {f.get('id')}: {f.get('claim', '')[:110]}", "cases": [], "why": text,
                           "keeper": path in RUNNER_FILES})
        update_json("fixfirst.json", [], add)
        if lead:
            for_dale(f"audit {n}: findings in protected files", "\n".join(lead) + "\nDefault taken: the climb goes on; "
                     "the lead lands these in its own commits (dev/climb, the rules and the tooling are no move's).")
        draw_map(os.path.join(STATE, "map.html"))   # D29: after every audit
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

# ---------------------------------------------------------------- the judge's own hill (Theo: an eval of past failures)
FINDING_RE = re.compile(r"\(A\d+[ES]\d+\)")

def judge_set(n):
    """The eval, fixed at its first run so every later run is comparable: the n latest landed fixes of an audit
    finding that change src/ and stay small. Each gives two cases: its revert, a defect an audit really found, which
    the reviewer must refuse (recall, the gate); and the fix itself, reported, never scored: a fix is no proof of a
    clean commit (on 2026-11-08 the reviewer refused 6 of 6 fixes, and two of its findings were audits 95 and 96's
    open A95S2 and A96S2 on those very fixes)."""
    saved = state_json("judge-set.json", [])
    if saved:
        return saved
    out = []
    for line in git("log", "-n", "2000", "--format=%H%x09%s", f"origin/{MARCH}").splitlines():
        sha, subj = line.split("\t", 1)
        if not subj.startswith("fix(") or not FINDING_RE.search(subj) or not git("diff", "--name-only", f"{sha}^", sha, "--", "src/"):
            continue
        changed = sum(int(a) + int(b) for a, b, *_ in (l.split("\t") for l in git("diff", "--numstat", f"{sha}^", sha).splitlines())
                      if a.isdigit() and b.isdigit())
        if changed <= 150:
            out.append({"sha": sha, "subject": subj})
        if len(out) >= n:
            break
    save_json("judge-set.json", out)
    return out

def clean_moves(n):
    """The climb's landed moves that a later audit read with no high or medium finding naming them: changes the
    reviewer should approve (A98E4: recall alone cannot tell a judge from one that refuses everything)."""
    faulted = set()
    for p in glob.glob(os.path.join(STATE, "runs", "audit*.audit.*.json")) + [os.path.join(STATE, "audit-saved.json")]:
        with contextlib.suppress(Exception):
            d = json.load(open(p)); so = d.get("structured_output") or d.get("so") or {}
            for f in so.get("findings", []):
                if f.get("severity") in ("high", "medium"):
                    faulted |= set(re.findall(r"\b[0-9a-f]{8}\b", json.dumps(f)))
    heads = re.findall(r"^## .* audited through ([0-9a-f]{7,40})", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M)
    out = []
    for e in reversed(events()):
        c = e.get("commit", "")
        if e["kind"] == "landed" and c and c[:8] not in faulted and heads and \
                sh(["git", "merge-base", "--is-ancestor", c, heads[-1]]).returncode == 0:
            out.append(c)
        if len(out) >= n:
            break
    return out

def isolated_case(before_tree, tree, stem):
    """A case in a repository of its own (A98E2): two commits, the tree before and the change, neutral messages, no
    other ref or history to search, and dev/AUDIT.md and dev/MARCH.md (whose rows name findings) blanked."""
    repo = os.path.join(STATE, "judge-repo")
    shutil.rmtree(repo, ignore_errors=True); os.makedirs(repo)
    ident = ["-c", "user.name=climb", "-c", "user.email=climb@localhost"]
    sh(["git", "init", "-q", repo], check=True)
    for t, msg in ((before_tree, "the tree before the change"), (tree, f"feat({stem}): the change under review")):
        for x in os.listdir(repo):
            if x != ".git":
                (shutil.rmtree if os.path.isdir(os.path.join(repo, x)) else os.remove)(os.path.join(repo, x))
        sh(f"git -C {REPO} archive {t} | tar -x -C {repo}", check=True)
        for blank in ("dev/AUDIT.md", "dev/MARCH.md"):
            if os.path.exists(os.path.join(repo, blank)):
                open(os.path.join(repo, blank), "w").write("(not part of this review)\n")
        git("add", "-A", cwd=repo); git(*ident, "commit", "-q", "--no-verify", "-m", msg, cwd=repo)
    return repo, git("rev-parse", "HEAD~1", cwd=repo)[:8], git("rev-parse", "HEAD", cwd=repo)

def judge_eval(n=6):
    """The blind reviewer (G4) is the climb's one judge that is a model, not a program. It is measured before it gates
    a move, and after any change to reviewer.md: its recall on real past defects (reverted audit fixes), which it must
    refuse, and its approval of the climb's landed moves a later audit passed, which it should approve."""
    def stem_of(a, b):
        return os.path.splitext(os.path.basename((git("diff", "--name-only", a, b, "--", "src/").splitlines() or ["src"])[0]))[0]
    defects, cleans = [], []
    for i, f in enumerate(judge_set(n)):
        sha = f["sha"]
        repo, base, head = isolated_case(git("rev-parse", f"{sha}^{{tree}}"), git("rev-parse", f"{sha}^^{{tree}}"), stem_of(f"{sha}^", sha))
        rv = review(f"judge{i}b", repo, base, head)
        defects.append({"sha": sha[:8], "subject": f["subject"][:120], "refused": bool(rv) and not approved(rv), "review": rv})
        event("judged", sha=sha[:8], case="defect", refused=defects[-1]["refused"])
    for i, c in enumerate(clean_moves(n)):
        repo, base, head = isolated_case(git("rev-parse", f"{c}^^{{tree}}"), git("rev-parse", f"{c}^{{tree}}"), stem_of(f"{c}^", c))
        rv = review(f"judge{i}c", repo, base, head)
        cleans.append({"sha": c[:8], "approved": approved(rv), "review": rv})
        event("judged", sha=c[:8], case="clean", approved=cleans[-1]["approved"])
    if not defects:
        return
    rec = sum(r["refused"] for r in defects) / len(defects)
    app = sum(r["approved"] for r in cleans) / len(cleans) if cleans else None
    save_json("judge-eval.json", {"t": stamp(), "recall": rec, "approval": app, "defects": defects, "cleans": cleans})
    event("judge-eval", recall=rec, approval=app, n=len(defects), clean=len(cleans))
    if rec < 0.8:   # intent: the reviewer refuses what audits found; band: 80% of the set, under it no move lands
        open(os.path.join(STATE, "PAUSE"), "w").write("the judge refused under 80% of past defects\n")
        for_dale("the judge misses past defects", f"The blind reviewer refused {rec:.0%} of {len(defects)} real past defects "
                 f"({os.path.join(STATE, 'judge-eval.json')}). Default taken: moves hold (PAUSE) until the lead tightens "
                 "dev/climb/reviewer.md against the misses and `climb.py judge-eval` measures it again (A97E5).")
    if app is not None and app < 0.5:   # intent: the reviewer passes sound work; band: half the clean moves, a note
        for_dale("the judge refuses sound moves", f"The blind reviewer approved {app:.0%} of {len(cleans)} landed moves a later "
                 "audit passed. Default taken: the climb runs; the lead reads its refusals and narrows reviewer.md.")
    print(f"judge: refused {rec:.0%} of past defects; approved " + (f"{app:.0%} of {len(cleans)} clean moves" if cleans else "no clean move yet"))

# ---------------------------------------------------------------- the loops
def scoreboard_once(head):
    board = os.path.join(STATE, "board")
    if not os.path.isdir(board):
        git("worktree", "add", "-q", "--detach", board, head)
    git("checkout", "-q", "--detach", head, cwd=board)
    if os.path.exists(os.path.join(ROOT, "Manifest.toml")):   # as dev/corpus.sh: the tree's resolved manifest
        shutil.copy(os.path.join(ROOT, "Manifest.toml"), os.path.join(board, "Manifest.toml"))
    out = os.path.join(STATE, f"cases-{head[:8]}.tsv")
    env = dict(os.environ, JULIA_NUM_THREADS="1", WT_SMOKE_CASES=out)
    env["JULIA_DEPOT_PATH"] = sh(["bash", os.path.join(ROOT, "dev", "depot.sh"), "path", board]).stdout.strip()
    t0 = time.time()
    with julia_slot("score"):
        r = sh(["taskpolicy", "-b", "julia", "--project=.", "--startup-file=no", "test/smoke.jl"], cwd=board,
               env=env, timeout=cfg()["smoke_wall_s"])
    if not os.path.exists(out):
        event("score-failed", sha=head[:8], secs=round(time.time() - t0), tail=(r.stdout + r.stderr)[-300:]); return
    s, lost, bad = record(out, head[:8])
    with julia_slot("score"):   # the src tail's definitions at this head (dev/src_progress.sh kinds, D40)
        k = sh(["bash", "dev/src_progress.sh", "kinds"], cwd=board, env=env, timeout=1800)
    if k.returncode == 0 and k.stdout.strip():
        open(os.path.join(STATE, "head-kinds.tsv"), "w").write(k.stdout)
    else:
        event("kinds-failed", sha=head[:8], tail=(k.stdout + k.stderr)[-300:])
    draw_map(os.path.join(STATE, "map.html"))
    print(f"scored {head[:8]}: S={s['passed']}/{s['climbable']} lost={len(lost)} bad={len(bad)} ({round(time.time() - t0)} s)", flush=True)

def unlogged_landings():
    """Commits on origin/wt2 since launch that dev/ship.sh's landing log does not name: a push around the driver."""
    p = os.path.join(STATE, "launch-base")
    if not os.path.exists(p):
        open(p, "w").write(git("rev-parse", f"origin/{MARCH}"))
    logged = [l.split("\t")[1] for l in open(os.path.join(COMMON, "wt-landings.tsv")) if l.count("\t") >= 2] \
        if os.path.exists(os.path.join(COMMON, "wt-landings.tsv")) else []
    return [c for c in git("rev-list", f"{open(p).read().strip()}..origin/{MARCH}").splitlines()
            if not any(c.startswith(h) for h in logged if len(h) >= 7)]

def score_tick():
    """One look at origin/wt2, a process of its own (launch.sh loops it), so every tick runs the current code: the
    rogue-push alarm, and a score when enough has landed or enough time has passed since the last."""
    sc = [e for e in events() if e["kind"] == "scored"]
    last = git("rev-parse", "--verify", "-q", sc[-1]["sha"], check=False) if sc else None
    last_t = datetime.datetime.fromisoformat(sc[-1]["t"]).timestamp() if sc else 0.0
    fetch()
    rogue = unlogged_landings()
    if rogue and not os.path.exists(os.path.join(STATE, "PAUSE")):
        open(os.path.join(STATE, "PAUSE"), "w").write("origin/wt2 advanced by a push no landing names\n")
        for_dale("the climb paused itself: a push around the driver", "These commits reached origin/wt2 with no "
                 f"dev/ship.sh landing: {', '.join(c[:8] for c in rogue)}. Default taken: paused until the lead "
                 "reads them and runs `bash dev/climb/launch.sh resume`.")
        event("rogue-push", commits=[c[:8] for c in rogue])
    head = git("rev-parse", f"origin/{MARCH}")
    n = len(git("rev-list", f"{last}..{head}").splitlines()) if last else 10 ** 6
    if head != last and (n >= cfg()["score_every_landings"] or time.time() - last_t >= cfg()["score_every_s"]):
        scoreboard_once(head)

def pick(slot=None):
    if not head_cases():   # no move before the first scored head: the holds and the sentinel net come from it
        return
    ev = events()
    sc = [e for e in ev if e["kind"] == "scored"]
    head = sc[-1]["sha"] if sc else None
    # a hold landed in no commit the scored head contains waits for a score that does, so no slot climbs it twice
    # (by ancestry, not by time: a score runs for an hour, and a landing during it is not in what it scored)
    adv = [e["sha"] for e in ev if e["kind"] == "advanced"]
    done = {e.get("hold_id") for e in ev if e["kind"] == "landed" and e.get("commit") not in adv
            and not (head and sh(["git", "merge-base", "--is-ancestor", e.get("commit", ""), head]).returncode == 0)}
    done |= {x["hold_id"] for x in state_json("ready.json", [])}   # its approved commit waits for the lander
    hs = holds()
    if slot == "climb-1":   # D40: one slot always ports compiler src, the hold that unlocks most cases first
        corpus = sorted((h for h in hs if not h["key"].startswith("G") and not h.get("fixfirst") and not h.get("tail")
                         and not h.get("keeper")), key=lambda h: -h["n"])
        hs = corpus + [h for h in hs if h not in corpus]
    for h in hs:
        if h["parked"] or h["id"] in done or h["n"] == 0 and not h.get("fixfirst"):
            continue
        yield h

def slot_once(name):
    """One iteration of a slot, a process of its own (launch.sh loops it), so every move runs the current code and
    no change to the climb ever waits for a restart (2026-11-09: a restart that waited for the moves in flight held
    slot 2 idle for two hours). Exit 0 after a move or an audit, 3 when there is nothing to do yet."""
    reap_claims()
    if os.path.exists(os.path.join(COMMON, "wt-line-stop")) or os.path.exists(os.path.join(STATE, "PAUSE")):
        return 3
    if week_half():
        return 3
    if over_budget():
        event("budget-wait", slot=name); return 3
    if name == "climb-1" and audit_lag()[0] >= cfg()["audit_every"]:
        audit(); return 0
    h = next((h for h in pick(name) if claim(h, name)), None)
    if not h:
        return 3
    try:
        move(h, name)
    except BaseException as e:   # every fault is an event and frees its hold
        event("driver-error", slot=name, hold=h.get("key"), error=repr(e)[:400])
        unclaim(h)
        raise
    return 0

def lanes():
    p = os.path.join(COMMON, "wt-orders", "LANES")
    if not os.path.exists(p):
        return []
    out = []
    for line in open(p):
        f = line.split()
        if len(f) >= 2 and not f[0].startswith("#") and f[0] != "lead" and os.path.isdir(os.path.join(WORKTREES, f[1])):
            out.append((f[0], os.path.join(WORKTREES, f[1])))
    return out

def preflight(kill=False):
    ok = True
    ps = "\n".join(l for l in sh("pgrep -fl 'dev/autoship.sh|dev/ship.sh|dev/corpus.sh' || true").stdout.splitlines()
                   if l.strip() and "pgrep" not in l and int(l.split()[0]) not in (os.getpid(), os.getppid()))
    if ps:
        print("stale loops still running:\n  " + ps.replace("\n", "\n  "))
        if kill:
            for line in ps.splitlines():
                try:
                    os.kill(int(line.split()[0]), signal.SIGTERM)
                except ProcessLookupError:
                    pass
            print("  … sent SIGTERM")
        else:
            ok = False; print("  run `climb.py preflight --kill` to stop them")
    for agent, p in lanes():
        dirty = len(git("status", "--porcelain", cwd=p).splitlines())
        unl = sum(1 for l in git("cherry", f"origin/{MARCH}", "HEAD", cwd=p, check=False).splitlines() if l.startswith("+"))
        if dirty or unl:
            print(f"paused lane {agent} ({os.path.basename(p)}): {dirty} dirty file(s), {unl} unlanded commit(s) → a harvest hold")
    held = os.path.join(COMMON, "wt-held")
    if os.path.exists(held) and open(held).read().strip():
        print("wt-held: " + open(held).read().strip().replace("\n", ", "))
    if os.path.exists(os.path.join(COMMON, "wt-line-stop")):
        ok = False; print("wt-line-stop is set: " + open(os.path.join(COMMON, "wt-line-stop")).read().strip())
    if not shutil.which("claude"):
        ok = False; print("claude: not on PATH")
    mc = sh(["bash", "dev/manifest_check.sh", ROOT])   # the scoreboard copies this tree's Manifest (as dev/lane.sh makes one)
    if mc.returncode != 0:
        ok = False; print("Manifest.toml: this tree's is not resolved for its Project.toml (" + (mc.stdout + mc.stderr).strip()[:200]
                          + "); do what dev/lane.sh start does: copy the main tree's, then Pkg.resolve()")
    try:   # D39: climbers develop in Kaimon sessions; without the server every probe pays a fresh process
        import urllib.request
        urllib.request.urlopen(cfg()["kaimon_url"].rsplit("/", 1)[0], timeout=3)
        print("kaimon: reachable")
    except Exception as e:
        if "HTTP Error" in repr(e):
            print("kaimon: reachable")
        else:
            ok = False; print(f"kaimon: not reachable at {cfg()['kaimon_url']} ({type(e).__name__}); start the Kaimon server first (D39)")
    print("scored head: " + ("yes" if head_cases() else "none yet (the scoreboard's first run scores one)"))
    print(f"budget: the account today {account_spend(1)/1e6:.0f}M of {allowance()/1e6:.0f}M weighted per day")
    return ok

def harvest():
    """The paused lanes' unfinished work, each a fix-first hold once (tstack takeover)."""
    done = state_json("harvested.json", {})
    def add(ff):
        for agent, p in lanes():
            dirty = git("status", "--short", cwd=p)
            unl = git("cherry", "-v", f"origin/{MARCH}", "HEAD", cwd=p, check=False)
            if not dirty and "+" not in unl:
                continue
            sig = hashlib.sha1((git("rev-parse", "HEAD", cwd=p) + dirty).encode()).hexdigest()
            if done.get(agent) == sig:
                continue
            done[agent] = sig
            key = f"harvest {agent} ({os.path.basename(p)})"
            ff[:] = [f for f in ff if f["key"] != key]
            orders = os.path.join(COMMON, "wt-orders", agent)
            o = open(orders).read()[-3000:] if os.path.exists(orders) else ""
            ff.append({"key": f"harvest {agent} ({os.path.basename(p)})", "cases": [], "why":
                       f"Take over the paused lane {agent}'s work (tstack takeover: finish its goal, never defend its code "
                       f"because it exists). Its worktree {p} is left as it was: read it, never edit it "
                       f"(`git -C {p} diff`, `git -C {p} status --short`, `git -C {p} log -p origin/{MARCH}..HEAD`). "
                       f"Its unlanded commits: {unl[:600]}; its uncommitted files: {dirty[:600]}. Its standing orders, "
                       f"last part:\n{o}\nRe-apply what is right onto your own branch as one commit, re-proven, or report "
                       f"what makes it wrong. Give the original lane credit in your commit body."})
    update_json("fixfirst.json", [], add)
    save_json("harvested.json", done)
    print(f"{len(state_json('fixfirst.json', []))} fix-first hold(s) queued")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("report"); h = sp.add_parser("holds"); h.add_argument("-n", type=int, default=20); h.add_argument("--json", action="store_true")
    r = sp.add_parser("record"); r.add_argument("tsv"); r.add_argument("sha")
    g = sp.add_parser("regress"); g.add_argument("tsv")
    sp.add_parser("budget"); m = sp.add_parser("map"); m.add_argument("out", nargs="?", default=os.path.join(STATE, "map.html"))
    p = sp.add_parser("preflight"); p.add_argument("--kill", action="store_true")
    sp.add_parser("harvest"); sp.add_parser("audit")
    j = sp.add_parser("judge-eval"); j.add_argument("-n", type=int, default=6)
    sp.add_parser("once"); so = sp.add_parser("slot"); so.add_argument("name")
    sp.add_parser("lander"); sp.add_parser("score-tick"); sp.add_parser("nslots")
    a = ap.parse_args()
    if a.cmd in ("audit", "once", "judge-eval"):
        os.setpgrp()   # its own process group: `launch.sh stop` stops the claude and julia children with it
    if a.cmd == "report": print(report())
    elif a.cmd == "holds":
        hs = holds()[:a.n]
        print(json.dumps(hs, indent=1) if a.json else "\n".join(f"{h['n']:4d}  {h['id']}  {h['key']}" for h in hs))
    elif a.cmd == "record":
        s, lost, bad = record(a.tsv, a.sha); print(json.dumps(s), f"lost={len(lost)} bad={len(bad)}")
    elif a.cmd == "regress":
        lost, bad = regress(read_cases(a.tsv))
        for l in lost: print("G2 lost", l)
        for l in bad: print("G1", l)
        sys.exit(1 if lost or bad else 0)
    elif a.cmd == "budget":
        cw, cu = climb_spend(now() - datetime.timedelta(days=7))
        print(f"the account: today {account_spend(1)/1e6:.1f}M of {allowance()/1e6:.0f}M weighted; 7 days {account_spend(7)/1e6:.0f}M; "
              f"the climb's 7 days {cw/1e6:.1f}M (${cu:.2f}" + (f", ${cu / max(cw / 1e6, 1e-9):.3f} per M weighted)" if cw else ")"))
        sys.exit(1 if over_budget() else 0)
    elif a.cmd == "map": print(draw_map(a.out))
    elif a.cmd == "preflight": sys.exit(0 if preflight(a.kill) else 1)
    elif a.cmd == "harvest": harvest()
    elif a.cmd == "audit": audit()
    elif a.cmd == "judge-eval": judge_eval(a.n)
    elif a.cmd == "once": sys.exit(slot_once("climb-1"))
    elif a.cmd == "slot": sys.exit(slot_once(a.name))
    elif a.cmd == "lander": land_ready()
    elif a.cmd == "score-tick": score_tick()
    elif a.cmd == "nslots": print(cfg()["slots"])

if __name__ == "__main__":
    main()
