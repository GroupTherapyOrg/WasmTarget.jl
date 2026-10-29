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
  if [ -n "$holder" ] && [ "$holder" != $$ ] && kill -0 "$holder" 2>/dev/null; then echo "autoship: already running for this lane (pid $holder)"; exit 2; fi
  rm -rf "$alock"; mkdir "$alock" || { echo "autoship: cannot take this lane's loop lock"; exit 2; }
fi
echo $$ > "$alock/pid"; trap 'rm -rf "$alock"' EXIT
last=""; since=$(date +%s)
# a HEAD whose ship went red is not shipped again until HEAD moves: the lane fixes it, its new commit
# settles and ships (march-monitor-a, 00:29: a red HEAD re-shipped each minute would take a queue turn and
# a check every time); or until origin/wt2 moves, since a red can be the base's own (a230adc6 turned four
# lanes' checks red at 122-126 s, 09:11-09:23, and its revert would have left them held)
failed=""; failed_base=""
# a running loop is the script it started as: when a rebase brings a new dev/autoship.sh (or dev/ship.sh), the
# loop starts again as the new one, keeping its lock (2026-10-29: four lanes' loops ran three revisions old)
me=$(cat dev/autoship.sh dev/ship.sh | cksum)
while :; do
  [ "$(cat dev/autoship.sh dev/ship.sh 2>/dev/null | cksum)" = "$me" ] || { echo "autoship: $(date -u +%FT%TZ) its script changed; starting again as the new one"; exec bash dev/autoship.sh; }
  git fetch -q origin "$MARCH" 2>/dev/null
  head=$(git rev-parse HEAD)
  [ "$head" = "$last" ] || { last=$head; since=$(date +%s); }
  busy=0
  for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do [ -e "$gitdir/$op" ] && busy=1; done
  holder=$(cat "$common/wt-ship/$(basename "$lane").lock/pid" 2>/dev/null || true)
  [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null && busy=1
  # the commits origin/wt2 lacks as patches: one another ship already carried under a new hash is not ahead
  # (an empty commit carries nothing: a lane's duplicate landed as one, 0cf4f0ea, 08:43)
  ahead=$(git log --diff-filter=ACDMRT --format=%H "origin/$MARCH..HEAD" 2>/dev/null | grep -cxFf <(git cherry "origin/$MARCH" HEAD 2>/dev/null | sed -n 's/^+ //p'))
  if [ "$busy" = 0 ] && [ "$ahead" -gt 0 ] && { [ "$head" != "$failed" ] || [ "$(git rev-parse "origin/$MARCH")" != "$failed_base" ]; } && [ $(( $(date +%s) - since )) -ge "$SETTLE" ]; then
    echo "autoship: $(date -u +%FT%TZ) shipping $ahead commit(s) at $(git rev-parse --short HEAD)"
    bash dev/ship.sh > .wtd/autoship.out 2>&1
    grep -E '^ship: (landed|pushed|a commit|REFUSED|recorded)' .wtd/autoship.out | tail -3
    if grep -qE '^ship: (a commit.s check is red|REFUSED|the rebase|origin/)' .wtd/autoship.out; then
      failed=$head; failed_base=$(git rev-parse "origin/$MARCH")
      echo "autoship: $(git rev-parse --short "$head") went red; not shipped again until HEAD moves"
    fi
  fi
  sleep 60
done
