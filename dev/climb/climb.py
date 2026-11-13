#!/usr/bin/env python3
"""dev/climb/climb.py — the climb's driver and its score (dev/climb/HILL.md).

The march as a hill climb (Dale 2026-11-04, D47). A program scores the compiler, and fresh agents make one
move each. The driver is a program, so no resident LLM lead and no LLM monitor spends tokens while it waits.

State lives outside the repository, in <dir of the repo>/.wt-climb. Dale's uid never executes anything an agent or a
candidate wrote: every such process runs as a build user behind the door (dev/climb/door.py).

    python3 dev/climb/climb.py report              the scoreboard: src progress, S, the gates, the holds, the budget
    python3 dev/climb/climb.py holds [-n K]        the holds, largest first (--json for the driver's form)
    python3 dev/climb/climb.py record <tsv> <sha>  a full smoke run's cases enter the table at the commit's count (G2)
    python3 dev/climb/climb.py budget              the account's spend today and this week against the allowance
    python3 dev/climb/climb.py map [<out.html>]    the project map, drawn by this program (D29), no agent
    python3 dev/climb/climb.py preflight [--kill]  what launch needs: stale loops, origin, Kaimon, disk, the budget
    python3 dev/climb/climb.py enqueue <ref> <title>  a commit made by hand (the harness, the rules) queued for the lander
    python3 dev/climb/climb.py enqueue <ref> --fixes <key>  a hand fix of a known red (fix-first entry <key>), which
                                                   the lander admits while that red is overdue (core.admits)
    python3 dev/climb/climb.py unpark <hold id>    a parked hold climbs again (an overdue fix-first's stall names it)
    python3 dev/climb/climb.py score-tick          one look at origin/wt2: the alarms, a score, the judge's eval and an
                                                   audit when due
    python3 dev/climb/climb.py slot <climb-N>      one move in that slot, then exit
    python3 dev/climb/climb.py lander              one round of the lander, the one process that lands: reconcile, then
                                                   the queue; it runs no agent
    python3 dev/climb/climb.py judge-eval [-n N]   the reviewer's recall on N real past defects (reverted audit fixes)
    python3 dev/climb/climb.py resume-stopped      resume every process a dead climb process left stopped
    python3 dev/climb/climb.py reap-orphans        reap a killed driver's build-user processes, each role no process uses
    python3 dev/climb/climb.py door-probe          as each build user, what the door refuses (dev/climb/door.py), no tokens
    python3 dev/climb/climb.py agent-probe         one agent run (at most agent_probe_usd) tries the door from inside
    python3 dev/climb/climb.py oracle-replay       the whole store answered again under origin's key (a key change: Julia,
                                                   the host, the answering program, the snapshot), resumable label by label
                                                   as the bootstrap is; refused while the climb runs (no PAUSE)
    python3 dev/climb/climb.py oracle-audit [-k K] [--seed S]  a seeded sample of stored answers answered again,
                                                   and compared byte for byte (HILL.md, the oracle); a difference is a note
    python3 dev/climb/climb.py oracle-bootstrap [--at REF] [--role R]
                                                   the store's first unit: every label of origin's corpus at REF answered
                                                   in a process of its own (HILL.md, the oracle), resumable; refused while
                                                   the climb runs (no PAUSE). Every store write (this, oracle-replay, a
                                                   freeze, oracle-audit's answers) is keyed by origin's answering program
                                                   (core.JUDGE_WRITE at measure.store_judge), the one every measurement reads under

Launch is dev/climb/launch.sh, which runs slot, lander and score-tick in loops from the driver's own worktree.
Config: <state>/config.json overrides DEFAULTS key by key, except LOCKED_KEYS (the budget, the models, the ledger's
numbers). This file is the command line; the driver is dev/climb/core.py (state, score, budget, agents),
dev/climb/measure.py (trees, G5, the fenced smoke, judging a candidate), dev/climb/lander.py (the queue, the probe,
landing, audits, the judge's eval), dev/climb/slots.py (Kaimon, moves, the agent probe) and dev/climb/door.py (the
build users: the one way in and out, its profiles, dev/ship.sh's too).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from core import *   # noqa: F403
from measure import *   # noqa: F403
from lander import *   # noqa: F403
from slots import *   # noqa: F403


# ---------------------------------------------------------------- the loops
def slot_names():
    """The slots' loops, `climb-1` to `climb-<slots>`, none for `slots: 0`: the one source of the names, read by both of
    launch.sh's loops (spec v20 F2; macOS `seq 0` prints `1 0`)."""
    return [f"climb-{i}" for i in range(1, cfg()["slots"] + 1)]


