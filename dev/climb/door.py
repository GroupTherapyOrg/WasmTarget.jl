#!/usr/bin/env python3
"""dev/climb/door.py — the one door between Dale's uid and the climb's build users (dev/climb/HILL.md, "The door").

Dale's uid never executes anything an agent or a candidate wrote, and never runs an interpreting tool in a tree they
wrote: every process that loads repository code or acts on a model's output (an agent, a Kaimon server and its
sessions, every Julia, node and java of a measurement, a score, a parse, a landing check and a regen) runs as a build
user that dev/climb/setup-users.sh made, through run() and popen() here alone, and comes back as data through take().
Precedent: Nix's build users (nixbld*, a build's processes killed by user, on macOS inside a sandbox-exec profile).
How Julia differs: an agent needs the network to reach its model, so an agent's `agent` profile opens one localhost
port, the driver's proxy() to its model, which alone holds the agents' token; every Julia job runs under the `julia` or `check` profile; and
sudo keeps Dale's Mach bootstrap, so every run starts with none (nobootstrap.c).

    python3 dev/climb/door.py probe          as each build user, try what the door must refuse (no tokens)
    python3 dev/climb/door.py tools          the toolchain the users run, mirrored under /Users/Shared/wt-climb
    python3 dev/climb/door.py reap           every process of every build user killed (launch.sh stop)
    python3 dev/climb/door.py land-check <tree>  dev/ship.sh's check of a climb landing's HEAD at <tree>, as _wtland
"""
import contextlib, fcntl, glob, hashlib, json, os, re, shutil, signal, stat, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from defaults import DEFAULTS   # every number the door uses (dev/ship.sh copies it beside its copy of this file)

TOP = "/Users/Shared/wt-climb"   # dev/climb/setup-users.sh's
ROLES = {"slot1": "_wtk1", "slot2": "_wtk2", "review1": "_wtr1", "review2": "_wtr2", "review3": "_wtr3",
         "measure": "_wtm1", "score": "_wtm2", "land": "_wtland", "deps": "_wtdep"}
# what each role's home keeps between its uses (D6, A6-2): using() deletes everything else as the user on entry, then
# prepares it, so nothing a run left (a planted ~/.gitconfig or shell rc, a reviewer's transcript) reaches the next
# run but these. Every role keeps nothing. A slot (A7-9): its Kaimon's depot and config were written by one move's
# agent and read first by the next move's server and session; Kaimon's compiled images are the deps user's
# (measure.kaimon_images), beneath a depot each move makes again. The landing (A8-1): its check's depot (.wtd) was
# written by one candidate's check and loaded first by the next candidate's, code passing from check to check; each
# check now gets a fresh first depot over the warm layer of origin's own images (land_layer), made from origin's
# landed head alone.
KEEPS = {"slot1": (), "slot2": (), "review1": (), "review2": (), "review3": (),
         "measure": (), "score": (), "land": (), "deps": ()}
assert set(KEEPS) == set(ROLES), "door.KEEPS names every role of ROLES"
GROUP = "_wtclimb"
HOME = os.path.expanduser("~")
# Dale's home sealed from the build users (the lead's finding, 2026-11-10: /Users/daleblack is 755, so every
# world-readable file there, ~/.gitconfig and ~/.config/kaimon among them, read as a build user): one ACE Dale's uid
# sets, so nothing under his home is reachable, and every tool a run needs is mirrored under TOP (tools())
SEAL = f"group:{GROUP} deny list,search,readattr,readextattr,readsecurity"
GRANT = "allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
PATH = f"{TOP}/tools/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin"   # Homebrew's git: /usr/bin/git is xcrun's, which a profile refuses
# a run's directory, entered as its user (sudo starts in /), every file it writes capped at file_cap_bytes (A6-5:
# RLIMIT_FSIZE, inherited by every process the run starts; /bin/sh's `ulimit -f` counts 1024-byte blocks, probed)
SH = ["/bin/sh", "-c", f'ulimit -f {DEFAULTS["file_cap_bytes"] // 1024} && cd "$0" && exec "$@"']
NOBOOT = f"{TOP}/tools/bin/nobootstrap"   # dev/climb/nobootstrap.c, built by tools()

# the one clock of every wall the driver keeps (O7-1, D5): time.monotonic is mach_absolute_time here, which stops while
# the machine sleeps (a lid closed), so a sleep is never a run's timeout or a case's budget; it counts from this boot, as
# every record that holds one carries the boot (BOOT). time.time() is read only for a stamp, a backoff or a file's age
CLOCK = time.monotonic

class DoorError(Exception):
    """The door refused or failed: located, never a plausible default (D9)."""

# the driver's beat (its loop's stamp: progress), event and disk room, given by core.py, which imports this file (O6-6);
# a door process of its own (land-check, as ship.sh runs it) asks the free space under TOP itself
HOOKS = {"beat": lambda: None, "event": lambda kind, **kw: None,
         "disk": lambda: shutil.disk_usage(TOP).free / 1e9 >= DEFAULTS["disk_free_gb"], "power": lambda: True,
         "locks": lambda: (),   # the measurement locks this process holds (measure.HELD_SLOT's kinds): measure.py sets it
         "state": lambda: False}   # whether this thread holds the climb's state lock (core.locked): core.py sets it

def disk_ok():
    """At least disk_free_gb free (core's disk_room in the driver, which pauses the climb with one note under it): asked
    at every tick of every wait on a build user's run (R7-6), so a run that writes past the floor is reaped while it
    runs, never only at the loop's next iteration."""
    return HOOKS["disk"]()

def flock_within(fd, limit, what):
    """fd's exclusive flock, waited for `limit` seconds at most (O6-6: a wait on a lock is never a hang), the loop's
    stamp beaten while it waits; past it an event and a DoorError, so the step fails into its loop's backoff."""
    t0 = CLOCK()
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            pass
        if CLOCK() - t0 > limit:
            HOOKS["event"]("lock-wait-limit", lock=what, limit=limit)
            raise DoorError(f"{what} is held by another process of the climb past {limit} s")
        HOOKS["beat"](); time.sleep(1)

def role_wait(role):
    """The longest a use of `role` waits for another's (DEFAULTS role_wait_s, by its kind)."""
    return DEFAULTS["role_wait_s"][role.rstrip("0123456789")]

def home(role):
    return f"{TOP}/u/{ROLES[role]}"

def base_env(role, **kw):
    h = home(role)
    return {**dict(HOME=h, USER=ROLES[role], LOGNAME=ROLES[role], TMPDIR=f"{h}/tmp", PATH=PATH, LANG="en_US.UTF-8",
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",   # no git config but the run's own (A6-2)
                   JULIA_PKG_OFFLINE="true",   # the run directories' and the pins' repositories
                   DEVELOPER_DIR="/Library/Developer/CommandLineTools",   # xcrun's shims (/usr/bin/clang) run the toolchain a
                   # profile executes: Dale's xcode-select names Xcode.app, and a profile refused its xcodebuild (probed)
                   GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="safe.directory", GIT_CONFIG_VALUE_0=f"{TOP}/in/*",   # are Dale's
                   GIT_CONFIG_KEY_1="safe.directory", GIT_CONFIG_VALUE_1=f"{TOP}/pins/*"), **kw}   # (skeleton.jl's `git -C <pin>`)

def process_env(role, env, cwd):
    """The whole environment a process the door starts as `role` sees (spec v16 X3: the answering process's own record
    of it is checked against this): base_env with `env` over it, and what argv's shell adds as it changes from the
    door's "/" to `cwd` and execs (PWD, OLDPWD, SHLVL; probed: `env -i A=1 /bin/sh -c 'cd "$0" && exec "$@"' /tmp
    /usr/bin/env` prints A=1, OLDPWD, PWD=/tmp and SHLVL=0, nothing else)."""
    return dict(base_env(role, **env), PWD=cwd, OLDPWD="/", SHLVL="0")

NONE = "none"   # the profile of the door's own fixed commands alone (A8-8): no seatbelt, named at every such call

def argv(role, cmd, env, cwd, profile, background=True):
    """The one command line by which Dale's uid runs anything as a build user: sudo to the role's user, an explicit
    environment and nothing inherited, no Mach bootstrap (nobootstrap, every run's first program), background QoS (D31), and
    its seatbelt `profile`, a required argument (A8-8): a profile file, or NONE for the door's own fixed commands (a
    home's clean, a file put, a directory made or copied; HILL names each), so no run starts unsandboxed by omission
    (a secret never goes in an argv: `ps` shows every argv to every user). sudo keeps Dale's bootstrap:
    through it a build user's `launchctl` submitted a job that ran as Dale, set his launchd environment and disabled
    and killed his jobs, osascript drove Finder, open launched an app and pbpaste read his clipboard (probed
    2026-11-09); launchd answers print, getenv and disable without asking the sandbox, so a profile alone leaves
    those, and only a null bootstrap port closes them."""
    if not profile:
        raise DoorError(f"a run as {ROLES[role]} names no profile (a file, or door.NONE): {' '.join(cmd)[:120]}")
    e = base_env(role, **(env or {}))
    return ["/usr/bin/sudo", "-n", "-u", ROLES[role], "/usr/bin/env", "-i", *(f"{k}={v}" for k, v in e.items()),
            NOBOOT, *(["/usr/sbin/taskpolicy", "-b"] if background else []), *(["/usr/bin/sandbox-exec", "-f", profile] if profile != NONE else []),
            *SH, cwd or home(role), *cmd]

# ---------------------------------------------------------------- a landing's window: one record of every stop
# While a landing's check runs, the roles it quiets (lander.QUIET) are stopped (SIGSTOP, by user) and start nothing and
# resume nothing. ONE record holds that fact (O7-1, A7-4, R7-10, O7-2, D5), TOP/locks/window.json, beside the users it
# guards (TOP is every state's): the window's owner (the lander's pid) and boot, its start on CLOCK, each role it covers
# and whether the owner stopped it (a role a move had stopped already stays as it was), the daemons it stopped, and
# each role's past windows. It serves three readers: the awake clock (awake(): every wall on a role's work counts its
# awake time alone, so the driver's own stop is never a run's timeout), the start gate (after_window(): popen() and a
# move's own SIGCONT wait while it is open) and the orphan resume (resume_orphans(): a dead owner's stops resumed by
# the next climb process). An open window whose owner is not alive() is closed for every reader: no wall is ever
# disabled by a killed lander's record. One window at a time across every state: its owner holds TOP/locks/window.lock.
LOCKS = f"{TOP}/locks"   # every lock on a global resource, and the window's record: Dale's alone (lock_fd)
WINDOW = f"{LOCKS}/window.json"

