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
# the rules dev/hooks/pre-push requires of every push to the march branch: this script's own blob, which must be
# origin's dev/ship.sh, so any older or edited copy is refused with no version to bump by hand (march-monitor-a, 20:06, D6)
export WT_SHIP_RULES="$(git hash-object "$0")"
# the rules that judge a landing are origin's, never the lane's copy: a lane, or a stale loop, on an older tree ran
# an older ship.sh without the refusals added since (the hold, the retry cap, the progress row; march-monitor-a, 19:47,
# D6). So when origin's dev/ship.sh differs from this file, this run executes origin's instead, from the lane's .wtd
# (so its dirname/.. is still the lane), saying so; dev/check.sh already runs from the scratch rebased onto origin
if [ -z "${WT_SHIP_ORIGIN:-}" ] && git fetch -q origin "$MARCH" 2>/dev/null; then
  mkdir -p .wtd; git show "origin/$MARCH:dev/ship.sh" > .wtd/ship.origin.sh 2>/dev/null
  if [ -s .wtd/ship.origin.sh ] && ! cmp -s .wtd/ship.origin.sh dev/ship.sh; then
    echo "ship: this lane's dev/ship.sh differs from origin/$MARCH's; running origin's"
    WT_SHIP_ORIGIN=1 exec bash .wtd/ship.origin.sh "$@"
  fi
fi
# a lane the lead holds (one worktree name a line in the common dir's wt-held) lands nothing, whatever runs this
# script: a stale autoship loop landed a held commit on its third attempt (3ea90d3b, march-monitor-a 15:16)
if grep -qxF "$(basename "$lane")" "$common/wt-held" 2>/dev/null; then
  echo "ship: REFUSED — this lane is held ($common/wt-held names $(basename "$lane")); the lead lifts it"; exit 2
fi
# dev/MARCH.md has one owner, the lead (a wt3-lead* worktree), as a CODEOWNERS file gives a path one owner: six
# conflicts on it in one day (17:26–21:06, march-monitor-a) were the shared hot file the oscillation lesson names.
# A lane sends its row to the lead; its commit that touches the file is refused here, before any rebase or check.
case "$(basename "$lane")" in
  wt3-lead*) ;;
  *) if [ -n "$(git diff --name-only "$(git merge-base "origin/$MARCH" HEAD)" HEAD -- dev/MARCH.md 2>/dev/null)" ]; then
       echo "ship: REFUSED — this lane's commits touch dev/MARCH.md, the lead's file; drop that hunk and send the lead the row"; exit 2
     fi;;
esac
# STOPGAP, the 13:10Z ruling (dev/MARCH.md 1.L, ended by A68S4's measure): a commit whose check went red on D14's band
# alone twice in the last hour is not shipped a third time, so a retry re-rolls the shards' noise once, never more
since=$(date -u -v-60M +%FT%TZ 2>/dev/null || date -u -d '-60 min' +%FT%TZ)
for s in $(git log --format=%s "origin/wt2..HEAD" 2>/dev/null | cut -c1-60 | tr ' ' '\001'); do
  s=$(printf '%s' "$s" | tr '\001' ' ')
  # a red counts only past today's band (dev/check.sh's D14_RED): a red the band now admits was no red
  n=$(awk -F'\t' -v t="$since" -v s="$s" -v band="$(sed -n 's/^D14_RED=\([0-9]*\).*/\1/p' dev/check.sh)" \
    '$1 >= t && index($3, s) && $4 ~ /past D14/ && match($4, /[0-9]+ s, past/) && substr($4, RSTART, RLENGTH - 8) + 0 > band + 0' \
    "$common/wt-ship-failures.tsv" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 2 ] && { echo "ship: REFUSED — \"$s\" went red on D14 alone $n times in the last hour; the ruling allows one retry"; exit 2; }