def power_hold():
    """The heartbeat's power assertion, as caffeinate's flags (spec battery1 B2), asked each minute by launch.sh's
    heartbeat: with `battery_runs`, `-i -s` while work may run (core.power_ok: `-i` holds the Mac awake on battery too,
    `-s` on AC as before) and none while the power rule stops work (Low Power Mode on battery, or under
    battery_floor_pct), so an emptying battery is never held awake (O9-2); with it off, `-s` alone, as before (it holds
    on AC only). A closed lid still sleeps the Mac."""
    if not cfg()["battery_runs"]:
        return "-s"
    return "-i -s" if power_ok() else ""


@contextlib.contextmanager
def loop_lock(name):
    """One process per loop and per slot (20): a second one exits at once (yields False)."""
    fd = os.open(os.path.join(STATE, f".{name}.lock"), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd); yield False; return
    try:
        yield True
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)

def scoreboard_once(head):
    """A full score of origin's head in the driver's board tree, by the one measurement every move takes, its three
    roles (O10, R5-4), and the src tail's kinds there, behind the door. A run that loses more than score_loss_band of the
    table's passing cases is run again before anything is recorded, and the second run is the one recorded (10). A
    score cut where no case of its own is in flight (its wall: measure.MeasureCut) is `score-failed`, naming the label
    in flight and the labels not reached, and nothing of it is recorded (O8-1); a score whose landed labels the store
    does not answer (measure.OracleGap: one gap rule for every measurement, spec v14 V5) is `score-failed` too, nothing
    recorded and no G2 filed, with one note naming the key field and the replay."""
    out = os.path.join(STATE, f"cases-{head[:8]}.tsv")
    t0 = door.CLOCK()
    src_part(head)   # the src suite first (the landing-check ruling, R6): its record, its reds located
    for attempt in (1, 2):
        try:
            with julia_slot("score"):
                rows, why = smoke("score", None, f"score-{head[:8]}", head, learn_=True)
            if rows is not None:
                judge_gaps(rows.values())   # the whole corpus's gaps, here alone (spec v19 P5)
        except MeasureCut as e:
            rows, why = None, str(e)
        except OracleGap as e:   # the store's gap: no score, no row, no G2; one note (alarm_s) naming the field and the replay
            event("score-failed", sha=head[:8], secs=round(door.CLOCK() - t0), tail=str(e)[-300:], gap=True)
            alarm("oracle-gap", "the store does not answer origin's labels: no score", f"{str(e)[:1500]}\nDefault taken: "
                  "every measurement fails, located, and nothing is recorded until the store answers them.")
            back_off("score", why=f"the score of {head[:8]}: {str(e)[-300:]}"); return
        lost = None
        if rows is not None:
            write_atomic(out, cases_text(rows.values()))
            lost = losses(list(rows.values()), count_of(head))
        if lost is None:
            event("score-failed", sha=head[:8], secs=round(door.CLOCK() - t0), tail=why[-300:])
            back_off("score", why=f"the score of {head[:8]} wrote no readable cases: {why[-300:]}"); return
        if attempt == 1 and len(lost) > cfg()["score_loss_band"] * max(sum(r[1] == "passed" for r in head_cases()), 1):
            event("score-held", sha=head[:8], lost=len(lost))   # run again before the table takes it
            continue
        break
    res = record(out, head)
    if res is None:
        return
    recovered("score")
    s, lost, bad = res
    try:
        with julia_slot("score"):   # the src tail's definitions at this head (dev/src_progress.sh kinds, D40)
            write_atomic(os.path.join(STATE, "head-kinds.tsv"), kinds(head, f"score-{head[:8]}"))
    except ClimbError as e:
        event("kinds-failed", sha=head[:8], tail=str(e)[-300:])
    draw_map(os.path.join(STATE, "map.html"))
    print(f"scored {head[:8]}: S={s['passed']}/{s['climbable']} lost={len(lost)} bad={len(bad)} ({round(door.CLOCK() - t0)} s)", flush=True)

