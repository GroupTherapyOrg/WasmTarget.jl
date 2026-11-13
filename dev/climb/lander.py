"""dev/climb/lander.py — the one process that lands (dev/ship.sh): the queue, the quiet probe, the rebased check,
the judge's eval and the audits it queues."""
from core import *   # noqa: F403
from measure import *   # noqa: F403

# ---------------------------------------------------------------- the quiet window: stopped only while a check runs
DAEMONS = ("photoanalysisd", "mediaanalysisd")   # macOS's Photos analysis (Dale 2026-11-09: "Kill photoanalysisd")

# whose processes a landing's check stops: every role but its own and the measurement roles, which never run beside a
# check (land() holds their locks through the probe and the check: ruling 1), so none of their clocks runs while stopped
QUIET = [r for r in door.ROLES if r not in ("land", "measure", "score")]

def resume_orphans():
    """Every climb process on start: what a dead climb process stopped is resumed (incident 10: a landing whose owner
    was killed left the scoreboard's and the slots' Julia stopped for good), from the one record of a landing's window
    (door.resume_orphans: its roles by user, its daemons by pid)."""
    gone = door.resume_orphans()
    if gone:
        event("resumed-orphans", stopped=gone)

@contextlib.contextmanager
def quiesced():
    """The climb's other build users and macOS's Photos analysis stopped (SIGSTOP) for a probe and a check, by user
    (door.stop_role: every process of the user, however it was started), each stop recorded first in the one record of
    the landing's window (door.open_window), which a kill of this process leaves for the next climb process to resume. A
    slot's user stopped between its climber's runs stays stopped, and its move cannot resume it, nor any role start a
    process, until the window closes (door.after_window). Yields a scan, run again every poll_s["scan"] by its caller,
    which stops what started meanwhile."""
    mine = {}
    def stat(r):
        return [f[1] for f in (l.split() for l in sh(["ps", "-axo", "user=,stat="]).stdout.splitlines()) if len(f) == 2 and f[0] == door.ROLES[r]]
    def scan():
        for r in QUIET:
            if r not in mine:
                st = stat(r)
                mine[r] = not (st and all(x.startswith("T") for x in st))   # one asleep already (a move's pause) stays so
            if mine[r]:
                door.stop_role(r)
        for line in sh(["ps", "-axo", "pid=,user=,comm="]).stdout.splitlines():
            f = line.split(None, 2)
            if len(f) == 3 and os.path.basename(f[2]) in DAEMONS and f[1] == os.environ.get("USER", "") and f[0] not in mine:
                door.stop_daemon(f[0]); mine[f[0]] = True
    scan.stopped = mine
    door.open_window(QUIET)   # nothing of these roles starts or resumes itself until it closes (door.after_window)
    try:
        scan()
        yield scan
    finally:
        door.close_window()   # what it stopped resumed, the record closed

def cpu_ticks():
    """Each CPU's (user, system, idle, nice) ticks from the kernel (host_processor_info, PROCESSOR_CPU_LOAD_INFO)."""
    import ctypes, ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    n, info, cnt = ctypes.c_uint(), ctypes.POINTER(ctypes.c_int)(), ctypes.c_uint()
    if libc.host_processor_info(libc.mach_host_self(), 2, ctypes.byref(n), ctypes.byref(info), ctypes.byref(cnt)) != 0:
        raise ClimbError("host_processor_info failed")
    out = [tuple(info[i * 4 + k] for k in range(4)) for i in range(n.value)]
    libc.vm_deallocate(ctypes.c_uint.in_dll(libc, "mach_task_self_"), ctypes.cast(info, ctypes.c_void_p).value, cnt.value * 4)
    return out

def probe():
    """D14's admission (15, O5-3): the performance and the efficiency cores' idle over probe_s, apart, and the paging
    over the same window, the pages swapped in and the pages the compressor decompressed (the machine waiting on
    memory now; the pressure level stays at "warning" for minutes with no paging, so it refuses only at critical, and
    is recorded). The efficiency cores come first in the kernel's CPU order (hw.perflevel1; measured 2026-11-09: six
    background-QoS spinners filled cpus 0-5 and left 6-9 idle)."""
    ne = int(sh(["sysctl", "-n", "hw.perflevel1.logicalcpu"]).stdout.strip() or 0)
    a, s0 = cpu_ticks(), paging(); time.sleep(cfg()["probe_s"]); b, s1 = cpu_ticks(), paging()
    idle = lambda cs: round(100.0 * sum(y[2] - x[2] for x, y in cs) / max(sum(sum(y) - sum(x) for x, y in cs), 1), 1)
    pairs = list(zip(a, b))
    return {"p_idle": idle(pairs[ne:]), "e_idle": idle(pairs[:ne]), "pressure": pressure(), "swapins": s1[0] - s0[0],
            "decompressions": s1[1] - s0[1]}

def admitted(pr):
    c = cfg()
    return pr["p_idle"] >= c["p_idle"] and pr["e_idle"] >= c["e_idle"] and pr["pressure"] < 4 and \
        pr["swapins"] <= c["swapins_max"] and pr["decompressions"] <= c["decompressions_max"]

def pressure():
    """The kernel's memory pressure level: 1 normal, 2 warning, 4 critical (unreadable: critical)."""
    return int(sh(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).stdout.strip() or 4)

def vm(keys=("Swapins", "Decompressions")):
    """vm_stat's counters `keys` since boot, in pages."""
    t = sh(["vm_stat"]).stdout
    return tuple(int(re.search(rf"{k}:\s+(\d+)", t).group(1)) for k in keys)

def paging():
    """(pages swapped in, pages decompressed) since boot, vm_stat's Swapins and Decompressions."""
    return vm()

CHECK_VM = ("Pageouts", "Swapouts", "Swapins", "Decompressions")   # what the machine paged during a check (O6-7)

# ---------------------------------------------------------------- landing: one shipper, the lander
# dev/ship.sh's result kinds (its finish()); any other text in its result file is OTHER
SHIP_KINDS = ("LANDED", "ADMISSIBLE", "NOTHING", "REFUSED", "D14", "OWN", "NETWORK", "OTHER")

def ship_step(slot):
    """The step dev/ship.sh runs now for the lander's lane (its $WT_SHIP_STEP: regen, check, still, push, landed), None
    before its rebase's steps begin or after they end."""
    with contextlib.suppress(FileNotFoundError):
        return open(os.path.join(COMMON, "wt-ship", f"{os.path.basename(slot)}.step")).read().strip() or None
    return None

def ship_files():
    """Two files the lander names for one run of dev/ship.sh, in its own state: ship.sh's result ($WT_SHIP_RESULT) and
    the check's verdict ($WT_CHECK_RESULT), each written by ship.sh, Dale's process, alone (R6-2, R6-7)."""
    d = os.path.join(STATE, "ship")
    os.makedirs(d, exist_ok=True)
    t = f"{int(time.time())}-{os.getpid()}"
    out = os.path.join(d, f"{t}.result"), os.path.join(d, f"{t}.check")
    for f in out:
        with contextlib.suppress(FileNotFoundError):
            os.remove(f)
    return out

def read_once(path, cap=4096):
    """A file of ship_files(), read (at most `cap` bytes) and removed; None when ship.sh wrote none."""
    try:
        with open(path) as f:
            text = f.read(cap).strip()
    except FileNotFoundError:
        return None
    os.remove(path)
    return text

def ship_result(path):
    """dev/ship.sh's verdict, `<KIND> [<arg>]`, from the file the lander named for it, never a line of its output, which
    carries what the check printed, a candidate's tests' lines among them (R6-2: a forged `ship-result: LANDED` was
    the last line of a killed ship's log): (KIND, arg); no file, or a kind ship.sh does not name, is OTHER (D9)."""
    text = read_once(path)
    if text is None:
        return "OTHER", "no result written (ship.sh killed, or one that writes none)"
    kind, _, arg = text.partition(" ")
    return (kind, arg.strip() or None) if kind in SHIP_KINDS else ("OTHER", f"an unknown result {text[:60]!r}")

SPLIT_RE = re.compile(r"(load|ratchet|shard\.(\d{1,2})) (\d+) ([0-9.]+) ([0-9.]+) ([0-9.]+)|wall (\d+)|start\.(\d{1,2}) ([0-9.]+)")

def check_verdict(path):
    """The check's verdict as ship.sh wrote it: (its exit status, its critical path's seconds or None, its split or
    None), or (None, None, None) when no check ran. The status is check.sh's own (dev/check.sh names each); the seconds
    and the split are what its stages reported (G3's trust: the processes that load the candidate write them), read for
    D14's note, the band and the predictions of a landing's test set (the landing-check ruling's step 2), never a
    verdict. The split: each stage's [judged seconds, performance-core G, efficiency-core seconds, unreported seconds]
    (load, ratchet, and the shards in order) and the wall, from the lines ship.sh copied after the first; a line it does
    not read leaves its stage out, never a number made up (D9)."""
    lines = (read_once(path) or "").splitlines()
    f = lines[0].split() if lines else []
    split = {}
    for l in lines[1:]:
        m = SPLIT_RE.fullmatch(l.strip())
        if not m:
            continue
        if m.group(8):   # a shard's measured start, its G until its first file (A13-7)
            split.setdefault("starts", {})[int(m.group(8))] = float(m.group(9))
        elif m.group(7):
            split["wall"] = int(m.group(7))
        else:
            v = [int(m.group(3)), float(m.group(4)), float(m.group(5)), float(m.group(6))]
            if m.group(2):
                split.setdefault("shards", {})[int(m.group(2))] = v
            else:
                split[m.group(1)] = v
    if "shards" in split:
        split["shards"] = [split["shards"][k] for k in sorted(split["shards"])]
    if "starts" in split:
        split["starts"] = [split["starts"][k] for k in sorted(split["starts"])]
    return (int(f[0]) if f and re.fullmatch(r"-?\d+", f[0]) else None,
            int(f[1]) if len(f) > 1 and f[1].isdigit() else None, split or None)

