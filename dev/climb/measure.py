"""dev/climb/measure.py — the driver's measurements: G5 read on a commit's diff, the environments and dependency
images, the three-role smoke behind the door, and the judgement of a candidate against its base."""
from core import *   # noqa: F403  the driver's shared state
import functools, random, shlex, struct   # unit_log_argv is read once; the oracle report reads a stored float
# (_value_text); run_input draws from the system's random source; the test-file process is read from dev/check.sh (shlex)

# ---------------------------------------------------------------- the gates
def lines(text, sign):
    return [l[1:] for l in text.splitlines() if l.startswith(sign) and not l.startswith(sign * 3)]

def changes(base, sha):
    """[(old mode, new mode, status, path)] of base..sha, read NUL-separated and unquoted (`--raw -z`, red 5) with no
    rename detection, so a rename is a deletion and an addition, each side judged."""
    f = sh(["git", "-c", "core.quotePath=false", "diff", "--raw", "-z", "--no-renames", "--no-abbrev", *DIFF, base, sha],
           check=True).stdout.split("\0")
    return [(*f[i].lstrip(":").split()[:2], f[i].split()[-1], f[i + 1]) for i in range(0, len(f) - 1, 2)]

def file_diff(base, sha, path, *opts):
    """One file's diff as git stores it, the path a literal pathspec (no glob, whatever its bytes)."""
    return git("diff", *DIFF, *opts, base, sha, "--", f":(literal){path}")

def g5(base, sha, kind="port"):
    """The judge untouched (HILL.md G5), read in the main repository from base..sha before anything of the commit is
    checked out or run: every entry a regular file of mode 100644 whose path the move's kind allows (MOVE_RULES), and
    each changed only as its rule says; anything else refused, named."""
    bad = []
    for old, new, st, n in changes(base, sha):
        how = move_rule(n, kind)
        if how is None:
            bad.append(f"{n} (no {kind} move changes this path)"); continue
        if st not in "AMD" or (st != "D" and new != "100644") or (st != "A" and old != "100644"):
            bad.append(f"{n} ({st} {old} -> {new}: a move changes regular files of mode 100644 alone)"); continue
        if how == "new" and st != "A":
            bad.append(f"{n} (an existing {'unit' if is_unit(n) else 'model'} changes; " +
                       ("a unit file is written once, by the landing that adds it)" if is_unit(n) else "models change only by ruling)")); continue
        if is_unit(n):   # the move's unit: loaded by the corpus loader over the base's corpus, its refusals named (early)
            bad += corpus_problems(base, sha, n)
        if how in ("add", "delete") and st != "M":
            bad.append(f"{n} ({'added' if st == 'A' else 'deleted'}; it may only {'gain' if how == 'add' else 'lose'} lines)"); continue
        d = file_diff(base, sha, n, "-U0") if how in ("add", "delete") else ""
        if how == "delete":
            if [l for l in lines(d, "+") if l.strip()]:
                bad.append(f"{n} (gains a line; a move may only delete a line of a definition it pins)")
            for l in (l.split() for l in lines(d, "-") if l.strip()):
                src = f"src/{l[0]}"
                fd = file_diff(base, sha, src, "-U5")
                if not ('pin"' in "\n".join(lines(fd, "+")) and len(l) > 1 and l[1].strip("[]") in fd):
                    bad.append(f"{n} (deletes `{' '.join(l)}`, whose definition this diff does not pin in {src})")
        if how == "add":
            removed = [l for l in lines(d, "-") if l.strip()]
            if removed:
                bad.append(f"{n} (removes or changes {len(removed)} line(s); it may only gain lines)")
            if n.endswith(".jl"):
                bad += [f"{n} (an added line names GROUPS or XFAIL: {l.strip()[:80]})" for l in lines(d, "+")
                        if re.search(r"\b(GROUPS|XFAIL)\b", l)]
                bad += corpus_problems(base, sha, n)
    units = [n for _, _, st, n in changes(base, sha) if st == "A" and is_unit(n)]
    if len(units) > 1:
        bad.append(f"{len(units)} unit files ({', '.join(units[:4])}): a move adds its cases in one unit file, test/corpus/<slug>.jl")
    tok = agent_token()   # D-F: the agents' token in a commit's diff or message is refused, named (item 15)
    if tok and tok in sh(["git", "log", "-p", *DIFF, "--format=%B", f"{base}..{sha}"]).stdout:
        bad.append("the commit holds the agents' token (its text in the diff or the message); it never lands")
    return bad

def bundled(base, sha):
    """Why base..sha cannot be queued, or None: it changes src/ together with a path no move may change (move_rule:
    the harness, the judge's files and the rules, D52's protected files), so its src would land under a message and a
    title written for the harness, its clauses unnamed (A106E2). A src change with its own test/src files is a move's
    shape and passes; the harness lands in a commit of its own. Read from git alone, before anything is queued
    (lander.enqueue, every kind)."""
    paths = [n for _, _, _, n in changes(base, sha)]
    src = [n for n in paths if n.startswith("src/")]
    held = [n for n in paths if move_rule(n) is None]
    if not (src and held):
        return None
    name = lambda ps: ", ".join(ps[:6]) + (f" and {len(ps) - 6} more" if len(ps) > 6 else "")
    return (f"{base[:10]}..{sha[:10]} bundles src with harness work: src/ ({len(src)}: {name(src)}) beside paths no move "
            f"may change ({len(held)}: {name(held)}); queue the src change and the harness change as commits of their own")

def corpus_problems(base, sha, n):
    """The move's unit `n` loaded by the corpus loader (test/corpus_loader.jl --check, the base's: the one function a
    unit is loaded by, early, in a process with no WasmTarget and no runner) over the base's snapshot and its units in
    their order, as the deps user in the `julia` profile (never behind a measurement's use of the measure user, A6-6),
    every file taken from git, never from a tree: its first refusal, located and named, or a label it registers twice.
    The loader in every measurement refuses the same forms again, whatever this run said (one function)."""
    files = corpus_files(base)
    files[n] = sh(["git", "show", f"{sha}:{n}"], check=True).stdout
    files.update({f"test/{j}": sh(["git", "show", f"{base}:test/{j}"], check=True).stdout for j in ("corpus_loader.jl",)})
    files["units.log"] = unit_log(base)
    r = julia_job("deps", f"load-{os.getpid()}", files, ["julia", "--startup-file=no", "{in}/test/corpus_loader.jl", "--check", "{in}"],
                  cfg()["loader_wall_s"])
    bad = []
    if r[0] != 0:
        bad.append(f"{n} (the corpus loader did not run over it: {why_of((r[2] or '') + (r[1] or ''))})")
    for f in (l.split("\t") for l in r[1].splitlines()):
        if f[0] == "refused" and len(f) >= 5:
            bad.append(f"{n} (the corpus loader refuses its line {f[2]}: {f[3]}: {f[4][:160]})")
    if r[0] == 0 and not any(l.startswith(("label\t", "refused\t")) for l in r[1].splitlines()):
        bad.append(f"{n} (the corpus loader read no label from it: a unit registers the cases it adds)")
    return bad

def g5_rows(base=None):
    """door-probe's corpus rows (HILL.md, the corpus): G5 read on three commits made on `base` (the driver's own commit,
    whose rules and loader these are) as objects alone (no ref): a move that changes the snapshot, test/smoke_corpus.jl,
    refused; one that adds two unit files, refused; one that adds one honest unit file, admitted (the loader run over
    it). Returns [(check, ok, evidence)]."""
    base = base or git("rev-parse", "HEAD", cwd=ROOT)
    unit = '_g("door_probe_unit", Any[\n    ("one", (n::Int64) -> n + 1, Int64(1)),\n])\n'
    snap = sh(["git", "show", f"{base}:{SNAPSHOT}"], check=True).stdout
    rows = []
    for what, files, want in (("a move that changes the snapshot (test/smoke_corpus.jl)", {SNAPSHOT: snap + "\n" + unit}, False),
                              ("a move that adds two unit files", {"test/corpus/door_probe_a.jl": unit,
                                                                  "test/corpus/door_probe_b.jl": unit.replace("door_probe_unit", "door_probe_unit_b")}, False),
                              ("a move that adds one unit file", {"test/corpus/door_probe_c.jl": unit}, True)):
        bad = g5(base, probe_commit(base, files, "door-probe: a corpus move"))
        rows.append((f"G5: {what} is {'admitted' if want else 'refused'}", (not bad) == want, "; ".join(bad)[:300] or "no refusal"))
    return rows

def probe_commit(base, files, message):
    """A commit on `base` with `files` (path: text) written, made as objects alone (no ref): a door-probe row's input."""
    ls = [l for l in git("ls-tree", "-r", "--full-tree", base).splitlines() if l.split("\t", 1)[1] not in files]
    for path, text in files.items():
        blob = sh(["git", "hash-object", "-w", "--stdin"], input=text, cwd=REPO, check=True).stdout.strip()
        ls.append(f"100644 blob {blob}\t{path}")
    return sh(["git", "commit-tree", tree_of("\n".join(ls) + "\n"), "-p", base, "-m", message], cwd=REPO, check=True).stdout.strip()

def bundled_rows(base=None):
    """door-probe's rows for `bundled`, the refusal every queued item passes (lander.enqueue): on two commits made on
    `base` as objects alone, a src change with its own test/src file admitted, and the same src change beside a file of
    the harness (dev/climb/HILL.md) refused, both sets named. Returns [(check, ok, evidence)]."""
    base = base or git("rev-parse", "HEAD", cwd=ROOT)
    src = "src/WasmTarget.jl"
    edit = lambda p: sh(["git", "show", f"{base}:{p}"], check=True).stdout + "\n# door-probe\n"
    rows = []
    for what, files, want in (("a src change with its own test/src file", {src: edit(src), "test/src/door_probe.jl": "# door-probe\n"}, True),
                              ("a src change beside a harness file (dev/climb/HILL.md)", {src: edit(src), "dev/climb/HILL.md": edit("dev/climb/HILL.md")}, False)):
        why = bundled(base, probe_commit(base, files, "door-probe: a hand commit"))
        ok = (why is None) == want and (want or (src in why and "dev/climb/HILL.md" in why))
        rows.append((f"enqueue: {what} is {'admitted' if want else 'refused'}", ok, (why or "no refusal")[:300]))
    return rows

def log_excerpt(path, head=1 << 16, tail=2000):
    """A process's log as the driver reads it, bounded (a process's output is unbounded, the driver's memory is not): the
    first ERROR line of its first `head` bytes and the line after it (where Julia names a failure, above its stack),
    then its last `tail` bytes."""
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as f:
        first = f.read(head).decode(errors="replace").splitlines()
        f.seek(max(0, os.path.getsize(path) - tail)); last = f.read().decode(errors="replace")
    i = next((i for i, l in enumerate(first) if "ERROR" in l), None)
    return ("\n".join(first[i:i + 2]) + "\n…\n" if i is not None else "") + last

def why_of(text):
    """A failed Julia's located reason: its ERROR line and the one after, never the tail of its stack."""
    ls = text.splitlines()
    i = next((i for i, l in enumerate(ls) if "ERROR" in l), None)
    return " | ".join(ls[i:i + 2])[:400] if i is not None else text[-300:]

def julia_job(role, run_id, files, cmd, wall, stdin=None, kind="julia", port=None, keep=None):
    """A short Julia job (a parser, the spans) as the role's build user in the `julia` profile: its files given in a
    run directory ({in} in `cmd` and `stdin` names it), it writes only its own scratch ({dh}), its answer read from
    its stdout; `keep` (a directory of its scratch, and where Dale keeps it) copied out by door.copy_home after a run
    that passed, while this use still holds the role, so no other job of its user runs while it is read. Returns (rc,
    stdout, stderr)."""
    with door.using(role):
        d = door.give(role, run_id, files)
        dh = f"{door.home(role)}/j/{run_id}"
        door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/j" && mkdir -p "$1/tmp"', "sh", dh], cfg()["step_wall_s"], profile=door.NONE)
        fill = lambda x: x.replace("{in}", d).replace("{dh}", dh)
        r = door.run(role, [fill(x) for x in cmd], wall, input=fill(stdin) if stdin else None,
                     profile=door.profile(f"{d}/job.sb", [dh], kind=kind, binds=[dh] if kind == "kaimon" else (), port=port),
                     env={"TMPDIR": f"{dh}/tmp", "JULIA_DEPOT_PATH": f"{dh}/depot:{door.TOP}/julia:", "JULIA_NUM_THREADS": "1"})
        if keep and r[0] == 0:
            door.copy_home(role, f"j/{run_id}/{keep[0]}", keep[1])
    return r

SLOT_KIND = {"measure": "verify", "score": "score"}   # the measurement lock each measuring role runs under
HELD_SLOT = {}   # kind: the lock's descriptor, while this process holds it (julia_slot)
door.HOOKS["locks"] = lambda: tuple(HELD_SLOT)   # door.assert_order reads them (LOCK_ORDER, spec v17 Y3)

def lander_waits(kind):
    """The lander's mark on the `kind` lock is live and not this process's: it waits to land (ruling 1)."""
    mark = os.path.join(door.LOCKS, f".julia-{kind}.first")
    with contextlib.suppress(OSError, ValueError, IndexError):
        holder, boot = (int(x) for x in open(mark).read().split()[:2])
        return holder != os.getpid() and alive(holder, boot)
    return False

def yield_slot(kind):
    """Between a measurement's parts (its three roles, and its compile's cases): while the lander waits on the lock this
    process holds, the lock passes to it, and this process takes it again once the lander is done, so no landing
    waits more than a measurement's part (ruling 1). Returns the seconds yielded. Taking the lock again is a taking in
    LOCK_ORDER (spec v17 Y3): refused (door.LockOrder) while this process uses a measuring role, which its caller leaves
    for the wait (door.released), so the lander's need of that role never waits on this process."""
    fd = HELD_SLOT.get(kind)
    if fd is None or not lander_waits(kind):
        return 0
    door.assert_order(f"lock:{kind}", retake=True)
    t0 = door.CLOCK()
    fcntl.flock(fd, fcntl.LOCK_UN)
    event("yielded", lock=kind)
    while True:
        time.sleep(cfg()["poll_s"]["yield"]); beat()
        if lander_waits(kind):   # its mark goes once it holds the lock; until then the lock is left for it
            continue
        with contextlib.suppress(BlockingIOError):
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return round(door.CLOCK() - t0)

def part_background(role):
    """Whether a measurement's parts (the compiling, the running and the verdict's process) run at background QoS: a
    slot's and the lander's measurement (role measure) as measure_background says, the score's always (it runs for
    hours beside everything). Either way one single-threaded process at a time under its measurement lock, which the
    lander takes before a check, so never beside one (D31)."""
    return cfg()["measure_background"] if role == "measure" else True

@contextlib.contextmanager
def julia_slot(kind, first=False):
    """The driver's heavy Julia, one of each kind at a time (D31 as amended): one measurement and one score, each a
    single thread (the score at background QoS, a measurement as measure_background says: part_background), never
    beside a landing's check. The lander is served first (red 8): while it
    waits (`first`), its mark holds every other taker back. A wait past lock_wait_s, for the lock or for a live
    ship.sh's landing lock, is a note and waits on (O5): every holder has a wall of its own (its derived wall,
    ship_kill_s), so no wait is a block, and none is a backoff or charged to a hold."""
    door.assert_order(f"lock:{kind}")   # LOCK_ORDER, before any wait (spec v17 Y3)
    fd = door.lock_fd(f".julia-{kind}.lock")   # TOP/locks: every state's measurements share the users (O8-2)
    mark, t0, lim = os.path.join(door.LOCKS, f".julia-{kind}.first"), door.CLOCK(), cfg()["lock_wait_s"]
    def long_wait(what):
        if door.CLOCK() - t0 > lim:
            alarm(f"wait-{kind}", f"a {kind} measurement waits past lock_wait_s", f"{what} has been held over {lim} s. "
                  "Default taken: it waits on; each holder's own wall ends it.")
    if first:
        write_atomic(mark, f"{os.getpid()} {door.BOOT}")
    try:
        while True:
            holder = open(mark).read().split() if not first and os.path.exists(mark) else []
            if not (len(holder) == 2 and alive(holder[0], int(holder[1]) if holder[1].isdigit() else None)):
                with contextlib.suppress(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
            long_wait(f"the {kind} measurement lock")
            time.sleep(cfg()["poll_s"]["lock"]); beat()
    finally:
        if first:
            with contextlib.suppress(FileNotFoundError):
                os.remove(mark)
    try:
        t0 = door.CLOCK()
        while landing_lock_held():
            long_wait(f"{COMMON}/wt-landing-lock")
            time.sleep(cfg()["poll_s"]["landing_lock"]); beat()
        ac_wait()   # no measurement starts while the power rule stops work (core.power_works): it waits, task_wall_s at most (O9-1, A9-1)
        HELD_SLOT[kind] = fd
        yield
    finally:
        HELD_SLOT.pop(kind, None)
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def stratified():
    """A net under every move (7): the quickest passing case of every group on the scored head, so a change that breaks
    any group is caught before it lands (G2 over the whole corpus holds at the next score)."""
    best = {}
    for l, o, secs, _ in head_cases():
        g = l.split("/", 1)[0]
        if o == "passed" and (g not in best or secs < best[g][1]):
            best[g] = (l, secs)
    return {l for l, _ in best.values()}

def labels_for(h):
    """What a move is measured on, at its base and on the move, the same labels both times: the hold's cases, every
    passing case of the hold's groups, and the stratified sample."""
    hc = head_cases()
    groups = {c.split("/", 1)[0] for c in h["cases"]}
    return set(h["cases"]) | stratified() | {l for l, o, _, _ in hc if o == "passed" and l.split("/", 1)[0] in groups}

PREFS = "[WasmTarget]\nprecompile_workload = false\n"   # dev/lane.sh's: a src edit reloads in seconds

def extensions(text, table_):
    """The WasmTarget extensions a Project.toml's [extensions] or a Manifest's [deps.WasmTarget.extensions] names
    (dev/manifest_check.sh's reading)."""
    out, on = [], False
    for l in text.splitlines():
        if re.match(r"^ *\[", l):
            on = re.match(rf"^ *\[{re.escape(table_)}\]", l) is not None; continue
        if on and l.split():
            out.append(l.split()[0])
    return sorted(out)

def project_hash():
    """origin's Project.toml, hashed: what the climb's Manifest was copied for."""
    return hashlib.sha1(git("show", f"origin/{MARCH}:Project.toml").encode()).hexdigest()

MANIFEST = os.path.join(STATE, "env", "Manifest.toml")   # the climb's Manifest, the driver's own (O6-5)

def copy_manifest():
    """Launch's copy of the main tree's Manifest.toml into the state (a hand act: Dale's launch), with the hash of
    origin's Project.toml it was copied for; the climb reads only this copy (manifest())."""
    write_atomic(MANIFEST, open(os.path.join(REPO, "Manifest.toml")).read())
    save_json("env/manifest.json", {"project": project_hash(), "t": stamp(), "from": os.path.join(REPO, "Manifest.toml")})
    return state_json("env/manifest.json", {})

def manifest():
    """The climb's Manifest: the copy launch made (copy_manifest), never Dale's working file read at run time (O6-5).
    When origin's Project.toml is no longer the one it was copied for: a pause and one note for Dale, then a
    ClimbError (the caller's step fails, located)."""
    rec = state_json("env/manifest.json", {})
    if not rec.get("project") or not os.path.exists(MANIFEST):
        raise ClimbError(f"no Manifest copied at launch in {MANIFEST} (launch's preflight makes it)")
    if rec["project"] != project_hash():
        why = (f"origin/{MARCH}'s Project.toml is not the one the climb's Manifest ({MANIFEST}) was copied for at launch "
               f"({rec['t']})")
        with locked():
            if not pause():
                write_atomic(os.path.join(STATE, "PAUSE"), why + "\n")
                for_dale("the climb paused: origin's Project.toml changed", why + ". Default taken: paused. Bring the main "
                         "tree's Manifest.toml up to origin's project (Pkg.resolve there), then relaunch (launch copies it).")
                event("manifest-stale", recorded=rec["project"][:12])
        raise ClimbError(why)
    return open(MANIFEST).read()

ENV_FILES = ("Manifest.toml", "LocalPreferences.toml")   # the untracked files environment() writes into a tree: the
# lander's slot keeps them through an item's checkout and clean (lander.land_round), so the layer it prepared is keyed
# by the files the check is given (door._layer_key, dev/ship.sh's copy of the lane's)

def environment(sha):
    """`sha`'s Manifest.toml and LocalPreferences.toml as dev/lane.sh makes them (R2, R10): the climb's Manifest
    (manifest()) when it names the extensions `sha`'s Project.toml does (dev/manifest_check.sh's rule), else that
    Manifest resolved for `sha`'s project files by Pkg, offline, as the deps user, cached by its inputs. Nothing of
    `sha` runs."""
    proj, man = sh(["git", "show", f"{sha}:Project.toml"], check=True).stdout, manifest()
    if extensions(proj, "extensions") != extensions(man, "deps.WasmTarget.extensions"):
        files = {f: sh(["git", "show", f"{sha}:{f}"], check=True).stdout for f in ("Project.toml", "lib/WasmInterpreter/Project.toml")}
        key = hashlib.sha1(json.dumps([files, man]).encode()).hexdigest()[:16]
        p = os.path.join(STATE, "env", f"{key}.toml")
        if not os.path.exists(p):
            files["Manifest.toml"] = man
            r = julia_job("deps", f"env-{key}", {f"env/{k}": v for k, v in files.items()},
                          ["/bin/sh", "-c", 'cp -R "$1/env" "{dh}/e" && cd "{dh}/e" && julia --startup-file=no --project=. '
                           '-e "using Pkg; Pkg.resolve()" >&2 && cat Manifest.toml', "sh", "{in}"], cfg()["pkg_wall_s"])
            if r[0] != 0 or extensions(r[1], "deps.WasmTarget.extensions") != extensions(proj, "extensions"):
                raise ClimbError(f"the environment of {sha[:10]}: {why_of(r[2] or r[1])}")
            write_atomic(p, r[1])
        man = open(p).read()
    return dict(zip(ENV_FILES, (man, PREFS)))

def deps(sha, manifest):
    """The compiled images of a Manifest's registry packages (no repository code: `sha`'s [deps] less its [sources],
    the path packages, and the Manifest less their entries, precompiled by Pkg), made once by the deps user and copied
    (APFS clones) under the door's top, where every role reads them beneath a depot of its own. Returns their depot."""
    key = hashlib.sha1(manifest.encode()).hexdigest()[:16]
    dst = f"{door.TOP}/deps/{key}"
    door.assert_order("lock:deps")   # LOCK_ORDER (spec v18 P6)
    lk = door.lock_fd(".deps.lock")   # one maker of a Manifest's images at a time, in every state (TOP/locks)
    try:
        door.flock_within(lk, door.role_wait("deps"), "the dependency images' lock (.deps.lock)")
        if not os.path.isdir(dst):
            make_deps(sha, manifest, key, dst)
    finally:
        os.close(lk)
    return dst

def toml_table(text, name):
    m = re.search(rf"^\[{re.escape(name)}\]\n(.*?)(?=^\[|\Z)", text, re.M | re.S)
    return m.group(1) if m else ""

def make_deps(sha, manifest, key, dst):
    proj = sh(["git", "show", f"{sha}:Project.toml"], check=True).stdout
    local = set(re.findall(r"^(\w+)\s*=", toml_table(proj, "sources"), re.M)) | set(re.findall(r'^name = "(\w+)"', proj, re.M))
    deps_ = "".join(l + "\n" for l in toml_table(proj, "deps").splitlines() if re.match(r"^(\w+)\s*=", l) and l.split("=")[0].strip() not in local)
    man = re.sub(r"^\[\[deps\.(\w+)\]\]\n.*?(?=^\[|\Z)", lambda m_: "" if m_.group(1) in local else m_.group(0), manifest, flags=re.M | re.S)
    r = julia_job("deps", f"deps-{key}", {"env/Project.toml": "[deps]\n" + deps_, "env/Manifest.toml": man},
                  ["/bin/sh", "-c", 'mkdir -p "{dh}/e" && cp "$1/env/Project.toml" "$1/env/Manifest.toml" "{dh}/e/" && '
                   'JULIA_DEPOT_PATH="{dh}/d:$2:" exec julia --startup-file=no --project="{dh}/e" -e "using Pkg; Pkg.precompile()"',
                   "sh", "{in}", f"{door.TOP}/julia"], cfg()["pkg_wall_s"], keep=("d", dst))
    if r[0] != 0:
        raise ClimbError(f"the dependency images of Manifest {key}: {why_of(r[2] or r[1])}")

def kaimon_images(base):
    """The compiled images of Kaimon's app, and of KaimonGate as a session of `base`'s tree loads it (its LOAD_PATH
    `@:@v#.#:@stdlib:<KaimonGate's own env>`, `@` the tree's project: an image is valid for the stack it was built
    in), made once per those Manifests by the deps user in the `kaimon` profile with localhost open (HTTP.jl and ZMQ
    bind localhost ports and sockets in their precompile workloads; no repository code runs: the tree's project is
    its two TOML files alone), copied under the door's top; each slot's Kaimon and session read them beneath a depot
    of its own."""
    ver = door.manifest_julia(manifest())   # the Julia the launch pinned (door.tools), the climb Manifest's
    app, glob_ = f"{door.TOP}/julia/environments/apps/Kaimon", f"{door.TOP}/julia/environments/v{'.'.join(ver.split('.')[:2])}"
    gate = next(iter(sorted(glob.glob(f"{door.TOP}/julia/packages/KaimonGate/*"))), "")
    env = dict(environment(base), **{"Project.toml": sh(["git", "show", f"{base}:Project.toml"], check=True).stdout})
    key = hashlib.sha1(open(f"{app}/Manifest.toml", "rb").read() + open(f"{glob_}/Manifest.toml", "rb").read() +
                       env["Manifest.toml"].encode() + gate.encode()).hexdigest()[:16]
    dst = f"{door.TOP}/kaimon/{key}"
    door.assert_order("lock:deps")   # LOCK_ORDER (spec v18 P6)
    lk = door.lock_fd(".deps.lock")
    with contextlib.closing(os.fdopen(lk)):
        door.flock_within(lk, door.role_wait("deps"), "the dependency images' lock (.deps.lock)")
        if not os.path.isdir(dst):
            e = f'JULIA_DEPOT_PATH="{{dh}}/d:{door.TOP}/julia:" XDG_CONFIG_HOME="{{dh}}/x" XDG_CACHE_HOME="{{dh}}/x" KAIMON_CONFIG_DIR="{{dh}}/k" KAIMON_CACHE_DIR="{{dh}}/k"'
            r = julia_job("deps", f"kaimon-{key}", {f"p/{n}": t for n, t in env.items()}, ["/bin/sh", "-c",
                          f'{e} JULIA_LOAD_PATH="{app}:@stdlib" julia --startup-file=no -e "using Kaimon" && '
                          f'{e} JULIA_LOAD_PATH="@:@v#.#:@stdlib:{gate}" exec julia --startup-file=no --project={{in}}/p -e "using KaimonGate"'],
                          cfg()["pkg_wall_s"], kind="kaimon", port="*", keep=("d", dst))
            if r[0] != 0:
                raise ClimbError(f"Kaimon's images: {why_of(r[2] or r[1])}")
    return dst

def extract(sha, d, overlay=None):
    """`sha`'s tree as plain files in `d` (git archive, read in the main repository; bsdtar refuses a path through a
    link or with '..'), `overlay` ({path: text}) written over it."""
    os.makedirs(d, exist_ok=True)
    piped(["git", "-C", REPO, "archive", sha], ["/usr/bin/tar", "-x", "-C", d], check=True)
    for n, text in (overlay or {}).items():
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(d, n))
        with open(os.path.join(d, n), "w") as f:
            f.write(text)
    return d

