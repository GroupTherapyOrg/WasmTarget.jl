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
# every exit says what happened in one machine line, the last it prints: `ship-result: <KIND> [<arg>]`, KIND one of
# LANDED <sha>, ADMISSIBLE, NOTHING, REFUSED <why>, D14 <seconds>, OWN <check|tests|conflict|parse>, NETWORK <fetch|push>,
# OTHER <why>; and the same `<KIND> [<arg>]` written to $WT_SHIP_RESULT when the caller names that file. The climb's
# lander names one in its own state, which only this script, Dale's process, writes, and reads that file and no line
# of this script's output: the output carries the check's, which prints what the tree's own tests print (R6-2)
result() { echo "ship-result: $*"; [ -z "${WT_SHIP_RESULT:-}" ] || { printf '%s\n' "$*" > "$WT_SHIP_RESULT.tmp" && mv -f "$WT_SHIP_RESULT.tmp" "$WT_SHIP_RESULT"; }; }
finish() { local rc=$1; shift; result "$@"; exit "$rc"; }
# a climb agent never lands: dev/climb/climb.py runs every agent with WT_CLIMB_AGENT set, and lands only after its own
# measurement and review (dev/climb/HILL.md G5)
[ -n "${WT_CLIMB_AGENT:-}" ] && { echo "ship: REFUSED — a climb agent never lands; the driver does (dev/climb/HILL.md)"; finish 2 REFUSED agent; }
# … and a climb worktree lands only when the driver ships it: a process without the agent's env (a Julia session the
# agent reaches through Kaimon) is refused in any worktree named climb-*, by its directory, so a detached HEAD there
# (the lander lands a pinned sha detached) is refused too
case "$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")" in
  climb-*) [ -n "${WT_CLIMB_DRIVER:-}" ] || { echo "ship: REFUSED — a climb worktree lands only through dev/climb/climb.py"; finish 2 REFUSED climb-worktree; } ;;
esac
# --admissible: only the cheap refusals below (a held lane, the MARCH.md owner, the one retry an hour on a D14 red,
# mid-operation, nothing to land, the line stop), then ADMISSIBLE or the refusal; no lock, no scratch, no check.
# The climb's lander asks before it stops anything for a landing (dev/climb/climb.py admissible)
# an argument this script does not know is refused before anything else runs: it has one flag, and a call with any
# other (`--help`, typed to read its usage, 2026-11-10) used to run a whole landing of the lane
[ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --admissible ]; } || { echo "ship: REFUSED — unknown argument: $* (the one flag is --admissible)"; finish 2 REFUSED argument; }
admissible=0; [ "${1:-}" = --admissible ] && admissible=1
# a lane may run dev/autoship.sh beside its work, which calls this script whenever its committed work settles
# the one march branch on origin (D23): every lane lands here; worktrees and their branches stay local
MARCH=wt2
cd "$(dirname "$0")/.."
lane=$(pwd -P)
common="$(git rev-parse --path-format=absolute --git-common-dir)"
# the rules dev/hooks/pre-push requires of every push to the march branch: this script's own blob, which must be
# origin's dev/ship.sh, so any older or edited copy is refused with no version to bump by hand (march-monitor-a, 20:06, D6)
# the rules this copy carries, set on the push alone (A77E1: exported, every check under the lock inherited it)
ship_rules="$(git hash-object "$0")"
# when this ship began, a diagnostic beside D13 (the queue and check), never its judge: dev/LEDGER.md's D13 bands edit to
# landed, and only Dale's words change what it measures (A84E3). Inherited only through the trampoline (WT_SHIP_ORIGIN=1)
[ "${WT_SHIP_ORIGIN:-}" = 1 ] && [ -n "${WT_SHIP_START:-}" ] || WT_SHIP_START=$(date +%s); export WT_SHIP_START
# the rules that judge a landing are origin's, never the lane's copy: a lane, or a stale loop, on an older tree ran
# an older ship.sh without the refusals added since (the hold, the retry cap, the progress row; march-monitor-a, 19:47,
# D6). So when origin's dev/ship.sh differs from this file, this run executes origin's instead, from the lane's .wtd
# (so its dirname/.. is still the lane), saying so; dev/check.sh already runs from the scratch rebased onto origin
if [ -z "${WT_SHIP_ORIGIN:-}" ] && git fetch -q origin "$MARCH" 2>/dev/null; then
  mkdir -p .wtd; git show "origin/$MARCH:dev/ship.sh" > .wtd/ship.origin.sh 2>/dev/null
  # always the copy, never this file in place: bash reads a script as it runs, so an edit to the tree's dev/ship.sh
  # during a ship changed the running ship ("dev/ship.sh: line 247: ...", wt3-lead2 14:47; march-monitor-a)
  if [ -s .wtd/ship.origin.sh ]; then
    cmp -s .wtd/ship.origin.sh dev/ship.sh || echo "ship: this lane's dev/ship.sh differs from origin/$MARCH's; running origin's"
    WT_SHIP_ORIGIN=1 exec bash .wtd/ship.origin.sh "$@"
  fi