def lock_fd(name):
    """A lock file of TOP/locks opened for flock (O8-2, A8-6, R8-2): every lock on a resource every state shares (a
    role, the landing window and its record, the measurement locks and the lander's marks, the dependency images, the
    agent probe) lives here, beside the users it guards, so a scratch state's process holds the real climb's locks and
    waits as any other; the directory is mode 700 and each file 600, so no build user can open one, and so none can
    flock it (R8-2: flock needs only a read fd, and a slot's agent held a review role's lock for its whole run)."""
    os.makedirs(LOCKS, mode=0o700, exist_ok=True)
    os.chmod(LOCKS, 0o700)
    fd = os.open(os.path.join(LOCKS, name), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    return fd
_WINDOW_FD = []   # this process's hold of window.lock while it owns the window

def _window():
    """The record, read; one of an earlier boot (its CLOCK readings mean nothing now) or none reads as empty."""
    try:
        with open(WINDOW) as f:
            d = json.load(f)
    except (FileNotFoundError, ValueError):
        d = {}
    if d.get("boot") != BOOT:
        d = {}
    return {"owner": d.get("owner"), "boot": BOOT, "open": d.get("open"), "roles": d.get("roles") or {},
            "daemons": d.get("daemons") or [], "done": d.get("done") or {}}

def _live(d):
    """The record's window is open and its owner alive (this boot): the only window any reader sees."""
    return d["open"] is not None and alive(d["owner"], d["boot"])

def _write_window(fn):
    """The record changed by fn(record) under its lock (a bounded wait, O6-6), written whole."""
    lk = lock_fd("window.json.lock")
    try:
        flock_within(lk, DEFAULTS["state_lock_s"], "the landing window's record")
        d = _window(); fn(d)
        with open(f"{WINDOW}.tmp{os.getpid()}", "w") as f:
            json.dump(d, f)
        os.replace(f"{WINDOW}.tmp{os.getpid()}", WINDOW)
    finally:
        os.close(lk)
    return d

def _close(d, now):
    """The record's window closed at `now`: each role's interval kept (stops_keep_s), nothing open."""
    if d["open"] is not None:
        for r in d["roles"]:
            d["done"][r] = [x for x in d["done"].get(r, []) if x[1] > now - DEFAULTS["stops_keep_s"]] + [[d["open"], now]]
    d.update(owner=None, open=None, roles={}, daemons=[])

def open_window(roles):
    """The landing's window opened by this process over `roles` (none stopped yet), one at a time across every state."""
    assert_order("lock:window")   # LOCK_ORDER (spec v18 P6)
    fd = lock_fd("window.lock")
    try:
        flock_within(fd, role_wait("land"), "the landing window (another landing's)")
    except BaseException:
        os.close(fd); raise
    _WINDOW_FD.append(fd)
    resume_orphans()   # a killed owner's window, which no live process holds, is resumed before this one opens
    _write_window(lambda d: (_close(d, CLOCK()) if d["open"] is not None else None,
                             d.update(owner=os.getpid(), boot=BOOT, open=CLOCK(), roles={r: False for r in roles}, daemons=[])))

def stop_role(role):
    """The landing's stop of every process of the role, recorded before it is sent."""
    _write_window(lambda d: d["roles"].__setitem__(role, True))
    signal_role(role, "STOP")

def stop_daemon(pid):
    """A daemon of Dale's (lander.DAEMONS) stopped for the window, recorded first."""
    _write_window(lambda d: d["daemons"].append(int(pid)))
    with contextlib.suppress(OSError):
        os.kill(int(pid), signal.SIGSTOP)

def _resume(d):
    for r, ours in d["roles"].items():
        if ours:
            signal_role(r, "CONT", landing=True)
    for pid in d["daemons"]:
        with contextlib.suppress(OSError):
            os.kill(int(pid), signal.SIGCONT)

def close_window():
    """This process's window closed: what it stopped resumed, then the record closed and the window's lock let go."""
    try:
        d = _window()
        if d["owner"] == os.getpid() and d["open"] is not None:
            _resume(d)
            _write_window(lambda d_: _close(d_, CLOCK()) if d_["owner"] == os.getpid() else None)
    finally:
        while _WINDOW_FD:
            fd = _WINDOW_FD.pop()
            fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def resume_orphans():
    """A window whose owner is dead (killed mid-check): every role and daemon it stopped resumed and the record closed,
    by the next climb process to start (incident 10). Returns what it resumed."""
    d = _window()
    if d["open"] is None or alive(d["owner"], d["boot"]):
        return []
    _resume(d)
    _write_window(lambda d_: _close(d_, CLOCK()) if d_["open"] is not None and not alive(d_["owner"], d_["boot"]) else None)
    return [r for r, ours in d["roles"].items() if ours] + [str(p) for p in d["daemons"]]

def in_window(role):
    """A live landing other than this process holds the window over `role`."""
    d = _window()
    return role in d["roles"] and d["owner"] != os.getpid() and _live(d)

def after_window(role):
    """Wait here while a landing's window covers the role (the one gate: popen, a move's SIGCONT), the loop's stamp
    beaten; a window past role_wait is an event and a DoorError (its owner's own wall, ship_kill_s, ends it first)."""
    t0, said = CLOCK(), False
    while in_window(role):
        if not said:
            HOOKS["event"]("quiet-wait", role=role); said = True
        if CLOCK() - t0 > role_wait(role):
            HOOKS["event"]("lock-wait-limit", lock="the quiet window", role=role, limit=role_wait(role))
            raise DoorError(f"a landing's quiet window over {role} is open past {role_wait(role)} s")
        HOOKS["beat"](); time.sleep(1)

def popen(role, cmd, *, profile, env=None, cwd=None, background=True, **kw):
    """A build user's process, in a session of its own, started only outside a landing's quiet window over its role."""
    after_window(role)
    return subprocess.Popen(argv(role, cmd, env, cwd, profile, background), cwd="/", start_new_session=True,
                            stdin=kw.pop("stdin", subprocess.DEVNULL), **kw)

def awake(role, t0):
    """Seconds of CLOCK since `t0` that the role was not in a landing's window: the one clock of every wall on a role's
    work (ruling 11). A window whose owner is dead counts as closed (A7-4: a killed lander never disables a wall)."""
    d, now = _window(), CLOCK()
    spans = d["done"].get(role, []) + ([[d["open"], now]] if role in d["roles"] and _live(d) else [])
    return now - t0 - sum(max(0.0, min(b, now) - max(a, t0)) for a, b in spans)

class Tick(DoorError):
    """tick()'s end of a wait: `why` is "disk" (under disk_free_gb), "power" (the power rule stops work, core.power_works, for a wait that ends on it) or
    "wall" (past the role's awake wall); the role is reaped before it is raised."""
    def __init__(self, role, why, text):
        super().__init__(text); self.role, self.why = role, why

def tick(role, t0=None, wall=None, battery_ends=False):
    """The one tick of every wait on a build user's process (A8-8: door.wait, measure.watched and land_job): the loop's
    beat, the power read (an event on change, core.power_ok), the disk asked (R7-6), and the role's awake time since
    `t0` against `wall` (awake(): a landing's stop is never a run's timeout). Under the disk's floor, when the power rule
    stops work and `battery_ends` (a measurement or a check: an agent run finishes, O8-3) or past the wall, the role is
    reaped and Tick raised naming why. Returns the awake seconds left (None with no wall)."""
    HOOKS["beat"]()
    ac = HOOKS["power"]()
    why = "disk" if not disk_ok() else "power" if battery_ends and not ac else None
    left = None if wall is None else wall - awake(role, t0)
    if why is None and left is not None and left <= 0:
        why = "wall"
    if why:
        reap(role)
        raise Tick(role, why, {"disk": f"the disk is under disk_free_gb while {ROLES[role]} ran: the role was reaped",
                               "power": f"the power rule stopped work (core.power_works) while {ROLES[role]} ran: the role was reaped",
                               "wall": f"{ROLES[role]} passed its wall of {wall} s of its awake time: the role was reaped"}[why])
    return left

def wait(role, p, wall, input=None):
    """p.communicate(input) waited for `wall` seconds of the role's awake time, each tick tick()'s: (stdout, stderr), or
    TimeoutExpired past the wall; DoorError under the disk's floor."""
    t0, first = CLOCK(), True
    while True:
        try:
            left = tick(role, t0, wall)
        except Tick as e:
            p.communicate()
            if e.why == "wall":
                raise subprocess.TimeoutExpired(p.args, wall)
            raise
        try:
            return p.communicate(input if first else None, timeout=min(left, 5))
        except subprocess.TimeoutExpired:
            first = False

def awake_call(role, fn, wall):
    """fn() in a thread of its own, waited for `wall` seconds of the role's awake time: its value or its exception, or
    TimeoutError past the wall (the thread ends with its socket when the role is reaped)."""
    import threading
    box, t0 = {}, CLOCK()
    def go():
        try:
            box["v"] = fn()
        except BaseException as e:
            box["e"] = e
    th = threading.Thread(target=go, daemon=True)
    th.start()
    while th.is_alive():
        th.join(0.2); HOOKS["beat"]()
        if th.is_alive() and awake(role, t0) > wall:
            raise TimeoutError(f"no answer within {wall} s of {ROLES[role]}'s awake time")
    if "e" in box:
        raise box["e"]
    return box["v"]

def run(role, cmd, wall, input=None, *, profile, **kw):
    """A build user's process waited for (wait()): (rc, stdout, stderr); past `wall` seconds of the role's awake time the
    role is reaped and rc is None."""
    p = popen(role, cmd, profile=profile, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
              stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL, **kw)
    try:
        out, err = wait(role, p, wall, input)
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        reap(role)
        out, err = p.communicate()
        return None, out, (err or "") + f"\npast its wall of {wall} s of its awake time: the role was reaped"

# launchd's own per-user agents: launchd starts one for a user that once ran with a Mach bootstrap and starts it again
# after every reap, until a reboot (v6d task 9: distnoted back 8-11 s after a reap); no door run reaches it (every run
# has no bootstrap). Named once here, and left out wherever a count of a role's processes is judged (R6-10)
LAUNCHD_AGENTS = ("/usr/sbin/distnoted",)

def pids(role, agents=True):
    """Every process of the role's user (ps sees every user's); with agents=False, launchd's agents left out (a count
    that is judged: a run's processes, a session's liveness)."""
    out = subprocess.run(["/bin/ps", "-axo", "pid=,user=,comm="], capture_output=True, text=True).stdout
    return [int(f[0]) for f in (l.split(None, 2) for l in out.splitlines())
            if len(f) == 3 and f[1] == ROLES[role] and (agents or f[2] not in LAUNCHD_AGENTS)]

def boot_time():
    """This boot's start (kern.boottime's seconds): every pid the climb records carries it (O6-11)."""
    out = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
    m = re.search(r"sec = (\d+)", out)
    if not m:
        raise DoorError(f"kern.boottime is unreadable: {out[:80]!r}")
    return int(m.group(1))

BOOT = boot_time()

def proc_start(pid):
    """A live process's start time, microseconds since the epoch (libproc's proc_pidinfo, PROC_PIDTBSDINFO:
    pbi_start_tvsec and pbi_start_tvusec at bytes 120 and 128 of struct proc_bsdinfo), or None: with the boot and the
    pid, a process's identity, so a mark's writer whose pid another process now holds is not that process."""
    import ctypes
    buf = ctypes.create_string_buffer(136)
    with contextlib.suppress(OSError, AttributeError):
        n = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True).proc_pidinfo(int(pid), 3, ctypes.c_uint64(0), buf, 136)
        if n == 136:
            return int.from_bytes(buf.raw[120:128], "little") * 1_000_000 + int.from_bytes(buf.raw[128:136], "little")
    return None

def alive(pid, boot):
    """The one test that a recorded process lives (O6-11): its pid recorded in this boot (`boot`, BOOT then) and
    running; a pid of an earlier boot, or recorded with none, is dead whatever process holds that number now."""
    if boot != BOOT:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False

def monitors(role):
    """Dale's sudo processes that run a command as the role's user. sudo suspends itself when its command is stopped
    (it mirrors a stopped child, as a job does) and resumes the command when it is continued itself; its real uid is
    Dale's, so `pkill -U <user>` never reaches it, and a stopped one neither returns its command's exit to wait() nor
    collects its killed command, whose zombie reap() then saw for good (probed 2026-11-10: a run that spanned a stop
    hung past the stop, and reap() failed on two zombies)."""
    out = subprocess.run(["/bin/ps", "-axo", "pid=,ruid=,command="], capture_output=True, text=True).stdout
    pre = f"/usr/bin/sudo -n -u {ROLES[role]} "
    return [int(f[0]) for f in (l.split(None, 2) for l in out.splitlines()) if len(f) == 3 and f[1] == str(os.getuid()) and f[2].startswith(pre)]

def resume_monitors(role):
    for pid in monitors(role):
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGCONT)

def reap(role, tries=50):
    """Every process of the role's user killed, by user (kill -1 as that user signals all of its processes and only
    them), until ps finds none: a setsid child, a detached node and a TERM-deaf server go too (R5-5, R5-6); its sudo
    monitors resumed each time, so a stopped one collects its command."""
    for _ in range(tries):
        if not pids(role):
            return
        subprocess.run(["/usr/bin/sudo", "-n", "-u", ROLES[role], "/bin/kill", "-KILL", "-1"], cwd="/", capture_output=True)
        resume_monitors(role)
        time.sleep(0.2)
    raise DoorError(f"{ROLES[role]} still runs {pids(role)} after {tries} kills")

def signal_role(role, sig, landing=False):
    """SIGSTOP or SIGCONT to every process of the role's user (the quiet window and a move's pauses, by user); a CONT
    resumes the role's sudo monitors too (monitors()). A move's CONT waits for a landing's quiet window to end
    (after_window); the landing's own (`landing`) ends it."""
    if sig == "CONT" and not landing:
        after_window(role)
    rc = subprocess.run(["/usr/bin/sudo", "-n", "-u", ROLES[role], "/usr/bin/pkill", f"-{sig}", "-U", ROLES[role]], cwd="/",
                        capture_output=True).returncode
    if sig == "CONT":
        resume_monitors(role)
    return rc   # pkill's: 0 a process signalled, 1 none to signal, more a failure (sudo's, pkill's)

HELD = {}   # role: the run directories give() made during this process's use of it (using())
USE = {}   # role: (the lock's descriptor, the use's generation) while this process uses it (using())

# THE order of the climb's locks (spec v17 Y3), as HILL states it (the quiet probe's "The locks' order"), the one
# constant every check reads, asserted where each lock is taken (using(), measure.julia_slot, measure.yield_slot): a
# slot's role (held across its move), a review's role, the measurement locks (`score`, then `verify`), ship.sh's
# landing lock (the common dir's wt-landing-lock, taken by origin's ship.sh under the lander's measurement locks; the
# driver only waits on it, measure.julia_slot), the landing's window (window.lock, open_window), the dependency images'
# lock (.deps.lock, measure.deps), one measuring role (measure, score, land, deps), and last the state lock
# (core.locked), held for a write alone, so no lock is taken while it is held (spec v18 P6: the order total, each
# asserted where the driver takes it; window.json.lock, the window record's, is held for one read or write alone). A process takes a lock only while every lock it holds is earlier in this order, so no two
# processes wait on each other; a yield (measure.yield_slot: a measurement lock let go and taken again) is a taking of
# that lock, so it happens with no measuring role held: a yield inside a measuring role's use leaves the use for its
# wait (released()). precedent(lock ordering: the Linux kernel's lockdep classes, one global order, checked at acquire)
LOCK_ORDER = ("slot", "review", "lock:score", "lock:verify", "lock:landing", "lock:window", "lock:deps", "measuring", "state")

class LockOrder(DoorError):
    """A lock taken out of LOCK_ORDER: refused where it is taken, before any wait (a cycle cannot be written)."""

def lock_rank(name):
    """`name`'s place in LOCK_ORDER: a role (`slot1`, `review2`, `measure`, ...) or a measurement lock (`lock:verify`)."""
    return LOCK_ORDER.index(name if name.startswith("lock:") or name == "state" else
                            "slot" if name.startswith("slot") else "review" if name.startswith("review") else "measuring")

def assert_order(name, retake=False):
    """Refuses (LockOrder) the taking of `name` while this process holds a lock not earlier than it in LOCK_ORDER (a
    role it uses, HELD; a measurement lock, HOOKS["locks"]); with `retake`, `name` itself held already (a yield's)."""
    held = [*HELD, *(f"lock:{k}" for k in HOOKS["locks"]()), *(["state"] if HOOKS["state"]() else [])]
    bad = [h for h in held if lock_rank(h) >= lock_rank(name) and not (retake and h == name)]
    if bad:
        raise LockOrder(f"{name} taken while this process holds {', '.join(bad)}, which LOCK_ORDER puts at or after it "
                        f"({' < '.join(LOCK_ORDER)}): a cycle with a process that takes them in order (spec v17 Y3)")

def _generation(role, new=False):
    """The role's use generation (TOP/locks/.role-<role>.gen): written anew by every process that takes the role's lock
    (using(), hold_roles(), role_free()), so a use that let it go for a yield knows whether another use came between."""
    p = f"{LOCKS}/.role-{role}.gen"
    if new:
        g = f"{os.getpid()}-{time.time_ns()}"
        with open(p, "w") as f:
            f.write(g)
        return g
    with contextlib.suppress(FileNotFoundError):
        return open(p).read()
    return None

def role_lock(role):
    """The role's lock, in TOP/locks beside the user it guards (O7-2, lock_fd): one for every state, so a scratch
    state's use of a role waits for the real climb's, and the real climb's for a scratch one's. Its descriptor."""
    return lock_fd(f".role-{role}.lock")

@contextlib.contextmanager
def using(role):
    """One process of the driver uses a role at a time, whatever state it serves (a flock in TOP/locks, role_lock), the
    role reaped on entry and on exit, so no process of one use outlives it into the next, and every run directory given
    to it in the use removed on exit, an exception's included (give() refuses a role not in use, so none is left
    behind). On entry its home is emptied of all but what KEEPS names, as its user, then prepared (prepare(), which
    runs here alone)."""
    assert_order(role)   # before any wait (spec v17 Y3)
    fd = role_lock(role)
    try:
        flock_within(fd, role_wait(role), f"the {role} role")
    except BaseException:
        os.close(fd); raise
    try:
        _enter(role, fd); yield
    finally:
        try:
            reap(role)
        finally:
            USE.pop(role, None)
            for d in HELD.pop(role, ()):
                shutil.rmtree(d, ignore_errors=True)
            fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def _enter(role, fd):
    """A use's entry, its lock held: every run directory of this role a killed driver left removed (spec v17 Y1: none
    outlives the use that made it, since no other process of any state can be using the role while its lock is held
    here), the role reaped, its home cleaned and prepared, and the use's generation written."""
    for d in glob.glob(f"{TOP}/in/{role}.*"):
        shutil.rmtree(d, ignore_errors=True)
    reap(role); HELD[role] = set(); clean(role); prepare(role)
    USE[role] = (fd, _generation(role, new=True))

@contextlib.contextmanager
def released(role):
    """The role's use left for the block and taken again after it (spec v17 Y3): the role reaped and its lock let go, so
    a process that needs the role meanwhile takes it (a yield waits on no role it holds). Yields a dict whose "lost" is
    set when the block is done: True when another use came between (its generation is not this use's), whose entry
    removed this use's run directories and cleaned its home, so this use is entered afresh (_enter) and the caller makes
    its directories again; False when none did, and every run directory and the home are as they were."""
    fd, gen = USE[role]
    held = HELD.pop(role)
    out = {"lost": False}
    reap(role)
    fcntl.flock(fd, fcntl.LOCK_UN)
    try:
        yield out
    finally:
        flock_within(fd, role_wait(role), f"the {role} role")
        HELD[role] = held
        if _generation(role) != gen:
            out["lost"] = True
            for d in held:
                shutil.rmtree(d, ignore_errors=True)
            _enter(role, fd)

def reap_orphans(roles=None, held=False):
    """An orphan of a killed driver: a build user's process (launchd's agents aside) whose role's lock no process holds,
    since using() reaps a role on entry and on exit, so no process of a use outlives it (round12-operator 4's walk:
    such a process lived until its role's next use and failed every quiet probe meanwhile). Each role of `roles` (every
    role) whose lock is free, taken without waiting (LOCK_NB, so a role in use is never touched), or held already by
    this process (`held`: within hold_roles), is reaped, with one event naming the role and the pids. Run at a launch
    (preflight), at a resume and by the heartbeat each minute (launch.sh). Returns {role: the pids reaped}."""
    out = {}
    for r in (roles or ROLES):
        fd = None
        if not held:
            fd = role_lock(r)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:   # in use: its processes are its use's
                os.close(fd); continue
        try:
            ps = pids(r, agents=False)
            if ps:
                reap(r); out[r] = ps
                HOOKS["event"]("orphan-reaped", role=r, user=ROLES[r], pids=ps)
        finally:
            if fd is not None:
                fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
    return out