def src_part(head):
    """The score's src part (measure.src_score) under the score's lock, before its smoke, a part of its own: a fault of
    ANY kind in it (a cut, a refused record, the door's, the driver's own bug) is `src-failed` with its traceback and one
    note, and the smoke runs still; that head is then not verified (D9: located, never lost; the operator's round-13
    finding 1, an IndexError out of the locate that killed every score before its smoke). A power cut is the one
    exception passed on: the score ends there and is redone when work may run, as every measurement's is."""
    import traceback
    try:
        with julia_slot("score"):
            src_score(head)
    except PowerCut:
        raise
    except Exception as e:   # noqa: BLE001 — located, the smoke goes on
        tb = traceback.format_exc()
        event("src-failed", sha=head[:8], why=f"{type(e).__name__}: {str(e)[-300:]}", traceback=tb[-2000:])
        alarm("src-failed", "the score's src part failed: its head is not verified",
              f"The src part of the score of {head[:10]} failed: {type(e).__name__}: {str(e)[:500]}\n{tb[-1500:]}\nDefault "
              "taken: the smoke runs; this head is not verified, and src_unverified_max holds landings if it lasts.")

def unlogged_landings():
    """Commits on origin/wt2 since launch that dev/ship.sh's landing log does not name: a push around the driver."""
    p = os.path.join(STATE, "launch-base")
    if not os.path.exists(p):
        write_atomic(p, git("rev-parse", f"origin/{MARCH}"))
    logged = [h for _, h, _ in landings() if len(h) >= 7]
    return [c for c in git("rev-list", f"{open(p).read().strip()}..origin/{MARCH}").splitlines()
            if not any(c.startswith(h) for h in logged)]

def alarms():
    """Stalls are never silent (21): no move started or landed for alarm_s while not paused, checks run with no landing
    for alarm_s, and a queue that no quiet probe has admitted for alarm_s, each a note. A computed wait is no stall (O6,
    O8-5): the week's half, a slot that waits for the day's budget, and the slots idling by rule (the queue at
    queue_cap, a D14 wait, battery) (D17: an alarm firing inside its band is a bug)."""
    if pause():
        return
    cut = stamp(now() - datetime.timedelta(seconds=cfg()["alarm_s"]))
    ev = events()
    la = os.path.join(STATE, "launched-at")   # written by launch.sh at each start (architect 13), never launch-base's age
    started = open(la).read().strip() if os.path.exists(la) else cut
    # the slots idle by rule, a computed wait, no stall (O8-5): the queue at queue_cap, a D14 wait or its binding, battery
    overdue = fixfirst_overdue()
    by_rule = len(admitted_queue(overdue)) >= cfg()["queue_cap"] or backed_off("lander", "d14") or \
        state_json("alarms.json", {}).get("d14-binds") or not state_json("power.json", {}).get("runs", True)
    if started < cut and not any(e["t"] >= cut for e in ev if e["kind"] in ("climb", "landed")) and not \
            (week_half() or state_json("waits.json", {}) or by_rule):
        alarm("stall", "the climb has stalled", f"No move started and none landed since {cut} (the backoffs: "
              f"{json.dumps(state_json('backoff.json', {}))[:800]}). Default taken: the climb keeps trying.")
    # an overdue known red whose hold is parked: nothing can climb it, so nothing lands; a stall of its own (finding 2)
    for h in holds():
        if h.get("fixfirst") and h["parked"] and any(f["key"] == h["key"] for f in overdue):
            alarm(f"fixfirst-parked-{h['id']}", "an overdue known red's hold is parked: nothing lands",
                  f"{h['key'][:200]} is overdue (filed {cfg()['fixfirst_max_landings']} or more landings ago) and parked "
                  f"({str(h['parked'].get('why', ''))[:300]}), so no slot climbs it and the lander admits fix-first items alone. "
                  f"Unpark it with `python3 dev/climb/climb.py unpark {h['id']}`, or land a hand fix with "
                  f"`python3 dev/climb/climb.py enqueue <ref> --fixes '{h['key'][:120]}'`. Default taken: the climb waits.")
    # checks ran and none landed (A7-2): from the first `ship` event after the last `landed` (or the launch), alarm_s
    last = max((e["t"] for e in ev if e["kind"] == "landed"), default=started)
    ships = [e["t"] for e in ev if e["kind"] == "ship" and e["t"] > last]
    if ships and ships[0] < cut:
        alarm("no-landing", "checks run and nothing lands", f"{len(ships)} landing check(s) since {ships[0]} and no landing "
              f"since {last}: the last results {[e.get('result') for e in ev if e['kind'] == 'ship'][-5:]}. Default taken: "
              "the lander keeps trying; approved commits stay queued.")
    probes = [e for e in ev if e["kind"] == "quiet-probe"]
    ok = max((e["t"] for e in probes if e["ok"]), default=started)
    if state_json("ready.json", []) and ok < cut and any(e["t"] >= cut for e in probes):
        alarm("quiet", "no quiet probe has passed", f"Approved commits wait, and no probe since {ok} found the machine quiet "
              f"(p_idle {cfg()['p_idle']}, e_idle {cfg()['e_idle']}): the last probes read "
              f"{[(e.get('p_idle'), e.get('e_idle'), e.get('pressure')) for e in probes[-5:]]}. Default taken: the lander keeps probing.")