fi
# a lane the lead holds (one worktree name a line in the common dir's wt-held) lands nothing, whatever runs this
# script: a stale autoship loop landed a held commit on its third attempt (3ea90d3b, march-monitor-a 15:16)
if grep -qxF "$(basename "$lane")" "$common/wt-held" 2>/dev/null; then
  echo "ship: REFUSED — this lane is held ($common/wt-held names $(basename "$lane")); the lead lifts it"; finish 2 REFUSED held
fi
# dev/MARCH.md has one owner, the lead (a wt3-lead* worktree), as a CODEOWNERS file gives a path one owner: fifteen
# conflicts on it in one day (11:44–21:06, march-monitor-a's count) were the shared hot file the oscillation lesson names.
# A lane sends its row to the lead; its commit that touches the file is refused here, before any rebase or check.
# STOPGAP (A79S3): the owner is named by worktree, and the diff spans merge-base..HEAD, every commit the lane holds, not
# only the SHIP_MAX carried (it over-refuses, never under). It ends when MARCH.md's rows become per-lane files the plan includes.
case "$(basename "$lane")" in
  wt3-lead*) ;;
  *) if [ -n "$(git diff --name-only "$(git merge-base "origin/$MARCH" HEAD)" HEAD -- dev/MARCH.md 2>/dev/null)" ]; then
       echo "ship: REFUSED — this lane's commits touch dev/MARCH.md, the lead's file; drop that hunk and send the lead the row"; finish 2 REFUSED march-md
     fi;;
esac
# STOPGAP, the 13:10Z ruling (dev/MARCH.md 1.L, ended by A68S4's measure): a commit whose check went red on D14's band
# alone twice in the last hour is not shipped a third time, so a retry re-rolls the shards' noise once, never more
since=$(date -u -v-60M +%FT%TZ 2>/dev/null || date -u -d '-60 min' +%FT%TZ)
band=$(git show "origin/$MARCH:dev/check.sh" 2>/dev/null | sed -n 's/^D14_RED=\([0-9]*\).*/\1/p')
# an unreadable band is no band of 0, which would count every D14 red: refuse, located (A79S2)
[ -n "$band" ] || { echo "ship: REFUSED — origin/$MARCH:dev/check.sh names no D14_RED, so the retry cap cannot read today's band"; finish 2 REFUSED no-band; }
for s in $(git log --format=%s "origin/wt2..HEAD" 2>/dev/null | cut -c1-60 | tr ' ' '\001'); do
  s=$(printf '%s' "$s" | tr '\001' ' ')
  # a red counts only past today's band (origin's dev/check.sh D14_RED, never the lane's copy, A77E3): a red the band now admits was no red
  n=$(awk -F'\t' -v t="$since" -v s="$s" -v band="$band" \
    '$1 >= t && index($3, s) && $4 ~ /past D14/ && match($4, /[0-9]+ s, past/) && substr($4, RSTART, RLENGTH - 8) + 0 > band + 0' \
    "$common/wt-ship-failures.tsv" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 2 ] && { echo "ship: REFUSED — \"$s\" went red on D14 alone $n times in the last hour; the ruling allows one retry"; finish 2 REFUSED hourly; }