ALL_HELD = []   # set while this process holds every role's lock (hold_roles): every role is then free of any use

@contextlib.contextmanager
def hold_roles():
    """Every role's lock taken at once, none waited for (LOCK_NB), and held until the block ends (A9-5): what changes
    TOP for every state (`tools`, a launch's preflight) runs with no role in use and none taken meanwhile. Yields the
    roles another process uses (the block refuses when any is), never a lock it does not hold."""
    fds, busy = [], []
    try:
        for r in ROLES:
            fd = role_lock(r)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); fds.append(fd); _generation(r, new=True)
            except BlockingIOError:
                os.close(fd); busy.append(r)
        ALL_HELD.append(not busy)
        yield busy
    finally:
        if len(ALL_HELD):
            ALL_HELD.pop()
        for fd in fds:
            fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def role_free(role):
    """No process of any state uses the role now (its lock taken and let go at once; every role, while this process
    holds them all, hold_roles)."""
    if ALL_HELD and ALL_HELD[-1]:
        return True
    fd = role_lock(role)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _generation(role, new=True)   # its caller may remove the role's run directories (clear_in): a yielded use's
        fcntl.flock(fd, fcntl.LOCK_UN)   # is then lost (released())
        return True
    except BlockingIOError:
        return False
    finally:
        os.close(fd)

def clear_in():
    """The run directories under TOP/in whose role no process of any state uses (role_free; give() names each
    `<role>.<run>`), removed: at launch (preflight), so a killed driver's, whose HELD lived in its memory alone, is not
    kept for good (O6-10), and a live use's, a scratch state's or the real climb's, is never touched (O7-2). Returns
    what it removed."""
    gone = [d for d in sorted(glob.glob(f"{TOP}/in/*")) if os.path.basename(d).split(".", 1)[0] not in ROLES or
            role_free(os.path.basename(d).split(".", 1)[0])]
    for d in gone:
        shutil.rmtree(d, ignore_errors=True)
    return [os.path.basename(d) for d in gone]

def acl(path, who, how=GRANT):
    r = subprocess.run(["/bin/chmod", "+a", f"{who} {how}", path], capture_output=True, text=True)
    if r.returncode:
        raise DoorError(f"chmod +a {who} on {path}: {r.stderr.strip()}")

def give(role, run_id, files=None):
    """A run's directory, the one way in: TOP/in/<run>, Dale's, readable by the role's user alone (an ACL), holding
    plain files; a repository goes in with repo(); removed when the role's using() ends."""
    if role not in HELD:
        raise DoorError(f"give({role!r}, {run_id!r}) outside a use of the role (using()): its run directory would outlive the run")
    d = f"{TOP}/in/{role}.{run_id}"   # its role named, so clear_in() can tell a live use's
    HELD[role].add(d)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d, mode=0o700)
    acl(d, ROLES[role])
    for name, text in (files or {}).items():
        os.makedirs(os.path.dirname(os.path.join(d, name)), mode=0o700, exist_ok=True)
        with open(os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:   # 0600: the ACL
            f.write(text)                                                                                    # its one grant
    return d

def git_(*a, cwd=None):
    r = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *a], cwd=cwd, capture_output=True, text=True)
    if r.returncode:
        raise DoorError(f"git {' '.join(a[:3])}: {r.stderr.strip()[:300]}")
    return r.stdout.strip()

HISTORY = ("slot1", "slot2", "measure", "score", "land", "deps")   # the roles that read origin's history in place

def repo(d, src, refs, history=True, links=True):
    """A bare repository in run directory `d` holding `refs` ({name: sha} of the repository `src`) and their history
    (a clone of the cache of origin's history when `history`: hard links, whose objects the HISTORY roles read, or a
    copy of its own for a reviewer's role, which reads no other run's history), or those commits' objects alone. The
    cache is mode 700, its ACL (the HISTORY roles) its only grant, so a reviewer reads nothing of it (R6-4)."""
    cache = f"{TOP}/cache.git"
    if history:
        if not os.path.isdir(cache):
            git_("init", "-q", "--bare", cache)
            for r in HISTORY:
                acl(cache, ROLES[r])
        os.chmod(cache, 0o700)
        git_("fetch", "-q", src, "+refs/remotes/origin/wt2:refs/heads/wt2", cwd=cache)
        git_("clone", "-q", "--bare", "--local", *([] if links else ["--no-hardlinks"]), cache, f"{d}/repo.git")
    else:
        git_("init", "-q", "--bare", f"{d}/repo.git")
    for name, sha in refs.items():
        git_("fetch", "-q", src, f"+{sha}:refs/heads/{name}", cwd=f"{d}/repo.git")
    return f"{d}/repo.git"

# Every open of a path a build user can write (its home, a land job's clone) is one of these three, each component
# opened without following a link and without blocking, and a file refused unless it is regular before a byte is
# read (R6-1: a FIFO's open waits for a writer, and a reaped user brings none, so the driver blocked for good)
NOWAIT = os.O_NOFOLLOW | os.O_NONBLOCK

def _parts(rel):
    parts = [p for p in rel.split("/") if p]
    if any(p in ("..", ".") for p in parts):
        raise DoorError(f"{rel}: a path with '..'")
    return parts

def _dir(role, parts):
    """The directory `parts` of the role's home, opened (O_DIRECTORY, no link, no wait): its descriptor."""
    fd = os.open(home(role), os.O_RDONLY | os.O_DIRECTORY | NOWAIT)
    try:
        for p in parts:
            nfd = os.open(p, os.O_RDONLY | os.O_DIRECTORY | NOWAIT, dir_fd=fd); os.close(fd); fd = nfd
    except BaseException:
        os.close(fd); raise
    return fd

def _regular(name, dir_fd, where):
    """`name` under `dir_fd` opened for reading (no link, no wait), refused before any read unless a regular file, its
    O_NONBLOCK then cleared: its descriptor."""
    f = os.open(name, os.O_RDONLY | NOWAIT, dir_fd=dir_fd)
    if not stat.S_ISREG(os.fstat(f).st_mode):
        os.close(f); raise DoorError(f"{where} is not a regular file")
    fcntl.fcntl(f, fcntl.F_SETFL, fcntl.fcntl(f, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    return f

def open_home(role, rel):
    """A file of the role's home opened for reading, a regular file, or None when it is not there: the one way Dale's
    uid reads what a build user wrote (take(), list_home() and copy_home() are its kin, NOWAIT above)."""
    parts, where = _parts(rel), f"{rel} in {ROLES[role]}'s home"
    try:
        fd = _dir(role, parts[:-1])
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as e:
        raise DoorError(f"{where}: {e}")
    try:
        return os.fdopen(_regular(parts[-1], fd, where), "rb")
    except FileNotFoundError:
        return None
    except OSError as e:
        raise DoorError(f"{where}: {e}")
    finally:
        os.close(fd)

def list_home(role, rel):
    """The names in directory `rel` of the role's home (opened as open_home opens), or [] when it is not there."""
    try:
        fd = _dir(role, _parts(rel))
    except (FileNotFoundError, NotADirectoryError):
        return []
    except OSError as e:
        raise DoorError(f"{rel} in {ROLES[role]}'s home: {e}")
    try:
        return sorted(os.listdir(fd))
    finally:
        os.close(fd)

def copy_home(role, rel, dst):
    """Directory `rel` of the role's home copied to `dst`, readable by every build user, once (dst made whole or not at
    all): the role reaped first, and the caller holding it (using()), so nothing of its user runs while it is read;
    each directory and file opened as open_home opens them and each file cloned from that descriptor (fclonefileat:
    APFS, no space, as clone_tree's cp -c); a link, a FIFO, a socket or any other entry refused, named."""
    import ctypes, ctypes.util
    if os.path.exists(dst):
        return dst
    if role not in HELD:
        raise DoorError(f"copy_home({role!r}) outside a use of the role (using()): its user could write while it is read")
    reap(role)
    clone = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True).fclonefileat
    tmp = f"{dst}.tmp{os.getpid()}"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    def walk(sfd, dfd, where):
        for e in os.scandir(sfd):
            w = f"{where}/{e.name}"
            if e.is_dir(follow_symlinks=False):
                os.mkdir(e.name, dir_fd=dfd)
                s, d = os.open(e.name, os.O_RDONLY | os.O_DIRECTORY | NOWAIT, dir_fd=sfd), os.open(e.name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=dfd)
                try:
                    walk(s, d, w)
                finally:
                    os.close(s); os.close(d)
            elif e.is_file(follow_symlinks=False):
                f = _regular(e.name, sfd, w)
                try:
                    if clone(f, dfd, e.name.encode(), 0) != 0:
                        raise DoorError(f"fclonefileat {w}: {os.strerror(ctypes.get_errno())}")
                finally:
                    os.close(f)
            else:
                raise DoorError(f"{w} is not a directory or a regular file")
    try:
        sfd = _dir(role, _parts(rel))
    except OSError as e:
        raise DoorError(f"{rel} in {ROLES[role]}'s home: {e}")
    dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
    try:
        walk(sfd, dfd, f"{rel} in {ROLES[role]}'s home")
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True); raise
    finally:
        os.close(sfd); os.close(dfd)
    subprocess.run(["/bin/chmod", "-R", "go+rX", tmp], capture_output=True)   # a copy readable by every build user
    os.rename(tmp, dst)
    return dst

def take(role, rel, cap):
    """A file of the role's home, the one way out (open_home), at most `cap` bytes, or None; its processes stopped
    or reaped first (the caller's)."""
    f = open_home(role, rel)
    if f is None:
        return None
    with f:
        data = f.read(cap + 1)
    if len(data) > cap:
        raise DoorError(f"{rel} in {ROLES[role]}'s home is over {cap} bytes")
    return data

def put(role, rel, text):
    """A file written into the role's home as its user (Dale's uid writes nothing there)."""
    rc, out, err = run(role, ["/bin/sh", "-c", 'mkdir -p "$(dirname "$1")" && cat > "$1"', "sh", f"{home(role)}/{rel}"], DEFAULTS["step_wall_s"], input=text, profile=NONE)
    if rc != 0:
        raise DoorError(f"put {rel} as {ROLES[role]}: {err.strip()[-200:]}")

def seal_home():
    """The ACE that keeps every build user out of Dale's home, set once, read back."""
    have = subprocess.run(["/bin/ls", "-led", HOME], capture_output=True, text=True).stdout
    if f"group:{GROUP} deny list,search" not in have:
        acl(HOME, f"group:{GROUP}", SEAL.split(" ", 1)[1])

# ---------------------------------------------------------------- the toolchain under TOP (no file under Dale's home)
def clone_tree(src, dst):
    """`src` as an APFS clone at `dst` (cp -c: no space, copy on write), once, readable by every build user (the
    copy's modes, never Dale's original's)."""
    if os.path.exists(dst):
        return dst
    tmp = f"{dst}.tmp{os.getpid()}"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    r = subprocess.run(["/bin/cp", "-Rc", src, tmp], capture_output=True, text=True)
    if r.returncode:
        raise DoorError(f"cp -Rc {src}: {r.stderr.strip()[-300:]}")
    subprocess.run(["/bin/chmod", "-R", "go+rX", tmp], capture_output=True)   # a copy readable by every build user
    os.rename(tmp, dst)
    return dst

def replace_tree(src, dst, same):
    """`src` at `dst` as clone_tree makes it, and made again when `same(src, dst)` is false (a newer registry, an
    environment whose Manifest changed): the new copy made beside it first, then swapped in, the old one removed."""
    if os.path.exists(dst) and not same(src, dst):
        new, old = clone_tree(src, f"{dst}.new{os.getpid()}"), f"{dst}.old{os.getpid()}"
        os.rename(dst, old); os.rename(new, dst)
        shutil.rmtree(old) if os.path.isdir(old) else os.remove(old)
        return dst
    return clone_tree(src, dst)

def digest(p, names=None):
    """A file's bytes hashed, or a directory's `names` (its files) hashed in order, each with its name; a missing file
    hashes as empty."""
    import hashlib
    h = hashlib.sha256()
    for n in [None] if names is None else names:
        f = p if n is None else os.path.join(p, n)
        h.update(b"" if n is None else n.encode() + b"\0")
        with contextlib.suppress(FileNotFoundError):
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()

def mirror_julia(src, dst, public, envs):
    """Dale's depot `src` (~/.julia) mirrored at `dst` (TOP/julia), what a build user reads (O6-5): every package
    version by its slug (packages/<name>/<slug>: a slug names one version's tree, so a new version is a new entry and
    an old one never changes), of the packages the General registry names (`public`: never a private package); every
    artifact (named by its hash); the registries, each made again when its bytes' hash differs (a newer General); and
    the global environments `envs`, each made again when a Project.toml or Manifest.toml in it differs."""
    for e in glob.glob(f"{src}/packages/*/*"):
        name = os.path.basename(os.path.dirname(e))
        if name in public:
            clone_tree(e, f"{dst}/packages/{name}/{os.path.basename(e)}")
    for e in glob.glob(f"{src}/artifacts/*"):
        clone_tree(e, f"{dst}/artifacts/{os.path.basename(e)}")
    for f in glob.glob(f"{src}/registries/General*"):
        replace_tree(f, f"{dst}/registries/{os.path.basename(f)}", lambda a, b: digest(a) == digest(b))
    def tomls(d):   # an environment's identity: every Project.toml and Manifest.toml under it, by relative path
        return digest(d, sorted(os.path.relpath(os.path.join(r, t), d) for r, _, fs in os.walk(d) for t in fs
                                if t in ("Project.toml", "Manifest.toml")))
    for name in envs:
        if os.path.isdir(f"{src}/environments/{name}"):
            replace_tree(f"{src}/environments/{name}", f"{dst}/environments/{name}", lambda a, b: tomls(a) == tomls(b))

def general_names():
    """Every package name the General registry holds (its Registry.toml, read from the registry's tarball)."""
    import tarfile
    with tarfile.open(f"{HOME}/.julia/registries/General.tar.gz") as t:
        text = t.extractfile("Registry.toml").read().decode()
    return set(re.findall(r'^[0-9a-f-]{36} = \{ name = "([^"]+)"', text, re.M))

def manifest_julia(text):
    """The Julia version a Manifest's text names (`julia_version = "1.12.7"`), or a DoorError."""
    m = re.search(r'^julia_version = "([^"]+)"', text, re.M)
    if not m:
        raise DoorError("the climb's Manifest names no julia_version")
    return m[1]

