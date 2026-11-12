#!/usr/bin/env bash
# dev/climb/launch.sh — start the climb (dev/climb/HILL.md), every part of it a program run by
# dev/climb/climb.py; no resident agent waits on anything.
#
#   bash dev/climb/launch.sh          stop the stale loops, then start the loops in the background: the scoreboard,
#                                     the lander and one loop per slot. Each runs one iteration of climb.py per process
#                                     from the driver's own worktree (../.worktrees/climb-driver), fast-forwarded to
#                                     origin/wt2 before every iteration: the climb runs landed code only, a change to it
#                                     reaches the climb by landing, and nothing waits for a restart
#   bash dev/climb/launch.sh stop     stop them and every claude and julia they started (each loop runs in its own
#                                     process group), then resume every process a stopped landing had stopped
#   bash dev/climb/launch.sh pause    no new move starts and nothing lands until `resume` (any PAUSE file pauses)
#   bash dev/climb/launch.sh resume
#   bash dev/climb/launch.sh status   the scoreboard (`python3 dev/climb/climb.py report`)
#   bash dev/climb/launch.sh probe    the door's probes: as each build user what the door refuses (no tokens; every
#                                     launch runs it and refuses on a failure), then one agent run (agent_probe_usd)
#   bash dev/climb/launch.sh watch-install   the watcher (O5-8, O5-9, D-H): a launchd user agent whose script lives
#                                     outside ~/Documents (macOS denies a launchd job the protected folders and Dale
#                                     grants no Full Disk Access) and posts a notification after every login, and when
#                                     the heartbeat the loops keep is watch_stale_s old; `watch-uninstall` removes it.
#                                     The climb itself never starts at login: a reboot waits for Dale's FileVault
#                                     password, and the watcher tells him to run launch.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)   # this script's own directory: its climb.py (here)
cd "$(dirname "$0")/../.."
common="$(git rev-parse --path-format=absolute --git-common-dir)"
repo="$(dirname "$common")"; [ "$(basename "$common")" = .git ] || repo="$common"
state="${WT_CLIMB_STATE:-$(dirname "$repo")/.wt-climb}"; mkdir -p "$state/logs"   # outside the repository: no agent's sandbox can write it
drv="$(dirname "$repo")/.worktrees/climb-driver"
export PYTHONDONTWRITEBYTECODE=1
watch="$HOME/Library/Application Support/wt-climb"   # the heartbeat and the watcher: outside ~/Documents (TCC)
hb="$watch/heartbeat"
# this boot's start (kern.boottime's seconds): every pid a launch records carries it, and a recorded pid is alive only
# when it was recorded in this boot and runs (door.alive's test, O7-6: a pid of an earlier boot is another process now)
boot=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
alive() { [ -n "$1" ] && [ "$2" = "$boot" ] && kill -0 "$1" 2>/dev/null; }
# a note for Dale written by bash alone, for when the driver itself cannot run (O5-9: a landed change that fails to
# import kills every loop, and alarm() lives in the broken modules)
bash_note() {
  printf '\n## %s — %s\n%s\n' "$(date -u +%FT%T+00:00)" "$1" "$2" >> "$state/for-dale.md"
  [ -n "${WT_CLIMB_STATE:-}" ] || /usr/bin/osascript -e "display notification \"${2//\"/}\" with title \"WasmTarget climb\" subtitle \"${1//\"/}\"" >/dev/null 2>&1
}
sync_driver() {   # the driver's worktree at origin/wt2: made once, then only fast-forwarded, never edited
  # its fetch is cut when it moves under DEFAULTS git_low_speed (O6-6), as every git network call of the driver's
  [ -n "${lowspeed:-}" ] || lowspeed=$(here default git_low_speed | tr -d '[] ')
  git -C "$repo" -c http.lowSpeedLimit="${lowspeed%,*}" -c http.lowSpeedTime="${lowspeed#*,}" fetch -q origin wt2 ||
    { echo "launch: cannot fetch origin/wt2"; return 1; }
  [ -d "$drv" ] || bash dev/lane.sh start climb-driver || return 1   # as every climb worktree: its Manifest resolved
  [ -z "$(git -C "$drv" status --porcelain --untracked-files=no)" ] || { echo "launch: $drv has local changes; the climb runs landed code only"; return 1; }
  git -C "$drv" merge-base --is-ancestor HEAD origin/wt2 || { echo "launch: $drv is not on origin/wt2"; return 1; }
  git -C "$drv" checkout -q --detach origin/wt2
}
py() { (cd "$drv" && python3 dev/climb/climb.py "$@"); }
here() { python3 "$HERE/climb.py" "$@"; }
# a launch's note for Dale, through the driver's alarm: at most one per alarm_s for each name (O4)
note() { here alarm "$1" "$2" "$3" >/dev/null 2>&1; }
case "${1:-start}" in
  stop)
    for p in "$state"/pids/*; do
      [ -f "$p" ] || continue; read -r pid pboot < "$p"
      alive "$pid" "$pboot" || { rm -f "$p"; continue; }   # an earlier boot's: its group is another's now
      kill -TERM -- "-$pid" 2>/dev/null && echo "stopping $(basename "$p") and its children"
      for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -0 "$pid" 2>/dev/null && { kill -KILL -- "-$pid" 2>/dev/null; echo "  killed $(basename "$p") after 60 s"; }
      rm -f "$p"
    done
    rm -f "$hb"   # a climb stopped on purpose: the watcher stays silent
    python3 "$HERE/door.py" reap && echo "reaped every build user's processes"   # sudo's children leave the loops' groups
    # every process a landing stopped is recorded with its owner; the owners are gone now, so each is resumed
    if [ -d "$drv" ]; then py resume-stopped; else python3 dev/climb/climb.py resume-stopped; fi
    exit 0 ;;
  pause)  touch "$state/PAUSE"; echo "paused: no new move starts and nothing lands"; exit 0 ;;
  resume) rm -f "$state/PAUSE"; echo "resumed"
          # a killed driver's orphans reaped before work starts again (door.reap_orphans: each role no process uses)
          if [ -d "$drv" ]; then py reap-orphans; else python3 dev/climb/climb.py reap-orphans; fi; exit 0 ;;
  status) if [ -d "$drv" ]; then py report; else python3 dev/climb/climb.py report; fi; exit 0 ;;
  probe) sync_driver || exit 1; py door-probe && py agent-probe; exit $? ;;
  watch-install)
    # the watcher's script and its agent, both outside ~/Documents; it reads only the heartbeat's age and the login
    mkdir -p "$watch"; agent="$HOME/Library/LaunchAgents/org.grouptherapy.wt-climb-watch.plist"
    cat > "$watch/watch.sh" <<'WATCH'
#!/bin/bash
# the climb's watcher (dev/climb/launch.sh watch-install): run by launchd at login and every 300 s
d="${WT_WATCH_DIR:-$HOME/Library/Application Support/wt-climb}"; hb="$d/heartbeat"; stale="${WT_WATCH_STALE_S:-600}"
say() { osascript -e "display notification \"$2\" with title \"WasmTarget climb\" subtitle \"$1\"" >/dev/null 2>&1; echo "$(date -u +%FT%TZ) $1: $2" >> "$d/watch.log"; }
now=$(date +%s); age=$(( now - $(stat -f %m "$hb" 2>/dev/null || echo 0) ))
# the machine's last wake: within $stale of it the loops have not yet stamped since the sleep, so a stale heartbeat
# then is the sleep's, never a dead climb (O7-1): the verdict waits for the next run
woke=$(( now - $(sysctl -n kern.waketime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p' | grep . || echo 0) ))
login=$(ps -ax -o pid=,uid=,comm= | awk -v u="$(id -u)" '$2 == u && $3 ~ /\/loginwindow$/ { print $1; exit }')   # this login's
if [ "$login" != "$(cat "$d/login" 2>/dev/null)" ]; then   # the first run of this login
  echo "$login" > "$d/login"
  [ -f "$hb" ] && [ "$age" -le "$stale" ] || say "after a login" "The climb is not running. Run: bash dev/climb/launch.sh"
elif [ -f "$hb" ] && [ "$age" -gt "$stale" ] && [ "$woke" -gt "$stale" ] && [ "$(cat "$d/notified" 2>/dev/null)" != "$(stat -f %m "$hb")" ]; then
  stat -f %m "$hb" > "$d/notified"   # once for each stale heartbeat
  say "the heartbeat stopped" "No loop of the climb has run for $(( age / 60 )) min. Read the climb's logs and for-dale.md, then run: bash dev/climb/launch.sh"
fi
WATCH
    chmod 755 "$watch/watch.sh"
    cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>org.grouptherapy.wt-climb-watch</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$watch/watch.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>WT_WATCH_STALE_S</key><string>$(here default watch_stale_s)</string><key>PATH</key><string>/usr/bin:/bin:/usr/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PLIST
    plutil -lint "$agent" && launchctl bootstrap "gui/$(id -u)" "$agent" && echo "installed $agent"; exit $? ;;
  watch-uninstall)
    agent="$HOME/Library/LaunchAgents/org.grouptherapy.wt-climb-watch.plist"
    launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null; rm -f "$agent"; echo "removed $agent"; exit 0 ;;
  start) ;;
  *) echo "launch: start|stop|pause|resume|status|probe|watch-install|watch-uninstall"; exit 2 ;;
esac
# one climb at a time (20): a recorded loop alive whose command line is this script's runs already (exit 0); a recorded
# pid that is alive but another program's is a stale file (red 10): removed, with a note, and this launch exits 1
for p in "$state"/pids/*; do
  [ -f "$p" ] || continue; read -r pid pboot < "$p"
  alive "$pid" "$pboot" || { rm -f "$p"; continue; }
  if ps -o command= -p "$pid" | grep -q "dev/climb/launch.sh\|wt-climb-heartbeat"; then echo "launch: $(basename "$p") runs already (pid $pid); stop first"; exit 0; fi
  rm -f "$p"; note launch-pid "launch: a stale pid file" "$p named pid $pid, alive but $(ps -o command= -p "$pid" | cut -c1-120). Default taken: the file is removed; launch again."
  echo "launch: $p named pid $pid, another program's; removed"; exit 1
done
sync_driver || { note launch-driver "launch refused: the driver's worktree" "launch.sh could not bring $drv to origin/wt2 (see the launch output)."; exit 1; }
# launch itself runs as landed: from the driver's worktree, never from the tree it was called in
[ "$(pwd -P)" = "$(cd "$drv" && pwd -P)" ] || exec bash "$drv/dev/climb/launch.sh" "$@"
# one preflight a launch (O7-8): it ends the stale loops and waits for them itself
if ! out=$(py preflight --kill 2>&1); then
  echo "$out"; note launch-preflight "launch refused: preflight fails" "$out"; echo "launch: preflight still fails; fix what it names first"; exit 1
fi
# the door proved at every launch, for no tokens (item 1): a failure refuses the launch, located
if ! out=$(py door-probe 2>&1); then
  echo "$out" | grep -v '^held'; note launch-door "launch refused: the door probe failed" "$(echo "$out" | grep -v '^held' | head -20)"; exit 1
fi
date -u +%FT%T+00:00 > "$state/launched-at"   # the stall alarm counts from here (architect 13)
mkdir -p "$state/pids"
set -m   # each loop in its own process group, so `stop` ends a loop with the move it runs
loop() {   # a loop of one part: $1 its name, $2 its sleep after an idle (exit 3) iteration, the rest climb.py's command
  local name=$1 idle=$2; shift 2
  ( fails=0; export WT_CLIMB_LOOP=$name   # each iteration stamps logs/$name.stamp (core.beat), as does this loop
    while :; do
      touch "$state/logs/$name.stamp"
      if sync_driver; then py "$@"; rc=$?; else rc=1; fi
      # its consecutive failures (an exit but 0 or 3), which the heartbeat reads; at the fifth a note from bash (O5-9)
      if [ $rc -eq 0 ] || [ $rc -eq 3 ]; then fails=0; else fails=$((fails + 1)); fi
      echo "$fails" > "$state/logs/$name.fails"
      [ "$fails" -eq 5 ] && bash_note "the $name loop fails" "Its last five iterations exited $rc ($state/logs/$name.log). Default taken: it keeps trying every 30 s; the heartbeat stops."
      [ $rc -eq 0 ] || sleep "$([ $rc -eq 3 ] && echo "$idle" || echo 30)"
    done ) >> "$state/logs/$name.log" 2>&1 &
  echo "$! $boot" > "$state/pids/$name"; echo "started $name (pid $!, log $state/logs/$name.log)"
}
loop scoreboard 120 score-tick
loop lander 180 lander
for n in $(py slot-names); do loop "$n" 120 slot "$n"; done   # climb.py slot_names: none for slots: 0
# the heartbeat (O5-8, O6-6): touched every minute while every loop's stamp (logs/<loop>.stamp, written at each
# iteration and each step of progress, core.beat) is younger than that loop's DEFAULTS loop_stale_s and none has failed
# five times in a row, under a power assertion named for it (pmset -g assertions: "caffeinate asserting on behalf of
# '.../wt-climb-heartbeat'"), so the Mac does not idle to sleep under the climb on AC and the watcher tells Dale when any
# one loop dies or hangs; `caffeinate -s` holds only on AC (O9-2: on battery the climb starts nothing, and `-i` kept the
# Mac awake until its battery emptied; the driver's awake clocks survive a sleep, O7-1)
stamps=""; for n in scoreboard lander $(py slot-names); do
  stamps="$stamps $n:$(here default loop_stale_s | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d[sys.argv[1].split("-")[0]])' "$n")"
done
mkdir -p "$watch"; cat > "$watch/wt-climb-heartbeat" <<BEAT
#!/bin/bash
while :; do
  fresh=1; now=\$(date +%s)
  for nb in$stamps; do s="$state/logs/\${nb%%:*}.stamp"; [ \$(( now - \$(stat -f %m "\$s" 2>/dev/null || echo 0) )) -le \${nb##*:} ] || fresh=0; done
  bad=0; for f in "$state"/logs/*.fails; do [ "\$(cat "\$f" 2>/dev/null || echo 0)" -ge 5 ] && bad=1; done
  [ \$fresh -eq 1 ] && [ \$bad -eq 0 ] && touch "$hb"
  # a killed driver's orphans, each minute (door.reap_orphans: a build user's process whose role no process uses)
  (cd "$drv" && python3 dev/climb/climb.py reap-orphans) >> "$state/logs/heartbeat.log" 2>&1
  sleep 60
done
BEAT
chmod 755 "$watch/wt-climb-heartbeat"; rm -f "$state"/logs/*.fails; touch "$hb"
/usr/bin/caffeinate -s "$watch/wt-climb-heartbeat" > /dev/null 2>&1 &
echo "$! $boot" > "$state/pids/heartbeat"; echo "started the heartbeat (pid $!, $hb)"
echo
py report