done
[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "ship: uncommitted changes stay here and are not landed"
# a lane mid-rebase, mid-merge, mid-cherry-pick or mid-revert has a HEAD that is not its work: refuse,
# never land a half-finished history (a ship from a mid-rebase worktree landed the wrong commits twice)
gitdir="$(git rev-parse --path-format=absolute --git-dir)"
for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  [ -e "$gitdir/$op" ] && { echo "ship: REFUSED: this worktree is mid-operation ($op); finish or abort it, then ship"; finish 2 REFUSED mid-operation; }
done
# the lane's commits that origin does not hold as the same patch (an empty commit carries nothing either: the rebase
# drops it, --no-keep-empty); none is nothing to land, never a red (wt3-codegen and wt3-tests, 07:52: each landed
# commit marked red, its lane told to fix nothing). grep reads every line, never -q: under pipefail a grep that quits
# at its first match can leave git log writing into a closed pipe, its SIGPIPE failing the pipeline, and a lane of 7
# unlanded commits was told it had nothing to land (wt3-translator2 12:47)
unlanded() { git log --diff-filter=ACDMRT --format=%H "origin/$MARCH..HEAD" | grep -xFf <(git cherry "origin/$MARCH" HEAD | sed -n 's/^+ //p'); }
if [ "$admissible" = 1 ]; then
  unlanded > /dev/null || { echo "ship: nothing to land: origin/$MARCH holds every commit of this lane"; finish 2 NOTHING; }
  # the line stop is check.sh's rule, asked of origin's check.sh in the mode that stops after it
  mkdir -p .wtd; git show "origin/$MARCH:dev/check.sh" > .wtd/check.admissible.sh
  # (its verdict is its exit status: 12 the line stop, 13 a hold)
  CHECK_LANDING=1 CHECK_ADMISSIBLE=1 WT_DEPOT_DIR="$lane" bash .wtd/check.admissible.sh; rc=$?
  case $rc in 0) ;; 12) finish 2 REFUSED linestop ;; 13) finish 2 REFUSED held ;; *) finish 2 REFUSED "check-$rc" ;; esac
  finish 0 ADMISSIBLE
fi
# the landing runs in a scratch worktree of this lane's HEAD, so the lane keeps editing while it
# lands: a rebase or an abort there never touches the lane's files (a lane lost uncommitted edits
# when ship rebased its own tree). Its untracked Manifest and preferences come along, and its checks
# compile into the lane's depot.
start=$(git rev-parse HEAD)
# one landing carries at most SHIP_MAX commits, the lane's oldest; the rest wait for its next ship, so the
# landing lock passes between lanes (march-monitor-a, 22:40: an eighteen-commit landing held the lock
# twenty minutes while two lanes' ports waited behind it)
SHIP_MAX=6   # a literal, never set from a lane's shell
# a landing lock with no pid written this many seconds after it was made is free (its holder died between the two
# steps); a literal the climb's driver reads here too (dev/climb/core.py landing_lock_held: one source)
LOCK_NOPID_S=20
git fetch -q origin "$MARCH" 2>/dev/null
if [ "$(git rev-list --count "origin/$MARCH..HEAD" 2>/dev/null || echo 0)" -gt "$SHIP_MAX" ]; then
  start=$(git rev-list --reverse "origin/$MARCH..HEAD" | sed -n "${SHIP_MAX}p")
  echo "ship: this landing carries the oldest $SHIP_MAX of $(git rev-list --count "origin/$MARCH..HEAD") commits; ship again for the rest"
fi
scratch="$common/wt-ship/$(basename "$lane")"
# one landing per lane at a time: a second ship from this worktree would remove the first's scratch
mkdir -p "$common/wt-ship"
lanelock="$scratch.lock"
# its holder's pid with this boot's start (kern.boottime): a pid recorded in an earlier boot is dead whatever holds that
# number now (O7-6, the climb's door.alive test)
boot=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
if ! mkdir "$lanelock" 2>/dev/null; then
  read -r holder hboot < "$lanelock/pid" 2>/dev/null || true
  if [ -n "${holder:-}" ] && [ "${hboot:-}" = "$boot" ] && kill -0 "$holder" 2>/dev/null; then
    echo "ship: a landing of this lane is already running (pid $holder); wait for it, then ship again"; finish 2 REFUSED busy
  fi
  rm -rf "$lanelock"; mkdir "$lanelock" || { echo "ship: cannot take this lane's landing slot"; finish 2 REFUSED busy; }