def enqueue(sha, title, kind, hold_id=None, fixfirst=False, unlocked=0, rows=None, base=None, audit=None, labels=(), h=None,
            approvals=1, answers=None):
    """An approved commit of the main repository, pinned: its sha, its patch-id, the base it was measured on, its rows
    (every label measured, under STATE) and its labels, on a ready branch that keeps its objects. The lander, the one process that runs
    dev/ship.sh, lands it."""
    sha = git("rev-parse", f"{sha}^{{commit}}")
    n, top = int(git("rev-list", "--count", f"origin/{MARCH}..{sha}")), ship_max()
    if n == 0 or n > top:
        raise ClimbError(f"{sha[:10]} has {n} commit(s) past origin/{MARCH}; a queued item carries 1 to {top} (ship.sh's SHIP_MAX)")
    base = base or git("merge-base", f"origin/{MARCH}", sha)
    why = bundled(base, sha)   # src never lands beside the harness (A106E2)
    if why:
        raise ClimbError(why)
    hid = hold_id or f"{kind}-{sha[:8]}"
    branch = f"ready/{hid}-{int(time.time())}"
    common_write(f"the ready branch {branch}")   # spec v18 P5
    git("branch", "-f", branch, sha)
    item = {"branch": branch, "sha": sha, "patch_id": next(iter(patch_ids(f"{sha}^!")), ""), "base": base,
            "kind": kind, "hold": title, "hold_id": hid, "fixfirst": fixfirst, "unlocked": unlocked,
            "rows": rows, "audit": audit, "labels": sorted(labels), "t": stamp(), "approvals": approvals, "answers": answers,
            # the hold as the move was judged against it, for the lander's rebased judgement (operator 9)
            "h": {k: h[k] for k in ("key", "cases", "tail", "defs", "require_pass", "fixfirst", "why") if k in h} if h else None}
    update_json("ready.json", [], lambda q: q.append(item))   # the audit rides in the same write (B14)
    event("queued", hold=title, hold_id=hid, sha=sha, branch=branch)
    return item

def ship_max():
    """dev/ship.sh's SHIP_MAX, read where ship.sh keeps it, origin's copy (A5-9: one source)."""
    return ship_literal("SHIP_MAX")

def unqueue(item, **kw):
    update_json("ready.json", [], lambda q: q.__setitem__(slice(None), [dict(x, **kw) if kw and x["branch"] == item["branch"] else x
                                                                       for x in q if kw or x["branch"] != item["branch"]]))

def ship_cmd(slot):
    """Origin's dev/ship.sh, written into the lander's worktree's .wtd from git, never the copy the checked-out commit
    carries (red 1: no script of a candidate's tree runs); asked to speak the result line before it is called, since
    one that does not would ship."""
    common_write("dev/ship.sh (a landing appends the landing log, wt-landings.tsv, and pushes)")   # spec v18 P5
    text = git("show", f"origin/{MARCH}:dev/ship.sh")
    if "WT_SHIP_RESULT" not in text:
        raise ClimbError(f"origin/{MARCH}'s dev/ship.sh writes no result file ($WT_SHIP_RESULT)")
    os.makedirs(os.path.join(slot, ".wtd"), exist_ok=True)
    write_atomic(os.path.join(slot, ".wtd", "ship.lander.sh"), text + "\n")
    return ["bash", ".wtd/ship.lander.sh"]

def admissible(slot):
    """dev/ship.sh's own cheap refusals (a held lane, the line stop, its one retry an hour on a D14 red, nothing to
    land), asked before anything is stopped: (its result, its output for the log)."""
    res, _ = ship_files()
    r = sh(ship_cmd(slot) + ["--admissible"], cwd=slot, timeout=cfg()["admissible_wall_s"],
           env=dict(os.environ, WT_CLIMB_DRIVER="1", WT_SHIP_RESULT=res))
    return ship_result(res), r.stdout + r.stderr

def land(slot, item, handed=None):
    """The probe, then the check, holding both measurement locks (the lander first on each, a score yielding between
    its parts: julia_slot, yield_slot), so no measurement runs beside a check and none starts during one (ruling 1);
    the climb's other build users and Photos analysis stopped (door.stop_role, whose stops every wall on those roles
    leaves out), the cores sampled, and only a quiet machine gets the check; a busy one is resumed at once and tried
    next round. ship.sh lands the commit the rebased check measured alone (WT_SHIP_EXPECT: its parent origin's head, so
    ship.sh's rebase replays nothing, A7-5), in a process group of its own that a timeout kills whole. Returns (probe, result, check,
    output): ship.sh's result and the check's verdict from the files the lander named (ship_files), its output for
    the log and notes alone; result None when the machine was not quiet."""
    c = cfg()
    # the score's lock first (O7-5): a score's part can run for kinds_wall_s, so the verify lock is never held idle
    # while the lander waits behind one
    with julia_slot("score", first=True), julia_slot("verify", first=True):
        # the warm layer of origin's own images beneath the check's fresh depot (A8-1), made before anything is stopped;
        # made after the landing before it (layer()), so here it is found, never built, unless none landed since launch
        layer(slot)
        with quiesced() as scan:
            return _land(slot, item, c, scan, handed)

def layer(slot):
    """The landing layer of origin's head for the lander's environment (door.land_layer: built once per head and
    environment, found after that), an event when it was built."""
    t = door.CLOCK()
    made, built = door.land_layer(COMMON, git("rev-parse", f"origin/{MARCH}"), {n: open(os.path.join(slot, n)).read() for n in
                                  ENV_FILES if os.path.isfile(os.path.join(slot, n))},
                                  os.path.join(STATE, "logs", "land-layer.log"))
    if built:
        event("land-layer", path=os.path.basename(made), secs=round(door.CLOCK() - t))

def _land(slot, item, c, scan, handed=None):
    """land()'s probe and check, inside its locks and its quiet window (`scan` stops what started meanwhile)."""
    pr = probe()
    ok = admitted(pr)
    # what the stopped users still hold in memory (operator 7): read beside the probe, to re-derive the band
    rss = [int(f[1]) for f in (l.split() for l in sh(["ps", "-axo", "user=,rss="]).stdout.splitlines())
           if len(f) == 2 and f[0] in {door.ROLES[r] for r in QUIET}]
    pr["stopped"], pr["stopped_rss_mb"] = len(rss), round(sum(rss) / 1024)
    event("quiet-probe", ok=ok, **pr)
    if not ok:   # a busy machine: the next probe waits probe_backoff_s, so no round makes the measurements yield for
        back_off("lander", "probe", why="the machine was not quiet", secs=c["probe_backoff_s"], note_at=0)   # nothing
        return pr, None, (None, None, None), ""
    recovered("lander", "probe")
    log = os.path.join(STATE, "logs", f"ship-{int(time.time())}.out")
    res, chk = ship_files()
    v0, t_check = vm(CHECK_VM), door.CLOCK()
    with open(log, "w") as f:
        p = subprocess.Popen(program(ship_cmd(slot)), cwd=slot, stdout=f, stderr=subprocess.STDOUT, text=True, start_new_session=True,
                             env=dict(os.environ, WT_CLIMB_DRIVER="1", WT_SHIP_EXPECT=item["rebased"]["commit"], WT_SHIP_RESULT=res,
                                      WT_CHECK_RESULT=chk, **({door.SET_ENV: handed[0], door.COSTS_ENV: handed[1]} if handed else {})))
        t0, battery, step = door.CLOCK(), False, None
        try:
            while p.poll() is None:
                if door.CLOCK() - t0 > c["ship_kill_s"]:
                    break
                time.sleep(c["poll_s"]["scan"]); beat()
                # when the power rule stops work (core.power_works) the check ends, redone when work may run, never a D14
                # row (O8-3); on battery with Low Power Mode off above the floor it runs on; ship.sh is stopped only while its step
                # is the regeneration or the check, never at the push or after it: a kill between the push and the landed
                # hook would leave a landing its log does not name (O9-1)
                if not power_ok() and (step := ship_step(slot)) in ("regen", "check"):
                    battery = True; break
                scan()   # a julia started during the check is stopped too (2026-11-09)
        finally:   # past its limit, or the lander stopped (launch.sh stop's TERM unwinds here): ship.sh's group ends (red 13)
            if p.poll() is None:
                with contextlib.suppress(OSError):
                    os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(c["term_grace_s"])
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(OSError):
                        os.killpg(p.pid, signal.SIGKILL)
                    p.wait()
            door.reap("land")   # the check's processes are the landing user's, never in ship.sh's group (red 4)
    # what the machine paged while ship.sh and its check ran (O6-7): beside the probe's, so the burn-in reads
    # whether a red follows memory
    pr["during"] = dict(zip((k.lower() for k in CHECK_VM), (b - a for a, b in zip(v0, vm(CHECK_VM)))), secs=round(door.CLOCK() - t_check))
    result, verdict = ship_result(res), check_verdict(chk)
    pr["records"] = read_once(chk + ".records", cap=DEFAULTS["land_outs"]["total_bytes"])   # popped by land_round
    if (battery or not power_ok()) and result[0] != "LANDED":   # a check the power rule stopped is no verdict (a landing stands)
        event("power-cut", role="land", in_flight=item["hold"], step=step, result=f"{result[0]}:{result[1]}")
        raise PowerCut(f"the power rule stopped work (core.power_works) during the landing check of {item['hold'][:80]} "
                       f"(ship.sh's step {step}): no verdict, redone when work may run")
    pr["battery"] = battery
    return pr, result, verdict, open(log, errors="replace").read()[-20000:]

