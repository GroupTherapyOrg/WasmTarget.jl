#!/usr/bin/env python3
"""dev/climb/defaults.py — every number the climb's driver uses, each with its intent and band (D17), and the one
paragraph of dev/climb/HILL.md generated from them. No side effect on import: the ratchet's lock reads it (L204).

    python3 -I dev/climb/defaults.py check <HILL.md>   exit 0 when HILL.md's paragraph is the generated one, else 1
    python3 -I dev/climb/defaults.py hill              the paragraph
"""
import json, re, sys

DEFAULTS = {
    "slots": 2,                                  # climbers at once (4 performance cores, one check at a time: D31)
    "climber_model": "claude-opus-5-5",          # D48: every agent runs on Opus (Dale 2026-11-04: Claude only)
    "climber_effort": "high",
    "reviewer_effort": "high",
    "ruler_model": "claude-opus-5-5",            # D48: Opus rules first; Fable is the escalation, called rarely
    "fable_model": "claude-fable-5-1",
    "fable_per_day": 2,                          # D48 (Dale 2026-11-04): "make fable use in the council minimal"
    # measured: 2026-11-01 10:00Z to 11-02 15:25Z, each message once, hit the limit at 8.38e8 (for the week from
    # 2026-11-08 this stood at twice that on Dale's "just push for now -- i have some resetcs"; reverted here)
    "week_weighted": 8.38e8,
    "margin": 0.85,
    # Dale 2026-11-08: "warn me when we hit 50% usage [for the week] and when we do, please pause"; the day's allowance
    # is the same half spread over the week (K7), so the climb runs every night up to the pause
    "week_pause": 0.5,
    # whether the governor HOLDS the climb at the day's allowance, the week's half and the week's margin. Dale
    # 2026-11-13, with the account past the day's allowance and 4.3M short of the week's half: "dont worry about token
    # keep going", then "STOP pausing EVER". False: the governor counts and reports every token as before (the budget
    # line, the week-half note, once a week), each run keeps its own dollar cap, and nothing waits or is refused for
    # the account's spend. True restores D51's pause at the three numbers above
    "budget_holds": False,
    # the march account's transcripts: run the climb under that account's own CLAUDE_CONFIG_DIR, so the governor counts
    # its sessions alone (another account's sessions in the same directory would be counted against it)
    "claude_home": "",                           # empty: $CLAUDE_CONFIG_DIR, else ~/.claude (cfg())
    "task_cap_usd": 25.0,                        # --max-budget-usd of a fresh run (calibrate on day 1: `budget`)
    "resume_cap_usd": 8.0,                       # a resume re-creates its cache cold, so it gets its own small cap
    # the agents' long-lived token (D-F, `claude setup-token`): a file only Dale's uid reads (mode 600, outside the
    # repository and every build user's reach), held by the driver's proxy alone (door.proxy), which adds it to each
    # call, so no build user's process has it; a diff holding its text is refused (G5)
    "token_file": "~/Library/Application Support/wt-climb/agent-token",
    # the agent probe (item 5), one run per pinned claude at effort low: its 7 Bash steps; v5's canary measured a
    # climber run of 11 turns at $0.71 at effort high. Band: Dale's cap for the probe (spec v6), a run cut by it leaves
    # steps untried and the probe failed, never passed
    "agent_probe_usd": 0.5,
    # a failed agent probe is run again on its backoff, at most this many runs per claude version, Dale told after the
    # last (O6-3: one failed run, a skipped step at effort low or an API 529, halted both slots until a human acted).
    # Band: 3 runs, at most 3 x agent_probe_usd = $1.50 a version ($0.28 a run measured, 2026-11-09)
    "agent_probe_runs": 3,
    # a climber's one commit comes back as a git bundle: a move's diff is source text, megabytes at most; 64 MB is
    # far over any and far under a disk-filling write
    "bundle_cap_bytes": 67108864,
    # what one million tokens of each kind cost in USD, for each model the climb runs, as the API bills an answer: its
    # proxy's count of a run's dollars (core.dollars), which refuses a call once the run passes its --max-budget-usd
    # (R6-6). Source: the published input price (the API's pricing, cached 2026-11-03: Opus 5.5 $4, Fable 5.1 $10,
    # Sonnet 5.5 $2, Haiku 5.5 $0.10) and the kinds' multiples as billed: output 5x, a 1-hour cache write 2x (claude's
    # writes are all 1-hour), a 5-minute write 1.25x, a read 0.1x for Haiku and 0.05x for Opus and Sonnet. Checked: these
    # reproduce claude's own total_cost_usd to the digit on every run recorded (v7b report: 4 Haiku runs, Opus, Sonnet);
    # Fable's multiples are Opus's, checked by one run (v7b report). The governor's weights (core.weighted) are not these
    "price_usd": {
        "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_write_5m": 5.0, "cache_write_1h": 8.0, "cache_read": 0.2},
        "claude-fable-5-1": {"input": 10.0, "output": 50.0, "cache_write_5m": 12.5, "cache_write_1h": 20.0, "cache_read": 0.5},
        "claude-sonnet-5-5": {"input": 2.0, "output": 10.0, "cache_write_5m": 2.5, "cache_write_1h": 4.0, "cache_read": 0.1},
        "claude-haiku-5-5": {"input": 0.1, "output": 0.5, "cache_write_5m": 0.125, "cache_write_1h": 0.2, "cache_read": 0.01}},
    # claude's own total_cost_usd over the proxy's dollars for one run. Band: 0.95-1.05 (the brief's, 2026-11-10); every
    # recorded run read 1.0000, so a run outside it is a price that changed: a note for Dale (D17)
    "price_band": [0.95, 1.05],
    "resumes_per_move": 3,                       # tstack sol-loop's default: three review rounds a change
    # a hold is parked after this many stops since its last park, one more at each step it reaches: intent, a hold
    # that unlocks more earns more tries; band, 3 under 50 cases, then 4, 5, 6 at 200 (2026-11-09: the 63-case
    # memoryref hold needed a fourth move after a ruling)
    "stops_per_hold": 3, "park_steps": [50, 100, 200],
    "queue_cap": 4,                              # D50: no slot starts a move while this many approved commits wait
    "task_wall_s": 5400,                         # no run outlives this (2026-10-28: hangs are never allowed)
    "audit_every": 5,                            # D21: every change read within 5 commits
    "score_every_landings": 3,                   # the scoreboard scores a head after this many landings, or …
    "score_every_s": 7200,                       # … this long since the last score, whichever first
    # a failure waits this long, doubled each time it repeats, up to the cap: intent, a failing step retries without a
    # loop; band, half an hour to 8 h (a night), a note at the third in a row
    "retry_backoff_s": 1800, "backoff_cap_s": 28800,
    "alarm_s": 21600,                            # no move or landing, or no quiet probe with a queue, this long: a note
    # a change of power source counts once the new reading has held this long (O9-2). Derivation: `pmset -g log`'s
    # adapter flaps, 117 changes in six minutes on 2026-11-08 16:15-16:21 and 37 in the minute of 2026-11-09 18:02,
    # held 12 s and 10 s at the longest inside each burst (v10/p3/holds.out); band 36-120 s: at least three times the
    # longest hold seen inside a burst, and at most two minutes of a real unplug before a measurement in flight ends
    "power_settle_s": 60,
    # work runs on battery too (spec battery1 B1), Low Power Mode off and the charge at or above battery_floor_pct; Low
    # Power Mode on battery waits (it halves the machine's rate: D14 reds, wrong learned seconds). Intent and
    # derivation: Dale 2026-11-13, "keep gping with or without battery"; false is the AC-only climb of O8-3
    "battery_runs": True,
    # under this charge the climb waits for AC, as on AC-only, so a landing or a push is never cut by the battery
    # emptying. Derivation: the load's measured drain, 100% to 75% in about 45 minutes under two builders on
    # 2026-11-11 (about 33%/h): 20% leaves about 35 minutes for what is in flight to end and the Mac to be plugged in;
    # band 10-40%: under 10 a check in flight (up to ~10 min) and the push can meet macOS's own low-battery sleep, over
    # 40 more than half of every battery period idles
    "battery_floor_pct": 20,
    # the oracle's audit (climb.py oracle-audit) replays this many stored answers, each in a process of its own at its
    # unit's commit. Derivation: a process pays the corpus's load, 60-90 s at normal priority (v8-report: native parts
    # of 66 s and 91 s) and about 7.5 min at background QoS, where the driver's Julia runs (the bootstrap of 2026-11-10:
    # 2,289 s for two passes of 1,949 labels, each pass's first answer 8 min after its start), so 8 labels hold the
    # verify lock about an hour, one score part's length. Band 4-16: under 4, a seeded sample of a ~2,000-label store
    # reads a landed unit's labels once in many audits; over 16, an audit holds the verify lock past two hours, which
    # every landing's rebased check waits behind
    "oracle_audit_k": 8,
    # the QoS of a native answer's process (measure.answer_labels, one process a label): background only while the
    # bootstrap's wall at it is within a night. Derivation (2026-11-10, v11b/r5, the snapshot and one label, on AC, after
    # ddcf34d7 stopped compiling a closure per snapshot case): 7.6 s a snapshot label's process and 8.8 s a unit label's
    # at default QoS, 34.8 s and 45.3 s at background QoS; the driver adds ~2.7 s a label (10.6 s a label through the
    # door over 384 labels). So 1,949 labels take ~5.7 h at default QoS, one single-threaded process at a time on one
    # P core, never beside a landing check (the lander holds verify and score: D31), and ~19-24 h at background. Band:
    # False until a label's process at background QoS answers within 18 s (a night for the bootstrap), then True
    "oracle_background": False,
    # the QoS of a slot's and the lander's measurement (measure.part_background; the score's stays background). The
    # burn-in window of 2026-11-13 (council throughput analysis, from the events): the one measurement lane was busy 89%
    # of the time, the slots spent 66% of their hours measuring or waiting for it and 25% climbing, and the four
    # performance cores ran landing checks for 25 of 720 minutes; at background QoS the lane's Julia runs on the
    # efficiency cores alone. The oracle's processes above measured 4.6 times faster at default QoS (7.6 s against
    # 34.8 s); a measurement's own ratio is to be read from the first measurements after this lands (case-secs.json).
    # False: one single-threaded process on one performance core, never beside a landing check (the lander takes the
    # verify lock first and a measurement in flight yields it at its next part: D31). Dale 2026-11-13, told the lane was
    # the limit and that this was the lead's default: "keep going", "STOP pausing EVER". True restores background QoS
    "measure_background": False,
    # a measurement waits this long for the lock or a live landing before a note; it then waits on (O5): every holder
    # has its own wall (a measuring process's derived wall, ship_kill_s), so the wait is bounded by theirs, never by a backoff
    "lock_wait_s": 3600,
    # a score that loses more than this share of the table's passing cases is run again before it counts. Derived from the scores
    # of 2026-11-08 to 11-09: 13 of 14 lost 0, one 9 (d72ffacf, 0.7% of 1278, a real ordering loss), one all of them
    # (fc89b8d8, the runner's failure, refused); 2% lies above the real loss and far below the runner's
    "score_loss_band": 0.02,
    # the judge's eval: this many past defects, each at most judge_lines changed lines (a defect a reviewer can read
    # whole); intent, the reviewer refuses what audits found and passes sound moves; band, under judge_recall of the
    # defects refused two blind approvals (K4), under judge_approval of the clean moves approved a note
    "judge_n": 10, "judge_lines": 150, "judge_recall": 0.8, "judge_approval": 0.5,
    # the eval does at most judge_per_tick reviews in one score tick, then resumes at the next (its verdicts kept by
    # judge and case, A8): a tick that ran all of them, twenty and more reviews, held the scoreboard for hours (A6-8).
    # Band: a review takes minutes (a reviewer run of at most task_wall_s), so 4 keep a tick near half an hour and
    # the eval done in about six ticks
    "judge_per_tick": 4,
    # a measuring process's wall is derived (O8-1, D17): wall_factor x (pkg_wall_s for its load + each label's learned
    # seconds, pkg_wall_s for a label never learned; measure.part_wall), so the per-case budgets bound a healthy run and
    # the wall only a run whose cases all run slow; a process past it is never a result (MeasureCut). Intent: no full
    # score passes a fixed wall by its size (the old 10,800 s: v8's own times project a score's compile part at 8,400 to
    # 14,800 s). Band: the learned seconds are the longest seen on origin's own commits while work may run (learn); a full
    # score's driver-timed compile measured 2.45 x smoke.jl's own seconds (round 8, p21's 127 labels), which the
    # learned seconds already carry, and Low Power Mode halves the rate (a measurement is ended in it, item 3), so 3
    # covers a run 50% slower than the slowest seen of each case at once; under 2 a slow hour fails healthy scores, over
    # 4 a hang of every case past its budget is all that ends a run (each case's own budget ends one case)
    "wall_factor": 3,
    # a compiling or native process with no new record (each case flushes `started <label>`) for its case's budget is
    # killed and the case booked errored, located (R5-10, O6-9; Dale 2026-10-28: no hang is allowed, every case has its
    # own budget): a label the driver never timed, and a process's first case, get pkg_wall_s (the first-run wall);
    # a label it timed, max(case_min_s, case_factor x the longest the driver saw it take, R6-9, A7-1). Intent: a case
    # that loops releases the lock, and no passing case is ever booked errored for time. Band, from the climb's own
    # tables (.wt-climb/cases-*.tsv, the 14 scores of 2026-11-08 to 11-10, 16,637 passing rows): median 1.3 s, p99
    # 38 s, p99.9 167 s, the slowest passing 409 s (dicts/dict_build) and the slowest of any outcome 466 s; so 900 s is
    # about twice the slowest case of any outcome; the watch reads the file every watch_s, so the driver's time of a
    # case is to watch_s
    "case_min_s": 900, "case_factor": 20, "watch_s": 5,
    # the native and verdict processes are watched by the same function (O6-9): a native case by its own records, the
    # verdict by case_min_s plus compare_module_s for each call the compile's records and the judge's fixtures name (the
    # run's allowance is the judge's own RUN_BUDGET and NODE_START a call, measure.run_allowance, spec v19 P2). Band: the
    # verdict decodes a line in milliseconds, so 10 s a call passes only when it is stuck
    "compare_module_s": 10,
    # slot k's own Kaimon listens on localhost:kaimon_port+k (never Dale's 2828); one MCP call waits kaimon_http_s (an
    # eval past ~30 s becomes a job Kaimon answers at once); a slot's Kaimon answers within kaimon_start_s of its start,
    # or the move is the driver's failure (a first start compiles Kaimon into its user's depot, minutes, once)
    "kaimon_port": 2840, "kaimon_http_s": 120, "kaimon_start_s": 900,
    "session_warm_s": 1800,                      # a slot's new Kaimon session loads WasmTarget within this
    # a check starts only when, over probe_s with the climb's Julia stopped, the performance cores are this idle, the
    # efficiency cores this idle, and the machine is not paging now: at most swapins_max pages swapped in and
    # decompressions_max decompressed over the probe (O5-3: the pressure level read "warning" for minutes at a time
    # with no paging and admitted 2 of 18 probes, so it refuses at critical alone and is recorded). Band (D17):
    # measured 2026-11-09 11:00-11:20 PST, Dale at work, 40 samples of 15 s: P idle median 95% (>= 85 in 33 of 40), E
    # median 79% (>= 60 in 37 of 40), both in 30 of 40; paging, 40 samples of 15 s, 2026-11-10 00:18-00:28Z, Dale's
    # sessions running and the pressure "warning" in all 40: swap-ins median 8 pages, 39 of 40 at most 349, one 13508;
    # decompressions 24889 to 243262 pages, median 80572, so 2000 and 400000 admit that machine and refuse one that
    # swaps or thrashes. Every probe (with the level) and the check's critical path that follows are events: both
    # bands are re-derived after the first night
    "p_idle": 85, "e_idle": 60, "probe_s": 15, "swapins_max": 2000, "decompressions_max": 400000,
    # after a probe that found the machine busy the lander waits this long before the next (O7-5): every round takes
    # both measurement locks, so a measurement in flight yields and restarts paying its load (a minute or two); the
    # probes of 2026-11-09 failed about a quarter of the time by day, in spells of minutes, so ten minutes keeps a
    # landing within a spell's end and the yields it forces to six an hour at most
    "probe_backoff_s": 600,
    # a green check whose median of the last five critical paths passes this share of D14's red is a note (D17: a
    # check firing inside its band is a bug, so the note reads the median, not one check; O12)
    "near_band": 0.85, "near_band_step": 5,       # ... noted again only when the median rises this many seconds (O5-11)
    # the lander waits d14_backoff_s after a check red on D14's time alone, the item kept in its place (A7-2: approved
    # work is never sent back for time); OTHER is retried other_tries times. d14_share [N, share]: one note for Dale
    # each time the share of the last N checks red on D14's time passes share, or falls back. Band: the climb's 85
    # checks of 2026-11-08 to 11-10 read 34% red (d14-report); 6 or more of 10 at that rate has a 4% chance, so the
    # note means D14 binds now, not a busy hour; tonight's quiet checks read 3 of 3 red (v7b J)
    "d14_backoff_s": 1200, "d14_share": [10, 0.6], "other_tries": 3,
    # a landing's ship.sh is killed past this (its process group, the check with it). Band: a check's hard limit is
    # 480 s (dev/check.sh WT_HARD_LIMIT) and a ship carries at most 6 commits, each checked: 6 x 480 = 2880 s, plus
    # the landing queue's wait; past an hour the ship is hung, never slow
    "ship_kill_s": 3600,
    # the watcher (launch.sh watch-install, run every 300 s) tells Dale when the heartbeat, touched every minute while
    # a loop lives and none has failed five times in a row, is this old: intent, a dead climb is known within a quarter
    # hour (600 s plus the watcher's 300 s at most); band, nine missed beats are no hiccup, an hour is a lost night's quarter
    "watch_stale_s": 600,
    "disk_free_gb": 20,                          # preflight refuses a launch with less free disk under the state
    # no file a build user's process writes grows past this (RLIMIT_FSIZE on the door's line, A6-5: a src change that
    # prints in a loop filled the volume Dale's work shares, through a log on his disk): such a write fails (SIGXFSZ),
    # the run's own failure. Band: the largest legitimate file a run writes is a full score's compile records, every
    # module in base64, past 536 MB on 2026-11-09 (test/runner.jl's RUN_PART_CHARS note); a measurement's native answers
    # hold no module (each label's answer once: the bootstrap's unit for origin's 1,949 labels is 21.6 MB, 19 MB of it two
    # set literals' leaves, measured 2026-11-10); a clone's pack is
    # 68 MB (measured 2026-11-10); the corpus grows, so 8 times the records, far under the free disk
    "file_cap_bytes": 4294967296,
    # a measurement's cases file, read whole by the driver (door.take): one row per case, its why cut at 500 characters
    # (test/smoke.jl), so the 1,949-case corpus writes about 0.2 MB; 256 MB (the literal it replaces) holds a corpus
    # a thousand times larger, stage 2's fuzzing included. A judging process's answers are no file of its own: the
    # driver keeps each case's block as it reads the process's records (measure.watched), streamed, never whole in memory
    "cases_cap_bytes": 268435456,
    # the bytes of one label's answer records, past which its judging process writes no answer but a `noanswer`, located
    # (test/smoke.jl's WT_SMOKE_ANSWER_CAP, measure.answer_labels). Intent: an answer is the leaves of one case's value,
    # read whole and linearly by the driver (measure.unit_blocks). Derivation (2026-11-11, the oracle build's bootstrap
    # unit of origin's 1,949 labels, <scratchpad>/oracle/boot): the largest stored answer is 9,842,945 bytes
    # (dart_set_literals/const_big_set_literal, 98,901 records), the next 9,249,539, the third 149,758. Band 16-64 MiB: at
    # least 1.6 times the largest the snapshot holds, and under 64 MiB, which the linear reader reads in under 2 s
    "answer_cap_bytes": 16777216,
    # origin's fetch, retried [tries, the first sleep, its step] (two slots, the scoreboard and ship.sh fetch side by side:
    # ref-lock races of a second or two): 3 + 7 + 11 + 15 = 36 s of waits outlast a lock and stay under a loop's
    # loop_stale_s; past them a ClimbError and the loop's backoff
    "fetch_tries": [5, 3, 4],
    "tail_chunk": 6,                             # a src-tail hold: one class's next definitions, at most this many
    "base_keep_s": 172800,                       # a base measurement two days old is no move's base: removed
    "fixfirst_lines": 3,                         # an audit's fix-first move touches its finding within this many lines
    # a known red on origin (a G2 loss, a src-test red: core.known_red) stands at most this many landings after it is
    # filed; past it the lander lands fix-first moves alone and Dale gets one note (the landing-check ruling's R4, R11:
    # before, a G2 fix-first parked after its stops left the loss standing while other work landed, since pick skips a
    # parked hold and nothing gated the lander). Intent: a red is fixed by the climb's next moves, never outlived by
    # them. Derivation: a fix-first ranks above every corpus hold, so the next free slot takes it; a move's edit to
    # landed reads 400-2,000 s (wt-landings.tsv) and a hold gets stops_per_hold 3 tries before its park, about 1.7 h,
    # in which the other slot lands 2-3 moves at the climb's measured ~1.4 landings an hour; 6 is twice that. Band
    # 3-12: under 3 one slow fix stops the lander; over 12 a red outlives two scores' worth of landings
    "fixfirst_max_landings": 6,
    # the landings that may stand with a test file of ported code unrun since (measure.src_unverified: since it last ran
    # green in a score's src part or a landing's check, the known reds left out); at it the lander lands nothing until
    # one runs them (the landing-check ruling's R5, R12: a run of failed scores never grows them past it). Derivation:
    # score_every_landings 3, plus the landings one score admits while it runs at the measured pace (~1.5 h at ~1.4
    # landings an hour, 2-3); band 3-12. A landing's check runs its set, so the files outside it count until a window or a score reaches them
    "src_unverified_max": 6,
    # the measured checks of one shape (a change to src/, or one outside it) a landing's prediction needs to fit that
    # shape's own shard start and rate (measure.predict, round 13's ruling S2: a change to src/ read its large sets'
    # shards 10-14 s slower per G than an outside-src set of the same G, 2026-11-11, lc's scratch landings); with fewer
    # it takes the other shape's, named in the prediction. Intent: each shape's rate from its own recent checks, read as
    # soon as two exist. Derivation: two points fit a rate and its start median; checks_measured keeps five of each.
    # Band 2-5: one check is no fit, over five no shape's own measures are read before the window fills
    "src_shape_checks_min": 2,
    # the predictor's priors (measure.predict, round 14's T3: a launch has priors, never "every file"), each a term the
    # measured checks replace as they arrive: g and the shard start once a shape has src_shape_checks_min checks with
    # measured starts (or the other shape has, S2), the load at a shape's first measured check, the ratchet and the
    # imbalance at the first of either. Intent: the first landings of a state with no measured check run a set under
    # the target. Derivation: lc's re-run on this machine (2026-11-12, scratch lander L7, 17 checks on AC under the
    # lander's quiet probe, b1fc9ff0's model): g 10.99 G a judged second for a change to src/ (7 checks) and 10.73
    # outside it (10), each shard's start 374.6 and 376.0 G at the median (369.5-394.7), the load 17 s and 0 s in every
    # check of its shape, the ratchet 78-80 s (70 on the lightest sets), the imbalance 8.0 and 10.4 s at the median
    # (6.0-16.2). Bands: g 8-14 (the machine's measured 6.75-11.5 over two days of model changes, rounded out), the
    # start 340-420 G, the load 10-30 s for a change to src/ and 0-20 outside it, the ratchet 60-100 s, the imbalance
    # 5-15 s
    "src_prior_g": {"src": 11.0, "outside": 10.7}, "src_prior_start_g": 375, "src_prior_load_s": {"src": 17, "outside": 0},
    # the ratchet re-derived (spec v18 Q5): 85-90 s in the eight checks of lc's v17 re-run on a found layer (scratch lander
    # L10, 2026-11-12, every lock run in every landing, L228's behaviour harness among them), 89 at the median, its band
    # 60-100 as above; a prior over the measured ratchet is safe (a smaller share), and the checks replace it at once
    "src_prior_ratchet_s": 89, "src_prior_imbalance_s": 9,
    # a landing's test set is cut to a target computed live (measure.src_target, round 13's ruling S3, which deleted the
    # hand-set target constant and its band: three hand derivations in one day read 125, 115 and 86-112): D14's band
    # (dev/check.sh D14_RED) less a margin per shape (spec v17 Z5, v18 Q5): three times the SECOND-largest POSITIVE
    # judged - predicted of the last src_margin_checks checks of the landing's shape whose prediction was recorded
    # before they ran, on AC, that landed or read red on D14's band alone, between src_margin_min_s and
    # src_margin_max_s, src_margin_start_s until that many exist. src_margin_min_s: intent, the target never sits on
    # the band whatever the model reads; derivation, the busy machine's six fenced checks of 2026-11-11 morning erred
    # 4.8 s at most, so 3 x that rounded to the next ten; band 10-20
    "src_margin_min_s": 10,
    # the checks of ONE shape the margin reads (src_target, per shape): intent, enough that its second-largest error is
    # a recurring one and not one outlier, few enough that a fixed model's improvement shows within a day; derivation,
    # ten checks of a shape at the climb's ~14 landings a day of both shapes, about a day and a half; band 5-20
    "src_margin_checks": 10,
    # the margin until src_margin_checks predicted checks exist: intent, a start that a new model's first errors fit
    # inside; derivation, 3 x 8.2 s (the largest error of the quiet re-measure that gave 115) rounded up; band 20-40
    "src_margin_start_s": 25,
    # the margin's cap (spec v17 Z5): src_target's margin never passes it, and a margin that would is one note to Dale
    # per crossing. Intent: the target stays where a change to src/ can still take files, whatever one bad window of
    # errors reads. Derivation: D14's 140 less the measured smallest path of a change to src/ (its load 17 s and the
    # ratchet 79 s, lc's re-run 2026-11-12) leaves 44 s; 40 keeps a few files of share at the widest margin. Band 30-44
    "src_margin_max_s": 40,
    # the driver's own subprocess walls: a Pkg resolve or the kinds (each loads every package), ship.sh's cheap
    # admission and a parse behind the door; past one it is an event and a backoff (guarded), never a hang
    "pkg_wall_s": 1800, "kinds_wall_s": 1800, "admissible_wall_s": 600, "parse_wall_s": 300,
    # G5's run of the corpus loader over a move's unit (measure.corpus_problems: the snapshot included, the base's units
    # and the move's loaded, as the deps user at background QoS). Derivation: 63 s for the snapshot and one honest unit
    # of 11 labels at background QoS (2026-11-10, loader/p5: the snapshot's include 28 s of it, addendum B; the rest the
    # loader's own first compile); band 300-1200 s: at least four times that run, for the E cores a landing's check
    # leaves and a few hundred units after the snapshot, and at most the twenty minutes past which a move's G5 holds its
    # slot longer than its own measurement
    "loader_wall_s": 600,
    # calls one run's proxy forwards at once: what claude -p itself was observed to open, 1 (claude-2.1.322, a run of
    # three parallel Bash calls, 2026-11-10, v7 report); more is a 429, which claude retries, so an agent's Bash cannot
    # fan calls out past it (R6-6). Band: 1 until a claude is observed to open more
    "proxy_in_flight": 1,
    # what one call through an agent's proxy may take (R6-5): a body over proxy_body_bytes is refused unread (a full
    # 1M-token context is about 4 MB of JSON; 32 MB is 8 times that and far under the 600 MB the red team sent); one
    # deadline a call, proxy_request_s of the role's awake time (claude's own API timeout, 600 s, bounds every answer it
    # waits for; twice it); leaving a run waits proxy_join_s for calls still answering, so their usage is booked (an
    # answer's tail after its agent is reaped), then shuts them. Band: a run's exit is never held past proxy_join_s
    "proxy_body_bytes": 33554432, "proxy_request_s": 1200, "proxy_join_s": 30,
    # every git network call of the driver, its loops and the ship.sh it runs is cut when it moves under
    # git_low_speed[0] bytes a second for git_low_speed[1] s (http.lowSpeedLimit, http.lowSpeedTime; O6-6: a fetch with
    # no timeout hung the lander's round for good). Band: the ruling's numbers; origin's fetches move kilobytes to a
    # few megabytes, so a link that cannot move 1 kB/s for a minute is down, never slow
    "git_low_speed": [1000, 60],
    # each loop stamps logs/<loop>.stamp at every iteration and at every step of progress (an event, a poll of a run it
    # waits on, a record of a measured case, a wait on a lock); the heartbeat stops when any loop's stamp is older
    # than its bound (O6-6: one dead or hung loop was silent while another lived). Band: above the longest step that
    # stamps nothing (dev/ship.sh --admissible, admissible_wall_s 600 s; a fetch's five tries under git_low_speed,
    # about 360 s), so 1800 s is three times it; the watcher then speaks within watch_stale_s more
    "loop_stale_s": {"scoreboard": 1800, "lander": 1800, "climb": 1800},
    # a wait on a lock another process of the climb holds is bounded (O6-6), past it an event and the step fails into
    # its loop's backoff: a role's lock (using()) by the longest use of that role (a slot or a review: one agent run and
    # its one retry, 2 x task_wall_s; a measurement or a score: the wall of a full score's longest part, which bounds
    # every measurement's part, a move's labels being a subset of the corpus (measure.part_wall: wall_factor 3 x
    # (pkg_wall_s 1,800 + 14,800 s, the upper end of a full score's projected seconds, round 9's operator) = 49,800 s;
    # past it a wait is an event and a backoff, never a failure of the holder, A9-4); the landing: a land
    # job's wall ship_kill_s and its copies; deps: two image builds of pkg_wall_s, also the .deps.lock's), the agent
    # probe's by a slot's, the state's own lock (state_lock_s) by far more than its longest hold (spend_days's cold
    # read of every transcript, 10.5 s measured, round 6)
    "role_wait_s": {"slot": 10800, "review": 10800, "measure": 49800, "score": 49800, "land": 5400, "deps": 3600},
    "state_lock_s": 600,
    # the door's short walls (A6-10): step_wall_s for a step that is one small command as a build user (a file put, a
    # home prepared, a directory made, one probe's try), each under a second as measured, so a minute is a hang;
    # tree_wall_s for a tree the user copies, clones, bundles or removes (a clone of origin's history by hard links, a
    # home's clean, a measurement's tree and its depot), seconds as measured and a depot's removal tens, so ten minutes
    "step_wall_s": 60, "tree_wall_s": 600,
    # the polls (A6-10): a slot's Kaimon job polled every kaimon_poll_s (an eval past ~30 s becomes a job, so a poll
    # of its period adds at most that); a starting Kaimon pinged with a kaimon_ping_s call every poll_s["kaimon_up"];
    # the lander's scan of the quiet window every poll_s["scan"] (a process that started meanwhile is stopped within
    # it); a lock's waiter every poll_s["lock"], ship.sh's landing lock's every poll_s["landing_lock"] and a yielded
    # lock's every poll_s["yield"]: each far under the wall it serves and over a busy loop's
    # a land job's wait polls every poll_s["land_job"], asking the disk each time (R7-6)
    "kaimon_poll_s": 30, "kaimon_ping_s": 10, "poll_s": {"kaimon_up": 5, "scan": 10, "lock": 5, "landing_lock": 20, "yield": 2,
                                                          "land_job": 5},
    # what a land job's check copies back into Dale's tree (A7-6, R7-6): its `.wtd/*.out`, at most `files` of them, each
    # at most `file_bytes`, `total_bytes` in all. Band: a check writes 13 outputs, about 120 KB together, the ratchet's
    # the largest at 76 KB (.git/wt-ship-failed, d14-report's runs); a failing test's output can be long, so 32 files,
    # 64 MB each (the literal it replaces, A6-10) and 128 MB in all (a thousand times what a check writes) bound a check
    # that writes without end; one file past its cap is the job's own red, past the total the rest is not copied
    "land_outs": {"files": 32, "file_bytes": 67108864, "total_bytes": 134217728},
    # a ship.sh the lander ends gets term_grace_s after its TERM before its group is killed (its check's own cleanup)
    "term_grace_s": 30,
    # the governor reads each transcript changed within spend_window_days: the week's window (week_start, Sunday at most
    # 7 days back) and a day for a session open across midnight
    "spend_window_days": 8,
    # a role's recorded stops (door.awake) are kept stops_keep_s: past every wall a stop can lengthen (role_wait_s's
    # largest, 49800 s)
    "stops_keep_s": 86400,
}
# D14 and D48: the budget and the models change by a commit naming Dale's words, never by config; so does every number a
# ledger row states (K2): D50's queue cap, D21's five commits
LOCKED_KEYS = ("week_weighted", "margin", "week_pause", "budget_holds", "climber_model", "ruler_model", "fable_model", "fable_per_day",
               "queue_cap", "audit_every")