def score_tick():
    """One look at origin/wt2: the alarms, the rogue-push alarm, a score when enough has landed or enough time has
    passed since the last (never within its backoff after a failed or refused one), then the agents the lander never
    runs (item 11): the judge's eval when stale and an audit when due, neither at the week's half or past the day's
    allowance (the eval waits; an audit, about 0.6M, is exempt from the allowance alone, K5)."""
    alarms()
    sc = scored_heads()
    last = git("rev-parse", "--verify", "-q", sc[-1]["sha"], check=False) if sc else None
    last_t = datetime.datetime.fromisoformat(sc[-1]["t"]).timestamp() if sc else 0.0
    fetch()
    rogue = unlogged_landings()
    if rogue and not pause():
        write_atomic(os.path.join(STATE, "PAUSE"), "origin/wt2 advanced by a push no landing names\n")
        for_dale("the climb paused itself: a push around the driver", "These commits reached origin/wt2 with no "
                 f"dev/ship.sh landing: {', '.join(c[:8] for c in rogue)}. Default taken: paused until Dale reads them "
                 "and runs `bash dev/climb/launch.sh resume`.")
        event("rogue-push", commits=[c[:8] for c in rogue])
    head = git("rev-parse", f"origin/{MARCH}")
    n = len(git("rev-list", f"{last}..{head}").splitlines()) if last else 10 ** 6
    if head != last and not backed_off("score") and (n >= cfg()["score_every_landings"] or time.time() - last_t >= cfg()["score_every_s"]) \
            and power_ok():   # no score starts while the power rule stops work (O8-3, core.power_works)
        scoreboard_once(head)
    if pause() or week_half() or token_refused():
        return
    if not judge_measured() and not backed_off("judge-eval") and not over_budget():
        guarded("judge-eval", judge_eval)   # until it passes, two approvals a move (K4)
    if audit_due():   # D21: an audit only enqueues, so it holds no landing (O13)
        guarded("audit", audit)

LOOP_LOCKS = ("slot-*", "lander", "score-tick")   # the loops' own locks (loop_lock): a live loop holds its

def loops_running():
    """The climb's loops alive now: each whose lock (loop_lock, in the state) another process holds."""
    out = []
    for p in sorted(x for g in LOOP_LOCKS for x in glob.glob(os.path.join(STATE, f".{g}.lock"))):
        fd = os.open(p, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); fcntl.flock(fd, fcntl.LOCK_UN)
        except BlockingIOError:
            out.append(os.path.basename(p)[1:-len(".lock")])
        finally:
            os.close(fd)
    return out

def preflight(kill=False):
    """What a launch needs, once a launch (O7-8): refused while any loop of the climb runs (A7-7: run by hand beside a
    live climb, it removed live run directories, re-pinned claude and re-mirrored the toolchain); with `kill`, the
    stale loops of the old landing scripts are ended first and waited for."""
    try:   # this state owns the repository it would write (spec v19 P3), first: else no loop starts at all
        common_write("the launch")
    except ClimbError as e:
        print(f"preflight: refused: {e}")
        return False
    live = loops_running()
    if live:
        print(f"preflight: refused while the climb's loops run ({', '.join(live)}): `bash dev/climb/launch.sh stop` first")
        return False
    # what it changes is TOP's: no role of any state in use (A8-6), and every role held until it returns, so none is
    # taken meanwhile (A9-5)
    with door.hold_roles() as busy:
        if busy:
            print(f"preflight: refused while the roles {', '.join(busy)} are in use (TOP/locks: a climb's or a probe's, any state)")
            return False
        ok = _preflight(kill)
    # the store against the key the build users will measure with: after the toolchain the users run is chosen (door.tools,
    # above), as the measure role computes it, with every role free again (spec v14 V5)
    return store_ready() and ok