def ship_event(item, pr, kind, arg, crc, path, out, split=None, src_set_=None):
    """One landing round's event (O6-7): ship.sh's result, the check's exit status and the critical path its stages
    reported, with its split (each stage's judged seconds and their terms, the wall: check_verdict), D14's verdict on it
    (red, the check's status 10; green, 0; else none: the check ended on another red),
    and the probe it was admitted on (its fields and stopped_rss_mb) with what the machine paged during the check
    (`during`: pageouts, swapouts, swapins, decompressions, seconds), so the burn-in can join each red to memory; `ship`
    when a check ran, `land-wait` when ship.sh refused before one."""
    event("ship" if pr else "land-wait", hold=item["hold"], result=f"{kind}:{arg}", check=crc, path=path if crc in (0, 10) else None,
          split=split if crc in (0, 10) else None, src_set=src_set_ if pr else None,
          target=(src_set_ or {}).get("target") if pr else None, margin=((src_set_ or {}).get("margin") or {}).get("margin") if pr else None,
          d14={"verdict": "red" if crc == 10 else "green" if crc == 0 else None, "band": d14_red()} if pr else None,
          probe=pr, tail=out[-300:])

def item_problems(item):
    """The pinned commit's shape, read again in the main repository before it is checked out: a move's or an audit's
    one commit through G5's rule for its kind (an audit adds to dev/AUDIT.md alone), G5 kept on the item by its sha
    (O5-12: a round that waits on the probe parses nothing again)."""
    commits = git("rev-list", f"origin/{MARCH}..{item['sha']}").splitlines()
    if item["kind"] not in ("move", "audit"):
        return []
    if (item.get("g5") or {}).get("sha") != item["sha"]:
        kind = "audit" if item["kind"] == "audit" else "port"
        base = item["base"] if item["kind"] == "move" else git("merge-base", f"origin/{MARCH}", item["sha"])
        item["g5"] = {"sha": item["sha"], "bad": ["G5: " + b for b in g5(base, item["sha"], kind)]}
        unqueue(item, g5=item["g5"])
    return item["g5"]["bad"] + ([f"{len(commits)} commits past origin; it is one"] if len(commits) != 1 else [])

def drop(item, outcome, note, stop=True):
    """A queued item that will not land: out of the queue, its commit kept on a salvage branch offered to its own hold,
    and the hold back to the climb (a NEW move re-runs every gate), a stop unless stop=False (an item queued before
    the sha was pinned). An audit is rebuilt by the next audit, never salvaged."""
    unqueue(item)
    branch = None
    if item.get("kind", "move") != "audit" and git("rev-parse", "-q", "--verify", f"refs/heads/{item['branch']}", check=False):
        branch = f"salvage/{item['hold_id']}-{now().strftime('%Y%m%dT%H%M%S')}"
        git("branch", "-m", item["branch"], branch)
        event("salvaged", slot="climb-land", branch=branch, hold_id=item["hold_id"])
    else:
        git("branch", "-D", item["branch"], check=False)
    text = f"An approved commit for this hold, {item.get('sha', item['branch'])[:12]}, did not land: {note[-1500:]}" + \
           (f"\nIt is on the local branch {branch}." if branch else "")
    if item.get("kind", "move") == "move":
        update_json("handoffs.json", {}, lambda hs: hs.__setitem__(item["hold_id"], (hs.get(item["hold_id"], "") + "\n\n" + text)[-2500:]))
        if stop:
            event("stopped", hold=item["hold"], hold_id=item["hold_id"], outcome=outcome, note=note[-600:])
    elif item["kind"] == "audit":   # rebuilt from nothing: its saved entry went red (22)
        save_json("audit-saved.json", {})
        event("audit-failed", n=item["audit"]["n"], why=note[-300:]); back_off("audit", why=note[-300:], note_at=2)
    else:
        for_dale(f"a queued commit did not land: {item['hold'][:80]}", text + "\nDefault taken: dropped from the queue.")
    event("dropped", hold=item["hold"], sha=item.get("sha"), outcome=outcome)

def on_origin(sha):
    """The commit `sha` names, when origin/wt2 holds it (after the caller's fetch), else None: the one test that a
    landing happened (R6-2, D9: a sha a result names that origin does not hold is no landing)."""
    full = git("rev-parse", "-q", "--verify", f"{sha}^{{commit}}", check=False) if sha else ""
    return full if full and sh(["git", "merge-base", "--is-ancestor", full, f"origin/{MARCH}"]).returncode == 0 else None

def landed_item(item, sha):
    """A queued item is on origin as `sha`: its bookkeeping, keyed by the pushed commit, and its patch confirmed. A sha
    origin does not hold books nothing and returns False (the caller's OTHER)."""
    full = on_origin(sha)
    if full is None:
        event("not-landed", hold=item["hold"], sha=str(sha)[:40], why="origin/wt2 does not hold it")
        return False
    # the event first (red 14): a kill before unqueue leaves the item for reconcile, which books it once
    if not any(e["kind"] == "landed" and e.get("approved") == item["sha"] for e in events()):
        event("landed", hold=item["hold"], hold_id=item["hold_id"], commit=full, unlocked=item.get("unlocked", 0),
              source=item["kind"], approved=item["sha"])
    # the labels it adds frozen before it leaves the queue (the oracle): from its measured answers, or replayed; a freeze
    # that fails leaves the item queued for reconcile's next round, and every measurement naming them fails, located
    freeze(full, item.get("answers"))
    if next(iter(patch_ids(f"{full}^!")), "") != item["patch_id"]:   # what landed is not what was approved: the climb stops for Dale
        write_atomic(os.path.join(STATE, "PAUSE"), f"{full[:10]} landed with a patch other than the approved {item['sha'][:10]}'s\n")
        for_dale("a landing's patch differs from its approval", f"{item['hold']}: approved {item['sha']} (patch "
                 f"{item['patch_id']}), landed {full}. Default taken: paused until `bash dev/climb/launch.sh resume`.")
        event("patch-mismatch", sha=full, approved=item["sha"])
    ran = item.get("src_verified")
    if item.get("fixfirst"):   # the fix-first entry the move was for, cleared; a src-test red only if its file ran green
        def clear(ff):
            for f in list(ff):
                if f["key"] != item["hold"]:
                    continue
                if f["key"].startswith("src-test ") and not set(f.get("tests", [])) <= set(ran or []):
                    event("fixfirst-kept", key=f["key"][:160], why="its landing's check did not run its file green")
                    continue
                ff.remove(f)
        update_json("fixfirst.json", [], clear)
    if item.get("src_ring") is not None:   # the ring's state its fill leaves (T2): the position past what it considered, and
        write_atomic(os.path.join(STATE, SRC_RING), json.dumps(dict(item["src_ring"], commit=full)))   # what it carried
    if ran is not None:   # exactly the files its check reported it ran green (the operator's finding 5)
        src_ran(full, ran, "landing")
        src_flaky_passed([f for f in ran if f in src_flaky_files()])
    else:   # no records of the check (a killed lander's reconcile, refused records): nothing claimed (D9)
        event("src-ran-unknown", commit=full[:12], hold=item["hold"])
    update_json("handoffs.json", {}, lambda hs: hs.pop(item["hold_id"], None))
    if item.get("rows") and os.path.exists(item["rows"]):   # every row it measured, at the landed commit (item 8)
        advance(read_cases(item["rows"]), full, f"the landing of {item['hold'][:80]}")
    if item.get("audit"):
        audit_landed(item["audit"]["n"], item["audit"]["range"], item["audit"]["so"])
    # the item leaves the queue LAST (spec v18 Q6, the round-15 operator's finding 5): a lander killed before here leaves
    # it queued, and reconcile's replay of landed_item makes the whole bookkeeping again (the `landed` event is booked
    # once; the entry's removal, the ring's write_atomic, src_ran's newer-only update and advance's rows are each the
    # same done twice)
    unqueue(item)
    git("branch", "-D", item["branch"], check=False)
    draw_map(os.path.join(STATE, "map.html"))   # D29: after every landing
    return True

def reconcile():
    """Every lander start: what a killed lander left. A queued item whose patch is on origin gets its bookkeeping (the
    landed event is written before the item leaves the queue, so that is the one source of a landing); an audit whose
    entry is on origin has its findings filed; a park with no case set records the one it stands for now."""
    fetch()
    for item in state_json("ready.json", []):
        if "sha" not in item:   # queued with no pinned sha: never landed blind; its hold re-climbs from its branch
            drop(item, "unpinned", "it was queued with no pinned sha, so nothing ties its branch to what was approved", stop=False)
            continue
        hit = patch_ids(f"{item['base']}..origin/{MARCH}").get(item["patch_id"])
        if hit:
            landed_item(item, hit)
    oracle_reconcile()
    saved = state_json("audit-saved.json", {})
    if saved.get("range") and "areas" in (saved.get("so") or {}):
        head = saved["range"].split("..")[1]
        if re.search(rf"^## .* audited through {re.escape(head)}\b", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M):
            audit_landed(saved.get("n", 0), saved["range"], saved["so"])
    hs = {h["id"]: h for h in holds()}
    update_json("parked.json", {}, lambda p: [ent.setdefault("cases", members(hs[i])) for i, ent in p.items() if i in hs])

