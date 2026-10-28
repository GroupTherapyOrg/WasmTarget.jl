#!/usr/bin/env bash
# The landing check (dev/ship.sh runs it on every commit it lands): WasmTarget loads, so every
# construction checks itself at load; the ratchet passes (its exit status decides); every test of
# ported code passes (test/src_tests.jl); and TLC checks every model the change touches, each
# Broken instance required to break its claim (dev/formal/run_tlc.sh). D14's band: a 60-s target,
# red past 120 s. CHECK_BASE names the commit the change is measured from (default origin/wt2).
set -uo pipefail
cd "$(dirname "$0")/.."
. dev/depot.sh; wt_depot_export "$(pwd)"
# D31: the machine is shared (Dale's own jobs run beside the lanes), so at most three checks run at
# once across every lane, each holding a slot in the repository's common dir; a slot whose holder
# died is freed. The wait is reported and not counted in D14's band, which times the check itself.
slots="$(git rev-parse --path-format=absolute --git-common-dir)/wt-check-slots"; mkdir -p "$slots"
w0=$(date +%s); slot=""
while [ -z "$slot" ]; do
  for i in 1 2 3; do
    if mkdir "$slots/$i" 2>/dev/null; then echo $$ > "$slots/$i/pid"; slot=$i; break; fi
    holder=$(cat "$slots/$i/pid" 2>/dev/null || true)
    [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && rm -rf "$slots/$i"
  done
  [ -n "$slot" ] || sleep 2
done
trap 'rm -rf "$slots/$slot"' EXIT
[ $(( $(date +%s) - w0 )) -gt 0 ] && echo "check: waited $(( $(date +%s) - w0 ))s for a slot"
export JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=2
mkdir -p .wtd; s0=$(date +%s)
base=${CHECK_BASE:-origin/wt2}
julia --project=. --startup-file=no test/parity_ratchet.jl > .wtd/ratchet.out 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "check: the ratchet fails (exit $rc)"
  grep -E '❌|FAIL|BROKEN|ERROR' .wtd/ratchet.out | cut -c1-300 | head -20
  grep -q '── charter' .wtd/ratchet.out || tail -30 .wtd/ratchet.out
  exit 1
fi
echo "check: ratchet passes ($(( $(date +%s) - s0 ))s)"
julia --project=. --startup-file=no test/src_tests.jl || { echo "check: src tests red"; exit 1; }
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
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print int($2) }'); cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
if [ $wall -gt 120 ]; then
  if [ "${load:-0}" -gt "$cores" ]; then echo "check: ${wall}s, past D14's band but UNJUDGED: load ${load} on ${cores} cores"
  else echo "check: RED — ${wall}s, past D14's band (a 60-s target, red past 120 s) at load ${load} on ${cores} cores"; exit 1; fi
fi
echo "check: green (${wall}s)"