def store_ready():
    """Whether the store answers origin's landed labels under the key the build users run (measure.measure_key, a
    process of the measure role that loads no corpus, as every measurement computes it): a missing store, a store keyed
    otherwise (a Julia juliaup updated since, the answering program or the snapshot changed) or a label it lacks refuses
    the launch, located: the store's key, the users' key, and the one replay (round12-operator 2)."""
    origin = git("rev-parse", f"origin/{MARCH}")
    try:
        key = measure_key("measure", origin, "preflight")
        idx = oracle_index()
        landed = landed_labels(labels_at(origin), origin, idx)
        _, missing = oracle_read(landed, key)
    except (ClimbError, door.DoorError) as e:
        print(f"store: refused: {str(e)[:600]}"); return False
    boot = open(os.path.join(ORACLE, "bootstrap")).read().split()[0] if os.path.exists(os.path.join(ORACLE, "bootstrap")) else None
    have = read_key(open(os.path.join(ORACLE, f"{boot}.tsv")).read().split("\n", 1)[0]) if boot and os.path.exists(os.path.join(ORACLE, f"{boot}.tsv")) else None
    if missing or not idx:
        l0 = sorted(missing)[0] if missing else None
        print(f"store: refused: the store is keyed {have[0] if have else 'nowhere (no store)'}, the users run {key}: "
              f"{len(missing)} of origin's {len(landed)} landed label(s) unanswered" + (f", e.g. {l0}: {missing[l0][:300]}" if l0 else "") +
              ". Pause, replay (`python3 dev/climb/climb.py oracle-bootstrap` for a store that has none, else "
              "`python3 dev/climb/climb.py oracle-replay`), then launch")
        return False
    print(f"store: answers origin's {len(landed)} landed label(s) under the users' key {key['julia']}")
    return True

def _preflight(kill):
    """preflight()'s checks, every role's lock held."""
    ok = True
    # the global locks' files an older driver kept elsewhere (v8: in the state; v7b: the role's stops beside the locks),
    # which nothing reads now (A9-4): cleared, while every role is held
    for p in [*glob.glob(os.path.join(STATE, ".julia-*.lock")), *glob.glob(os.path.join(STATE, ".role-*.lock")),
              os.path.join(STATE, ".deps.lock"), os.path.join(STATE, ".agent-probe.lock"), *glob.glob(os.path.join(door.LOCKS, "stops-*.json*"))]:
        with contextlib.suppress(FileNotFoundError):
            os.remove(p); print(f"stale: removed {p}")
    def stale():
        return "\n".join(l for l in sh(["pgrep", "-fl", "dev/autoship.sh|dev/ship.sh|dev/corpus.sh"]).stdout.splitlines()
                         if l.strip() and "pgrep" not in l and int(l.split()[0]) not in (os.getpid(), os.getppid()))
    ps = stale()
    if ps:
        print("stale loops still running:\n  " + ps.replace("\n", "\n  "))
        if kill:
            for line in ps.splitlines():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(line.split()[0]), signal.SIGTERM)
            t0 = door.CLOCK()
            while stale() and door.CLOCK() - t0 < cfg()["term_grace_s"]:
                time.sleep(1)
            ps = stale()
            print("  … sent SIGTERM" + (f"; still running after {cfg()['term_grace_s']} s" if ps else "; they exited"))
            ok = not ps
        else:
            ok = False; print("  run `climb.py preflight --kill` to stop them")
    held = os.path.join(COMMON, "wt-held")
    if os.path.exists(held) and open(held).read().strip():
        print("wt-held: " + open(held).read().strip().replace("\n", ", "))
    if os.path.exists(os.path.join(COMMON, "wt-line-stop")):
        ok = False; print("wt-line-stop is set: " + open(os.path.join(COMMON, "wt-line-stop")).read().strip())
    door.clear_in()   # what a killed driver left in the door's run directories (its HELD lived in its memory alone)
    for r, ps in door.reap_orphans(held=True).items():   # its orphans: every role is held here, so any process is one
        print(f"orphans: reaped {door.ROLES[r]}'s {ps}")
    free = shutil.disk_usage(STATE).free / 1e9
    if free < cfg()["disk_free_gb"]:
        ok = False; print(f"disk: {free:.0f} GB free under {STATE}, under the {cfg()['disk_free_gb']} GB a climb needs")
    for r in door.ROLES:   # the door (D-E): every build user reachable through sudo, with no password
        if door.run(r, ["/usr/bin/true"], cfg()["step_wall_s"], profile=door.NONE)[0] != 0:
            ok = False; print(f"door: sudo -n -u {door.ROLES[r]} fails; run dev/climb/setup-users.sh (with sudo) first")
    try:
        door.seal_home()   # the toolchain the users run, at launch: Julia of the main tree's Manifest (launch copies it below)
        print("door: " + json.dumps(tool_versions(door.tools(door.manifest_julia(open(os.path.join(REPO, "Manifest.toml")).read()),
                                                             state=STATE, prune=not os.environ.get("WT_CLIMB_STATE")))))
        # alone, its versions recorded once a launch (spec v15 W2)
        # chosen here, never by a landing; only the real state's launch prunes older copies (a scratch one's never, O7-2)
        print("door: the agents' claude " + json.dumps(door.pin_claude(STATE, prune=not os.environ.get("WT_CLIMB_STATE"))))
    except (door.DoorError, OSError) as e:
        ok = False; print(f"door: {e}")
    try:   # the climb's Manifest, copied here from the main tree's and read only from the state (O6-5)
        print("env: the climb's Manifest " + json.dumps(copy_manifest()))
    except (OSError, ClimbError) as e:
        ok = False; print(f"env: the main tree's Manifest.toml could not be copied: {e}")
    if not agent_token():
        ok = False; print(f"token: none at {cfg()['token_file']} (D-F: `claude setup-token`, mode 600)")
    else:   # one max_tokens:1 call with it, through a proxy (O6-8): a refused token refuses the launch, named
        try:
            st = token_call()
        except OSError as e:
            st = f"no answer ({e})"
        print(f"token: the API answered {st} to one call with it" + ("" if st == 200 else "; run `claude setup-token`"))
        ok = ok and st == 200
    print("scored head: " + ("yes" if head_cases() else "none yet (the scoreboard's first run scores one)"))
    print(f"budget: the account today {account_spend(1)/1e6:.0f}M of {allowance()/1e6:.0f}M weighted per day")
    return ok