def oracle_reconcile(origin=None):
    """Every lander start (the oracle): an index line whose label origin's corpus registers no more is dropped first (R4);
    then each label origin's corpus registers that the store does not answer as origin registers it (no line, or a line
    of another source or another text of its unit file: a hand landing, a killed lander's freeze, a unit file edited in
    place) is frozen by a replay of its source commit, one process a label; a snapshot label the store does not hold is
    the store's own gap, named once (a snapshot edit is a key change: every measurement fails, located, naming the
    `snapshot` field and the one replay, oracle-replay). No stale answer is served as stored (spec v14 V2, D9)."""
    origin = origin or git("rev-parse", f"origin/{MARCH}")
    if not os.path.exists(os.path.join(ORACLE, "bootstrap")):
        return
    oracle_drop(set(oracle_index()) - labels_at(origin))   # a line whose label origin registers no more: dropped (R4)
    by = {}
    for l, c in oracle_unanswered(origin).items():
        by.setdefault(c, []).append(l)
    for c, ls in sorted(by.items(), key=lambda x: x[0] or ""):
        if c is None:
            alarm("oracle-gap", "snapshot labels the store does not answer", f"{len(ls)} label(s) of origin's snapshot are in "
                  f"no unit of the store, e.g. {sorted(ls)[0]}. Default taken: each measurement naming them fails, located; {REPLAY}.")
            continue
        freeze(c)

def rebased_check(item):
    """When origin moved past an item's base, the item rebased onto origin is measured before it ships (7): two moves
    approved on one base, each sound alone, can break a case together. One tree (O8), the candidate rebased onto
    origin, under one acquisition of the measurement lock, judged against the table alone (item 8); every label whose
    outcome there differs from the table is measured at origin itself before it is charged or counted (confirmed()):
    a loss origin shares is origin's, never the item's. Every case of its hold passing already, the item is done by
    another landing (D5) and dropped with no stop; a conflict is the queue's order, no stop either. Its verdict is
    kept on the item by origin's sha, so a round that does not land re-measures nothing (red 7, operator 2), and no
    change but dev/AUDIT.md's needs one. A run that wrote nothing is run once more before it is the move's (O14).
    The commit measured (or, with no re-measure, the commit replayed onto origin by the same merge) is kept on the item
    as `commit`, the one commit dev/ship.sh lands for it (WT_SHIP_EXPECT: one merge and one regeneration a landing, the
    lander's, A7-5). Returns (problems, stop)."""
    origin = git("rev-parse", f"origin/{MARCH}")
    v = item.get("rebased") or {}
    if v.get("origin") == origin and "commit" in v:
        return v["problems"], v["stop"]
    if item["kind"] != "move":   # an audit's entry or a commit made by hand: replayed onto origin by the same merge, each
        at, why = origin, None   # of its commits in order, and never measured (A7-5: ship.sh lands what the lander made)
        with julia_slot("verify", first=True):   # its regen is Julia as _wtland: never beside a measurement (D31, O8-4)
            for c in [] if origin == item["base"] else git("rev-list", "--reverse", f"{item['base']}..{item['sha']}").splitlines():
                at, why = rebased(f"{c}^", c, at)
                if at is None or why:
                    break
        at = item["sha"] if origin == item["base"] else at
        problems = [why] if why else [] if at else [f"it does not apply on origin {origin[:10]} (git merge-tree: a conflict)"]
        unqueue(item, rebased={"origin": origin, "problems": problems, "stop": bool(why), "commit": at})
        return problems, bool(why)
    if origin == item["base"] or {c[3] for c in changes(item["base"], origin)} <= {"dev/AUDIT.md"}:
        at, why = rebased(item["base"], item["sha"], origin) if origin != item["base"] else (item["sha"], None)
        problems = [why] if why else [] if at else [f"it does not apply on origin {origin[:10]} (git merge-tree: a conflict)"]
        stop = bool(why)
        unqueue(item, rebased={"origin": origin, "problems": problems, "stop": stop, "commit": at})
        return problems, stop
    h = item.get("h") or {"key": item["hold"], "cases": []}
    labels = set(item.get("labels", [])) | stratified() | set(h["cases"])
    before = {l: r for l, (r, _) in table().items()}
    kw, fault, at = {}, None, None
    if h["cases"] and all(before.get(l, ("", ""))[1] == "passed" for l in h["cases"]):
        problems, fault = ["done by another landing: every case of its hold passes at origin"], "done"
    else:
        keep = os.path.join(STATE, "deltas", f"land-{item['hold_id']}-{origin[:10]}.answers.tsv")   # its added labels' answers
        for _ in range(2):
            unlocked, problems, rows, fault, at = measure_candidate(h, item["base"], item["sha"], labels, before,
                                                                    f"land-{item['hold_id']}", onto=origin, keep=keep)
            if fault != "output":
                break
        if not problems:
            kw = {"rows": os.path.join(STATE, "deltas", f"land-{item['hold_id']}-{origin[:10]}.tsv"), "unlocked": len(unlocked),
                  "answers": keep}
            write_atomic(kw["rows"], cases_text(rows))
    stop = fault not in ("conflict", "done")   # queue order, or another landing's, never the move's (operator 3)
    unqueue(item, rebased={"origin": origin, "problems": problems, "stop": stop, "commit": at}, **kw)
    return problems, stop

def d14_red():
    """D14's band, origin's dev/check.sh D14_RED, read where dev/ship.sh reads it."""
    m = re.search(r"^D14_RED=(\d+)", git("show", f"origin/{MARCH}:dev/check.sh"), re.M)
    if not m:
        raise ClimbError(f"origin/{MARCH}:dev/check.sh names no D14_RED")
    return int(m.group(1))

def d14_binds():
    """D17 for D14 (A7-2): one note for Dale each time the share of the last d14_share[0] checks that read red on D14's
    time alone passes d14_share[1], or falls back under it, naming their critical paths and Dale's band; never a note a
    check (the band is Dale's and is not moved here)."""
    n, share = cfg()["d14_share"]
    checks = [e for e in events() if e["kind"] == "ship" and (e.get("d14") or {}).get("verdict") and not (e.get("probe") or {}).get("battery")][-n:]
    if len(checks) < n:
        return
    reds = [e for e in checks if e["d14"]["verdict"] == "red"]
    over = len(reds) >= share * n
    if bool(state_json("alarms.json", {}).get("d14-binds")) != over:
        update_json("alarms.json", {}, lambda a: a.__setitem__("d14-binds", over))
        event("alarm", name="d14-binds", over=over, reds=len(reds), of=n)
        paths = ", ".join(f"{e.get('path')} s" for e in checks)
        for_dale("D14's band binds the climb's landings" if over else "D14's band no longer binds the climb's landings",
                 f"{len(reds)} of the last {n} landing checks read red on D14's time alone (band {d14_red()} s, Dale's; "
                 f"their critical paths: {paths})." + (" Default taken: approved commits stay queued, each tried again after "
                 f"d14_backoff_s; at queue_cap the slots idle and spend nothing. The band, or the check's rates "
                 f"(council/d14-rates.patch), is Dale's to change." if over else " Default taken: the lander lands as before."))

def landing_set(item):
    """The test set a landing of the item runs (measure.src_set, measure.src_handed), computed from origin's code and the
    lander's own state before the check (the landing-check ruling's R1, R6) and kept for its `ship` event. A set that
    cannot be made (`why`: no score's record, no band in check.sh, no warm-up) is a located refusal: (the set, None), the
    item waits, never a check of every file that D14 cannot pass (spec v18 Q2, the round-15 architect's finding 3); a
    fault of the driver's raises, located, never a check. Returns (the set, its files or None)."""
    h, sha = git("rev-parse", f"origin/{MARCH}"), item["rebased"]["commit"]
    ss = src_set(h, sha, item.get("hold_id"))
    return (ss, None) if "share" not in ss else (ss, src_handed(ss, h, sha))

def hand_set(item, files, ss):
    """The set's two files in the lander's state, named to dev/ship.sh (door.SET_ENV, door.COSTS_ENV), which its door
    process gives the land job in its run directory, a file the check's user reads and cannot write: the set (its header
    the commit it was made for, which dev/check.sh compares with its HEAD) and the score's costs ordering the shards."""
    d = os.path.join(STATE, "ship")
    os.makedirs(d, exist_ok=True)
    # the newest SHIP_KEEP attempts' files kept, an attempt's files grouped by their stamp (spec v17 Z7)
    prune_newest(os.path.join(d, "*"), SHIP_KEEP, group=lambda p: os.path.basename(p).split(".", 1)[0])
    t = f"{int(time.time())}-{os.getpid()}"
    setp, costp = os.path.join(d, f"{t}.set"), os.path.join(d, f"{t}.costs")
    # each known red that runs in the set, by its entry's failing tests (each counted: spec v19 Q1): a row red only there is the known red's,
    # never this change's (dev/src_verdict.sh, spec v17 Z1)
    known = sorted({(f, tuple(e.get("fails") or [e["first"]])) for f, es in src_reds().items() if f in files for e in es if e.get("first")})
    write_atomic(setp, f"# head {item['rebased']['commit']}\n# score {ss.get('hs', 'none')}\n" +
                 "".join(f"# known {f}\t" + "\t".join(fs) + "\n" for f, fs in known) + "".join(f + "\n" for f in files))
    rec = src_latest(git("rev-parse", f"origin/{MARCH}"))
    write_atomic(costp, "".join(f"{f}\t{r[1]}\n" for f, r in sorted(rec[2].items()) if r[0] == "passed" and r[1] is not None) if rec else "")
    return setp, costp

R3_ROLE = "measure"   # the role a red file is run at origin's head as (R3): the lander's measurements' (src_red_at)