done
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
  # each pushed commit is one row of the landings log, its seconds from its own first commit (author time, kept
  # through the rebase) to its push: a stack that lands some commits and then goes red still records the ones
  # it landed (march-monitor-a, 15:03: three landings missing from the log, each a stack's green head before a red)
  # one row per landed commit: a head pushed again (a re-ship whose commit already landed) writes none (A70E2: f05b2fa8
  # logged twice, its D13 median skewed)
  export WT_LANDINGS_LOG="$log"
  if ! { git rebase -q --no-keep-empty --empty=drop "origin/$MARCH" --exec 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_REFLOG_ACTION CHECK_BASE=HEAD~1 bash dev/check.sh && git push -q origin HEAD:'"$MARCH"' && echo "ship: pushed $(git log -1 --format="%h %s" | cut -c1-90)" && { grep -q "	$(git rev-parse --short HEAD)	" "$WT_LANDINGS_LOG" 2>/dev/null || printf "%s\t%s\t%s\n" "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "$(( $(date +%s) - $(git log -1 --format=%at HEAD) ))" >> "$WT_LANDINGS_LOG"; }' 2>&1 | tee .wtd/rebase.out; [ "${PIPESTATUS[0]}" -eq 0 ]; }; then
    record_failure
    if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then git rebase --abort; fi
    return 1
  fi
}
# a red landing leaves its record, which the scratch worktree's cleanup would otherwise delete: one row in
# the common dir's wt-ship-failures.tsv (time, lane, the stopped commit, the first red line) and the
# check's outputs under wt-ship-failed/<lane>/ (march-corrector, 22:10: two port stacks went red with
# their causes only in the scrollback of the shells that ran them)
# the red line is the check's own verdict: "red" as a word, never inside a name ("MCCFGStackifySinglePredBroken"
# matched it and recorded a green TLC line as the cause, march-monitor-a, 09:30)
record_failure() {
  local at red
  at=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-100 | tr '\t' ' ')
  red=$(grep -m1 -E '^check: (RED|.*( red$| red[ ;:,]| fails|REFUSED|does not))|CONFLICT|could not apply|^pre-push: REFUSED' .wtd/rebase.out 2>/dev/null | cut -c1-240 | tr '\t' ' ')
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$lane")" "$at" "$red" >> "$common/wt-ship-failures.tsv"
  rm -rf "$common/wt-ship-failed/$(basename "$lane")"; mkdir -p "$common/wt-ship-failed/$(basename "$lane")"
  cp .wtd/*.out "$common/wt-ship-failed/$(basename "$lane")/" 2>/dev/null
  echo "ship: recorded in $common/wt-ship-failures.tsv; the check's outputs in $common/wt-ship-failed/$(basename "$lane")/"
}
release() { rm -rf "$lock"; }
trap cleanup_scratch EXIT
# the landing lock: a directory holding its holder's pid; a holder that died frees it, and so does
# a lock with no pid written 20 seconds after it was made (its holder died between the two steps; one empty
# lock held eight ships for four minutes under the old ten-minute rule, 09:52)
# lanes take the lock in the order they queued (a ticket, its name <seconds>-<pid>, in the common dir's
# wt-landing-queue): a ship waits until its ticket is the oldest of a live ship, so a lane that queued
# first is never skipped by one that polled first (march-monitor-a, 23:41: codegen-b's five commits were
# passed over twice)
# a ticket's time carries its stack's class, read from the stack itself, never from a list of lanes
# (march-corrector, 09:41: of fifteen queued commits only three ported a stub, and they waited behind twelve
# checks): an audit finding's fix (a commit citing A<n>S<n> or A<n>E<n>, D21) queues 40 minutes early, a stack
# porting more `@parity "…" @unported` stubs than it adds (a moved stub is no port, march-monitor-a, 09:45)
# 20 minutes early, the rest at its time. The order stays every ship's one sort of <seconds>-<pid>, so a ship
# on an older dev/ship.sh ranks the same tickets the same way (a second ticket name, ranked differently by old
# and new ships, deadlocked the queue at 09:53), and a ticket that has waited 20 minutes stands level with a
# fresh one a class above it, so none starves (bors's p= priority, GitHub's merge queue).
# every Julia file the stack changes parses before the stack takes a place in the queue: a conflict resolved into
# a file that does not parse cost a whole check and two minutes of the lock (wt3-cgstubs, 14:43,
# test/src/classes.jl:269, march-monitor-b); one julia with no project parses them all in about a second
git fetch -q origin "$MARCH" 2>/dev/null
changed_jl=$(git diff --name-only --diff-filter=AMR "origin/$MARCH...HEAD" -- '*.jl')
if [ -n "$changed_jl" ]; then
  if ! perr=$(printf '%s\n' $changed_jl | julia --startup-file=no -e '
      bad = false
      for f in eachline(stdin)
          e = Meta.parseall(read(f, String); filename = f)
          for a in e.args
              a isa Expr && a.head in (:error, :incomplete) || continue
              println(f, ": ", a.args[1]); global bad = true; break
          end
      end
      exit(bad ? 1 : 0)' 2>&1); then
    echo "ship: a changed Julia file does not parse; not queued:"; printf '%s\n' "$perr" | head -20; exit 1
  fi
fi
# a port stack is one that changes src/'s code, the compiler, read from its diff by dev/src_progress.sh (D40: a landing
# that changes nothing under src/ is no rebuild progress, and a comment-only change none either, A66E4): it queues
# 20 minutes early, ahead of tooling, docs and tests. Counting removed
# rejection sites was tried and refused: a real port fills a body and adds located rejections for the cases it
# does not yet reach, so 6 of 7 of the day's ports removed fewer sites than they added (march-corrector, 15:14;
# 6d540b66's @unported-marker test ranked almost nothing early once one marker was left)
early=0; why="other work"
if git log --format=%B "origin/$MARCH..HEAD" | grep -E '\bA[0-9]+[SE][0-9]+\b' > /dev/null; then early=2400; why="an audit finding's fix"
else
  bash dev/src_progress.sh code "origin/$MARCH" HEAD; rc=$?
  [ $rc -gt 1 ] && { echo "ship: the port class cannot read the change from origin/$MARCH; not queued"; exit 1; }
  [ $rc -eq 0 ] && { early=1200; why="a change to src/'s code, port work (D40)"; }
fi
queue="$common/wt-landing-queue"; mkdir -p "$queue"
ticket="$queue/$(( $(date +%s) - early ))-$$"; : > "$ticket"
echo "ship: queued $(( early / 60 )) minutes early ($why)"
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
  elif [ -d "$lock" ] && [ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) )) -gt 20 ]; then rm -rf "$lock"; fi
  sleep 2
done
echo $$ > "$lock/pid"; rm -f "$ticket"; trap 'release; cleanup_scratch' EXIT
[ $(( $(date +%s) - w0 )) -gt 0 ] && echo "ship: waited $(( $(date +%s) - w0 ))s for the landing lock"
# dev/check.sh runs only under the landing lock, which this marks
export CHECK_LANDING=1
git fetch -q origin "$MARCH" || { echo "ship: cannot fetch origin/$MARCH"; exit 1; }
# under the lock nothing else lands, so the ship.sh this run must match (dev/hooks/pre-push admits only origin's blob)
# cannot change before its push; a ship.sh that changed while this run queued is caught here, before its check, not
# at the push after a passing one (ca14d187 lost a green 134-s check that way, march-monitor-a, 20:17)
[ "$(git rev-parse "origin/$MARCH:dev/ship.sh")" = "$WT_SHIP_RULES" ] ||
  { echo "ship: REFUSED — origin's dev/ship.sh changed while this landing queued; ship again (no check was spent)"; exit 2; }
[ "$(git rev-list --count "origin/$MARCH..HEAD")" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
# a lane whose commits another ship already carried (the same patch under a new hash) has nothing to land,
# never a red: the rebase would drop them all and the carry check below would refuse "missing: all"
# (wt3-codegen and wt3-tests, 07:52: each landed commit marked red, its lane told to fix nothing)
# (and an empty commit carries nothing either: the rebase drops it, --no-keep-empty)
# (grep reads every line, never -q: under pipefail a grep that quits at its first match can leave git log
# writing into a closed pipe, its SIGPIPE failing the pipeline, and a lane of 7 unlanded commits was told it had
# nothing to land, wt3-translator2 12:47)
git log --diff-filter=ACDMRT --format=%H "origin/$MARCH..HEAD" | grep -xFf <(git cherry "origin/$MARCH" HEAD | sed -n 's/^+ //p') > /dev/null ||
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
    # and the same line kept in the common dir's wt-progress.tsv, one row per landing (time, head, line), so R2's history
    # is read from one file rather than from each lane's overwritten autoship output (march-monitor-a, 19:16)
    p=$(grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //' | tr '\t\n' '  ')
    [ -n "$p" ] || echo "ship: no src line in the check's ratchet output, so no row is written to wt-progress.tsv"
    [ -n "$p" ] && printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "$p" >> "$common/wt-progress.tsv"
    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0
fi
echo "ship: the push was refused under the landing lock"; exit 1