def landed_code():
    """The loops run landed code only (24): this file's tree is the driver's own worktree, clean, at a commit origin
    holds. launch.sh fast-forwards it each iteration; a tree being edited never runs the climb."""
    if os.path.realpath(ROOT) != os.path.realpath(DRIVER):
        return f"this is {ROOT}, not the driver's worktree {DRIVER}"
    if git("status", "--porcelain", "--untracked-files=no"):
        return f"{DRIVER} has local changes"
    if sh(["git", "merge-base", "--is-ancestor", "HEAD", f"origin/{MARCH}"]).returncode != 0:
        return f"{DRIVER}'s HEAD is not on origin/{MARCH}"
    return None

def oracle_on_ac(what, fn, *args):
    """A hand command's long run of the oracle (its bootstrap, replay or audit) through the power gate, on_ac: a cut
    prints one line, waits until work may run (core.power_works) and runs fn again, which continues from what it kept
    (the bootstrap's partial file); past task_wall_s of awake time waiting it ends with one line and exit 3, resumable,
    never a traceback. An
    interrupt (INT, TERM) is no PowerCut: it ends the command at once."""
    try:
        return on_ac(what, fn, *args, wait=True, say=lambda s: print(f"climb: {s}", flush=True))
    except PowerCut as e:
        print(f"climb: {what} ended, the power rule stopping work past task_wall_s ({str(e)[:160]}); run it again on AC "
              "or on battery with Low Power Mode off: it continues "
              "from what it kept", flush=True)
        sys.exit(3)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("report"); h = sp.add_parser("holds"); h.add_argument("-n", type=int, default=20); h.add_argument("--json", action="store_true")
    r = sp.add_parser("record"); r.add_argument("tsv"); r.add_argument("sha")
    sp.add_parser("budget"); m = sp.add_parser("map"); m.add_argument("out", nargs="?", default=os.path.join(STATE, "map.html"))
    p = sp.add_parser("preflight"); p.add_argument("--kill", action="store_true")
    e = sp.add_parser("enqueue"); e.add_argument("ref"); e.add_argument("title", nargs="?", default=None)
    e.add_argument("--fixes", default=None, help="the fix-first entry's key this hand commit fixes: admitted while it is overdue")
    up = sp.add_parser("unpark"); up.add_argument("hold_id")
    j = sp.add_parser("judge-eval"); j.add_argument("-n", type=int, default=None)
    so = sp.add_parser("slot"); so.add_argument("name")
    sp.add_parser("lander"); sp.add_parser("score-tick"); sp.add_parser("slot-names"); sp.add_parser("power-hold"); sp.add_parser("resume-stopped"); sp.add_parser("hill")
    sp.add_parser("reap-orphans")
    nt = sp.add_parser("alarm"); nt.add_argument("name"); nt.add_argument("title"); nt.add_argument("text")
    sp.add_parser("door-probe"); sp.add_parser("agent-probe"); sp.add_parser("claim-repo"); df = sp.add_parser("default"); df.add_argument("key")
    ob = sp.add_parser("oracle-bootstrap"); ob.add_argument("--at", default=f"origin/{MARCH}")
    ob.add_argument("--role", default="measure", choices=("measure", "score"))
    oa = sp.add_parser("oracle-audit"); oa.add_argument("-k", type=int, default=None); oa.add_argument("--seed", default=None)
    oa.add_argument("--role", default="measure", choices=("measure", "score"))
    orp = sp.add_parser("oracle-replay"); orp.add_argument("--role", default="measure", choices=("measure", "score"))
    a = ap.parse_args()
    # a TERM (launch.sh stop) unwinds every `finally`, so a quiesce resumes what it stopped (9)
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(128 + s))
    resume_orphans()
    beat()   # the iteration's first stamp (launch.sh names the loop: WT_CLIMB_LOOP)
    if a.cmd in ("slot", "lander", "score-tick"):
        why = landed_code()
        if why:
            alarm("landed-code", "a loop refuses to run", f"{why}. Default taken: each loop refuses until it is fixed by a commit made by hand.")
            print(f"climb: refused, the climb runs landed code only: {why} (run it through dev/climb/launch.sh)"); sys.exit(2)
        with loop_lock(f"slot-{a.name}" if a.cmd == "slot" else a.cmd) as mine:   # one process per loop (20)
            sys.exit(3 if not mine or not disk_room() else guarded("slot", slot_once, a.name, key=a.name) if a.cmd == "slot"
                     else guarded("lander", land_round) if a.cmd == "lander"
                     else (guarded("score", score_tick), 3)[1])   # the scoreboard sleeps between looks
    if a.cmd == "judge-eval":
        os.setpgrp()   # its own process group: a stop ends the claude children with it
    if a.cmd == "report": print(report())
    elif a.cmd == "holds":
        hs = holds()[:a.n]
        print(json.dumps(hs, indent=1) if a.json else "\n".join(f"{h['n']:4d}  {h['id']}  {h['key']}" for h in hs))
    elif a.cmd == "record":
        res = record(a.tsv, a.sha)
        if res is None:
            print("refused: the runner failed on most cases"); sys.exit(1)
        s, lost, bad = res; print(json.dumps(s), f"lost={len(lost)} bad={len(bad)}")
    elif a.cmd == "budget":
        print(f"the account: today {account_spend(1)/1e6:.1f}M of {allowance()/1e6:.0f}M weighted; 7 days {account_spend(7)/1e6:.0f}M; "
              f"the climb's 7 days {climb_spend(7)/1e6:.1f}M")
        sys.exit(1 if over_budget() else 0)
    elif a.cmd == "map": print(draw_map(a.out))
    elif a.cmd == "preflight": sys.exit(0 if preflight(a.kill) else 1)
    elif a.cmd == "enqueue":
        fetch()
        if a.fixes is not None:   # the lead's deliberate act: a hand fix of a known red, admitted while it is overdue
            if not any(f["key"] == a.fixes for f in state_json("fixfirst.json", [])):
                sys.exit(f"enqueue --fixes: no fix-first entry is keyed {a.fixes!r}")
            # on the entry's own hold (its id, as slots.py's moves on it carry), so measure.src_set runs the red's file
            # and landed_item may clear the entry: a hand fix whose check never ran the file could only be kept
            it = enqueue(a.ref, a.fixes, "hand", hold_id=hashlib.sha1(a.fixes.encode()).hexdigest()[:10], fixfirst=True)
        elif a.title is None:
            sys.exit("enqueue: a hand commit names its title, or --fixes <key>")
        else:
            it = enqueue(a.ref, a.title, "hand")
        print(f"queued {it['sha'][:10]} as {it['branch']}")
    elif a.cmd == "unpark":   # the one command that unparks a hold (an overdue fix-first's stall names it)
        update_json("parked.json", {}, lambda p: p.pop(a.hold_id, None)); event("unparked", hold_id=a.hold_id)
        print(f"unparked {a.hold_id}")
    elif a.cmd == "judge-eval": judge_eval(a.n)
    elif a.cmd == "slot-names": print(" ".join(slot_names()))
    elif a.cmd == "power-hold": print(power_hold())
    elif a.cmd == "resume-stopped": pass   # resume_orphans() above is the whole command
    elif a.cmd == "reap-orphans":   # a killed driver's build-user processes, each role whose lock is free (door.reap_orphans)
        for r, ps in door.reap_orphans().items():
            print(f"orphans: reaped {door.ROLES[r]}'s {ps}")
    elif a.cmd == "default": print(json.dumps(cfg()[a.key]))
    elif a.cmd == "claim-repo":   # this repository's logs and refs are this state's (spec v18 P5)
        print(f"claimed {COMMON} for {claim_repo()}")
    elif a.cmd == "door-probe":
        door.seal_home()
        res = door.probe(STATE, COMMON) + g5_rows() + bundled_rows() + audit_rows() + reader_rows()
        for what, ok, ev in res:
            print(("held  " if ok else "FAILED") + f"  {what}: {ev}")
        event("door-probe", ok=all(ok for _, ok, _ in res), failed=[w for w, ok, _ in res if not ok])
        sys.exit(0 if all(ok for _, ok, _ in res) else 1)
    elif a.cmd == "oracle-bootstrap":
        if not pause():   # the store's writer is the lander's lock's, with the climb paused (HILL.md, the oracle)
            print(f"climb: refused, the bootstrap runs with the climb paused ({os.path.join(STATE, 'PAUSE')} absent)"); sys.exit(2)
        at, judge_at = git("rev-parse", a.at), store_judge()
        t0 = door.CLOCK()
        with julia_slot("verify"):
            blocks = oracle_on_ac("oracle-bootstrap", oracle_bootstrap, at, a.role)
        unit = os.path.join(ORACLE, f"{at}.tsv")
        big = max(blocks, key=lambda l: len(blocks[l]))
        print(f"oracle: unit {at[:12]} ({len(blocks)} labels, judge {judge_at[:12]}), {os.path.getsize(unit)} bytes "
              f"(largest {big}: {len(blocks[big])} bytes), {round(door.CLOCK() - t0)} s, one process a label")
    elif a.cmd == "oracle-audit":
        k = cfg()["oracle_audit_k"] if a.k is None else a.k
        seed = a.seed or stamp()
        with julia_slot("verify"):
            found = oracle_on_ac("oracle-audit", oracle_audit, k, seed, a.role)
        for f in found:
            print(f"  {f}")
        print(f"oracle-audit: {k} label(s), seed {seed}: {len(found)} finding(s)")
        if found:
            for_dale(f"the oracle's audit found {len(found)} difference(s)", "\n".join(found)[:3000] + "\nDefault taken: the "
                     "store serves them as stored; each is a corpus bug to fix by a commit made by hand, or a replay.")
        sys.exit(1 if found else 0)
    elif a.cmd == "oracle-replay":   # THE replay: the whole store at origin, under origin's key (spec v14 V5)
        if not pause():
            print(f"climb: refused, a replay runs with the climb paused ({os.path.join(STATE, 'PAUSE')} absent)"); sys.exit(2)
        boot = open(os.path.join(ORACLE, "bootstrap")).read().split()[0] if os.path.exists(os.path.join(ORACLE, "bootstrap")) else None
        if boot is None:
            print("climb: refused, the store has no bootstrap (oracle/bootstrap): run `climb.py oracle-bootstrap` first"); sys.exit(2)
        at, t0 = store_judge(), door.CLOCK()
        with julia_slot("verify"):
            blocks = oracle_on_ac("oracle-replay", oracle_bootstrap, at, a.role, True, boot)
        print(f"oracle: the store replayed at {at[:12]} under its key, {len(blocks)} label(s), {round(door.CLOCK() - t0)} s, one process a label")
    elif a.cmd == "agent-probe":
        rec = agent_probe()
        print(json.dumps(rec, indent=1)); sys.exit(0 if rec["ok"] else 1)

if __name__ == "__main__":
    main()