# ---- the corpus: the snapshot (test/smoke_corpus.jl, as it stood at the bootstrap; no move changes it) and the units
# after it (test/corpus/<slug>.jl, one a landing, loaded by test/corpus_loader.jl in landing order). The order is git's:
# test/corpus_loader.jl's unit_order reads the log UNIT_LOG_ARGV prints (its first-parent commits adding a unit file),
# so the driver hands each judging process that log (its argv the first line, which the judge checks against its own),
# never an order it derived
SNAPSHOT = "test/smoke_corpus.jl"
UNITS = "test/corpus/"
@functools.lru_cache(maxsize=None)
def unit_log_argv():
    """test/corpus_loader.jl's UNIT_LOG_ARGV, read from its text when first asked (a tuple): the one definition of the
    units' log (spec v16 X3; the judge refuses a log whose first line is another argv), so the driver's two logs
    (unit_log's, unit_commits') and the judge's own run of git are one argv (`--no-renames` among them: a rename reads as
    a deletion and an addition, as G5 reads it)."""
    m = re.search(r'^const UNIT_LOG_ARGV = \[([^\]]*)\]', open(os.path.join(ROOT, "test", "corpus_loader.jl")).read(), re.M)
    if not m:
        raise ClimbError("test/corpus_loader.jl holds no `const UNIT_LOG_ARGV = [...]` for the driver to read")
    return tuple(re.findall(r'"([^"]*)"', m.group(1)))

def is_unit(path):
    return re.fullmatch(r"test/corpus/[a-z0-9][a-z0-9_]{0,63}\.jl", path, re.ASCII) is not None

def unit_log(sha):
    """The log the judge orders `sha`'s units by: its argv, then git's output (test/corpus_loader.jl unit_order)."""
    return " ".join(unit_log_argv()) + "\n" + git("log", *unit_log_argv()[1:], sha, "--", UNITS)

def corpus_files(sha, overlay=None):
    """{path: text} of the corpus `sha` measures (with `overlay`, {path: text}, written over it): the snapshot and every
    unit file, each read from git's objects."""
    paths = [SNAPSHOT] + [p for p in git("ls-tree", "-r", "--name-only", sha, "--", UNITS).split() if is_unit(p)]
    out = {p: sh(["git", "show", f"{sha}:{p}"], check=True).stdout for p in paths}
    out.update({p: t for p, t in (overlay or {}).items() if p == SNAPSHOT or is_unit(p)})
    return out

def corpus_label_set(files):
    """The labels a corpus registers: the snapshot's and each unit's, each file read by the parser (corpus_labels)."""
    return {l for p in sorted(files) for l in corpus_labels(files[p])}

def labels_at(sha, overlay=None):
    return corpus_label_set(corpus_files(sha, overlay))

def unit_commits(sha):
    """{unit file: the last first-parent commit that added or changed it} of the corpus at `sha`, by git's log: the
    commit whose text of the unit file the store's answers of its labels are (its landing, or a hand edit in place since),
    the store's unit for them (freeze)."""
    out = {}
    argv = [a if a != "--diff-filter=A" else "--diff-filter=AM" for a in unit_log_argv()[1:]]
    for chunk in git("log", *argv, sha, "--", UNITS).split("\0"):
        ls = [l.strip() for l in chunk.split("\n") if l.strip()]
        if ls and re.fullmatch(r"[0-9a-f]{40}", ls[0]):
            out.update({p: ls[0] for p in ls[1:] if is_unit(p)})
    return out

def text_blob(text):
    """The git blob id of a corpus file's text (as git hash-object writes it)."""
    b = text.encode()
    return hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()

def label_sources(sha):
    """{label: (its source, its text's blob)} of the corpus at `sha`: for a unit's label the commit that added or last
    changed its unit file and that file's blob, for a snapshot label the store's bootstrap commit (oracle/bootstrap; None
    before one) and the snapshot's blob: what an index line must name for the store's answer to be this label's (R4, spec
    v14 V2: a stored answer serves only the TEXT it answered)."""
    files, adds = corpus_files(sha), unit_commits(sha)
    boot = open(os.path.join(ORACLE, "bootstrap")).read().split()[0] if os.path.exists(os.path.join(ORACLE, "bootstrap")) else None
    return {l: (adds.get(p) if is_unit(p) else boot, text_blob(files[p])) for p in sorted(files) for l in corpus_labels(files[p])}

def landed_labels(run, origin, idx):
    """The labels of `run` a measurement reads from the store: those origin's corpus registers whose index line, if it
    has one, names the source and the text origin registers it from (label_sources); a label whose line names another
    source or another text of its unit file (a snapshot case removed and its label registered again by a unit, a unit's
    label a later unit took, a unit file edited in place) is no landed label: it is added, answered fresh, and its
    freeze replaces the line. A snapshot label's text is the store key's (its `snapshot` field): an edit of the snapshot
    is the store's gap, located (oracle_read), never a mass of added labels. A landed label with no line is the store's
    gap, located (oracle_read), never answered fresh."""
    src = label_sources(origin)
    # a snapshot label's source is the store's bootstrap commit: a store whose index names it but which records no
    # bootstrap (oracle/bootstrap) cannot say whose answer the line holds, a located gap (D9), never an added label
    # answered fresh
    nob = sorted(l for l in run if l in src and src[l][0] is None and l in idx)
    if nob:
        raise OracleGap(f"oracle/index.tsv names {len(nob)} snapshot label(s), e.g. {nob[0]}, and the store records no bootstrap "
                        f"commit (oracle/bootstrap): whose answer each line holds cannot be checked; {REPLAY}")
    snap = text_blob(corpus_files(origin)[SNAPSHOT])
    return {l for l in run if l in src and (l not in idx or idx[l][0] == src[l][0] and (idx[l][2] == src[l][1] or src[l][1] == snap))}

def corpus_id(files):
    """One name for a corpus's bytes (the freeze checks a measurement's corpus is the landed commit's): the sha1 of each
    file's path and git blob."""
    blob = lambda t: sh(["git", "hash-object", "--stdin"], input=t, check=True).stdout.strip()
    return hashlib.sha1("".join(f"{p} {blob(files[p])}\n" for p in sorted(files)).encode()).hexdigest()

def write_corpus(d, files, log):
    """The corpus written into a judging directory or a tree: its files, and `units.log`, the log the judge orders the
    units by (WT_SMOKE_UNITS names it)."""
    for p, t in files.items():
        os.makedirs(os.path.dirname(os.path.join(d, p)), exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(d, p))
        with open(os.path.join(d, p), "w") as f:
            f.write(t)
    with open(os.path.join(d, "units.log"), "w") as f:
        f.write(log)
    return os.path.join(d, "units.log")

# the files each process of a measurement's after the compile reads, the judge's (G5 holds them to the base's but a
# runner): the run's (test/runner.jl, the judge's since spec v18 P2, which loads the verdict's module for its budget and the
# test suite's API, and the Node major ci.yml names; copied into the run's own directory, spec v17 Y1) and the
# verdict's (no runner, no node: spec v16 X1)
RUN_FILES = ("test/runner.jl", "test/verdict.jl", "test/oracle.jl", "test/oracle_read.jl", ".github/workflows/ci.yml")
VERDICT_FILES = ("test/verdict.jl", "test/oracle.jl", "test/oracle_read.jl", "test/fixtures/runner_raw.tsv")
# the runner's fixtures as the driver interleaves them (run_input), read by the driver alone: no process that runs a
# move's code is handed a file that tells a fixture from a case
FIXTURE_FILES = ("test/fixtures/runner_calls.tsv", "test/fixtures/runner_patch.tsv")
# what the run process reads besides its own directory and the `native` kind's (spec v17 Y1): node's OpenSSL
# configuration, which nodejs.org's build opens at start (probed: without it node exits "OpenSSL configuration error ...
# calling fopen(/System/Library/OpenSSL//openssl.cnf, rb)", every call `err node gave no answer`); a system file
RUN_READS = ("/System/Library/OpenSSL/openssl.cnf",)
# how many drawn fixtures a run adds to the frozen ones (spec v17 Y1): each identity this many times with drawn
# arguments, this many copies of the patched module (each slot drawn) and this many frozen calls again at random, so
# the trap, the wasm exception and every frozen call can fall anywhere among the cases
FIXTURE_DRAWS = 2

def run_input(mods, fixtures, rng):
    """THE run process's input and the verdict's plan of it (spec v17 Y1), from the compile's records `mods` (bytes) and
    the judge's fixtures (`fixtures`: {path: text} of FIXTURE_FILES), with `rng` (random.SystemRandom: the run cannot
    predict a draw). Every module (each case's, the frozen fixture module, FIXTURE_DRAWS copies of runner_patch.wat
    with each slot's constant drawn and written at its declared byte offset, no assembler) goes under a label drawn
    as every other's is (16 hex digits) and at a drawn place among the module records, each label's own in its order
    (a call names its label's j-th); the fixture calls (the frozen ones, the identities with drawn arguments, each
    patched slot and the patched module's trap and throw, FIXTURE_DRAWS frozen ones again) go at positions drawn among the compile's calls, which keep their
    order. The fixtures are the runner's regression test (spec v18 P2: the runner is the judge's, no move's), never a
    defence against a runner that adapts: a fixture call names an export (a case's names `-`) and its module is the
    frozen runner.wat or runner_patch.wat outside its slots, so a runner can tell them apart; the drawn positions and
    constants stay as a check of the runner's own marshalling.
    Returns (the input's text in the compile records' grammar, the plan's text: one line a run line, test/verdict.jl's
    `place` grammar; the wire a fixture must produce follows from its line by the verdict's own table)."""
    tok = lambda: f"{rng.getrandbits(64):016x}"
    labels, mrec, calls = {}, {}, []   # a label's token; a token's module texts, in order; (token, j, entry, args, plan)
    for ln in mods.decode().splitlines():
        f = ln.split("\t")
        if f[0] == "module" and len(f) >= 4:
            mrec.setdefault(labels.setdefault(f[1], tok()), []).append(f[3])
        elif f[0] == "call" and len(f) >= 4:
            calls.append((labels.setdefault(f[1], tok()), f[2], f[3], f[4:], f"case\t{len(calls) + 1}"))
    fixed, frozen = None, []
    for ln in fixtures["test/fixtures/runner_calls.tsv"].splitlines():
        f = ln.split("\t")
        if f[0] == "module":
            fixed = f[3]
        elif f[0] == "call":
            frozen.append((f[3], f[4:]))
    pmod, slots, fixed_ = None, [], []
    for ln in fixtures["test/fixtures/runner_patch.tsv"].splitlines():
        f = ln.split("\t")
        if f[0] == "module":
            pmod = base64.b64decode(f[1])
        elif f[0] == "slot":
            slots.append((f[1], int(f[2]), int(f[3]), f[4]))
        elif f[0] == "fixed":
            fixed_.append(f[1])
    if fixed is None or len(frozen) == 0 or pmod is None or not slots:
        raise ClimbError("the judge's fixtures (test/fixtures/runner_calls.tsv, runner_patch.tsv) hold no module or no call")
    tf = tok(); mrec[tf] = [fixed]
    fx = [(tf, "0", e, a, f"frozen\t{k}") for k, (e, a) in enumerate(frozen, 1)]
    fx += [(tf, "0", e, a, f"frozen\t{k}") for k in (rng.randrange(len(frozen)) + 1 for _ in range(FIXTURE_DRAWS))
           for e, a in [frozen[k - 1]]]
    for kind, width in (("i32", 32), ("i64", 64), ("f32", 32), ("f64", 64)):
        for _ in range(FIXTURE_DRAWS):
            arg = f"{kind}:{rng.getrandbits(width):0{width // 4}x}"
            fx.append((tf, "0", kind, [arg], f"ident\t{kind}\t{arg}"))
    for _ in range(FIXTURE_DRAWS):
        b, tp = bytearray(pmod), tok()
        for name, off, width, kind in slots:
            bits = rng.getrandbits(8 * width)
            b[off:off + width] = bits.to_bytes(width, "little")
            if name == "p_add":
                arg = f"i64:{rng.getrandbits(64):016x}"
                fx.append((tp, "0", name, [arg], f"patched\t{name}\t{bits:016x}\t{arg}"))
            else:
                fx.append((tp, "0", name, [], f"patched\t{name}\t{bits:0{2 * width}x}"))
        fx += [(tp, "0", name, [], f"patched\t{name}") for name in fixed_]   # a trap and a throw in the drawn bytes
        mrec[tp] = [base64.b64encode(bytes(b)).decode()]
    rng.shuffle(fx)
    at = set(rng.sample(range(len(calls) + len(fx)), len(fx)))
    it_c, it_f = iter(calls), iter(fx)
    order = [next(it_f) if i in at else next(it_c) for i in range(len(calls) + len(fx))]
    slots_ = [t for t, ms in mrec.items() for _ in ms]   # each module record's place drawn, its label's in order
    rng.shuffle(slots_)
    nth, text = {}, []
    for t in slots_:
        j = nth.get(t, 0); nth[t] = j + 1
        text.append(f"module\t{t}\t-\t{mrec[t][j]}\n")
    text += ["\t".join(["call", t, j, e, *a]) + "\n" for t, j, e, a, _ in order]
    return "".join(text), "".join(p + "\n" for *_, p in order)


def judge_files(sha, d, corpus=None, log=None, paths=None):
    """What a native, run or verdict process reads, taken from the main repository's objects (plumbing, R1) into a
    directory no candidate process writes: `paths` of `sha` (an answering process's: JUDGE_WRITE, the answering program;
    the run's RUN_FILES; the verdict's VERDICT_FILES), and `corpus` ({path: text}, the snapshot and the units the
    measurement measures: the commit's own, or a tail move's over its base) with `log`, the units' order (units.log), for
    a process that computes answers."""
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    piped(["git", "-C", REPO, "archive", sha, *paths], ["/usr/bin/tar", "-x", "-C", d], check=True)
    if corpus is not None:
        write_corpus(d, corpus, log)
    return d

def run_files_are_origins(sha):
    """Whether every file the run and its judgement read (RUN_FILES, FIXTURE_FILES, VERDICT_FILES) is, at `sha`, the same
    blob as at origin's head (spec v17 Y1): a fixture failure then is no move's."""
    paths = sorted(set(RUN_FILES) | set(FIXTURE_FILES) | set(VERDICT_FILES))
    at = lambda c: [git("rev-parse", f"{c}:{p}", check=False).strip() for p in paths]
    return at(sha) == at(f"origin/{MARCH}")

JUDGE_GAP_KIND_RE = re.compile(r"no leaf kind for (?:the argument type )?([^(;]+?) \(|(at most 3 arguments)")
RUNNER_GAP_KIND_RE = re.compile(r"(no entry|the runner passes no argument[^;(]*|the runner reads no result of [^;(]*|the module imports [^,;]+)")

GAPS = ("judge-gap", "runner-gap")   # the outcomes that are the judge's to read (spec v17 Y2, v18 P2)

def judge_gaps(rows):
    """The judge's gaps a measurement's rows hold (spec v17 Y2, v18 P2): `judge-gap` (the judge's wire has no leaf kind)
    and `runner-gap` (a shape the runner cannot call or read), each the lead's hand, no climber and no G1; read from the
    score's whole-corpus measurement alone (spec v19 P5: a candidate's subset is no set of the corpus's). One note
    when the SET of kinds changes (operator round 15 4: never the same set again every alarm_s), kept in the state's
    gap-kinds.json."""
    kinds = collections.defaultdict(list)
    for l, o, _, w in rows:
        if o in ("judge-gap", "runner-gap"):
            m = (JUDGE_GAP_KIND_RE if o == "judge-gap" else RUNNER_GAP_KIND_RE).search(w)
            kinds[f"{o}: " + (((m.group(1) or m.group(2) if o == "judge-gap" else m.group(1)) or "").strip() if m else "unnamed")].append(l)
    have = sorted(kinds)
    if have == state_json("gap-kinds.json", []):
        return
    save_json("gap-kinds.json", have)
    if kinds:
        for_dale(f"the judge's gaps changed: {len(have)} kind(s)", "\n".join(f"- {k}: {len(kinds[k])} case(s), e.g. {', '.join(kinds[k][:3])}"
                 for k in have) + "\nDefault taken: counted apart, no climber and no G1, until a new leaf kind or a marshalling "
                 "change (test/verdict.jl, test/runner.jl: the lead's hand) reads them.")

def run_allowance(tree, ncalls):
    """The run process's wall (spec v19 P2): case_min_s, then for each call the judge's own allowance, a hang's whole cost
    (test/verdict.jl's RUN_BUDGET, the call's, and test/runner.jl's NODE_START, a new node's start after it), read from
    the run's own copies at `tree`, never a number of the driver's (D5), so `ncalls` hanging calls in a row fit."""
    def const(path, name):
        m = re.search(rf"^const {name} = ([0-9.]+)\s*$", open(os.path.join(tree, path)).read(), re.M)
        if not m:
            raise ClimbError(f"{path} defines no `const {name} = <seconds>`: the run's allowance has no source")
        return float(m.group(1))
    return cfg()["case_min_s"] + ncalls * (const("test/verdict.jl", "RUN_BUDGET") + const("test/runner.jl", "NODE_START"))

def run_part_failed(sha, why, candidate=False):
    """The run part's failure (its lines missing or unreadable, or a fixture of the judge's failed): the runner's, a
    move's, as (None, why), or, while every file the run and its judgement read is origin's (run_files_are_origins), the
    infrastructure's (spec v17 Y1): one run-failed note and RunFailed, no move charged, no stop. A run that wrote no line
    on a `candidate` (spec v19 P2) is the candidate's, as a tree that does not load is: its modules are its only input
    that is not origin's."""
    if not run_files_are_origins(sha) or candidate:
        return None, why
    alarm("run-failed", "the run part fails on origin's own run files", f"{why[:1500]}\nDefault taken: the measurement "
          "is cut as the infrastructure's (no move charged, no stop); the node the run executes (TOP/tools/bin/node, "
          "door.pin_node: `door.py tools --fetch-node`) or the host is the suspect.")
    raise RunFailed(f"the run part failed on origin's run files: {why[:600]}")

def shape_records(blocks):
    """THE projection of stored answers onto what the compiling process is handed (spec v16 X1, test/oracle_read.jl's
    Shape and read_shapes): for each label's whole block (unit_blocks'), its `shape` record (the answer record without
    its arguments' and native's values: their count alone), each group's `sgroup` record (its type path, its leaves'
    capture kind, never a value, and their paths), its `digest`, or a bare `noanswer` (its why is the driver's to book).
    A scalar answer that is a type (a thrown exception's, a singleton's: spec v17 Y2) names that type, which its
    judge-built reader reads; any other answer `-`. Bytes, in label order."""
    out = []
    for label in sorted(blocks):
        ls = blocks[label].decode().split("\n")[:-1]
        f = ls[0].split("\t")
        if f[0] == "noanswer":
            out.append(f"noanswer\t{label}\n"); continue
        nk = f[6].split(",")[:2] if f[9] == "-" and f[6].split(",")[0] in ("throws", "void") else None
        out.append("\t".join(["shape", f[1], f[2], f[3], f[4], str(0 if f[5] == "-" else len(f[5].split(";"))), f[7], f[8], f[9],
                              ",".join(nk) if nk else "-"]) + "\n")
        i = 1
        while i < len(ls):
            g = ls[i].split("\t")
            if g[0] == "group":
                leaves = [x.split("\t") for x in ls[i + 1:i + 1 + int(g[4])]]
                kind = leaves[0][3].split(",")[0] if leaves else "opaque"
                out.append("\t".join(["sgroup", g[1], g[2], kind, g[3], g[4], ";".join(x[2] for x in leaves)]) + "\n")
                i += 1 + int(g[4])
            else:   # its digest, as stored
                out.append(ls[i] + "\n"); i += 1
    return "".join(out).encode()

class MeasureCut(ClimbError):
    """A measurement cut where no case of its own is in flight to book (its wall, or a process stalled between cases or
    before its first): never a result (D9, O8-1). Nothing of it is recorded: no row in the table, no S, no pass set,
    no learned time; its caller's failure is the driver's (infra), the label in flight and the labels not reached named."""

class RoleLost(MeasureCut):
    """A part that yielded (door.released) found its role used by another process meanwhile and cannot make its
    directories again: cut, never a result (spec v17 Y3)."""

class RunFailed(MeasureCut):
    """The run process failed the judge's fixtures while every file the run and its judgement read is origin's (spec v17
    Y1): the infrastructure's (its node, its host), never a move's; one note (run-failed), no move charged, no stop."""

def corpus_labels(text):
    """The labels a corpus file registers, read by the corpus loader's one reader of a registration
    (test/corpus_loader.jl --labels, the driver's own tree's, as the deps user in the `julia` profile), cached by the
    file's and the loader's hash: every label a measurement runs is one of these, so the driver names each process's
    labels exactly (WT_SMOKE_ONLY) and derives its wall from them. A list of labels, never a proof that the corpus
    loads, which the process that loads it gives (R8-1, R8-3)."""
    loader = open(os.path.join(ROOT, "test", "corpus_loader.jl")).read()
    key = hashlib.sha1((text + "\0" + loader).encode()).hexdigest()[:16]
    p = os.path.join(STATE, "corpus-labels", f"{key}.txt")
    if not os.path.exists(p):
        r = julia_job("deps", f"labels-{key}", {"corpus.jl": text, "corpus_loader.jl": loader},
                      ["julia", "--startup-file=no", "{in}/corpus_loader.jl", "--labels", "{in}/corpus.jl"], cfg()["parse_wall_s"])
        unread = [l for l in r[1].splitlines() if not l.startswith("label\t")]
        if r[0] != 0 or unread:
            raise ClimbError(f"the corpus {key}'s labels: " + (f"a line the loader's reader wrote that is no label: {unread[0][:200]}" if r[0] == 0 and unread
                                                              else (r[2] or r[1]).strip()[-300:]))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        write_atomic(p, "".join(l.split("\t", 1)[1] + "\n" for l in r[1].splitlines()))
    return open(p).read().split("\n")[:-1]

def label_file(d, labels):
    """WT_SMOKE_ONLY as a file in `d`: the labels a process runs, exactly (test/smoke.jl runs them sorted)."""
    if labels is None:
        return {}
    p = os.path.join(d, "wt_smoke_only.txt")
    write_atomic(p, "".join(f"{l}\n" for l in sorted(labels)))
    return {"WT_SMOKE_ONLY": p}

def case_secs(part):
    """{label: seconds} of `part` (compile, native) as the driver timed each case itself (R6-9): never a number the
    measured process reports. A label's seconds only grow (the longest the driver has seen it take), so a run that
    rejects a case at once never shortens the budget of a run that compiles it (A7-1); they are learned only from
    measurements of origin's own commits (learn())."""
    return state_json("case-secs.json", {}).get(part, {})

def learn(part, timed):
    """The driver's times of `part`'s cases kept in case-secs.json, each label at the longest seen. Its callers are
    measurements of origin's commits alone (a base, a score, confirmed()'s): a candidate, later rejected or slow, never
    teaches a budget (A8-2: one slow candidate taught a 1-s label 899 s, its budget 17,980 s for good)."""
    def up(cs):
        m = cs.setdefault(part, {})
        for l, s in timed.items():
            m[l] = max(m.get(l, 0.0), s)
    update_json("case-secs.json", {}, up)

def case_budget(c, secs, label, first, first_s):
    """A case's budget (A7-1, D9): the process's first case (`first`: it pays the load) and a label the driver has
    never timed get `first_s`, the first-run wall (pkg_wall_s), so a case is booked errored for time only past a budget
    the driver learned or past that wall; a label it timed gets max(case_min_s, case_factor x its longest seconds)."""
    return first_s if first or label not in secs else max(c["case_min_s"], c["case_factor"] * secs[label])

def part_wall(c, secs, labels, first_s):
    """A process's wall, derived (D17, O8-1): wall_factor x (first_s for its load + each label's learned seconds, first_s
    for one never learned), so the per-case budgets, never the wall, bound a healthy run of any size."""
    return c["wall_factor"] * (first_s + sum(secs.get(l, first_s) for l in labels or ()))

# a native process's records past its answer's band: the `started`, `loads`, `digest` and `ended` records around the
# answer's own (answer_cap_bytes bounds those). A bound with a band (D17): intent, a few KB (the loads record ~300 B, a
# digest ~40 B a write); band, 1 MiB, past which the drain refuses the process's records (spec v14 V4)
RECORD_MARGIN = 1 << 20

def drain(src, dst, cap, capped=None):
    """A judging process's stdout, its records, copied into `dst` (the driver's own file, in a run directory no build
    user writes) as it is written, at most `cap` bytes (answer_cap_bytes and RECORD_MARGIN: spec v14 V4, the band holds
    whatever the body writes): past it nothing more is read, held or stored, `capped["bytes"]` says so, and the watch
    refuses the case in flight, located (watched); a pipe is read in order and never rewritten (R8-1: a file of the
    process's own was rewritten in place at exit)."""
    n = 0
    with open(dst, "ab") as g:
        while chunk := os.read(src.fileno(), 1 << 16):
            if n + len(chunk) > cap:
                if capped is not None:
                    capped["bytes"] = n + len(chunk)
                return
            n += len(chunk)
            g.write(chunk); g.flush()

FRAME_KINDS = ("module", "rejected", "call", "compiled", "row")   # a compile's block: its module, rejected and call lines, then one end

