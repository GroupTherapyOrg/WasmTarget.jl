"""dev/climb/slots.py — a slot's move: its own Kaimon and session, the climber, the gates, the review and the queue,
all as the slot's build users; and the agent probe, an agent run that shows what only a model can."""
from core import *   # noqa: F403
from measure import *   # noqa: F403
from lander import *   # noqa: F403

# ---------------------------------------------------------------- Kaimon: the slot's own server and session (D39)
def mcp(k, calls, timeout=None):
    """Kaimon's MCP over HTTP (JSON-RPC, streamable HTTP) at a slot's Kaimon `k` (its url, key and role, kaimon_up):
    initialize, then each (tool, arguments); the texts. Each call waits kaimon_http_s (or `timeout`) of the slot role's
    awake time (door.awake_call: a landing's stop of the role is never a timeout of its Kaimon, ruling 11); the
    socket's own timeout, a backstop past any stop (ship_kill_s), ends a call left behind."""
    url, key, role = k
    sid, out, timeout = None, [], timeout or cfg()["kaimon_http_s"]
    def post(body, t):
        nonlocal sid
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **({"Authorization": f"Bearer {key}"} if key else {})}
        if sid:
            h["Mcp-Session-Id"] = sid
        def call():
            r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), h), timeout=t + cfg()["ship_kill_s"])
            return r.headers.get("Mcp-Session-Id"), r.read().decode()
        got, txt = door.awake_call(role, call, t)
        sid = got or sid
        msgs = [json.loads(l[5:]) for l in txt.splitlines() if l.startswith("data:")] or \
               ([json.loads(txt)] if txt.strip().startswith("{") else [])
        return next((m for m in msgs if m.get("id") == body.get("id")), {})
    try:
        post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
              "capabilities": {}, "clientInfo": {"name": "climb-driver", "version": "3"}}}, timeout)
        post({"jsonrpc": "2.0", "method": "notifications/initialized"}, timeout)
        for i, (tool, args) in enumerate(calls, 1):
            m = post({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": tool, "arguments": args}}, timeout)
            out.append("\n".join(c.get("text", "") for c in (m.get("result") or {}).get("content", [])) or json.dumps(m.get("error")))
    except (OSError, ValueError) as e:   # Kaimon down or answering garbage: the driver's failure, never the move's
        raise ClimbError(f"Kaimon at {url}: {type(e).__name__}: {e}")
    return out

def kaimon_eval(k, ses, code, wall):
    """One evaluation in session `ses` of Kaimon `k` (url, key), waited for: Kaimon promotes one past ~30 s to a job
    polled with check_eval."""
    t = mcp(k, [("ex", {"e": code, "ses": ses, "q": False})])[0]
    job = re.search(r"Job ID: (\w+)", t)
    t0 = door.CLOCK()
    while job and door.awake(k[2], t0) < wall:   # its answer: "<id> on <key>\ncompleted, 40.1s\n<value>" (probed 2026-11-09)
        time.sleep(cfg()["kaimon_poll_s"]); beat()
        t = mcp(k, [("check_eval", {"eval_id": job.group(1)})])[0]
        status = (t.split("\n") + [""])[1]
        if re.match(r"(completed|failed|error|cancel)", status):
            return t.split("\n", 2)[-1] if status.startswith("completed") else "ERROR: " + t
    return f"ERROR: not done after {wall} s" if job else t

def kaimon_url(name):
    """Slot `name`'s (climb-<k>) own Kaimon's URL, at its slot role's port (core.kaimon_port)."""
    return f"http://127.0.0.1:{kaimon_port(users(name)[0])}/mcp"

def kaimon_up(user, name, clone, depot, base):
    """The slot's own Kaimon (R5-3 and the deserialize finding: no session of the climb's ever reaches Dale's Kaimon,
    and Dale's projects.json is never written): `kaimon --headless` as the slot's user on its own port, its config and
    cache in that user's home, in the `kaimon` profile (TCP on its own port alone, unix sockets in its home; its
    sessions run in it too), its one project the slot's clone, whose sessions take the clone's depot over `depot`;
    strict, with an API key made for the move (the climber's lives in an MCP config file in its own home, never an
    argv). Started with the move and reaped with it. Returns (its URL, its key, the slot's role) once it answers
    within kaimon_start_s of the role's awake time."""
    import secrets
    h, url, key, port = door.home(user), kaimon_url(name), "kaimon_" + secrets.token_hex(20), kaimon_port(user)
    d = door.give(user, f"kaimon-{name}", {"julia-session": f"#!/bin/sh\nJULIA_DEPOT_PATH=\"{clone}/.wtd/depot:{depot}:{kaimon_images(base)}:{door.TOP}/julia:\" "
                                                             f"exec {door.TOP}/tools/bin/julia \"$@\"\n"})
    os.chmod(f"{d}/julia-session", 0o755)
    door.put(user, "kaimon/config/config.json", json.dumps({"mode": "strict", "api_keys": [key], "allowed_ips": ["127.0.0.1", "::1"], "port": port}))
    door.put(user, "mcp.json", json.dumps({"mcpServers": {"kaimon": {"type": "http", "url": url, "headers": {"Authorization": f"Bearer {key}"}}}}))
    door.put(user, "kaimon/config/projects.json", json.dumps({"projects": [{"project_path": clone, "enabled": True, "launch_config": {
        "threads": "4", "startup_file": False, "instantiate": "never", "julia_bin": f"{d}/julia-session"}}]}, indent=2))
    log = open(os.path.join(STATE, "logs", f"kaimon-{name}.log"), "a")
    door.popen(user, [f"{door.TOP}/tools/bin/julia", "--startup-file=no", "--threads=auto,2", "--gcthreads=1", "-m", "Kaimon",
                      "--headless", "--port", str(port)], stdout=log, stderr=subprocess.STDOUT,
               profile=door.profile(f"{d}/kaimon.sb", [h], kind="kaimon", binds=[f"{h}/kaimon"], port=port),
               env={"KAIMON_CONFIG_DIR": f"{h}/kaimon/config", "KAIMON_CACHE_DIR": f"{h}/kaimon/cache",
                    "JULIA_DEPOT_PATH": f"{h}/kdepot:{kaimon_images(base)}:{door.TOP}/julia:",
                    "JULIA_LOAD_PATH": f"{door.TOP}/julia/environments/apps/Kaimon:@stdlib"})
    t0 = door.CLOCK()
    while door.awake(user, t0) < cfg()["kaimon_start_s"]:
        with contextlib.suppress(ClimbError):
            mcp((url, key, user), [], timeout=cfg()["kaimon_ping_s"]); return url, key, user
        time.sleep(cfg()["poll_s"]["kaimon_up"])
    raise ClimbError(f"{name}'s Kaimon did not answer within {cfg()['kaimon_start_s']} s (logs/kaimon-{name}.log)")

def session(k, clone, name):
    """The slot's Kaimon session (D39), started by the driver, loaded (`using WasmTarget`) before the climber starts."""
    t0 = door.CLOCK()
    t = mcp(k, [("start_session", {"project_path": clone, "private": True, "name": name})])[0]
    m = re.search(r"Session key: (\w+)", t)
    if not m:
        raise ClimbError(f"Kaimon started no session for {name}: {t[:300]}")
    r = kaimon_eval(k, m.group(1), "using WasmTarget; 1 + 1", cfg()["session_warm_s"])
    if r.strip().splitlines()[-1:] != ["2"]:
        raise ClimbError(f"{name}'s session did not load WasmTarget: {r[-300:]}")
    event("session", slot=name, key=m.group(1), secs=round(door.CLOCK() - t0))
    return m.group(1)

def infra_down(k, ses, depot):
    """What of the driver's own infrastructure a climber depends on is down, or None (O5-5): the slot's Kaimon, its
    session `ses` itself (asked `1 + 1` by its key, R6-10: never "any process of its user", which launchd's agents
    answer), the dependency images."""
    try:
        mcp(k, [])
    except ClimbError as e:
        return f"Kaimon down ({e})"
    try:
        r = kaimon_eval(k, ses, "1 + 1", cfg()["kaimon_http_s"])
    except ClimbError as e:
        r = str(e)
    if r.strip().splitlines()[-1:] != ["2"]:
        return f"the slot's session {ses} does not answer ({r.strip()[-160:]})"
    if not os.path.isdir(depot):
        return "the dependency images missing"
    return None

def claim(h, slot):
    p = os.path.join(STATE, "claims", h["id"])
    try:
        fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    os.write(fd, json.dumps({"slot": slot, "pid": os.getpid(), "boot": door.BOOT, "t": stamp(), "key": h["key"]}).encode()); os.close(fd)
    return True

def unclaim(h):
    with contextlib.suppress(FileNotFoundError):
        os.remove(os.path.join(STATE, "claims", h["id"]))

def reap_claims():
    """A claim whose process is gone frees its hold (a stopped or crashed driver leaves no hold unclimbable)."""
    for p in glob.glob(os.path.join(STATE, "claims", "*")):
        try:
            c = json.load(open(p)); pid, boot = c.get("pid"), c.get("boot")
        except (OSError, ValueError):
            pid = boot = None
        if not alive(pid, boot):
            with contextlib.suppress(FileNotFoundError):
                os.remove(p)
            event("reaped", claim=os.path.basename(p))

def park(h, why, tell=True):
    update_json("parked.json", {}, lambda p: p.__setitem__(h["id"], {"key": h["key"], "why": why, "t": stamp(), "cases": members(h)}))
    event("parked", hold=h["key"], why=why[:300])
    if tell:
        for_dale("parked: " + h["key"][:100], why[:1500] + "\nDefault taken: the hold waits; the climb goes on with the "
                 "others, and a score or landing that changes its cases unparks it.")

def fable_left():
    day = stamp(now().replace(hour=0, minute=0, second=0, microsecond=0))
    return cfg()["fable_per_day"] - sum(1 for e in events() if e["kind"] == "fable" and e["t"] >= day)

def rule(h, escalation, ruser):
    """Opus rules first (D48); only a ruling that names itself beyond Opus goes to Fable, at most fable_per_day. An
    empty ruling is infrastructure: the hold is not parked. The ruler reads a clone of origin of its own, as the
    slot's review user."""
    c = cfg()
    prior = "\n".join(f"- {x['ruling']}" for x in state_json("rulings.json", {}).get(h["id"], [])) or "(none)"
    with door.using(ruser):
        tree = agent_tree(ruser, f"ruling-{h['id']}", "wt2", git("rev-parse", f"origin/{MARCH}"))
        prompt = render("ruling.md", WORKTREE=tree, ESCALATION=escalation, RULINGS=prior)
        so = ask("ruling", h["id"], c["ruler_model"], "high", SCHEMA_RULING, REVIEW_TOOLS, prompt, tree, ruser)
        if isinstance(so, dict) and so.get("escalate"):
            if fable_left() <= 0:
                park(h, "Opus asked for Fable's ruling and today's Fable rulings are spent: " + so["ruling"][:1000]); return
            event("fable", hold=h["key"])
            so2 = ask("ruling-fable", h["id"], c["fable_model"], "high", SCHEMA_RULING, REVIEW_TOOLS,
                      prompt + "\n\nOpus's ruling, which asked for yours:\n" + so["ruling"], tree, ruser)
            so = so2 if isinstance(so2, dict) else so
    if not isinstance(so, dict):
        event("infra", hold=h["key"], note="the ruling run gave no answer twice" if so is None else "the budget refused the ruling")
        return
    update_json("rulings.json", {}, lambda r: r.setdefault(h["id"], []).append({"ruling": so["ruling"], "t": stamp()}))
    if so.get("for_dale") or so.get("ledger_row"):
        for_dale(h["key"][:100], so.get("for_dale", "") + (f"\nproposed ledger row: {so['ledger_row']}" if so.get("ledger_row") else ""))
    event("ruled", hold=h["key"], requeue=so["requeue"], ruling=so["ruling"][:300])
    if not so["requeue"]:
        park(h, so["ruling"], tell=False)

def since_park(h, kind):
    """The events of `kind` on hold h since it was last parked, reset when a hold comes back from a park (24)."""
    ev = events()
    t = max((e["t"] for e in ev if e["kind"] == "parked" and e.get("hold") == h["key"]), default="")
    return sum(1 for e in ev if e["kind"] == kind and e.get("hold") == h["key"] and e["t"] > t)

def finish(h, outcome, slot_name, note, driver=False):
    """A move that did not land. The driver's own failures (infra) and the governor's (budget) are no stop: the slot
    backs off, the hold stays. A stop keeps its handoff and counts toward a park. Only a climber's own `blocked:*` is
    ruled at once; a driver's refusal or a review that did not approve is `refused`, ruled only when the hold reaches
    its park (A7), where the ruling is written beside the park for the next climber after it. `driver`: an infra
    outcome the driver's own code raised (slot_once's driver-error), whose backoff is a driver fault's (core.back_off:
    driver_fault_backoff_s first, ended when the driver's code changes), as the loops' own are (core.guarded)."""
    unclaim(h)
    if outcome in ("infra", "budget"):
        event("infra" if outcome == "infra" else "budget-stop", hold=h["key"], slot=slot_name, note=note[:600])
        if outcome == "infra":
            back_off("slot", slot_name, why=note, **(dict(driver=driver_tree(), first=cfg()["driver_fault_backoff_s"]) if driver else {}))
        return outcome
    event("stopped", hold=h["key"], hold_id=h["id"], outcome=outcome, note=note[:600])
    update_json("handoffs.json", {}, lambda hs: hs.__setitem__(h["id"], note[-2500:]))
    stops = since_park(h, "stopped")
    # a hold that unlocks more earns more tries before it waits for Dale (park_steps)
    if stops >= cfg()["stops_per_hold"] + sum(h.get("n", 0) >= k for k in cfg()["park_steps"]):
        rule(h, f"outcome: {outcome} (its {stops}th stop since its last park)\n\n{note}", users(slot_name)[1])
        if h["id"] not in state_json("parked.json", {}):
            park(h, f"{stops} moves stopped without landing; the last: {outcome}: {note[:1200]}")
    elif outcome.startswith("blocked:"):
        rule(h, f"outcome: {outcome}\n\n{note}", users(slot_name)[1])
    return outcome

def already_advanced(h, base, rows):
    """The hold is gone at origin: none of its cases stops at its key in the base measurement, which measured every
    one of them (8). Its rows are advanced (kept under the base's hash until a score holds it) and the hold skipped,
    never a stop."""
    if h.get("fixfirst") and not h.get("require_pass"):   # a finding is gone only when a move resolves it
        return False
    rows = {l: r for l, r in rows.items() if l in h["cases"]}
    live = [l for l, r in rows.items() if (r[1] != "passed" if h.get("fixfirst") else hold_key(r[1], l, r[3]) == h["key"])]
    if live or not rows:
        return False
    advance(list(rows.values()), base, f"{h['key'][:80]} is gone at origin")
    if h.get("fixfirst"):   # a G2 loss whose cases all pass again at origin
        update_json("fixfirst.json", [], lambda ff: ff.__setitem__(slice(None), [f for f in ff if f["key"] != h["key"]]))
    event("already-advanced", hold=h["key"], cases=len(rows))
    unclaim(h)
    return True

def users(slot_name):
    """A slot's two build users' roles: its climber's (with its Kaimon) and its reviewer's (and ruler's)."""
    k = slot_name.rsplit("-", 1)[1]
    return f"slot{k}", f"review{k}"

def move(h, slot_name):
    """One climber, one hold, as the slot's build user: the base measured (the hold skipped when it is gone) → a clone
    of its own and its own Kaimon → climb → its one commit back as a bundle → G5 → the driver's measurement as the
    measure user → review as the slot's review user → queued for the lander. Every process of the slot's user is
    reaped when the move ends."""
    user, _ = users(slot_name)
    update_json("slots.json", {}, lambda s_: s_.__setitem__(slot_name, h["id"]))
    task = f"{h['id']}-{int(time.time())}"
    labels = labels_for(h)   # once: the same labels at the base and on the move
    base = base_choice(labels)   # an older head whose base holds every label, measured by this driver (T4), or origin's
    env = environment(base)
    dk = deps(base, env["Manifest.toml"])
    hb = sorted(h["cases"])
    with door.using(user):
        clone = agent_tree(user, slot_name, slot_name, base, dict(env, **{".git/hooks/commit-msg": open(os.path.join(ROOT, "dev", "hooks", "commit-msg")).read(),
                                                                         ".wtd/hold-cases.txt": "".join(f"{l}\n" for l in hb)}))
        warm = {}   # the slot's Kaimon starts and its session warms beside the base measurement
        def warmup():
            try:
                warm["k"] = kaimon_up(user, slot_name, clone, dk, base)
                warm["key"] = session(warm["k"], clone, slot_name)
            except Exception as e:
                warm["error"] = e
        th = threading.Thread(target=warmup, daemon=True)
        th.start()
        try:   # a power cut waits until work may run and measures the base again, the slot's use kept (on_ac, O9-1)
            before = on_ac(f"base {base[:10]}", measure_base, base, labels, wait=True)
        except ClimbError as e:   # origin's own tree failed: the driver's, one note, never the hold's (O5, O14)
            alarm("base-failed", "a base measurement of origin failed", f"origin {base[:10]}: {str(e)[:1200]}\nDefault taken: "
                  "the slot backs off as for any failure of the driver's (infra); no hold is charged.")
            raise
        finally:
            th.join()
        if already_advanced(h, base, before):
            return "already-advanced"
        if "error" in warm:
            return finish(h, "infra", slot_name, f"the slot's Kaimon: {warm['error']}")
        return climb(h, slot_name, clone, base, task, labels, before, warm, dk)

def remeasure(fn, hold, slot_name):
    """A move's gate (fn: the bundle, G5 and the driver's measurement of the climber's one commit) run again on the same
    commit after a fault of the driver's measurement (MeasureCut and RoleLost, the door's DoorError, an OSError of its
    files): the climber's work is on its branch, so the slot measures it again rather than climb the hold again from
    nothing (2026-11-14 16:43:46Z: a run directory removed from outside, a FileNotFoundError, and climb-1's 53-minute move
    started over). The same fault twice in a row is the driver's own (a bug: no measurement of this commit will pass it)
    and goes on to the caller, as does any fault past task_wall_s from the first: the move then ends as infrastructure,
    its hold kept (slot_once). A failure of the move's own is no fault: fn returns it (its problems)."""
    seen, t0 = [], None
    while True:
        try:
            return fn()
        except (MeasureCut, door.DoorError, OSError) as e:
            why = f"{type(e).__name__}: {e}"
            t0 = door.CLOCK() if t0 is None else t0
            if (seen and seen[-1] == why) or door.CLOCK() - t0 > cfg()["task_wall_s"]:
                raise
            seen.append(why)
            event("remeasure", hold=hold, slot=slot_name, why=why[:300])

def climber_cap(resume, counted):
    """A climber run's dollar cap (claude's --max-budget-usd): a counted resume (resumes_per_move: the driver's own asks)
    resume_cap_usd; the first run and a resume past a landing's window (through_pauses, uncounted) the move's own
    (task_cap_usd, claude_cmd's default)."""
    return cfg()["resume_cap_usd"] if resume and counted else None

def pause_text(spans, clock=None, wall=None):
    """What a climber is told its processes were stopped for: each span (door.CLOCK) as UTC times and seconds."""
    clock, wall = door.CLOCK() if clock is None else clock, time.time() if wall is None else wall
    at = lambda x: datetime.datetime.fromtimestamp(wall - (clock - x), datetime.timezone.utc).strftime("%H:%M:%SZ")
    total = round(sum(b - a for a, b in spans))
    return (f"Your processes (your Kaimon session and its jobs, every Bash command, julia and dev/lanetest.sh you ran) were "
            f"stopped for a landing's check from " + ", and from ".join(f"{at(a)} to {at(b)} ({round(b - a)} s)" for a, b in spans) +
            f": {total} s in all. A timeout, a hard limit passed or a job that seemed hung in that time was that stop, not "
            "your code: nothing is broken. Re-run what it cut (a run past its limit; a Kaimon job still running is still "
            "running: collect it with check_eval) and continue the move.")

def through_pauses(so, last, again, hold, slot_name):
    """A climber's run that a landing's window stopped (last(): its spans, door.paused_spans) and that ended without a
    commit resumed with exactly what happened (pause_text) by again(text): uncounted (no resume of resumes_per_move) and
    at the move's cap (climber_cap). On 2026-11-14 two runs of climb-1 gave up after a landing's window stopped their
    processes: a dev/lanetest.sh past its 900-s wall-clock limit (16:57-17:37Z), a Kaimon job read as hung at 6m52s
    (17:49-17:58Z); the driver's walls count awake time (door.awake), the climber's tools cannot. Once per run stopped:
    a run no window stopped ends it, so the resumes are bounded by the landings during the move. It resumes any outcome
    but a commit, a stop of the climber's own for a reason the window did not cause (a ruling it needs) among them: at
    worst one resume that repeats that stop."""
    while isinstance(so, dict) and so.get("outcome") != "committed":
        spans = last()
        if not spans:
            return so
        event("climber-paused", hold=hold, slot=slot_name, outcome=so.get("outcome"), spans=len(spans),
              secs=round(sum(b - a for a, b in spans)))
        so = again(pause_text(spans))
    return so

def move_gate(gated, h, slot_name):
    """A move's gate as climb() runs it: a power cut waits until work may run and runs it again (on_ac), and a fault of
    the driver's measurement measures the same commit again (remeasure); the climber's work and the slot's use kept."""
    return lambda: remeasure(lambda: on_ac(f"move {h['key'][:80]}", gated, wait=True), h["key"], slot_name)

def bundle(user, clone, base, slot_name, task):
    """The climber's commits on `base`, back as a git bundle its user writes (in the `check` profile) and the driver
    takes (door.take) and fetches into the main repository (git parses the pack, fsck on): exactly one commit on
    `base`, or why not. Uncommitted work is not kept."""
    h = door.home(user)
    d = door.give(user, f"bundle-{task}")
    rc, o, e = door.run(user, ["/bin/sh", "-c", 'mkdir -p "$HOME/out" && rm -f "$HOME/out/c.bundle" && git bundle create -q "$HOME/out/c.bundle" HEAD "^$1"',
                               "sh", base], cfg()["tree_wall_s"], cwd=clone, profile=door.profile(f"{d}/bundle.sb", [h], kind="check"))
    try:
        data = door.take(user, "out/c.bundle", cfg()["bundle_cap_bytes"]) if rc == 0 else None
    except door.DoorError as e:   # no regular file where its bundle goes: the move's own, never a wait (R6-1)
        return None, f"its bundle: {e}"
    if data is None:
        return None, f"no commit on its base ({(o + e).strip()[-200:]})"
    p = os.path.join(STATE, "verify", f"{task}.bundle")
    with open(p, "wb") as f:
        f.write(data)
    common_write(f"the bundle's ref refs/climb/{slot_name}")   # spec v18 P5
    r = sh(["git", "-c", "core.hooksPath=/dev/null", "-c", "fetch.fsckObjects=true", "fetch", "-q", p, f"+HEAD:refs/climb/{slot_name}"], cwd=REPO)
    os.remove(p)
    if r.returncode:
        return None, f"its bundle does not fetch: {r.stderr.strip()[-200:]}"
    sha = git("rev-parse", f"refs/climb/{slot_name}")
    n = int(git("rev-list", "--count", f"{base}..{sha}"))
    if n != 1 or git("rev-parse", f"{sha}^") != base:
        return None, f"one commit on its base expected; found {n} commit(s)"
    return sha, None

def climb(h, slot_name, clone, base, task, labels, before, warm, dk):
    """A move's agent work and its gates, while the slot's Kaimon and session live: the climber, the driver's
    measurement, the review, the queue. Between the climber's runs every process of its user is stopped (SIGSTOP),
    so nothing writes while its commit is read and measured (red 3)."""
    c = cfg()
    user, ruser = users(slot_name)
    hb = [before[l] for l in sorted(h["cases"]) if l in before]
    caselines = "\n".join(f"- {r[0]} — {r[1]} — {r[3][:160]}" for r in hb[:40]) or "- (no case reaches it yet: write one that does, D12)"
    if len(hb) > 40:
        caselines += f"\n- … and {len(hb) - 40} more (all in .wtd/hold-cases.txt)"
    hand = state_json("handoffs.json", {}).get(h["id"])
    rl = state_json("rulings.json", {}).get(h["id"], [])
    brief = render("climber.md", WORKTREE=clone, BRANCH=slot_name, BASE=base[:10], SESSION=warm["key"],
                   HOLD=f"**{h['key']}**\n\nWhy (the first case's rejection): {h['why']}" + (
                       "\n\nThe hold's distinct rejections (one gap, its instances; port the gap, not one instance):\n" +
                       "\n".join(f"- {n} × {r}" for r, n in h["instances"].most_common(15)) if len(h.get("instances", {})) > 1 else ""),
                   CASES=caselines, HANDOFF=f"## The last climber's handoff\n\n{hand}" if hand else "",
                   RULINGS="## Rulings on this hold (bound by these)\n\n" + "\n".join(f"- {x['ruling']}" for x in rl) if rl else "")
    write_atomic(os.path.join(STATE, "briefs", f"{task}.md"), brief)
    event("climb", hold=h["key"], slot=slot_name, task=task)
    sid = str(uuid.uuid4())
    pauses = []   # the spans a landing's window stopped the climber's last run (door.paused_spans)
    def climber(prompt, resume, counted=True):
        door.signal_role(user, "CONT")
        t0c = door.CLOCK()
        try:
            return ask("climb", task, c["climber_model"], c["climber_effort"], SCHEMA_CLIMB, CLIMBER_TOOLS, prompt, clone, user, sid=sid,
                       resume=resume, cap=climber_cap(resume, counted), mcp=f"{door.home(user)}/mcp.json",
                       depot=f"{clone}/.wtd/depot:{dk}:{door.TOP}/julia:",
                       again="Your run ended without a report. Finish the move or stop, and reply with only the JSON the schema asks for.")
        finally:
            door.signal_role(user, "STOP")
            pauses[:] = door.paused_spans(user, t0c)
    def climbed(prompt, resume):   # a run, and its resumes past each landing's window that stopped it (through_pauses)
        return through_pauses(climber(prompt, resume), lambda: list(pauses),
                              lambda text: climber(text + "\nThen reply with the same JSON as before.", True, counted=False),
                              h["key"], slot_name)
    so = climbed(brief, False)
    if so == BUDGET:
        return finish(h, "budget", slot_name, "the governor refused the climber's run")
    if so is None:
        return finish(h, "infra", slot_name, "the climber gave no answer twice (a timeout, a crash or its cap)")
    if so["outcome"] != "committed":
        # the driver labels the stop (22): a climber's "infra" is the driver's own when the driver sees it fail
        # (O5-5: Kaimon, the session, the depot), no stop; else a give-up
        door.signal_role(user, "CONT")
        down = infra_down(warm["k"], warm["key"], dk) if so["outcome"] == "blocked:infra" else None
        if down:
            return finish(h, "infra", slot_name, f"the climber reported blocked:infra and the driver finds {down}: " + so.get("handoff", "")[:600])
        return finish(h, "gave-up" if so["outcome"] == "blocked:infra" else so["outcome"], slot_name, so.get("handoff", ""))
    resumes = 0
    SPENT = "spent"   # no resume left: the move is refused, its own
    def resume(ask_text):
        nonlocal resumes
        if resumes >= c["resumes_per_move"]:
            return SPENT
        resumes += 1
        return climbed(ask_text + "\nThen reply with the same JSON as before.", True)
    def not_its_own(so2):
        """A resume the governor refused (BUDGET) or that gave no answer (None) ends the move as the governor's or the
        driver's, never a stop charged to the hold (O6-4)."""
        return finish(h, "budget", slot_name, "the governor refused the climber's resume") if so2 == BUDGET else \
            finish(h, "infra", slot_name, "the climber's resume gave no answer twice") if so2 is None else None
    cand = {}
    def gated():
        """Every gate the driver holds a commit to, re-run after every change to it: the one commit back as a bundle,
        G5 on base..sha in the main repository before anything of the commit runs (red 1), then the driver's
        measurement as the measure user, judged by processes that never load it (red 4, 12, R5-4)."""
        sha, why = bundle(user, clone, base, slot_name, task)
        if sha is None:
            return [], [why], []
        cand["sha"] = sha
        bad = g5(base, sha, "port")
        if bad:
            return [], ["G5: " + b for b in bad], []
        return measure_candidate(h, base, sha, labels, before, task, keep=os.path.join(STATE, "deltas", f"{task}.answers.tsv"))[:3]
    # a power cut in a gate waits until work may run and runs the gate again on the commit the move holds: the
    # climber's work and the slot's use are kept (on_ac, O9-1); past task_wall_s of waiting the move ends as infrastructure
    gate = move_gate(gated, h, slot_name)
    unlocked, problems, rows = gate()
    if problems and not any(p_.startswith("G5") for p_ in problems):
        so2 = resume("The driver measured your commit against its base and found:\n" + "\n".join(f"- {p_}" for p_ in problems[:30]) +
                     "\nFix each at its source and amend your one commit, or report blocked.")
        if so2 == BUDGET or so2 is None:
            return not_its_own(so2)
        if isinstance(so2, dict) and so2["outcome"] == "committed":
            unlocked, problems, rows = gate()
    if problems:
        event("refused", hold=h["key"], problems=problems[:20])
        return finish(h, "refused", slot_name, "the driver's measurement refused the move:\n" + "\n".join(problems[:30]))
    answers, need = "", reviewers()
    for rnd in (1, 2, 3):
        commit = cand["sha"]
        # every round a fresh review in the eval's form (A7-10): the climber's message and answers are claims in its job
        claims = sh(["git", "log", "-1", "--format=%B", commit], check=True).stdout + answers
        rv = review(task, ruser, base, commit, job_text(h, base, commit), claims)
        if rv == BUDGET:
            return finish(h, "budget", slot_name, "the governor refused the review")
        if rv is None:
            return finish(h, "infra", slot_name, "the review gave no answer twice")
        event("reviewed", hold=h["key"], round=rnd, verdict=rv.get("verdict"), fidelity=rv.get("fidelity"))
        need = reviewers()
        if approved(rv) and need == 2:   # a second blind reviewer, fresh, told nothing of the first (K4): another review
            # user, whose home cannot read the first's (each mode 700) and holds nothing of its own past runs (door.KEEPS)
            rv2 = review(f"{task}-2", "review2" if ruser == "review1" else "review1", base, commit, job_text(h, base, commit), claims)
            if not isinstance(rv2, dict):
                return finish(h, "budget" if rv2 == BUDGET else "infra", slot_name, "the second blind review gave no verdict")
            event("reviewed", hold=h["key"], round=rnd, verdict=rv2.get("verdict"), fidelity=rv2.get("fidelity"), second=True)
            rv = rv if approved(rv2) else rv2
        if approved(rv):
            break
        so2 = resume("The fidelity review asks for changes. For each blocker or should: fix it at its source and amend "
                     "your one commit, or disagree with evidence (file:line, a command and its output). Nits: decline in "
                     "one line.\n\n" + json.dumps(rv, indent=1)) if rnd < 3 else SPENT
        if so2 == BUDGET or so2 is None:
            return not_its_own(so2)
        if not isinstance(so2, dict) or so2["outcome"] != "committed":
            return finish(h, "refused", slot_name, "the review did not approve: " + json.dumps(rv.get("findings", []))[:1500])
        unlocked, problems, rows = gate()
        if problems:
            return finish(h, "refused", slot_name, "after the review's fixes the driver refused the move:\n" + "\n".join(problems[:30]))
        answers = ("\n\nIts answers to the earlier review's findings:\n" + json.dumps({"findings": rv.get("findings", []),
                                                                             "answers": so2}, indent=1))
    dpath = os.path.join(STATE, "deltas", f"{task}.tsv")   # every row measured on the commit, for the table at its landing
    write_atomic(dpath, cases_text(rows))
    enqueue(cand["sha"], h["key"], "move", hold_id=h["id"], fixfirst=bool(h.get("fixfirst")),
            unlocked=len(unlocked), rows=dpath, base=base, labels=labels, h=h, approvals=need,
            measured=cand["sha"], driver=driver_commit(),
            answers=os.path.join(STATE, "deltas", f"{task}.answers.tsv"))
    unclaim(h)
    return "queued"

# ---------------------------------------------------------------- the agent probe (item 5): what only a model shows
def probe_blob():
    """What the agent probe is, hashed (A7-3, as judge_blob is G4's): agent_probe's source, the calls and the body rule
    its proxy admits (door.CALLS, BLOCKS, SOURCES, body_refusal, block_refusal) and the agent profile's text, so a
    record of another probe, an older one or one of a looser door, never passes the gate."""
    import inspect
    sb = door.profile(os.path.join(STATE, f".probe-profile-{os.getpid()}.sb"), [door.home("slot1")], kind="agent", port=1, egress=2)
    text = open(sb).read(); os.remove(sb)
    parts = [inspect.getsource(agent_probe), repr(sorted(door.CALLS)), repr(sorted(door.BLOCKS)), repr(sorted(door.SOURCES)), repr(sorted(door.BODY_KEYS)),
             inspect.getsource(door.body_refusal), inspect.getsource(door.block_refusal), text]
    return hashlib.sha1("\0".join(parts).encode()).hexdigest()[:16]

def probe_ok():
    """The agent probe passed for the climb's pinned claude and for the probe as it is now (probe_blob): the gate of a
    slot's move (never of a landing)."""
    rec = state_json("probe.json", {})
    return bool(rec.get("ok")) and rec.get("claude") == os.path.basename(door.claude_bin(STATE)) and rec.get("probe") == probe_blob()

def probe_gate(name):
    """Whether slot `name` may start a move: the agent probe passed for the claude the launch chose (O6-3). One probe
    runs at a time, under a flock of its own, probe_ok() read again once it is held, so a second slot never runs a
    duplicate; a probe that failed is run again, on its own backoff (retry_backoff_s, doubled), at most
    agent_probe_runs runs per claude version, and Dale is told only after the last. A new claude is adopted at launch
    alone (door.pin_claude), so these runs are its probes."""
    if probe_ok():
        return True
    fd = door.lock_fd(".agent-probe.lock")   # TOP/locks: one probe at a time across states (O8-2)
    try:
        door.flock_within(fd, door.role_wait("slot"), "the agent probe's lock")
    except BaseException:
        os.close(fd); raise
    try:
        if probe_ok():
            return True
        me, rec = os.path.basename(door.claude_bin(STATE)), state_json("probe.json", {})
        runs, last = (rec.get("runs", 1), rec) if rec.get("claude") == me and rec.get("probe") == probe_blob() else (0, None)
        if runs >= cfg()["agent_probe_runs"]:
            alarm(f"agent-probe-{me}", "the agent probe failed", f"The probe of {me} failed {runs} times, the last: "
                  f"{json.dumps(last.get('failed') if last else None)} ({STATE}/probe.json). Default taken: no move starts "
                  "until it passes (`climb.py agent-probe`, or a launch with another claude); the lander lands on.")
            return False
        if backed_off("agent-probe"):
            return False
        rec = agent_probe(name, runs + 1)
        if rec["ok"]:
            recovered("agent-probe")
            return True
        back_off("agent-probe", why=f"{me}: {rec['failed']}", note_at=0)   # no note but the last run's (above)
        return False
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def agent_probe(name="climb-1", runs=1):
    """Item 5 (R12): one agent run per pinned claude, capped at agent_probe_usd, as slot `name`'s user (the slot that
    asks, probe_gate) with a climber's argv
    and its slot's own Kaimon and session: what only a model shows, each judged from what the driver holds, never the
    agent's word or its transcript (its user's to rewrite); the fences are door-probe's, tried with no model. It
    answered (its proxy admitted calls the API answered 200 and refused none); its Bash, Edit and Write ran (the tools
    `claude` itself sent the proxy as run without an error, door.done_tools, and the files each made, in its commit);
    it committed (its bundle: exactly one commit on its base); it reached its slot's Kaimon and `ex` answered 2 (the
    global its ex set, read by the driver from the session itself); Julia loaded WasmTarget in its clone (a file
    holding Julia's hash of a fresh word, which the session computes again). Its clone loads WasmTarget first, as its
    user in the `check` profile, so a new claude's probe passes cold. Recorded in probe.json by claude's version, with
    `runs`, this version's runs so far (probe_gate)."""
    c, n, user = cfg(), uuid.uuid4().hex[:8], users(name)[0]
    base = git("rev-parse", f"origin/{MARCH}")
    env = environment(base)
    dk = deps(base, env["Manifest.toml"])
    want = {"bash.txt": n, "probe-edit.txt": f"edited {n}", "write.txt": n}
    steps = [f"Bash: `echo {n} > bash.txt`", f"Edit the file probe-edit.txt: replace `edit me {n}` with `edited {n}`.",
             f"Write the file write.txt with the content `{n}`.",
             f"Bash: `julia --startup-file=no --project=. -e 'using WasmTarget; write(\"jl.txt\", string(hash(\"{n}\")))'`",
             f"Kaimon's ex tool, in session `{{ses}}`: `wtprobe_{n} = 1 + 1`",
             "Bash: `git add bash.txt probe-edit.txt write.txt jl.txt && git commit -q -m probe`"]
    with door.using(user):
        clone = agent_tree(user, name, name, base, dict(env, **{"probe-edit.txt": f"edit me {n}\n"}))
        depot = f"{clone}/.wtd/depot:{dk}:{door.TOP}/julia:"
        rc, o, e = door.run(user, ["julia", "--startup-file=no", "--project=.", "-e", "using WasmTarget"], c["session_warm_s"], cwd=clone,
                            profile=door.profile(f"{door.give(user, f'warm-{n}')}/warm.sb", [door.home(user)], kind="check"),
                            env={"JULIA_DEPOT_PATH": depot, "JULIA_NUM_THREADS": "1"})
        if rc != 0:
            raise ClimbError(f"the probe's clone did not load WasmTarget: {(o + e).strip()[-300:]}")
        k = kaimon_up(user, name, clone, dk, base)
        ses = session(k, clone, name)
        sid = str(uuid.uuid4())
        prompt = ("You are the climb's agent probe: a test of the tools you run with, approved by their owner. Do each step "
                  "below exactly once, in order, and nothing else; then reply with the JSON the schema asks for, outcome "
                  "`committed`, and in `handoff` one line per step.\n\n" + "\n".join(f"{i}. {x}" for i, x in enumerate(steps, 1)).replace("{ses}", ses))
        run_agent("probe", f"probe-{n}", claude_cmd(c["climber_model"], "low", SCHEMA_CLIMB, CLIMBER_TOOLS, prompt, sid, clone,
                                                    cap=c["agent_probe_usd"], mcp=f"{door.home(user)}/mcp.json"), clone, sid, user, depot)
        px = json.load(open(next(iter(glob.glob(os.path.join(STATE, "runs", f"probe-{n}.probe.*.{sid}.json"))))))
        got = kaimon_eval(k, ses, f'(wtprobe_{n}, string(hash("{n}")))', c["kaimon_http_s"]) if door.pids(user, agents=False) else ""
        door.reap(user)
        sha, why = bundle(user, clone, base, f"probe-{n}", f"probe-{n}")   # its own ref, deleted once read
    files = {f: sh(["git", "show", f"{sha}:{f}"]).stdout.strip() if sha else None for f in (*want, "jl.txt")}
    if sha:
        git("update-ref", "-d", f"refs/climb/probe-{n}")
    m = re.fullmatch(r'\(2, "(\d+)"\)', got.strip().splitlines()[-1] if got.strip() else "")
    held = {"it answered": any(st == 200 for _, st in px["admitted"]) and not px["refused"],
            "it committed": sha is not None,
            **{f"its {t} ran": t in px["tools"] and files[f] == want[f] for t, f in (("Bash", "bash.txt"), ("Edit", "probe-edit.txt"), ("Write", "write.txt"))},
            "it reached its slot's Kaimon and ex answered 2": "mcp__kaimon__ex" in px["tools"] and bool(m),
            "Julia loaded WasmTarget in its clone": bool(m) and files["jl.txt"] == m.group(1)}
    failed = [k_ for k_, ok in held.items() if not ok]
    rec = {"t": stamp(), "claude": os.path.basename(door.claude_bin(STATE)), "probe": probe_blob(), "runs": runs, "sid": sid,
           "failed": failed, "bundle": why,
           "tools": px["tools"], "admitted": px["admitted"], "refused": px["refused"], "session": got[-120:], "ok": not failed}
    save_json("probe.json", rec)
    event("agent-probe", ok=rec["ok"], failed=failed)
    return rec

def pick(slot=None):
    if not head_cases():   # no move before the first scored head: the holds and the sentinel net come from it
        return
    # a landing's rows are in the table at once (item 8), so the holds show what it left; a hold whose approved
    # commit waits for the lander is not climbed twice
    done = {x["hold_id"] for x in state_json("ready.json", [])}
    overdue = fixfirst_overdue()
    scored = origin_scored()
    hs = [h for h in holds() if admits(h, overdue, scored)]   # while a red is overdue, every slot climbs fix-first holds alone
    if slot == "climb-1":   # D40: one slot always ports compiler src, the hold that unlocks most cases first
        corpus = sorted((h for h in hs if not h["key"].startswith("G") and not h.get("fixfirst") and not h.get("tail")),
                        key=lambda h: -h["n"])
        hs = corpus + [h for h in hs if h not in corpus]
    for h in hs:
        if h["parked"] or h["id"] in done or h["n"] == 0 and not h.get("fixfirst"):
            continue
        yield h

def line_stopped(lane):
    """check.sh's one rule (28): while the common dir's wt-line-stop exists, only the lane its first line names works."""
    p = os.path.join(COMMON, "wt-line-stop")
    return os.path.exists(p) and (open(p).read().split("\n")[0].strip() != lane)

def slot_once(name):
    """One iteration of a slot, a process of its own (launch.sh loops it): one move, then exit. Exit 0 after a move,
    3 when there is nothing to do yet (the loop sleeps)."""
    reap_claims()
    if line_stopped(name) or pause() or backed_off("slot", name) or week_half() or token_refused() or not power_ok():
        return 3   # no move starts while the power rule stops work (O8-3)
    if not probe_gate(name):   # what only a model shows, proved per claude the launch chose (item 5, O6-3)
        return 3
    if over_budget():   # the wait's transitions alone are events (A13)
        if not state_json("waits.json", {}).get(name):
            update_json("waits.json", {}, lambda w: w.__setitem__(name, stamp())); event("budget-wait", slot=name)
        return 3
    if state_json("waits.json", {}).get(name):
        update_json("waits.json", {}, lambda w: w.pop(name, None)); event("budget-wait-end", slot=name)
    if len(admitted_queue()) >= cfg()["queue_cap"]:   # D50: no move while the queue is full of what can land
        return 3
    h = next((h for h in pick(name) if claim(h, name)), None)
    if not h:
        return 3
    try:
        move(h, name)
    except Exception as e:   # every fault of the driver's is infrastructure: an event, a backoff, the hold kept (26)
        event("driver-error", slot=name, hold=h.get("key"), error=repr(e)[:400])
        finish(h, "infra", name, f"the driver: {e}", driver=True)
        return 3
    except BaseException:   # a stop (TERM, ^C): its hold freed
        unclaim(h)
        raise
    recovered("slot", name)
    return 0