fi
echo "$$ $boot" > "$lanelock/pid"
git worktree remove --force "$scratch" 2>/dev/null; rm -rf "$scratch"
git worktree add -q --detach "$scratch" "$start" || { echo "ship: cannot make the scratch worktree"; finish 1 OTHER scratch; }
# the climb's lander names the commit it pinned at approval: anything else at the scratch's HEAD is refused before the
# rebase (a HEAD moved between the lander's checks and this line would land unreviewed)
if [ -n "${WT_SHIP_EXPECT:-}" ] && [ "$(git -C "$scratch" rev-parse HEAD)" != "$WT_SHIP_EXPECT" ]; then
  echo "ship: REFUSED — the HEAD to land is $(git -C "$scratch" rev-parse HEAD), not the expected $WT_SHIP_EXPECT"
  git worktree remove --force "$scratch"; rm -rf "$lanelock"; finish 2 REFUSED expect
fi
# a climb landing lands the commit its lander measured, on origin's head as it stood (A7-5: one merge, the lander's, and
# one regeneration): origin's head is its ancestor (a move's parent; a stack made by hand, its first commit's), so the
# rebase below replays nothing and no merge driver or regeneration runs; origin having moved is a retry, which the
# lander measures again, never a second merge here
if [ -n "${WT_CLIMB_DRIVER:-}" ] && ! git merge-base --is-ancestor "origin/$MARCH" "${WT_SHIP_EXPECT:-HEAD}" 2>/dev/null; then
  echo "ship: REFUSED — origin/$MARCH moved past the commit the lander measured (origin's head is not its ancestor)"
  git worktree remove --force "$scratch"; rm -rf "$lanelock"; finish 2 REFUSED moved
fi
for f in Manifest.toml LocalPreferences.toml; do [ -f "$lane/$f" ] && cp "$lane/$f" "$scratch/$f"; done
export WT_DEPOT_DIR="$lane"
# a climb landing's Julia runs behind the climb's door, never as Dale (dev/climb/HILL.md, "The door"): origin's
# dev/climb/door.py runs the check and the packages regeneration as the landing's build user, in its own clone, depot
# and caches, with no network, its outputs copied back into the scratch (the check's printed output to .wtd/check.log,
# never into this script's); the pins it reads are fetched first, here, with origin's dev/fetch_julia.sh, and the land
# job mirrors them alone (the toolchain and the agents' claude are refreshed at the climb's launch alone, so a landing
# starts no other build user's process beside its check, O6-2); the push follows the check, as Dale
if [ -n "${WT_CLIMB_DRIVER:-}" ]; then
  export WT_SHIP_DOOR="$common/wt-ship/$(basename "$lane").door.py"; pins="$common/wt-ship/$(basename "$lane").pins"
  rm -rf "$pins"; mkdir -p "$pins/dev" "$pins/src/julia"
  { git show "origin/$MARCH:dev/climb/door.py" > "$WT_SHIP_DOOR" && git show "origin/$MARCH:dev/climb/defaults.py" > "$common/wt-ship/defaults.py" &&
    git show "origin/$MARCH:dev/fetch_julia.sh" > "$pins/dev/fetch_julia.sh" &&
    git show "origin/$MARCH:src/julia/parity.jl" > "$pins/src/julia/parity.jl" && bash "$pins/dev/fetch_julia.sh" > /dev/null; } ||
    { echo "ship: a climb landing runs behind the door, and origin/$MARCH's dev/climb/door.py or its pins failed"; git worktree remove --force "$scratch"; rm -rf "$lanelock"; finish 1 OTHER door; }
fi
# the check's verdict, its exit status (dev/check.sh: only its own process sets it) and its critical path, written by
# this script's rebase step to $WT_CHECK_RESULT (the lander names one in its state), never read from a printed line
export WT_CHECK_RESULT="${WT_CHECK_RESULT:-$common/wt-ship/$(basename "$lane").check}" WT_SHIP_STEP="$common/wt-ship/$(basename "$lane").step"
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
  # and its progress row, from that commit's own ratchet output, before the next commit's check overwrites it (A78E3:
  # one row per ship, written after the rebase, left a36ed084 and 98390e9e with landings rows and no progress row)
  export WT_SHIP_LANE="$(basename "$lane")" WT_LANDINGS_LOG="$log" WT_PROGRESS_LOG="$common/wt-progress.tsv" WT_SHIP_LANDED="$common/wt-ship/$(basename "$lane").landed.sh" \
    WT_SHIP_COMMON="$common" WT_SHIP_EXEC="$common/wt-ship/$(basename "$lane").exec.sh"
  # one commit's steps (the rebase's --exec), each named in $WT_SHIP_STEP before it runs, so a red's class is the step
  # that failed and, for the check, its exit status (red_kind): the packages regenerated when the merge driver blanked
  # them; the check, its verdict written to $WT_CHECK_RESULT; the line stop and a hold asked again right before the
  # push (v6 item 3: a check takes minutes, and either can arrive meanwhile); the push, its rules ($1) set on it alone
  # (A77E1); the landed hook. A commit whose steps all passed leaves no step named
  cat > "$WT_SHIP_EXEC" <<'EXEC'
