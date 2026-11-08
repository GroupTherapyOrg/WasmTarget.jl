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
    python3 dev/climb/climb.py scoreboard          loop: new heads of origin/wt2 scored with the full smoke
    python3 dev/climb/climb.py run [--slots N]     loop: the climb itself, with an audit whenever the lag reaches its band
    python3 dev/climb/climb.py once                one move in one slot, then exit (a dry rehearsal at launch)
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
    # the march account's transcripts: run the climb under that account's own CLAUDE_CONFIG_DIR, so the governor counts
    # its sessions alone (another account's sessions in the same directory would be counted against it)
    "claude_home": os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
    "task_cap_usd": 25.0,                        # --max-budget-usd of a fresh run (calibrate on day 1: `budget`)
    "resume_cap_usd": 8.0,                       # a resume re-creates its cache cold, so it gets its own small cap
    "resumes_per_move": 2,
    "stops_per_hold": 3,                         # then the hold is parked for Dale, never retried for ever
    "task_wall_s": 5400,                         # no run outlives this (2026-10-28: hangs are never allowed)
    "audit_every": 5,                            # D21: every change read within 5 commits
    "score_every_landings": 3,                   # the scoreboard scores a head after this many landings, or …
    "score_every_s": 7200,                       # … this long since the last score, whichever first
    "smoke_wall_s": 10800,
    "kaimon_url": "http://localhost:2828/mcp",   # D39: every climber develops in a live Kaimon session (MCP)
}
BUDGET_KEYS = ("week_weighted", "margin")   # D14: a budget changes by a commit naming Dale's words, never by config

def cfg():
    c = dict(DEFAULTS)
    p = os.path.join(STATE, "config.json")
    if os.path.exists(p):
        c.update({k: v for k, v in json.load(open(p)).items() if k not in BUDGET_KEYS})
    return c

# G5: the judge and the rules. A move touching one is refused before review; ADD_ONLY files may only gain lines,
# and NEW_ONLY directories only gain files (a model's invariant is never loosened in a port move: refusal 9).
PROTECTED = [r"^dev/(?!formal/)", r"^dev/formal/run_tlc\.sh$", r"^test/smoke\.jl$", r"^test/runner\.jl$",
             r"^test/parity_ratchet\.jl$", r"^AGENTS\.md$", r"^\.github/", r"^\.gitignore$", r"^Project\.toml$",
             r"^Manifest\.toml$", r"^legacy/"]   # all of dev/: the tooling, the plan and the audit log are the driver's or a ruling's
ADD_ONLY = [r"^test/smoke_corpus\.jl$", r"^test/smoke_times\.tsv$"]
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