def part_log(d, part):
    """The log a watched process's stdout and stderr go to, in its run directory `d`: a `native` profile names it among
    its reads (spec v17 Y1, probed as _wtm1: Julia under a profile that cannot read its stdout's file writes nothing to
    it, so the verdict's fixture failure, and every error of the run and the verdict, was never read)."""
    return os.path.join(d, f"{part}.log")

def watched(start, role, d, rel, part, labels, first_s, var=None, keep_done=False, yields=False, learn_=False, plan=None,
            frame=None, beside=None, rejoin=None):
    """One process of a measurement's role, watched case by case: the one watch function of its three roles (compile,
    native, compare; O6-9, R5-10, the rule that no hang is allowed). The process flushes `started <label>` before each
    case into its records (`var` names their file in its environment, read from the role's home, `rel`, through
    door.open_home; with `plan`, a judging process's stdout, drained into the driver's own file as it is written); the driver stamps each record with its own clock as it reads it and times each case from one
    record to the next (R6-9: a number the process reports is never a budget's input; a process's first case, which
    pays its load, is not timed), learned in case-secs.json by `part` only with `learn_` (a measurement of origin's
    commit). The driver gives the process its labels exactly (`labels`, WT_SMOKE_ONLY: every one a label of the corpus
    it loads, corpus_labels) and test/smoke.jl runs them sorted, so each `started` line names the label the driver
    expects next; a line naming any
    other label, one of the run already started or one out of that order is refused,
    the process reaped (R7-8, R7-9, R8-3), and the measurement fails as the measured code's. A case with no new record
    for its budget (case_budget()), or one in flight when its process ends (a crash, O9-3), is booked errored by name
    (`killed`), the process reaped, and the process started again without it and, with `keep_done` (a compile, whose records are kept part by part), without every case it finished; a
    process with no records (compare: node judges every module at once) gets `first_s`. A process with records that
    stalls at its load, before its first `started`, is the measured code's (its src or its corpus): its records refused,
    named (spec v11 R7). A cut where no case of its own
    is in flight (a process stalled before its first case or between two) and a process past its wall (part_wall,
    derived from the labels' learned seconds) is never a result: MeasureCut, naming the label in flight and the labels
    not reached (O8-1, A8-2). With `yields` (a compile), while the lander waits on the lock this measurement holds the
    process is reaped at a case's boundary and started again once the lander is done (yield_slot, ruling 1); the
    yielded wait and the restart's load up to its first record are outside its wall. The wait leaves the role's use
    (door.released, spec v17 Y3: no yield while a measuring role is held); when another use came between, `rejoin()`
    makes the part's run directory and home again before the restart, and with no `rejoin` the part is cut (RoleLost). With `plan` (a judging process,
    R8-1) each case's block, its `loads` record (the files its answering program loaded), its `answer` record and then its `group` and `leaf` records and a unit label's `digest`
    (test/smoke_judge.jl: its unit's load, which the compiling process compares with its own), or one `noanswer`, every one
    naming that case, is kept only when it stands between that case's `started` and the next `started` or `ended`, and
    is appended to plan["path"] then (plan["runs"] counts its records); a line outside its case's block is refused as a
    lie, a killed case's block is dropped, and nothing written after `ended`, or by a process that ended without it, is
    read: no code that runs at load, at another case's call or at exit writes a case's answer. With `frame` (a compile, R3: the judge's block rule on the
    compile side) each case's block, its `module` and `rejected` lines and then one `compiled` or `row` line, every one
    naming the case in flight, is appended to frame["path"] when its `compiled` or `row` line is read, as the driver
    reads it (never read again from the process's own file, which it can rewrite in place); any other line, one naming
    another label, one before the first `started` or one after its block's end (an atexit's), is refused as a lie, and
    a cut or yielded case's partial block is dropped. The records are read once more after the process exits. With
    `beside` (a list `start` fills with the processes it starts beside the watched one: an answer's second process,
    spec v16 X2) a process that ended its case is reaped only once each of them has exited, or the case's budget has
    passed, so the role's reap never cuts a pair's second process short.
    `start(env, log)` starts it. Returns (its output's tail, {label: budget} it killed, the number of processes, why the driver refused its records
    or None)."""
    c, kind, secs = cfg(), SLOT_KIND.get(role), case_secs(part)
    wall = part_wall(c, secs, labels, first_s)
    done, killed, n, t0, log, refused, timed = set(), {}, 0, door.CLOCK(), part_log(d, part), None, {}
    reload_t = None   # a restart after a yield: its load, up to its first record, is outside the wall (O8-1)
    elapsed = lambda: door.CLOCK() - t0 - (door.CLOCK() - reload_t if reload_t is not None else 0)
    stop = None
    while True:
        excl = (done if keep_done else set()) | set(killed)
        o = None if labels is None else set(labels) - excl
        expect = set(o or ())
        recs = f"{rel}/rec.{n}"; n += 1
        local = os.path.join(d, f"{os.path.basename(rel)}.rec.{n - 1}")   # a judging process's records, drained from its stdout
        with open(log, "a") as lf:
            p = start(dict(label_file(d, o), **({var: f"{door.home(role)}/{recs}"} if var else {}),
), lf)
        th, capped = None, {}
        if plan is not None:   # a native process's records, capped at its answer's band (spec v14 V4)
            th = threading.Thread(target=drain, args=(p.stdout, local, c["answer_cap_bytes"] + RECORD_MARGIN, capped), daemon=True); th.start()
        off, last, cur, t_last, cut, fin, gave, prev, seen = 0, None, None, door.CLOCK(), None, 0, False, "", set()
        blk, closed = None, False   # the open case's block [label, its lines, its head kind]; `ended` read
        fblk = None   # a compile's open block [label, its lines, ended]: a cut or yielded process's partial one dropped
        while True:
            alive = p.poll() is None
            if alive:
                time.sleep(c["watch_s"])
            try:   # the one tick (door.tick): the disk (R7-6) and the power (O8-3); its wall is the derived one, below
                door.tick(role, battery_ends=True)
            except door.Tick as e:
                p.wait()
                if e.why == "power":   # the power rule stopped work: the measurement ends, redone when work may run (on_ac); nothing it timed is learned
                    flight = last if last and last not in done else None
                    event("power-cut", role=role, part=part, in_flight=flight, after=max(done) if done else None)
                    raise PowerCut(f"the power rule stopped work (core.power_works: battery in Low Power Mode, under "
                                   f"battery_floor_pct, or with battery_runs off) while the {part} process ran (in flight: "
                                   f"{flight or 'no case, its load or between two'}): the measurement ends, redone when work may run")
                raise ClimbError(f"the {part} process: {e}")
            if not alive and th is not None:
                th.join(c["step_wall_s"])   # every byte it wrote before it ended, drained
            try:
                f = (open(local, "rb") if os.path.exists(local) else None) if plan is not None else door.open_home(role, recs) if var else None
            except door.DoorError as e:   # its records are no regular file: the process's own fault, never a wait (R6-1)
                door.reap(role); p.wait(); refused = str(e); break
            started_now, now_, lie = False, door.CLOCK(), None
            with f or contextlib.nullcontext():   # the new whole records alone
                for raw in ([] if f is None or closed else (f.seek(off), f)[1]):
                    if not raw.endswith(b"\n"):
                        break
                    off += len(raw); t_last = now_
                    if reload_t is not None:
                        t0 += now_ - reload_t; reload_t = None
                    r = raw.decode(errors="replace").rstrip("\n").split("\t", 2)
                    ends = r[0] in ("started", "ended") or (r[0] in ("compiled", "row", "case") and len(r) > 1 and cur and r[1] == cur[0])
                    if frame is not None and r[0] != "started":   # a compile's line: of the case in flight's block alone (R3)
                        nm = r[1] if len(r) > 1 else ""
                        if not (fblk and not fblk[2] and r[0] in FRAME_KINDS and nm == fblk[0]):
                            lie = (f"its `{r[0][:20]}` line {'names ' + nm[:120] if nm else ''} outside its case's block" +
                                   (" (after that block's `compiled` or `row`)" if fblk and fblk[2] and nm == fblk[0] else "")); break
                        fblk[1].write(raw)   # streamed, never whole in memory
                        if r[0] in ("compiled", "row"):   # its block is whole: kept, as the driver read it
                            fblk[1].close(); fblk[2] = True
                            with open(frame["path"], "ab") as mf, open(f"{frame['path']}.blk", "rb") as bf:
                                shutil.copyfileobj(bf, mf)
                    if frame is not None and r[0] == "started" and fblk and not fblk[2]:
                        lie = f"its block for {fblk[0][:120]} has no `compiled` or `row` before the next `started`"; break
                    if plan is not None and r[0] in ("started", "ended") and blk:   # its block is whole: kept
                        blk[1].close()
                        with open(plan["path"], "ab") as pf, open(f"{plan['path']}.blk", "rb") as bf:
                            shutil.copyfileobj(bf, pf)
                        plan["runs"] += blk[3]; blk = None
                    if plan is not None and r[0] not in ("started", "ended"):   # a line of the open case's block alone
                        if blk and len(r) > 1 and r[1] == blk[0] and (r[0] == "loads" and not blk[2] or
                                                                      r[0] in ("answer", "noanswer") and blk[2] in (None, "loads") or
                                                                      r[0] in ("group", "leaf", "digest") and blk[2] == "answer"):
                            # (`loads`, the files the answering program loaded, first: answer_labels checks and drops it)
                            blk[1].write(raw); blk[2] = r[0] if r[0] in ("loads", "answer", "noanswer") else blk[2]
                            blk[3] += r[0] != "loads"   # streamed, never whole in memory
                        else:
                            lie = f"its `{r[0][:20]}` line {'names ' + r[1][:120] if len(r) > 1 else ''} outside its case's block"; break
                    if ends and cur:   # the case before ends here: timed by the driver, its process's first case not
                        if cur[2]:
                            timed[cur[0]] = round(now_ - cur[1], 1)
                        done.add(cur[0]); fin += 1; cur = None
                    if r[0] == "started":
                        x = r[1].strip() if len(r) > 1 else ""
                        lie = "names no label" if not x else "names a label already started" if x in seen or x in killed \
                            else f"is out of the driver's order (after {prev})" if prev and x <= prev \
                            else None if x in expect else "names a label the run does not take"
                        if lie:
                            lie = f"its `started {x[:120]}` {lie}"; break
                        last, started_now, prev = x, True, x; seen.add(x)
                        cur = (last, now_, fin > 0)
                        blk = [x, open(f"{plan['path']}.blk", "wb"), None, 0] if plan is not None else None
                        if frame is not None:
                            fblk = [x, open(f"{frame['path']}.blk", "wb"), False]
                    elif r[0] == "ended":
                        last = None; closed = plan is not None   # nothing after it is read (R8-1)
                        if closed:
                            break
            if capped.get("bytes") and not lie:   # past the drain's cap: the case in flight refused, located; nothing more read
                door.reap(role); p.wait()
                flight = last if last and last not in done else None
                if flight is None:
                    refused = f"its records passed the driver's cap of {c['answer_cap_bytes'] + RECORD_MARGIN} bytes with no case in flight"
                else:
                    cut = (flight, f"its records passed the driver's cap of {c['answer_cap_bytes'] + RECORD_MARGIN} bytes "
                                   f"(answer_cap_bytes and a record's margin) at the drain")
                    event("case-over-cap", role=role, part=part, label=flight, bytes=capped["bytes"])
                break
            if lie:   # the process's own record is refused: reaped, and the measurement fails as the measured code's
                door.reap(role); p.wait(); refused = lie
                event("case-refused", role=role, part=part, why=lie[:300])
                break
            if closed:   # `ended` read: its answer is whole, and whatever it does after (an atexit) is never read (R8-1)
                for q in beside or ():   # a pair's second process: its own case, within the first's budget and wall, before the reap
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        q.wait(max(0.0, min(first_s, wall) - elapsed()))
                door.reap(role); p.wait()
                break
            if not alive:   # its records read once more after it ended: done, or the case in flight booked by name
                flight = last if last and last not in done else None
                if flight is not None:   # it ended during a case (a segfault, an abort, jetsam): that case errored, as a
                    cut = (flight, "the process ended during the case")   # hang is, and the process runs on without it (O9-3)
                    event("case-ended", role=role, part=part, label=flight, rc=p.returncode)
                break
            if yields and lander_waits(kind) and (last is None or started_now or last in done):   # a case's boundary
                door.reap(role); p.wait(); gave = True
                break
            budget = case_budget(c, secs, last, fin == 0, first_s) if last or not fin else c["case_min_s"]
            over = elapsed() > wall
            if door.CLOCK() - t_last > budget or over:
                door.reap(role); p.wait()
                flight = last if last and last not in done else None
                if (var or plan) is not None and not over and last is None and not done:   # stalled at its load, before its first case: the code it
                    # loads is the measured commit's (its src, its corpus), so the stall is the measured code's, booked
                    # as a refusal of its records, never the driver's own cut (spec v11 R7)
                    refused = f"the {part} process stalled at its load past {round(budget)} s, before its first case"
                    event("load-stall", role=role, part=part, budget=round(budget))
                elif over or flight is None:   # no case of its own to book: never a result (O8-1)
                    stop = {"part": part, "in_flight": flight, "after": max(done) if done else None, "wall": round(wall), "over_wall": over,
                            "not_reached": sorted(expect - done - {flight})}
                    event("measure-cut", role=role, **{k: v for k, v in stop.items() if k != "not_reached"},
                          not_reached=len(stop["not_reached"]), first=stop["not_reached"][:5])
                else:
                    cut = (flight, round(budget))
                    event("case-budget", role=role, part=part, label=flight, budget=round(budget))
                break
        if timed and learn_ and not stop and not refused:   # a process cut or refused teaches nothing (MeasureCut, O9-4)
            learn(part, timed)
        timed = {}
        if gave:   # the lander lands; this measurement goes on after it, its yielded time and the reload never its own
            with door.released(role) if role in door.HELD else contextlib.nullcontext({"lost": False}) as use:
                t0 += yield_slot(kind)
            if use["lost"]:   # another use of the role came between: this part's directories are gone
                if rejoin is None:
                    raise RoleLost(f"the {part} process of a measurement as {door.ROLES[role]} yielded, and another use of the "
                                   "role came between, which removed its run directory and home; nothing of it is recorded")
                rejoin()
            reload_t = door.CLOCK()
            continue
        if stop or refused or not cut:
            break
        killed[cut[0]] = cut[1]
    door.reap(role)
    if stop:
        raise MeasureCut(f"the {part} process of a measurement as {door.ROLES[role]} was cut " +
                         (f"past its wall of {stop['wall']} s" if stop["over_wall"] else "with no case of its own in flight") +
                         f": in flight {stop['in_flight'] or 'none'} (after {stop['after'] or 'none'}), {len(stop['not_reached'])} "
                         f"label(s) not reached ({', '.join(stop['not_reached'][:5])}); nothing of it is recorded")
    tail = log_excerpt(log)
    return tail, killed, n, refused

def killed_row(label, budget, part):
    """The driver's own row for a case it booked, located (D9): errored, its role named, and its budget (a case it
    killed) or why (`budget` a text: a process that ended during the case, O9-3)."""
    why = f"{part}: {budget} (the driver booked it)" if isinstance(budget, str) else \
        f"{part} past its budget: no record for {budget} s (the driver killed it)"
    return f"row\t{label}\terrored\t{0 if isinstance(budget, str) else budget}\t".encode() + base64.b64encode(why.encode()) + b"\n"

class Booked(bytes):
    """A driver-booked `noanswer` (a case killed past its budget, a process that failed, records the driver refused): the
    measurement's located gap for that label, NEVER stored (spec v16 X3, red 6: a timing or infrastructure artifact is
    no answer): oracle_write refuses it, so a freeze or a bootstrap leaves the label without an index line, answered
    again later (oracle_unanswered, at the next lander start; a resumed bootstrap). Only a body's own noanswer (over
    the cap, an answer that depends on its process, a value that does not read) is stored."""

def noanswer_row(label, budget, part):
    """The driver's own record for a judging process's case it booked (killed_row's, D9): no answer, located; Booked."""
    why = f"{part}: {budget} (the driver booked it)" if isinstance(budget, str) else \
        f"{part} past its budget: no record for {budget} s (the driver killed it)"
    return Booked(f"noanswer\t{label}\t".encode() + base64.b64encode(why.encode()) + b"\n")

def compile_watched(run, role, d, rel, labels, learn_, w, rejoin):
    """The compiling process (watched, a compile's records kept part by part): its records joined in `d`/modules.tsv as
    the driver reads them, each case's block whole and naming that case alone (watched's `frame`, R3: a line naming
    another case, or written after its block, is refused, and the measurement fails as the measured code's), each part
    through its last finished case (a case cut or yielded runs again whole), with the driver's own row for each case it
    killed. The records are kept in `w`, the driver's own directory (no build user's, and no use's: a yield may leave
    the role, whose next use removes its run directories, spec v17 Y3), `rejoin` making the part's directories again
    after a yield that lost them. Returns (its output's tail, why the driver refused its records or None)."""
    mods = os.path.join(w, "modules.tsv")
    open(mods, "wb").close()
    out, killed, n, refused = watched(run, role, d, rel, "compile", labels, cfg()["pkg_wall_s"], var="WT_SMOKE_COMPILED",
                                      keep_done=True, yields=True, learn_=learn_, frame={"path": mods}, rejoin=rejoin)
    if refused:
        return out, refused
    with open(mods, "ab") as f:
        for l, budget in killed.items():
            f.write(killed_row(l, budget, "compile"))
    return out, None

# ---------------------------------------------------------------- the oracle: native answers as frozen data
# HILL.md's oracle: a label's native answer is the answer computed from the corpus at the commit that added the label (for
# the corpus as it stood at the bootstrap: at the bootstrap commit), in a process of its own unit, recorded once by
# Dale's uid in $STATE/oracle, and read, never recomputed, by every later measurement. One file per unit,
# oracle/<unit commit>.tsv: its key line, then each label's records as test/oracle.jl writes them (answer, group and leaf,
# or noanswer); oracle/index.tsv names each label's unit and that unit file's sha256. A missing, unreadable or
# key-mismatched entry is a located failure of the measurement (D9), never a recompute from the live corpus.
ORACLE = os.path.join(STATE, "oracle")
ORACLE_INDEX = os.path.join(ORACLE, "index.tsv")
# ---- THE processes of a measurement (spec v16 X3), each declared once: its argv (after the door's own prefix, door.argv)
# and the environment it adds to the door's (door.base_env), `{...}` the run's own paths and numbers. The door's command
# is built from it (process()), so an edit of a process is an edit here; the answering process's also makes the store
# key's `env` field (answer_key_env) and is what its own record of what it ran with is checked against (loads_checked:
# its ARGS, its whole environment and its Julia options, by name). JULIA_DEPOT_PATH names exactly the two depots it reads,
# no trailing `:` (whose expansion Julia decides: probed, it appended its two bundled depots, local/share/julia and
# share/julia, never the user's ~/.julia): its own fresh depot, and Julia's bundled `share/julia` (bundled_depot), whose
# compiled stdlib caches hold Base64's (SHA is in the sysimage). Without the bundled depot Base64 is compiled, which
# spawns Julia's lld, and the `native` profile executes Julia alone (probed as _wtm1: "could not spawn …/lld")
ANSWER_PROCESS = {"argv": ("julia", "--startup-file=no", "{judge}/test/smoke_judge.jl"),
                  "env": {"JULIA_NUM_THREADS": "1", "JULIA_LOAD_PATH": "@stdlib", "JULIA_DEPOT_PATH": "{scratch}/depot:{bundled}",
                          "TMPDIR": "{scratch}/tmp", "WT_SMOKE_JUDGE": "1", "WT_SMOKE_ANSWER_CAP": "{answer_cap_bytes}",
                          "WT_SMOKE_UNITS": "{units}", "WT_SMOKE_ONLY": "{only}"}}
# the key's process: the answering process's argv and Julia, asked Julia's and the host's half of the key and what it ran
# with (test/smoke_judge.jl's WT_SMOKE_KEY), loading no corpus
KEY_PROCESS = {"argv": ANSWER_PROCESS["argv"],
               "env": {"JULIA_NUM_THREADS": "1", "JULIA_LOAD_PATH": "@stdlib", "JULIA_DEPOT_PATH": "{scratch}/depot:{bundled}",
                       "TMPDIR": "{scratch}/tmp", "WT_SMOKE_KEY": "1"}}
COMPILE_PROCESS = {"argv": ("julia", "--startup-file=no", "--project=.", "test/smoke.jl"),
                   "env": {"JULIA_NUM_THREADS": "1", "JULIA_DEPOT_PATH": "{scratch}/depot:{deps}:{top}/julia:", "TMPDIR": "{scratch}/tmp",
                           "WT_SMOKE_SHAPES": "{shapes}", "WT_SMOKE_UNITS": "{units}", "WT_SMOKE_ONLY": "{only}",
                           "WT_SMOKE_COMPILED": "{records}"}}
# the run (spec v17 Y1): its own directory alone (`{run}`: RUN_FILES under tree/, the calls run_input wrote), cwd tree/
# PATH is TOP/tools/bin alone: the profile executes nothing else, and a PATH entry it refuses fails Julia's own lookup
# (probed as _wtm1: `Sys.which("node")` threw EPERM stat-ing /opt/homebrew/bin/node, and the runner wrote no line)
RUN_PROCESS = {"argv": ("julia", "--startup-file=no", "test/runner.jl", "{run}/raw.tsv", "{run}/calls.tsv"),
               "env": {"JULIA_NUM_THREADS": "1", "JULIA_LOAD_PATH": "@stdlib", "JULIA_DEPOT_PATH": "{scratch}/depot:{bundled}", "TMPDIR": "{scratch}/tmp",
                       "PATH": "{top}/tools/bin"}}
VERDICT_PROCESS = {"argv": ("julia", "--startup-file=no", "test/verdict.jl"),
                   "env": {"JULIA_NUM_THREADS": "1", "JULIA_LOAD_PATH": "@stdlib", "JULIA_DEPOT_PATH": "{scratch}/depot:{bundled}",
                           "TMPDIR": "{scratch}/tmp", "WT_VERDICT_ANSWERS": "{judge}/answers.tsv",
                           "WT_VERDICT_MODULES": "{judge}/modules.tsv", "WT_VERDICT_RAW": "{judge}/raw.tsv",
                           "WT_VERDICT_PLAN": "{judge}/plan.tsv", "WT_VERDICT_CASES": "{scratch}/cases.tsv"}}

def julia_adds(role):
    """What a julia process the door starts adds to its own environment before any code of ours runs: Julia's loader sets
    OpenBLAS's two thread variables (probed: `env -i A=1 julia -e` prints A=1 and these; run as Dale it also printed
    macOS CoreFoundation's __CF_USER_TEXT_ENCODING, which a door process, with no Mach bootstrap, never gets: probed as
    _wtm1, the key process's own record named it missing). The same for every role."""
    return {"OPENBLAS_MAIN_FREE": "1", "OPENBLAS_DEFAULT_NUM_THREADS": "1"}

def bundled_depot():
    """Julia's own bundled depot, `share/julia` of the julia the door runs (TOP/tools/bin/julia's install): the one depot
    a stdlib-only process reads besides its fresh one (ANSWER_PROCESS's comment)."""
    return os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(f"{door.TOP}/tools/bin/julia"))), "share", "julia")

def process(decl, extra=None, **slots):
    """(argv, env) of a declared process, each `{...}` slot filled from `slots` (a slot not given is a KeyError, named;
    `bundled`, Julia's bundled depot, filled here), `extra` ({name: value}) the one variation a pair's second process
    adds (PAIR_VAR)."""
    slots.setdefault("bundled", bundled_depot())
    fill = lambda v: v.format_map(slots)
    return [fill(a) for a in decl["argv"]], dict({k: fill(v) for k, v in decl["env"].items()}, **(extra or {}))

def answer_key_env():
    """The store key's `env` field (spec v16 X3): the answering process as declared, its argv and its whole environment
    (door.base_env's, its role's home and user named, then ANSWER_PROCESS's, its paths named and its numbers filled), one
    text: an edit of the answering process, or of what the door gives every process, is a key change."""
    fixed = {k: "{home}" if k == "HOME" else "{user}" if k in ("USER", "LOGNAME") else v
             for k, v in door.base_env("measure").items() if k != "TMPDIR"}
    env = dict(fixed, **{k: v.replace("{answer_cap_bytes}", str(cfg()["answer_cap_bytes"])) for k, v in ANSWER_PROCESS["env"].items()})
    return "argv=" + " ".join(ANSWER_PROCESS["argv"]) + "; " + " ".join(f"{k}={v}" for k, v in sorted(env.items()))

class SrcVoid(ClimbError):
    """A src-test process whose records are void (its judge's canary read wrong or is missing, or its exit status
    disagrees with its rows, A13-5), naming the files it ran: a red of the PROCESS, located as a red is (spec v17 Z3,
    the round-14 operator's finding 3): src_void_split narrows it to the file whose presence voids it, src_locate locates
    that file over commits."""
    def __init__(self, why, files):
        super().__init__(why)
        self.files = files

class OracleGap(ClimbError):
    """A label the store does not answer, located: no entry, a unit whose bytes are not the index's, or one whose key is
    not this measurement's (D9). Never a recompute."""

# the one command that renews the store after a key change (V5), named by every gap
REPLAY = "pause the climb, then `python3 dev/climb/climb.py oracle-replay` renews the whole store under the new key"

def oracle_index():
    """{label: (unit, sha256, blob)} of oracle/index.tsv: the store's unit holding the label's answer, that unit file's
    sha256, and the blob of the corpus file whose text it answered (the snapshot's or its unit file's, spec v14 V2); a
    line that does not read is a gap of the whole store, located."""
    if not os.path.exists(ORACLE_INDEX):
        return {}
    out = {}
    for n, l in enumerate(open(ORACLE_INDEX).read().splitlines(), 1):
        f = l.split("\t")
        if len(f) != 4 or not re.fullmatch(r"[0-9a-f]{40}", f[1]) or not re.fullmatch(r"[0-9a-f]{64}", f[2]) or \
                not re.fullmatch(r"[0-9a-f]{40}", f[3]):
            raise OracleGap(f"oracle/index.tsv line {n} does not read as `<label> <unit> <sha256> <blob>`: {l[:120]}; {REPLAY}")
        out[f[0]] = (f[1], f[2], f[3])
    return out