def julia_install(version, full=False):
    """(version, install root above bin/) of the juliaup install of exactly `version`, the climb Manifest's julia_version
    (spec v16 X4: never juliaup's default channel, which moves when Dale updates it), read from juliaup.json (no Julia
    runs as Dale); with `full`, the build as juliaup names it (`1.12.7+0.aarch64.apple.darwin14`) third. A version juliaup
    has not installed is a DoorError naming it and the installed ones: the launch is refused, located."""
    d = json.load(open(f"{HOME}/.julia/juliaup/juliaup.json"))
    arch = {"arm64": "aarch64", "x86_64": "x64"}.get(os.uname().machine, os.uname().machine)   # juliaup's name of this host's
    hits = sorted(k for k in d["InstalledVersions"] if k.split("+")[0] == version and f".{arch}." in k)   # build (probed:
    if len(hits) != 1:   # 1.12.7 is installed for aarch64 and for x64 here, and the x64 build sorted last)
        raise DoorError(f"the climb's Manifest names Julia {version}, of which juliaup has {len(hits)} {arch} install(s) "
                        f"({', '.join(hits) or 'none'}; installed: {', '.join(sorted(d['InstalledVersions'])) or 'none'}): "
                        f"`juliaup add {version}` so exactly one is, then launch again")
    v = hits[0]
    binp = d["InstalledVersions"][v]["BinaryPath"]
    root = os.path.normpath(os.path.join(HOME, ".julia", "juliaup", os.path.dirname(os.path.dirname(binp))))
    return (v.split("+")[0], root, v) if full else (v.split("+")[0], root)

def node_header_version(root):
    """A node install's version as its own include/node/node_version.h states it (no program run as Dale for it)."""
    t = open(f"{root}/include/node/node_version.h").read()
    v = [re.search(rf"^#define NODE_{n}_VERSION (\d+)", t, re.M) for n in ("MAJOR", "MINOR", "PATCH")]
    if not all(v):
        raise DoorError(f"{root}/include/node/node_version.h states no version")
    return ".".join(x[1] for x in v)

# THE node a build user runs (spec v17 Y1): nodejs.org's official build of ci.yml's node-version major, self-contained (it
# links /usr/lib and /System alone, so no Homebrew library a `brew upgrade` renames can stop it loading), its version
# and each build's sha256 declared here and nowhere else; door.tools refuses any other, and `door.py tools --fetch-node`
# (a launch step Dale runs once) downloads it, checks the sha256 and installs it under TOP/tools. precedent(actions/
# setup-node: CI installs nodejs.org's build of the major ci.yml names, the node test/runner.jl was written against)
NODE_PIN = {"version": "26.11.0", "url": "https://nodejs.org/dist/v{version}/{file}",
            "builds": {"arm64": ("node-v26.11.0-darwin-arm64.tar.gz", "1b51d948058a5a0f4d83723d395786f13a647565ca4dfdeac37dafa95040e5f3")},
            # each build's installed bin/node, its sha256 (spec v18 P6: pin_node hashes the bytes it pins, never trusting
            # the .sha256 record fetch_node wrote beside them); read from the fetched v26.11.0 darwin-arm64 install
            "binaries": {"arm64": "c0a30100c7909baa2253b29dab28a5b476e796c69cf8a7d0b47c8e188fe78c5a"}}

def _node_build():
    """(the tarball's name, its declared sha256) of NODE_PIN for this host, or a DoorError naming the host."""
    arch = os.uname().machine
    if arch not in NODE_PIN["builds"]:
        raise DoorError(f"NODE_PIN declares no node build for this host ({arch}): declare one, its nodejs.org sha256 with it")
    return NODE_PIN["builds"][arch]

def fetch_node(top):
    """`door.py tools --fetch-node`: NODE_PIN's build downloaded from nodejs.org to a temp file under `top`/tools, its
    sha256 checked against the declared one (a mismatch refused, the file removed), unpacked and installed at
    `top`/tools/node-<version> with the sha256 it was checked against (.sha256), which pin_node reads. A launch step
    Dale runs once a version; it starts no build user's process. Returns the install's directory."""
    import hashlib, tempfile, urllib.request
    name, sha = _node_build()
    dst = f"{top}/tools/node-{NODE_PIN['version']}"
    os.makedirs(f"{top}/tools", exist_ok=True)
    with tempfile.TemporaryDirectory(dir=f"{top}/tools") as tmp:
        tar = os.path.join(tmp, name)
        with urllib.request.urlopen(NODE_PIN["url"].format(version=NODE_PIN["version"], file=name), timeout=600) as r, open(tar, "wb") as f:
            shutil.copyfileobj(r, f)
        got = hashlib.sha256(open(tar, "rb").read()).hexdigest()
        if got != sha:
            raise DoorError(f"{name}: its sha256 is {got}, NODE_PIN declares {sha}: refused, nothing installed")
        r = subprocess.run(["/usr/bin/tar", "-xzf", tar, "-C", tmp], capture_output=True, text=True)
        if r.returncode:
            raise DoorError(f"tar -xzf {name}: {r.stderr.strip()[-300:]}")
        src = os.path.join(tmp, name[:-len(".tar.gz")])
        with open(os.path.join(src, ".sha256"), "w") as f:
            f.write(sha + "\n")
        subprocess.run(["/bin/chmod", "-R", "go+rX", src], capture_output=True)
        shutil.rmtree(dst, ignore_errors=True)
        os.rename(src, dst)
    return dst

def pin_node(top, ci_yml):
    """node at a launch (spec v17 Y1): NODE_PIN's build as fetch_node installed it under `top`/tools/node-<version>
    (its .sha256 the declared one), of ci.yml's node-version major, its version as its own node_version.h states it, and
    self-contained (`otool -L` of its binary names /usr/lib and /System alone), linked at `top`/tools/bin/node: the one
    node every build user's PATH and the run process's profile reach. Anything else is refused, named: the launch waits
    on `door.py tools --fetch-node`. Returns (version, its install)."""
    m = re.search(r"node-version: *'?([0-9]+)", open(ci_yml).read())
    if not m:
        raise DoorError(f"{ci_yml} names no node-version")
    ver, (_, sha) = NODE_PIN["version"], _node_build()
    if ver.split(".")[0] != m[1]:
        raise DoorError(f"NODE_PIN declares node {ver}, and ci.yml names the major {m[1]}: declare that major's build")
    dst = f"{top}/tools/node-{ver}"
    have = open(f"{dst}/.sha256").read().strip() if os.path.exists(f"{dst}/.sha256") else None
    if have != sha:
        raise DoorError(f"{dst} is not NODE_PIN's node {ver} (its recorded sha256 {have}, declared {sha}): run "
                        "`python3 dev/climb/door.py tools --fetch-node` (a launch step), then launch again")
    if node_header_version(dst) != ver:
        raise DoorError(f"{dst} holds node {node_header_version(dst)}, not the {ver} it is named for")
    import hashlib
    got = hashlib.sha256(open(f"{dst}/bin/node", "rb").read()).hexdigest()
    want = NODE_PIN["binaries"].get(os.uname().machine)
    if got != want:   # the bytes pinned, hashed each launch (spec v18 P6)
        raise DoorError(f"{dst}/bin/node hashes {got}, NODE_PIN declares its binary {want}: refused; run "
                        "`python3 dev/climb/door.py tools --fetch-node` again")
    r = subprocess.run(["/usr/bin/otool", "-L", f"{dst}/bin/node"], capture_output=True, text=True)
    libs = [l.strip().split(" ")[0] for l in r.stdout.splitlines()[1:] if l.strip()]
    foreign = [l for l in libs if not l.startswith(("/usr/lib/", "/System/"))]
    if r.returncode or not libs or foreign:
        raise DoorError(f"{dst}/bin/node is not self-contained: it links {foreign or r.stderr.strip()[-200:]}")
    link = f"{top}/tools/bin/node"
    os.makedirs(os.path.dirname(link), exist_ok=True)
    if os.path.realpath(link) != os.path.realpath(f"{dst}/bin/node"):
        with contextlib.suppress(FileNotFoundError):
            os.remove(link)
        os.symlink(f"{dst}/bin/node", link)
    return ver, dst

def tools(julia_version, state=None, prune=False):
    """What a build user runs and reads, under TOP, keyed by version: Julia's install (the juliaup install of exactly
    `julia_version`, the climb Manifest's), node (pin_node: ci.yml's major, copied), the shared depot (Dale's
    ~/.julia's packages the General registry names, artifacts, that registry and Kaimon's app) and the pinned
    checkouts WasmTarget's anchors read (pins()). git and java are system or Homebrew paths. Run at launch alone
    (climb.py preflight): a landing refreshes the pins alone (land_job), never this, so it starts no build user's
    process beside a check (O6-2); the agents' claude is pin_claude()'s. With `state`, the launch's node and Julia are
    recorded in its tools-pins.json, and with `prune` (the real state's launch alone, as pin_claude's) every node and
    Julia copy under TOP/tools but this launch's and the one before is removed (spec v17 Y6, prune_tools)."""
    for d in (TOP, f"{TOP}/tools", f"{TOP}/tools/bin"):
        os.makedirs(d, exist_ok=True)
    for name, dst in (("nobootstrap.c", NOBOOT), ("homeacl.c", HOMEACL)):   # every run's first program; a home's ACL
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
        r = subprocess.run(["/usr/bin/xcrun", "cc", "-O2", "-Wall", "-Werror", "-o", f"{dst}.tmp", src], capture_output=True, text=True)
        if r.returncode:
            raise DoorError(f"cc {src}: {r.stderr.strip()[-300:]}")
        os.rename(f"{dst}.tmp", dst)
    ver, root, full = julia_install(julia_version, full=True)
    node, keg = pin_node(TOP, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".github", "workflows", "ci.yml"))
    jl = clone_tree(root, f"{TOP}/tools/julia-{ver}")
    link = f"{TOP}/tools/bin/julia"
    if os.path.realpath(link) != f"{jl}/bin/julia":
        with contextlib.suppress(FileNotFoundError):
            os.remove(link)
        os.symlink(f"{jl}/bin/julia", link)
    plain_ps()
    # no compiled image: one records its source's path, and Julia's loader stats it (an image of a tree under Dale's
    # home is EACCES to a build user, which fails the load, never "stale"); the deps user builds them. The global
    # environments hold KaimonGate, which every Kaimon session loads, and Kaimon's app
    mirror_julia(f"{HOME}/.julia", f"{TOP}/julia", general_names(), ("apps", f"v{'.'.join(ver.split('.')[:2])}"))
    pins()
    if state is not None:
        prune_tools(state, {"node": os.path.basename(keg), "julia": os.path.basename(jl)}, prune)
    return {"julia": ver, "julia_build": full, "node": node, "node_keg": keg, "node_sha256": open(f"{keg}/.sha256").read().strip()}

def prune_tools(state, now, prune):
    """TOP/tools keeps the current launch's node and Julia and the one before (spec v17 Y6, as pin_claude keeps claude's):
    `now` ({"node": "node-<v>", "julia": "julia-<v>"}) recorded in the state's tools-pins.json with what the launch
    before pinned; with `prune` (the real state's launch alone: a scratch state's never removes the real climb's copies,
    O7-2) every other `node-*` and `julia-*` under TOP/tools is removed. Returns the record."""
    p = os.path.join(state, "tools-pins.json")
    old = json.load(open(p)) if os.path.exists(p) else {}
    rec = {k: {"now": v, "before": old.get(k, {}).get("now") if old.get(k, {}).get("now") != v else old.get(k, {}).get("before")}
           for k, v in now.items()}
    with open(f"{p}.tmp", "w") as f:
        json.dump(rec, f)
    os.replace(f"{p}.tmp", p)
    for k, r in rec.items():
        for c in glob.glob(f"{TOP}/tools/{k}-*") if prune else ():
            if os.path.basename(c) not in (r["now"], r["before"]):
                shutil.rmtree(c) if os.path.isdir(c) else os.remove(c)
    return rec

def tla2tools_pin(tree):
    """The sha256 of tla2tools.jar that `tree`'s dev/formal/run_tlc.sh pins beside the release it names (its
    TLA2TOOLS_SHA256 line, the one place the jar's identity is written), or None."""
    p = os.path.join(tree, "dev", "formal", "run_tlc.sh")
    m = re.search(r"^TLA2TOOLS_SHA256=([0-9a-f]{64})\b", open(p).read(), re.M) if os.path.exists(p) else None
    return m.group(1) if m else None

def mirror_jar(src, dst, want):
    """`src` copied to `dst` when its sha256 is `want`; a `dst` of another hash removed, so no landing's model checker
    reads a jar its tree does not pin. Returns why `dst` is not the pinned jar, or None."""
    have = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest() if os.path.isfile(f) else None
    if want is None:
        return "no TLA2TOOLS_SHA256 in dev/formal/run_tlc.sh"
    if have(dst) == want:
        return None
    with contextlib.suppress(FileNotFoundError):
        os.remove(dst)
    if have(src) != want:
        return f"{src} is {'missing' if not os.path.exists(src) else 'not the pinned jar (sha256 ' + str(have(src)) + ')'}"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, f"{dst}.tmp{os.getpid()}")
    os.chmod(f"{dst}.tmp{os.getpid()}", 0o644)   # readable by every build user
    os.replace(f"{dst}.tmp{os.getpid()}", dst)
    return None

