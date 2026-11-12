#!/usr/bin/env python3
"""dev/climb/core.py — what every part of the climb's driver shares (dev/climb/HILL.md): its state (one lock, atomic
writes, the events), the score and the holds, the budget, the report and the map, the agents and the judge's state."""
import argparse, base64, collections, contextlib, datetime, fcntl, glob, hashlib, html, json, os, re, shutil, signal, \
    subprocess, sys, threading, time, urllib.error, urllib.request, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import door   # dev/climb/door.py: the one way to the build users

# the driver reads git as git stores it: no replace refs, no system attributes, no textconv or external diff (DIFF),
# no hook or fsmonitor of a slot's config run by the driver (git())
os.environ["GIT_NO_REPLACE_OBJECTS"] = "1"; os.environ["GIT_ATTR_NOSYSTEM"] = "1"
DIFF = ("--text", "--no-textconv", "--no-ext-diff")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MARCH = "wt2"
CLIMBER_TOOLS = ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]
REVIEW_TOOLS = ["Bash", "Read", "Grep", "Glob"]   # a reviewer's, an auditor's and a ruler's: read-only

class ClimbError(Exception):
    """A failed step of the driver: an event, never a dead process (SystemExit is not an Exception)."""

class PowerCut(Exception):
    """A measurement or a landing check ended, or could not start, because the Mac draws from its battery (power_ok):
    never a failure, a verdict or a learned time (O8-3). Not a ClimbError, so no handler of the driver's failures books
    it: on_ac() is its one handler (O9-1, A9-1). `final`: raised by ac_wait() past task_wall_s on battery."""
    final = False

# the programs the driver runs as Dale (D10's rule applied to the driver: the wrong program cannot be run): git as
# plumbing and porcelain in trees no agent wrote, the machine's readers, the door's sudo, the notifier, and bash for
# origin's dev/ship.sh alone, written from git; Julia, node and claude run behind the door (dev/climb/door.py) only
PROGRAMS = {"git", "ps", "pgrep", "sysctl", "vm_stat", "sudo", "tar", "grep", "head", "launchctl", "osascript", "lsof", "pmset"}

def program(cmd):
    """`cmd`, an argv list whose program is one of PROGRAMS (or bash running origin's ship.sh as the lander wrote it),
    or a ClimbError: no shell string, so no program can hide in one (A6-11: a scan of a string's `|`, `&&` and `;`
    missed `$(...)`, a backtick, a newline and `&`)."""
    if not isinstance(cmd, list) or not cmd or not all(isinstance(w, str) for w in cmd):
        raise ClimbError(f"the driver runs argv lists only, never a shell string: {str(cmd)[:200]}")
    # bash runs two scripts only: origin's ship.sh as the lander wrote it, and the driver's OWN dev/src_verdict.sh in its
    # `--fails` mode (a red's identity from stdin, its one definition: spec v19 Q1), never a candidate's
    if os.path.basename(cmd[0]) not in PROGRAMS and not (cmd[:1] == ["bash"] and len(cmd) > 1 and cmd[1].endswith(".wtd/ship.lander.sh")) \
            and cmd != ["bash", os.path.join(ROOT, "dev", "src_verdict.sh"), "--fails"]:
        raise ClimbError(f"the driver runs no {cmd[0]} as Dale: {' '.join(cmd)[:200]} (door.py runs it as a build user)")
    return cmd

def sh(cmd, cwd=None, timeout=None, env=None, check=False, stdin=None, input=None):
    """The one way the driver's modules run a program (core, measure, lander, slots, climb; door.py's own calls are
    the door's): `cmd` through program(), its output captured, `input` its stdin text when given."""
    r = subprocess.run(program(cmd), cwd=cwd or ROOT, capture_output=True, text=True, timeout=timeout, env=env,
                       stdin=stdin, input=input)
    if check and r.returncode != 0:
        raise ClimbError(f"{' '.join(cmd)}: {(r.stderr or r.stdout).strip()[:400]}")
    return r

def piped(a, b, cwd=None, check=False):
    """`a | b`, two argv lists of PROGRAMS, as two processes: b's result; with `check`, a failure of either raises."""
    p = subprocess.Popen(program(a), cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        r = sh(b, cwd=cwd, stdin=p.stdout)
    finally:
        p.stdout.close(); err = p.stderr.read().decode(errors="replace"); p.wait()
    if check and (p.returncode or r.returncode):
        raise ClimbError(f"{' '.join(a)} | {' '.join(b)}: {(err if p.returncode else r.stderr or r.stdout).strip()[:400]}")
    return r

def git(*args, cwd=None, check=True):
    """git as the driver runs it: no hook and no fsmonitor, in trees and repositories no agent wrote (agents work in
    their users' homes, and their commits come back as bundles: slots.bundle)."""
    return sh(["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *args], cwd=cwd, check=check).stdout.strip()

def safe_write(path, text, mode=0o644):
    """`text` at `path` as a new file, whatever was there removed first and never followed."""
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    with contextlib.suppress(FileNotFoundError):
        os.remove(path)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode), "w") as f:
        f.write(text)

def fetch():
    """origin/wt2, retried (DEFAULTS fetch_tries): two slots, the scoreboard and ship.sh fetch side by side (ref-lock
    races)."""
    tries, first, step = DEFAULTS["fetch_tries"]
    common_write("git fetch origin (the repository's refs and objects)")
    for i in range(tries):
        if sh(["git", "fetch", "-q", "origin", MARCH]).returncode == 0:
            return
        time.sleep(first + step * i)
    raise ClimbError(f"git fetch origin wt2 failed {tries} times")

COMMON = sh(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], check=True).stdout.strip()
REPO = os.path.dirname(COMMON) if os.path.basename(COMMON) == ".git" else COMMON
STATE = os.environ.get("WT_CLIMB_STATE") or os.path.join(os.path.dirname(REPO), ".wt-climb")   # the override: a dry run
WORKTREES = os.path.join(os.path.dirname(REPO), ".worktrees")
# THE state that owns this repository's logs and refs (spec v18 P5, the incident: a probe run from a worktree of the real
# repository wrote the real common dir's landing log): COMMON/wt-climb-state holds that state's realpath, written by
# `climb.py claim-repo` alone. Every driver write under COMMON goes through common_write (or common_path), which
# refuses, located, unless the marker names the running STATE: the lander's ship.sh (its landing appends the landing
# log, wt-landings.tsv), a fetch of origin, a ready branch, a slot's bundle ref, a worktree of the repository
CLAIM = os.path.join(COMMON, "wt-climb-state")

def claimed_by():
    """The state that owns this repository (COMMON/wt-climb-state's realpath), or None."""
    with contextlib.suppress(FileNotFoundError):
        return open(CLAIM).read().strip() or None
    return None

def common_write(what):
    """Refuses (ClimbError, located) a driver write under COMMON unless this repository is claimed by the running STATE
    (spec v18 P5): no scratch state writes the real repository's logs or refs; a scratch harness claims its own clone."""
    owner = claimed_by()
    if owner != os.path.realpath(STATE):
        raise ClimbError(f"{what}: {COMMON} is claimed by {owner or 'no state'}, not this state {os.path.realpath(STATE)}: "
                         "nothing under it is written (`climb.py claim-repo` claims it; a scratch harness claims its own clone)")

def common_path(name, write=False):
    """The path of `name` under COMMON; with `write`, only when this state owns the repository (common_write)."""
    write and common_write(f"a write of {name}")
    return os.path.join(COMMON, name)

def claim_repo():
    """`climb.py claim-repo`: this repository's common dir names the running STATE as its owner, refused when it names
    another state that exists (its own claim-repo is the way back), or any other state when STATE is overridden, so two
    states never both write its logs."""
    owner, me = claimed_by(), os.path.realpath(STATE)
    # who may claim (spec v19 P4, red round 16 2): the repository's default state (<its parent>/.wt-climb, no
    # WT_CLIMB_STATE override), or an overridden state when the repository is a clone's own .git (its git dir is its
    # common dir); a scratch state run from a linked worktree never claims, so no probe can claim the real repository
    default = os.path.realpath(os.path.join(os.path.dirname(REPO), ".wt-climb"))
    gitdir = sh(["git", "rev-parse", "--path-format=absolute", "--git-dir"], check=True).stdout.strip()
    own_git = os.path.realpath(gitdir) == os.path.realpath(COMMON)
    overridden = bool(os.environ.get("WT_CLIMB_STATE")) and me != default
    if overridden and not own_git:
        raise ClimbError(f"{me} is an overridden state run from a linked worktree ({gitdir}) of {COMMON}: it claims nothing; "
                         "the repository's own state is its default, and a scratch state claims a clone of its own")
    # an overridden state never replaces another's marker, whether or not that state's directory exists (spec v20 F5,
    # red round 17 3: the default state moved aside, a probe in the real checkout would claim it); only the default
    # state re-claims a repository whose owner is gone
    if owner and owner != me and (overridden or os.path.isdir(owner)):
        raise ClimbError(f"{COMMON} is claimed by the state {owner}"
                         f"{', which exists' if os.path.isdir(owner) else ''}: not claimed for {me}"
                         f"{' (an overridden state never replaces a claim; only the default state re-claims)' if overridden else ''}")
    write_atomic(CLAIM, me + "\n")
    return me
DRIVER = os.path.join(WORKTREES, "climb-driver")   # the loops run landed code only, from here (launch.sh)
for d in ("runs", "claims", "briefs", "logs", "verify", "base", "deltas", "env"):
    os.makedirs(os.path.join(STATE, d), exist_ok=True)

from defaults import DEFAULTS, LOCKED_KEYS, hill_defaults   # every number, with its band (dev/climb/defaults.py)
# every git the driver runs, and the dev/ship.sh it runs, cuts a network call that moves under git_low_speed (O6-6): git
# reads its config from the environment (GIT_CONFIG_COUNT), so no git call of the driver's can be written without it
os.environ.update(GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="http.lowSpeedLimit", GIT_CONFIG_VALUE_0=str(DEFAULTS["git_low_speed"][0]),
                  GIT_CONFIG_KEY_1="http.lowSpeedTime", GIT_CONFIG_VALUE_1=str(DEFAULTS["git_low_speed"][1]))
LOOP = os.environ.get("WT_CLIMB_LOOP")   # the loop this process is an iteration of (launch.sh), or None
_BEAT = [0.0]