def judge_id(sha):
    """The judge's key a row is judged under (spec v17 Y4): the sha1 of each judge file's path and blob at `sha`, the
    answering program's and the verdict's (JUDGE_WRITE, JUDGE_READ, in order; a path `sha` does not hold names `-`), so
    any edit of the judge makes every row a rebase, never a landing's loss; and the launch's tools (the state's tools.json:
    Julia's build, node's version and sha256, spec v18 P4), so a tool change is the same rebase, one rule."""
    return hashlib.sha1(("".join(f"{p} {git('rev-parse', f'{sha}:{p}', check=False).strip() or '-'}\n"
                                 for p in (*JUDGE_WRITE, *JUDGE_READ)) +
                         "tools " + json.dumps(state_json("tools.json", {}), sort_keys=True) + "\n").encode()).hexdigest()

def answer_hash(block):
    """A stored answer's hash as a row names it (spec v17 Y4): the sha1 of its block's bytes, `noanswer:` before it
    for a stored noanswer, which G2 never counts."""
    return ("noanswer:" if block.startswith(b"noanswer\t") else "") + hashlib.sha1(block).hexdigest()

def judge_key(sha):
    """The store key's `judge` field at `sha`: the sha1 of each answering-program file's path and git blob (JUDGE_WRITE,
    in order), so an edit of any of them (the judging entry, the capture, the loader) is a key change, a located gap
    naming this field (spec v14 V2)."""
    blobs = []
    for p in JUDGE_WRITE:
        b = git("rev-parse", f"{sha}:{p}", check=False).strip()
        if not re.fullmatch(r"[0-9a-f]{40}", b):
            raise ClimbError(f"{sha[:10]} has no {p}: no native answer is read or written for it")
        blobs.append(f"{p} {b}\n")
    return hashlib.sha1("".join(blobs).encode()).hexdigest()

def oracle_key(sha, julia_host):
    """The key a measurement of `sha` reads the store under: the answering program's files at `sha` (judge_key: a runner,
    decoder or compiling-side change stales nothing), Julia and the host as a process that loads no corpus printed them
    (`julia_host`), the answering process as declared (answer_key_env), and the snapshot's blob at `sha` (a snapshot
    edit is a key change, Dale's rare act)."""
    snap = git("rev-parse", f"{sha}:{SNAPSHOT}", check=False).strip()
    return {"judge": judge_key(sha), "julia": julia_host[0], "host": julia_host[1], "env": answer_key_env(), "snapshot": snap}

KEY_FIELDS = ("judge", "julia", "host", "env", "snapshot")

def key_line(key, tail):
    """A store file's key line: `key`, KEY_FIELDS in order, then `tail` (a unit's commit, a partial file's judge, a kept
    measurement's corpus id)."""
    return "\t".join(["key", *(key[k] for k in KEY_FIELDS), tail]) + "\n"

def read_key(line):
    """(key, tail) of a key line (key_line's), or None when it is none."""
    f = line.rstrip("\n").split("\t")
    return (dict(zip(KEY_FIELDS, f[1:-1])), f[-1]) if f[0] == "key" and len(f) == len(KEY_FIELDS) + 2 else None

def store_judge():
    """THE judge of the store (R7): the commit whose test/oracle.jl keys every store write, origin's, the one every
    measurement reads the store under (oracle_key of a measured commit whose test/oracle.jl no move changes: G5). The
    freeze, a replay, the audit and the bootstrap all take it, so no write is keyed by another commit's capture (a
    replay of a unit commit keyed by that commit's own test/oracle.jl was a gap in every measurement after an edit of it)."""
    return git("rev-parse", f"origin/{MARCH}")

def unit_blocks(data, chunks=False):
    """THE reader of answer records, in Python (R5; test/runner.jl's read_answers reads the same records by the same
    counts): {label: its block (bytes, each line ending in a newline)} of an answers file, a unit's body or the
    bootstrap's partial file, in order, linear (each block's lines kept in a list and joined once, never `+=`). A block is
    whole when it is a `noanswer` record alone, or an `answer` record (its tenth field the count of its groups, `-` for
    none), then exactly that many `group` records each followed by exactly the `leaf` records its fifth field counts, then
    at most one `digest` record (a unit label's: its load's digest), every record naming the label; a line with no final
    newline (an append cut), a block short of a count, one holding a record of another kind or label, and a record outside
    any block are not whole: dropped, never read as an answer and never glued to the next (its label is unanswered, and a
    bootstrap answers it again). With `chunks` (the bootstrap's partial file) a block is whole only when the line after it
    is `answered <label> <n>`, n its records, which the bootstrap appends after each label's records. A label named by two
    whole blocks is refused, located. Returns {label: block}, and with `chunks` also the offset just past the last whole
    chunk (where a resumed bootstrap truncates before it appends)."""
    out, end, pos = {}, 0, 0
    cur, lines, groups, leaves, digested, ok = None, [], 0, 0, False, False
    def close():   # the open block, kept only when whole (and, with chunks, its `answered` line read)
        nonlocal cur, lines
        if cur is not None and ok and groups == 0 and leaves == 0 and not chunks:
            keep(cur, lines)
        cur, lines = None, []
    def keep(label, ls):
        if label in out:
            raise OracleGap(f"the answers name {label} twice")
        out[label] = b"".join(ls)
    for raw in data.splitlines(keepends=True):
        pos += len(raw)
        if not raw.endswith(b"\n"):   # an append cut inside a record: dropped with its block
            cur, lines, ok = None, [], False; break
        f = raw[:-1].split(b"\t")
        k, lab = f[0], (f[1].decode(errors="replace") if len(f) > 1 else None)
        if k in (b"answer", b"noanswer"):
            close()
            cur, lines, digested = lab, [raw], False
            if k == b"noanswer":
                groups, leaves, ok = 0, 0, len(f) >= 2
            else:
                ok = len(f) == 10 and (f[9] == b"-" or f[9].isdigit())
                groups, leaves = (0 if f[9] == b"-" else int(f[9])) if ok else 0, 0
        elif cur is not None and lab == cur and k == b"group" and ok and lines[0].startswith(b"answer\t") and groups > 0 \
                and leaves == 0 and not digested and len(f) == 5 and f[4].isdigit():
            groups, leaves = groups - 1, int(f[4]); lines.append(raw)
        elif cur is not None and lab == cur and k == b"leaf" and ok and leaves > 0 and len(f) == 4:
            leaves -= 1; lines.append(raw)
        elif cur is not None and lab == cur and k == b"digest" and ok and lines[0].startswith(b"answer\t") and groups == 0 \
                and leaves == 0 and not digested and len(f) == 5:
            digested = True; lines.append(raw)
        elif chunks and k == b"answered" and cur is not None and lab == cur and len(f) == 3 and f[2] == str(len(lines)).encode():
            if ok and groups == 0 and leaves == 0:
                keep(cur, lines); end = pos
            cur, lines, ok = None, [], False
        elif k == b"key" and cur is None and not out:
            end = pos   # a file's key line, first
        else:   # a record outside its label's block, or one that breaks it: the block is not whole
            cur, lines, ok = None, [], False
    close()
    return (out, end) if chunks else out

EDGE_BLOCKS = os.path.join(ROOT, "test", "src", "oracle_edge_blocks.tsv")

def reader_rows(path=EDGE_BLOCKS):
    """door-probe's rows of the one wholeness rule (spec v14 V4): each case of test/src/oracle_edge_blocks.tsv (written by
    test/oracle.jl's own writer; test/src/oracle_read.jl reads the same cases with read_answers) read alone by unit_blocks,
    which must give label e/a the case's verdict: whole, dropped or refused. Returns [(check, ok, evidence)]."""
    cases, cur = [], None
    for l in open(path, encoding="utf-8").read().splitlines():
        if l.startswith("#"):
            continue
        f = l.split("\t")
        if f[0] == "case":
            cur = [f[1], f[2], []]; cases.append(cur)
        else:
            cur[2].append(l)
    rows = []
    for name, verdict, ls in cases:
        data = ("\n".join(ls) + ("" if name == "cut" else "\n")).encode()
        try:
            got = "whole" if "e/a" in unit_blocks(data) else "dropped"
        except OracleGap:
            got = "refused"
        rows.append((f"the reader of answer records: edge block {name} is {verdict}", got == verdict, f"unit_blocks: {got}"))
    return rows

def oracle_read(labels, key):
    """({label: its stored records}, {label: why it has none}) for `labels` under `key`: each label's unit named by the
    index, its bytes checked against the index's sha256 and its key line against `key`, field by field."""
    idx, units, got, gaps = oracle_index(), {}, {}, {}
    for l in sorted(labels):
        if l not in idx:
            gaps[l] = "no frozen answer: oracle/index.tsv names no unit for it"; continue
        u, h, _ = idx[l]
        if u not in units:
            p = os.path.join(ORACLE, f"{u}.tsv")
            try:
                data = open(p, "rb").read()
            except OSError as e:
                units[u] = f"its unit oracle/{u}.tsv does not read ({e.strerror})"; data = None
            if data is not None:
                if hashlib.sha256(data).hexdigest() != h:
                    units[u] = f"its unit oracle/{u[:12]}.tsv is not the bytes the index names (sha256 mismatch)"
                else:
                    have = (read_key(data.split(b"\n", 1)[0].decode(errors="replace")) or ({}, None))[0]
                    diff = [k for k in KEY_FIELDS if have.get(k) != key[k]]
                    units[u] = (f"its unit {u[:12]}'s answers are for {', '.join(f'{k} {have.get(k)!r}' for k in diff)}; this "
                                f"measurement runs {', '.join(f'{k} {key[k]!r}' for k in diff)}: {REPLAY}") if diff else unit_blocks(data.split(b"\n", 1)[1])
        b = units[u]
        if isinstance(b, str):
            gaps[l] = b
        elif l not in b:
            gaps[l] = f"its unit {u[:12]} holds no records for it"
        else:
            got[l] = b[l]
    return got, gaps

def added_labels(c):
    """{label: its text's blob} of the labels whose answers are commit `c`'s unit: those of the unit files `c` adds or
    changes (label_sources: their source is `c`). A snapshot label is never one: the snapshot is the store key's (an edit
    of it is a key change and a replay of the whole store, oracle-replay)."""
    return {l: b for l, (src, b) in label_sources(c).items() if src == c}

def freeze(full, keep=None, role="measure"):
    """The unit of landed commit `full`: the labels it adds, answered from `keep` (a measurement's records of them, which
    smoke() wrote with its key and corpus) when that measurement's corpus is `full`'s and its key's capture the store
    judge's, else by a replay (answer_labels on `full`'s corpus, the store's judge: store_judge), written by oracle_write;
    a commit whose labels the index already names its unit for is frozen already, no process run. Returns the commit's
    added labels."""
    added = added_labels(full)
    labels = sorted(added)
    idx = oracle_index()
    todo = [l for l in labels if idx.get(l, ("",))[0] != full]   # the labels its unit does not hold yet (booked before)
    if not todo:   # nothing to add, or frozen already: once
        return labels
    blocks, key, source = {}, None, "measured"
    if keep and os.path.exists(keep):
        data = open(keep, "rb").read()
        k = read_key(data.split(b"\n", 1)[0].decode(errors="replace"))
        if k and k[1] == corpus_id(corpus_files(full)) and k[0]["judge"] == judge_key(store_judge()):
            key, blocks = k[0], unit_blocks(data.split(b"\n", 1)[1])
    need = [l for l in todo if l not in blocks]
    if key is None or need:   # no measurement of this corpus holds them: the definition, replayed for the labels it lacks
        with contextlib.nullcontext() if "verify" in HELD_SLOT else julia_slot("verify", first=True):   # never beside a measurement
            # a label whose process fails is booked noanswer with why (failed="book"): the item leaves the queue, and the
            # label, never stored (Booked), is the located gap of every measurement until oracle_unanswered answers it
            # again at the next lander start (spec v16 X3, red 6; round12-operator 7)
            got, k2 = answer_labels(role, full, store_judge(), need if key is not None else todo, f"oracle-freeze-{full[:8]}", failed="book")
            if key is not None and k2 != key:
                raise ClimbError(f"the freeze of {full[:12]}: its replay answered under {k2}, its measurement's records under {key}")
            key, source = k2, "replay"
            blocks.update(got)
    booked = sorted(l for l in todo if isinstance(blocks.get(l), Booked))
    if booked:
        event("oracle-booked", commit=full[:12], labels=len(booked), first=booked[0])
    keepn = {l: blocks[l] for l in todo if l not in booked}
    if keepn:
        oracle_write(full, keepn, key, added)
    event("oracle-frozen", commit=full[:12], labels=len(keepn), booked=len(booked), source=source)
    return labels

def oracle_unanswered(origin):
    """The labels of origin's corpus the store does not answer as origin registers them (no index line, or one naming
    another source or text: landed_labels' rule), each with the commit whose unit would answer it, its source ({label:
    commit}); a snapshot label the store does not hold is the bootstrap's own gap (None)."""
    idx, src = oracle_index(), label_sources(origin)
    have = landed_labels(set(src), origin, idx) & set(idx)
    snap = text_blob(corpus_files(origin)[SNAPSHOT])
    return {l: (None if b == snap else c) for l, (c, b) in src.items() if l not in have}

def oracle_drop(labels):
    """The index lines of `labels` removed (the reconcile: labels origin's corpus no longer registers), written whole
    (write_atomic); their units' files keep their bytes, which the remaining lines still name by sha256."""
    idx = oracle_index()
    gone = sorted(set(labels) & set(idx))
    if gone:
        write_atomic(ORACLE_INDEX, "".join(f"{l}\t{u}\t{s}\t{b}\n" for l, (u, s, b) in sorted(idx.items()) if l not in gone))
        event("oracle-dropped", labels=len(gone), first=gone[0])
    return gone

def oracle_write(unit, blocks, key, blobs, replace=False):
    """The unit of commit `unit`: {label: records} with `key` (and the unit commit) as its key line, written whole and
    fsynced, then the index lines for its labels (write_atomic), each with `blobs[label]`, the blob of the corpus file
    whose text it answered. A driver-booked noanswer (Booked) is never stored: refused here, the one writer (spec v16
    X3). A unit already present with the same bytes is no change; one under the same key whose every label's records
    are these grows by the labels it lacked (a label booked at its freeze, answered later); any other is refused, but
    with `replace` (a replay: a deliberate act, under the verify lock)."""
    booked = sorted(l for l, b in blocks.items() if isinstance(b, Booked))
    if booked:
        raise ClimbError(f"oracle_write: {len(booked)} driver-booked noanswer(s) ({', '.join(booked[:3])}) offered to oracle/{unit[:12]}.tsv; "
                         "a booked label is no answer and is never stored")
    os.makedirs(ORACLE, exist_ok=True)
    p = os.path.join(ORACLE, f"{unit}.tsv")
    old = open(p, "rb").read() if os.path.exists(p) else None
    if old is not None and not replace:
        head, _, body = old.partition(b"\n")
        have = unit_blocks(body) if head + b"\n" == key_line(key, unit).encode() else None
        if have is None or any(blocks.get(l, b) != b for l, b in have.items()):
            raise ClimbError(f"oracle/{unit[:12]}.tsv holds other answers: a unit is written once (a replay replaces it)")
        blocks = dict(have, **blocks)   # its own answers, and the labels it lacked (booked at its freeze, answered since)
    data = key_line(key, unit).encode() + b"".join(blocks[l] for l in sorted(blocks))
    h = hashlib.sha256(data).hexdigest()
    if data != old:
        tmp = f"{p}.tmp-{os.getpid()}"
        with open(tmp, "wb") as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, p)
    idx = oracle_index()
    idx.update({l: (unit, h, blobs[l] if l in blobs else idx[l][2]) for l in blocks})
    write_atomic(ORACLE_INDEX, "".join(f"{l}\t{u}\t{s}\t{b}\n" for l, (u, s, b) in sorted(idx.items())))
    event("oracle-unit", unit=unit[:12], labels=len(blocks), bytes=len(data))
    return h

def julia_host(role, d, dh, jd):
    """(julia, host, its Julia options) as a process of `role` that loads no corpus and no src prints them
    (test/smoke_judge.jl's WT_SMOKE_KEY, test/oracle.jl's oracle_key), in the `native` profile, the declared KEY_PROCESS:
    the half of the store's key a measurement checks, and the Julia options its argv gives (each answering process's
    are checked against them, loads_checked), the process's own record of what it ran with checked against its
    declaration first."""
    door.run(role, ["/bin/mkdir", "-p", f"{dh}/key/tmp"], cfg()["step_wall_s"], profile=door.NONE)
    prof = door.profile(f"{d}/key.sb", [f"{dh}/key"], kind="native", reads=[jd])
    argv, env = process(KEY_PROCESS, judge=jd, scratch=f"{dh}/key")
    r = door.run(role, argv, cfg()["step_wall_s"], cwd=jd, profile=prof, env=env)
    f = r[1].strip().split("\t")
    if r[0] != 0 or len(f) != 3 or not f[0].startswith("julia=") or not f[1].startswith("host="):
        raise ClimbError(f"the oracle's key process: {(r[2] or r[1]).strip()[-300:]}")
    ran, why = read_ran(f[2])
    why = why or ran_differs(ran, dict(door.process_env(role, env, jd), **julia_adds(role)), None, argv[2])
    if why:
        raise ClimbError(f"the oracle's key process ran otherwise than declared (KEY_PROCESS): {why}")
    return f[0], f[1], ran["opt"]

def answer_labels(role, corpus_at, judge_at, labels, task, overlay=None, each=None, failed="raise"):
    """THE one definition of a native answer (HILL.md, the oracle; a gate, a rebased check, a freeze, a replay, the audit
    and the bootstrap all call it, per label): for each of `labels`, one fresh process of `role` in the `native` profile
    whose judging directory holds the judge at `judge_at` and the corpus at `corpus_at` (`overlay`, {path: text}, laid
    over it: a tail move's units at its base) reduced to the snapshot and, for a unit's label, that label's unit alone,
    which loads them, calls that one case once at its world, writes its one record and exits (test/smoke_judge.jl, the judging
    process, which takes exactly one label). So no other case's body runs before or beside it, in any process that
    answers it. A case killed past its budget, or in flight when its process ended, gets the driver's own `noanswer`,
    located; a process that ended before its label, with none in flight (its load failed), is a ClimbError: no answer
    is written from it. `each(label, records, key)`, when given, is called as each label is answered (the bootstrap
    appends it then: a kill loses at most the label in flight). With `failed` "book" (a freeze, spec v14 V5) a label
    whose process fails (its records refused, its answering program not the keyed one, its load failing before its case)
    is booked `noanswer` with that reason, located, never a failure of the whole call. Every label is answered by TWO
    fresh processes run at once (spec v16 X2; precedent(reproducible builds: Debian's reprotest varies what a build
    must not read)), the second varied in what a fair test must not read: another cwd, its own pid and clock by nature,
    one more environment variable than the key holds (PAIR_VAR), its units' file at another path and its own depot and
    scratch; each must load exactly the keyed program (`loads_checked`), and their records must be byte-equal, else
    the label is the body's own `noanswer`, "its answer depends on its process", located. Returns ({label: its records}, the key: test/oracle.jl's
    blob at `judge_at`, and Julia and the host as a process that loads no corpus printed them)."""
    files, log = corpus_files(corpus_at, overlay), unit_log(corpus_at)
    owner = {l: p for p in sorted(files) for l in corpus_labels(files[p])}
    program = {p: git("rev-parse", f"{judge_at}:{p}") for p in JUDGE_WRITE}   # the answering program, by blob
    out, key = {}, None
    with door.using(role):
        d = door.give(role, f"{role}-{task}")
        dh = f"{door.home(role)}/m/{task}"
        for i, l in enumerate(sorted(labels)):   # (each label's records drained into a file of its own: n<i>.rec.*)
            if l not in owner:
                raise ClimbError(f"{l}: the corpus at {corpus_at[:10]} registers no such label")
            door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/m" && mkdir -p "$1/n/tmp" "$1/n2/tmp"', "sh", dh], cfg()["step_wall_s"], profile=door.NONE)
            jd = judge_files(judge_at, f"{d}/judge", {p: files[p] for p in {SNAPSHOT, owner[l]}}, log, paths=JUDGE_WRITE)
            if key is None:
                jh = julia_host(role, d, dh, jd)
                key, opts = oracle_key(judge_at, jh), jh[2]
            # the pair's second process reads its units' file at another path (the same bytes)
            os.makedirs(f"{d}/pair", exist_ok=True); shutil.copyfile(f"{jd}/units.log", f"{d}/pair/units.log")
            # one profile a process (spec v17 Y4, red 8d): each writes and reads its own scratch alone (and the judge's
            # files, its labels and its log), so neither can hand the other a draw
            prof = door.profile(f"{d}/n.sb", [f"{dh}/n"], kind="native", reads=[jd, f"{d}/wt_smoke_only.txt", part_log(d, "native")])
            prof2 = door.profile(f"{d}/n2.sb", [f"{dh}/n2"], kind="native", reads=[jd, f"{d}/wt_smoke_only.txt", f"{d}/pair", part_log(d, "native")])
            plan = {"path": f"{d}/answers.tsv", "runs": 0}
            open(plan["path"], "w").close()
            second, pairs, declared = [], [], {}
            def start(e, lg):   # the two processes of a label at once: the watched one, and its varied second beside it
                if set(e) != {"WT_SMOKE_ONLY"}:
                    raise ClimbError(f"a judging process is handed {sorted(e)}, where its declaration takes WT_SMOKE_ONLY alone")
                slots = dict(judge=jd, answer_cap_bytes=cfg()["answer_cap_bytes"], only=e["WT_SMOKE_ONLY"])
                first_ = process(ANSWER_PROCESS, scratch=f"{dh}/n", units=f"{jd}/units.log", **slots)
                second_ = process(ANSWER_PROCESS, dict(PAIR_ENV, HOME=f"{dh}/n2"), scratch=f"{dh}/n2", units=f"{d}/pair/units.log", **slots)
                declared.update(first=(dict(door.process_env(role, first_[1], jd), **julia_adds(role)), first_[0][2]),
                                second=(dict(door.process_env(role, second_[1], f"{dh}/n2"), **julia_adds(role)), second_[0][2]))
                second.clear(); pairs.append(f"{d}/answers.pair.{len(pairs)}")   # a file a start: a reaped one's drain ends apart
                pair = pairs[-1]; open(pair, "w").close()
                q = door.popen(role, second_[0], cwd=f"{dh}/n2", profile=prof2, stdout=subprocess.PIPE, stderr=lg,
                               background=cfg()["oracle_background"], env=second_[1])
                second.append(q)
                threading.Thread(target=drain, args=(q.stdout, pair, cfg()["answer_cap_bytes"] + RECORD_MARGIN), daemon=True).start()
                return door.popen(role, first_[0], cwd=jd, profile=prof, stdout=subprocess.PIPE, stderr=lg,
                                  background=cfg()["oracle_background"], env=first_[1])
            tail, killed, _, why = watched(start, role, d, f"m/{task}/n{i}", "native", {l}, cfg()["pkg_wall_s"], plan=plan, beside=second)
            def fail(text):   # a label whose process failed: the call's failure, or (a freeze) the label's Booked noanswer
                if failed != "book":
                    raise ClimbError(f"the native process of {l} ({task}): {text}")
                event("answer-booked", label=l, task=task, why=text[:300])
                return {l: noanswer_row(l, text, "native")}
            data, blocks = open(plan["path"], "rb").read(), None
            if why:
                blocks = fail(f"the driver refused its records: {why}")
            elif l not in killed:   # the answering program it ran is exactly the keyed files, the snapshot and its unit
                want = dict(program, **{p: text_blob(files[p]) for p in {SNAPSHOT, owner[l]}})
                data, lwhy = loads_checked(data, l, want, (*declared["first"][:1], opts, declared["first"][1]))
                if lwhy:
                    blocks = fail(lwhy)
                elif data:   # the second process: the same program loaded, and the same records, byte for byte
                    other, pwhy = pair_block(open(pairs[-1], "rb").read(), l)
                    if pwhy is not None:   # it ended without its case: the one rule for either process (spec v17 Y4)
                        blocks = {l: ended_without(l, f"its second process: {pwhy}", task)}
                    else:
                        other, pwhy = loads_checked(other, l, want, (*declared["second"][:1], opts, declared["second"][1]))
                    if blocks is None and pwhy is not None:
                        blocks = fail(f"its second process: {pwhy}")
                    elif blocks is None and other != data:
                        a_, b_ = data.split(b"\n"), other.split(b"\n")
                        k = next(j for j in range(max(len(a_), len(b_))) if j >= len(a_) or j >= len(b_) or a_[j] != b_[j])
                        fa, fb = (a_[k] if k < len(a_) else b"").split(b"\t"), (b_[k] if k < len(b_) else b"").split(b"\t")
                        m = next((j for j in range(max(len(fa), len(fb))) if j >= len(fa) or j >= len(fb) or fa[j] != fb[j]), 0)
                        at = lambda fs: fs[m][:120].decode(errors="replace") if m < len(fs) else "(none)"
                        blocks = {l: f"noanswer\t{l}\t".encode() + base64.b64encode(
                            (f"its answer depends on its process: two processes (the second in another cwd, with {PAIR_VAR} set, "
                             f"another HOME, USER and LOGNAME, and its units' file at another path) wrote different records, the "
                             f"first at its record {k + 1} "
                             f"({(fa[0] or b'none').decode(errors='replace')}), field {m + 1}: {at(fa)} against {at(fb)}").encode()) + b"\n"}
                        event("answer-process-dependent", label=l, task=task, record=k + 1)
            if blocks is None:
                blocks = unit_blocks(data)
                if l in killed:   # killed past its budget, or in flight when its process ended: no answer, located
                    blocks[l] = ended_without(l, killed[l], task)
                elif l not in blocks:   # its process ended before it, no case in flight (its load failed): no answer (D9)
                    blocks = {l: ended_without(l, f"it ended before its case: {why_of(tail)}", task)}
            out[l] = blocks[l]
            each is None or each(l, out[l], key)
        door.wipe(role, f"{door.home(role)}/m")
    return out, key

# the one environment variable the pair's second process holds and the key does not (spec v16 X2), and its other
# placeholders for who runs it (spec v17 Y4, red 8a: HOME its own scratch, given where it starts; USER and LOGNAME
# names no user has). Its uid is the first's: one role runs both, so a body that reads its uid reads one value
PAIR_VAR = "WT_ANSWER_PAIR"
PAIR_ENV = {PAIR_VAR: "1", "USER": "wtpair", "LOGNAME": "wtpair"}