def pins(tree=None):
    """The pinned checkouts WasmTarget's anchors read (Dale's ~/.cache/wasmtarget, which dev/ship.sh fetches first with
    origin's dev/fetch_julia.sh: Julia's and utf8proc's, the pin derived from it), each mirrored at its own commit and
    sparse list (a list grown at the same commit, deps/utf8proc.version, is a new copy): at launch (tools()) and before
    a landing's job (land_job), Dale's own copies, no build user's process. And tla2tools.jar, the model checker
    dev/check.sh runs on the models a landing touches (dev/formal/run_tlc.sh), mirrored when Dale's copy is the jar
    `tree`'s run_tlc.sh pins (TLA2TOOLS_SHA256; `tree` the landing's, else the driver's own): a landing has no network,
    and its run_tlc.sh refuses a missing or other jar, located, never a download (2026-11-14: a move touching
    dev/formal went red at its landing on `curl: Could not resolve host`)."""
    def ident(d):   # a checkout's commit and the files its sparse list checks out
        return tuple(open(f).read().strip() if os.path.exists(f) else "none" for f in (f"{d}/.git/HEAD", f"{d}/.git/info/sparse-checkout"))
    for n in ("julia", "utf8proc", "llvm-project", "dart-sdk"):   # each pinned checkout at its own commit
        src = os.path.realpath(f"{HOME}/.cache/wasmtarget/{n}")
        dst = f"{TOP}/pins/{n}"
        if os.path.exists(dst) and ident(dst) != ident(src):
            shutil.rmtree(dst)
        clone_tree(src, dst)
    why = mirror_jar(f"{HOME}/.cache/wasmtarget/tla2tools.jar", f"{TOP}/pins/tla2tools.jar",
                     tla2tools_pin(tree or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    if why:   # the landing whose models run reads it red there, located (run_tlc.sh); no other landing needs it
        print(f"door: tla2tools.jar not mirrored into {TOP}/pins: {why}", file=sys.stderr)

def pin_claude(state, prune=False):
    """The agents' claude, chosen at launch alone (A6-3, O6-2, O6-3): Dale's current claude copied under TOP/bin and
    its name recorded in the state's claude.json, which claude_bin() reads, so an update of Dale's claude changes
    nothing until the next launch. With `prune` (the real state's launch alone: a scratch state's pin never removes the
    copy the real climb pinned, O7-2), the copy launched and the one before it are kept, every older one removed
    (O6-10). Returns the record."""
    real = os.path.realpath(shutil.which("claude") or "")
    v = os.path.basename(real)
    if not re.fullmatch(r"\d+\.\d+\.\d+", v):
        raise DoorError(f"claude's version is not readable from its install ({v!r})")
    clone_tree(real, f"{TOP}/bin/claude-{v}")
    p = os.path.join(state, "claude.json")
    old = json.load(open(p)) if os.path.exists(p) else {}
    rec = {"claude": f"claude-{v}", "before": old.get("claude") if old.get("claude") != f"claude-{v}" else old.get("before"),
           "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    with open(f"{p}.tmp", "w") as f:
        json.dump(rec, f)
    os.replace(f"{p}.tmp", p)
    for c in glob.glob(f"{TOP}/bin/claude-*") if prune else ():
        if os.path.basename(c) not in (rec["claude"], rec["before"]):
            shutil.rmtree(c) if os.path.isdir(c) else os.remove(c)
    return rec

def plain_ps():
    """TOP/tools/bin/ps, first on a build user's PATH: /bin/ps with no setuid bit and no entitlements (ad-hoc signed).
    A sandboxed process may exec no setuid program (probed: /bin/ps under `(allow default)` gives EPERM), and Kaimon's
    liveness check runs `ps -o state= -p <pid>` (Kaimon/src/gate_client_discovery.jl `_is_pid_alive`), so in the
    `kaimon` profile every session read as dead and its gate files were removed. This copy reads the process table's
    fields (a pid, its user, `Z` for a zombie: Kaimon's check), never what ps reads by task_for_pid, root's alone: its
    `time` reads 0:00.00, `pri` 0 and a live process's `state` `?` (probed); a CPU time is read by proc_pid_rusage
    (test/dart_limit.jl)."""
    ps = f"{TOP}/tools/bin/ps"
    if not os.path.exists(ps):
        shutil.copyfile("/bin/ps", f"{ps}.tmp"); os.chmod(f"{ps}.tmp", 0o755)
        r = subprocess.run(["/usr/bin/codesign", "-f", "-s", "-", f"{ps}.tmp"], capture_output=True, text=True)
        if r.returncode:
            raise DoorError(f"codesign of the plain ps: {r.stderr.strip()[-200:]}")
        os.rename(f"{ps}.tmp", ps)
    return ps

def claude_bin(state):
    """The climb's claude: the copy the launch recorded in the state (pin_claude), never the newest on disk."""
    p = os.path.join(state, "claude.json")
    name = (json.load(open(p)).get("claude") if os.path.exists(p) else None) or ""
    if not re.fullmatch(r"claude-\d+\.\d+\.\d+", name) or not os.path.exists(f"{TOP}/bin/{name}"):
        raise DoorError(f"no claude pinned at launch in {state} ({name or 'no claude.json'}): `python3 dev/climb/door.py pin-claude <state>` (launch's preflight)")
    return f"{TOP}/bin/{name}"

def dale_uuid():
    """Dale's uid's UUID (membership's mbr_uid_to_uuid, in the driver, which has his Mach bootstrap): what homeacl sets."""
    import ctypes, ctypes.util, uuid
    u = ctypes.create_string_buffer(16)
    if ctypes.CDLL(ctypes.util.find_library("System")).mbr_uid_to_uuid(os.getuid(), u) != 0:
        raise DoorError("mbr_uid_to_uuid failed for the driver's uid")
    return str(uuid.UUID(bytes=u.raw)).upper()
HOMEACL = f"{TOP}/tools/bin/homeacl"   # dev/climb/homeacl.c, built by tools()
# the one removal of a build user's files, as the user (R7-5): what its owner can set to make an rm fail (an immutable
# or append-only flag, a deny ACE, a mode without its own write or search) undone, then removed. Each pass restores
# traversal before it clears flags (R8-4: `chflags -R` cannot enter a directory of mode 000, so an immutable file in one
# survived a clean), and a pass reaches one level of directories made immutable and untraversable more than the last,
# so the passes repeat while each changes the tree (its listing with modes, flags and ACLs, `ls -lRaOe`: a pass
# removes entries or opens a level), never to a fixed count (R9-2: 16 passes left a nest 40 deep refusing two uses);
# a pass that changes nothing ends it, its rm's failure the result. The passes only ever loosen and remove, so they end;
# tree_wall_s bounds them. $1 names the entries kept, the rest are the directory's entries (or the paths given after $2)
WIPE = ('w() { p=; until /bin/rm -rf "$1" 2>/dev/null; do '
        '/bin/chmod -R u+rwX "$1" 2>/dev/null; /usr/bin/chflags -R nouchg,nouappnd "$1" 2>/dev/null; /bin/chmod -R -N "$1" 2>/dev/null; '
        '/bin/chmod -R u+rwX "$1" 2>/dev/null; q=$(/bin/ls -lRaOe "$1" 2>&1 | /sbin/md5); '
        '[ "$q" != "$p" ] || { /bin/rm -rf "$1"; return 1; }; p=$q; done; }; ')

def clean(role):
    """Everything in the role's home but what KEEPS names removed as its user, each entry's flags, ACLs and modes
    cleared first (WIPE), and the home's own mode (700) and ACL (Dale's read, as setup-users.sh sets it) made again, so
    no run can leave its role unusable (R7-5: an immutable file made the next use refuse for good); the ACL is set by
    homeacl (dev/climb/homeacl.c: a run has no Mach bootstrap, so chmod +a cannot name Dale); nothing else left (read
    back)."""
    rc, out, err = run(role, ["/bin/sh", "-c", WIPE + 'cd "$HOME" || exit 1; for e in * .[!.]* ..?*; do '
                              '[ -e "$e" ] || [ -L "$e" ] || continue; case " $1 " in *" $e "*) continue;; esac; w "$e"; done; '
                              '/usr/bin/chflags nouchg,nouappnd "$HOME" && /bin/chmod 700 "$HOME" && "$2" "$HOME" "$3"',
                              "sh", " ".join(KEEPS[role]), HOMEACL, dale_uuid()], DEFAULTS["tree_wall_s"], profile=NONE)
    left = sorted(set(list_home(role, "")) - set(KEEPS[role]))
    if left or rc != 0:
        raise DoorError(f"{ROLES[role]}'s home keeps {left} past its clean (rc={rc}: {err.strip()[-200:]})")

# a plant only the owner's own rights make (door-probe's row and v8's p7): an immutable file in a directory that denies
# its own deletion by an ACE, mode 500, inside an append-only directory; and (R8-4) an immutable file under two
# directories each immutable and of mode 000, the inner inside the outer
STUCK = ('mkdir -p "$HOME/stuck/d" && echo x > "$HOME/stuck/d/f" && /usr/bin/chflags uchg "$HOME/stuck/d/f" && '
         '/bin/chmod +a "everyone deny delete,delete_child" "$HOME/stuck/d" && /bin/chmod 500 "$HOME/stuck/d" && '
         '/usr/bin/chflags uappnd "$HOME/stuck" && mkdir -p "$HOME/z/d1/d2" && echo x > "$HOME/z/d1/d2/f" && '
         '/usr/bin/chflags uchg "$HOME/z/d1/d2/f" && /bin/chmod 000 "$HOME/z/d1/d2" && /usr/bin/chflags uchg "$HOME/z/d1/d2" && '
         '/bin/chmod 000 "$HOME/z/d1" && /usr/bin/chflags uchg "$HOME/z/d1"')
# (R9-2) an immutable file at the bottom of 64 directories each immutable and of mode 000, the inner inside the outer
DEEP = ('d="$HOME/deep"; p="$d"; for i in $(/usr/bin/jot 64); do p="$p/d"; done; /bin/mkdir -p "$p" && echo x > "$p/f" && '
        '/usr/bin/chflags uchg "$p/f" && while [ "$p" != "$d" ]; do /bin/chmod 000 "$p" && /usr/bin/chflags uchg "$p" || exit 1; p="${p%/d}"; done')

def wipe(role, path):
    """`path` of the role's home removed as its user as clean() removes an entry: (rc, its error)."""
    rc, out, err = run(role, ["/bin/sh", "-c", WIPE + 'w "$1"', "sh", path], DEFAULTS["tree_wall_s"], profile=NONE)
    return rc, err

def prepare(role):
    """The role's home as each run expects it, made by its user: its TMPDIR, and ~/.cache/wasmtarget the pins."""
    rc, out, err = run(role, ["/bin/sh", "-c", f'mkdir -p "$HOME/tmp" "$HOME/.cache" && ln -sfn {TOP}/pins "$HOME/.cache/wasmtarget"'], DEFAULTS["step_wall_s"], profile=NONE)
    if rc != 0:
        raise DoorError(f"prepare {ROLES[role]}: {err.strip()[-200:]}")

# ---------------------------------------------------------------- the profiles a Julia job runs in, inside its user
def _q(p):
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'

# what a `native` process reads besides the paths it is given (R8-1, an allowlist, never "everything but a hide list"):
# Julia's install under TOP/tools, and what the dynamic loader, libSystem, sh and Julia's start read. The kernel logged
# no denial of these runs (`log show` held none for them), so each name was found one at a time by bisection (each
# top-level directory denied in turn under an otherwise open profile), and then each entry removed in turn, as Dale
# and as _wtm1 (v9 p2): the root's own listing ("/": sh and Julia abort without it, rc -6), /bin/sh's choice of shell
# (/private/var/select/sh) and the locale (Julia's UTF-8: a warning without it); the libraries come from the dyld
# shared cache, which needs no read. /dev/null's read is the run process's (spec v17 Y1): Julia starts a child with its
# stdin on /dev/null (`readchomp(\`node --version\`)` in test/runner.jl's node_binary), refused with EPERM without it (probed)
NATIVE_READS = ("/usr/share/locale", "/private/var/select")
NATIVE_LITERALS = ("/", "/dev/null")
NATIVE_META = ("/", "/Users", "/Users/Shared", "/private", "/private/var", "/private/var/db", "/System", "/System/Volumes",
               "/System/Volumes/Preboot", "/usr", "/usr/share", "/private/etc", "/etc", "/var", "/tmp", "/private/tmp")

def _ancestors(p):
    """Every directory above `p`: what a lookup of `p` stats on its way (a `native` process's metadata reads)."""
    out = []
    while p not in ("/", ""):
        p = os.path.dirname(p); out.append(p)
    return out

def profile(path, writes, kind="julia", binds=(), port=None, egress=None, reads=()):
    """A `(deny default)` seatbelt for a job already running as a build user: it reads what its user may (the user
    boundary and the sealed home decide that), writes only `writes` (never a `.git` for a `julia` job), executes
    Julia's, the system's and Homebrew's programs, opens no network connection (a unix socket's connect is one),
    binds unix sockets only under `binds`, signals only its own sandbox and looks up no Mach service, so neither
    launchd nor LaunchServices nor AppleEvents starts a process for it. `check` also writes a `.git` (its clone's own
    caches); `kaimon` (a slot's server and its sessions) also listens and connects on TCP `port` of localhost alone
    and connects to unix sockets under `binds` (probed: as a build user with no profile, `launchctl submit` ran a job
    as Dale, sudo keeping his Mach bootstrap; in each profile it is refused). `agent` (`claude`, its tools and their
    children) also executes the pinned claude and connects to localhost's `egress` (the driver's proxy() to its model)
    and `port` (its slot's Kaimon) alone: no other address, no DNS and no Mach lookup, which `claude`, git and their
    TLS need none of (probed); `(allow … "*:*")` then `(deny … "localhost:*")` lets localhost through (probed), so the
    rule names ports. Claude Code's own sandbox cannot run inside it: on this macOS a nested sandbox_apply fails
    under any outer profile that denies anything (probed with one deny of a file, a Mach name, a port). `native` (a
    measurement's judging process, which runs corpus code a move may add, R7-1) executes Julia's install and the door's
    /bin/sh (bash, which macOS's sh runs) alone (no node, no Homebrew, no artifact) and reads an allowlist alone (R8-1):
    `reads` (its judging directory and its labels), its `writes`, Julia's install and what the loader and
    libSystem read (NATIVE_READS, NATIVE_LITERALS, each path's ancestors' metadata), so it can neither evaluate a
    module nor load a src, nor read any other file of its run (compile.log: probed, EPERM)."""
    # (in/: Dale's own run files, a session's julia among them)
    ex = [f"{TOP}/tools", "/bin/sh", "/bin/bash"] if kind == "native" else \
        [f"{TOP}/tools", f"{TOP}/julia/artifacts", f"{TOP}/in", "/opt/homebrew", "/bin", "/usr/bin", "/usr/libexec", "/usr/sbin",
         "/Library/Java", "/Library/Developer/CommandLineTools"] + ([f"{TOP}/bin"] if kind == "agent" else [])
    w = " ".join(f"(subpath {_q(os.path.realpath(p))})" for p in writes)
    rd = ["(allow file-read*)"] if kind != "native" else \
        ["(allow file-read* " + " ".join(f"(subpath {_q(os.path.realpath(p))})" for p in (f"{TOP}/tools", *NATIVE_READS, *reads, *writes)) + ")",
         "(allow file-read-data " + " ".join(f"(literal {_q(p)})" for p in NATIVE_LITERALS) + ")",
         "(allow file-read-metadata " + " ".join(f"(literal {_q(p)})" for p in sorted(set(NATIVE_META) | {
             a for p in (f"{TOP}/tools", *reads, *writes) for a in _ancestors(os.path.realpath(p))})) + ")"]
    out = ["(version 1)", "(deny default)", *rd, "(allow process-fork)",
           "(allow process-exec " + " ".join(f"({'literal' if p in ('/bin/sh', '/bin/bash') else 'subpath'} {_q(p)})" for p in ex) + ")",
           "(allow sysctl-read)", "(allow signal (target same-sandbox))", "(allow process-info* (target same-sandbox))",
           "(allow system-sched)", "(allow system-socket)", "(allow file-ioctl)",
           "(allow ipc-posix-shm-read-data ipc-posix-shm-write-data ipc-posix-shm-read-metadata)",
           f"(allow file-write* {w} (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (literal \"/dev/ptmx\")"
           " (regex #\"^/dev/tty\") (subpath \"/dev/fd\"))"]
    if kind in ("julia", "native"):
        out.append("(deny file-write* (regex #\"/\\.git(/|$)\"))")
    for b in binds:
        out += [f"(allow file-write* (subpath {_q(b)}))", f"(allow network-bind (local unix-socket (subpath {_q(b)})))",
                f"(allow network-inbound (local unix-socket (subpath {_q(b)})))",
                f"(allow network-outbound (remote unix-socket (subpath {_q(b)})))"]
    if kind == "kaimon":
        out += [f"(allow network-bind (local ip \"localhost:{port}\"))", f"(allow network-inbound (local ip \"localhost:{port}\"))",
                f"(allow network-outbound (remote ip \"localhost:{port}\"))"]   # no Mach lookup: a session's gate is found by
        # polling its socket directory (probed under nobootstrap: a session matched in 27 s)
    if kind == "agent":
        out.append("(allow network-outbound" + "".join(f" (remote ip \"localhost:{p}\")" for p in (egress, port) if p) + ")")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    return path

API = "api.anthropic.com"   # the one host an agent reaches, through proxy()
# the calls `claude -p` makes with ANTHROPIC_BASE_URL set (observed with claude-2.1.321, 2026-11-09): every other one is a 403
CALLS = {("POST", "/v1/messages")}

def done_tools(req):
    """The tools a request's conversation ran without an error: the name of each tool_use whose tool_result is not
    is_error (what `claude` itself sent, read in the driver, never the agent's transcript)."""
    names, ok = {}, set()
    for m in req.get("messages") or []:
        for b in m.get("content") if isinstance(m.get("content"), list) else []:
            if b.get("type") == "tool_use":
                names[b.get("id")] = b.get("name")
            elif b.get("type") == "tool_result" and not b.get("is_error"):
                ok.add(b.get("tool_use_id"))
    return {names[i] for i in ok if i in names}

def _no_duplicate(pairs):
    """json's object hook: a body with a key twice is refused (the API's parser and this one could read different
    values, R6-6)."""
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError(f"a key twice: {sorted(k for k in set(keys) if keys.count(k) > 1)[:3]}")
    return dict(pairs)

# the content a run's claude sends, an allowlist (R7-3, ruling 29): each block of a message, of a tool_result's content
# and of the system prompt is one of BLOCKS, and a block's `source` one of SOURCES (data in the body); anything else is
# a 403, named in the run's `refused`: a `url` source has the API fetch any address for the agent, as a server tool
# would. Observed through the proxy (2026-11-10, claude-2.1.322, the climber's, reviewer's and auditor's argv at their
# efforts, each told to Read a text file, a PNG and a PDF and run Bash): text, thinking, tool_use, tool_result,
# image/base64 and document/base64, nothing else. redacted_thinking is the API's own block in an answer, which claude
# sends back unchanged (refusing it would fail the next call of a run whose answer held one); no source but base64 was
# sent, so none other is admitted
BLOCKS = {"text", "image", "document", "tool_use", "tool_result", "thinking", "redacted_thinking"}
# the top-level keys of a body, an allowlist (R8-6): observed through the proxy (2026-11-10, claude-2.1.322, five runs:
# the climber's argv on Opus at efforts high and low, and the climber's, reviewer's and auditor's on Haiku, each the
# same ten keys); `service_tier`, `speed`, `mcp_servers`, `container` and any key not observed is a 403, so no
# capability the API adds later, nor one dollars() does not price, passes unread
BODY_KEYS = {"context_management", "max_tokens", "messages", "metadata", "model", "output_config", "stream", "system",
             "thinking", "tools"}
SYSTEM_BLOCKS = {"text"}
SOURCES = {"base64"}

def block_refusal(blocks, where, kinds=BLOCKS):
    """Why a list of content blocks is refused, or None (BLOCKS, SOURCES), a tool_result's content read the same way."""
    if not isinstance(blocks, list):
        return f"{where}: content neither text nor a list of blocks"
    for b in blocks:
        kind = b.get("type") if isinstance(b, dict) else None
        if kind not in kinds:
            return f"{where}: a content block of type {str(kind)[:40]!r}"
        src = b.get("source")
        if src is not None and (not isinstance(src, dict) or src.get("type") not in SOURCES):
            return f"{where}: a {kind} block sourced {str(src.get('type') if isinstance(src, dict) else src)[:40]!r}"
        if kind == "tool_result" and not isinstance(b.get("content"), (str, type(None))):
            why = block_refusal(b["content"], "a tool_result")
            if why:
                return why
    return None

def block_kinds(req):
    """The content blocks a body holds, as `type` or `type/source type`, tool_results' content and the system's
    included: what the proxy observed its claude send (the record's `blocks`, which re-derives BLOCKS)."""
    out = set()
    def walk(bs):
        for b in bs if isinstance(bs, list) else []:
            if isinstance(b, dict):
                src = b.get("source")
                out.add(str(b.get("type")) + (f"/{src.get('type')}" if isinstance(src, dict) else ""))
                if b.get("type") == "tool_result":
                    walk(b.get("content"))
    for m in req.get("messages") or [] if isinstance(req, dict) else []:
        walk(m.get("content") if isinstance(m, dict) else None)
    walk(req.get("system") if isinstance(req, dict) else None)
    return out

def body_refusal(req, models):
    """Why the proxy refuses a call's body, or None: it admits only what the run's own claude sends (R6-6), its run's
    model (R10), top-level keys of BODY_KEYS alone (R8-6: no MCP connector, container, service tier or speed), only tools of its own (no `type`, or `custom`: a server tool, web_fetch,
    web_search, code_execution, ..., would give the agent the network its profile denies), and content blocks of
    BLOCKS with sources of SOURCES alone (R7-3)."""
    if not isinstance(req, dict):
        return "no JSON object"
    if req.get("model") not in models:
        return "a model not its run's"
    extra = sorted(set(req) - BODY_KEYS)
    if extra:
        return f"a top-level key off its list, `{str(extra[0])[:40]}`"
    tools = req.get("tools") or []
    if not isinstance(tools, list) or any(not isinstance(x, dict) or x.get("type") not in (None, "custom") for x in tools):
        return "a server tool"
    msgs = req.get("messages")
    if not isinstance(msgs, list) or not all(isinstance(m, dict) for m in msgs):
        return "messages that are no list of objects"
    for m in msgs:
        why = None if isinstance(m.get("content"), str) else block_refusal(m.get("content"), "a message")
        if why:
            return why
    sys_ = req.get("system")
    return None if sys_ is None or isinstance(sys_, str) else block_refusal(sys_, "the system prompt", SYSTEM_BLOCKS)

def add_usage(total, u):
    """An answer's `usage` added into a run's `total`, every integer summed, a dict's within it (the cache writes' 5-minute
    and 1-hour parts among them), so the run's dollars are counted by kind (core.dollars)."""
    for k, v in u.items():
        if isinstance(v, dict):
            if not isinstance(total.get(k), dict):
                total[k] = {}
            add_usage(total[k], v)
        elif isinstance(v, int) and not isinstance(v, bool):
            total[k] = (total[k] if isinstance(total.get(k), int) else 0) + v
    return total

def merge_usage(u, d):
    """An answer's `usage` merged into `u`, every value kept (R6-6: a fee in a dict is never dropped): an int at its
    largest seen (an SSE stream repeats running totals), a dict merged the same way, anything else as given."""
    for k, v in d.items():
        if isinstance(v, dict):
            if not isinstance(u.get(k), dict):
                u[k] = {}
            merge_usage(u[k], v)
        elif isinstance(v, int) and not isinstance(v, bool):
            u[k] = max(u[k], v) if isinstance(u.get(k), int) else v
        else:
            u[k] = v
    return u

@contextlib.contextmanager
def proxy(token, models, admit, book, role=None):
    """The one road from an `agent` profile to the network and the one holder of the agents' token (D-F): a plain HTTP
    server on a localhost port of the driver's, the agent's ANTHROPIC_BASE_URL (its own credential a placeholder), that
    forwards a call in CALLS whose body names a model in `models` (the run's own, R10) to API over verified TLS with its
    Authorization replaced by `token`, and streams the answer back line by line as it comes (SSE). It asks admit() (the
    governor and the run's dollar cap: admit(rec)) before each call and gives each answer's usage to book() at once
    (the governor's one spend source, which every live run's proxy writes, so no set of runs passes the room, R11).
    It admits only bodies body_refusal() passes, read with no key twice, each of a decimal Content-Length (no
    Transfer-Encoding; anything else a 400 or 411, unread, R7-2), and at most proxy_in_flight calls at once
    (more is a 429, which claude retries). Anything else is a 403. It cannot hold a run or swell the driver (R6-5): a
    body over proxy_body_bytes is a 413, unread; each call has one deadline, proxy_request_s of `role`'s awake time
    (awake(): a landing's stop of the agent is never a cut call, so no call is paid twice, A6-9), past which its
    client's and upstream's sockets are shut; no per-write timeout; its handlers are daemon threads, and on leaving it
    waits proxy_join_s for calls still answering before it shuts them; a call's usage and its `admitted` row are booked
    in a `finally`, so a cut, a timeout or a reset loses nothing its answer already carried (A8-3). Yields {"port",
    "usage", "refused", "admitted", "tools"}: the usage summed from the answers themselves, by kind, each refused call with its
    model, each admitted call's model and status, and done_tools() of what it forwarded, all held by the driver.
    Precedent: Claude Code's sandbox proxy (a localhost allowlist) and an API gateway's credential injection; how this
    differs: it outlives no run and serves one agent, so its record is the run's alone, and a call's answer is read
    only for its `usage`."""
    import http.client, http.server, socket, ssl, threading
    rec = {"usage": {}, "refused": [], "admitted": [], "tools": set(), "peak": 0, "blocks": set(), "keys": set()}
    lock, tls, live_calls, handlers = threading.Lock(), ssl.create_default_context(), [0], set()
    clock = (lambda t0: awake(role, t0)) if role else (lambda t0: CLOCK() - t0)
    class One(http.server.BaseHTTPRequestHandler):
        up = upsock = None
        def log_message(self, *a):
            pass
        def handle(self):
            with lock:
                handlers.add(self)
            try:
                super().handle()
            finally:
                with lock:
                    handlers.discard(self)
        def cut(self):
            """This call's client and upstream sockets shut: a read or write blocked on either ends."""
            for s in (self.connection, self.upsock):   # the upstream's own socket: http.client drops its `sock` once
                # a response that closes the connection is read (A8-3: a cut call kept reading its pings to their end)
                with contextlib.suppress(OSError, AttributeError):
                    s.shutdown(socket.SHUT_RDWR)
        def do_POST(self):
            t0, ended = CLOCK(), threading.Event()
            def watch():   # the call's one deadline, in the role's awake time
                while not ended.wait(1):
                    if clock(t0) > DEFAULTS["proxy_request_s"]:
                        with lock:
                            rec["refused"].append([self.command, self.path, None, "past proxy_request_s"])
                        return self.cut()
            threading.Thread(target=watch, daemon=True).start()
            try:
                self.serve()
            finally:
                ended.set()
        def serve(self):
            call, cl = (self.command, self.path.split("?")[0]), self.headers.get("Content-Length")
            if call not in CALLS:   # a call off its list, refused unread whatever its body
                with lock:
                    rec["refused"].append([*call, None, "a call off its list"])
                return self.send_error(403)
            # the body's length, decided before a byte is read (R7-2): a decimal Content-Length and no
            # Transfer-Encoding, or the call is refused unread (a negative length read to EOF: 600 MB swelled the
            # driver by 1.2 GB)
            if self.headers.get("Transfer-Encoding") is not None or cl is None or not re.fullmatch(r"[0-9]{1,15}", cl.strip()):
                with lock:
                    rec["refused"].append([*call, None, f"a body of no decimal length ({str(cl)[:20]!r}, "
                                                        f"Transfer-Encoding {str(self.headers.get('Transfer-Encoding'))[:20]!r})"])
                return self.send_error(411 if cl is None and self.headers.get("Transfer-Encoding") is None else 400)
            n = int(cl)
            if n > DEFAULTS["proxy_body_bytes"]:
                with lock:
                    rec["refused"].append([*call, None, f"a body of {n} bytes"])
                return self.send_error(413)
            body = self.rfile.read(min(n, DEFAULTS["proxy_body_bytes"]))
            try:
                req = json.loads(body or b"{}", object_pairs_hook=_no_duplicate)
            except ValueError as e:
                req = f"unreadable: {e}"
            model = req.get("model") if isinstance(req, dict) else None
            why = body_refusal(req, models) if isinstance(req, dict) else req
            with lock:
                busy = live_calls[0] >= DEFAULTS["proxy_in_flight"]
            if why or busy or not admit(rec):
                with lock:
                    rec["refused"].append([*call, model] + ([why] if why else ["in flight"] if busy else []))
                return self.send_error(429 if busy and not why else 403)
            with lock:
                live_calls[0] += 1; rec["peak"] = max(rec["peak"], live_calls[0])
            try:
                self.forward(body, req, model)
            finally:
                with lock:
                    live_calls[0] -= 1
        def forward(self, body, req, model):
            r, u = None, {}
            try:
                up = self.up = http.client.HTTPSConnection(API, context=tls, timeout=DEFAULTS["proxy_request_s"])
                up.request(self.command, self.path, body, {**{k: v for k, v in self.headers.items() if k.lower() not in
                           ("host", "authorization", "accept-encoding", "connection", "content-length")}, "Authorization": "Bearer " + token})
                self.upsock = up.sock
                r, live = up.getresponse(), True
                self.send_response(r.status)
                for k, v in r.getheaders():
                    if k.lower() not in ("connection", "content-length", "transfer-encoding"):
                        self.send_header(k, v)
                self.end_headers()
                while line := r.readline():   # read to its end even when the agent hung up: the spend is the answer's
                    try:
                        live and (self.wfile.write(line), self.wfile.flush())
                    except OSError:
                        live = False
                    with contextlib.suppress(ValueError, AttributeError, KeyError, TypeError):   # an SSE event's line or a JSON body
                        d = json.loads(line.removeprefix(b"data:"))
                        merge_usage(u, d.get("usage") or d["message"]["usage"])
            finally:   # a deadline cut, an idle timeout or a reset loses nothing the answer already carried (A8-3)
                with lock:
                    add_usage(rec["usage"], u)
                    rec["admitted"].append([model, r.status if r is not None else None])
                    rec["tools"] |= done_tools(req); rec["blocks"] |= block_kinds(req); rec["keys"] |= set(req)
                if u:
                    book(u)
        do_GET = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_POST
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), One)
    srv.daemon_threads, srv.block_on_close = True, False   # leaving waits proxy_join_s for its calls, never more
    srv.handle_error = lambda *a: None   # a call cut (its deadline, its agent gone) ends its handler, recorded in `refused`
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        rec["port"] = srv.server_address[1]
        yield rec   # the record itself, filled as calls come
    finally:
        srv.shutdown()
        t_end = CLOCK() + DEFAULTS["proxy_join_s"]
        while handlers and CLOCK() < t_end:
            time.sleep(0.1)
        with lock:
            left = list(handlers)
        for h in left:
            h.cut()
        srv.server_close()

# ---------------------------------------------------------------- the probe: what the door must refuse, tried for no tokens
def bootstrap_tries(mark, label):
    """What sudo's kept Mach bootstrap gave a build user (probed 2026-11-09: each reached Dale): each must fail."""
    d = f"gui/{os.getuid()}"
    return [("launchctl print of Dale's domain", ["/bin/launchctl", "print", d]),
            ("launchctl submit of a job that runs as Dale", ["/bin/launchctl", "submit", "-l", f"{label}.sub", "--", "/usr/bin/touch", f"{mark}-launchd"]),
            ("launchctl setenv in Dale's domain", ["/bin/launchctl", "setenv", "WTCLIMB_DOORPROBE", "1"]),
            ("launchctl getenv of a variable Dale set", ["/bin/launchctl", "getenv", "WTCLIMB_DOORPROBE_GET"]),
            ("launchctl disable of Dale's job", ["/bin/launchctl", "disable", f"{d}/{label}"]),
            ("launchctl kill of Dale's job", ["/bin/launchctl", "kill", "SIGKILL", f"{d}/{label}"]),
            ("an AppleEvent to Finder", ["/usr/bin/osascript", "-l", "JavaScript", "-e", 'Application("Finder").startupDisk.name()']),
            ("open", ["/usr/bin/open", "-g", "-j", "-a", "Calculator"]),
            ("the pasteboard", ["/usr/bin/pbpaste"])]

def dale_untouched(mark, label, pid0, calc0):
    """'' when Dale's domain shows none of bootstrap_tries' effects, else what it shows (each effect undone)."""
    d, bad = f"gui/{os.getuid()}", []
    pr = subprocess.run(["/bin/launchctl", "print", f"{d}/{label}"], capture_output=True, text=True).stdout
    if f"pid = {pid0}" not in pr:
        bad.append("the probe's job was killed")
    if f'"{label}" => disabled' in subprocess.run(["/bin/launchctl", "print-disabled", d], capture_output=True, text=True).stdout:
        bad.append("the probe's job was disabled"); subprocess.run(["/bin/launchctl", "enable", f"{d}/{label}"])
    if subprocess.run(["/bin/launchctl", "getenv", "WTCLIMB_DOORPROBE"], capture_output=True, text=True).stdout.strip():
        bad.append("Dale's launchd environment was set"); subprocess.run(["/bin/launchctl", "unsetenv", "WTCLIMB_DOORPROBE"])
    if subprocess.run(["/bin/launchctl", "remove", f"{label}.sub"], capture_output=True).returncode == 0 or os.path.exists(f"{mark}-launchd"):
        bad.append("a job ran as Dale")
    if not calc0 and subprocess.run(["/usr/bin/pgrep", "-x", "Calculator"], capture_output=True).returncode == 0:
        bad.append("Calculator was launched")
    return "; ".join(bad)

def takes_at_once(role, rel, unblock):
    """take() of `rel` raised DoorError within a second (R6-1's row): (ok, evidence). A take still waiting after it is
    released by `unblock` (a writer for a FIFO), so a broken door fails the row rather than hanging the probe."""
    import threading
    got = {}
    def go():
        try:
            got["v"] = take(role, rel, 1 << 20)
        except DoorError as e:
            got["e"] = str(e)
    th = threading.Thread(target=go, daemon=True)
    t0 = time.time(); th.start(); th.join(1.0)
    if th.is_alive():
        unblock(); th.join(10)
        return False, f"take() still waited after 1 s (released by a writer: {got})"
    return "e" in got, f"{round(time.time() - t0, 3)} s: " + (got.get("e") or f"returned {got.get('v')!r}")

def refused_unread(port, head, want):
    """R7-2's row: a call to the proxy at `port` with header `head`, its body streamed, answered `want` within a second
    (ok, evidence); a proxy that reads the body first answers only when the stream ends, past the second."""
    import socket
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(0.05)
    try:
        s.sendall(f"POST /v1/messages HTTP/1.1\r\nHost: x\r\n{head + chr(13) + chr(10) if head else ''}\r\n".encode())
        t0, got = CLOCK(), b""
        while CLOCK() - t0 < 1.0 and b"\r\n" not in got:
            try:
                s.sendall(b"x" * 65536)
            except OSError:
                pass
            try:
                got += s.recv(200)
            except (socket.timeout, OSError):
                pass
        return want in got[:40], f"{round(CLOCK() - t0, 2)} s: {got[:40]!r}"
    finally:
        s.close()

def probe(state, gitdir):
    """Item 1: as each build user, each of these must fail: a write into the climb's state and into the main .git; a
    read of ~/.ssh/known_hosts, of ~/Documents, of Dale's home and its ~/.gitconfig, and of another build user's home;
    `kill -0` of the driver; a crontab. Inside the `julia` profile: a connect to 127.0.0.1:2828 and to an outside
    address, `open`, an AppleEvent that would run a command as Dale, `launchctl submit` of a job that would (no file
    made, no job left), a `launchctl getenv` of a variable Dale set (its value never read); while Julia runs there.
    Then reap() leaves no process after a setsid child that ignores TERM and a detached node child. Inside the `agent`
    profile, bootstrap_tries() and the network fail, and its proxy refuses a call off its list and a model not its
    run's. Returns [(check, ok, evidence)]."""
    out, me, mark = [], os.getpid(), f"/private/tmp/wtclimb-doorprobe-{os.getpid()}"
    label = f"wtclimb.doorprobe-target.{me}"   # a job of Dale's the tries aim at
    subprocess.run(["/bin/launchctl", "submit", "-l", label, "--", "/bin/sleep", "3600"], check=True); time.sleep(1)
    pid0 = re.search(r"\bpid = (\d+)", subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True, text=True).stdout)[1]
    calc0 = subprocess.run(["/usr/bin/pgrep", "-x", "Calculator"], capture_output=True).returncode == 0
    val = f"wtclimb-doorprobe-{me}"   # Dale's launchd environment holds it while the probe runs: no build user reads it
    subprocess.run(["/bin/launchctl", "setenv", "WTCLIMB_DOORPROBE_GET", val], check=True)
    try:
        return _probe(state, gitdir, out, me, mark, label, pid0, calc0, val)
    finally:
        subprocess.run(["/bin/launchctl", "unsetenv", "WTCLIMB_DOORPROBE_GET"])
        subprocess.run(["/bin/launchctl", "remove", label], capture_output=True)