def beat():
    """This loop's stamp (logs/<loop>.stamp) touched: a step of progress (O6-6), read by launch.sh's heartbeat against
    the loop's loop_stale_s; at most once a second."""
    if LOOP and time.time() - _BEAT[0] >= 1:
        _BEAT[0] = time.time()
        p = os.path.join(STATE, "logs", f"{LOOP}.stamp")
        with contextlib.suppress(OSError):
            with open(p, "a"):
                os.utime(p)

def cfg():
    c = dict(DEFAULTS)
    p = os.path.join(STATE, "config.json")
    if os.path.exists(p):
        c.update({k: v for k, v in json.load(open(p)).items() if k not in LOCKED_KEYS})
    c["claude_home"] = c["claude_home"] or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return c

# G5, a positive rule (R14): a move's diff may hold regular files (mode 100644) only, each path one its kind allows,
# changed only as its rule says; every other entry is refused, so no name a list forgot passes (round 3 found
# non-ASCII paths, round 4 Julia's environment files and symlinks). The rules are the climb's own landings' paths
# (2026-11-08 to 11-09: 61 src/**, 29 test/src/**, 8 the corpus, 2 a debt list, 1 a new model): `any` change, `add`
# lines only (the smoke times), `delete` lines only of a definition the diff pins (L227: the commit that pins a
# debt-listed definition deletes its line), `new` files only (D11: a model is never loosened; a corpus unit is written
# once, by its landing, and loaded by test/corpus_loader.jl, which G5 runs over it)
MOVE_RULES = {
    # (test/src/runner.jl, the runner's test, test/src/corpus_loader_negatives.jl, the loader's negatives (D38),
    # test/src/oracle_read.jl, the store's format's test (spec v14 V2), and test/src/verdict.jl, the verdict's (spec v16
    # X1), are the judge's, outside every port move's reach as test/runner.jl is: R6)
    "port": [(r"src/[\w/.-]+\.jl", "any"), (r"test/src/(?!runner\.jl$|corpus_loader_negatives\.jl$|oracle_read\.jl$|verdict\.jl$)[\w/.-]+\.jl", "any"),
             # the corpus: a new unit file alone (test/corpus/<slug>.jl, one a move, G5); the snapshot, test/smoke_corpus.jl,
             # is no move's to change (HILL.md, the corpus)
             (r"test/corpus/[a-z0-9][a-z0-9_]{0,63}\.jl", "new"), (r"test/smoke_times\.tsv", "add"),
             (r"dev/quarantine_(unpinned|no_counterpart)\.txt", "delete"), (r"dev/formal/[\w.-]+\.(tla|cfg)", "new")],
    "audit": [(r"dev/AUDIT\.md", "add")]}

# THE answering program besides the corpus (spec v14 V2, D5): the files the native-answer process loads, test/smoke_judge.jl
# (the judging entry, which loads the others through one recording reader), test/oracle.jl (the capture's write half)
# and test/corpus_loader.jl (which decides the program a unit's load makes and writes its digest). Used three ways and
# restated nowhere: G5 (move_rule: no move's rule admits them), the store's key (measure.oracle_key: its `judge` field
# the hash of their blobs) and the answering process's own record (measure.answer_labels refuses an answer whose
# `loads` list is not exactly these files at the store's judge, the snapshot and the label's unit)
JUDGE_WRITE = ("test/smoke_judge.jl", "test/oracle.jl", "test/corpus_loader.jl")
# the judge's other files: the store's decoder (outside the key: no stored byte depends on it), the compiling side, the
# verdict, the runner and its fixtures (spec v16 X1; v18 P2: the runner is the judge's, a marshalling change the lead's
# hand, so no move edits anything on the verdict's path); no move's either
JUDGE_READ = ("test/oracle_read.jl", "test/smoke.jl", "test/verdict.jl", "test/runner.jl", "test/src/runner.jl", "test/fixtures/runner.wat",
              "test/fixtures/runner_calls.tsv", "test/fixtures/runner_raw.tsv", "test/fixtures/runner_patch.wat",
              "test/fixtures/runner_patch.tsv", "test/fixtures/make_fixtures.py", "test/run_child.jl",
              "test/throw_shapes.jl")

def move_rule(path, kind="port"):
    """The rule `kind` (port, audit) applies to `path`, or None: a path no move of that kind may change (a file
    of the answering program, JUDGE_WRITE, or the judge's, JUDGE_READ, never)."""
    if path in JUDGE_WRITE or path in JUDGE_READ:
        return None
    return next((how for rx, how in MOVE_RULES[kind] if re.fullmatch(rx, path, re.ASCII)), None)


def now():
    return datetime.datetime.now(datetime.timezone.utc)

def stamp(t=None):
    return (t or now()).isoformat(timespec="seconds")

alive = door.alive   # the one test that a recorded process lives, its boot time with it (O6-11)

# ---------------------------------------------------------------- state: one lock, atomic writes
_LOCK = {"n": 0, "fd": None, "thread": threading.RLock(), "owner": None}
# the state lock is the last of LOCK_ORDER (spec v18 P6): no lock is taken while this thread holds it (door.assert_order)
door.HOOKS["state"] = lambda: _LOCK["n"] > 0 and _LOCK["owner"] == threading.get_ident()

@contextlib.contextmanager
def locked():
    """One lock over the state for every process of the climb (flock), re-entrant within a thread, and one thread of a
    process at a time (a move warms its session in a thread beside its base measurement)."""
    with _LOCK["thread"]:
        if _LOCK["n"] == 0:
            door.assert_order("state")   # last: nothing this thread holds comes after it
            _LOCK["fd"] = os.open(os.path.join(STATE, ".lock"), os.O_CREAT | os.O_RDWR)
            try:
                door.flock_within(_LOCK["fd"], DEFAULTS["state_lock_s"], "the climb's state lock")
            except BaseException:
                os.close(_LOCK["fd"]); raise
        _LOCK["n"] += 1
        _LOCK["owner"] = threading.get_ident()
        try:
            yield
        finally:
            _LOCK["n"] -= 1
            if _LOCK["n"] == 0:
                fcntl.flock(_LOCK["fd"], fcntl.LOCK_UN); os.close(_LOCK["fd"])
                _send_notes()   # a note for Dale is sent once the lock is released, never under it (spec v14 V6)

def write_atomic(path, text):
    """Every state file is replaced whole or not at all: a kill or a full disk mid-write leaves the old file."""
    with locked():
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)

def event(kind, **kw):
    beat()
    p = os.path.join(STATE, "events.jsonl")
    with locked(), open(p, "a+b") as f:
        sep = b""
        if f.seek(0, os.SEEK_END) > 0:
            f.seek(-1, os.SEEK_END)
            sep = b"" if f.read(1) == b"\n" else b"\n"   # a line cut by a kill ends here, never joins this one
        f.write(sep + (json.dumps({"t": stamp(), "kind": kind, **kw}) + "\n").encode())

door.HOOKS.update(beat=beat, event=lambda kind, **kw: event(kind, **kw), disk=lambda: disk_room(), power=lambda: power_ok())

def events():
    """Every event; a line that does not parse (a write cut short) is skipped, never fatal to the loop that reads."""
    p = os.path.join(STATE, "events.jsonl")
    out = []
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            with contextlib.suppress(ValueError):
                out.append(json.loads(line))
    return out

def state_json(name, default):
    p = os.path.join(STATE, name)
    return json.load(open(p)) if os.path.exists(p) else default

def save_json(name, obj):
    write_atomic(os.path.join(STATE, name), json.dumps(obj, indent=1))

def update_json(name, default, fn):
    with locked():
        obj = state_json(name, default); fn(obj); save_json(name, obj)

def notify(title, text):
    """A macOS notification for Dale (O5-8), from the driver's own uid, never from a scratch state (a dry run), within a
    wall (step_wall_s: osascript can block, and no process runs without one): its failure, a wall passed among them, is
    an event, never the loop's. Called by _send_notes alone, never under the state lock (spec v14 V6)."""
    if not os.environ.get("WT_CLIMB_STATE"):
        q = lambda x: json.dumps(x[:200], ensure_ascii=False)
        try:
            r = sh(["/usr/bin/osascript", "-e", f"display notification {q(text)} with title \"WasmTarget climb\" subtitle {q(title)}"],
                   timeout=cfg()["step_wall_s"])
            if r.returncode != 0:
                event("notify-failed", title=title[:120], why=(r.stderr or "")[-300:])
        except (subprocess.TimeoutExpired, OSError) as e:
            event("notify-failed", title=title[:120], why=f"{type(e).__name__}: {str(e)[:300]}")

_NOTES = []   # notes for Dale written under the state lock, sent once it is released (_send_notes)

def _send_notes():
    """Every note written since, sent now: the state lock is released (locked() calls this when its count reaches 0)."""
    while _NOTES and _LOCK["n"] == 0:
        notify(*_NOTES.pop(0))

def for_dale(title, text):
    """THE note for Dale (one place): written to for-dale.md under the state lock, and its notification sent after the
    lock is released, with a wall (notify), whoever called it under the lock (power_ok, disk_room, an alarm)."""
    with locked(), open(os.path.join(STATE, "for-dale.md"), "a") as f:
        f.write(f"\n## {stamp()} — {title}\n{text}\n")
        _NOTES.append((title, text))
    _send_notes()

def backed_off(kind, key=None):
    ent = state_json("backoff.json", {}).get(f"{kind}:{key}" if key else kind)
    return bool(ent) and time.time() < ent["until"]

def waits(kind):
    """THE one wait predicate of a loop (spec v17 Z1): any backoff of `kind` or `kind:<key>` still running. A loop reads
    this alone, so no backoff can be written that its loop does not read (the round-14 operator's finding 2: the
    lander wrote `lander:flaky` and read only three of its keys, and checked every item back to back)."""
    now = time.time()
    return any((k == kind or k.startswith(kind + ":")) and isinstance(v, dict) and now < v.get("until", 0)
               for k, v in state_json("backoff.json", {}).items())