def shard_records(text):
    """A check's shards' records as ship.sh passed them (`shard <name>` before each shard's own lines): {file: outcome},
    outcome passed, failed, or unfinished (a `started` with no row: its shard ended during the file). The records are
    the candidate's processes' to write: the driver believes a green row only for a file of the set it handed (the
    verified record) and a red only as far as a run of origin's code at origin's head bears it out (R3). None when no
    record was passed (D9: never assumed)."""
    if not text:
        return None
    out, cur = {}, None
    for l in text.splitlines():
        f = l.split("\t")
        if f[0] == "shard":
            if cur is not None:
                out.setdefault(cur, "unfinished")
            cur = None
        elif f[0] == "started" and len(f) == 2:
            if cur is not None:
                out.setdefault(cur, "unfinished")
            cur = f[1]
        elif f[0] == "row" and len(f) in (5, 6) and f[1] == cur:   # a file's row carries its canary as the file (Z4)
            out[cur] = "passed" if f[2] == "passed" else "failed"; cur = None
    if cur is not None:
        out.setdefault(cur, "unfinished")
    out.pop(CANARY, None)   # the judge's canary: dev/check.sh voided the check when it read wrong (A13-5)
    return out

def verified_rows(item, recs, files):
    """The verified record of a landing's check (the operator's round-13 finding 5, the architect's 7a, spec v17 Z2): the
    files its records REPORT green, believed only when the records name exactly the set handed (`files`): a row outside
    it, or a file of it with no record, refuses them all (`src-records-refused`), never "every file"."""
    if recs is None:
        return None
    outside, missing = sorted(set(recs) - set(files)), sorted(set(files) - set(recs))
    if outside or missing:
        event("src-records-refused", hold=item["hold"], outside=outside[:20], missing=missing[:20])
        return None
    return sorted(f for f, o in recs.items() if o == "passed")

def origin_red(item, slot, ss, recs):
    """R3 with R10: a check red on its test files alone, every red file outside the move's own (and inside the set it
    ran), runs those files at origin's head in one process (src_red_at, R3_ROLE). Every one red there: origin's: each
    located at once (src_locate: the fix-first filed, the file into R) and the item checked again without them,
    uncharged (no stop, no backoff: it keeps its place). A file red in the shard and green alone at origin's head is the
    move's own red, as before, unless it read so twice within fixfirst_max_landings landings (src-differs.json holds
    each file's landing counts at origin's head when it read so, those outside the window dropped: "twice" never means
    "ever twice, months apart", the round-14 architect's finding 8, spec v17 Z7; the window is the span a known red
    ages in before it is overdue): then the note and R until it passes twice (src_flaky), uncharged. Returns True when the item goes on uncharged, False when the red is the move's own."""
    # a check red only at known reds' own listed failing tests is green (dev/src_verdict.sh, spec v17 Z1, v19 Q1), so a
    # red row here is a new red: of a known red's file too, when any failure, counted, is not one its entry lists
    red = {f for f, o in (recs or {}).items() if o != "passed"} or None
    own, ran = set(ss.get("own", [])), set(ss.get("ran", []))
    if not red or red & own or not red <= ran:
        event("src-own-red", hold=item["hold"], red=sorted(red or []), why="no record names a red file" if not red else
              "a red file is the move's own" if red & own else "a red file outside the set it ran (its records refused)")
        return False
    h = git("rev-parse", f"origin/{MARCH}")
    with julia_slot("verify", first=True):
        try:
            v = src_red_at(sorted(red), h, f"r3-{item['hold_id']}-{h[:8]}", role=R3_ROLE)
        except ClimbError as e:   # no verdict at origin: the move's own, as before (the driver's fault noted)
            event("src-own-red", hold=item["hold"], red=sorted(red), why=f"its run at origin's head wrote no result: {str(e)[:200]}")
            return False
        at_h = {f: v[f][1] or v[f][0] for f in red if v[f][0] != "passed"}
        if at_h:
            src_locate(at_h, h, R3_ROLE)
        nr = sorted(f for f in red if f not in at_h)
        ok, twice = not_reproduced(item, nr, h, "red in a landing's shard and green run alone at origin's head") if nr else (True, [])
    event("src-origin-red", hold=item["hold"], red=sorted(red), at_origin=sorted(at_h), flaky=twice, origin=h[:8], uncharged=ok)
    return ok

def not_reproduced(item, files, h, how):
    """ONE rule for a red or a void of `files` outside the move's own that does not reproduce at origin's head (spec v18
    Q3; the round-15 operator's finding 3: a void had none, so a shard killed once by the OS stopped an innocent move).
    src-differs.json keeps each file's landing counts at origin's head when it read so, those outside
    fixfirst_max_landings landings dropped ("twice" never means "ever twice, months apart", spec v17 Z7). A file that read
    so twice within the window is a flaky known red (src_flaky: the note and R until it passes twice), uncharged.
    Otherwise the item's FIRST such failure checks it again, once, uncharged (`rechecked`), and a failure on that second
    check is the move's own, read before anything is counted: a red the move makes reproduces with it, and an item's own
    two checks never make a file "twice". Returns (uncharged, the files filed flaky)."""
    if item.get("rechecked"):   # it read so again on the item's second check: it reproduces with the move, which made it
        event("src-own-red", hold=item["hold"], red=files, why=f"{how}, again on its second check")   # (never counted twice)
        return False, []
    n, w = landings_at(h), cfg()["fixfirst_max_landings"]
    def seen(d, f):   # the landing counts at which `f` read so, within the window (a count of the old form: none)
        return [x for x in (d.get(f) if isinstance(d.get(f), list) else []) if n - x < w]
    differs = state_json("src-differs.json", {})
    twice = [f for f in files if len(seen(differs, f)) + 1 >= 2]
    update_json("src-differs.json", {}, lambda d: [d.__setitem__(f, seen(d, f) + [n]) for f in files])
    for f in twice:
        src_flaky(f, h, f"{how}, twice", f"{f}: {how}")
    rest = [f for f in files if f not in twice]
    if not rest:
        return True, twice
    unqueue(item, rechecked=True)
    event("src-recheck", hold=item["hold"], files=rest, why=how)
    return True, twice

def void_files(text):
    """The files of a check's void shards, as dev/src_verdict.sh listed them (`void\t<file>` lines, the shard record
    ship.sh passes as src_records.void.out): the files whose process the check could not believe (spec v17 Z3)."""
    return sorted({l.split("\t", 1)[1] for l in (text or "").splitlines() if l.startswith("void\t")})

def origin_void(item, ss, vfiles):
    """R3 for a void process (spec v17 Z3, the round-14 operator's finding 3): its files outside the move's own run at
    origin's head (src_red_at, R3_ROLE). Void there: origin's, narrowed to the file whose presence voids the process
    (src_void_split, one process a half) and located over commits as a red is (src_locate), its fix-first filed and the
    item checked again without it, uncharged. Not void there: the move's own, as before. Returns True when uncharged."""
    own = set(ss.get("own", []))
    at = sorted(set(vfiles or []) - own)
    if not at:
        event("src-own-red", hold=item["hold"], red=sorted(vfiles or []), why="a void process of the move's own files alone" if vfiles else "no record names the void process's files")
        return False
    h = git("rev-parse", f"origin/{MARCH}")
    task = f"r3v-{item['hold_id']}-{h[:8]}"
    with julia_slot("verify", first=True):
        try:
            v = src_red_at(at, h, task, role=R3_ROLE)
            why = next((v[f][1] for f in at if v[f][0] == "void"), None)
        except SrcVoid as e:
            why = str(e)
        except ClimbError as e:
            event("src-own-red", hold=item["hold"], red=at, why=f"its void files' run at origin's head wrote no result: {str(e)[:200]}")
            return False
        if why is None:   # not void at origin's head: the one rule of what does not reproduce there (spec v18 Q3)
            ok, flaky = not_reproduced(item, at, h, "void in a landing's shard and not at origin's head")
            event("src-origin-void", hold=item["hold"], files=at, origin=h[:8], why="not void at origin's head", flaky=flaky, uncharged=ok)
            return ok
        fs, why = src_void_split(at, h, task, R3_ROLE) if len(at) > 1 else (at, why)
        if len(fs) == 1:
            src_locate({fs[0]: f"void: {why}"[:400]}, h, R3_ROLE)
        else:
            add_fixfirst([{"key": f"src-test {' '.join(fs)} void together at {h[:8]}", "tests": fs, "first": "void",
                           "culprit": None, "flaky": False, "hold": None, "why": f"these test files void their process together at {h[:10]}: {why[:300]}"}])
    event("src-origin-void", hold=item["hold"], files=fs, origin=h[:8], why=why[:300])
    return True

def unverified_binds(behind, files):
    """One note for Dale each time the landings standing with a test file unrun since (measure.src_unverified) reach
    src_unverified_max, and one when they fall back: at the bound the lander lands nothing until a score (or a landing's
    check) runs those files green (R12: a run of failed scores never grows the unverified landings past it)."""
    over = behind >= cfg()["src_unverified_max"]
    if bool(state_json("alarms.json", {}).get("src-unverified")) != over:
        update_json("alarms.json", {}, lambda a: a.__setitem__("src-unverified", over))
        event("alarm", name="src-unverified", over=over, behind=behind, files=files)
        for_dale("landings wait: test files unrun past src_unverified_max" if over else "test files are verified again",
                 (f"{behind} landings stand since {', '.join(files)} last ran green (src_unverified_max "
                  f"{cfg()['src_unverified_max']}). Default taken: the lander lands nothing until a score's src part runs "
                  "them; the score keeps its schedule." if over else "Default taken: the lander lands as before."))