def _probe(state, gitdir, out, me, mark, label, pid0, calc0, val):
    def held(what, rc, o):   # launchctl getenv answers rc 0 and nothing with no bootstrap (probed): its value is the test
        if what == "the pasteboard":
            return not o
        if what.startswith("launchctl getenv"):
            return val not in o
        return rc not in (0, None) and not (what == "an AppleEvent to Finder" and o.strip())
    tries = [("a write into the climb's state", ["/usr/bin/touch", f"{state}/door-probe"]),
             ("a write into the main .git", ["/usr/bin/touch", f"{gitdir}/door-probe"]),
             ("a read of ~/.ssh/known_hosts", ["/bin/cat", f"{HOME}/.ssh/known_hosts"]),
             ("a read of ~/Documents", ["/bin/ls", f"{HOME}/Documents"]),
             ("a list of Dale's home", ["/bin/ls", HOME]), ("a read of ~/.gitconfig", ["/bin/cat", f"{HOME}/.gitconfig"]),
             ("kill -0 of the driver", ["/bin/kill", "-0", str(me)]),
             ("a crontab", ["/bin/sh", "-c", "echo '* * * * * /usr/bin/true' | /usr/bin/crontab -"]),
             ("a flock of a role's lock (R8-2)", ["/usr/bin/perl", "-e", 'use Fcntl qw(:flock); open(my $f, "<", $ARGV[0]) or die "open: $!"; '
                                                   'flock($f, LOCK_EX | LOCK_NB) or die "flock: $!"', f"{LOCKS}/.role-review3.lock"])]
    for role in ROLES:
        other = ROLES["deps" if role != "deps" else "measure"]
        for what, cmd in tries + [("a read of another build user's home", ["/bin/ls", f"{TOP}/u/{other}"])] + bootstrap_tries(mark, label):
            rc, o, e = run(role, cmd, DEFAULTS["step_wall_s"], profile=NONE)   # the user boundary alone: no Mach bootstrap
            out.append((f"{ROLES[role]}: {what}", held(what, rc, o), f"rc={rc} " + ("(pasteboard text)" if o and what == "the pasteboard" else (o + e).strip()[-100:])))
        bad = dale_untouched(mark, label, pid0, calc0)
        out.append((f"{ROLES[role]}: Dale's launchd domain untouched", not bad, bad or "job alive, enabled, no environment, no job made"))
        if os.path.isdir(f"{TOP}/cache.git"):   # origin's history: the HISTORY roles read it, no other (R6-4)
            rc, o, e = run(role, ["git", "-c", "safe.directory=*", f"--git-dir={TOP}/cache.git", "rev-list", "--count", "--all"], DEFAULTS["step_wall_s"], profile=NONE)
            out.append((f"{ROLES[role]}: " + ("reads" if role in HISTORY else "no read of") + " the history cache",
                        (rc == 0) == (role in HISTORY), f"rc={rc} {(o + e).strip()[-80:]}"))
    with using("measure"):
        for name in ("deps", "lock:verify"):   # LOCK_ORDER (spec v17 Y3): a lock not after every held one, refused first
            what = f"LOCK_ORDER: {name} taken while the measure role is held"
            try:
                assert_order(name); out.append((what, False, "taken"))
            except LockOrder as e:
                out.append((what, True, str(e)[:100]))
        d = give("measure", "door-probe")
        prof = profile(f"{d}/julia.sb", [f"{home('measure')}/tmp"])
        jail = [("a connect to 127.0.0.1:2828", ["/usr/bin/curl", "-s", "-m", "5", "http://127.0.0.1:2828/"]),
                ("a connect outside", ["/usr/bin/curl", "-s", "-m", "5", "https://example.com/"]),
                ("open", ["/usr/bin/open", "-a", "Calculator"]),
                ("an AppleEvent to Finder", ["/usr/bin/osascript", "-l", "JavaScript", "-e", 'Application("Finder").startupDisk.name()']),
                ("launchctl getenv of a variable Dale set", ["/bin/launchctl", "getenv", "WTCLIMB_DOORPROBE_GET"]),
                ("launchctl submit of a job that runs as Dale", ["/bin/launchctl", "submit", "-l", f"wtclimb.doorprobe.{os.getpid()}", "--",
                                                                 "/usr/bin/touch", f"{mark}-launchd"])]
        for what, cmd in jail:
            rc, o, e = run("measure", cmd, DEFAULTS["step_wall_s"], profile=prof)
            time.sleep(1)
            made = [f for f in (f"{mark}-ae", f"{mark}-launchd") if os.path.exists(f)]
            out.append((f"the julia profile: {what}", held(what, rc, o) and not made, (o + e).strip()[-120:] or f"rc={rc}"))
        job = subprocess.run(["launchctl", "remove", f"wtclimb.doorprobe.{os.getpid()}"], capture_output=True).returncode == 0
        out.append(("the julia profile: no launchd job made", not job, f"a job removed: {job}"))
        rc, o, e = run("measure", ["julia", "--startup-file=no", "-e", "print(1 + 1)"], DEFAULTS["parse_wall_s"], profile=prof)
        out.append(("the julia profile: Julia runs", rc == 0 and o.strip() == "2", (o + e).strip()[-120:]))
        # the judging process's profile (R7-1): no node or other program but Julia's, none of what it hides is read
        h = f"{home('measure')}/tmp"
        run("measure", ["/bin/sh", "-c", f'mkdir -p "{h}/hid" "{h}/w" && echo secret > "{h}/hid/modules.tsv" && echo open > "{h}/seen.txt"'], DEFAULTS["step_wall_s"], profile=NONE)
        nat = profile(f"{d}/native.sb", [f"{h}/w"], kind="native", reads=[f"{h}/seen.txt"])
        for what, cmd, want in (("node is not run", ["/opt/homebrew/bin/node", "-e", "console.log(2)"], None),
                                ("a program but Julia's is not run", ["/bin/cat", f"{h}/seen.txt"], None),
                                ("a file off its read allowlist is not read (R8-1)", ["julia", "--startup-file=no", "-e", f'print(read("{h}/hid/modules.tsv", String))'], None),
                                ("a file it may read is read", ["julia", "--startup-file=no", "-e", f'print(read("{h}/seen.txt", String))'], "open"),
                                ("Julia runs", ["julia", "--startup-file=no", "-e", "print(1 + 1)"], "2")):
            rc, o, e = run("measure", cmd, DEFAULTS["parse_wall_s"], profile=nat, env={"JULIA_LOAD_PATH": "@stdlib", "JULIA_DEPOT_PATH": f"{h}/w/depot:"})
            ok = rc == 0 and o.strip() == want if want else rc not in (0, None) and "secret" not in o and "2" != o.strip()
            out.append((f"the native profile: {what}", ok, f"rc={rc} " + (o + e).strip()[-100:]))
        stray = ["/bin/sh", "-c", "/usr/bin/perl -e 'use POSIX; setsid(); $SIG{TERM} = q(IGNORE); sleep 600' >/dev/null 2>&1 & "
                 "/opt/homebrew/bin/node -e \"require('child_process').spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], "
                 "{detached: true, stdio: 'ignore'}).unref()\"; sleep 1"]
        run("measure", stray, DEFAULTS["step_wall_s"], profile=NONE)
        left = pids("measure", agents=False)
        reap("measure")
        out.append(("reap: a setsid child ignoring TERM and a detached node child", bool(left) and not pids("measure", agents=False),
                    f"{len(left)} process(es) before, {len(pids('measure', agents=False))} after"))
        plant = ["/bin/sh", "-c", 'cd "$HOME/tmp" && rm -rf dp.fifo dp.sock dp.dir && mkfifo dp.fifo && mkdir dp.dir && '
                 "/usr/bin/perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => q(dp.sock), Listen => 1) or die $!'"]
        rc, o, e = run("measure", plant, DEFAULTS["step_wall_s"], profile=NONE)
        for what, name in (("a FIFO", "dp.fifo"), ("a socket", "dp.sock"), ("a directory", "dp.dir")):
            ok, ev = takes_at_once("measure", f"tmp/{name}", lambda: run("measure", ["/bin/sh", "-c", f'echo > "$HOME/tmp/{name}"'], 10, profile=NONE))
            out.append((f"take() of {what} a build user planted raises within a second", rc == 0 and ok, ev if rc == 0 else f"plant rc={rc} {e[-100:]}"))
        run("measure", ["/bin/rm", "-rf", f"{home('measure')}/tmp/dp.fifo", f"{home('measure')}/tmp/dp.sock", f"{home('measure')}/tmp/dp.dir"], DEFAULTS["step_wall_s"], profile=NONE)
        rc, o, e = run("measure", ["/bin/sh", "-c", STUCK], DEFAULTS["step_wall_s"], profile=NONE)   # R7-5: what its user can make unremovable
        try:
            clean("measure"); ok, ev = rc == 0, f"planted rc={rc}; the home after clean(): {list_home('measure', '')}"
        except DoorError as x:
            ok, ev = False, str(x)[-160:]
        prepare("measure")
        out.append(("clean() removes a home's entry its user made immutable, append-only, denied, unwritable and untraversable (R8-4)", ok, ev))
        rc, o, e = run("measure", ["/bin/sh", "-c", DEEP], DEFAULTS["step_wall_s"], profile=NONE)   # R9-2: no pass count it outlasts
        try:
            clean("measure"); ok, ev = rc == 0, f"planted rc={rc}; the home after clean(): {list_home('measure', '')}"
        except DoorError as x:
            ok, ev = False, str(x)[-160:]
        prepare("measure")
        out.append(("clean() removes a nest 64 deep of immutable directories of mode 000 in one use (R9-2)", ok, ev))
    with using("slot1"), proxy("", {"claude-haiku-5-5"}, lambda r: True, lambda u: None) as px:   # no token: nothing is spent
        ep = px["port"]
        d = give("slot1", "door-probe-agent")
        prof = profile(f"{d}/agent.sb", [home("slot1")], kind="agent", egress=ep)
        curl = lambda *a: ["/usr/bin/curl", "-s", "-m", "8", "-o", "/dev/null", "-w", "%{http_code}", *a]
        for what, cmd in bootstrap_tries(mark, label) + [
                ("a connect to 127.0.0.1:2828", curl("--noproxy", "*", "http://127.0.0.1:2828/")),
                ("a connect to 0.0.0.0:2828", curl("--noproxy", "*", "http://0.0.0.0:2828/")),
                ("a connect outside, direct", curl("--noproxy", "*", "https://1.1.1.1/")),
                ("a host but its model's, through its proxy", curl("-x", f"http://127.0.0.1:{ep}", "https://example.com/")),
                ("a write outside its home", ["/usr/bin/touch", f"{mark}-agentw"]),
                ("a nested allow-default sandbox", ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"])]:
            rc, o, e = run("slot1", cmd, DEFAULTS["step_wall_s"], profile=prof)
            out.append((f"the agent profile: {what}", held(what, rc, o) and not os.path.exists(f"{mark}-agentw"),
                        f"rc={rc} " + ("(pasteboard text)" if o and what == "the pasteboard" else (o + e).strip()[-100:])))
        bad = dale_untouched(mark, label, pid0, calc0)
        out.append(("the agent profile: Dale's launchd domain untouched", not bad, bad or "job alive, enabled, no environment, no job made"))
        rc, o, e = run("slot1", curl(f"http://127.0.0.1:{ep}/v1/models"), DEFAULTS["step_wall_s"], profile=prof)
        out.append(("the agent profile: its proxy answers a call off its list 403", rc == 0 and o.strip() == "403", f"rc={rc} {o.strip()}"))
        img = {"type": "image", "source": {"type": "url", "url": "https://example.com/x.png"}}
        for what, model, want, content in (("its proxy refuses a model not its run's", "claude-opus-5-5", "403", "1"),
                                           ("its proxy refuses an image sourced by url (R7-3)", "claude-haiku-5-5", "403", [img]),
                                           ("its proxy refuses one inside a tool_result", "claude-haiku-5-5", "403",
                                            [{"type": "tool_result", "tool_use_id": "t", "content": [img]}]),
                                           ("its proxy forwards its run's model (no token: the API's 401)", "claude-haiku-5-5", "401", "1")):
            rc, o, e = run("slot1", curl("-X", "POST", "-H", "content-type: application/json", "--data",
                                         json.dumps({"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": content}]}),
                                         f"http://127.0.0.1:{ep}/v1/messages"), DEFAULTS["step_wall_s"], profile=prof)
            out.append((f"the agent profile: {what}", rc == 0 and o.strip() == want, f"rc={rc} {o.strip()} {px['refused'][-1:]}"))
        rc, o, e = run("slot1", curl("-X", "POST", "-H", "content-type: application/json", "--data", json.dumps(
            {"model": "claude-haiku-5-5", "max_tokens": 1, "service_tier": "priority", "messages": [{"role": "user", "content": "1"}]}),
            f"http://127.0.0.1:{ep}/v1/messages"), DEFAULTS["step_wall_s"], profile=prof)
        out.append(("the agent profile: its proxy refuses a top-level key off its list, service_tier (R8-6)", rc == 0 and o.strip() == "403",
                    f"rc={rc} {o.strip()} {px['refused'][-1:]}"))
        for what, head, want in (("a negative Content-Length", "Content-Length: -1", b" 400 "),
                                 ("a chunked body", "Transfer-Encoding: chunked", b" 400 "),
                                 ("no Content-Length", "", b" 411 ")):
            ok, ev = refused_unread(ep, head, want)
            out.append((f"its proxy refuses {what} within a second, unread", ok, ev))
        rc, o, e = run("slot1", [claude_bin(state), "--version"], DEFAULTS["step_wall_s"], profile=prof)
        out.append(("the agent profile: the pinned claude runs", rc == 0 and "Claude Code" in o, (o + e).strip()[-120:]))
    for f in (f"{state}/door-probe", f"{gitdir}/door-probe", f"{mark}-ae", f"{mark}-launchd", f"{mark}-agentw"):
        with contextlib.suppress(FileNotFoundError):
            os.remove(f)
    return out