def back_off(kind, key=None, why="", secs=None, note_at=3):
    """One way any failure waits (21): retry_backoff_s, doubled each time it repeats before a success clears it
    (backoff_cap_s at most), and one note for Dale when it has repeated note_at times in a row; `secs` waits a fixed
    time instead."""
    k = f"{kind}:{key}" if key else kind
    with locked():
        b = state_json("backoff.json", {})
        n = b.get(k, {}).get("n", 0) + 1
        b[k] = {"until": time.time() + (secs or min(cfg()["retry_backoff_s"] * 2 ** (n - 1), cfg()["backoff_cap_s"])), "n": n, "why": why[:300]}
        save_json("backoff.json", b)
    if n == note_at:
        for_dale(f"{k} failed {n} times in a row", f"The last: {why[:1200]}\nDefault taken: it waits "
                 f"{round((b[k]['until'] - time.time()) / 60)} min and tries again, the wait doubling each time.")

def recovered(kind, key=None):
    update_json("backoff.json", {}, lambda b: b.pop(f"{kind}:{key}" if key else kind, None))

# ---------------------------------------------------------------- the score
class Row(tuple):
    """A row (label, outcome, secs, why) and what it was judged against (spec v17 Y4): `prov`, (the stored answer's
    block hash, `noanswer:<hash>` for a stored noanswer, and the judge's key, measure.judge_id), or None for a row no
    measurement of v17 wrote. G2 compares two rows only when both name the same answer and judge (losses)."""
    def __new__(cls, r, prov=None):
        t = super().__new__(cls, tuple(r))
        t.prov = prov
        return t

PROV_RE = re.compile(r"(?:noanswer:)?[0-9a-f]{40}")

def read_cases(path):
    return parse_cases(open(path).read(), path)

def parse_cases(text, path="the cases"):
    """A cases file's rows; one with a label twice is refused (smoke.jl keeps the last of two equal labels, red 3). A
    `#prov <label> <answer> <judge>` line (cases_text's) names its row's provenance (Row.prov)."""
    out, prov = [], {}
    for line in text.splitlines():
        if line.startswith("#prov\t"):
            f = line.split("\t")
            if len(f) != 4 or not PROV_RE.fullmatch(f[2]) or not re.fullmatch(r"[0-9a-f]{40}", f[3]):
                raise ClimbError(f"{path}: a provenance line that does not read: {line[:200]!r}")
            prov[f[1]] = (f[2], f[3])
            continue
        f = line.rstrip("\n").split("\t", 3)
        if len(f) >= 3:
            out.append((f[0], f[1], float(f[2] or 0), f[3] if len(f) > 3 else ""))
    out = [Row(r, prov.get(r[0])) for r in out]
    dup = sorted(l for l, n in collections.Counter(r[0] for r in out).items() if n > 1)
    if dup:
        raise ClimbError(f"{path} has {len(dup)} label(s) twice: {', '.join(dup[:5])}")
    return out

def cases_text(rows):
    return "".join(f"{l}\t{o}\t{s}\t{w}\n" + (f"#prov\t{l}\t{p[0]}\t{p[1]}\n" if p else "")
                   for l, o, s, w, p in ((*r, getattr(r, "prov", None)) for r in rows))

def _norm(s):
    s = re.sub(r"#\d+(#\d+)*", "#N", s)
    return re.sub(r"0x[0-9a-f]+", "0x…", s).strip()

UNPORTED_RE = re.compile(r"unported: the (dart|Julia-only) definition (.*)")
SITE_RE = re.compile(r"(internal error at|invalid module at) (\S+:\d+ \S+?)(:|,|\s|$)")

def unported_site(why):
    m = UNPORTED_RE.search(why)
    return re.split(r", | \| |; ", m.group(2))[0] if m else None

def site_def(site):
    """A rejection site's definition: its file and its name (`src/julia/classes.jl type_value_unmade: …` or
    `dart2wasm/lib/intrinsics.dart:1194 Intrinsifier.generateStaticIntrinsic`), never its reason's words."""
    head = site.partition(": ")[0].strip()
    path, _, name = head.partition(" ")
    return path, name.strip()

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
    s = {"passed": c["passed"], "climbable": len(cases) - c["outside"] - c["judge-gap"] - c["runner-gap"], "outside": c["outside"],
         "unported": c["unported"], "wrong": c["wrong"], "errored": c["errored"], "judge_gap": c["judge-gap"],
         "runner_gap": c["runner-gap"], "total": len(cases)}
    if base:   # S over the corpus as it stood at launch; cases added since count apart (HILL.md)
        s["passed_base"] = sum(1 for l, o, _, _ in cases if o == "passed" and l in base)
        s["added"] = sum(1 for l, _, _, _ in cases if l not in base)
    return s

def landings():
    """dev/ship.sh's landing log, one reader: (time, short sha, lane) per landed commit."""
    p = os.path.join(COMMON, "wt-landings.tsv")
    return [(f[0], f[1], f[4] if len(f) > 4 else "") for f in (l.rstrip("\n").split("\t") for l in open(p)) if len(f) >= 3] \
        if os.path.exists(p) else []

def landings_at(sha):
    """The landings `sha` holds: the landing log's rows (landings()) whose commit is `sha` or one of its ancestors, the
    landing count OF that commit, never of the moment it is read (the round-14 operator's finding 6, spec v17 Z7). Origin
    lands one commit a row in order, so the count is the place of the newest row `sha` reaches, plus one; one listing of
    `sha`'s history whatever the log's length."""
    rows = landings()
    if not rows:
        return 0
    reach = set(git("rev-list", sha).split())
    lens = {len(r[1]) for r in rows}
    reach = {x[:k] for x in reach for k in lens}
    for i in range(len(rows) - 1, -1, -1):
        if rows[i][1] in reach:
            return i + 1
    return 0

def count_of(sha):
    """A commit's place on origin: its ancestors and itself (git rev-list --count), the age every row of the table has."""
    return int(git("rev-list", "--count", sha))

def table():
    """The one table (A5-1, R5-12, O5-6): {label: (row, count)}, each case's latest row and the count of the origin
    commit it was measured at. A score and a landing both write it, and a row replaces an older one only (write_rows),
    so a score of a head older than a landing never undoes that landing's rows. The table is G2's "before" and every
    move's; nothing else is (no pass set, no rows applied again)."""
    p = os.path.join(STATE, "table.tsv")
    out, prov = {}, {}
    if os.path.exists(p):
        for line in open(p):
            if line.startswith("#prov\t"):   # a row's provenance (spec v17 Y4: cases_text's line)
                f = line.rstrip("\n").split("\t")
                if len(f) == 4:
                    prov[f[1]] = (f[2], f[3])
                continue
            f = line.rstrip("\n").split("\t", 4)
            if len(f) == 5:
                out[f[1]] = ((f[1], f[2], float(f[3] or 0), f[4]), int(f[0]))
    return {l: (Row(r, prov.get(l)), c) for l, (r, c) in out.items()}

def head_cases():
    return [r for r, _ in table().values()]

def write_rows(rows, n):
    """Rows measured at origin's count `n` written into the table, each over a row no newer than it."""
    with locked():
        t = table()
        for r in rows:
            if r[0] not in t or t[r[0]][1] <= n:
                t[r[0]] = (r, n)
        write_atomic(os.path.join(STATE, "table.tsv"), "".join(
            f"{c}\t{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\n" + (f"#prov\t{r[0]}\t{r.prov[0]}\t{r.prov[1]}\n" if getattr(r, "prov", None) else "")
            for r, c in t.values()))

def baseline():
    p = os.path.join(STATE, "baseline-labels.txt")
    return set(open(p).read().split()) if os.path.exists(p) else set()

def scored_heads(ev=None):
    """The one reader of the scored heads (pick, report, the map, score-tick): a refused score scored nothing."""
    ev = events() if ev is None else ev
    refused = {e["sha"] for e in ev if e["kind"] == "score-invalid"}
    return [e for e in ev if e["kind"] == "scored" and e["sha"] not in refused]

# the src tail: definitions dev/src_progress.sh counts as not ported (D40, D46), each kind's meaning from its line
TAIL_KINDS = {
    "Internal": "its body rejects Internal where Julia's inference finds it never returns; the progress line counts it "
                "not ported, \"each to triage\"",
    "Guard": "it returns nothing past a guard that rejects Internal; the progress line counts it not ported, "
             "\"each to triage\"",
    "Unported": "it still rejects Unported or Unquarantined: a gap to fill"}

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
        k = cfg()["tail_chunk"]
        chunks += [(path, cls, defs[i:i + k]) for i in range(0, len(defs), k)]
    out = []
    for path, cls, defs in chunks:
        kinds = collections.Counter(k for k, _ in defs)
        why = (f"src tail: {len(defs)} definition(s) of {path}{' ' + cls if cls else ''} that src/ does not port yet; no corpus case reaches them. "
               + " ".join(f"{k} ({n}): {TAIL_KINDS[k]}." for k, n in kinds.items())
               + " A rejection-only body is never ported (D46, refusal 3). For each: read it and its anchor at the pin, "
               "port what the anchor's body does with a corpus case that reaches it (D12), or report blocked:ruling with "
               "what you found. The definitions:\n" + "\n".join(f"- {a} ({k})" for k, a in defs[:60]))
        out.append({"key": f"src tail {defs[0][1]}" + (f" (+{len(defs) - 1})" if len(defs) > 1 else ""), "cases": [], "defs": [a for _, a in defs], "secs": 0.0, "why": why,
                    "tail": True})
    return out

def members(h):
    """What a hold stands for: its cases, or a tail hold's definitions. A park holds while this is unchanged."""
    return sorted(h["cases"] or h.get("defs", []))

def holds(cases=None):
    cases = head_cases() if cases is None else cases
    parked = state_json("parked.json", {})
    groups = collections.OrderedDict()
    for label, outcome, secs, why in cases:
        # a judge gap and a runner gap are the judge's edit (spec v17 Y2, v18 P2: the lead's hand), never a climber's
        if outcome in ("passed", "outside", "judge-gap", "runner-gap"):
            continue
        k = hold_key(outcome, label, why)
        g = groups.setdefault(k, {"key": k, "cases": [], "secs": 0.0, "why": why[:400]})
        g["cases"].append(label); g["secs"] += secs
        inst = (unported_site(why) if outcome == "unported" else None) or why[:160]
        g.setdefault("instances", collections.Counter())[inst] += 1
    out = list(groups.values())
    for f in state_json("fixfirst.json", []):   # audit findings and G2 losses: fix first (D21), a measured one only
        if fixfirst_problem(f) is None:   # (its writers refused any other; one written before them is skipped here)
            out.append({"key": f["key"], "cases": f.get("cases", []), "secs": 0.0, "why": f["why"], "fixfirst": True,
                        "require_pass": f.get("require_pass", False), "tests": f.get("tests", [])})
    out += src_tail()
    for h in out:
        h["n"] = len(h["cases"]) or len(h.get("defs", []))
        h["id"] = hashlib.sha1(h["key"].encode()).hexdigest()[:10]
        p = parked.get(h["id"])
        # a park stands for the case set it was parked on: a score or a landing that changes the set unparks it
        h["parked"] = p if p and p.get("cases", members(h)) == members(h) else None
    # the gates, then fix-first findings, then the corpus (S), then the src tail S does not reach
    rank = lambda h: (0 if h["key"].startswith("G") else 1 if h.get("fixfirst") else 3 if h.get("tail") else 2, -h["n"], h["secs"])
    return sorted(out, key=rank)