step() { echo "$1" > "$WT_SHIP_STEP"; }
if [ -e "$WT_PACKAGES_MERGED" ]; then
  step regen; rm -f "$WT_PACKAGES_MERGED"
  [ -z "${WT_SHIP_DOOR:-}" ] || { echo 'ship: REFUSED — a climb landing merged; it lands the commit its lander measured'; exit 1; }
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE bash dev/regen_packages.sh; rc=$?
  [ $rc -eq 3 ] && { rm -f "$WT_SHIP_STEP"; exit 0; }
  [ $rc -eq 0 ] || exit 1
fi
step check; rm -f .wtd/check-path.out .wtd/check-split.out
set -- "$1" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_REFLOG_ACTION CHECK_BASE=HEAD~1
if [ -n "${WT_SHIP_DOOR:-}" ]; then "${@:2}" python3 "$WT_SHIP_DOOR" land-check "$PWD"; rc=$?
else "${@:2}" bash dev/check.sh 2>&1 | tee .wtd/check.log; rc=${PIPESTATUS[0]}; fi
{ printf '%s %s\n' "$rc" "$(tr -cd 0-9 < .wtd/check-path.out 2>/dev/null | cut -c1-6)"
  grep -E '^(load|ratchet|shard\.[0-9]{1,2}) [0-9]{1,6}( [0-9]{1,9}\.[0-9]){3}$|^wall [0-9]{1,6}$|^start\.[0-9]{1,2} [0-9]{1,9}\.[0-9]$' .wtd/check-split.out 2>/dev/null | head -30; } > "$WT_CHECK_RESULT"
# and each shard's per-file records (test/src_tests.jl's WT_SRC_RECORDS, a file a shard), headed by their shard, beside
# the verdict: what the check reports it ran, the climb's lander's verified record and R3's reading, never assumed
for f in .wtd/src_records.*.out; do [ -f "$f" ] && { printf 'shard\t%s\n' "$(basename "$f")"; cat "$f"; }; done > "$WT_CHECK_RESULT.records" 2>/dev/null
# a red on D14's band alone is a red only when the machine was quiet at the check's start and its end (throughput P0):
# dev/d14_judge.sh asks the climb's lander, which named the question (WT_D14_ASK); the verdict file above keeps 10
[ ! -f dev/d14_judge.sh ] || rc=$(bash dev/d14_judge.sh "$rc")
[ $rc -eq 0 ] || exit 1
step still
{ ! grep -qxF "$WT_SHIP_LANE" "$WT_SHIP_COMMON/wt-held" 2>/dev/null; } &&
  { [ ! -f "$WT_SHIP_COMMON/wt-line-stop" ] || [ "$(head -1 "$WT_SHIP_COMMON/wt-line-stop")" = "$WT_SHIP_LANE" ]; } ||
  { echo 'ship: REFUSED — a hold or the line stop arrived during the check'; exit 1; }
MARCH="$WT_SHIP_MARCH"; step push; WT_SHIP_RULES="$1" git push -q origin HEAD:$MARCH || exit 1
step landed; bash "$WT_SHIP_LANDED" || exit 1
rm -f "$WT_SHIP_STEP"
EXEC
  rm -f "$WT_SHIP_STEP" "$WT_CHECK_RESULT"
  cat > "$WT_SHIP_LANDED" <<'LANDED'