def fixfirst_binds(overdue):
    """One note for Dale each time the set of known reds past fixfirst_max_landings changes (core.fixfirst_overdue), and
    one when none is again: while one stands, the climb admits fix-first items alone (core.admits). The note states
    what is true when it is written (the operator's round-13 finding 8): each red's age in landings, whether a hold
    climbs it or is parked, what the queue holds that can land and what waits."""
    keys = sorted(f["key"] for f in overdue)
    if state_json("alarms.json", {}).get("fixfirst-age") == (keys or None):
        return
    update_json("alarms.json", {}, lambda a: a.__setitem__("fixfirst-age", keys or None))
    event("alarm", name="fixfirst-age", over=bool(keys), keys=[k[:120] for k in keys])
    if not keys:
        for_dale("no known red is past its age", "Default taken: the climb admits every approved move again."); return
    hs = {h["key"]: h for h in holds()}
    q = state_json("ready.json", [])
    adm = [x for x in q if admits(x, overdue)]
    def hold_state(k):
        h = hs.get(k)
        return ("no hold (a G2 loss or a red of the src part, filed)" if h is None else
                f"parked ({str(h['parked'].get('why', ''))[:120]}): `python3 dev/climb/climb.py unpark {h['id']}`" if h["parked"] else
                "claimed by a slot" if os.path.exists(os.path.join(STATE, "claims", h["id"])) else "free for the next slot")
    for_dale("a known red outlived its landings: the climb admits its fix alone",
             f"{len(keys)} known red(s) past fixfirst_max_landings ({cfg()['fixfirst_max_landings']} landings): " +
             "; ".join(f"{f['key'][:160]} ({f['age']} landings; its hold: {hold_state(f['key'])})" for f in overdue) +
             f". The queue holds {len(adm)} item(s) that can land (fix-first) and {len(q) - len(adm)} that wait; every slot "
             "climbs fix-first holds alone. Default taken: the lander lands fix-first items and hand fixes enqueued "
             "`--fixes <key>` alone; other approved work keeps its place.")

def near_band():
    """D17: green checks near D14's band are a finding, early; the median of the last five, never one check (O12),
    noted once when it passes near_band of the band and again only when it rises near_band_step more (O5-11)."""
    greens = sorted(e["path"] for e in [x for x in events() if x["kind"] == "ship" and x.get("path") and not (x.get("probe") or {}).get("battery")
                                        and x.get("result", "").startswith("LANDED")][-5:])
    if len(greens) < 5:
        return
    med, prev = greens[2], state_json("alarms.json", {}).get("near-band-state") or [False, 0]
    over = med > cfg()["near_band"] * d14_red()
    if over and (not prev[0] or med >= prev[1] + cfg()["near_band_step"]):
        event("alarm", name="near-band")
        for_dale("landing checks run near D14's band", f"The median of the last five green checks' critical paths, "
                 f"{med} s ({greens}), is past {cfg()['near_band']:.0%} of D14's {d14_red()} s. Default taken: the lander "
                 "keeps landing; the probe events and the checks' paths re-derive its band.")
        prev = [True, med]
    update_json("alarms.json", {}, lambda a: a.__setitem__("near-band-state", prev if over else [False, 0]))

def land_tree():
    """The lander's worktree of the main repository, the lane ship.sh lands from (`climb-land`): made once, origin's
    environment written by content (no Pkg runs as Dale), reset before each item."""
    path = os.path.join(WORKTREES, "climb-land")
    if not os.path.isdir(path):
        common_write("the lander's worktree")
        git("worktree", "add", "-q", "--detach", path, f"origin/{MARCH}")
    for n, text in environment(git("rev-parse", f"origin/{MARCH}")).items():
        safe_write(os.path.join(path, n), text)
    return path

def land_round():
    """One round: what a killed lander left, then the queue in order; each item through its pinned sha, its gates read
    again, ship.sh's admission, a re-measure when origin moved past its base, the quiet probe and the check. The
    lander runs no agent (item 11): the judge's eval and the audits run from the score tick, and an item needs the
    approvals that held when it was approved, so no agent's state, the week's half or the budget stops a landing (D51).
    The line stop is ship.sh's to apply (--admissible). Returns 3 when nothing waits or nothing could land."""
    if pause() or waits("lander") or not power_ok():   # every lander:* backoff, by one predicate (Z1)
        return 3   # no rebased measurement or landing check starts while the power rule stops work (O8-3)
    reconcile()
    overdue = fixfirst_overdue()   # R4, R11: a known red past its age, the lander lands its fix alone
    fixfirst_binds(overdue)
    origin = git("rev-parse", f"origin/{MARCH}")
    behind, files = src_unverified(origin)   # R5, R12: landings standing with a test file unrun since, held at the bound
    unverified_binds(behind, files)
    if behind >= cfg()["src_unverified_max"]:
        return 3
    scored = origin_scored()
    if not scored:   # no score's record at origin's head: nothing lands, every item keeps its place (spec v18 Q2)
        alarm("land-no-score", "landings wait for the first score", f"origin's head {origin[:10]} has no score's src record, so "
              "no landing's test set can be made. Default taken: nothing lands or climbs until the score's src part runs.")
        return 3
    for item in list(state_json("ready.json", [])):
        if not admits(item, overdue, scored):   # it keeps its place: approved work waits, never sent back (A7-2); one event
            if item.get("skipped") != [f["key"] for f in overdue]:
                unqueue(item, skipped=[f["key"] for f in overdue])
                event("land-skipped", hold=item["hold"], why="a known red is overdue", overdue=[f["key"][:120] for f in overdue])
            continue
        slot = land_tree()
        if git("rev-parse", "-q", "--verify", f"refs/heads/{item['branch']}", check=False) != item["sha"]:
            drop(item, "ref-moved", f"its branch {item['branch']} no longer points at the approved {item['sha']}")
            for_dale("a ready branch moved", f"{item['branch']} moved off the approved {item['sha']}: something wrote "
                     "the git refs between approval and landing. Default taken: the item is dropped and its hold re-climbed.")
            continue
        bad = item_problems(item)   # before the commit is checked out anywhere (red 1)
        if bad:
            drop(item, "landing-red", "the pinned commit fails its gates at landing:\n" + "\n".join(bad[:20])); continue
        git("checkout", "-q", "-f", "--detach", item["sha"], cwd=slot)
        # the environment land_tree() wrote stays (ENV_FILES, round 13's S1): LocalPreferences.toml is untracked and
        # ignored by no rule of the repository's own, so a clean removed it, layer() then keyed a layer by the Manifest
        # alone and built it inside the round, and the check, given the lane's files by dev/ship.sh, loaded no layer
        # prepared from land_tree's environment: 16-17 s of WasmTarget's image in the judged load of every landing
        git("clean", "-q", "-fd", *[a for n in ENV_FILES for a in ("-e", f"/{n}")], cwd=slot, check=False)
        # the cheap refusals first, ship.sh's and the memory's, before a re-measure or a stop (operator 2, red 7)
        (kind, arg), out = admissible(slot)
        pr = None
        if kind == "ADMISSIBLE":
            if pressure() >= 4:   # a critical machine measures nothing; a failed probe, so the quiet alarm covers it (O1)
                event("quiet-probe", ok=False, reason="memory", pressure=pressure(), hold=item["hold"])
                return 3
            try:
                bad, stop = rebased_check(item)
            except OracleGap as e:   # the store does not answer origin's labels, so a moved item cannot be re-measured (S5):
                # refused here, located, for this item alone; it keeps its place, one event while the gap reads the same,
                # and the gap's own note (the score's: one gap rule, spec v14 V5); the round goes on to the next item
                why = str(e)[:300]
                if item.get("gap") != why:
                    unqueue(item, gap=why)
                    event("land-gap", hold=item["hold"], sha=item["sha"][:10], why=why)
                alarm("oracle-gap", "the store does not answer origin's labels: no score, and no re-measure of a moved item",
                      f"{str(e)[:1500]}\nDefault taken: every measurement fails, located, and nothing is recorded or landed "
                      "that needs one until the store answers them.")
                continue
            if bad:
                drop(item, "landing-red" if stop else "done-elsewhere", "rebased onto origin:\n" + "\n".join(bad[:20]), stop=stop); continue
            item = next(x for x in state_json("ready.json", []) if x["branch"] == item["branch"])   # its rebased rows
            git("checkout", "-q", "-f", "--detach", item["rebased"]["commit"], cwd=slot)   # the commit it measured (A7-5)
            ss, files = landing_set(item)   # the set the check runs, chosen before it from origin's code and state (R1, R6)
            if files is None:   # no set can be made: the item keeps its place, one note a why (spec v18 Q2)
                event("land-no-set", hold=item["hold"], why=ss.get("why", "")[:300])
                alarm(f"land-no-set-{hashlib.sha1(ss.get('why', '').encode()).hexdigest()[:8]}", "a landing's test set cannot be made",
                      f"{ss.get('why', '')[:500]}. Default taken: the item keeps its place and nothing lands until a set can be made.")
                return 3
            if ss.get("refuse"):   # own ∪ unscored alone predict past D14's band: the move's own, before any Julia (located)
                drop(item, "landing-red", f"its own test files {ss['own']} and the unscored {ss['unscored']} predict "
                     f"{ss['own_unscored']['path']} s at the score's costs, past D14's band of {d14_red()} s: split the file "
                     "or the move"); continue
            item["src_ring"] = {"hs": ss["hs"], "pos": ss["pos_next"], "carry": ss["dropped"]} if "share" in ss else None
            unqueue(item, src_handed=files, src_ring=item["src_ring"])
            pr, res, (crc, path, split), out = land(slot, item, hand_set(item, files, ss))
            if res is None:
                return 3   # not quiet: everything resumed at once, the next round tries again
            rtext = pr.pop("records", None)
            recs, vfiles = shard_records(rtext), void_files(rtext)
            # the verified record: the files the check REPORTS it ran green, of the set handed (the operator's round-13
            # finding 5, the architect's 7a): never the set assumed, never "every file"; a row naming a file outside
            # the set refuses them all (a check that ran what it was not handed, L228)
            # and exactly the set (spec v17 Z2): a file of the set with no record refuses them too (red's round-14 p5:
            # one file claimed its red sibling away from every shard)
            item["src_verified"] = verified_rows(item, recs, files)
            fetch()
            kind, arg = res
        else:
            crc = path = split = ss = recs = vfiles = None
        ship_event(item, pr, kind, arg, crc, path, out, split, ss)
        if kind == "LANDED" and recs and any(o != "passed" for o in recs.values()):   # green with known reds red (Z1)
            event("src-known-red", hold=item["hold"], red=sorted(f for f, o in recs.items() if o != "passed"))
        if kind == "LANDED":
            if landed_item(item, arg):
                near_band(); recovered("lander")
                # the next landing's layer, of the head this one made, built now under the verify lock alone, never on
                # that landing's critical path with both measurement locks held (round 9's architect, S3)
                try:
                    with julia_slot("verify", first=True):
                        layer(land_tree())
                except door.DoorError as e:   # the next landing builds it again before its check, failing there loudly
                    event("land-layer-failed", error=str(e)[:300])
                return 0
            kind, arg = "OTHER", f"its result named {arg}, which origin/{MARCH} does not hold"
        if kind == "D14" and set((ss or {}).get("estimated", [])) & set((ss or {}).get("own", [])):
            # an own file no score ran has no known cost: its check past the band is the move's own, from its set's own
            # record, never from output (the design's B.2), never a D14 wait
            drop(item, "landing-red", f"its own unscored test files {sorted(set(ss['estimated']) & set(ss['own']))}, no score "
                 f"having costed them, read the check {arg} s, past D14's band of {d14_red()} s: split them"); continue
        if kind == "OWN" and arg == "tests" and ss and origin_red(item, slot, ss, recs):
            continue   # origin's red, located and filed: the item is checked again without it next round, uncharged
        if kind == "OWN" and arg == "void" and ss and origin_void(item, ss, vfiles):
            continue   # origin's void, located and filed: as R3's red (spec v17 Z3), uncharged
        if kind == "D14":   # red on D14's time alone: never the move's (A7-2, O7-3, R7-4)
            # approved work is never sent back for time: the item keeps its queue place, its approvals, its rebased
            # verdict and tree, and is tried again after the lander's backoff; while queue_cap items wait the slots idle
            # (no tokens); whether D14 binds the climb is Dale's band, told once a state (d14_binds)
            unqueue(item, d14=(item.get("d14", []) + [[stamp(), int(arg) if (arg or "").isdigit() else 0]])[-cfg()["d14_share"][0]:])
            back_off("lander", "d14", why="D14", secs=cfg()["d14_backoff_s"], note_at=0)
            d14_binds()
            return 3
        if arg == "hourly":
            continue
        if kind == "NETWORK" or arg in ("held", "linestop", "stale-ship", "busy", "moved"):   # moved: re-measured next round
            if kind == "NETWORK":   # never the item's fault: it stays queued (17)
                back_off("lander", why=f"dev/ship.sh could not reach origin ({arg}): {out[-300:]}", note_at=1)
            return 3
        if kind == "NOTHING":   # its patch is on origin (booked there), or it carries nothing
            hit = patch_ids(f"{item['base']}..origin/{MARCH}").get(item["patch_id"])
            landed_item(item, hit) if hit else drop(item, "nothing", out, stop=False)
            continue
        if kind == "OTHER":
            tries = item.get("tries", 0) + 1
            if tries < cfg()["other_tries"]:
                unqueue(item, tries=tries); return 3
            # ship.sh's or the door's own faults (a door failure, a push hung, no result, a tree other than measured):
            # never the item's stop, and the lander waits before its next round (O6-4)
            drop(item, "landing-failed", f"dev/ship.sh failed {tries} times outside the check ({arg}): " + out[-800:], stop=False)
            back_off("lander", why=f"dev/ship.sh OTHER {arg}"); return 3
        failed = os.path.join(COMMON, "wt-ship-failed", "climb-land")
        detail = "\n".join([l for f in sorted(glob.glob(f"{failed}/*.out")) for l in open(f, errors="replace").read().splitlines()
                             if re.search(r"Error During Test|Test Failed|LOCK BROKEN|✗|FieldError|MethodError", l)][:30])
        drop(item, "landing-red", f"dev/ship.sh: {kind} {arg}:\n{out[-1000:]}\nIts failures:\n{detail}")
    return 3