def ended_without(label, why, task):
    """THE rule for a process of an answer pair that ends without its case (spec v17 Y4, operator 7), either process,
    killed past its budget, in flight when it ended, or ended before its case: the label's Booked noanswer, located,
    never stored (Booked: a later replay answers it again), never the measurement's failure."""
    event("answer-booked", label=label, task=task, why=str(why)[:300])
    return noanswer_row(label, why, "native")

def pair_block(data, label):
    """The pair's second process's records of `label` (its stdout, drained as the first's is): (the lines between its
    `started <label>` and its `ended`, None), or (b"", why) for any other shape: a line before its `started`, another
    label, a second `started`, or no `ended` (R8-1's rule, the first process's own: nothing after `ended` is read)."""
    ls = data.split(b"\n")
    if not ls or ls[0] != f"started\t{label}".encode():
        return b"", f"its first record is {ls[0][:80].decode(errors='replace') if ls else 'none'!r}, not `started {label}`"
    for j, raw in enumerate(ls[1:], 1):
        if raw == b"ended":
            return b"".join(x + b"\n" for x in ls[1:j]), None
        if raw.startswith(b"started\t"):
            return b"", "it started another case before its `ended`"
    return b"", "it ended with no `ended` record"

def read_ran(field):
    """A process's record of what it ran with (test/smoke_judge.jl's _process_record: base64 of `<arg|env|opt>\\t<name>\\t
    <value>` lines) as ({"arg": [...], "env": {...}, "opt": {...}}, None), or (None, why) when it does not read."""
    try:
        text = base64.b64decode(field, validate=True).decode()
    except (ValueError, UnicodeDecodeError) as e:
        return None, f"its record of what it ran with does not read ({e})"
    ran = {"arg": [], "env": {}, "opt": {}}
    for ln in text.split("\n") if text else []:
        f = ln.split("\t", 2)
        if len(f) != 3 or f[0] not in ran or (f[0] != "arg" and f[1] in ran[f[0]]):
            return None, f"its record of what it ran with holds a line that reads as nothing: {ln[:120]!r}"
        ran["arg"].append(f[2]) if f[0] == "arg" else ran[f[0]].__setitem__(f[1], f[2])
    return ran, None

def ran_differs(ran, env, opts, program):
    """Why a process's record of what it ran with differs from its declaration, by name, or None: its ARGS (none: the
    script takes no argument), its whole environment against `env` (door.process_env of its declared one), and its
    Julia options against `opts` (the key process's, which ran the same argv; None for the key process itself), its
    `program_file` against `program`, the script its declared argv names."""
    bad = []
    if ran["arg"]:
        bad.append(f"it ran with the argument(s) {ran['arg'][:3]}, its declared argv gives none")
    have = ran["env"]
    bad += [f"it ran with {k}={have[k][:80]!r}, which its declared environment does not hold" for k in sorted(set(have) - set(env))]
    bad += [f"it ran without {k}, which its declared environment sets to {env[k][:80]!r}" for k in sorted(set(env) - set(have))]
    bad += [f"it ran with {k}={have[k][:80]!r}, its declared environment's is {env[k][:80]!r}"
            for k in sorted(set(env) & set(have)) if env[k] != have[k]]
    if ran["opt"].get("program_file") != program:
        bad.append(f"its Julia option program_file is {ran['opt'].get('program_file')!r}, its declared argv's script is {program!r}")
    if opts is not None:
        o = {k: v for k, v in ran["opt"].items() if k != "program_file"}
        w = {k: v for k, v in opts.items() if k != "program_file"}
        bad += [f"its Julia option {k} is {o.get(k)!r}, the key process's (its declared argv) is {w.get(k)!r}"
                for k in sorted(set(o) | set(w)) if o.get(k) != w.get(k)]
    return "; ".join(bad[:6]) + (f"; and {len(bad) - 6} more" if len(bad) > 6 else "") if bad else None

def loads_checked(data, label, want, ran=None):
    """(the records without their `loads` line, None) when the judging process's record of the files it loaded
    (test/smoke_judge.jl's `loads <label> <path>=<blob>;... <what it ran with>`, before its answer) is exactly `want`
    ({path: blob}: the answering program's files at the store's judge, JUDGE_WRITE, the snapshot and the label's unit)
    and what it ran with is its declaration (`ran`: (env, opts, program), ran_differs'), else (data, why): a file loaded
    besides them, one missing or another text of one, an argument, an environment variable or a Julia option not its
    declared process's, named (spec v14 V2, spec v16 X3: the answering program and process are exactly the keyed ones,
    by construction). A block with no `loads` line, or two, is refused the same way."""
    keep, got, proc = [], [], []
    for raw in data.splitlines(keepends=True):
        f = raw.rstrip(b"\n").split(b"\t")
        if f[0] == b"loads" and len(f) == 4 and f[1].decode(errors="replace") == label:
            got.append(f[2].decode(errors="replace")); proc.append(f[3].decode(errors="replace"))
        else:
            keep.append(raw)
    if not got and not any(raw.startswith((b"answer\t", b"noanswer\t")) for raw in keep):   # it wrote nothing for the
        return data, None   # label: no answer to check (the caller names why: it ended before its case)
    if len(got) != 1:
        return data, f"it wrote {len(got)} record(s) of the files it loaded, not one"
    have = {}
    for e in got[0].split(";"):
        p, _, b = e.rpartition("=")
        if p in have:
            return data, f"it loaded {p} twice"
        have[p] = b
    extra, missing = sorted(set(have) - set(want)), sorted(set(want) - set(have))
    other = sorted(p for p in set(have) & set(want) if have[p] != want[p])
    if extra or missing or other:
        return data, ("its answering program is not the keyed one: " + "; ".join(x for x in (
            extra and f"it loaded {', '.join(extra)} besides", missing and f"it did not load {', '.join(missing)}",
            other and f"it loaded another text of {', '.join(other)}") if x))
    if ran is not None:
        r, why = read_ran(proc[0])
        why = why or ran_differs(r, *ran)
        if why:
            return data, f"its process is not the declared one (ANSWER_PROCESS): {why}"
    return b"".join(keep), None

LEAF = b"\nleaf\t"

def _value_text(cap):
    """A stored value (test/oracle.jl's _capture) as a reader names it: its type's name and, for a primitive integer,
    float or Bool, its value; any other bits in hex."""
    k, tp, hx = cap.split(",")
    t = base64.b64decode(tp).decode(errors="replace").split(" ")
    name = base64.b64decode(t[2]).decode(errors="replace") if len(t) >= 3 and t[0] == "T" else "?"
    if k != "bits":
        return {"void": name, "throws": f"throws {name}", "opaque": f"a {name}"}.get(k, cap)
    b = bytes.fromhex(hx) if hx != "-" else b""
    if name == "Bool":
        return f"Bool {bool(b[0])}"
    if name in ("Float64", "Float32"):
        return f"{name} {struct.unpack('<d' if name == 'Float64' else '<f', b)[0]!r}"
    if re.fullmatch(r"U?Int\d+", name):
        return f"{name} {int.from_bytes(b, 'little', signed=name.startswith('Int'))}"
    return f"{name} 0x{hx}"

def _answer_summary(b):
    """A label's answer as a reader names it: its native value (or its noanswer's why) and its leaves' count."""
    f = b.split(b"\n", 1)[0].split(b"\t")
    return (f"no answer: {base64.b64decode(f[2]).decode(errors='replace')}" if f[0] == b"noanswer" else
            f"native {_value_text(f[6].decode(errors='replace'))}" + (f", {b.count(LEAF)} leaf record(s)" if LEAF in b else "") +
            (f", leaves {hashlib.sha256(b).hexdigest()[:12]}" if LEAF in b else ""))

def oracle_bootstrap(at, role="measure", replace=False, boot=None, say=print):
    """THE store written whole from the corpus at origin's commit `at`: the bootstrap (`boot` None: `at` becomes the
    store's bootstrap commit) and the one replay of the whole store (`boot` the store's bootstrap commit, `at` origin's
    head, `replace` True: every unit rewritten under origin's key, spec v14 V5). Every label of `at`'s corpus is answered
    by answer_labels, the one definition, in a process of its own, keyed by the store's judge (store_judge), then
    written in the unit of its source (label_sources: a unit label's unit file's last adding or changing commit, a
    snapshot label's the bootstrap), each index line with its text's blob; a line `at` registers no more is dropped.
    The key is computed FIRST (measure_key, as a measurement would read the store), and the partial file
    oracle/<at>.partial.tsv is kept only when its whole key line is that key and `at`; any other is removed and the run
    starts over, saying so (a bootstrap cut under one Julia and resumed under another, round12-operator 5). Resumable,
    and a kill loses at most the label in flight: each label's records are appended as it is answered (answer_labels'
    `each`), closed by `answered <label> <n>` and fsynced, so a chunk is whole only with its count line (unit_blocks'
    `chunks`); started again, it truncates the file after its last whole chunk and answers only the labels it lacks.
    Returns {label: records}."""
    labels, judge_at = sorted(labels_at(at)), store_judge()   # the store's one judge (R7)
    if not labels:   # a corpus the parser reads no registration from is no corpus to answer (D9)
        raise ClimbError(f"the corpus at {at[:10]} registers no label the parser reads: no unit is written")
    boot = boot or at
    t0, part_ = door.CLOCK(), os.path.join(ORACLE, f"{at}.partial.tsv")
    os.makedirs(ORACLE, exist_ok=True)
    key = measure_key(role, judge_at, f"oracle-key-{at[:8]}")
    have = {}
    if os.path.exists(part_):
        data = open(part_, "rb").read()
        k = read_key(data.split(b"\n", 1)[0].decode(errors="replace"))
        if k == (key, at) and b"\n" in data:
            have, end = unit_blocks(data, chunks=True)
            os.truncate(part_, max(end, data.index(b"\n") + 1))   # after the last whole chunk: a cut tail is answered again
        else:
            os.remove(part_)   # another key's or no key line: nothing of it is this run's
            why = f"its key line names {k[0] if k else 'no key'} for {k[1][:12] if k else '?'}; this run is keyed {key} for {at[:12]}"
            event("oracle-partial-dropped", at=at[:12], why=why[:400])
            say(f"climb: the partial file oracle/{at[:12]}.partial.tsv is another run's ({why}): it starts over")
    if not os.path.exists(part_):
        with open(part_, "wb") as f:
            f.write(key_line(key, at).encode()); f.flush(); os.fsync(f.fileno())
    booked = {}
    def each(l, records, k):   # one label answered: its chunk appended whole, then fsynced; a booked one never (spec v16 X3)
        if k != key:
            raise ClimbError(f"a label was answered under the key {k}, this run is keyed {key}")
        if isinstance(records, Booked):
            booked[l] = records; event("oracle-booked", at=at[:12], label=l); return
        n = records.count(b"\n")
        with open(part_, "ab") as f:
            f.write(records + f"answered\t{l}\t{n}\n".encode()); f.flush(); os.fsync(f.fileno())
        have[l] = records
        if len(have) % 32 == 0 or len(have) == len(labels):
            event("oracle-bootstrap-part", at=at[:12], answered=len(have), of=len(labels), secs=round(door.CLOCK() - t0))
    todo = [l for l in labels if l not in have]
    if todo:
        answer_labels(role, at, judge_at, todo, f"oracle-boot-{at[:8]}", each=each)
    if booked:   # never stored: the partial file holds every other label, and the bootstrap run again answers these alone
        first_why = _answer_summary(booked[sorted(booked)[0]])
        raise ClimbError(f"the bootstrap of {at[:12]}: {len(booked)} label(s) the driver booked ({', '.join(sorted(booked)[:3])}: "
                         f"{first_why[:200]}); a booked label is never stored: run it again, it answers only the labels it lacks")
    files, adds = corpus_files(at), unit_commits(at)
    by, blob = {}, {}
    for p in sorted(files):   # each label in the unit of its source (label_sources' rule): a snapshot label's the bootstrap
        for l in corpus_labels(files[p]):
            by.setdefault(adds[p] if is_unit(p) else boot, []).append(l); blob[l] = text_blob(files[p])
    for unit, ls in sorted(by.items()):
        oracle_write(unit, {l: have[l] for l in ls}, key, {l: blob[l] for l in ls}, replace=replace)
    oracle_drop(set(oracle_index()) - set(labels))   # a line `at` registers no more (R4)
    write_atomic(os.path.join(ORACLE, "bootstrap"), f"{boot}\n")
    os.remove(part_)
    h = hashlib.sha256(open(os.path.join(ORACLE, f"{boot}.tsv"), "rb").read()).hexdigest() if os.path.exists(os.path.join(ORACLE, f"{boot}.tsv")) else ""
    event("oracle-replay" if replace else "oracle-bootstrap", at=at[:12], boot=boot[:12], labels=len(labels), units=len(by),
          secs=round(door.CLOCK() - t0), sha256=h[:16])
    return {l: have[l] for l in labels}

def oracle_audit(k, seed, role="measure"):
    """The store checked against its own definition: a seeded sample of `k` stored answers (a label's `answer`, never a
    `noanswer`), each answered again by answer_labels, the one definition, from the corpus at its unit's commit, the
    store's judge (store_judge), and compared byte for byte with the store; and every unit's bytes against the index's sha256.
    A difference is a finding: the label, its unit and both answers (a key the store failed to capture, a body that
    answers differently each time, or an edit of a unit and its index together). Returns the findings."""
    import random
    idx, findings, answered, judge_at = oracle_index(), [], [], store_judge()
    units = {}
    for l, (u, h, _) in idx.items():
        units.setdefault((u, h), []).append(l)
    stored = {}
    for (u, h), ls in sorted(units.items()):
        data = open(os.path.join(ORACLE, f"{u}.tsv"), "rb").read() if os.path.exists(os.path.join(ORACLE, f"{u}.tsv")) else b""
        if hashlib.sha256(data).hexdigest() != h:
            findings.append(f"unit {u[:12]}: its file is not the bytes the index names (sha256), {len(ls)} label(s)"); continue
        blocks = unit_blocks(data.split(b"\n", 1)[1])
        for l in ls:
            if blocks.get(l, b"").startswith(b"answer\t"):
                answered.append((l, u)); stored[l] = blocks[l]
    sample = random.Random(seed).sample(sorted(answered), min(k, len(answered)))
    for l, u in sample:
        got, _ = answer_labels(role, u, judge_at, [l], f"oracle-audit-{hashlib.sha1(l.encode()).hexdigest()[:8]}", failed="book")
        if isinstance(got[l], Booked):   # no answer to compare: the driver's own failure, not the store's
            findings.append(f"{l} (unit {u[:12]}): not checked, its process was booked by the driver ({_answer_summary(got[l])})")
        elif got[l] != stored[l]:
            findings.append(f"{l} (unit {u[:12]}): stored {_answer_summary(stored[l])}; answered again {_answer_summary(got[l])}")
    event("oracle-audit", k=len(sample), seed=seed, findings=len(findings), labels=[l for l, _ in sample][:20])
    return findings

def measure_key(role, sha, task):
    """The store's key a measurement of `sha` as `role` reads under (oracle_key): the answering program's files and the
    snapshot at `sha`, and Julia and the host as a process of `role` that loads no corpus prints them (julia_host), in
    a judging directory of the answering program alone. The one computation of a measurement's key: a measurement, the
    launch's preflight and a resumed bootstrap or replay all take it (spec v14 V5)."""
    with door.using(role):
        d = door.give(role, f"{role}-{task}-key")
        dh = f"{door.home(role)}/m/{task}-key"
        jk = judge_files(sha, f"{d}/judge-key", paths=JUDGE_WRITE)
        key = oracle_key(sha, julia_host(role, d, dh, jk))
        door.wipe(role, f"{door.home(role)}/m")
    return key

def store_gap(missing, key):
    """The one OracleGap of labels the store does not answer under `key` (oracle_read's `missing`): how many, the first,
    why, the key field it names, and the one replay (spec v14 V5)."""
    l0 = sorted(missing)[0]
    return OracleGap(f"{len(missing)} landed label(s) the store does not answer, e.g. {l0}: {missing[l0]}" +
                     ("" if REPLAY in missing[l0] else f"; {REPLAY}"))

def smoke(role, only, task, sha, known=None, overlay=None, learn_=False, keep=None):
    """The driver's one measurement (R4, R6, R5-4, item 7): `only` (and, with `known`, every corpus case it does not
    list: one gained since; every case with `only` None) of commit `sha` (`overlay` written over its tree), the labels
    read from the corpus by the parser (corpus_labels) and named to each process exactly, as the role's build user, in
    three roles, each in a `julia` profile writing its own directory alone and reaped before the next, in this order:
    native answers first: every label origin's corpus holds (a landed label) read from the store (oracle_read, under
    this measurement's key), never computed, and the labels the measured corpus adds (its unit's) answered by
    answer_labels, the one definition of a native answer, exactly as a replay of that commit answers them: each in a
    fresh process of its own that loads the snapshot and that label's unit alone (the native role: no src, the
    `native` profile), so one process load per added label; `keep` (a path) taking their records for the lander's
    freeze; a landed label the store does
    not answer is a located failure, OracleGap, raised before any process answers or compiles (ONE gap rule for every
    measurement, a score's among them, spec v14 V5: no row is ever errored for a gap); a label the store holds as
    `noanswer` (killed) is errored with its why in every measurement; compile loads the commit's src (its own fresh depot over the dependency
    images) and writes each case's modules or its non-passing outcome, each case's readers shaped by its answer and no
    case's function called (R2); compare loads neither, binds each answer to exactly its case's modules, runs node and
    writes the cases; each watched by one function (watched). A score, a base, a candidate and a rebased check all run
    here; `learn_` (a measurement of origin's own commit) alone teaches case-secs. Between its roles it yields its lock
    to a waiting lander (yield_slot), and each part's seconds are an event (`smoke-part`), the parts a landing can wait
    behind. Returns ({label: row}, None) with a row for every label it runs, or (None, why) when the measured code wrote
    none, a label twice, records the driver refused, or rows for fewer labels than it runs; raises MeasureCut when a
    part is cut with no case of its own to book (its wall): never a partial table (O8-1)."""
    kind, tp = SLOT_KIND.get(role), [door.CLOCK()]
    env = environment(sha)
    dk = deps(sha, env["Manifest.toml"])
    files = corpus_files(sha, overlay)
    corpus = corpus_label_set(files)
    run = corpus if only is None else (set(only) | (corpus - set(known) if known is not None else set())) & corpus
    # landed: a label origin's corpus registers from the source the store's line names (R4); added: every other, answered
    # fresh, whatever the store holds for its name (a stored answer serves only the case it answered)
    idx = oracle_index()
    landed = landed_labels(run, git("rev-parse", f"origin/{MARCH}"), idx)
    added = sorted(run - landed)
    # the store read first, under this measurement's key, before any process answers or compiles: a gap is the
    # measurement's located failure, OracleGap, raised now (one gap rule, spec v14 V5)
    key = measure_key(role, sha, task)
    stored, missing = oracle_read(landed, key)
    if missing:
        raise store_gap(missing, key)
    def part(name):   # one part done: its seconds an event, then the lander first if it waits
        event("smoke-part", role=role, task=task, part=name, secs=round(door.CLOCK() - tp[0]), labels=len(run))
        yield_slot(kind); tp[0] = door.CLOCK()
    # the added labels: each answered by answer_labels, the one definition, in a process of its own; a process of the
    # measured corpus that does not load, or whose records the driver refuses, is the measured code's
    added_blocks, added_key = {}, None
    if added:
        try:
            added_blocks, added_key = answer_labels(role, sha, sha, added, f"{task}-added", overlay=overlay)
            part("added")
        except ClimbError as e:
            return None, f"the native process of a label it adds: {e}"
    log = unit_log(sha)
    # native answers first, every label's, compiled or not, before any compile (the oracle, R1): a landed label's
    # from the store, read under this measurement's key (the capture's blob, and Julia and the host as a process
    # that loads no corpus prints them), never computed; each case the measured corpus adds in a process of its own,
    # believed for that case alone, so one added registration's code never runs where another's answer is computed
    # (R7-1 d). They run in the `native` profile (no node, no Homebrew, no artifact to execute; its reads an
    # allowlist, its judging directory, its labels and Julia's install, R8-1), and each case's records are kept only
    # in its own block (watched's plan). They stay in the driver's memory until the compile and the run are reaped:
    # no process that runs a move's code (the measured src) is handed an answer, or can read one
    # (spec v16 X1); the compile is handed each answer's shape alone (shape_records)
    answers = b"".join(stored[l] for l in sorted(stored)) + b"".join(added_blocks[l] for l in added)
    unanswered = {l: base64.b64decode(b.split(b"\t")[2]).decode(errors="replace")
                  for l, b in stored.items() if b.startswith(b"noanswer\t")}
    blocks = unit_blocks(answers)
    # a process that ended before a label's records: no answer, located (D9)
    answers += b"".join(noanswer_row(l, "its process ended with no record for it", "native") for l in added if l not in blocks)
    blocks = unit_blocks(answers)
    if keep:   # the added labels' records, for the lander's freeze of this commit's unit: its key and the corpus's blob first
        if added_key is not None and added_key != key:
            return None, f"the added labels were answered under the key {added_key}, the measurement reads {key}"
        write_atomic(keep, key_line(key, corpus_id(files)) + b"".join(added_blocks[l] for l in added
                                                                       if l in added_blocks and not isinstance(added_blocks[l], Booked)).decode())
    shapes = shape_records(blocks)
    # each part (compile, run, verdict) takes its own use of the role and leaves it before the next (spec v17 Y3: no
    # yield while a measuring role is held, LOCK_ORDER); what a part hands the next is kept in `w`, the driver's own
    # directory, never in a run directory, which the role's next use removes
    w = os.path.join(STATE, "m", f"{role}-{task}")
    shutil.rmtree(w, ignore_errors=True); os.makedirs(w)
    try:
        rows, why = smoke_parts(role, task, sha, env, overlay, log, dk, run, learn_, shapes, answers, unanswered, w, part)
    finally:
        shutil.rmtree(w, ignore_errors=True)
    if rows is None:
        return rows, why
    # each row names the stored answer it was judged against and the judge (spec v17 Y4: G2 compares like with like)
    jid = judge_id(sha)
    return {l: Row(r, (answer_hash(blocks[l]), jid) if l in blocks else None) for l, r in rows.items()}, why

def smoke_parts(role, task, sha, env, overlay, log, dk, run, learn_, shapes, answers, unanswered, w, part):
    """smoke()'s three parts after the native answers, each in its own use of `role` (spec v17 Y3), `part` called
    between them (the parts' event and the yield to a waiting lander, outside any use); `w` the driver's own directory.
    smoke()'s result."""
    dh = f"{door.home(role)}/m/{task}"
    def compile_dir():   # the compile's run directory and its tree in the role's home: on entry, and again after a
        d = door.give(role, f"{role}-{task}")   # yield whose wait another use of the role came into (door.released)
        extract(sha, f"{d}/tree", dict(env, **(overlay or {})))
        write_corpus(f"{d}/tree", {}, log)   # the units' order, beside the tree's corpus (WT_SMOKE_UNITS)
        with open(f"{d}/shapes.tsv", "wb") as f:
            f.write(shapes)
        door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/m" && mkdir -p "$1/compile/tmp" && cp -Rc "$2/tree" "$1/compile/tree"',
                        "sh", dh, d], cfg()["tree_wall_s"], profile=door.NONE)
        door.profile(f"{d}/compile.sb", [f"{dh}/compile"])
        return d
    with door.using(role):
        # compile: each case's readers shaped by its answer's shape (WT_SMOKE_SHAPES, the driver's file, which the process
        # reads and cannot write), and the calls that read them; it calls no case's function (R2)
        d = compile_dir()
        def compile_start(e, log_):   # the declared compiling process (COMPILE_PROCESS), its labels and records the watch's
            argv, env_ = process(COMPILE_PROCESS, scratch=f"{dh}/compile", deps=dk, top=door.TOP, shapes=f"{d}/shapes.tsv",
                                 units=f"{dh}/compile/tree/units.log", only=e["WT_SMOKE_ONLY"], records=e["WT_SMOKE_COMPILED"])
            return door.popen(role, argv, cwd=f"{dh}/compile/tree", env=env_, profile=f"{d}/compile.sb", stdout=log_,
                              stderr=subprocess.STDOUT, background=part_background(role))
        out, why = compile_watched(compile_start, role, d, f"m/{task}/compile", run, learn_, w, compile_dir)
        door.reap(role)
        rc, err = door.wipe(role, f"{door.home(role)}/m")
    part("compile")
    if rc != 0:   # its status read (R7-5): a directory the measured code made unremovable is the measurement's failure
        return None, f"the measurement's directory could not be removed: {err.strip()[-300:]}"
    if why:
        return None, f"the driver refused the compiling process's records: {why}"
    mods = f"{w}/modules.tsv"
    if not os.path.getsize(mods):
        return None, "the compiling process wrote no modules: " + out[-600:]
    # run: the runner and node in their own directory, which the driver fills and the run's allowlist
    # profile alone admits (spec v17 Y1): RUN_FILES and the calls run_input composed (each case's modules and calls
    # with the judge's fixtures interleaved where it drew them, every label drawn), never d, the tree, the corpus,
    # an answer or the plan; it writes each call's raw line. No record of its own, so its process gets case_min_s
    # and compare_module_s for each call (the runner's own watchdog kills node first)
    fx = judge_files(sha, f"{w}/judge-fixtures", paths=FIXTURE_FILES)
    calls, plan = run_input(open(mods, "rb").read(), {p: open(f"{fx}/{p}").read() for p in FIXTURE_FILES}, random.SystemRandom())
    ncalls = plan.count("\n")
    with door.using(role):
        d = door.give(role, f"{role}-{task}")
        judge_files(sha, f"{d}/run/tree", paths=RUN_FILES)
        with open(f"{d}/run/calls.tsv", "w") as f:
            f.write(calls)
        rc_, *oe = door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/m" && mkdir -p "$1/run/tmp" && cp -R "$2/run/tree" "$2/run/calls.tsv" "$1/run/"',
                                   "sh", dh, d], cfg()["tree_wall_s"], profile=door.NONE)
        if rc_ != 0:
            raise ClimbError(f"the run's directory: {''.join(x or '' for x in oe).strip()[-300:]}")
        prof_r = door.profile(f"{d}/run.sb", [f"{dh}/run"], kind="native", reads=(*RUN_READS, part_log(d, "run")))
        argv_r, env_r = process(RUN_PROCESS, run=f"{dh}/run", scratch=f"{dh}/run", top=door.TOP)
        try:   # the judge's own per-call allowance (run_allowance); a cut on a candidate is the candidate's (spec v19 P2)
            o, _, _, _ = watched(lambda e, log_: door.popen(role, argv_r, cwd=f"{dh}/run/tree", profile=prof_r, stdout=log_,
                                                            stderr=subprocess.STDOUT, env=env_r,
                                                            background=part_background(role)),
                                 role, d, f"m/{task}/run", "run", None, run_allowance(f"{d}/run/tree", ncalls))
        except MeasureCut as e:
            if learn_:   # origin's own commit: never a result, the driver's (O8-1)
                raise
            return None, f"the run part was cut on the candidate: {str(e)[:500]}"
        door.reap(role)
        try:
            raw = door.take(role, f"m/{task}/run/raw.tsv", cfg()["cases_cap_bytes"])
        except door.DoorError as e:
            raw = e
        rc, err = door.wipe(role, f"{door.home(role)}/m")
    part("run")
    if rc != 0:
        return None, f"the run's directory could not be removed: {err.strip()[-300:]}"
    if isinstance(raw, door.DoorError):
        return run_part_failed(sha, f"the run process's lines: {raw}", candidate=not learn_)
    if raw is None:
        return run_part_failed(sha, "the run process wrote no lines: " + o[-600:], candidate=not learn_)
    # verdict: the judge's file alone (test/verdict.jl, no runner, no node, no WasmTarget, no corpus), in the `native`
    # profile reading its own directory alone, handed the answers now, with the compile's records and the run's lines
    with door.using(role):
        d = door.give(role, f"{role}-{task}")
        door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/m" && mkdir -p "$1/verdict/tmp"', "sh", dh], cfg()["tree_wall_s"], profile=door.NONE)
        jv = judge_files(sha, f"{d}/judge-verdict", paths=VERDICT_FILES)
        for name, data in (("answers.tsv", answers), ("modules.tsv", open(mods, "rb").read()), ("raw.tsv", raw), ("plan.tsv", plan.encode())):
            with open(f"{jv}/{name}", "wb") as f:
                f.write(data)
        prof_v = door.profile(f"{d}/verdict.sb", [f"{dh}/verdict"], kind="native", reads=[jv, part_log(d, "verdict")])
        argv_v, env_v = process(VERDICT_PROCESS, judge=jv, scratch=f"{dh}/verdict")
        o, _, _, _ = watched(lambda e, log_: door.popen(role, argv_v, cwd=jv, profile=prof_v, stdout=log_, stderr=subprocess.STDOUT, env=env_v,
                                                        background=part_background(role)),
                             role, d, f"m/{task}/verdict", "verdict", None, cfg()["case_min_s"] + cfg()["compare_module_s"] * ncalls)
        door.reap(role)
        try:
            cases = door.take(role, f"m/{task}/verdict/cases.tsv", cfg()["cases_cap_bytes"])
        except door.DoorError as e:
            cases = e
        rc, err = door.wipe(role, f"{door.home(role)}/m")
    part("verdict")
    if rc != 0:
        return None, f"the measurement's directory could not be removed: {err.strip()[-300:]}"
    if isinstance(cases, door.DoorError):
        return None, f"the verdict process's cases: {cases}"
    if cases is None:   # the runner failing a fixture of the judge's: the runner's (spec v16 X1), or, where every file
        # the run and its judgement read is origin's, the infrastructure's (spec v17 Y1: one note, no move charged)
        fx = [l for l in o.splitlines() if l.startswith("verdict: the runner fails its fixtures")]
        return run_part_failed(sha, fx[0][:600]) if fx else (None, "the verdict wrote no cases: " + o[-600:])
    try:   # each row's seconds the driver's own (case-secs, its compile's), never the number a process wrote (R7-9)
        cs = case_secs("compile")
        rows = {r_[0]: (r_[0], r_[1], cs.get(r_[0], 0.0), r_[3]) for r_ in parse_cases(cases.decode(errors="replace"))}
    except ClimbError as e_:
        return None, str(e_)
    for l, why in unanswered.items():   # no frozen answer: errored, located, whatever the compile did (D9)
        if l in rows:
            rows[l] = (l, "errored", rows[l][2], f"no frozen native answer: {why}"[:500])
    short = sorted(run - set(rows))
    if short:   # a row for every label it runs, or no result: never a partial table read as whole (O8-1)
        return None, f"the measurement wrote no row for {len(short)} of its {len(run)} label(s) ({', '.join(short[:5])})"
    return rows, None

