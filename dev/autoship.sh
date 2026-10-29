#!/usr/bin/env bash
# dev/autoship.sh — a lane's committed work lands without the lane remembering to ship it.
#
#   bash dev/autoship.sh          loop, in a lane's worktree: whenever HEAD has commits origin/wt2 lacks,
#                                 no ship of this lane runs, and HEAD has not moved for SETTLE seconds,
#                                 run dev/ship.sh; idle a minute between looks
#
# A lane commits only work that is green in its own tests; this lands it in queue order (dev/ship.sh's
# ticket) the moment it settles, never waiting on the lane's attention (2026-10-28: lanes held green
# commits 10 to 20 minutes unshipped while the landing queue stood empty, flagged tick after tick).
# A lane mid-rebase or mid-merge is skipped (dev/ship.sh refuses it too); each ship's output goes to
# .wtd/autoship.out, a red one recorded in the common dir's wt-ship-failures.tsv as every ship's is.
set -uo pipefail
MARCH=wt2
SETTLE=60   # a literal: HEAD must rest this long, so a lane's commit series lands whole
cd "$(dirname "$0")/.."
lane=$(pwd -P)
common="$(git rev-parse --path-format=absolute --git-common-dir)"
gitdir="$(git rev-parse --path-format=absolute --git-dir)"
mkdir -p .wtd
# one loop per lane: a second would see "no ship of this lane runs" at the same moment and queue the same
# HEAD twice (march-monitor-a, 00:48: two loops found in one lane)
alock="$common/wt-autoship/$(basename "$lane")"; mkdir -p "$common/wt-autoship"
if ! mkdir "$alock" 2>/dev/null; then
  holder=$(cat "$alock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then echo "autoship: already running for this lane (pid $holder)"; exit 2; fi
  rm -rf "$alock"; mkdir "$alock" || { echo "autoship: cannot take this lane's loop lock"; exit 2; }
fi
echo $$ > "$alock/pid"; trap 'rm -rf "$alock"' EXIT
last=""; since=$(date +%s)
# a HEAD whose ship went red is not shipped again until HEAD moves: the lane fixes it, its new commit
# settles and ships (march-monitor-a, 00:29: a red HEAD re-shipped each minute would take a queue turn and
# a check every time)
failed=""
while :; do
  git fetch -q origin "$MARCH" 2>/dev/null
  head=$(git rev-parse HEAD)
  [ "$head" = "$last" ] || { last=$head; since=$(date +%s); }
  busy=0
  for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do [ -e "$gitdir/$op" ] && busy=1; done
  holder=$(cat "$common/wt-ship/$(basename "$lane").lock/pid" 2>/dev/null || true)
  [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null && busy=1
  ahead=$(git rev-list --count "origin/$MARCH..HEAD" 2>/dev/null || echo 0)
  if [ "$busy" = 0 ] && [ "$ahead" -gt 0 ] && [ "$head" != "$failed" ] && [ $(( $(date +%s) - since )) -ge "$SETTLE" ]; then
    echo "autoship: $(date -u +%FT%TZ) shipping $ahead commit(s) at $(git rev-parse --short HEAD)"
    bash dev/ship.sh > .wtd/autoship.out 2>&1
    grep -E '^ship: (landed|pushed|a commit|REFUSED|recorded)' .wtd/autoship.out | tail -3
    if grep -qE '^ship: (a commit.s check is red|REFUSED|the rebase|origin/)' .wtd/autoship.out; then
      failed=$head
      echo "autoship: $(git rev-parse --short "$head") went red; not shipped again until HEAD moves"
    fi
  fi
  sleep 60
done