def losses(rows, n):
    """G2 at a commit of count `n`: the labels the table holds passing, at a commit no newer, that `rows` do not pass,
    judged against the same stored answer and the same judge as the table's row (spec v17 Y4); never a stored
    noanswer. Every other such label is a rebase (rebases), never a landing's loss."""
    return _lost(rows, n)[0]

def rebases(rows, n):
    """The labels the table holds passing that `rows` do not pass where the stored answer, or the judge, is not the one
    the table's row was judged against (a replay, a bootstrap, an answer pair turning it noanswer, a judge edit), or
    either row names none: the table takes these rows as its base, with one note (spec v17 Y4)."""
    return _lost(rows, n)[1]

def same_judgement(b, a):
    """Two rows judged against the same stored answer and the same judge, neither a stored noanswer (spec v17 Y4): the
    one condition under which a pass lost between them is G2's."""
    p, q = getattr(b, "prov", None), getattr(a, "prov", None)
    return bool(p) and p == q and not q[0].startswith("noanswer:")

def _lost(rows, n):
    t, lost, rebased = table(), [], []
    for r in rows:
        l, o = r[0], r[1]
        if l in t and t[l][1] <= n and t[l][0][1] == "passed" and o != "passed":
            (lost if same_judgement(t[l][0], r) else rebased).append(l)
    return sorted(lost), sorted(rebased)

def runner_down(cases):
    """The cases that failed for the runner's one reason: past half of a score, the judge is broken, not the compiler
    (2026-11-09: fc89b8d8 read 0 passed, every case "node gave no answer", node's string limit)."""
    return sum(1 for _, o, _, w in cases if o in ("wrong", "errored") and "node gave no answer" in w)

PATCH_EXCLUDE = ":(exclude)src/julia/packages.jl"   # ship.sh regenerates its blocks after a merge (regen_packages.sh)

def patch_ids(rng):
    """{patch-id: commit} of every commit in rng, one git call: a commit's patch whatever its hash and its neighbours'
    lines (zero context: a landing beside its hunk changes no -U0 patch-id; operator 1), the generated packages blocks
    left out. The one identity of a patch, the lander's (architect cut)."""
    out = piped(["git", "log", "-p", "-U0", *DIFF, "--no-merges", "--format=commit %H", rng, "--", ".", PATCH_EXCLUDE],
                ["git", "patch-id", "--stable"]).stdout
    return {p: c for p, c in (l.split() for l in out.splitlines() if l.strip())}

def fixfirst_problem(f):
    """Why a fix-first entry cannot be measured, or None (A4): G2's cases to pass, a src-test red's test files to pass
    (measure.src_locate: the move's landing check runs them), or an audit finding whose why starts with its path:line.
    Its writers ask (add_fixfirst); holds() only reads (A5-10)."""
    if f.get("require_pass") and f.get("cases") or f["key"].startswith("audit ") and re.match(r"[\w/.-]+:\d+ ", f.get("why", "")) \
            or f["key"].startswith("src-test ") and f.get("tests"):
        return None
    return "neither G2's cases to pass, a src-test red's files, nor an audit finding whose why starts with path:line"

def known_red(f):
    """A fix-first entry that stands for a red on origin (a G2 loss, a src-test red), whose age fixfirst_max_landings bounds."""
    return bool(f.get("require_pass")) or f["key"].startswith("src-test ")

def add_fixfirst(entries):
    """Fix-first entries, each once by its key, refused at the write when no move on it can be measured; each new one
    stamped with the landings the landing log held when it was filed (`filed_landings`), the age fixfirst_overdue reads
    in landings, never commits (the operator's round-13 finding 8: a hand stack of six was six "landings")."""
    bad = [(f, fixfirst_problem(f)) for f in entries if fixfirst_problem(f)]
    for f, why in bad:
        alarm(f"fixfirst-{hashlib.sha1(f['key'].encode()).hexdigest()[:8]}", "a fix-first entry is refused",
              f"{f['key'][:160]!r}: {why}. Default taken: it is not filed.")
    n = len(landings())
    good = [dict(f, filed_landings=n, filed_t=stamp()) for f in entries if not fixfirst_problem(f)]
    update_json("fixfirst.json", [], lambda ff: ff.extend(f for f in good if not any(x["key"] == f["key"] for x in ff)))

def origin_scored():
    """Whether origin's head has a score's src record: src-latest.json's head (written by measure.src_score) is origin's
    head or an ancestor of it. Without one no landing's test set can be made (measure.src_set), so nothing lands or
    climbs (admits; spec v18 Q2, the round-15 architect's finding 3: the check would run every file, past D14)."""
    h = state_json("src-latest.json", {}).get("head")
    return bool(h) and sh(["git", "merge-base", "--is-ancestor", h, f"origin/{MARCH}"]).returncode == 0

def admits(x, overdue=None, scored=None):
    """THE one predicate of what the climb may land and climb: nothing while origin's head has no score's src record
    (origin_scored, spec v18 Q2: the first score comes before any climb move, a construction); while a known red is
    overdue (the operator's round-13 finding 2), a fix-first item or hold (a move on a fix-first hold, or a hand item
    enqueued `--fixes <key>`, the lead's deliberate act naming the red it fixes), and nothing else; else everything. Read
    by the lander's loop, the slots' pick, the queue cap and the stall alarm alike, so none can disagree with another."""
    overdue = fixfirst_overdue() if overdue is None else overdue
    scored = origin_scored() if scored is None else scored
    return scored and (not overdue or bool(x.get("fixfirst")))

def admitted_queue(overdue=None):
    """The queued items admits() admits now: what the queue cap counts (a skipped item never fills the queue)."""
    overdue, scored = fixfirst_overdue() if overdue is None else overdue, origin_scored()
    return [x for x in state_json("ready.json", []) if admits(x, overdue, scored)]

def fixfirst_overdue():
    """The known reds (known_red) filed fixfirst_max_landings or more landings ago and still unfixed (the landing-check
    ruling's R4, R11): while any stands, the lander lands fix-first moves alone (lander.land_round), so a known red is
    never left standing while other work lands. Its age is in LANDINGS, the landing log's rows since it was filed. An
    entry filed before entries were stamped so is stamped now, an event."""
    n = len(landings())
    if any(known_red(f) and "filed_landings" not in f for f in state_json("fixfirst.json", [])):
        def stamp_(ff):
            for f in ff:
                if known_red(f) and "filed_landings" not in f:
                    f["filed_landings"], f["filed_t"] = n, stamp()
                    event("fixfirst-stamped", key=f["key"][:160], filed_landings=n)
        update_json("fixfirst.json", [], stamp_)
    return [dict(f, age=n - f["filed_landings"]) for f in state_json("fixfirst.json", [])
            if known_red(f) and n - f["filed_landings"] >= cfg()["fixfirst_max_landings"]]

def file_g2(lost, sha):
    """G2: one fix-first hold per set of lost cases, never one per scored head."""
    key = "G2 lost " + hashlib.sha1("\n".join(lost).encode()).hexdigest()[:8] + f": {len(lost)} passing case(s)"
    add_fixfirst([{"key": key, "cases": lost, "require_pass": True, "why": f"these cases passed before and do not at "
                   f"{sha}; find the landing that lost them (git bisect between the last scored heads) and fix it at its source (D12)"}])

def tool_versions(door_tools):
    """THE record of the tools a verdict runs under (spec v15 W2), taken once a launch, after door.tools chose them:
    Julia's full build (juliaup's install of the climb Manifest's version), node's version read from the copy the door
    pinned (spec v16 X4: door.pin_node) and its sha256 (the installed bytes', spec v18 P6). Kept in the state's tools.json,
    written as a `tools` event, carried by every score's `scored` event, and hashed into every row's judge key
    (measure.judge_id, spec v18 P4: a tool change is a rebase as a judge edit is, one rule)."""
    t = {"julia": door_tools["julia_build"], "node": door_tools["node"], "node_sha256": door_tools.get("node_sha256", "")}
    save_json("tools.json", t)
    event("tools", **t)
    return t

def record(path, sha):
    """A full score's rows enter the table at the scored head's count; a case the table held passing at an older
    commit that the score does not pass is G2's. The one path (`record` and the scoreboard), so the runner-failure
    guard holds on both."""
    cases = read_cases(path)
    down = runner_down(cases)
    if not cases or down > len(cases) // 2:
        event("score-invalid", sha=sha, runner_down=down, total=len(cases))
        for_dale("a score was refused: the runner failed", f"{down} of {len(cases)} cases at {sha} read \"node gave "
                 "no answer\". Default taken: the score is not recorded; the table keeps its rows.")
        back_off("score")
        return None
    n = count_of(sha)
    tools = state_json("tools.json", None)
    with locked():
        lost, bad = losses(cases, n), sorted(l for l, o, _, _ in cases if o in ("wrong", "errored"))
        rebased = rebases(cases, n)
        write_rows(cases, n)
        if not os.path.exists(os.path.join(STATE, "baseline-labels.txt")):
            write_atomic(os.path.join(STATE, "baseline-labels.txt"), "\n".join(sorted(l for l, _, _, _ in cases)) + "\n")
        s = score(cases, baseline())
        event("scored", sha=sha, **s, lost=len(lost), tools=tools)
    if lost:
        file_g2(lost, sha)
    if rebased:   # a stored answer or the judge changed under these labels: no landing's loss (spec v17 Y4)
        event("score-rebased", sha=sha, answers=True, lost=len(rebased), first=rebased[:20])
        for_dale(f"the store or the judge changed: {len(rebased)} passing case(s) no longer pass", f"At {sha[:10]}, "
                 f"{len(rebased)} case(s) the table held passing do not pass, and each was judged against another stored "
                 f"answer or another judge than its table row: {', '.join(rebased[:20])}. Default taken: no G2 fix-first is "
                 "filed (no move can fix a change of the store or the judge); the table takes this score's rows as its base.")
    return s, lost, bad