# ---------------------------------------------------------------- audits (D21), run by the score tick: they only enqueue
def audit_lag():
    heads = re.findall(r"^## .* audited through ([0-9a-f]{7,40})", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M)
    if not heads:
        return 0, None
    n = len(git("log", "--format=%h", f"{heads[-1]}..origin/{MARCH}", "--invert-grep", "--grep=^docs(audit)").splitlines())
    return n, heads[-1]

def audit_due():
    return (audit_lag()[0] >= cfg()["audit_every"] and not backed_off("audit") and not pause() and not week_half()
            and not any(x.get("audit") for x in state_json("ready.json", [])))   # one waits to land: never a second

def audit_entry(so, rng, head):
    """The dev/AUDIT.md entry in L148's form, written by the driver from the auditor's fields, so its area labels,
    its commit and its Resolution are right by construction (audit 98's `Area: the builder` failed L148 twice)."""
    areas = "\n\n".join(f"Area: {label}. {so['areas'][k].strip()}" for k, label in AUDIT_AREAS)
    return (f"## {now().date().isoformat()} — audited through {head} ({rng}: {so['topics'].strip()})\n\n{areas}\n\n"
            f"stopgap in disguise: {so['stopgap'].strip()}\n\nprecedent: {so['precedent'].strip()}\n\n"
            f"Resolution: {so['resolution'].strip()}\n")