def hold_key(outcome, label, why):
    """One rejection site and reason: the cases one fix can unlock (HILL.md, 'holds')."""
    if outcome == "wrong":
        return "G1 wrong: " + label
    if outcome == "unported":
        m = UNPORTED_RE.search(why)
        if m:
            return _norm(("unported " if m.group(1) == "dart" else "unquarantined ") + unported_site(why))[:200]
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
    groups = collections.OrderedDict()
    for label, outcome, secs, why in cases:
        if outcome in ("passed", "outside"):
            continue
        k = hold_key(outcome, label, why)
        g = groups.setdefault(k, {"key": k, "cases": [], "secs": 0.0, "why": why[:400]})
        g["cases"].append(label); g["secs"] += secs
    out = list(groups.values())
    for f in state_json("fixfirst.json", []):          # audit findings, G2 losses and harvests: fix first (D21)
        out.append({"key": f["key"], "cases": f.get("cases", []), "secs": 0.0, "why": f["why"], "fixfirst": True,
                    "require_pass": f.get("require_pass", False)})
    out += src_tail()
    for h in out:
        h["n"] = len(h["cases"]) or len(h.get("defs", []))
        h["id"] = hashlib.sha1(h["key"].encode()).hexdigest()[:10]
        h["parked"] = parked.get(h["id"])
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
    lines.append(f"budget: the account today {account_spend(1)/1e6:.0f}M of {allowance()/1e6:.0f}M weighted, 7 days "
                 f"{account_spend(7)/1e6:.0f}M of {cfg()['week_weighted']*cfg()['margin']/1e6:.0f}M; the climb's own 24 h {cw/1e6:.0f}M (${cu:.0f})")
    hs = holds(cases)
    lines.append(f"holds: {len(hs)} ({sum(1 for h in hs if h['parked'])} parked); the largest:")
    for h in hs[:k]:
        tag = " [parked]" if h["parked"] else " [claimed]" if os.path.exists(os.path.join(STATE, "claims", h["id"])) else ""
        lines.append(f"  {h['n']:4d}  {h['key'][:110]}{tag}")
    je = state_json("judge-eval.json", None)
    lines.append(f"judge: refused {je['recall']:.0%} of past defects ({je['t'][:10]}; approved {je['approval']:.0%} of their fixes, reported only)"
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
SCHEMA_AUDIT = {"type": "object", "required": ["entry", "findings"], "properties": {"entry": {"type": "string"},
    "findings": {"type": "array", "items": {"type": "object", "required": ["id", "severity", "claim"], "properties": dict(
        _FINDING["properties"], severity={"type": "string", "enum": ["high", "medium", "low"]},
        requirement={"type": "string"}, fix_first={"type": "boolean"})}}}}
SCHEMA_RULING = {"type": "object", "required": ["ruling", "requeue", "escalate"], "properties": {"ruling": {"type": "string"},
    "requeue": {"type": "boolean"}, "escalate": {"type": "boolean"}, "for_dale": {"type": "string"}, "ledger_row": {"type": "string"}}}

# the briefs, each a template the driver fills (their full paths, so the ratchet's L130 sees them consumed)
TEMPLATES = {"climber.md": "dev/climb/climber.md", "reviewer.md": "dev/climb/reviewer.md",
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
    if over_budget():   # every run, not only a move's first: a move never overshoots the day by its later steps
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

DEF_RE = re.compile(r"^(?:function\s+)?([A-Za-z_]\w*)\s*\(.*?\)\s*(?:=|$)", re.M)

def g5(slot):
    """The judge untouched (HILL.md G5)."""
    names = git("diff", "--name-only", f"origin/{MARCH}...HEAD", cwd=slot).splitlines()
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
                base_defs = set(DEF_RE.findall(git("show", f"origin/{MARCH}:{n}", cwd=slot)))
                for l in added_lines(slot, n):
                    if re.search(r"\b(GROUPS|XFAIL)\b", l):
                        bad.append(f"{n} (an added line names GROUPS or XFAIL: {l.strip()[:80]})")
                    m = DEF_RE.match(l)
                    if m and m.group(1) in base_defs and m.group(1) not in ("_g", "_xf", "_lazy_g", "_lazy_xf"):
                        bad.append(f"{n} (an added line redefines {m.group(1)}, which the corpus already defines)")
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
    if h.get("tail") and not git("diff", "--name-only", f"origin/{MARCH}...HEAD", "--", "src/", cwd=slot):
        problems.append("a src-tail move that changes nothing under src/")
    if h.get("require_pass"):
        problems += [f"G2 still not passing: {l}" for l in sorted(hc - set(unlocked))]
    elif hc and not moved:
        problems.append("no case of the hold passes or reaches a deeper unported site the move did not write")
    return unlocked, problems

# ---------------------------------------------------------------- slots and moves
def slot_ready(name):
    """A climber's worktree at origin/wt2. Earlier work is kept on a salvage branch, never reset away; the
    branch's name is returned so the next climber starts from it."""
    path = os.path.join(WORKTREES, name)
    fetch()
    if not os.path.isdir(path):
        r = sh(["bash", "dev/lane.sh", "start", name])
        if r.returncode != 0:
            raise ClimbError(f"dev/lane.sh start {name}: {(r.stdout + r.stderr)[-300:]}")
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
    git("checkout", "-q", "-B", name, f"origin/{MARCH}", cwd=path)
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
    event("ruled", hold=h["key"], requeue=so["requeue"], ruling=so["ruling"][:300])
    if not so["requeue"]:
        park(h, so["ruling"], tell=False)

def finish(h, outcome, slot, note, salvage_hint=None):
    """A move that did not land: its handoff kept (with where its work is), and the hold ruled, retried or parked."""
    event("stopped", hold=h["key"], outcome=outcome, note=note[:600])
    hand = note[-2500:] + (f"\n\nThe last climber's commit stays on this slot's branch; the next move keeps it on a salvage "
                           f"branch (named in your brief): start from it if it is right." if salvage_hint else "")
    update_json("handoffs.json", {}, lambda hs: hs.__setitem__(h["id"], hand))
    stops = sum(1 for e in events() if e["kind"] == "stopped" and e.get("hold") == h["key"])
    if stops >= cfg()["stops_per_hold"]:
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
    brief = render("climber.md", WORKTREE=slot, BRANCH=slot_name, BASE=base,
                   HOLD=f"**{h['key']}**\n\nWhy (the first case's rejection): {h['why']}",
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
        bad = g5(slot)
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
    for rnd in (1, 2):
        if over_budget():
            return finish(h, "budget", slot, "the day's allowance ran out mid-move; the commit is kept", slot_name)
        commit = git("rev-parse", "HEAD", cwd=slot)
        rv = review(task, slot, base, commit, prior)
        event("reviewed", hold=h["key"], round=rnd, verdict=(rv or {}).get("verdict"), fidelity=(rv or {}).get("fidelity"))
        if approved(rv):
            break
        so2 = resume("The fidelity review asks for changes. For each blocker or should: fix it at its source and amend "
                     "your one commit, or disagree with evidence (file:line, a command and its output). Nits: decline in "
                     "one line.\n\n" + json.dumps(rv, indent=1)) if rnd == 1 else None
        if not so2 or so2["outcome"] != "committed":
            return finish(h, "blocked:ruling", slot, "the review did not approve: " + json.dumps((rv or {}).get("findings", []))[:1500], slot_name)
        unlocked, problems = gated()
        if problems:
            return finish(h, "blocked:ruling", slot, "after the review's fixes the driver refused the move:\n" + "\n".join(problems[:30]), slot_name)
        prior = {"findings": (rv or {}).get("findings", []), "answers": so2}
    for attempt in (1, 2):   # ship.sh rebases and checks; a red is infrastructure first, retried once mechanically
        try:
            r = sh(["bash", "dev/ship.sh"], cwd=slot, timeout=3600, env=dict(os.environ, WT_CLIMB_DRIVER="1"))
        except subprocess.TimeoutExpired:
            return finish(h, "blocked:infra", slot, "dev/ship.sh passed its hour", slot_name)
        fetch()
        commits, _ = slot_state(slot)
        if r.returncode == 0 and not commits:
            break
        if attempt == 2:
            return finish(h, "blocked:infra", slot, "dev/ship.sh did not land: " + (r.stdout + r.stderr)[-1500:], slot_name)
    landed = git("rev-parse", "--short", "HEAD", cwd=slot)
    event("landed", hold=h["key"], hold_id=h["id"], commit=landed, unlocked=len(unlocked), slot=slot_name)
    draw_map(os.path.join(STATE, "map.html"))   # D29: after every landing
    if h.get("fixfirst"):
        update_json("fixfirst.json", [], lambda ff: ff.__setitem__(slice(None), [f for f in ff if f["key"] != h["key"]]))
    update_json("handoffs.json", {}, lambda hs: hs.pop(h["id"], None))
    unclaim(h)
    return "landed"

def audit_lag():
    heads = re.findall(r"^## .* audited through ([0-9a-f]{7,40})", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M)
    if not heads:
        return 0, None
    n = len(git("log", "--format=%h", f"{heads[-1]}..origin/{MARCH}", "--invert-grep", "--grep=^docs(audit)").splitlines())
    return n, heads[-1]

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
        commits = git("log", "--format=- %h %s", rng, "--invert-grep", "--grep=^docs(audit)", cwd=slot)
        if not commits:
            return
        so, _ = run_agent("audit", f"audit{n}", claude_cmd(c["climber_model"], "high", SCHEMA_AUDIT, ["Bash", "Read", "Grep", "Glob"],
                          render("auditor.md", WORKTREE=slot, RANGE=rng, N=n, PREV=prev, COMMITS=commits), str(uuid.uuid4()), slot), slot, None)
        if not so:
            event("audit-failed", n=n, range=rng); return
        if git("status", "--porcelain", cwd=slot):
            raise ClimbError("the auditor changed its worktree")
        with open(os.path.join(slot, "dev", "AUDIT.md"), "a") as f:
            f.write("\n" + so["entry"].strip() + "\n")
        git("add", "dev/AUDIT.md", cwd=slot)
        git("commit", "-q", "-m", f"docs(audit): audit #{n}: {rng}\n\nCharter: C0\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n", cwd=slot)
        r = sh(["bash", "dev/ship.sh"], cwd=slot, timeout=3600, env=dict(os.environ, WT_CLIMB_DRIVER="1"))
        event("audited", n=n, range=rng, landed=r.returncode == 0, findings=len(so["findings"]))
        def add(ff):
            for f in so["findings"]:
                if f.get("fix_first") or f.get("severity") in ("high", "medium"):
                    ff.append({"key": f"audit A{n} {f.get('id')}: {f.get('claim', '')[:110]}", "cases": [],
                               "why": f"{f.get('file')}:{f.get('line')} {f.get('claim')} Fix: {f.get('fix')} ({f.get('requirement', '')})"})
        update_json("fixfirst.json", [], add)
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

def judge_eval(n=6):
    """The blind reviewer (G4) is the climb's one judge that is a model, not a program. Its recall on real past
    defects and its approval of their fixes are measured before it gates a move, and after any change to reviewer.md."""
    slot, _ = slot_ready("climb-judge")
    results = []
    try:
        for i, f in enumerate(judge_set(n)):
            sha = f["sha"]
            stem = os.path.splitext(os.path.basename(git("diff", "--name-only", f"{sha}^", sha, "--", "src/").splitlines()[0]))[0]
            git("checkout", "-q", "-B", "climb-judge", sha, cwd=slot)
            git("revert", "--no-commit", sha, cwd=slot)
            git("-c", "user.name=climb", "-c", "user.email=climb@localhost", "commit", "-q", "--no-verify", "-m",
                f"feat({stem}): the change under review", cwd=slot)
            bad = git("rev-parse", "HEAD", cwd=slot)
            rv_bad = review(f"judge{i}b", slot, sha[:8], bad)
            git("checkout", "-q", "-B", "climb-judge", sha, cwd=slot)
            rv_good = review(f"judge{i}g", slot, git("rev-parse", "--short", f"{sha}^", cwd=slot), sha)
            results.append({"sha": sha[:8], "subject": f["subject"][:120],
                            "defect_refused": bool(rv_bad) and not approved(rv_bad), "fix_approved": approved(rv_good),
                            "bad": rv_bad, "good": rv_good})
            event("judged", sha=sha[:8], refused=results[-1]["defect_refused"], approved=results[-1]["fix_approved"])
    finally:
        git("checkout", "-q", "-B", "climb-judge", f"origin/{MARCH}", cwd=slot)   # the eval's commits are synthetic
    if not results:
        return
    rec = sum(r["defect_refused"] for r in results) / len(results)
    spec = sum(r["fix_approved"] for r in results) / len(results)
    save_json("judge-eval.json", {"t": stamp(), "recall": rec, "approval": spec, "results": results})
    event("judge-eval", recall=rec, approval=spec, n=len(results))
    if rec < 0.8:   # intent: the reviewer refuses what audits found; band: 80% of the set, its edge a note for Dale
        for_dale("the judge misses past defects", f"The blind reviewer refused {rec:.0%} of {len(results)} real past defects "
                 f"({os.path.join(STATE, 'judge-eval.json')}). Default taken: the climb runs, and the lead tightens "
                 "dev/climb/reviewer.md against the misses, then re-runs `climb.py judge-eval`.")
    print(f"judge: refused {rec:.0%} of past defects; approved {spec:.0%} of their fixes, reported only ({len(results)} pairs)")

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

def scoreboard():
    last, last_t = None, 0.0
    while True:
        try:
            fetch()
            head = git("rev-parse", f"origin/{MARCH}")
            n = len(git("rev-list", f"{last}..{head}").splitlines()) if last else 10 ** 6
            if head != last and (n >= cfg()["score_every_landings"] or time.time() - last_t >= cfg()["score_every_s"]):
                scoreboard_once(head)
                last, last_t = head, time.time()
        except Exception as e:   # the scoreboard never dies of one bad iteration
            event("score-failed", error=repr(e)[:300])
        time.sleep(120)

def pick():
    if not head_cases():   # no move before the first scored head: the holds and the sentinel net come from it
        return
    ev = events()
    scored = max((e["t"] for e in ev if e["kind"] == "scored"), default="")
    # a hold landed since the last scored head waits for the next score, so no slot climbs it twice
    done = {e.get("hold_id") for e in ev if e["kind"] == "landed" and e["t"] > scored}
    for h in holds():
        if h["parked"] or h["id"] in done or h["n"] == 0 and not h.get("fixfirst"):
            continue
        yield h

def run(slots, one=False):
    stop = threading.Event()
    reap_claims()
    def worker(i):
        name = f"climb-{i}"
        while not stop.is_set():
            h = None
            try:
                if os.path.exists(os.path.join(COMMON, "wt-line-stop")) or os.path.exists(os.path.join(STATE, "PAUSE")):
                    time.sleep(60); continue
                if over_budget():
                    event("budget-wait", slot=name); time.sleep(900); continue
                if i == 1 and audit_lag()[0] >= cfg()["audit_every"]:
                    audit()
                h = next((h for h in pick() if claim(h, name)), None)
                if not h:
                    time.sleep(300); continue
                move(h, name)
            except BaseException as e:   # every fault is an event and frees its hold; Ctrl-C still stops
                event("driver-error", slot=name, hold=(h or {}).get("key"), error=repr(e)[:400])
                if h:
                    unclaim(h)
                if isinstance(e, KeyboardInterrupt):
                    stop.set()
                time.sleep(30)
            if one:
                stop.set()
    ts = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(1, slots + 1)]
    for t in ts:
        t.start()
    try:
        while any(t.is_alive() for t in ts):
            time.sleep(5)
    except KeyboardInterrupt:
        stop.set(); print("climb: stopping after the moves in flight")

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
    sp.add_parser("harvest"); sp.add_parser("scoreboard"); sp.add_parser("audit")
    j = sp.add_parser("judge-eval"); j.add_argument("-n", type=int, default=6)
    rn = sp.add_parser("run"); rn.add_argument("--slots", type=int, default=None)
    sp.add_parser("once")
    a = ap.parse_args()
    if a.cmd in ("scoreboard", "run", "audit", "once", "judge-eval"):
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
    elif a.cmd == "scoreboard": scoreboard()
    elif a.cmd == "audit": audit()
    elif a.cmd == "judge-eval": judge_eval(a.n)
    elif a.cmd == "run": run(a.slots or cfg()["slots"])
    elif a.cmd == "once": run(1, one=True)

if __name__ == "__main__":
    main()