h=$(git rev-parse --short HEAD)
echo "ship: pushed $(git log -1 --format='%h %s' | cut -c1-90)"
grep -q "	$h	" "$WT_LANDINGS_LOG" 2>/dev/null || printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$h" "$(( $(date +%s) - $(git log -1 --format=%at HEAD) ))" "$(( $(date +%s) - WT_SHIP_START ))" "$WT_SHIP_LANE" >> "$WT_LANDINGS_LOG"
p=$(grep -E '^ *· src:' .wtd/ratchet.out 2>/dev/null | sed 's/^ *· //' | tr '\t\n' '  ')
if [ -z "$p" ]; then echo "ship: no src line in $h's ratchet output, so no row is written to wt-progress.tsv"
else grep -q "	$h	" "$WT_PROGRESS_LOG" 2>/dev/null || printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$h" "$p" >> "$WT_PROGRESS_LOG"; fi
# an admission the landed commit used is spent, so it admits no second landing (A92E1; the one spend step,
# reading the common dir's wt-no-counterpart-admit, never the scratch's)
bash dev/no_counterpart_spend.sh
LANDED
  # src/julia/packages.jl merges with its generated blocks blanked (dev/merge_packages.sh) and, when it did, the
  # commit's own tree rewrites them before its check (dev/regen_packages.sh): two lanes adding imports or roots
  # conflicted there eleven times on 2026-11-02, each a hand resolution
  export WT_PACKAGES_MERGED="$scratch/.wtd/packages-merged"; rm -f "$WT_PACKAGES_MERGED"
  if ! { git -c merge.wt-packages.name="src/julia/packages.jl, its generated blocks blanked" -c merge.wt-packages.driver="bash $scratch/dev/merge_packages.sh %O %A %B" rebase -q --no-keep-empty --empty=drop "origin/$MARCH" --exec 'WT_SHIP_MARCH='"$MARCH"' bash "$WT_SHIP_EXEC" '"$ship_rules" 2>&1 | tee .wtd/rebase.out; [ "${PIPESTATUS[0]}" -eq 0 ]; }; then
    failed=$(red_kind)   # before the abort: a stopped rebase with no step named is a conflict
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
# (a red of the check is written in this script's words from its verdict, never a line it printed: the retry cap above
# counts the rows reading "past D14")
record_failure() {
  local at red rc path
  at=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-100 | tr '\t' ' ')
  if [ "$(cat "$WT_SHIP_STEP" 2>/dev/null)" = check ]; then
    read -r rc path < "$WT_CHECK_RESULT" 2>/dev/null
    case "$rc" in 10) red="check: RED — ${path:-?} s, past D14's band" ;; 11) red="check: RED — past the hard limit" ;;
      14) red="check: red on its test files (its outputs in wt-ship-failed/$(basename "$lane")/, src_records.*.out)" ;;
      15) red="check: a test process void (its outputs in wt-ship-failed/$(basename "$lane")/, src_records.void.out)" ;;
      *) red="check: red, its exit status ${rc:-none} (its outputs in wt-ship-failed/$(basename "$lane")/)" ;; esac
  else red=$(grep -m1 -E '^ship: REFUSED|CONFLICT|could not apply|^pre-push: REFUSED' .wtd/rebase.out 2>/dev/null | cut -c1-240 | tr '\t' ' '); fi
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$lane")" "$at" "$red" >> "$common/wt-ship-failures.tsv"
  rm -rf "$common/wt-ship-failed/$(basename "$lane")"; mkdir -p "$common/wt-ship-failed/$(basename "$lane")"
  cp .wtd/*.out .wtd/*.log "$common/wt-ship-failed/$(basename "$lane")/" 2>/dev/null
  echo "ship: recorded in $common/wt-ship-failures.tsv; the check's outputs in $common/wt-ship-failed/$(basename "$lane")/"
}
# a red landing's class: the step that failed ($WT_SHIP_STEP) and, for the check, its exit status ($WT_CHECK_RESULT),
# never a printed line (R6-7: a test that printed check.sh's D14 line was classed D14); a stopped rebase with no step
# named stopped on a conflict
red_kind() {
  local rc path
  case "$(cat "$WT_SHIP_STEP" 2>/dev/null)" in
    check) read -r rc path < "$WT_CHECK_RESULT" 2>/dev/null
      case "$rc" in 10) echo "D14 ${path:-0}" ;; 11) echo "OTHER hang" ;; 12) echo "REFUSED linestop" ;; 13) echo "REFUSED held" ;;
        1) echo "OWN check" ;; 14) echo "OWN tests" ;; 15) echo "OWN void" ;; *) echo "OTHER check-${rc:-none}" ;; esac ;;
    regen) echo "OTHER regen" ;;
    still) echo "REFUSED held" ;;
    tree) echo "OTHER tree" ;;
    push) echo "NETWORK push" ;;
    landed) echo "OTHER landed-hook" ;;
    "") if [ -d "$(git rev-parse --git-path rebase-merge)" ]; then echo "OWN conflict"; else echo "OTHER rebase"; fi ;;
    *) echo "OTHER step" ;;
  esac
}
release() { rm -rf "$lock"; }
trap cleanup_scratch EXIT
# the landing lock: a directory holding its holder's "<pid> <boot>" (alive_rec); a holder that died frees it, and so does
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
# (a climb landing parses nothing as Dale: the driver read its Julia with Julia's parser behind the door at G5, and
# its check parses every file as the landing's build user)
if [ -n "$changed_jl" ] && [ -z "${WT_CLIMB_DRIVER:-}" ]; then
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
    echo "ship: a changed Julia file does not parse; not queued:"; printf '%s\n' "$perr" | head -20; finish 1 OWN parse
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
  [ $rc -gt 1 ] && { echo "ship: the port class cannot read the change from origin/$MARCH; not queued"; finish 1 OTHER port-class; }
  [ $rc -eq 0 ] && { early=1200; why="a change to src/'s code, port work (D40)"; }
fi
queue="$common/wt-landing-queue"; mkdir -p "$queue"
# a recorded holder (a ticket's or the landing lock's "<pid> <boot>", as the lane lock's) is alive: recorded in this boot
# and running (O8-6, O6-11: the climb's door.alive and core.landing_lock_held read the same record); a record of an
# older ship.sh (no record, or a pid alone: $2 the pid its name carries) is alive while its file was made in this boot
alive_rec() {   # <file> [<pid when the file records none>]
  local p b; read -r p b < "$1" 2>/dev/null || true
  [ -n "${p:-}" ] || p=${2:-}
  [ -n "$p" ] || return 1
  if [ -n "${b:-}" ]; then [ "$b" = "$boot" ] && kill -0 "$p" 2>/dev/null
  else [ "$(stat -f %m "$1" 2>/dev/null || echo 0)" -ge "$boot" ] && kill -0 "$p" 2>/dev/null; fi
}
ticket="$queue/$(( $(date +%s) - early ))-$$"; echo "$$ $boot" > "$queue/.t$$" && mv "$queue/.t$$" "$ticket"
echo "ship: queued $(( early / 60 )) minutes early ($why)"
trap 'rm -f "$ticket"; cleanup_scratch' EXIT
w0=$(date +%s)
while :; do
  for t in "$queue"/*; do
    [ -e "$t" ] || continue
    alive_rec "$t" "${t##*-}" || rm -f "$t"
  done
  first=$(ls "$queue" | sort -t- -k1,1n -k2,2n | head -1)
  if [ "$queue/$first" = "$ticket" ] && mkdir "$lock" 2>/dev/null; then break; fi
  if [ -s "$lock/pid" ]; then alive_rec "$lock/pid" || rm -rf "$lock"
  elif [ -d "$lock" ] && [ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) )) -gt "$LOCK_NOPID_S" ]; then rm -rf "$lock"; fi
  sleep 2
done
echo "$$ $boot" > "$lock/pid"; rm -f "$ticket"; trap 'release; cleanup_scratch' EXIT
[ $(( $(date +%s) - w0 )) -gt 0 ] && echo "ship: waited $(( $(date +%s) - w0 ))s for the landing lock"
# dev/check.sh runs only under the landing lock, which this marks
export CHECK_LANDING=1
git fetch -q origin "$MARCH" || { echo "ship: cannot fetch origin/$MARCH"; finish 1 NETWORK fetch; }
# under the lock nothing else lands, so the ship.sh this run must match (dev/hooks/pre-push admits only origin's blob)
# cannot change before its push; a ship.sh that changed while this run queued is caught here, before its check, not
# at the push after a passing one (ca14d187 lost a green 134-s check that way, march-monitor-a, 20:17)
[ "$(git rev-parse "origin/$MARCH:dev/ship.sh")" = "$ship_rules" ] ||
  { echo "ship: REFUSED — origin's dev/ship.sh changed while this landing queued; ship again (no check was spent)"; finish 2 REFUSED stale-ship; }
[ "$(git rev-list --count "origin/$MARCH..HEAD")" -gt 0 ] || { echo "ship: nothing to land"; finish 0 NOTHING; }
# a lane whose commits another ship already carried (the same patch under a new hash) has nothing to land: the
# rebase would drop them all and the carry check below would refuse "missing: all"
unlanded > /dev/null ||
  { echo "ship: every commit of this lane is on origin/$MARCH already, as the same patch; nothing to land (git reset --hard origin/$MARCH)"; finish 0 NOTHING; }
first=$(git log --reverse --format=%at "origin/$MARCH..HEAD" | head -1)
base=$(git rev-parse "origin/$MARCH")
checked_rebase || { git fetch -q origin "$MARCH"; echo "ship: a commit's check is red or the rebase conflicts; $(git rev-list --count "$base..origin/$MARCH") commit(s) before it landed. Fix it, git rebase origin/$MARCH (the landed ones drop out) and ship again"; finish 1 $failed; }
# a push that took no lock (a lane on an older dev/ship.sh) moved the base: refuse, never land unchecked
git fetch -q origin "$MARCH" && git merge-base --is-ancestor "origin/$MARCH" HEAD ||
  { echo "ship: origin/$MARCH moved under the landing lock (a lane on an older dev/ship.sh); ship again"; finish 1 OTHER moved; }
# never claim a landing the push doesn't carry: HEAD must hold every commit this lane brought, by
# subject (a rebase that lost them, leaving HEAD at origin's tip, would push nothing and print
# "landed"; wt3-tests saw exactly that)
want=$(git log --diff-filter=ACDMRT --format=%s "$base..$start" | sort -u)
have=$( { git log --format=%s "$base..HEAD"; git log -400 --format=%s "$base"; } | sort -u)
missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | sed '/^$/d')
if [ "$(git rev-list --count "$base..HEAD")" -eq 0 ] || [ -n "$missing" ]; then
  echo "ship: REFUSED — the rebased HEAD doesn't carry this lane's commits (missing: ${missing:-all}); nothing pushed"; finish 1 OTHER carry
fi
# the rules ride on this last push alone: every check has run by now (A77E1)
export WT_SHIP_RULES="$ship_rules"
if git push -q origin HEAD:$MARCH; then
  release; trap cleanup_scratch EXIT
  secs=$(( $(date +%s) - first ))
  # D13 judges edit to landed, as dev/LEDGER.md's row bands it: the median of the last five landings' seconds from first
  # commit to landed (field 3). A ship's own queue and check (field 4, from its start) is printed beside it as the diagnostic
  # that tells a slow loop from a held lane; changing which one D13 judges is Dale's to say (A84E3 reverted f08173cf's switch)
  med=$(tail -5 "$log" | cut -f3 | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
  echo "ship: landed $(git rev-parse --short HEAD) on $MARCH, ${secs}s from its first commit to landed ($(( $(date +%s) - WT_SHIP_START ))s of it this ship's queue and check)"
  # D13's band judges the loop, not this change: past it, the slowest step is the finding to fix
  if [ "$med" -gt 600 ]; then echo "ship: RED — the median of the last five landings is ${med}s from first commit to landed, past D13's band (a 300-s target, red past 600 s): find what slows the loop"
  else echo "ship: median of the last five landings ${med}s from first commit to landed (D13: a 300-s target, red past 600 s)"; fi
  # the rebuild's src progress, dev/src_progress.sh's line the check's ratchet printed for this tree (L208, D40)
  # the lane's own branch follows when it is as ship found it: clean, and HEAD unmoved
  if [ "$(git -C "$lane" rev-parse HEAD)" = "$start" ] && [ -z "$(git -C "$lane" status --porcelain --untracked-files=no)" ]; then
    git -C "$lane" rebase -q "origin/$MARCH" && echo "ship: this lane's branch is now on origin/$MARCH"
  else echo "ship: this lane moved on while landing; run git rebase origin/$MARCH when ready (the landed commits drop out)"; fi
    # each landed commit's line is kept in the common dir's wt-progress.tsv by the rebase's --exec (WT_SHIP_LANDED), one
    # row per landing, so R2's history is read from one file (march-monitor-a, 19:16; A78E3)
    # the result line last, from the exit trap, after the progress line L208 reads here verbatim
    landed=$(git rev-parse HEAD); trap 'cleanup_scratch; result LANDED $landed' EXIT
    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0
fi
echo "ship: the push was refused under the landing lock"; finish 1 NETWORK push
