#!/usr/bin/env bash
# Land this worktree's commits on the march branch: rebase onto it, run dev/check.sh on every
# commit, push fast-forward. Never a merge commit, never a force push.
#
# The lane takes the landing lock first, then rebases onto the march branch and checks each commit,
# so every commit is checked exactly once and never again: a serialized merge queue (bors's
# one-at-a-time mode). The machine runs one check at a time (dev/check.sh, D31), so lanes checking
# side by side only queued for the one slot and then re-checked under the lock when another lane
# landed meanwhile, two checks a landing; waiting lanes keep working in their own trees.
set -uo pipefail
# a lane may run dev/autoship.sh beside its work, which calls this script whenever its committed work settles
# the one march branch on origin (D23): every lane lands here; worktrees and their branches stay local
MARCH=wt2
cd "$(dirname "$0")/.."
lane=$(pwd -P)
common="$(git rev-parse --path-format=absolute --git-common-dir)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "ship: uncommitted changes stay here and are not landed"
# a lane mid-rebase, mid-merge, mid-cherry-pick or mid-revert has a HEAD that is not its work: refuse,
# never land a half-finished history (a ship from a mid-rebase worktree landed the wrong commits twice)
gitdir="$(git rev-parse --path-format=absolute --git-dir)"
for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  [ -e "$gitdir/$op" ] && { echo "ship: REFUSED: this worktree is mid-operation ($op); finish or abort it, then ship"; exit 2; }
done
# the landing runs in a scratch worktree of this lane's HEAD, so the lane keeps editing while it
# lands: a rebase or an abort there never touches the lane's files (a lane lost uncommitted edits
# when ship rebased its own tree). Its untracked Manifest and preferences come along, and its checks
# compile into the lane's depot.
start=$(git rev-parse HEAD)
# one landing carries at most SHIP_MAX commits, the lane's oldest; the rest wait for its next ship, so the
# landing lock passes between lanes (march-monitor-a, 22:40: an eighteen-commit landing held the lock
# twenty minutes while two lanes' ports waited behind it)
SHIP_MAX=6   # a literal, never set from a lane's shell
git fetch -q origin "$MARCH" 2>/dev/null
if [ "$(git rev-list --count "origin/$MARCH..HEAD" 2>/dev/null || echo 0)" -gt "$SHIP_MAX" ]; then
  start=$(git rev-list --reverse "origin/$MARCH..HEAD" | sed -n "${SHIP_MAX}p")
  echo "ship: this landing carries the oldest $SHIP_MAX of $(git rev-list --count "origin/$MARCH..HEAD") commits; ship again for the rest"
