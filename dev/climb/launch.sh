#!/usr/bin/env bash
# dev/climb/launch.sh — start the climb (dev/climb/HILL.md), every part of it a program run by
# dev/climb/climb.py; no resident agent waits on anything.
#
#   bash dev/climb/launch.sh          stop the stale loops, queue the paused lanes' work, then start the
#                                     scoreboard, the judge's eval and the climb (which audits first: audit #97's
#                                     range) in the background
#   bash dev/climb/launch.sh stop     stop them and every claude and julia they started (each runs in its own
#                                     process group); a stopped move's work stays on its slot, salvaged next time
#   bash dev/climb/launch.sh pause    the climbers start no new move until `resume`
#   bash dev/climb/launch.sh resume
#   bash dev/climb/launch.sh status   the scoreboard (`python3 dev/climb/climb.py report`)
#
# Run it from a worktree at origin/wt2 (the one the driver's templates are read from).
set -uo pipefail
cd "$(dirname "$0")/../.."
common="$(git rev-parse --path-format=absolute --git-common-dir)"
state="$(dirname "$common")"; [ "$(basename "$common")" = .git ] || state="$common"
state="$(dirname "$state")/.wt-climb"; mkdir -p "$state/logs"   # outside the repository: no agent's sandbox can write it
py="python3 dev/climb/climb.py"
case "${1:-start}" in
  stop)
    for p in "$state"/pids/*; do
      [ -f "$p" ] || continue; pid=$(cat "$p")
      kill -TERM -- "-$pid" 2>/dev/null && echo "stopping $(basename "$p") and its children"
      for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -0 "$pid" 2>/dev/null && { kill -KILL -- "-$pid" 2>/dev/null; echo "  killed $(basename "$p") after 60 s"; }
      rm -f "$p"
    done
    exit 0 ;;
  pause)  touch "$state/PAUSE"; echo "paused: no new move starts"; exit 0 ;;
  resume) rm -f "$state/PAUSE"; echo "resumed"; exit 0 ;;
  status) $py report; exit 0 ;;
  start) ;;
  *) echo "launch: start|stop|pause|resume|status"; exit 2 ;;
esac
git fetch -q origin wt2
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/wt2)" ] || { echo "launch: this tree is not at origin/wt2; land the harness first"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
$py preflight --kill || true
sleep 10   # the stale loops exit before preflight looks again
$py preflight || { echo "launch: preflight still fails; fix what it names first"; exit 1; }
$py harvest
mkdir -p "$state/pids"
start() {   # one background part, its pid kept for `stop`, its log in the state dir
  nohup $py "$1" > "$state/logs/$1.log" 2>&1 &
  echo $! > "$state/pids/$1"; echo "started $1 (pid $!, log $state/logs/$1.log)"
}
start scoreboard
# the judge's eval runs while the first score does (climbers wait for a scored head anyway); once, then on demand
[ -f "$state/judge-eval.json" ] || start judge-eval
start run         # its first slot audits first whenever the lag is past its band (audit #97's range at launch)
echo
$py report