# ---------------------------------------------------------------- the landing's Julia (dev/ship.sh, a climb landing)
def _shared(files, origin):
    """The depots beneath a land job's own first one: the warm layer of `origin`'s own images for these files
    (land_layer) when it is made, the dependency images of their Manifest when they are made, then the mirror."""
    import hashlib
    dk = f"{TOP}/deps/" + hashlib.sha1(files.get("Manifest.toml", "").encode()).hexdigest()[:16]
    layer = f"{TOP}/landimg/" + _layer_key(origin, files)
    return ":".join([x for x in (layer, dk) if os.path.isdir(x)] + [f"{TOP}/julia"])

def _layer_key(origin, files):
    import hashlib
    return f"{origin[:16]}-" + hashlib.sha1(json.dumps(sorted(files.items())).encode()).hexdigest()[:16]

# the test set a landing's check runs and the score's costs that order its shards (the landing-check ruling, R1-R3, R6):
# the lander writes both, from origin's code and its own state, before ship.sh runs, and names them to ship.sh, whose
# door process (this file, as Dale) reads them here and gives them to the land job in its run directory, which the job's
# user reads and cannot write: no candidate's process writes either (dev/check.sh refuses a set its user can write)
SET_ENV, COSTS_ENV = "WT_SRC_SET_FILE", "WT_SRC_COSTS_FILE"