def advance(rows, sha, why):
    """Rows measured on a commit of origin (a landing's, or a base's) written into the table at its count at once: a
    gap that unlocks few passes uncovers the next gap of the same cases (on 2026-11-09 the 256-case
    translateStorageType hold passed 5 and moved 251 on), so its next layer is a hold for the next move."""
    if not rows:
        return 0
    write_rows(rows, count_of(sha))
    event("advanced", sha=sha, cases=len(rows), why=why)
    return len(rows)

# ---------------------------------------------------------------- the budget: the account's whole spend
def weighted(u):
    return (u.get("cache_read_input_tokens", 0) * 0.1 + u.get("cache_creation_input_tokens", 0) * 1.25
            + u.get("input_tokens", 0) + u.get("output_tokens", 0) * 5)

def dollars(u, model):
    """A usage's dollars as the API bills it (DEFAULTS price_usd, each kind of token at `model`'s price): the proxy's
    count of a run's cost against its --max-budget-usd (R6-6). A cache write the answer did not split into its
    5-minute and 1-hour parts is counted at the 1-hour price, the higher, so a cap never reads low."""
    p, cc = cfg()["price_usd"][model], u.get("cache_creation") or {}
    w5, w1 = cc.get("ephemeral_5m_input_tokens", 0), cc.get("ephemeral_1h_input_tokens", 0)
    unsplit = max(0, u.get("cache_creation_input_tokens", 0) - w5 - w1)
    return (u.get("input_tokens", 0) * p["input"] + u.get("output_tokens", 0) * p["output"] + u.get("cache_read_input_tokens", 0) * p["cache_read"]
            + w5 * p["cache_write_5m"] + (w1 + unsplit) * p["cache_write_1h"]) / 1e6

def transcript(path, off=0):
    """The one reader of a Claude Code transcript: (the offset past it, the entry) for each whole JSON line from `off`
    (a line still being written is left for the next read), an unreadable line skipped."""
    with open(path, "rb") as f:
        f.seek(off)
        for raw in f:
            if not raw.endswith(b"\n"):
                return
            off += len(raw)
            with contextlib.suppress(ValueError):
                yield off, json.loads(raw)

SPEND = os.path.join(STATE, "spend.jsonl")   # the climb's one spend source (R11): book() writes it, spend_days() reads it

def book(**run):
    """The writer of SPEND, given to each run's proxy (door.proxy): each answer's usage appended the moment the proxy
    has read it, so the governor that admits every next call (room()) counts every live run's spend, a slot's, a
    reviewer's and the lander's alike, never one run's room twice. Every writer is a process of the driver's: one
    line per answer under a flock of the file, a line cut by a kill ended before the next."""
    def write(u):
        with open(SPEND, "a+b") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            sep = b"" if f.seek(0, os.SEEK_END) == 0 or (f.seek(-1, os.SEEK_END), f.read(1))[1] == b"\n" else b"\n"
            f.write(sep + (json.dumps({"t": stamp(), **run, "usage": dict(u)}) + "\n").encode())
    return write

def spend_days():
    """{"runs": {day: weighted}, "account": {day: weighted}}: the climb's runs from SPEND (the usage each proxy read
    from the answers themselves; an agent's own result and transcript are its user's to forge, and live in its
    user's home, never under claude_home), Dale's own sessions from his transcripts, each file read once
    (incrementally); the cache keeps spend_window_days alone and is written only when it changed."""
    home, window = os.path.join(cfg()["claude_home"], "projects"), cfg()["spend_window_days"]
    oldest = (now() - datetime.timedelta(days=window)).date().isoformat()
    with locked():
        cache = state_json("spend-cache.json", {})
        changed = cache.pop("runs:", None) is not None   # the run records' own spend, before SPEND
        runs = cache.setdefault("spend:", {"off": 0, "days": {}})
        if os.path.exists(SPEND):
            for runs["off"], d in transcript(SPEND, runs["off"]):
                runs["days"][d["t"][:10]] = runs["days"].get(d["t"][:10], 0.0) + weighted(d.get("usage") or {}); changed = True
        # a transcript not written within the window, and a day before it, leave the cache (O7-7: it held 299 entries and
        # 23,561 ids, 900 KB, rewritten with fsync under the state lock at every proxy call)
        for p in [p for p in cache if p != "spend:" and (not os.path.exists(p) or os.stat(p).st_mtime < time.time() - window * 86400)]:
            del cache[p]; changed = True
        for ent in cache.values():
            for day in [d for d in ent["days"] if d < oldest]:
                del ent["days"][day]; changed = True
        for p in glob.glob(os.path.join(home, "**", "*.jsonl"), recursive=True):
            st = os.stat(p)
            if st.st_mtime < time.time() - window * 86400:
                continue
            ent = cache.get(p, {"off": 0, "days": {}, "seen": []})
            if st.st_size < ent["off"]:
                ent = {"off": 0, "days": {}, "seen": []}
            if st.st_size == ent["off"]:
                continue
            seen = set(ent["seen"])
            for ent["off"], d in transcript(p, ent["off"]):
                m = d.get("message") or {}
                if d.get("type") != "assistant" or m.get("id") in seen:
                    continue
                seen.add(m.get("id"))
                day = (d.get("timestamp") or "")[:10]
                ent["days"][day] = ent["days"].get(day, 0.0) + weighted(m.get("usage") or {})
            ent["seen"] = list(seen)[-2000:]
            cache[p] = ent; changed = True
        if changed:   # written only when an offset or a day changed (O7-7)
            save_json("spend-cache.json", cache)
    acc, rs = collections.Counter(), collections.Counter(runs["days"])
    for p, ent in cache.items():
        if p != "spend:":
            acc.update(ent["days"])
    return {"runs": rs, "account": acc + rs}

def days_back(days):
    return {(now() - datetime.timedelta(days=i)).date().isoformat() for i in range(days)}

def account_spend(days=1):
    """Every session of the account (the climb's runs, Dale's, a hand-run session's), by day: the weekly limit counts
    them all, so the governor does too."""
    return sum(v for d, v in spend_days()["account"].items() if d in days_back(days))

def week_start():
    """The weekly limit resets on Sunday (2026-11-01 and 11-08): its window counted from Sunday 00:00Z, the earliest
    the reset can be, so the count errs high."""
    t = now()
    return (t - datetime.timedelta(days=(t.weekday() + 1) % 7)).date().isoformat()

def week_spend():
    start = week_start()
    return sum(v for d, v in spend_days()["account"].items() if d >= start)

def week_half():
    """Half the week's limit spent: no agent runs until the week resets (Dale 2026-11-08, D51). A state computed from
    the spend and week_start(), never written to PAUSE (architect 1: one file for a hand pause and the week's made a
    hand pause do nothing); Dale is told once a week."""
    w, lim = week_spend(), cfg()["week_weighted"] * cfg()["week_pause"]
    if w < lim:
        return False
    if state_json("alarms.json", {}).get("week-half") != week_start():
        update_json("alarms.json", {}, lambda a: a.__setitem__("week-half", week_start()))
        event("week-half", spent=round(w), limit=round(cfg()["week_weighted"]))
        for_dale("the climb's agents wait: half the week's usage", f"This week (from {week_start()} 00:00Z) the account "
                 f"spent {w/1e6:.0f}M weighted tokens of the {cfg()['week_weighted']/1e6:.0f}M weekly limit measured on "
                 "2026-11-02. Default taken (D51): no agent runs; the lander keeps landing approved commits; agents run "
                 "again when the week resets.")
    return True

def pause():
    """A hand pause or an alarm's: PAUSE's text, or "hand" for an empty file; any PAUSE file pauses (architect 1)."""
    p = os.path.join(STATE, "PAUSE")
    return (open(p).read().strip() or "hand") if os.path.exists(p) else None

def disk_room():
    """Free disk under the state of at least disk_free_gb, asked by every loop's iteration (O6-10: only launch read it,
    and a full disk mid-measurement read as the move's fault): under it the climb pauses, with one note for Dale."""
    free = shutil.disk_usage(STATE).free / 1e9
    if free >= cfg()["disk_free_gb"]:
        return True
    with locked():
        if not pause():
            write_atomic(os.path.join(STATE, "PAUSE"), f"disk: {free:.1f} GB free under {STATE}, under disk_free_gb\n")
            event("disk-low", free_gb=round(free, 1))
            for_dale("the climb paused: the disk is nearly full", f"{free:.1f} GB free under {STATE}, under the "
                     f"{cfg()['disk_free_gb']} GB a climb needs. Default taken: paused; free space, then "
                     "`bash dev/climb/launch.sh resume`.")
    return False

def power_read():
    """(on AC, Low Power Mode on), read from pmset's own words (`pmset -g batt`: "Now drawing from 'AC Power'" or
    "'Battery Power'"; `pmset -g`: `lowpowermode 1`); an answer that names neither source is a ClimbError, never a
    guess (D9)."""
    b, g = sh(["pmset", "-g", "batt"]).stdout, sh(["pmset", "-g"]).stdout
    if "'AC Power'" not in b and "'Battery Power'" not in b:
        raise ClimbError(f"pmset names no power source: {b.strip()[:120]!r}")
    m = re.search(r"^\s*lowpowermode\s+(\d+)", g, re.M)
    return "'AC Power'" in b, bool(m and m.group(1) != "0")

POWER = [power_read, 0.0, None]   # the reader (a probe stubs it), when last read, what it read

