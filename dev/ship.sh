#!/usr/bin/env bash
# Land this worktree's commits on the march branch: rebase onto it, run dev/check.sh on every
# commit, push fast-forward. Never a merge commit, never a force push.
#
# The check runs first outside any lock, so lanes check side by side. Then the lane takes the
# landing lock (one lane at a time, held for a fetch and a push, and for a re-check only when
# another lane landed meanwhile), so a landing is checked again at most once and never starves:
# the optimistic-then-serialized landing of a merge queue (bors, GitHub's merge queue), its
# serialized part kept short.
set -uo pipefail
# the one march branch on origin (D23): every lane lands here; worktrees and their branches stay local
MARCH=wt2
cd "$(dirname "$0")/.."
lane=$(pwd -P)
common="$(git rev-parse --path-format=absolute --git-common-dir)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "ship: uncommitted changes stay here and are not landed"
# the landing runs in a scratch worktree of this lane's HEAD, so the lane keeps editing while it
# lands: a rebase or an abort there never touches the lane's files (a lane lost uncommitted edits
# when ship rebased its own tree). Its untracked Manifest and preferences come along, and its checks
# compile into the lane's depot.
start=$(git rev-parse HEAD)
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
# before the lock every commit is checked on its own tree, against its parent; under the lock only
# the rebased tip is checked again (audit 47, A47E3), with git's own rebase variables cleared: the ratchet's plants
# make scratch repositories, and an inherited GIT_DIR or GIT_INDEX_FILE would point them at this one
checked_rebase() {
  if ! git rebase -q "origin/$MARCH" --exec 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_REFLOG_ACTION CHECK_BASE=HEAD~1 bash dev/check.sh'; then
    if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then git rebase --abort; fi
    return 1
  fi
}
release() { rm -rf "$lock"; }
trap cleanup_scratch EXIT
git fetch -q origin "$MARCH" || { echo "ship: cannot fetch origin/$MARCH"; exit 1; }
[ "$(git rev-list --count "origin/$MARCH..HEAD")" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
first=$(git log --reverse --format=%at "origin/$MARCH..HEAD" | head -1)
checked_rebase || { echo "ship: a commit's check is red or the rebase conflicts; the branch is as it was. Fix it and ship again"; exit 1; }
# the landing lock: a directory holding its holder's pid; a holder that died frees it, and so does
# a lock older than 10 minutes with no pid written (its holder died before writing it)
while ! mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ]; then kill -0 "$holder" 2>/dev/null || rm -rf "$lock"
  elif [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rm -rf "$lock"; fi
  sleep 2
done
echo $$ > "$lock/pid"; trap 'release; cleanup_scratch' EXIT
# under the lock the re-check takes the reserved slot (dev/check.sh's slot L), so the holder never
# waits behind other lanes' optimistic checks; a push a lane on an older dev/ship.sh beat (one that
# takes no lock) is fetched and re-checked again, at most three times
export CHECK_RESERVED=1
for try in 1 2 3; do
  git fetch -q origin "$MARCH" || { echo "ship: cannot fetch origin/$MARCH"; exit 1; }
  if ! git merge-base --is-ancestor "origin/$MARCH" HEAD; then
    # every commit already passed on its own tree before the lock; under it, the stack is rebased
    # onto the new base and its tip checked once, as a merge queue checks the head it lands (bors,
    # GitHub's merge queue), so the lock is held for one check, never one per commit
    echo "ship: another lane landed while this one checked; checking the rebased tip under the landing lock"
    if ! git rebase -q "origin/$MARCH"; then
      if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then git rebase --abort; fi
      echo "ship: the rebase onto the new base conflicts; the branch is as it was. Fix it and ship again"; exit 1
    fi
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE CHECK_BASE="origin/$MARCH" bash dev/check.sh ||
      { echo "ship: the rebased tip is red on the new base; the branch is as it was. Fix it and ship again"; exit 1; }
  fi
  git fetch -q origin "$MARCH" && git merge-base --is-ancestor "origin/$MARCH" HEAD && break
done
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
