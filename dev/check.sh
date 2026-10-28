#!/usr/bin/env bash
# The landing check (dev/ship.sh runs it on every commit it lands): WasmTarget loads, so every
# construction checks itself at load; the ratchet passes (its exit status decides); every test of
# ported code passes (test/src_tests.jl); and TLC checks every model the change touches, each
# Broken instance required to break its claim (dev/formal/run_tlc.sh). D14's band: a 60-s target,
# red past 120 s. CHECK_BASE names the commit the change is measured from (default origin/wt2).
set -uo pipefail
cd "$(dirname "$0")/.."
# the depot of the lane being checked: dev/ship.sh checks in a scratch worktree of the lane and
# names the lane in WT_DEPOT_DIR, so its compiled images are the lane's, never a cold depot
. dev/depot.sh; wt_depot_export "${WT_DEPOT_DIR:-$(pwd)}"
# D31: the machine is shared (Dale's own jobs run beside the lanes), so at most three checks (two Julia processes each) run at
# once across every lane, each holding a slot in the repository's common dir; a slot whose holder
# died is freed. The wait is reported and not counted in D14's band, which times the check itself.
slots="$(git rev-parse --path-format=absolute --git-common-dir)/wt-check-slots"; mkdir -p "$slots"
w0=$(date +%s); slot=""
# the landing-lock holder (dev/ship.sh sets CHECK_RESERVED) takes slot L alone, so it never waits
# behind other lanes' optimistic checks
ids="1 2 3"; [ "${CHECK_RESERVED:-}" = 1 ] && ids="L"
while [ -z "$slot" ]; do
  for i in $ids; do
    if mkdir "$slots/$i" 2>/dev/null; then echo $$ > "$slots/$i/pid"; slot=$i; break; fi
    holder=$(cat "$slots/$i/pid" 2>/dev/null || true)
    if [ -n "$holder" ]; then kill -0 "$holder" 2>/dev/null || rm -rf "$slots/$i"
    elif [ -n "$(find "$slots/$i" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rm -rf "$slots/$i"; fi
  done
  [ -n "$slot" ] || sleep 2
done
trap 'rm -rf "$slots/$slot"' EXIT
[ $(( $(date +%s) - w0 )) -gt 0 ] && echo "check: waited $(( $(date +%s) - w0 ))s for a slot"
export JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=2
mkdir -p .wtd; s0=$(date +%s)
base=${CHECK_BASE:-origin/wt2}
# the ratchet and the tests of ported code run side by side (two processes, one thread each): the
# landing-lock holder's re-check is the loop's one serial step, so its wall is the slower of the two
julia --project=. --startup-file=no -e 'using WasmTarget' > .wtd/load.out 2>&1 || { echo "check: WasmTarget does not load"; tail -30 .wtd/load.out; exit 1; }
# a hard limit no stage may outlive, whatever the load: a hang is red within minutes and names the
# test file and case it was running (WT_PROGRESS), never an hour of a pinned core (2026-10-28: a
# shared-DAG constant hashed in 2^40 steps and held a landing for 50 minutes)
WT_HARD_LIMIT=${WT_HARD_LIMIT:-480}
export WT_PROGRESS="$PWD/.wtd/progress"; : > "$WT_PROGRESS"
julia --project=. --startup-file=no test/parity_ratchet.jl > .wtd/ratchet.out 2>&1 & rpid=$!
julia --project=. --startup-file=no test/src_tests.jl > .wtd/src_tests.out 2>&1 & tpid=$!
hung=""
while kill -0 $rpid 2>/dev/null || kill -0 $tpid 2>/dev/null; do
  if [ $(( $(date +%s) - s0 )) -gt "$WT_HARD_LIMIT" ]; then
    kill -0 $rpid 2>/dev/null && { hung="the ratchet"; pkill -P $rpid 2>/dev/null; kill $rpid 2>/dev/null; }
    kill -0 $tpid 2>/dev/null && { hung="${hung:+$hung and }the src tests, at: $(cat "$WT_PROGRESS" 2>/dev/null)"; pkill -P $tpid 2>/dev/null; kill $tpid 2>/dev/null; }
    break
  fi
  sleep 2
done
if [ -n "$hung" ]; then echo "check: RED — past the hard limit of ${WT_HARD_LIMIT}s, a hang or a blow-up: $hung"; exit 1; fi
wait $rpid; rc=$?
wait $tpid; trc=$?
if [ $rc -ne 0 ]; then
  echo "check: the ratchet fails (exit $rc)"
  grep -E '❌|FAIL|BROKEN|ERROR' .wtd/ratchet.out | cut -c1-300 | head -20
  grep -q '── charter' .wtd/ratchet.out || tail -30 .wtd/ratchet.out
  exit 1
fi
echo "check: ratchet passes ($(( $(date +%s) - s0 ))s)"
# D19: dev/CHARTER.md changes only with Dale's say-so, which the commit names in its trailer
# `Charter-change: <clauses> — Dale <YYYY-MM-DD>: "<his words>"`; the audit reads each claim
# against the conversation (a stopgap: no program can verify Dale's words)
for c in $(git rev-list "$(git merge-base "$base" HEAD)..HEAD" -- dev/CHARTER.md); do
  git log -1 --format=%B "$c" | grep -qE '^Charter-change: .*Dale [0-9]{4}-[0-9]{2}-[0-9]{2}: ".+"' ||
    { echo "check: $(git log -1 --format='%h %s' "$c" | cut -c1-80) changes dev/CHARTER.md with no Charter-change trailer quoting Dale (D19)"; exit 1; }
done
grep -E '^(Test Summary|src )' .wtd/src_tests.out | tail -2
[ $trc -eq 0 ] || { echo "check: src tests red"; grep -vE '^\s*$' .wtd/src_tests.out | tail -40; exit 1; }
# the models the change touches: a changed dev/formal/<Name>.tla or MC<Name>*.{tla,cfg} selects
# every instance MC<Name>*.cfg of that model
models=$(git diff --name-only "$base" HEAD -- dev/formal | sed -nE 's#^dev/formal/(MC)?([A-Z][A-Za-z0-9]*)\.(tla|cfg)$#\2#p' | sort -u)
cfgs=""
for m in $models; do
  for c in dev/formal/MC"$m"*.cfg; do [ -e "$c" ] && cfgs="$cfgs $(basename "$c")"; done
done
if [ -n "$cfgs" ]; then
  cfgs=$(printf '%s\n' $cfgs | sort -u | tr '\n' ' ')
  TLC_ONLY="${cfgs% }" bash dev/formal/run_tlc.sh || { echo "check: TLC red on the touched models"; exit 1; }
  echo "check: TLC green on $cfgs"
fi
wall=$(( $(date +%s) - s0 ))
# a machine loaded past its cores (Dale's own jobs share it) leaves the band unjudged, never a
# scaled pass: the time is printed with the load, as the retired timing ratchet left a slow
# machine's timing unjudged (L195)
load=$( { sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg 2>/dev/null; } | tr -d '{}' | awk '{ print int($1) }')
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)
if [ $wall -gt 120 ]; then
  if [ "${load:-0}" -gt "$cores" ]; then echo "check: ${wall}s, past D14's band but UNJUDGED: load ${load} on ${cores} cores"
  else echo "check: RED — ${wall}s, past D14's band (a 60-s target, red past 120 s) at load ${load} on ${cores} cores"; exit 1; fi
fi
echo "check: green (${wall}s)"