def power_ok():
    """The one reading of the power source and Low Power Mode (O8-3, R8-5), taken at every tick where the disk is asked
    (door.wait, measure.watched, the lander's check) and by every loop before it starts work, pmset read at most once a
    second. A change counts only once it has held power_settle_s (O9-2: the adapter flapped 117 times in six minutes on
    2026-11-08): the reading that differs from the settled one is kept in power.json with when any process first saw
    it, dropped when any process reads the settled one again, and settled once it has held; settling writes the event
    (`power`) and, at most once per direction per alarm_s, one note for Dale. True while the settled source is AC. On
    battery no move, measurement, score or landing check starts (ac_wait), and one in flight ends, never a failure
    (on_ac)."""
    if time.time() - POWER[1] >= 1 or POWER[2] is None:
        POWER[2], POWER[1] = POWER[0](), time.time()
    ac, low = POWER[2]
    rec = state_json("power.json", {})
    if "ac" in rec and [rec["ac"], rec.get("lowpower")] == [ac, low] and "seen" not in rec:
        return ac
    with locked():
        rec = state_json("power.json", {})
        now_ = time.time()
        if "ac" not in rec:   # the first reading settles at once: nothing came before it
            rec = {"ac": ac, "lowpower": low, "since": stamp()}
            changed, was = True, True
        elif [rec["ac"], rec.get("lowpower")] == [ac, low]:   # back to the settled reading: a flap, never a change
            rec.pop("seen", None); changed = False
        elif (rec.get("seen") or [None])[:2] != [ac, low]:   # a new reading: held from now
            rec["seen"] = [ac, low, now_]; changed = False
        elif now_ - rec["seen"][2] >= cfg()["power_settle_s"]:   # held power_settle_s: settled
            was = rec["ac"]
            rec = dict(rec, ac=ac, lowpower=low, since=stamp()); rec.pop("seen", None); changed = True
        else:
            changed = False
        if changed:
            event("power", ac=ac, lowpower=low)
            way = "ac" if ac else "battery"
            noted = rec.setdefault("noted", {})
            if was != ac and now_ - noted.get(way, 0) >= cfg()["alarm_s"]:   # one note per direction per alarm_s
                noted[way] = now_
                for_dale(f"on battery since {stamp()}: the climb waits; plug in" if not ac else f"on AC since {stamp()}: the climb goes on",
                         ("The Mac draws from its battery" + (" in Low Power Mode" if low else "") + ". Default taken: no move, "
                          "measurement, score or landing check starts; one in flight ends and waits for AC, never a failure "
                          "(a move keeps its commit); agent runs in flight finish.") if not ac else "The Mac draws from AC again. "
                         "Default taken: the climb starts work again; what battery ended is redone.")
        save_json("power.json", rec)
    return rec["ac"]

def climb_spend(days):
    """The climb's own spend over the last `days` days: its runs' answers' usage, as their proxies booked it (SPEND)."""
    return sum(v for d, v in spend_days()["runs"].items() if d in days_back(days))

def allowance():
    """The day's allowance: the week's spend up to its pause, spread over the week (K7, O9), so no night of the week is
    left without an allowance by the days before it."""
    c = cfg()
    return c["week_weighted"] * c["week_pause"] / 7

def over_budget():
    return account_spend(1) >= allowance() or account_spend(7) >= cfg()["week_weighted"] * cfg()["margin"]

def room():
    """The weighted tokens the account may still spend before the week's half, asked by every run's proxy before each
    call (door.proxy), read from spend_days(), which every live run's proxy writes at once (book()). The day's allowance
    gates a move's start alone (slot_once, and the score tick's eval: over_budget()), never a call of a move it admitted
    (O7-4: a move cut mid-run at the day's crossing kept nothing of what it had spent). A run's own --max-budget-usd is
    its proxy's other refusal (dollars(), DEFAULTS price_usd); a build user's Bash reaches the proxy too."""
    acc, start = spend_days()["account"], week_start()
    return cfg()["week_weighted"] * cfg()["week_pause"] - sum(v for d, v in acc.items() if d >= start)

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
    ev = events()
    lines = [progress_line()]   # D40: a status leads with src progress
    sc = scored_heads(ev)
    if cases:
        s = score(cases, baseline())
        lines.append(f"S = {s.get('passed_base', s['passed'])} of the launch corpus pass ({s['passed']} of {s['climbable']} climbable "
                     f"with {s.get('added', 0)} cases added since); wrong {s['wrong']}, errored {s['errored']}, unported "
                     f"{s['unported']}, outside {s['outside']}; scored at {sc[-1]['sha'] if sc else '?'}, advanced by the landings since")
        if len(sc) > 1:
            lines.append("S over the scored heads: " + " → ".join(str(e.get("passed_base", e["passed"])) for e in sc[-8:]))
    else:
        lines.append("S: no scored head yet (the scoreboard's first run)")
    landed = [e for e in ev if e["kind"] == "landed"]
    lines.append(f"landings: {len(landed)} by the climb, {sum(1 for e in landed if e['t'] >= stamp(now() - datetime.timedelta(days=1)))} in 24 h; "
                 f"{len(state_json('ready.json', []))} approved commit(s) wait for the lander")
    lines.append(f"this week (from {week_start()}): {week_spend()/1e6:.0f}M of {cfg()['week_weighted']/1e6:.0f}M weighted "
                 f"({100 * week_spend() / cfg()['week_weighted']:.1f}%; the climb pauses at {100 * cfg()['week_pause']:.0f}%)")
    lines.append(f"budget: the account today {account_spend(1)/1e6:.0f}M of {allowance()/1e6:.0f}M weighted, 7 days "
                 f"{account_spend(7)/1e6:.0f}M of {cfg()['week_weighted']*cfg()['margin']/1e6:.0f}M; the climb's own today {climb_spend(1)/1e6:.0f}M")
    hs = holds(cases)
    lines.append(f"holds: {len(hs)} ({sum(1 for h in hs if h['parked'])} parked); the largest:")
    for h in hs[:k]:
        tag = " [parked]" if h["parked"] else " [claimed]" if os.path.exists(os.path.join(STATE, "claims", h["id"])) else ""
        lines.append(f"  {h['n']:4d}  {h['key'][:110]}{tag}")
    je = state_json("judge-eval.json", None)
    lines.append(f"judge: refused {je['recall']:.0%} of past defects, approved " + (f"{je['approval']:.0%} of clean moves" if je.get('approval') is not None else "no clean move yet") + f" ({je['t'][:10]}{'' if judge_measured() else '; its brief or HILL.md gates changed since: stale'}{'' if je.get('recall', 0) >= cfg()['judge_recall'] else '; under its band: moves need two blind approvals (K4)'})"
                 if je else "judge: not measured yet (the score tick measures it)")
    fd = os.path.join(STATE, "for-dale.md")
    if os.path.exists(fd) and open(fd).read().strip():
        lines.append("for Dale (defaults taken): " + fd)
    return "\n".join(lines)