fi
scratch="$common/wt-ship/$(basename "$lane")"
# one landing per lane at a time: a second ship from this worktree would remove the first's scratch
mkdir -p "$common/wt-ship"
lanelock="$scratch.lock"
if ! mkdir "$lanelock" 2>/dev/null; then
  holder=$(cat "$lanelock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "ship: a landing of this lane is already running (pid $holder); wait for it, then ship again"; exit 2
  fi
  rm -rf "$lanelock"; mkdir "$lanelock" || { echo "ship: cannot take this lane's landing slot"; exit 2; }
fi
echo $$ > "$lanelock/pid"
git worktree remove --force "$scratch" 2>/dev/null; rm -rf "$scratch"
git worktree add -q --detach "$scratch" "$start" || { echo "ship: cannot make the scratch worktree"; exit 1; }
for f in Manifest.toml LocalPreferences.toml; do [ -f "$lane/$f" ] && cp "$lane/$f" "$scratch/$f"; done
export WT_DEPOT_DIR="$lane"
cleanup_scratch() { cd "$lane" && git worktree remove --force "$scratch" 2>/dev/null; rm -rf "$lanelock"; }
cd "$scratch"
log="$common/wt-landings.tsv"   # one log for every lane: D13's band
lock="$common/wt-landing-lock"
# under the lock every commit is checked on its own tree, against its parent, with git's own rebase
# variables cleared: the ratchet's plants make scratch repositories, and an inherited GIT_DIR or
# GIT_INDEX_FILE would point them at this one
checked_rebase() {
  # each commit green on its own tree is pushed at once, under the lock, so a long stack lands as it goes
  # and a red commit keeps the green ones before it (march-corrector, 21:51: a ten-commit stack held the
  # port count flat for 25 minutes, pushing only once all ten were green)
  mkdir -p .wtd
  if ! { git rebase -q --no-keep-empty --empty=drop "origin/$MARCH" --exec 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_REFLOG_ACTION CHECK_BASE=HEAD~1 bash dev/check.sh && git push -q origin HEAD:'"$MARCH"' && echo "ship: pushed $(git log -1 --format="%h %s" | cut -c1-90)"' 2>&1 | tee .wtd/rebase.out; [ "${PIPESTATUS[0]}" -eq 0 ]; }; then
    record_failure
    if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then git rebase --abort; fi
    return 1
  fi
}
# a red landing leaves its record, which the scratch worktree's cleanup would otherwise delete: one row in
# the common dir's wt-ship-failures.tsv (time, lane, the stopped commit, the first red line) and the
# check's outputs under wt-ship-failed/<lane>/ (march-corrector, 22:10: two port stacks went red with
# their causes only in the scrollback of the shells that ran them)
record_failure() {
  local at red
  at=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-100 | tr '\t' ' ')
  red=$(grep -m1 -E '^check: .*(RED|red|fails|REFUSED|does not)|CONFLICT|could not apply' .wtd/rebase.out 2>/dev/null | cut -c1-240 | tr '\t' ' ')
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$lane")" "$at" "$red" >> "$common/wt-ship-failures.tsv"
  rm -rf "$common/wt-ship-failed/$(basename "$lane")"; mkdir -p "$common/wt-ship-failed/$(basename "$lane")"
  cp .wtd/*.out "$common/wt-ship-failed/$(basename "$lane")/" 2>/dev/null
  echo "ship: recorded in $common/wt-ship-failures.tsv; the check's outputs in $common/wt-ship-failed/$(basename "$lane")/"
}
release() { rm -rf "$lock"; }
trap cleanup_scratch EXIT
# the landing lock: a directory holding its holder's pid; a holder that died frees it, and so does
# a lock older than 10 minutes with no pid written (its holder died before writing it)
# lanes take the lock in the order they queued (a ticket, its name <seconds>-<pid>, in the common dir's
# wt-landing-queue): a ship waits until its ticket is the oldest of a live ship, so a lane that queued
# first is never skipped by one that polled first (march-monitor-a, 23:41: codegen-b's five commits were
# passed over twice)
queue="$common/wt-landing-queue"; mkdir -p "$queue"
ticket="$queue/$(date +%s)-$$"; : > "$ticket"
trap 'rm -f "$ticket"; cleanup_scratch' EXIT
w0=$(date +%s)
while :; do
  for t in "$queue"/*; do
    [ -e "$t" ] || continue
    kill -0 "${t##*-}" 2>/dev/null || rm -f "$t"
  done
  first=$(ls "$queue" | sort -t- -k1,1n -k2,2n | head -1)
  if [ "$queue/$first" = "$ticket" ] && mkdir "$lock" 2>/dev/null; then break; fi
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ]; then kill -0 "$holder" 2>/dev/null || rm -rf "$lock"
  elif [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rm -rf "$lock"; fi
  sleep 2
done
echo $$ > "$lock/pid"; rm -f "$ticket"; trap 'release; cleanup_scratch' EXIT
[ $(( $(date +%s) - w0 )) -gt 0 ] && echo "ship: waited $(( $(date +%s) - w0 ))s for the landing lock"
# dev/check.sh runs only under the landing lock, which this marks
export CHECK_LANDING=1
git fetch -q origin "$MARCH" || { echo "ship: cannot fetch origin/$MARCH"; exit 1; }
[ "$(git rev-list --count "origin/$MARCH..HEAD")" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
# a lane whose commits another ship already carried (the same patch under a new hash) has nothing to land,
# never a red: the rebase would drop them all and the carry check below would refuse "missing: all"
# (wt3-codegen and wt3-tests, 07:52: each landed commit marked red, its lane told to fix nothing)
# (and an empty commit carries nothing either: the rebase drops it, --no-keep-empty)
git log --diff-filter=ACDMRT --format=%H "origin/$MARCH..HEAD" | grep -qxFf <(git cherry "origin/$MARCH" HEAD | sed -n 's/^+ //p') ||
  { echo "ship: every commit of this lane is on origin/$MARCH already, as the same patch; nothing to land (git reset --hard origin/$MARCH)"; exit 0; }
first=$(git log --reverse --format=%at "origin/$MARCH..HEAD" | head -1)
base=$(git rev-parse "origin/$MARCH")
checked_rebase || { git fetch -q origin "$MARCH"; echo "ship: a commit's check is red or the rebase conflicts; $(git rev-list --count "$base..origin/$MARCH") commit(s) before it landed. Fix it, git rebase origin/$MARCH (the landed ones drop out) and ship again"; exit 1; }
# a push that took no lock (a lane on an older dev/ship.sh) moved the base: refuse, never land unchecked
git fetch -q origin "$MARCH" && git merge-base --is-ancestor "origin/$MARCH" HEAD ||
  { echo "ship: origin/$MARCH moved under the landing lock (a lane on an older dev/ship.sh); ship again"; exit 1; }
# never claim a landing the push doesn't carry: HEAD must hold every commit this lane brought, by
# subject (a rebase that lost them, leaving HEAD at origin's tip, would push nothing and print
# "landed"; wt3-tests saw exactly that)
want=$(git log --diff-filter=ACDMRT --format=%s "$base..$start" | sort -u)
have=$( { git log --format=%s "$base..HEAD"; git log -400 --format=%s "$base"; } | sort -u)
missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | sed '/^$/d')
if [ "$(git rev-list --count "$base..HEAD")" -eq 0 ] || [ -n "$missing" ]; then
  echo "ship: REFUSED — the rebased HEAD doesn't carry this lane's commits (missing: ${missing:-all}); nothing pushed"; exit 1
fi
if git push -q origin HEAD:$MARCH; then
  release; trap cleanup_scratch EXIT
  secs=$(( $(date +%s) - first ))
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "$secs" >> "$log"
  med=$(tail -5 "$log" | cut -f3 | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
  echo "ship: landed $(git rev-parse --short HEAD) on $MARCH, ${secs}s from its first commit to landed"
  # D13's band judges the loop, not this change: past it, the slowest step is the finding to fix
  if [ "$med" -gt 600 ]; then echo "ship: RED — the median of the last five landings is ${med}s, past D13's band (a 300-s target, red past 600 s): find what slows the loop"
  else echo "ship: median of the last five landings ${med}s (D13: a 300-s target, red past 600 s)"; fi
  # the rebuild's src progress, dev/src_progress.sh's line the check's ratchet printed for this tree (L208, D40)
  # the lane's own branch follows when it is as ship found it: clean, and HEAD unmoved
  if [ "$(git -C "$lane" rev-parse HEAD)" = "$start" ] && [ -z "$(git -C "$lane" status --porcelain --untracked-files=no)" ]; then
    git -C "$lane" rebase -q "origin/$MARCH" && echo "ship: this lane's branch is now on origin/$MARCH"
  else echo "ship: this lane moved on while landing; run git rebase origin/$MARCH when ready (the landed commits drop out)"; fi
    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0
fi
echo "ship: the push was refused under the landing lock"; exit 1