def measure_base(base, labels, locked_=False):
    """The labels at `base`, an origin commit, in the driver's base tree: cached by the base's sha and shared by the
    slots, so each label runs once per base. Every run also takes the corpus cases the table does not know (gained
    since), so a case another landing added is judged from its base too, never as new. `locked_`: the caller holds
    the measurement lock already (the lander's rebased check, one acquisition)."""
    path = os.path.join(STATE, "base", f"{base}-{judge_id(base)[:16]}.tsv")   # (sha, judge_id): spec v18 P4
    with (contextlib.nullcontext() if locked_ else julia_slot("verify")):
        have = {r[0]: r for r in read_cases(path)} if os.path.exists(path) else {}
        missing = set(labels) - set(have)
        if missing:
            got, why = smoke("measure", missing, f"base-{base[:12]}", base, known=set(table()), learn_=True)
            if got is None:   # origin's own tree: the driver's failure, never the move's
                raise ClimbError(f"the base {base[:10]}: {why}")
            have.update(got)
            write_atomic(path, cases_text(have.values()))
            for old in glob.glob(os.path.join(STATE, "base", "*.tsv")):   # a base two days old is no move's base
                if os.path.getmtime(old) < time.time() - cfg()["base_keep_s"]:
                    os.remove(old)
    return have

def confirmed(origin, before, after):
    """`before` (the table) with every label whose outcome `after` changes measured at `origin` itself (item 8, A5-1,
    R5-12, O5-6): a loss origin shares is origin's, so the table takes origin's rows and a loss of a case the table
    held passing is filed as G2's, and a case origin passes already is no progress of the item's. Runs under the
    caller's measurement lock."""
    diff = {l for l, r in after.items() if l in before and before[l][1] != r[1]}
    if not diff:
        return before
    o = measure_base(origin, diff, locked_=True)
    theirs = [o[l] for l in sorted(diff) if l in o and o[l][1] != before[l][1]]
    advance(theirs, origin, "a rebased check measured origin")
    like = lambda r: same_judgement(before[r[0]], r)
    lost = sorted(r[0] for r in theirs if before[r[0]][1] == "passed" and like(r))
    if lost:
        file_g2(lost, origin[:8])
    rebased = sorted(r[0] for r in theirs if before[r[0]][1] == "passed" and not like(r))
    if rebased:   # a stored answer or the judge changed under them: no landing's loss (spec v17 Y4)
        event("score-rebased", sha=origin[:8], answers=True, lost=len(rebased), first=rebased[:20])
        alarm("rebased", f"the store or the judge changed: {len(rebased)} passing case(s) no longer pass", f"At origin "
              f"{origin[:10]} (a rebased check): {', '.join(rebased[:20])}, each judged against another stored answer or "
              "judge than its table row. Default taken: no G2 fix-first; the table takes origin's rows.")
    return dict(before, **{r[0]: r for r in theirs})

def def_spans(at, defs):
    """{d: [(src file, first line, last line)]}: where each definition d sits at commit `at`, read by Julia's parser
    (dev/climb/spans.jl, as the measure user in the `julia` profile), never by its name somewhere in a text
    (architect 14): a src file's name its top-level forms that define it, a src file without a name the whole file,
    a dart anchor the top-level form of each src line that cites it."""
    out, queries, files = {x: [] for x in defs}, [], set()
    for i, (path, name) in enumerate(defs):
        if path.startswith("src/") and not name:
            out[defs[i]].append((path, 1, 10 ** 9))
        elif path.startswith("src/"):
            files.add(path); queries.append((i, path, name))
        else:
            for hit in git("grep", "-n", "-F", f"{path} {name}".strip(), at, "--", "src/", check=False).splitlines():
                _, f, ln = hit.split(":", 3)[:3]
                files.add(f); queries.append((i, f, f":{ln}"))
    if queries:
        given = {f"t/{f}": sh(["git", "show", f"{at}:{f}"]).stdout for f in files}
        given["spans.jl"] = open(os.path.join(ROOT, "dev", "climb", "spans.jl")).read()
        r = julia_job("measure", f"spans-{os.getpid()}", given, ["julia", "--startup-file=no", "{in}/spans.jl"], cfg()["parse_wall_s"],
                      stdin="".join(f"{i}\t{{in}}/t/{f}\t{q}\n" for i, f, q in queries))
        if r[0] != 0:
            raise ClimbError(f"dev/climb/spans.jl: {(r[2] or r[1]).strip()[-300:]}")
        for line in r[1].splitlines():
            i, a, b = line.split("\t")
            f = next(f for j, f, _ in queries if j == int(i))
            out[defs[int(i)]].append((f, int(a), int(b)))
    return out