def hill_defaults():
    """HILL.md's one generated paragraph: every value DEFAULTS holds, the locked keys marked."""
    words = [f"`{k}` {json.dumps(v)}" + (" (locked)" if k in LOCKED_KEYS else "") for k, v in DEFAULTS.items()]
    out, line = ["The driver's numbers, generated from dev/climb/defaults.py, where each states its intent and band:"], ""
    for w in words:
        if line and len(line) + len(w) + 2 > 118:
            out.append(line + ","); line = w
        else:
            line += (", " if line else "") + w
    return "\n".join(out + [line + "."])

def hill_faults(text):
    """Why HILL.md's text `text` does not hold the generated paragraph, or None."""
    m = re.search(r"<!-- defaults:begin -->\n(.*?)<!-- defaults:end -->", text, re.S)
    if not m:
        return "dev/climb/HILL.md has no <!-- defaults:begin --> ... <!-- defaults:end --> paragraph"
    return None if m.group(1) == hill_defaults() + "\n" else \
        "dev/climb/HILL.md's DEFAULTS paragraph differs from dev/climb/defaults.py: `python3 dev/climb/defaults.py hill`"

if __name__ == "__main__":
    if sys.argv[1:2] == ["hill"]:
        print(hill_defaults())
    elif sys.argv[1:2] == ["check"] and len(sys.argv) == 3:
        why = hill_faults(open(sys.argv[2]).read())
        print(why or "dev/climb/HILL.md's DEFAULTS paragraph is the generated one")
        sys.exit(1 if why else 0)
    else:
        print(__doc__, file=sys.stderr); sys.exit(2)