def landing(tree, check=True):
    """What a landing's job reads, given as _wtland's run directory: the commit at `tree`'s HEAD (the scratch
    dev/ship.sh rebased, its parent origin's head) in a repository with origin's history, the tree's Manifest and
    preferences, and, for a CHECK, the lander's test set and the score's costs (SET_ENV, COSTS_ENV: files of the lander's
    state named in this process's environment by ship.sh's caller), copied in as `src-set.txt` and `src-costs.tsv`; a
    check with no set named is refused, located (D9: never every file by default). A job that runs no test (`check`
    false: the packages regeneration of a rebased commit, which the lander runs before any set exists) is given neither
    file. Returns (run directory, the depots beneath its own: _shared() of its parent)."""
    common = git_("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=tree)
    sha = git_("rev-parse", "HEAD", cwd=tree)
    files = {n: open(os.path.join(tree, n)).read() for n in ("Manifest.toml", "LocalPreferences.toml") if os.path.isfile(os.path.join(tree, n))}
    sp, cp = os.environ.get(SET_ENV, ""), os.environ.get(COSTS_ENV, "")
    if check and (not sp or not os.path.isfile(sp)):
        raise DoorError(f"a landing's check runs the test set its lander chose, and {SET_ENV} names none ({sp!r})")
    given = {"src-set.txt": open(sp).read(), "src-costs.tsv": open(cp).read() if cp and os.path.isfile(cp) else ""} if check else {}
    d = give("land", f"land-{sha[:12]}", {**files, **given})
    repo(d, common, {"check": sha})
    return d, _shared(files, git_("rev-parse", "HEAD^", cwd=tree))

# what a check's unjudged builds and its load make of origin's own packages (dev/check.sh: the project's path packages,
# test/DartCorpus, dev/SkeletonImage), built into the layer's depot from origin's landed head alone
LAYER = ("julia --project=. --startup-file=no -e 'using Pkg; Pkg.precompile()' && "
         "julia --project=. --startup-file=no test/DartCorpus/load.jl && "
         "julia --project=. --startup-file=no -e 'push!(LOAD_PATH, joinpath(pwd(), \"dev\", \"SkeletonImage\")); using SkeletonImage'")

def land_layer(common, origin, files, log):
    """The warm layer beneath every land job's fresh first depot (A8-1): the compiled images of origin's own packages
    at its landed head `origin`, for `files` (its Manifest and preferences), made once per origin head and files by the
    landing user in its clone ($HOME/c, the path every check's clone has: Julia accepts a path package's image only for
    the package found at the path it was built from) on a fresh depot over the dependency images, then copied by Dale's
    uid (copy_home) under TOP/landimg, which no build user writes. No candidate's code shapes it, so no check of one
    candidate shapes another's. Made by the lander right after a landing, of the head it made, under its verify lock
    and at background QoS (D31), so the next check finds it (and built before a check only when no landing made it);
    every layer but this one and the one before it is removed. Returns (its path, whether it was built now)."""
    key = _layer_key(origin, files)
    dst = f"{TOP}/landimg/{key}"
    if os.path.isdir(dst):
        return dst, False
    os.makedirs(f"{TOP}/landimg", exist_ok=True)
    with using("land"), open(log, "w") as logf:
        d = give("land", f"layer-{key}", files)
        repo(d, common, {"check": origin})
        h = home("land")
        p = popen("land", ["/bin/sh", "-c", 'git clone -q -b check "$1/repo.git" "$HOME/c" && for f in Manifest.toml LocalPreferences.toml; do '
                           '[ ! -f "$1/$f" ] || cp "$1/$f" "$HOME/c/"; done && cd "$HOME/c" && . dev/depot.sh && wt_depot_export "$HOME/layer" && ' + LAYER,
                           "sh", d], profile=profile(f"{d}/check.sb", [h], kind="check"), stdout=logf, stderr=subprocess.STDOUT,
                  env=dict(WT_SHARED_DEPOT=_shared(files, "none"), JULIA_NUM_THREADS="1"))
        try:
            wait("land", p, DEFAULTS["pkg_wall_s"])
        except subprocess.TimeoutExpired:
            reap("land"); p.wait()
            raise DoorError(f"the landing layer of {origin[:10]} passed pkg_wall_s ({log})")
        if p.returncode != 0:
            raise DoorError(f"the landing layer of {origin[:10]} failed (exit {p.returncode}, {log})")
        copy_home("land", "layer/.wtd/depot", dst)
    for old in sorted(glob.glob(f"{TOP}/landimg/*"), key=os.path.getmtime)[:-2]:   # this one and the one before it kept
        shutil.rmtree(old, ignore_errors=True)
    return dst, True

DOOR_FAILED = 75   # land-check's exit when the door itself failed (EX_TEMPFAIL): no verdict of the job's

# dev/regen_packages.sh's Julia, as the lander's rebased measurement runs it (measure.rebased): src/julia/packages.jl's
# generated blocks of the commit's tree
REGEN = ('. dev/depot.sh && wt_depot_export "$WT_DEPOT_DIR" && exec julia --project=. --startup-file=no -e \'include(joinpath(pwd(), "dev", "skeleton.jl")); '
         'S = Skeleton; normpath(S.ROOT) == normpath(pwd() * "/") || error("dev/skeleton.jl reads $(S.ROOT), not this '
         'tree"); t = S.packages_text(); t == read(S.PACKAGES, String) || write(S.PACKAGES, t)\'')

def land_job(tree, script, log, out_files=(), wall=DEFAULTS["ship_kill_s"], background=False, check=True):
    """`script` (sh, its $1 the run directory) in _wtland's own clone of the landing's commit ($HOME/c), at default
    QoS in the `check` profile (it writes its home alone: its clone, its depot and its caches, so nothing it writes is
    read by another check or by Dale's processes, R5-2); its output to `tree`/.wtd/`log`, never into dev/ship.sh's
    (a line the job prints is the candidate's to write, R6-2); `out_files` of its clone copied back into `tree` after it
    is reaped. Its first depot is a new one ($HOME/.wtd/depot: KEEPS gives the landing nothing, so using() removed the
    last), over the warm layer of origin's own images (land_layer) and the dependency images: no earlier check's
    candidate code shapes a check or what a landing returns into its pushed content (A6-4, A8-1). Returns its exit
    status: the job's own, 124 past its wall, 128 + n killed by signal n."""
    os.makedirs(os.path.join(tree, ".wtd"), exist_ok=True)
    with using("land"), open(os.path.join(tree, ".wtd", log), "w") as logf:
        pins(tree)   # the checkouts this landing's check reads, as dev/ship.sh fetched them: the one mirror a landing refreshes
        d, shared = landing(tree, check)   # `check` false: a job that runs no test and is given no set (the regeneration)
        jdk = subprocess.run(["/usr/libexec/java_home"], capture_output=True, text=True).stdout.strip()
        h = home("land")
        p = popen("land", ["/bin/sh", "-c", 'rm -rf "$HOME/c" && mkdir -p "$WT_DEPOT_DIR" && git clone -q -b check "$1/repo.git" "$HOME/c" && '
                           'for f in Manifest.toml LocalPreferences.toml; do [ ! -f "$1/$f" ] || cp "$1/$f" "$HOME/c/"; done && '
                           'cd "$HOME/c" && ' + script,
                           "sh", d], profile=profile(f"{d}/check.sb", [h], kind="check"), background=background,
                  stdout=logf, stderr=subprocess.STDOUT,
                  env=dict(PATH=f"{jdk}/bin:{PATH}" if jdk else PATH, WT_DEPOT_DIR=h, WT_SHARED_DEPOT=shared, WT_PINS_READY="1",
                           CHECK_LANDING="1", CHECK_BASE="HEAD~1", WT_SRC_SET=f"{d}/src-set.txt", WT_SRC_COSTS=f"{d}/src-costs.tsv"))
        t0, walled = CLOCK(), False
        try:   # its wall in the role's awake time, the disk and the power at every tick (tick(): R7-6, O8-3, A8-8)
            while p.poll() is None:
                time.sleep(DEFAULTS["poll_s"]["land_job"])
                tick("land", t0, wall, battery_ends=True)   # a check run by ship.sh's door process asks no power: its hook
        except Tick as e:                                   # is the lander's, which ends the check itself by the power rule
            p.wait(); walled = True
            if e.why != "wall":
                logf.write(f"\ndoor: {e}\n")
                raise
        rc = None if walled else p.returncode
        reap("land"); p.wait()
        for rel in out_files:
            rc = copy_back(tree, rel, logf, rc)
    return 124 if rc is None else 128 - rc if rc < 0 else rc

def copy_back(tree, rel, logf, rc):
    """A land job's output `rel` of its clone ($HOME/c) copied into `tree` (`.wtd/*.out`: the check's outputs, at most
    land_outs' files and bytes, A7-6/R7-6: a check that writes outputs without end fills Dale's disk through this copy;
    past the total the rest is not copied, logged), each through take(); an output that is no regular file, or one past
    its cap, is the job's own fault (rc 1). Returns rc."""
    files, each, total = (DEFAULTS["land_outs"][k] for k in ("files", "file_bytes", "total_bytes"))
    names = sorted(x for x in list_home("land", "c/.wtd") if x.endswith(".out")) if rel == ".wtd/*.out" else [os.path.basename(rel)]
    if len(names) > files:
        logf.write(f"\ndoor: {len(names)} outputs, past land_outs' {files}: the first {files} copied\n"); names = names[:files]
    for n in names:
        src = f"c/.wtd/{n}" if rel == ".wtd/*.out" else f"c/{rel}"
        if rel == ".wtd/*.out" and total <= 0:
            logf.write(f"\ndoor: the outputs passed land_outs' {DEFAULTS['land_outs']['total_bytes']} bytes: {n} and after not copied\n")
            break
        try:
            data = take("land", src, min(each, total) if rel == ".wtd/*.out" else DEFAULTS["file_cap_bytes"])
        except DoorError as e:   # an output that is no regular file or past its cap: the job's own fault, never a block
            logf.write(f"\ndoor: {e}\n"); rc = 1 if rc == 0 else rc; continue
        if data is None:
            continue
        if rel == ".wtd/*.out":
            total -= len(data)
        dst = os.path.join(tree, os.path.dirname(rel), n)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            os.remove(dst)
        with open(dst, "wb") as f:
            f.write(data)
    return rc

if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["tools", "--fetch-node"]:   # a launch step Dale runs once a node version (spec v17 Y1)
        print(fetch_node(TOP))
    elif a[:1] == ["tools"]:   # at launch alone: refused while any role is in use, the real climb's or a probe's (A8-6),
        with hold_roles() as busy:   # and every role held until it returns, so none is taken meanwhile (A9-5)
            if busy:
                print(f"tools: refused while the roles {', '.join(busy)} are in use (TOP/locks)", file=sys.stderr); sys.exit(1)
            seal_home()
            print(tools(manifest_julia(open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "Manifest.toml")).read())))
    elif a[:1] == ["pin-claude"] and len(a) == 2:   # launch's choice of the agents' claude, recorded in state a[1]
        print(pin_claude(a[1]))
    elif a[:1] == ["reap"]:   # every build user's every process (launch.sh stop)
        for r in ROLES:
            reap(r)
    elif a[:1] == ["probe"] and len(a) == 3:
        seal_home()
        res = probe(a[1], a[2])
        for what, ok, ev in res:
            print(("held  " if ok else "FAILED") + f"  {what}: {ev}")
        sys.exit(0 if all(ok for _, ok, _ in res) else 1)
    elif a[:1] == ["land-check"] and len(a) == 2:
        try:   # its exit status is the job's (dev/check.sh's is its verdict), or DOOR_FAILED: never a door fault as a red
            # its outputs back in .wtd, each shard's per-file records among them (src_records.<k>.out), which the lander
            # reads when the check is red on its test files alone (R3)
            rc = land_job(a[1], "bash dev/check.sh", "check.log", [".wtd/*.out"])
        except Exception as e:
            print(f"door: {a[0]} failed in the door itself: {type(e).__name__}: {e}", file=sys.stderr); rc = DOOR_FAILED
        sys.exit(rc)
    else:
        print(__doc__, file=sys.stderr); sys.exit(2)