def hunks(base, sha, path):
    """The old side of each hunk of base..sha in `path`, (first line, count), from git's own hunk headers."""
    return [(int(m.group(1)), int(m.group(2) or 1)) for m in
            re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+", file_diff(base, sha, path, "-U0"), re.M)]

def touched(base, sha, spans):
    """Some hunk of base..sha overlaps one of `spans`: a pure insertion (count 0) sits after its line, so it touches a
    span that holds that line or the next."""
    for f, a, b in spans:
        for s0, n in hunks(base, sha, f):
            lo, hi = (s0, s0 + n - 1) if n else (s0, s0 + 1)
            if lo <= b and hi >= a:
                return True
    return False

def regressions(h, labels, before, after):
    """G1 and G2, by the difference from the base, on the same labels both times (12, 19)."""
    hc, problems = set(h["cases"]), []
    for l, (_, o, _, w) in sorted(after.items()):
        b = before.get(l)
        if b is None:   # a case the move adds
            if o in ("wrong", "errored"):
                problems.append(f"G1 {o} {l} (a case the move adds): {w[:200]}")
            continue
        if b[1] == "passed" and o != "passed" and same_judgement(b, after[l]):   # like with like (spec v17 Y4)
            problems.append(f"G2 lost {l}: {o} {w[:160]}")
        if o in ("wrong", "errored") and b[1] not in ("wrong", "errored"):
            problems.append(f"G1 {o} {l}: {w[:200]}")
        if o == "outside" and b[1] != "outside":
            problems.append(f"newly outside the subset (needs a ruling): {l}")
        if o in GAPS and b[1] not in GAPS:   # a move cannot turn a case into the judge's gap unseen (spec v19 P5)
            problems.append(f"newly a gap (needs a ruling): {l}: {o} {w[:160]}")
    return problems + [f"the move's run did not reach {l}" for l in sorted((set(before) & labels) - set(after))]

def judge_move(h, at, base, sha, labels, before, after):
    """G1 and G2 (regressions) and progress, judged by the difference from `before`, measured at `at` (the move's base,
    or origin for the lander's rebased check), the diff read over base..sha. Returns (unlocked, problems)."""
    hc = set(h["cases"])
    problems = regressions(h, labels, before, after)
    unlocked = sorted(l for l in hc if l in after and after[l][1] == "passed" and before.get(l, ("", ""))[1] != "passed")
    # a case stops at another definition: the definition it stopped at before (d0) and the one it stops at now (d1)
    stops = {}
    for l in hc:
        b, a = before.get(l), after.get(l)
        if b and a and b[1] == a[1] == "unported":
            d0, d1 = site_def(unported_site(b[3]) or ""), site_def(unported_site(a[3]) or "")
            if d0 != d1 and d0[0] and d1[0]:   # a rejection that names no definition is no stop at one
                stops[l] = (d0, d1)
    now_spans = def_spans(at, sorted({d1 for _, d1 in stops.values()})) if stops else {}
    old_spans = def_spans(base, sorted({d0 for d0, _ in stops.values()})) if stops else {}
    # progress: a case passes, or it stops at another definition `at` already had (its span found) and a hunk of the
    # diff overlaps the definition it stopped at before: a reworded rejection, a stub the move wrote, or a stop moved by
    # a change elsewhere is no progress (refusal 3)
    moved = [l for l in hc if l in unlocked or (l in stops and now_spans[stops[l][1]] and touched(base, sha, old_spans[stops[l][0]]))]
    if h.get("tail") and not git("diff", "--name-only", base, sha, "--", "src/"):
        problems.append("a src-tail move that changes nothing under src/")
    if h.get("require_pass"):
        problems += [f"G2 still not passing: {l}" for l in sorted(hc - set(unlocked))]
    elif hc and not moved:
        problems.append("no case of the hold passes or stops at another definition the base had, by a change to the definition it stopped at")
    return unlocked, problems

KINDS_INPUTS = ("dev/src_progress.sh", "dev/progress_kinds.jl", "dev/skeleton.jl", "dev/cache_key.sh", "dev/depot.sh")

def kinds(head, task):
    """The listing of `dev/src_progress.sh kinds` at origin's head `head` (the src tail's holds; a candidate's own is
    never read, item 10), ROOT's copies of the program's files written over the tree's, as the score user in the
    `check` profile (a git repository of its own made there, which the program's cache key reads)."""
    env = environment(head)
    dk = deps(head, env["Manifest.toml"])
    with door.using("score"):
        d = door.give("score", f"kinds-{task}")
        extract(head, f"{d}/tree", dict(env, **{f: open(os.path.join(ROOT, f)).read() for f in KINDS_INPUTS}))
        dh = f"{door.home('score')}/k/{task}"
        door.run("score", ["/bin/sh", "-c", 'rm -rf "$HOME/k" && mkdir -p "$1/tmp" && cp -Rc "$2/tree" "$1/tree"', "sh", dh, d], cfg()["tree_wall_s"], profile=door.NONE)
        r = door.run("score", ["/bin/sh", "-c", "git init -q && git add -A && git -c user.name=climb -c user.email=climb@localhost "
                               "commit -qm head && exec bash dev/src_progress.sh kinds"], cfg()["kinds_wall_s"], cwd=f"{dh}/tree",
                     profile=door.profile(f"{d}/kinds.sb", [dh], kind="check"),
                     env={"TMPDIR": f"{dh}/tmp", "JULIA_DEPOT_PATH": f"{dh}/depot:{dk}:{door.TOP}/julia:",
                          "WT_SHARED_DEPOT": f"{dk}:{door.TOP}/julia", "JULIA_NUM_THREADS": "1"})
        rc, err = door.wipe("score", f"{door.home('score')}/k")
    if rc != 0:
        raise ClimbError(f"dev/src_progress.sh kinds at {head[:10]}: its directory could not be removed: {err.strip()[-300:]}")
    if r[0] != 0 or not r[1].strip():
        raise ClimbError(f"dev/src_progress.sh kinds at {head[:10]}: {(r[1] + r[2])[-300:]}")
    return r[1]

# ---------------------------------------------------------------- the src suite: the score's src part, a red located
# Every test file of ported code (test/src_tests.jl's walk of test/src) is run on origin's head at each score, before its
# smoke (the landing-check ruling, R6), by test/src_tests.jl itself, origin's harness, which writes each file's outcome
# and cost (WT_SRC_RECORDS) in the records watched() reads for a measurement's cases. A file red there is run again
# alone (one process for every such file, R10) and bisected over origin's first-parent commits since it last ran green
# (src_locate), each step one process at that commit (src_red_at: the one answer to "is this file red at this commit",
# R3), and a red located to a landing is a fix-first hold of its own kind, `src-test <file> red since <landing>`.
SRC_DIR = "test/src/"

def src_files(sha):
    """T(sha): the test files test/src_tests.jl walks at `sha` (every .jl under test/src), relative to test/src, in its
    walk's sorted order."""
    return sorted(p[len(SRC_DIR):] for p in git("ls-tree", "-r", "--name-only", sha, "--", SRC_DIR).splitlines()
                  if p.endswith(".jl"))

def check_rate(sha):
    """dev/check.sh's RATE_P_SRC at `sha`: the one rate a file's children are counted at (test/src_tests.jl), never a copy."""
    m = re.search(r"^RATE_P_SRC=([0-9.]+)", git("show", f"{sha}:dev/check.sh"), re.M)
    if not m:
        raise ClimbError(f"{sha[:10]}:dev/check.sh names no RATE_P_SRC")
    return m.group(1)

# what the driver's state keeps of the files that grow one a score or one a landing attempt (the round-14 operator's
# finding 8, spec v17 Z7), the newest by time kept, as TOP/landimg keeps its newest two: SRC_KEEP heads' records and
# plans (src_latest reads the newest alone; the one before it is kept to compare a score against its predecessor, the
# rest for an operator reading back a day of scores, about four), SHIP_KEEP landing attempts' files (STATE/ship: a set,
# its costs, ship.sh's result and the check's verdict an attempt, the last day's attempts at a few an hour)
SRC_KEEP, SHIP_KEEP = 4, 64

def prune_newest(pattern, keep, group=lambda p: p):
    """Every file `pattern` matches but those of the newest `keep` groups (`group`: a file's group name; each its own by
    default), by modification time, removed."""
    by = {}
    for p in glob.glob(pattern):
        with contextlib.suppress(FileNotFoundError):
            g = group(p); by[g] = max(by.get(g, 0), os.path.getmtime(p))
    old = set(sorted(by, key=by.get)[:-keep] if keep else by)
    for p in glob.glob(pattern):
        if group(p) in old:
            with contextlib.suppress(FileNotFoundError):
                os.remove(p)

def src_process_decl(sha):
    """THE test-file process at `sha` (spec v17 Z7): dev/check.sh's SRC_PROCESS_ENV and SRC_PROCESS, the environment and
    command its shards start, read at the commit as check_rate reads RATE_P_SRC, so the score's src part runs exactly the
    process a landing's shard runs and the costs one measures are the other's (the round-14 architect's finding 8: two
    declarations, each measured in its own shape). Returns ({name: value}, argv); a commit declaring neither is refused."""
    t = git("show", f"{sha}:dev/check.sh")
    e, c = (re.search(rf"^{n}=\((.*)\)$", t, re.M) for n in ("SRC_PROCESS_ENV", "SRC_PROCESS"))
    if not e or not c:
        raise ClimbError(f"{sha[:10]}:dev/check.sh declares no test-file process (SRC_PROCESS_ENV, SRC_PROCESS)")
    env = dict(x.split("=", 1) for x in shlex.split(e.group(1)))
    return env, shlex.split(c.group(1))

CANARY = "~canary"   # the judge's canary's label (test/src_canary.jl): sorted after every path of test/src, so run last

def src_process(text, rc):
    """One process's records (its own file, read once it ended): ({file: (outcome, G, why)}, the files it started,
    why its rows are void or None). They stand only when its canary, last, read passed (the judge's canary: a test file
    runs in the process that writes its own record, the round-13 architect's A13-5) and its exit status agrees with them:
    a red row and exit 0, or a nonzero exit with every row passed and no file left unfinished, disagree. A process the
    driver killed (rc < 0: a file past its budget) has no canary: void, its files run again whole by the next process."""
    rows, started, canary, block, after = {}, [], None, None, False
    for l in text.splitlines():
        f = l.split("\t")
        # the block grammar (spec v18 Q3; dev/src_verdict.sh reads the same): `started <f>` then `row <f>`, closed before
        # the next opens; a started inside another file's block or a row outside its own block voids the process
        if after:   # the canary's row is the last line (spec v19 Q2; dev/src_verdict.sh reads the same)
            return {}, [x for x in started if x != CANARY], f"a line after the canary's row: {l[:120]!r}"
        if f[0] == "claimed" and len(f) == 2 and block is None:   # a file another process took (a shard's queue)
            continue
        if f[0] == "started" and block is not None:
            return {}, [x for x in started if x != CANARY], f"a started of {f[1] if len(f) > 1 else '?'} inside {block}'s block"
        if f[0] == "row" and (len(f) < 2 or f[1] != block):
            return {}, [x for x in started if x != CANARY], f"a row of {f[1] if len(f) > 1 else '?'} outside its own block"
        block = f[1] if f[0] == "started" and len(f) == 2 else None if f[0] == "row" else block
        if f[0] == "started" and len(f) == 2:
            started.append(f[1])
        elif f[0] == "row" and len(f) == 5 and f[1] == CANARY:
            canary, after = (f[2], base64.b64decode(f[4]).decode(errors="replace")), True
        elif f[0] == "row" and len(f) == 6 and f[2] in ("passed", "failed"):
            if f[5] != "passed":   # its canary run AS the file read wrong (spec v17 Z4): the process is void
                files = [x for x in started if x != CANARY]
                cw = base64.b64decode(f[5][len("failed:"):]).decode(errors="replace") if f[5].startswith("failed:") else f[5]
                return {}, files, f"its canary as {f[1]} read wrong: {cw[:200]}; its files: {', '.join(files[:20])}"
            try:
                rows[f[1]] = (f[2], float(f[3]), base64.b64decode(f[4]).decode(errors="replace"))
            except ValueError:
                return {}, started, f"a src record the driver does not read: {l[:200]!r}"
        else:
            return {}, started, f"a src record the driver does not read: {l[:200]!r}"
    files = [x for x in started if x != CANARY]
    if canary is None or canary[0] != "passed":
        return {}, files, (f"its canary read {canary[0]}: {canary[1][:200]}" if canary else "it ended with no canary (exit "
                           f"{rc})") + f"; its files: {', '.join(files[:20])}"
    red = any(r[0] != "passed" for r in rows.values())
    unfinished = [x for x in files if x not in rows]
    if (rc == 0 and red) or (rc != 0 and not red and not unfinished):
        return {}, files, f"its exit status {rc} disagrees with its rows ({'a red row' if red else 'every row passed'}); its files: {', '.join(files[:20])}"
    return rows, files, None

def src_run(head, files, task, role="score", learn_=False, yields=False):
    """`files` (paths under test/src) run at commit `head` by its own test/src_tests.jl as the role's build user in the
    `check` profile (node, wasm-opt), in `head`'s tree without its history (git archive), so each file runs as a
    landing's check runs it at `head` (the one process dev/check.sh declares, src_process_decl; a fresh first depot
    over the dependency images). At default QoS: one single-threaded process at a time under the score's measurement lock, which the lander
    takes before a check, so never beside one (D31), its instructions counted on the performance cores a check's shards
    run on. Each process runs WT_SRC_SET (the files not yet read, in the walk's order) and then the judge's canary, its
    records read per process (src_process: a row stands only beside a canary that read passed and an exit status that
    agrees, A13-5). Watched as a measurement's cases are (watched(): each file's `started` and its `row`, a per-file
    budget learned from origin's commits with `learn_`, a file past its budget booked errored by name and the rest run
    again in a fresh process). With `yields`, a waiting lander makes the run stop gracefully before its next file
    (WT_SRC_STOP): that process runs its canary and exits, the lock passes to the lander (yield_slot), and the files not
    yet read run in a new process after. A restarted process's first file pays the shared first compile again: its cost
    is recorded unmeasured (None; the operator's round-13 finding 7). Returns ({file: (outcome, G, secs, why)}, the
    warm-up G or None) for every file, or (None, why) when a process's records were void, refused or missing; MeasureCut
    when a part is cut with no file to book."""
    if not files:
        raise ClimbError("src_run with no file to run (D9: an empty set is never every file)")
    env = environment(head)
    dk = deps(head, env["Manifest.toml"])
    rate, kind = check_rate(head), SLOT_KIND.get(role)
    penv, pcmd = src_process_decl(head)
    secs, rows, warms, restarted, rnd = case_secs("src"), {}, [], set(), 0
    with door.using(role):
        dh, d, prof = f"{door.home(role)}/s/{task}", None, None
        def prepare():   # the run directory, its history and the tree: at entry, and again as the rejoin after a yield
            nonlocal d, prof   # that another use of the role came between (spec v18 Q4)
            d = door.give(role, f"src-{task}", env)
            door.repo(d, COMMON, {"check": head})
            prof = door.profile(f"{d}/src.sb", [door.home(role)], kind="check")
            # the commit's tree WITHOUT history (spec v17 Z4: a test's verdict never reads git), and the base a test is
            # measured against (its parent's test/ and the rename map, WT_BASE_TREE), both made here, by the driver's git
            r = door.run(role, ["/bin/sh", "-c", 'rm -rf "$HOME/s" && mkdir -p "$1/tmp" "$1/tree" "$1/base/tree" && '
                                'git clone -q --bare -b check "$2/repo.git" "$1/g.git" && git --git-dir="$1/g.git" archive check | tar -x -C "$1/tree" && '
                                '{ git --git-dir="$1/g.git" archive "check~1" -- test 2>/dev/null | tar -x -C "$1/base/tree" 2>/dev/null; '
                                'git --git-dir="$1/g.git" diff -M --name-status "check~1" check > "$1/base/renames" 2>/dev/null; true; } && '
                                'cp "$2/Manifest.toml" "$2/LocalPreferences.toml" "$1/tree/" && rm -rf "$1/g.git"', "sh", dh, d],
                         cfg()["tree_wall_s"], profile=prof)   # the history removed once the tree and the base are made
            if r[0] != 0:
                raise ClimbError(f"the src run's clone of {head[:10]}: {(r[1] + r[2]).strip()[-300:]}")
        prepare()
        remaining = sorted(files)
        while remaining:
            rel, procs, stopped = f"s/{task}/r{rnd}", [], [False]
            door.run(role, ["/bin/sh", "-c", 'mkdir -p "$1"', "sh", f"{door.home(role)}/{rel}"], cfg()["step_wall_s"], profile=door.NONE)
            def start(e, log, rel=rel):
                e = dict(e)
                setf = os.path.join(d, f"set.{rnd}.{len(procs)}.txt")   # the labels watched names, the canary's aside
                write_atomic(setf, "".join(x + "\n" for x in open(e.pop("WT_SMOKE_ONLY")).read().split() if x != CANARY))
                p = door.popen(role, pcmd, cwd=f"{dh}/tree",   # the process dev/check.sh's shards start (src_process_decl)
                               env=dict(penv, TMPDIR=f"{dh}/tmp", JULIA_DEPOT_PATH=f"{dh}/depot:{dk}:{door.TOP}/julia:", WT_SRC_SET=setf,
                                        WT_BASE_TREE=f"{dh}/base", GIT_CEILING_DIRECTORIES=dh,
                                        WT_DART_CORPUS_DIR=f"{dh}/wt-dart-corpus",   # the corpus's images: no history to ask
                                        WT_SRC_WARM=f"{door.home(role)}/{rel}/warm", WT_SRC_CHILD_RATE=rate,
                                        WT_SRC_STOP=f"{door.home(role)}/{rel}/stop", **e),
                               profile=prof, background=False, stdout=log, stderr=subprocess.STDOUT)
                procs.append(p)
                return p
            done_ev = threading.Event()
            def watch_lander(rel=rel):   # a landing waits: the run stops before its next file (its canary still runs)
                while not done_ev.wait(cfg()["poll_s"]["yield"]):
                    if yields and lander_waits(kind):
                        door.put(role, f"{rel}/stop", "stop\n"); stopped[0] = True; return
            th = threading.Thread(target=watch_lander, daemon=True); th.start()
            out, killed, n, refused = watched(start, role, d, rel, "src", remaining + [CANARY], cfg()["pkg_wall_s"],
                                              var="WT_SRC_RECORDS", keep_done=False, yields=False, learn_=learn_,
                                              frame={"path": os.path.join(d, f"frame.{rnd}.tsv")})
            done_ev.set(); th.join()
            if refused:
                door.wipe(role, f"{door.home(role)}/s")
                return None, f"the driver refused the src run's records: {refused}"
            warms += [float(x) for x in (door.take(role, f"{rel}/warm", 1 << 16) or b"").decode(errors="replace").split()
                      if re.fullmatch(r"[0-9.]+", x)]
            got = {}
            for k in range(n):   # each process's own records, read whole once it ended
                text = (door.take(role, f"{rel}/rec.{k}", cfg()["cases_cap_bytes"]) or b"").decode(errors="replace")
                prows, started, void = src_process(text, procs[k].returncode if k < len(procs) else None)
                if void and procs[k].returncode is not None and procs[k].returncode >= 0:
                    door.wipe(role, f"{door.home(role)}/s")
                    event("src-void", task=task, why=void[:400])
                    raise SrcVoid(f"a src process's records are void: {void}", [x for x in started if x != CANARY])
                if (rnd > 0 or k > 0) and started:   # a restarted process's first file: no cost of its own
                    restarted.add(started[0])
                got.update(prows)   # a later process's rows (a killed one's files run again) supersede
            for f_, (o, g, why) in got.items():
                rows[f_] = (o, None if f_ in restarted else g, secs.get(f_, 0.0), why)
            for f_, budget in killed.items():   # the driver's own row for a file it booked (D9)
                if f_ != CANARY:
                    rows[f_] = ("errored", 0.0, secs.get(f_, 0.0), f"src past its budget: no record for {budget} s (the driver killed it)"
                                if not isinstance(budget, str) else f"src: {budget} (the driver booked it)")
            left = [f_ for f_ in remaining if f_ not in rows]
            if not stopped[0] and left:   # it ended with files unread and no stop asked: no result (O8-1)
                door.wipe(role, f"{door.home(role)}/s")
                return None, f"the src run wrote no row for {len(left)} of its {len(files)} file(s) ({', '.join(left[:5])}): " + out[-600:]
            remaining, rnd = left, rnd + 1
            if stopped[0] and remaining:   # the lander lands; the rest after it, in a fresh process, the role left meanwhile
                with door.released(role) as use:   # (spec v18 Q4, the round-15 operator's finding 1: a yield that held the
                    yield_slot(kind)               # role took the score lock against LOCK_ORDER and raised)
                if use["lost"]:   # another use of the role came between, which removed the run directory and the home
                    prepare()
        rc, err = door.wipe(role, f"{door.home(role)}/s")
    if rc != 0:
        return None, f"the src run's directory could not be removed: {err.strip()[-300:]}"
    return rows, (min(warms) if warms else None)

def src_red_at(files, at, task, role="score"):
    """The one answer to "is this file red at this commit" (R3, D5): `files` run at commit `at` in one process (src_run),
    a file the commit does not hold read red ("absent"). Returns {file: (outcome, why)}, outcome passed, failed, errored,
    absent, or void (one file whose process alone is void: spec v17 Z3); a void process of several files raises SrcVoid
    (src_void_split narrows it); a run that wrote no result raises ClimbError, naming why (never a file read green past it, D9)."""
    have = set(src_files(at))
    out = {f: ("absent", f"{at[:10]} holds no test/src/{f}") for f in files if f not in have}
    run = sorted(set(files) & have)
    if run:
        try:
            rows, _ = src_run(at, run, task, role=role)
        except SrcVoid as e:   # one file's process alone void: that file's red, `void` (Z3); more: the caller splits
            if len(run) == 1:
                return dict(out, **{run[0]: ("void", str(e)[:400])})
            raise
        if rows is None:
            raise ClimbError(f"the src run of {len(run)} file(s) at {at[:10]} wrote no result: {_}")
        out.update({f: (rows[f][0], rows[f][3]) for f in run})
    return out

def src_void_split(files, at, task, role="score"):
    """The file whose presence voids a process (spec v17 Z3): `files`, whose one process at `at` was void, run again in
    halves, one process a half (R10's shape), down to one file whose process alone is void. Returns (files, why): one
    file, or the smallest set that voids only together (named so), with the void's why."""
    def void(fs, n):
        try:
            v = src_red_at(fs, at, f"{task}-v{n}", role=role)
            w = [v[f][1] for f in fs if v[f][0] == "void"]
            return w[0] if w else None
        except SrcVoid as e:
            return str(e)
    fs, why, n = sorted(files), None, 0
    while len(fs) > 1:
        a, b = fs[:len(fs) // 2], fs[len(fs) // 2:]
        n += 1; wa = void(a, n)
        if wa:
            fs, why = a, wa; continue
        n += 1; wb = void(b, n)
        if wb:
            fs, why = b, wb; continue
        break
    if len(fs) == 1 and why is None:
        why = void(fs, n + 1)
    return fs, why or "a src process's records are void only with these files together"

def src_first(why):
    """The `first` field of a src-test red's fix-first entry and the place its key names: its first non-passing test's
    place and kind (`<file>:<line> <kind>`, the records' why). Not the red's identity, which is src_fails's multiset
    (red_id, dev/src_verdict.sh; spec v20 F4, architect round 17 4)."""
    m = re.match(r"(\S+:\d+ \S+?):", why or "")
    return m.group(1) if m else (why or "")[:120]

def src_fails(why):
    """A red's identity (spec v18 Q1, v19 Q1; the round-15 architect's finding 2, the round-16 architect's finding 2): the
    MULTISET of `<file>:<line> <kind>` of every non-passing test its row lists, as the sorted list with duplicates
    kept, read by dev/src_verdict.sh's `red_id` (`--fails`), the ONE definition the check reads too (D5)."""
    if not (why or "").strip():
        return []
    r = sh(["bash", os.path.join(ROOT, "dev", "src_verdict.sh"), "--fails"], input=why, check=True)
    return [l for l in r.stdout.splitlines() if l]

def src_reds():
    """THE registry of known reds (A13-8, D5): the src-test fix-first entries of fixfirst.json, {file: [entry, ...]},
    each a located red (`culprit`) or a flaky one (`flaky`, `passes`), keyed by its first non-passing test (`first`)."""
    out = collections.defaultdict(list)
    for e in state_json("fixfirst.json", []):
        if e["key"].startswith("src-test ") and e.get("tests"):
            for f in e["tests"]:
                out[f].append(e)
    return dict(out)

def src_known(f, why):
    """`f`'s red is a known red's: its non-passing tests, each counted, are among those a known entry of `f` lists
    (src_fails, a multiset; an entry made before v18 lists its first alone), so a new failure in a known red's file, or
    a second one at a line it lists, is a new red (spec v18 Q1, v19 Q1). A red with no listed failure is never known."""
    fs = collections.Counter(src_fails(why))
    return bool(fs) and any(all(n <= collections.Counter(e.get("fails") or [e.get("first")])[k] for k, n in fs.items())
                            for e in src_reds().get(f, []))

def src_located_reds():
    """The files of the known reds that are located (red at origin until their fix lands): the share's and unscored's
    exclusions. A flaky entry's file is not among them: it runs in every landing's set until it resolves."""
    return {f for f, es in src_reds().items() if any(not e.get("flaky") for e in es)}

def src_flaky_files():
    return {f for f, es in src_reds().items() if any(e.get("flaky") for e in es)}

def src_entry_set(key, **kw):
    update_json("fixfirst.json", [], lambda ff: [e.update(kw) for e in ff if e["key"] == key])

def src_entry_drop(key):
    update_json("fixfirst.json", [], lambda ff: ff.__setitem__(slice(None), [e for e in ff if e["key"] != key]))

SRC_GREEN = "src-green.json"   # each file's newest green run: {file: [the landings its commit holds, origin count, commit]}
SRC_LATEST = "src-latest.json"   # the newest score's src record: {"head": sha}
SRC_RING = "src-ring.json"   # the ring's state since its score (round 14's T2): {"hs", "pos" (the ring index the next landing
# starts from), "carry" (the files the last landing's fill could not take, tried first by the next), "commit"}, written when a
# landing lands (lander.landed_item)

def src_record(head):
    """The score's src record of `head`, STATE/src-<head>.tsv: (warm G or None, {file: (outcome, G, secs, why)}), or None."""
    p = os.path.join(STATE, f"src-{head[:8]}.tsv")
    if not os.path.exists(p):
        return None
    ls = open(p).read().splitlines()
    h = ls[0].split("\t")
    if h[:2] != ["head", head]:
        return None
    rows = {}
    for l in ls[1:]:
        f = l.split("\t", 4)
        rows[f[0]] = (f[1], float(f[2]) if f[2] else None, float(f[3]), f[4] if len(f) > 4 else "")   # "" unmeasured
    return (float(h[3]) if len(h) > 3 and h[3] else None), rows

def src_ran(commit, files, source):
    """A green run of `files` (paths under test/src, exactly those that ran green: never "every file") at origin's
    `commit` (a score's src part, a landing's check): each file's newest green run in ONE map, src-green.json, written
    whole by write_atomic and updated in O(files) (the operator's round-13 finding 4: the log it replaces was replayed
    whole on every lander round, 1,002 git processes at 400 records, and one cut line wedged the lander and the score).
    Each entry holds the landings the run's COMMIT holds (core.landings_at: the age src_unverified counts, in landings,
    finding 8; never the count when the record is written, which a score that yields to the lander would stamp with
    landings it never ran: the round-14 operator's finding 6, spec v17 Z7), the commit's count and the commit; an entry
    is replaced only by a newer run."""
    if not isinstance(files, list):   # a run's files named one by one, never "all" (the operator's round-13 finding 5)
        raise ClimbError(f"src_ran of {commit[:10]} names {files!r}, not the files that ran green")
    n, k = landings_at(commit), count_of(commit)
    def up(g):
        for f in files:
            if f not in g or g[f][1] <= k:
                g[f] = [n, k, commit]
    update_json(SRC_GREEN, {}, up)

def src_last_green(file, at):
    """The commit, `at` or an ancestor of it, of `file`'s newest green run (src-green.json), or None when none is recorded
    there: one read of the map and one ancestry test, whatever the history's length."""
    e = state_json(SRC_GREEN, {}).get(file)
    if not e or sh(["git", "merge-base", "--is-ancestor", e[2], at]).returncode != 0:
        return None
    return e[2]

def src_bisect(files, chain, lo, hi, task, out, role="score"):
    """Each of `files`, green at chain[lo] (lo -1: the commit before the chain) and red at chain[hi], located to the first
    commit of `chain` at which it is red: one process a step for every file still sharing a range (R10), the files
    split by their verdict there. `out` gathers {file: commit}. Its base case is a range of at most one commit: one
    commit, the culprit; none (an empty chain, a red at the very commit it last ran green), no culprit, which src_locate
    sends to the flaky rule before it bisects (the operator's round-13 finding 1: `hi - lo == 1` indexed an empty chain)."""
    if not files:
        return
    if hi - lo <= 1:
        if 0 <= hi < len(chain):
            out.update({f: chain[hi] for f in files})
        return
    mid = (lo + hi) // 2
    v = src_red_at(files, chain[mid], f"{task}-b{mid}", role=role)
    red = sorted(f for f in files if v[f][0] != "passed")
    src_bisect(red, chain, lo, mid, task, out, role)
    src_bisect(sorted(set(files) - set(red)), chain, mid, hi, task, out, role)

def src_locate(red, head, role="score"):
    """The files red at origin's `head` in the score's src part (`red`: {file: why}), located (the landing-check ruling's
    R3, R10): first run again alone at `head`, all of them in ONE process; a file green there reads differently alone
    and in its run, a note for Dale naming both runs, and it stays in R until it passes twice. Each file still red is
    bisected over origin's first-parent commits since it last ran green (src_last_green, src_bisect), one process a
    step; a file located to a commit whose own green run holds it (its landing's check ran it green there) reads
    differently alone and in that run, the same note. Every other file located is a fix-first hold, `src-test <file> red
    since <commit>`, naming its first test that did not pass, and joins R; the entry names the landed hold whose landing
    it is (`hold`), so every later move on that hold runs the file while the entry stands (src_set reads it there: no
    second record of the hold's files, which outlived the red they were for). A file whose red cannot be located (no green run
    recorded, or a run that wrote no result) is still filed, located to `head`, its why naming what is missing (D9).
    Returns {file: what was filed}."""
    task = f"locate-{head[:8]}"
    filed = {}
    try:
        alone = src_red_at(sorted(red), head, f"{task}-alone", role=role)
    except ClimbError as e:
        alone = {f: ("unread", str(e)) for f in red}
    flaky = sorted(f for f in red if alone[f][0] == "passed")
    for f in flaky:
        src_flaky(f, head, f"red in the score's run of every file at {head[:10]}, green run again alone there", red[f])
        filed[f] = "flaky"
    still = {f: (alone[f][1] or red[f]) for f in red if f not in flaky}
    where = {}   # why a file is not located (D9: never a plausible culprit)
    groups = collections.defaultdict(list)
    for f in sorted(still):
        hv = src_last_green(f, head) if alone[f][0] != "unread" else None
        if hv is None:
            where[f] = ("not located: its run alone at this head wrote no result (" + alone[f][1][:200] + ")" if alone[f][0] == "unread"
                        else "not located: no green run of it is recorded at or before this head")
        groups[hv].append(f)
    located = {}
    for hv, fs in list(groups.items()):
        if hv is None:
            continue
        chain = git("rev-list", "--first-parent", "--reverse", f"{hv}..{head}").splitlines()
        if not chain:   # red at the very commit whose own run ran it green: it reads differently there, the flaky rule
            for f in fs:
                src_flaky(f, head, f"red at {head[:10]}, whose own run recorded it green", still[f])
                filed[f] = "flaky"; still.pop(f, None)
            continue
        try:
            src_bisect(fs, chain, -1, len(chain) - 1, task, located, role)
        except ClimbError as e:
            for f in fs:
                if f not in located:
                    where[f] = f"not located: last green at {hv[:10]}, a step of its bisect wrote no result ({str(e)[:200]})"
        for f in fs:
            if f in located:
                where[f] = (f"located to {located[f][:10]} ({git('log', '-1', '--format=%s', located[f])[:80]}) by src_locate, "
                            f"green at {hv[:10]}")
    # a culprit stands only when the same locate runs the file green at the culprit's parent (spec v17 Z4, red's round-14
    # finding 5): a file red there too is red at a commit its record calls green, so it reads by something other than
    # the code (the clock, a history it found), never the culprit's: the flaky rule
    byparent = collections.defaultdict(list)
    for f, c_ in located.items():
        if f in still:
            byparent[git("rev-parse", f"{c_}^")].append(f)
    for par, fs in byparent.items():
        try:
            v = src_red_at(sorted(fs), par, f"{task}-parent", role=role)
        except ClimbError as e:
            for f in fs:
                where[f] += f"; its culprit's parent {par[:10]} wrote no result ({str(e)[:120]})"
            continue
        for f in fs:
            if v[f][0] != "passed":
                src_flaky(f, head, f"located to {located[f][:10]}, and red at that commit's parent {par[:10]} too, where its "
                          "record ran it green", still[f])
                filed[f] = "flaky"; still.pop(f, None); located.pop(f, None)
    green = state_json(SRC_GREEN, {})
    for f, why in sorted(still.items()):
        at = located.get(f)
        if at and f in green and green[f][1] >= count_of(at):   # a run at or after its culprit read it green
            src_flaky(f, head, f"located to {at[:10]}, whose own run ran it green, and red there alone", why)
            filed[f] = "flaky"; continue
        key = f"src-test {f} red since {(at or head)[:8]} at {src_first(why)}"
        hold = next((e.get("hold_id") for e in events() if e["kind"] == "landed" and at and e.get("commit") == at), None)
        add_fixfirst([{"key": key, "tests": [f], "first": src_first(why), "fails": src_fails(why), "culprit": at, "flaky": False, "hold": hold,
                       "why": f"test/src/{f} is red at {head[:10]}: {why[:300]}; {where[f]}. Make it pass at its source (D12); "
                       "the move's landing check runs it"}])
        event("src-located", file=f, at=head[:8], culprit=(at or "")[:8], hold=hold, key=key)
        filed[f] = key
    return filed

def src_flaky(f, head, how, why):
    """A file that reads differently alone and in a run with others (`how`), its failure `why`: a known red of its own
    (red's round-13 finding 7), a fix-first entry keyed by its first failing test, aging under fixfirst_max_landings like
    every known red, counted by src_unverified, run in every landing's set until it passes twice (a score's run or a
    landing's check); a note for Dale naming both runs. A different failure of the file is a new red."""
    first = src_first(why)
    key = f"src-test {f} flaky at {first}"
    add_fixfirst([{"key": key, "tests": [f], "first": first, "fails": src_fails(why), "flaky": True, "passes": 0, "culprit": None,
                   "why": f"test/src/{f} reads differently alone and in a run with others ({how}): {why[:300]}. Make its result "
                   "independent of what runs beside it (its order, its process); every landing runs it until it passes twice"}])
    event("src-flaky", file=f, at=head[:8], first=first, how=how[:200])
    alarm(f"src-flaky-{hashlib.sha1(key.encode()).hexdigest()[:8]}", f"a test file reads differently alone: {f}",
          f"test/src/{f} at {head[:10]}: {how}; its failure: {why[:300]}. Default taken: a known red (the fix-first `{key}`), "
          "run in every landing's set and aging under fixfirst_max_landings until it passes twice.")

def src_flaky_passed(files):
    """The flaky known reds whose file ran green in a whole run (a score's, a landing's check): one pass each; resolved
    at the second."""
    for f in files:
        for e in src_reds().get(f, []):
            if e.get("flaky"):
                if e.get("passes", 0) + 1 >= 2:
                    src_entry_drop(e["key"]); event("src-resolved", file=f, key=e["key"])
                else:
                    src_entry_set(e["key"], passes=e.get("passes", 0) + 1)

def src_score(head, role="score"):
    """The score's src part (R6): every file of T(head) run at origin's `head` in one process (src_run, the score role,
    yielding to a waiting lander at file boundaries, its files' seconds learned), recorded in STATE/src-<head>.tsv (each
    file's outcome, cost and seconds, and the warm-up), a green run kept (src_ran), the known reds it ran green resolved
    (a located red at once, a flaky one at its second pass: its fix-first entry removed), and every other red located
    (src_locate). A run with no result records nothing (D9): its head is not verified. Returns (rows, warm) or None."""
    t0, files = door.CLOCK(), src_files(head)
    voided = {}
    try:
        rows, warm = src_run(head, files, f"score-{head[:8]}", role=role, learn_=True, yields=True)
    except SrcVoid as e:   # a void process is located, never only an event (spec v17 Z3): narrowed to the file whose
        fs, why = src_void_split(e.files, head, f"void-{head[:8]}", role)   # presence voids it, then located over commits
        voided = {f: why for f in fs}
        event("src-void-located", sha=head[:8], files=fs, why=why[:300])
        for_dale("a test file voids its process", f"At the score of {head[:10]}, test/src/{', test/src/'.join(fs)} makes "
                 f"its process's records void: {why[:400]}. Default taken: located as a red (src_locate), filed fix-first, "
                 "and the score's other files run again without it.")
        try:
            rows, warm = src_run(head, [f for f in files if f not in voided], f"score-{head[:8]}-novoid", role=role, learn_=True, yields=True)
        except SrcVoid as e2:
            rows, warm = None, str(e2)
        if rows is not None:
            rows.update({f: ("void", None, 0.0, f"void: {why}"[:400]) for f in voided})
    if rows is None:
        event("src-failed", sha=head[:8], why=warm[-300:] if isinstance(warm, str) else "")
        return None
    write_atomic(os.path.join(STATE, f"src-{head[:8]}.tsv"), f"head\t{head}\twarm\t{'' if warm is None else warm}\n" +
                 "".join(f"{f}\t{o}\t{'' if g is None else g}\t{s_}\t{w}\n" for f, (o, g, s_, w) in sorted(rows.items())))
    green = sorted(f for f, r in rows.items() if r[0] == "passed")
    src_ran(head, green, "score")
    write_atomic(os.path.join(STATE, SRC_LATEST), json.dumps({"head": head}))
    prune_newest(os.path.join(STATE, "src-*.tsv"), SRC_KEEP)          # the score's records and plans grow one a score
    prune_newest(os.path.join(STATE, "src-plan-*.json"), SRC_KEEP)    # (the round-14 operator's finding 8, spec v17 Z7)
    for f, es in src_reds().items():   # the known reds this run read: resolved, kept, or a new failure of the file
        for e in es:
            if f not in rows:   # removed (L227 names a removal): nothing of it stands
                src_entry_drop(e["key"]); event("src-resolved", file=f, key=e["key"], why="removed")
            elif rows[f][0] == "passed" and not e.get("flaky"):
                src_entry_drop(e["key"]); event("src-resolved", file=f, at=head[:8], key=e["key"])
            elif rows[f][0] != "passed" and e.get("flaky"):
                src_entry_set(e["key"], passes=0)
    src_flaky_passed([f for f in green if f in src_flaky_files()])
    new = {f: r[3] or r[0] for f, r in rows.items() if r[0] != "passed" and not src_known(f, r[3] or r[0])}
    if len(voided) > 1:   # files that void a process only together: one entry naming them, located to this head (D9)
        add_fixfirst([{"key": f"src-test {' '.join(sorted(voided))} void together at {head[:8]}", "tests": sorted(voided),
                       "first": "void", "culprit": None, "flaky": False, "hold": None,
                       "why": f"these test files void their process together at {head[:10]}: {next(iter(voided.values()))[:300]}"}])
        new = {f: w for f, w in new.items() if f not in voided}
    filed = src_locate(new, head, role) if new else {}
    event("src-scored", sha=head[:8], files=len(files), red=len(files) - len(green), new=len(new), filed=len(filed),
          warm=warm, secs=round(door.CLOCK() - t0))
    return rows, warm

# ---- a landing's test set (the landing-check ruling's R1, R2, R5; step 3: computed and recorded for every landing,
# not yet applied, so its prediction is measured against the judged path of real checks)
def src_latest(at):
    """The newest score's src record (src-latest.json, written by src_score), when its head is `at` or an ancestor of it:
    (its head, warm G or None, {file: row}) or None; one read and one ancestry test, never a scan of every record."""
    h = state_json(SRC_LATEST, {}).get("head")
    if not h or sh(["git", "merge-base", "--is-ancestor", h, at]).returncode != 0:
        return None
    rec = src_record(h)
    return None if rec is None else (h, rec[0], rec[1])

def src_target(band, src_change):
    """THE target a landing's test set is cut to (round 13's ruling S3, D5: a number that moves with the model and the
    machine is computed at its one source, never set by hand), for a landing of the shape `src_change`: D14's band
    (`band`, origin's dev/check.sh D14_RED) less a margin, one-sided, robust, per shape and bounded (spec v17 Z5; the
    round-14 architect's finding 4, red's 7):
      - its errors: judged less predicted, POSITIVE only (a check faster than predicted never threatens D14), of the last
        src_margin_checks checks of this shape whose prediction the lander recorded before they ran, not ended by the power rule, that
        passed and landed OR read red on D14's band alone (spec v18 Q5, the round-15 architect's finding 5: the errors
        that cross the band are exactly the ones the margin must see; every check that ran passed the lander's quiet
        probe); a check red on its tests teaches nothing here;
      - the margin: three times the SECOND-largest of them (one outlier moves nothing), between src_margin_min_s and
        src_margin_max_s; src_margin_start_s until that many checks exist;
      - its range: the largest set in G those errors were measured on (`gmax`): src_set admits no set larger than it
        by more than one file, so the model is never trusted past the sets it was checked on (none until a check of the
        shape exists).
    A margin that would pass src_margin_max_s is one note for Dale, once per crossing of the cap. Returns (target,
    {margin, gmax, why, ...})."""
    c = cfg()
    n = c["src_margin_checks"]
    pairs = [(e, round(e["path"] - e["src_set"]["predicted"]["path"], 1)) for e in events()
             if e["kind"] == "ship" and (e.get("check") == 0 and str(e.get("result", "")).startswith("LANDED") or e.get("check") == 10)
             and (e.get("src_set") or {}).get("src_change") is bool(src_change) and e.get("path") is not None
             and judged_check(e)   # quiet at its start and its end, and not cut by battery (throughput P0)
             and isinstance(((e.get("src_set") or {}).get("predicted") or {}).get("path"), (int, float))][-n:]
    gmax = max([e["src_set"].get("ran_cost") or 0.0 for e, _ in pairs], default=None)
    shape = "a change to src/" if src_change else "a change outside src/"
    if len(pairs) < n:
        raw = margin = c["src_margin_start_s"]
        info = {"margin": margin, "checks": len(pairs), "gmax": gmax,
                "why": f"{len(pairs)} of {n} checks of {shape} (landed, or red on D14 alone) predicted before they ran: the start margin"}
    else:
        pos = sorted((err for _, err in pairs if err > 0), reverse=True)
        second = pos[1] if len(pos) > 1 else 0.0
        raw = round(3 * second, 1)
        margin = min(c["src_margin_max_s"], max(c["src_margin_min_s"], raw))
        info = {"margin": margin, "checks": len(pairs), "gmax": gmax, "second": second, "largest": pos[0] if pos else 0.0,
                "why": f"3 x {second:+} s, the second-largest positive error of the last {n} checks of {shape} (landed, or red on D14 alone)"
                       + (f", capped at src_margin_max_s" if raw > margin else "")}
    target = round(band - margin, 1)
    over = raw > c["src_margin_max_s"]
    st = state_json("src-margin.json", {})
    if st.get(shape) != over:   # once per crossing of the cap, either way
        write_atomic(os.path.join(STATE, "src-margin.json"), json.dumps(dict(st, **{shape: over})))
        if over:
            for_dale("a landing's test set holds little: its prediction errs widely",
                     f"For {shape} the margin would be {raw} s, past src_margin_max_s ({c['src_margin_max_s']} s): {info['why']}. "
                     f"The target is held at {target} s under D14's {band}. Default taken: shares stay small until the "
                     "errors fall back; the model is the lead's to look at.")
    return target, info

def checks_measured(n=5):
    """The split of the last `n` landing checks OF EACH SHAPE (a change to src/, one outside it: the src_change its
    lander recorded) not ended by the power rule (probe.battery) whose tests all passed, green or red on D14's time alone (`ship` events, step 2: a D14 red is
    a whole check, and leaving it out would read the machine faster than it ran), in their order, each with the files it
    ran: the measures predict() reads, never a number made up (D9). Per shape, since a change to src/ reads its files
    slower than the score's costs (its changed image compiles more, round 13's ruling S2), so a run of one shape never
    pushes the other's measures out."""
    es = [e for e in events() if e["kind"] == "ship" and e.get("check") in (0, 10) and e.get("split") and
          judged_check(e) and (e.get("src_set") or {}).get("src_change") in (True, False)]
    keep = {id(e) for shape in (True, False) for e in [x for x in es if x["src_set"]["src_change"] is shape][-n:]}
    return [e for e in es if id(e) in keep]

def src_costs(rows, files, at):
    """Each of `files`' cost in G: its row of the score's record, or, for a file the score did not run (unscored), its
    size at `at` at the scored files' G per byte (test/src_tests.jl's own rule for an unmeasured file), named."""
    have = {f: r[1] for f, r in rows.items() if r[0] == "passed" and r[1] is not None}   # unmeasured: by size, named
    sizes = {p[len(SRC_DIR):]: int(sz) for sz, p in (l.split()[3:5] for l in git("ls-tree", "-r", "-l", at, "--", SRC_DIR).splitlines())
             if p.endswith(".jl")}
    rate = sum(have.values()) / max(1, sum(sizes.get(f, 0) for f in have))
    return {f: have[f] if f in have else sizes.get(f, 0) * rate for f in files}, sorted(f for f in files if f not in have)

def predict(costs, warm, src_change, shards, checks):
    """The critical path a check of the files `costs` ({file: G}) would read (the landing-check ruling's B.2): the files
    by longest processing time over `shards`, each shard read as c0 + its files' G / g judged seconds, c0 its measured
    start plus the warm-up its first file pays (the score's record's `warm`); the slowest shard at least the mean plus
    the checks' imbalance; beside the ratchet, plus the load of a check of its shape. Each term is the measured checks'
    when they hold it and a declared prior (DEFAULTS `src_prior_*`, measured on this machine) until they do (round 14's
    T3: a launch has priors, never "every file"):
      - g and the start: the predicted shape's own checks with measured starts once src_shape_checks_min exist, else
        the other shape's once it has that many (S2), else the priors (`src_prior_g` of the shape, `src_prior_start_g`);
      - the load: the median of the shape's measured loads from its first measured check, else `src_prior_load_s`;
      - the ratchet and the imbalance: the medians of the measured checks from the first, else `src_prior_ratchet_s`
        and `src_prior_imbalance_s`.
    `model` names which. Returns ({path, shards, ratchet, load, g, c0, imbalance, model}, None), or (None, why) when the
    score's record holds no warm-up (no score: the set is then every file, src_handed)."""
    if warm is None:
        return None, "the score's record holds no warm-up cost"
    c = cfg()
    rat, gap = [], []
    measured = {True: [], False: []}   # each shape's checks with measured shard starts: its own g and c0 (S2)
    load = {True: [], False: []}   # each shape's measured load stage: a shard's measured start begins after it
    for e in checks:
        sp, ran = e["split"], (e.get("src_set") or {}).get("ran_cost")
        shape = (e.get("src_set") or {}).get("src_change")
        if ran and sp.get("shards"):
            js = [x[0] for x in sp["shards"]]
            gap.append(max(js) - sum(js) / len(js))
            if sp.get("starts") and len(sp["starts"]) == len(js) and shape in (True, False):   # each shard's start (A13-7)
                # each shard pays the warm-up once more on its first file (the shared first compile the score pays once and
                # keeps off every file's cost, its record's `warm`): the shards' own records read 230-375 G over the
                # score's cost on each shard's first file (step 6's re-run, 2026-11-11), so it is a term of every shard
                measured[shape].append((ran + sum(sp["starts"]) + len(js) * warm, sum(js), sorted(sp["starts"])[len(sp["starts"]) // 2]))
        if sp.get("ratchet"):
            rat.append(sp["ratchet"][0])
        if sp.get("load") and shape in (True, False):
            load[shape].append(sp["load"][0])
    med = lambda xs: sorted(xs)[len(xs) // 2]
    key = "src" if src_change else "outside"
    own, other, nmin = measured[bool(src_change)], measured[not src_change], c["src_shape_checks_min"]
    shape_name = "a change to src/" if src_change else "a change outside src/"
    use = own if len(own) >= nmin else other if len(other) >= nmin else None
    if use is not None:
        g = sum(w for w, _, _ in use) / max(1, sum(s_ for _, s_, _ in use))
        c0 = (med([st for _, _, st in use]) + warm) / g   # its start, then the warm-up its first file pays
        model = (f"c0 measured, g over {len(use)} checks of {shape_name}" if use is own else
                 f"c0 measured, g over {len(use)} checks of the other shape ({shape_name} has {len(own)}, under {nmin})")
    else:   # too few measured checks of either shape: the declared priors, until src_shape_checks_min exist (T3)
        g = c["src_prior_g"][key]
        c0 = (c["src_prior_start_g"] + warm) / g
        model = f"priors (g, start: {len(own)} of {shape_name}'s checks and {len(other)} of the other's measured, under {nmin})"
    ld = med(load[bool(src_change)]) if load[bool(src_change)] else c["src_prior_load_s"][key]
    rt = med(rat) if rat else c["src_prior_ratchet_s"]
    imb = med(gap) if gap else c["src_prior_imbalance_s"]
    if not load[bool(src_change)] or not rat or not gap:
        model += "; prior " + ", ".join(n for n, m in (("load", load[bool(src_change)]), ("ratchet", rat), ("imbalance", gap)) if not m)
    bins = [0.0] * shards
    for f in sorted(costs, key=lambda f: (-costs[f], f)):
        i = min(range(shards), key=lambda k_: bins[k_]); bins[i] += costs[f]
    sj = [round(c0 + b / g, 1) for b in bins]
    # the slowest shard is never under the mean by the checks' own imbalance: the shards claim files from one queue as
    # they finish, and one shard carries the node and wasm-opt children's unreported seconds, so the measured checks'
    # slowest shard stood 4-10 s above their mean where the balanced bins read none (step 4's quiet re-measure)
    slow = max(max(sj), sum(sj) / len(sj) + imb)
    return {"path": round(ld + max(rt, slow), 1), "shards": sj, "ratchet": rt, "load": ld, "g": round(g, 2),
            "c0": round(c0, 1), "imbalance": round(imb, 1), "model": model}, None

def src_plan(hs, rows):
    """What a score fixes of its ring (round 14's T2): the scored files in path order with their costs, and T their
    total; written once a score, never a capacity. Each landing fills its share from the ring's position under its own
    live target (src_set), so no target of one moment is frozen into the ring."""
    p = os.path.join(STATE, f"src-plan-{hs[:8]}.json")
    if os.path.exists(p):
        plan = json.load(open(p))
        if "Q" not in plan:   # a plan of the frozen-capacity kind is made again in this one's form
            return plan
    passed = sorted(f for f, r in rows.items() if r[0] == "passed")
    cost = src_costs(rows, passed, hs)[0]   # an unmeasured row (a restart's first file) at its size's estimate
    plan = {"head": hs, "ring": [[f, round(cost[f], 1)] for f in passed], "T": round(sum(cost.values()), 1), "t": stamp()}
    write_atomic(p, json.dumps(plan))
    return plan

def src_unfit(hs, unfit, src_change, target):
    """LC-A at a landing's own target: the files its fill could not take and that predict past the target alone, so no
    share of that shape holds them at today's measures and target; one event `src-unfit` and one note for Dale each time
    the set changes (an empty set again included). The ring still carries them, the score runs them, and
    src_unverified_max bounds the landings they stand unrun; splitting a file is the lead's move."""
    names, key = sorted(f for f, _ in unfit), "src-unfit:" + ("src" if src_change else "outside")
    # keyed per shape (the round-14 operator's finding 8, spec v17 Z7): the two shapes' sets differ, and one key read the
    # alternation of landings of either shape as a change each time, a note a landing
    if state_json("alarms.json", {}).get(key) == names:
        return
    update_json("alarms.json", {}, lambda a: a.__setitem__(key, names))
    shape = "a change to src/" if src_change else "a change outside src/"
    event("src-unfit", sha=hs[:8], files=[{"file": f, "cost": c} for f, c in unfit], shape=shape, target=target)
    for_dale("test files a landing's share cannot hold" if unfit else "every test file fits a landing's share again",
             (f"At a target of {target} s, {shape} cannot hold " + ", ".join(f"test/src/{f} ({c} G)" for f, c in unfit) +
              " alone. Default taken: they stay on the ring and are carried; the score runs them (R2), and the lander holds "
              "at src_unverified_max landings; splitting a file is the lead's move.") if unfit else "Default taken: none.")

def src_index(h, hs):
    """Landing i since the score: the landings origin's head `h` holds past the scored head `hs` (R2's window index;
    landings, never commits: a hand item of k commits is one landing, and skips no window: the round-14 architect's
    finding 8, spec v17 Z7)."""
    return landings_at(h) - landings_at(hs)

def src_set(h, sha, hold_id):
    """The test files a landing of `sha` onto origin's head `h` would run (the landing-check ruling's R1, R2, R7; the files
    it hands the check, src_handed): `own`, the test files the diff h..sha adds or edits (git diff --raw --no-renames, A and M
    under test/src) and those of the src-test fix-first entries standing for its hold (the culprit's hold, or the
    entry's own), never cut; `unscored`, the files of h the score's record
    does not hold, never cut; the `share`, the ring's window of this landing (its index i the landings since the score:
    the files whose start lies in [(i·Q) mod T, (i·Q) mod T + Q)), less own, unscored and the known reds R, taken in the
    window's order while the predicted path of own ∪ unscored ∪ share stays within the live target (src_target), a file that would
    pass it left out (`dropped`). Also the prediction of every file (`all`, what the check would read running them
    all) and whether own ∪ unscored alone predicts past D14's band (`refuse`: the move is refused before its check);
    src_handed adds the files run (`ran`) and their cost (`ran_cost`). Returns a dict, or {"why": ...} when it cannot be
    made."""
    rec = src_latest(h)
    if rec is None:
        return {"why": f"no score's src record at {h[:10]} or before it"}
    hs, warm, rows = rec
    m = re.search(r"^SHARDS=(\d+)", git("show", f"{h}:dev/check.sh"), re.M)
    band = re.search(r"^D14_RED=(\d+)", git("show", f"{h}:dev/check.sh"), re.M)
    if not m or not band:
        return {"why": f"{h[:10]}:dev/check.sh names no SHARDS or D14_RED"}
    shards, checks = int(m.group(1)), checks_measured()
    t_sha, t_h = set(src_files(sha)), src_files(h)
    raw = git("diff", "--raw", "--no-renames", "-z", *DIFF, h, sha, "--", SRC_DIR).split("\0")
    own = {p[len(SRC_DIR):] for st, p in zip(raw[0::2], raw[1::2]) if st.split()[-1:] in (["A"], ["M"]) and p.endswith(".jl")}
    # a src-test red's file runs in every move of the hold whose landing it is located to (`hold`) and of the entry's own
    # hold (its fix): read from the standing entries alone, so it leaves the set when its entry is cleared
    own |= {f for es in src_reds().values() for e in es if hold_id and hold_id in (e.get("hold"), hashlib.sha1(e["key"].encode()).hexdigest()[:10])
            for f in e["tests"]} & t_sha
    reds = src_located_reds()
    flaky = (src_flaky_files() & t_sha) - own
    # (a file of h the score did not run green and that is no known red: never left out for want of a cost, D9)
    unscored = {f for f in set(t_h) & t_sha if rows.get(f, ("",))[0] != "passed"} - reds - own - flaky
    src_change = sh(["git", "diff", "--quiet", h, sha, "--", "src", "Project.toml"]).returncode != 0
    out = {"hs": hs[:10], "own": sorted(own), "unscored": sorted(unscored), "flaky": sorted(flaky), "src_change": src_change,
           "reds": sorted(reds & t_sha)}
    every, est = src_costs(rows, sorted(t_sha - reds), sha)
    pa, why = predict(every, warm, src_change, shards, checks)
    out["all"], out["estimated"] = pa or {"why": why}, est
    target, margin = src_target(int(band.group(1)), src_change)   # D14's band less this shape's measured margin (S3, Z5)
    out["target"], out["margin"] = target, margin
    plan = src_plan(hs, rows)
    names = [f for f, _ in plan["ring"]]
    rs = state_json(SRC_RING, {})
    pos = rs.get("pos", 0) % max(1, len(names)) if rs.get("hs") == hs[:10] else 0   # a new score's ring starts at 0
    base_set = sorted(own | unscored | flaky)   # a flaky known red runs in every landing until it resolves (red 7)
    c_all, _ = src_costs(rows, sorted(set(base_set) | (set(names) & t_sha) | set(rs.get("carry", [])) & t_sha), sha)
    pb, why = predict({f: c_all[f] for f in base_set}, warm, src_change, shards, checks)
    if pb is None:
        out["why"] = why; return out
    out["refuse"] = pb["path"] > int(band.group(1))
    # the share (round 14's T2): the files the last landing could not take first (deficit round robin, A13-6), then the
    # ring from its position, each taken while the set predicts within THIS landing's target. A ring file that does not
    # fit is passed over and carried, never ending the window (e6029f5d: one heavy file at the position left a share of
    # the own files alone, the T3 probe's 1 of 59), and the position advances past the last file taken; the files after
    # it were not reached and stay ahead of the position. With none taken the first file is carried and the position
    # advances one, so each landing moves the ring on and a carried file runs at the first landing whose target holds it
    skip = set(base_set) | reds | flaky
    # within the target, and within the range the margin's errors were measured on (Z5): a set's G less its last file
    # never past `gmax`, the largest set this shape's margin was measured on; no range until a check of the shape exists
    gmax = margin.get("gmax")
    in_range = lambda fs: gmax is None or not fs or sum(c_all[x] for x in base_set + fs[:-1]) <= gmax
    fits = lambda fs: in_range(fs) and predict({x: c_all[x] for x in base_set + fs}, warm, src_change, shards, checks)[0]["path"] <= target
    kept, dropped = [], []
    carry = [f for f in rs.get("carry", []) if f in t_sha and f not in skip] if rs.get("hs") == hs[:10] else []
    for f in carry:
        (kept if fits(kept + [f]) else dropped).append(f)
    passed, last = [], None
    for k in range(len(names)):
        f = names[(pos + k) % len(names)]
        if f in skip or f not in t_sha or f in carry:
            continue
        if fits(kept + [f]):
            kept.append(f); last = k
        else:
            passed.append((k, f))
    if last is not None:
        dropped += [f for k, f in passed if k < last]   # passed over on the way to the last file taken: carried
        considered = last + 1
    else:
        dropped += [f for _, f in passed[:1]]   # nothing fits: the first file is carried and the ring moves one
        considered = passed[0][0] + 1 if passed else 0
    pos_next = (pos + considered) % max(1, len(names))
    share = kept
    pr, _ = predict({f: c_all[f] for f in base_set + share}, warm, src_change, shards, checks)
    lone = [[f, round(c_all[f], 1)] for f in dropped if predict({f: c_all[f]}, warm, src_change, shards, checks)[0]["path"] > target]
    src_unfit(hs, lone, src_change, target)
    i, T = src_index(h, hs), plan["T"]
    out.update({"i": i, "T": T, "pos": pos, "pos_next": pos_next, "considered": considered, "carried": carry, "share": share,
                "dropped": dropped, "unfit": [f for f, _ in lone], "predicted": pr, "own_unscored": pb})
    return out

def src_handed(ss, h, sha):
    """The files a landing's check of `sha` onto origin's head `h` runs, from its set `ss` (src_set): own ∪ unscored ∪
    share; a set that could not be made (`ss` holds only its why) is refused, never every file (spec v18 Q2). `ss` gains `ran` and `ran_cost` (the score's costs of the files run, what predict()
    calibrates against). Returns the sorted files."""
    if "share" not in ss:   # never every file (spec v18 Q2): the lander refuses before it asks (landing_set)
        raise ClimbError(f"src_handed with no set made: {ss.get('why', 'no set')}")
    files = sorted(set(ss["own"]) | set(ss["unscored"]) | set(ss.get("flaky", [])) | set(ss["share"]))
    rec = src_latest(h)
    ss["ran"], ss["ran_cost"] = files, round(sum(src_costs(rec[2], files, sha)[0].values()), 1) if rec else None
    return files

def src_unverified(h):
    """The landings (the landing log's, never commits: the operator's round-13 finding 8) since every test file of
    origin's head `h` last ran green (src-green.json: a score's run, a landing's check), the known reds left out (they
    stand named, bounded by fixfirst_max_landings): the count src_unverified_max bounds (R5, R12), so a run of failed
    scores cannot leave files unrun for good. O(files): one map, the landing log and one listing of `h`. A file with no
    green run counts every landing. Returns (count, the files furthest behind)."""
    green, n = state_json(SRC_GREEN, {}), len(landings())
    reds = src_located_reds()   # a flaky known red stays counted (red 7): no landing's run may leave it unrun
    behind = {f: n - (green[f][0] if f in green else 0) for f in src_files(h) if f not in reds}
    worst = max(behind.values(), default=0)
    return worst, sorted(f for f, k in behind.items() if k == worst)[:5]

def tail_problems(h, base, sha, before, after, task):
    """A src-tail move is measured on what cannot be forged (item 10): each passing case it adds, run at the base
    with the move's corpus (the base's src, origin's code, compiles it), stops at one of the hold's definitions. A
    definition the move leaves unported stays a hold at the next score (the scoreboard's kinds, origin's code)."""
    added = sorted(l for l, r in after.items() if l not in before and r[1] == "passed")
    if not added:
        return ["a src-tail move that adds no passing corpus case reaching what it ports (D12)"]
    units = [n for _, _, st, n in changes(base, sha) if st == "A" and is_unit(n)]
    rows, why = smoke("measure", set(added), f"{task}-tailbase", base,   # the base's src, the move's unit files over its corpus
                      overlay={n: sh(["git", "show", f"{sha}:{n}"], check=True).stdout for n in units})
    if rows is None:
        return [f"src tail: the added cases at the base: {why}"]
    problems = []
    for l in added:
        r = rows.get(l)
        at = " ".join(site_def(unported_site(r[3]) or "")).strip() if r else ""
        if not r or r[1] != "unported" or at not in h["defs"]:
            problems.append(f"src tail: the added case {l} at the base {'is ' + r[1] + (' at ' + at if at else '') if r else 'did not run'}, "
                            "not stopped at one of the hold's definitions: it does not reach what the move ports")
    return problems

def fixfirst_problems(h, base, sha):
    """An audit's fix-first move touches the finding's path:line (architect 6): a hunk of base..sha within
    fixfirst_lines of it (holds() admits no audit finding without one)."""
    m = re.match(r"([\w/.-]+):(\d+) ", h.get("why", "")) if h.get("fixfirst") and h["key"].startswith("audit ") else None
    if not m:
        return []
    path, line, k = m.group(1), int(m.group(2)), cfg()["fixfirst_lines"]
    return [] if touched(base, sha, [(path, line - k, line + k)]) else [f"the audit finding's {path}:{line} is not touched by the diff"]

def rebased(base, sha, onto):
    """`sha`'s one commit on `base` replayed onto `onto` by the one merge a landing makes (R6-8, D5): git's merge-tree
    (plumbing in the main repository, no work tree) with `onto`'s packages merge driver, dev/merge_packages.sh, as
    dev/ship.sh's rebase runs it, the attributes read from `onto`'s tree; when that driver merged
    src/julia/packages.jl, its blocks are regenerated from the merged tree as ship.sh's rebase step does (door.REGEN
    as the landing user, on a fresh depot, in the driver's climb-regen worktree), so the commit measured is the commit
    ship.sh lands (A7-5: its parent is origin's head, so ship.sh's rebase replays nothing), packages.jl included. Returns (commit, None), (None, None) on a conflict, or (None, why) when the
    regeneration failed (the commit's own: its src breaks the generator)."""
    drv, mark = os.path.join(STATE, "merge_packages.sh"), os.path.join(STATE, f".packages-merged-{os.getpid()}")
    write_atomic(drv, git("show", f"{onto}:dev/merge_packages.sh") + "\n")
    with contextlib.suppress(FileNotFoundError):
        os.remove(mark)
    r = sh(["git", "-c", f"attr.tree={onto}", "-c", "merge.wt-packages.name=src/julia/packages.jl, its generated blocks blanked",
            "-c", f"merge.wt-packages.driver=bash {drv} %O %A %B", "merge-tree", "--write-tree", "--no-messages",
            f"--merge-base={base}", onto, sha], env=dict(os.environ, WT_PACKAGES_MERGED=mark))
    if r.returncode != 0:
        return None, None
    msg = sh(["git", "log", "-1", "--format=%B", sha], check=True).stdout
    # the commit keeps its author and author date, as ship.sh's rebase kept them (D13's edit-to-landed reads the author
    # time); its committer is the climb's
    an, ae, ad = sh(["git", "log", "-1", "--format=%an%n%ae%n%ad", "--date=raw", sha], check=True).stdout.split("\n")[:3]
    who = dict(os.environ, GIT_AUTHOR_NAME=an, GIT_AUTHOR_EMAIL=ae, GIT_AUTHOR_DATE=ad, GIT_COMMITTER_NAME="climb",
               GIT_COMMITTER_EMAIL="climb@localhost")
    commit = lambda tree: sh(["git", "commit-tree", tree, "-p", onto, "-m", msg], env=who, check=True).stdout.strip()
    at = commit(r.stdout.split()[0])
    if not os.path.exists(mark):
        return at, None
    os.remove(mark)
    wt = os.path.join(WORKTREES, "climb-regen")
    if not os.path.isdir(wt):
        common_write("the regen worktree")
        git("worktree", "add", "-q", "--detach", wt, at)
    git("checkout", "-q", "-f", "--detach", at, cwd=wt)
    for n, text in environment(at).items():
        safe_write(os.path.join(wt, n), text)
    try:
        rc = door.land_job(wt, door.REGEN, "regen.log", ["src/julia/packages.jl"], cfg()["pkg_wall_s"],
                           background=True, check=False)   # under the caller's verify lock and at background QoS (D31,
                                                           # A7-5); no test runs, so no test set is named
    except door.Tick as e:   # cut by the power rule: no verdict on the commit, redone when work may run (on_ac)
        if e.why == "power":
            raise PowerCut(f"the packages regeneration of {at[:10]}: {e}") from e
        raise
    if rc == door.DOOR_FAILED:
        raise ClimbError(f"the packages regeneration of {at[:10]}: the door failed ({wt}/.wtd/regen.log)")
    if rc != 0:
        return None, f"src/julia/packages.jl's regeneration on origin {onto[:10]} failed (exit {rc}): " + \
            open(os.path.join(wt, ".wtd", "regen.log"), errors="replace").read()[-400:]
    blob = sh(["git", "hash-object", "-w", "--stdin"], input=open(os.path.join(wt, "src/julia/packages.jl")).read(), cwd=REPO,
              check=True).stdout.strip()
    ls = [f"100644 blob {blob}\tsrc/julia/packages.jl" if l.endswith("\tsrc/julia/packages.jl") else l
          for l in sh(["git", "ls-tree", "-r", "--full-tree", at], check=True).stdout.splitlines()]
    return commit(tree_of("\n".join(ls) + "\n")), None

def measure_candidate(h, base, sha, labels, before, task, onto=None, keep=None):
    """One measurement of a candidate, shared by a move's gates and the lander's rebased check (architect cut): the
    commit (replayed onto `onto`, origin, for the lander), its three roles as the measure user (smoke(), native
    answers from the corpus of its base or of `onto`), and its judgement against `before` (measured at the base, or
    the table for `onto`), the tail's and a fix-first's measured checks beside it. G5 is the caller's, on base..sha,
    before this. Returns (unlocked, problems, rows, fault, at): rows every label measured, fault "conflict" when it
    does not apply on `onto`, "regen" when its packages' regeneration there failed, "output" when the smoke wrote no
    cases, "done" when origin passes every case of the hold already, else None; `at` the commit measured."""
    with julia_slot("verify", first=onto is not None):
        at, why = rebased(base, sha, onto) if onto else (sha, None)
        if why:
            return [], [why], [], "regen", None
        if at is None:
            return [], [f"it does not apply on origin {onto[:10]} (git merge-tree: a conflict)"], [], "conflict", None
        after, why = smoke("measure", labels, task, at, known=set(table()) | set(before), keep=keep)
        if after is None:   # the move's tree: its own fault until shown otherwise (a src change that breaks the load)
            return [], [why], [], "output", at
        if onto:
            before = confirmed(onto, before, after)
            if h["cases"] and all(before.get(l, ("", ""))[1] == "passed" for l in h["cases"]):
                return [], ["done by another landing: every case of its hold passes at origin"], [], "done", at
        extra = tail_problems(h, base, sha, before, after, task) if h.get("tail") else []
        unlocked, problems = judge_move(h, onto or base, base, sha, labels, before, after)
    return unlocked, problems + extra + fixfirst_problems(h, base, sha), sorted(after.values()), None, at

def job_text(h, base, sha):
    """What a reviewer is told the move was for when the diff alone cannot say: a tail move's definitions, a fix-first
    finding, and the test/src lines it removes, as refusal-4 candidates (12)."""
    j = ""
    if h.get("tail"):
        j = ("This move is to port these definitions, each with a body:\n" + "\n".join(f"- {d}" for d in h["defs"]) +
             "\nConfirm each is ported with a body; a definition left rejection-only, or missing, is a blocker (refusal 3).")
    elif h.get("fixfirst"):
        j = ("This move is to resolve this finding:\n" + h["why"][:1500] +
             "\nConfirm the diff resolves it at its source; a finding left unresolved is a blocker.")
    removed = [l for l in lines(git("diff", *DIFF, "-U0", base, sha, "--", "test/src/"), "-") if l.strip()]
    if removed:
        j += ("\n\nThe commit removes these lines from test/src/: for each, is the check it made still made? A test that "
              "checks less is refusal 4:\n" + "\n".join(f"- {l.strip()[:160]}" for l in removed[:40]))
    return j