def audit():
    """D21: the landings since the last entry, read by one fresh auditor as the score's review user in a clone of
    origin of its own; the driver writes its entry and makes the commit by plumbing (origin's tree with the entry
    added, no work tree), and queues it like any commit (the lander reads its shape again). A failed audit backs off,
    with a note at the second failure; it never loops, and never holds a landing (22)."""
    c = cfg()
    origin = git("rev-parse", f"origin/{MARCH}")
    nums = [int(m.group(1)) for l in git("log", "--format=%s", "-n", "600", origin).splitlines() for m in [re.search(r"audit #(\d+)", l)] if m]
    n = (max(nums) + 1) if nums else 97
    _, prev = audit_lag()
    rng = f"{prev}..{origin[:8]}"
    saved = state_json("audit-saved.json", {})
    if saved.get("range", "").startswith(f"{prev}..") and "areas" in (saved.get("so") or {}):
        rng, n = saved["range"], saved.get("n", n)   # a cut audit lands first, over its own range, under its own number (A98E7)
    commits = git("log", "--format=- %h %s", rng, "--invert-grep", "--grep=^docs(audit)")
    if not commits:
        return
    so = saved.get("so") if saved.get("range") == rng and "areas" in (saved.get("so") or {}) else None
    if so is None:   # an audit whose landing was cut is landed again, never paid for twice
        with door.using("review3"):
            tree = agent_tree("review3", f"audit{n}", "wt2", origin)
            so = ask("audit", f"audit{n}", c["climber_model"], "high", SCHEMA_AUDIT, REVIEW_TOOLS,
                     render("auditor.md", WORKTREE=tree, RANGE=rng, N=n, PREV=prev, COMMITS=commits), tree, "review3")
        if isinstance(so, dict):
            save_json("audit-saved.json", {"range": rng, "n": n, "so": so})
    if not isinstance(so, dict):
        why = "the governor refused the auditor" if so == BUDGET else "the auditor gave no answer twice"
        event("audit-failed", n=n, range=rng, why=why); back_off("audit", why=why, note_at=2); return
    text = git("show", f"{origin}:dev/AUDIT.md") + "\n\n" + audit_entry(so, rng, rng.split("..")[1])
    blob = sh(["git", "hash-object", "-w", "--stdin"], input=text + "\n", cwd=REPO, check=True).stdout.strip()
    tree = tree_of("\n".join(f"100644 blob {blob}\t{l.split(chr(9), 1)[1]}" if l.endswith("\tdev/AUDIT.md") else l
                             for l in sh(["git", "ls-tree", "-r", "--full-tree", origin], check=True).stdout.splitlines()) + "\n")
    sha = git("-c", "user.name=climb", "-c", "user.email=climb@localhost", "commit-tree", tree, "-p", origin, "-m",
              f"docs(audit): audit #{n}: {rng}\n\nCharter: C0\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
    enqueue(sha, f"audit #{n}", "audit", hold_id=f"audit{n}", audit={"n": n, "range": rng, "so": so})
    event("audited", n=n, range=rng, queued=True, findings=len(so["findings"]))

def audit_route(f):
    """Where an audit's finding is filed: None (neither fix-first nor high or medium: it stays on its route in the
    entry), "lead" or "climb". The lead's when it is about a commit's message, trailers or process, not code
    (`about`, which the schema requires: a move cannot rewrite a landed commit, whatever line the finding cites;
    A106E2, anchored at src/julia/show.jl:1, was filed for a climber), when no move may change its file (G5), or when
    it names no line a move can be measured against (A4); else a fix-first a climber takes."""
    if not (f.get("fix_first") or f.get("severity") in ("high", "medium")):
        return None
    if f.get("about") == "process" or not move_rule((f.get("file") or "").strip()) or not isinstance(f.get("line"), int):
        return "lead"
    return "climb"

def audit_rows():
    """door-probe's rows for audit_route: a process finding anchored at a src line goes to the lead, a code finding there
    to the climb, a code finding in dev/climb to the lead. Returns [(check, ok, evidence)]."""
    rows = []
    for what, f, want in (("a finding about a commit's message, anchored at a src line", {"about": "process", "file": "src/julia/show.jl", "line": 1}, "lead"),
                          ("a finding about code at a src line", {"about": "code", "file": "src/julia/show.jl", "line": 1}, "climb"),
                          ("a finding about code in dev/climb", {"about": "code", "file": "dev/climb/core.py", "line": 1}, "lead")):
        got = audit_route(dict(f, severity="medium"))
        rows.append((f"audit: {what} goes to the {want}", got == want, f"routed to {got}"))
    return rows

def audit_landed(n, rng, so):
    """An audit's entry is on origin: its findings are filed (audit_route), fix-first or for Dale, and the map redrawn."""
    event("audited", n=n, range=rng, landed=True, findings=len(so["findings"]))
    save_json("audit-saved.json", {})
    hand, add = [], []
    for f in so["findings"]:
        route = audit_route(f)
        if route is None:
            continue
        path = (f.get("file") or "").strip()
        text = f"{path}:{f.get('line')} {f.get('claim')} Fix: {f.get('fix')} ({f.get('requirement', '')})"
        if route == "lead":   # no move can land it: a landed commit's message, the harness or the rules (G5)
            hand.append(f"- A{n} {f.get('id')}: {text}")
            continue
        add.append({"key": f"audit A{n} {f.get('id')}: {f.get('claim', '')[:110]}", "cases": [], "why": text})
    add_fixfirst(add)
    if hand:
        for_dale(f"audit {n}: findings for a commit made by hand", "\n".join(hand) + "\nDefault taken: the climb goes on; "
                 "these wait for a commit made by hand (a landed commit's message, dev/climb, the rules and the tooling "
                 "are no move's), queued with `climb.py enqueue`.")
    draw_map(os.path.join(STATE, "map.html"))   # D29: after every audit

# ---------------------------------------------------------------- the judge's own hill (Theo: an eval of past failures)
FINDING_RE = re.compile(r"\(A\d+[ES]\d+\)")

def judge_set(n):
    """The eval's defects, kept from run to run so every later run is comparable, and only grown when n grows (6 to 10,
    council round 2): landed fixes of an audit finding that change src/ and stay small, each reverted, a defect an
    audit really found, which the reviewer must refuse."""
    out = state_json("judge-set.json", [])
    if len(out) >= n:
        return out[:n]
    for line in git("log", "-n", "2000", "--format=%H%x09%s", f"origin/{MARCH}").splitlines():
        sha, subj = line.split("\t", 1)
        if not subj.startswith("fix(") or not FINDING_RE.search(subj) or not git("diff", "--name-only", f"{sha}^", sha, "--", "src/"):
            continue
        if any(x["sha"] == sha for x in out):
            continue
        changed = sum(int(a) + int(b) for a, b, *_ in (l.split("\t") for l in git("diff", "--numstat", f"{sha}^", sha).splitlines())
                      if a.isdigit() and b.isdigit())
        if changed <= cfg()["judge_lines"]:
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
            d = json.load(open(p))
            d = json.loads(d["out"]) if "out" in d else d   # a run's record holds claude's stdout as `out` (run_agent)
            so = d.get("structured_output") or d.get("so") or {}
            for f in so.get("findings", []):
                if f.get("severity") in ("high", "medium"):
                    faulted |= set(re.findall(r"\b[0-9a-f]{8}\b", json.dumps(f)))
    heads = re.findall(r"^## .* audited through ([0-9a-f]{7,40})", git("show", f"origin/{MARCH}:dev/AUDIT.md"), re.M)
    out = []
    for e in reversed(events()):
        c = e.get("commit", "")
        if e["kind"] == "landed" and e.get("source", "move") == "move" and c and c[:8] not in faulted and heads and \
                not e.get("hold_id", "").startswith(("audit", "lead-")) and \
                sh(["git", "merge-base", "--is-ancestor", c, heads[-1]]).returncode == 0:
            out.append(c)
        if len(out) >= n:
            break
    return out

def judge_eval(n=None):
    """The blind reviewer (G4) is the climb's one judge that is a model, not a program. It is measured before it gates
    a move and again whenever judge_blob changes: its recall on real past defects (reverted audit fixes),
    which it must refuse, and its approval of the climb's landed moves a later audit passed, which it should approve.
    A missed defect is reviewed once more before it counts. An empty review is infrastructure: left out, never a miss."""
    n = n or cfg()["judge_n"]
    fd = os.open(os.path.join(STATE, ".judge.lock"), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd); return
    try:
        defects, cleans = [], []
        blob = judge_blob()   # each case's verdict kept by (judge, sha), so an eval cut by the budget resumes (A8)
        done = state_json("judge-partial.json", {}) if state_json("judge-partial.json", {}).get("judge") == blob else {"judge": blob}
        ran = [0]   # this tick's reviews: at most judge_per_tick, then the eval resumes at the next tick (A6-8)
        class Tick(Exception):
            pass
        def verdict(kind, sha, before_tree, tree, i):
            """One case, blind (A98E2), in the form every round of the gate has (core.review, A7-10): the tree before and
            the change, a neutral message, origin's dev/climb/ in both trees (the HILL.md the moves are judged by; the
            defects predate it), dev/AUDIT.md and dev/MARCH.md (whose rows name findings) blank, reviewed as the score's
            review user."""
            key = f"{kind}:{sha}"
            if key in done:
                return done[key]
            head = two_commits(before_tree, tree, "the change under review", climb_from=f"origin/{MARCH}",
                               blank=("dev/AUDIT.md", "dev/MARCH.md"))
            # the author's claims, as a move's reach its review (A7-10): a landed move's own message; for a defect, the
            # claim every climber makes of its move, since a revert has no author
            claims = git("log", "-1", "--format=%B", sha) if kind == "clean" else \
                f"fix({change_stem(f'{head}^', head)}): a faithful port of its anchors; its cases pass and nothing else changes"
            def one(suffix):   # one review, counted against judge_per_tick (A6-8: the second review of a miss included)
                if ran[0] >= cfg()["judge_per_tick"]:
                    raise Tick()
                ran[0] += 1
                return review(f"judge{i}{kind[0]}{suffix}", "review3", f"{head}^", head, "", claims)
            rv = done.get(f"{key}#1") or one("")   # a miss's first review kept while its second waits for the next tick
            if kind == "defect" and approved(rv):   # a miss is read once more before it counts (D17's band, not one review's noise)
                if f"{key}#1" not in done:
                    done[f"{key}#1"] = rv; save_json("judge-partial.json", done)
                rv = one("2")
            if isinstance(rv, dict):
                done.pop(f"{key}#1", None); done[key] = rv; save_json("judge-partial.json", done)
            return rv
        try:   # at most judge_per_tick new reviews this tick (verdict raises Tick), the rest at the next
            for i, f in enumerate(judge_set(n)):
                sha = f["sha"]
                rv = verdict("defect", sha, git("rev-parse", f"{sha}^{{tree}}"), git("rev-parse", f"{sha}^^{{tree}}"), i)
                if rv == BUDGET:   # the governor's refusal is no failure of the eval: it resumes when the budget allows (O4)
                    event("judge-eval-budget"); return
                if isinstance(rv, dict):
                    defects.append({"sha": sha[:8], "subject": f["subject"][:120], "refused": not approved(rv), "review": rv})
                event("judged", sha=sha[:8], case="defect", refused=defects[-1]["refused"] if isinstance(rv, dict) else None)
            for i, c in enumerate(clean_moves(n)):
                rv = verdict("clean", c, git("rev-parse", f"{c}^^{{tree}}"), git("rev-parse", f"{c}^{{tree}}"), i)
                if rv == BUDGET:
                    event("judge-eval-budget"); return
                if isinstance(rv, dict):
                    cleans.append({"sha": c[:8], "approved": approved(rv), "review": rv})
                event("judged", sha=c[:8], case="clean", approved=cleans[-1]["approved"] if isinstance(rv, dict) else None)
        except Tick:
            event("judge-eval-partial", reviewed=ran[0], kept=len(done) - 1)
            return
        if not defects:
            event("judge-eval-failed", why="no defect case was reviewed"); back_off("judge-eval"); return
        rec = sum(r["refused"] for r in defects) / len(defects)
        app = sum(r["approved"] for r in cleans) / len(cleans) if cleans else None
        save_json("judge-eval.json", {"t": stamp(), "judge": blob, "recall": rec, "approval": app,
                                      "defects": defects, "cleans": cleans})
        save_json("judge-partial.json", {})
        event("judge-eval", recall=rec, approval=app, n=len(defects), clean=len(cleans))
        if rec < cfg()["judge_recall"]:   # intent: the reviewer refuses what audits found; band: under it two reviewers (K4)
            for_dale("the judge misses past defects", f"The blind reviewer refused {rec:.0%} of {len(defects)} real past defects "
                     f"({os.path.join(STATE, 'judge-eval.json')}). Default taken (K4): every move needs two independent blind "
                     "approvals until reviewer.md, tightened against the misses by a commit made by hand (`climb.py "
                     "enqueue`), passes a re-eval; the lander measures it again when its blob changes (A97E5).")
        if app is not None and app < cfg()["judge_approval"]:   # intent: the reviewer passes sound work; under the band a note
            for_dale("the judge refuses sound moves", f"The blind reviewer approved {app:.0%} of {len(cleans)} landed moves a later "
                     "audit passed. Default taken: the climb runs; reviewer.md's refusals are read and narrowed by a commit made by hand.")
        print(f"judge: refused {rec:.0%} of past defects; approved " + (f"{app:.0%} of {len(cleans)} clean moves" if cleans else "no clean move yet"))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