def draw_map(out):
    """The project map (D29): the S line of every scored head and report()'s text, drawn by this program."""
    pts = [e.get("passed_base", e["passed"]) for e in scored_heads()][-60:] or [0]
    poly = " ".join(f"{i * 600 / max(len(pts) - 1, 1):.1f},{120 - 110 * p / max(max(pts), 1):.1f}" for i, p in enumerate(pts))
    write_atomic(out, f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>WasmTarget Climb</title><style>:root{{--bg:#14121a;--fg:#e8e4f0;--acc:#b9a3ff}}
@media (prefers-color-scheme: light){{:root:not([data-theme=dark]){{--bg:#faf8ff;--fg:#1d1a26;--acc:#6d4fd8}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.45 ui-monospace,monospace;padding:24px 16px;max-width:1000px;margin:auto}}
svg{{width:100%;height:130px}} polyline{{fill:none;stroke:var(--acc);stroke-width:2}} pre{{white-space:pre-wrap}}</style>
<h1>WasmTarget climb</h1><svg viewBox="0 0 600 125" preserveAspectRatio=none><polyline points="{poly}"/></svg>
<pre>{html.escape(report(25))}\n\ndrawn {stamp()} by dev/climb/climb.py</pre>""")
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
    "requeue": {"type": "boolean"}, "escalate": {"type": "boolean"}, "for_dale": {"type": "string"}, "ledger_row": {"type": "string"}}}

# the briefs, each a template the driver fills (their full paths, so the ratchet's L130 sees them consumed)
TEMPLATES = {"climber.md": "dev/climb/climber.md", "reviewer.md": "dev/climb/reviewer.md",
             "auditor.md": "dev/climb/auditor.md", "ruling.md": "dev/climb/ruling.md"}

def render(template, **kw):
    t = open(os.path.join(ROOT, TEMPLATES[template])).read()
    for k, v in kw.items():
        t = t.replace("{{" + k + "}}", str(v))
    return t

KAIMON_TOOLS = ["mcp__kaimon__ex", "mcp__kaimon__manage_repl", "mcp__kaimon__check_eval"]
BUDGET = "budget"   # run_agent's answer when the governor refuses the run: no verdict, no stop
TIMEOUT = "timeout"   # run_agent's answer for a run past task_wall_s: its user was reaped (a slot's Kaimon with it)

def agent_token():
    """The agents' token (D-F), or None before Dale made one: read from token_file, which only his uid reads."""
    p = os.path.expanduser(cfg()["token_file"])
    return (open(p).read().strip() or None) if os.path.isfile(p) else None

def _token_mtime():
    p = os.path.expanduser(cfg()["token_file"])
    return os.path.getmtime(p) if os.path.isfile(p) else None

def token_refused():
    """The API refused the agents' token (a 401 or 403 a run's proxy forwarded, O6-8) and its file has not been
    written since: no agent runs; a new token (`claude setup-token`, the file written again) ends it."""
    rec = state_json("token-refused.json", None)
    return bool(rec) and rec.get("mtime") == _token_mtime()

def token_answered(admitted, task, role):
    """A run's proxy's admitted calls read for the API's refusal of the token (O6-8): a 401 or 403 is the token's,
    never the run's: recorded (token_refused), one event and one note for Dale. Returns whether it was refused."""
    bad = sorted({st for _, st in admitted if st in (401, 403)})
    if bad and not token_refused():
        save_json("token-refused.json", {"t": stamp(), "mtime": _token_mtime(), "status": bad, "task": task})
        event("token-refused", status=bad, task=task, role=role)
        for_dale("the agents' token is refused: run `claude setup-token`", f"The API answered {bad} to {task} ({role}) through its "
                 f"proxy. Default taken: no agent runs until the token file ({cfg()['token_file']}) is written again "
                 "(`claude setup-token`); the lander lands on.")
    return bool(bad)

def token_call():
    """Launch's one call with the agents' token (O6-8): max_tokens 1 to the climber's model through a proxy of its own
    (door.proxy, which alone holds the token), its usage booked: the API's status. A 200 clears a recorded refusal.
    The call is Claude Code's, as the agents' is: the API admits a subscription token (`claude setup-token`'s) only
    for a request whose system prompt opens with Claude Code's line, and answers any other with a 429 (probed
    2026-11-10: with the line 200, without it 429 `rate_limit_error`, while a `claude -p` run answered 200)."""
    model = cfg()["climber_model"]
    with door.proxy(agent_token(), {model}, lambda r: True, book(task="preflight", role="probe", sid="preflight")) as px:
        req = urllib.request.Request(f"http://127.0.0.1:{px['port']}/v1/messages", json.dumps(
            {"model": model, "max_tokens": 1, "system": [{"type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."}],
             "messages": [{"role": "user", "content": "1"}]}).encode(),
            {"content-type": "application/json", "anthropic-version": "2023-06-01", "anthropic-beta": "oauth-2025-04-20"})
        try:
            st = urllib.request.urlopen(req, timeout=cfg()["kaimon_http_s"]).status
        except urllib.error.HTTPError as e:
            st = e.code
    if st == 200:
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(STATE, "token-refused.json"))
    else:
        token_answered([[model, st]], "preflight", "probe")
    return st

# An agent (HILL.md, "The door") runs the climb's pinned claude as a build user, in a clone of its own in that user's
# home, inside the door's `agent` profile with no Mach bootstrap, like every other build-user process: it writes its
# home alone and reaches the network only through the driver's proxy to its model (door.proxy) and its slot's
# Kaimon; "dontAsk" runs a tool only when the allowlist names it (Edit and Write under its clone and never its .git;
# for a climber Kaimon's ex, manage_repl and check_eval on the slot's own Kaimon, which holds that slot's sessions
# alone); no settings, hooks or CLAUDE.md are read from the tree. The user boundary is under all of it: no path into
# Dale's home, the state or the main repository, no signal to Dale's processes. Claude Code's own sandbox is off: it
# cannot start inside a profile (door.profile), and with it on every Bash call fails (probed).
SANDBOX = json.dumps({"sandbox": {"enabled": False}})

def claude_cmd(model, effort, schema, tools, prompt, sid, cwd, resume=False, cap=None, mcp=None):
    c = cfg()
    root = "/" + os.path.abspath(cwd)   # "//abs/path": a permission rule's absolute path
    allowed = [f"{t}({root}/**)" if t in ("Edit", "Write") else t for t in tools] + (KAIMON_TOOLS if mcp else [])
    cmd = [door.claude_bin(STATE), "-p", prompt, "--model", model, "--effort", effort, "--output-format", "json",
           "--json-schema", json.dumps(schema), "--tools", *tools, "--allowedTools", *allowed,
           "--disallowedTools", *[f"{t}({root}/.git/**)" for t in ("Edit", "Write")], "--strict-mcp-config",
           "--mcp-config", mcp or json.dumps({"mcpServers": {}}),   # a slot's: a file in its user's home (its key)
           "--setting-sources", "", "--settings", SANDBOX, "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections",
           "--permission-mode", "dontAsk", "--max-budget-usd", str(cap or c["task_cap_usd"])]
    return cmd + (["--resume", sid] if resume else ["--session-id", sid])

def agent_env(user, port, depot=None):
    """An agent's environment, explicit and nothing inherited: its user's Claude Code config and temporary directory
    (its default is /tmp/claude-<uid>, outside the profile's writes), no auto-update and no traffic but the model's, no
    git prompt, the driver's proxy as its model's address with a placeholder for the token the proxy adds (so `claude`
    sends what it sends with a token, and no process of its user holds one), and Julia's depot over the dependency
    images (A5-5)."""
    h = door.home(user)
    return dict(CLAUDE_CONFIG_DIR=f"{h}/claude", CLAUDE_CODE_TMPDIR=f"{h}/tmp", DISABLE_AUTOUPDATER="1",
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", WT_CLIMB_AGENT="1", GIT_TERMINAL_PROMPT="0",
                MCP_TOOL_TIMEOUT=str(cfg()["kaimon_http_s"] * 1000),   # a hung Kaimon call errors to the agent (O6-12)
                ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}", CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-placeholder",
                **({"JULIA_DEPOT_PATH": depot, "WT_SHARED_DEPOT": depot.split(":", 1)[1].rstrip(":")} if depot else {}))

def run_models(cmd):
    """The models a run's proxy admits (R10): those its `claude` requests for its argv, observed through the proxy
    (claude-2.1.322, 2026-11-10, `--model` claude-sonnet-5-5 with Bash, Edit, Write and a commit): its `--model` alone,
    no small model. Any other model a call names is a 403, listed in the run's `refused`."""
    return {cmd[cmd.index("--model") + 1]}

def kaimon_port(role):
    """Slot role `role`'s (slot<k>) own Kaimon's port, localhost:kaimon_port+k (never Dale's 2828): the one source of
    it (A6-10), read by its server's start, its URL and its agent's profile."""
    return cfg()["kaimon_port"] + int(role[len("slot"):])

def run_agent(role, task, cmd, cwd, sid, user, depot=None):
    """One agent run as build user `user`, at background QoS (its children inherit it, D31): its structured answer,
    BUDGET when the governor refuses it, or None when it printed no answer (a timeout, a crash, a cap); its result
    kept under runs/ with its proxy's record; its spend booked call by call in SPEND (book()), each call asked of the
    room left (room()).
    The token stays in the driver's proxy (D-F)."""
    t0 = time.time()
    # the week's half and a refused token stop every run; the day's allowance stops a move's start alone (slot_once;
    # the score tick asks it before the judge's eval; an audit, about 0.6M, and the agent probe are exempt, K5), never a
    # run of a move it admitted (O7-4)
    if week_half() or token_refused():
        event("budget-refused", role=role, task=task, token=token_refused())
        return BUDGET
    tok = agent_token()
    if not tok:
        raise ClimbError(f"no agents' token at {cfg()['token_file']} (D-F: `claude setup-token`, a file only Dale reads)")
    d = door.give(user, f"agent-{sid}")
    kaimon = kaimon_port(user) if user.startswith("slot") else None
    model, cap = next(iter(run_models(cmd))), float(cmd[cmd.index("--max-budget-usd") + 1])
    with door.proxy(tok, run_models(cmd), lambda r: room() > 0 and dollars(r["usage"], model) < cap,
                    book(task=task, role=role, sid=sid), role=user) as px:
        p = door.popen(user, cmd, cwd=cwd, env=agent_env(user, px["port"], depot), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, profile=door.profile(f"{d}/agent.sb", [door.home(user)], kind="agent", port=kaimon, egress=px["port"]))
        try:   # task_wall_s of its role's awake time: a landing's stop of the role is never the run's (ruling 11)
            out, err = door.wait(user, p, cfg()["task_wall_s"])
        except subprocess.TimeoutExpired:
            door.reap(user); out, err = "", TIMEOUT; p.communicate()
        if not user.startswith("slot"):   # nothing of the run (a Bash child left behind) holds its proxy: reaped before
            door.reap(user)               # it is left; a slot's Kaimon lives on, its user stopped by its move (climb)
    usd = dollars(px["usage"], model)
    write_atomic(os.path.join(STATE, "runs", f"{task}.{role}.{int(t0)}.{sid}.json"),   # its spend is SPEND's (book())
                 json.dumps({"refused": px["refused"], "admitted": px["admitted"], "tools": sorted(px["tools"]), "peak": px["peak"],
                             "blocks": sorted(px["blocks"]), "keys": sorted(px["keys"]),
                             "usd": usd, "out": out}))
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        d = None
    theirs = d.get("total_cost_usd") if isinstance(d, dict) else None
    lo, hi = cfg()["price_band"]
    if isinstance(theirs, (int, float)) and theirs > 0 and usd > 0 and not lo <= theirs / usd <= hi:
        alarm(f"price-{model}", "the proxy's dollars disagree with claude's", f"{task} ({role}, {model}): claude counted "
              f"${theirs:.4f}, the proxy ${usd:.4f} (ratio {theirs / usd:.2f}, band {lo}-{hi}). Default taken: the proxy "
              "caps runs at its own count; check DEFAULTS price_usd against the published price.")
    token_answered(px["admitted"], task, role)   # the API refused the token: the token's, never the run's (O6-8)
    for x in px["refused"]:
        if len(x) > 3 and x[3] not in ("in flight",):
            event("proxy-refused", role=role, task=task, call=x[:2], why=x[3])
    if d is None:
        event("agent-error", role=role, task=task, after=round(time.time() - t0), stderr=err[-300:])
        return TIMEOUT if err == TIMEOUT else None
    so = d.get("structured_output")
    if so is None:
        with contextlib.suppress(json.JSONDecodeError, TypeError):
            so = json.loads(d.get("result", ""))
    return so or None

def ask(role, task, model, effort, schema, tools, prompt, cwd, user, sid=None, resume=False, cap=None, mcp=None, again=None, depot=None):
    """An agent's answer, its empty answer retried once: an empty answer is infrastructure (a timeout, a crash, a cap),
    never a verdict, a park or a judge's miss. The retry resumes the same session with `again` when given (the
    climber's work is in it), else runs fresh. Returns the answer, BUDGET, or None after two empty answers."""
    sid = sid or str(uuid.uuid4())
    go = lambda prompt_, sid_, resume_, cap_: run_agent(role, task, claude_cmd(model, effort, schema, tools, prompt_, sid_, cwd, resume=resume_,
                                                         cap=cap_, mcp=mcp), cwd, sid_, user, depot)
    so = go(prompt, sid, resume, cap)
    if so == TIMEOUT:   # its user was reaped: no retry, least of all a resume against its dead Kaimon (O6-12)
        return None
    if so is not None:
        return so
    event("agent-empty", role=role, task=task)
    so = go(again, sid, True, cfg()["resume_cap_usd"]) if again else go(prompt, str(uuid.uuid4()), False, cap)
    return None if so == TIMEOUT else so

def tree_of(listing):
    """A tree object of the main repository from `ls-tree -r` lines (plumbing: a temporary index of the driver's)."""
    idx = os.path.join(STATE, f".index-{os.getpid()}")
    with contextlib.suppress(FileNotFoundError):
        os.remove(idx)
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    sh(["git", "update-index", "--index-info"], input=listing, cwd=REPO, env=env, check=True)
    t = sh(["git", "write-tree"], cwd=REPO, env=env, check=True).stdout.strip()
    os.remove(idx)
    return t

def two_commits(before, after, msg, climb_from=None, blank=()):
    """A reviewer's whole repository (A98E2), two commits of their own in the main repository's objects: tree
    `before` with no parent and `after` on it, with no other ref or history to search; with `climb_from`, both trees
    carry that commit's dev/climb/ (the HILL.md the moves are judged by) and the files `blank` names read blank."""
    def fix(t):
        if not climb_from:
            return t
        blob = sh(["git", "hash-object", "-w", "--stdin"], input="(not part of this review)\n", cwd=REPO, check=True).stdout.strip()
        ls = [l for l in sh(["git", "ls-tree", "-r", "--full-tree", t], check=True).stdout.splitlines() if not l.split("\t", 1)[1].startswith("dev/climb/")]
        ls = [(f"100644 blob {blob}\t{l.split(chr(9), 1)[1]}" if l.split("\t", 1)[1] in blank else l) for l in ls]
        return tree_of("\n".join(ls + sh(["git", "ls-tree", "-r", climb_from, "--", "dev/climb"], check=True).stdout.splitlines()) + "\n")
    ident = ["-c", "user.name=climb", "-c", "user.email=climb@localhost"]
    c1 = git(*ident, "commit-tree", fix(before), "-m", "the tree before the change")
    return git(*ident, "commit-tree", fix(after), "-p", c1, "-m", msg)

def agent_tree(user, run_id, ref, sha, files=None):
    """A clone of its own in build user `user`'s home ($HOME/w/<run>), made by the user in the `check` profile from a
    run directory holding `sha` as `ref`: with origin's history for a slot (hard links), a copy for any other role;
    `files` ({path in the clone: text}) laid in after. Returns its path."""
    d = door.give(user, run_id, {f"files/{k}": v for k, v in (files or {}).items()})
    door.repo(d, REPO, {ref: sha}, history=ref != "review", links=user in door.HISTORY)
    w = f"{door.home(user)}/w/{run_id}"
    rc, o, e = door.run(user, ["/bin/sh", "-c", 'rm -rf "$HOME/w" && git clone -q -b "$2" "$1/repo.git" "$3" && cd "$3" && '
                               'git config user.name climb && git config user.email climb@localhost && '
                               'if [ -d "$1/files" ]; then cp -R "$1/files/." .; fi', "sh", d, ref, w], cfg()["tree_wall_s"],
                        profile=door.profile(f"{d}/clone.sb", [door.home(user)], kind="check"))
    if rc != 0:
        raise ClimbError(f"the clone for {user}: {(o + e).strip()[-300:]}")
    return w

def ac_wait(t0=None):
    """No measurement or check starts on battery (O9-1, A9-1): waits while power_ok() reads battery, at most
    task_wall_s of awake time since `t0` (now), past which PowerCut (`final`): the climb's longest run bounds its
    longest wait."""
    t0 = door.CLOCK() if t0 is None else t0
    while not power_ok():
        if door.CLOCK() - t0 > cfg()["task_wall_s"]:
            e = PowerCut(f"the Mac has drawn from its battery for task_wall_s ({cfg()['task_wall_s']} s of awake time)")
            e.final = True
            raise e
        time.sleep(cfg()["poll_s"]["lock"]); beat()

def on_ac(what, fn, *args, wait=False, say=None):
    """The one handling of a power cut (O9-1, A9-1, timing-report G): fn's PowerCut is never a failure. It books
    `power-wait` naming `what` and the cut (the label in flight is in its text, measure.watched), with no backoff, no
    alarm and no note beyond power_ok's own. A loop's iteration (`wait` False, guarded: a score, a base, a rebased check,
    a landing round) ends there (3), and the loop starts nothing until AC. A move's gate and a hand command's long run
    (`wait` True: the oracle's bootstrap, replay and audit, which keep what they answered) wait for AC, keeping what
    they have, and run fn again; the wait is bounded by task_wall_s of awake time from the first cut (ac_wait), past
    which the PowerCut goes on to the caller (a slot's move ends as infrastructure). `say`, a hand command's printer,
    gets one line a cut."""
    t0 = None
    while True:
        try:
            return fn(*args)
        except PowerCut as e:
            event("power-wait", what=what, final=e.final, why=str(e)[:300])
            if not wait:
                return 3
            if e.final:
                raise
            if say:
                say(f"{what}: the Mac went on battery ({str(e)[:160]}); waiting for AC, at most task_wall_s "
                    f"({cfg()['task_wall_s']} s) of awake time, then it continues from what it kept")
            t0 = door.CLOCK() if t0 is None else t0
            ac_wait(t0)

def guarded(kind, fn, *args, key=None):
    """The one wrapper around every loop's iteration (architect 2): the slots', the lander's, the score tick's and the
    audit's. A power cut is on_ac's (power-wait, no failure); any other Exception, a subprocess's timeout among them, is
    an event and a backoff of its kind, with one note when it repeats (back_off); never a dead loop, and never one that
    retries at once."""
    try:
        return on_ac(f"{kind}:{key}" if key else kind, fn, *args)
    except Exception as e:
        why = f"{type(e).__name__}: {e}"
        event(f"{kind}-error", key=key, error=why[:400])
        back_off(kind, key, why=why)
        return 3

def change_stem(a, b):
    """The stem of the first src file a..b changes (`src` when none): the scope of the neutral message a review sees."""
    return os.path.splitext(os.path.basename((git("diff", "--name-only", a, b, "--", "src/").splitlines() or ["src"])[0]))[0]

def review(task, user, base, commit, job="", claims=""):
    """G4, blind, as review user `user` in a repository of two commits (base's tree, the commit's), so no other ref
    or history is there to read (A98E2). The reviewer sees one form, the judge's eval's and every round of the gate's
    alike (A7-10): a neutral message (`feat(<stem>): the change under review`) and a fresh review, never an earlier
    round's findings; `job` tells it what the move was for when the diff alone cannot (a tail move's definitions, a
    fix-first finding, test lines it removes), and `claims`, what the author states (its commit message, its answers to
    an earlier review), reaches it there alone, as claims to check. Returns the review, BUDGET or None."""
    c = cfg()
    if claims:
        job += ("\n\nWhat the change's author states (its commit message, and its answers to an earlier review): claims "
                "to check against the code, never evidence of their own:\n" + claims[:6000])
    with door.using(user):
        tree = agent_tree(user, f"review-{task}", "review", two_commits(f"{base}^{{tree}}", f"{commit}^{{tree}}",
                                                                         f"feat({change_stem(base, commit)}): the change under review"))
        prompt = render("reviewer.md", WORKTREE=tree, COMMIT="HEAD", BASE="HEAD~1", JOB=job)
        return ask("review", task, c["climber_model"], c["reviewer_effort"], SCHEMA_REVIEW, REVIEW_TOOLS, prompt, tree, user)

def approved(rv):
    return isinstance(rv, dict) and rv.get("verdict") == "APPROVE" and not any(
        f.get("severity") in ("blocker", "should") and f.get("status") != "resolved" for f in rv.get("findings", []))

def landing_lock_held():
    """dev/ship.sh's landing lock, held by a live process (a dead holder's lock is free, as ship.sh itself rules)."""
    lock = os.path.join(COMMON, "wt-landing-lock")
    if not os.path.isdir(lock):
        return False
    if os.path.getmtime(lock) < door.BOOT:   # made before this boot: its holder is dead whatever holds its pid now
        return False
    p = os.path.join(lock, "pid")
    with contextlib.suppress(OSError, ValueError, IndexError):   # ship.sh's record, "<pid> <boot>", read as ship.sh's
        rec = open(p).read().split()   # alive_rec reads it (O8-6); an older ship.sh's pid alone: its file's own boot
        return alive(int(rec[0]), int(rec[1]) if len(rec) > 1 else door.BOOT if os.path.getmtime(p) >= door.BOOT else None)
    # its holder died between mkdir and writing its pid: ship.sh's own rule, read where ship.sh keeps it (D5, A7-6)
    return time.time() - os.path.getmtime(lock) < ship_literal("LOCK_NOPID_S")

def ship_literal(name):
    """A number dev/ship.sh names (`<NAME>=<n>` at a line's start), read from origin's copy, the one source of a rule
    ship.sh and the driver share (SHIP_MAX, LOCK_NOPID_S)."""
    m = re.search(rf"^{name}=(\d+)", git("show", f"origin/{MARCH}:dev/ship.sh"), re.M)
    if not m:
        raise ClimbError(f"origin/{MARCH}'s dev/ship.sh names no {name}")
    return int(m.group(1))

def judge_blob():
    """What G4 is: reviewer.md and the parts of HILL.md a reviewer applies, its gates and its refusals (11; red 13), so
    a change to the landing, the door or the numbers there forces no eval (O7)."""
    hill = open(os.path.join(ROOT, "dev", "climb", "HILL.md")).read()
    parts = re.findall(r"^## The (?:gates|refusals)\b.*?(?=^## )", hill, re.S | re.M)
    return hashlib.sha1((open(os.path.join(ROOT, TEMPLATES["reviewer.md"])).read() + "".join(parts)).encode()).hexdigest()[:16]

def judge_measured():
    je = state_json("judge-eval.json", None)
    return bool(je) and je.get("judge") == judge_blob()

def judge_current():
    """G4 measured as it is and passing (11): its recall at least judge_recall on the judge G4 is now."""
    return judge_measured() and state_json("judge-eval.json", {})["recall"] >= cfg()["judge_recall"]

def reviewers():
    """How many independent blind approvals a move needs (K4): one while the judge is current; two while it is under
    its recall or not measured as it is, so the climb never idles on the judge, and one again when a re-eval passes."""
    need = 1 if judge_current() else 2
    if state_json("alarms.json", {}).get("judge-double-state") != need:   # one note per change of state (A14)
        update_json("alarms.json", {}, lambda a: a.__setitem__("judge-double-state", need))
        if need == 2:
            event("alarm", name="judge-double")
            for_dale("moves need two blind approvals", "The blind reviewer is under its recall on past defects, or not "
                     "measured as it is. Default taken (K4): every move needs two independent blind approvals until a "
                     "re-eval passes; a move approved before it waits for no further review (it needs the approvals that held "
                     "when it was approved).")
    return need

def alarm(name, title, text):
    """A note for Dale, at most once per alarm_s for each name (21)."""
    a = state_json("alarms.json", {})
    if time.time() - a.get(name, 0) >= cfg()["alarm_s"]:
        update_json("alarms.json", {}, lambda x: x.__setitem__(name, time.time()))
        event("alarm", name=name)
        for_dale(title, text)
