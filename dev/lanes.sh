#!/usr/bin/env bash
# The inner loop as ONE command (dev/MARCH.md §5): structure → behavior → byte identity →
# formal (the fast TLC set). Exit code = the commit gate. Measured 2026-10-07 (mostly AC
# power): the whole run 50 min, smoke 408 s, the suite lane (two shards, then fuzz) 1492 s.
#
#   bash dev/lanes.sh            # all four lanes on the default `julia`
#   JULIA="julia +1.13" bash dev/lanes.sh   # not a gate: a JULIA= run fails the 1.13 lane
#   bash dev/lanes.sh --fast     # ratchet + smoke only: the inner loop, never a push
#
# The default run is the gate before a push (AGENTS.md, L153): it adds the byte probes, the
# registry, the models, smoke on Julia 1.13 and the whole Pkg.test suite as two concurrent
# shards (WT_SHARD=0,2 and 1,2: every family CI's shards run; two processes for this lane,
# Dale 2026-10-07, after one process took 50 min on battery) beside CI's fuzz pass (WT_FUZZ=1, its own slice
# on CI), so CI confirms rather than discovers: a
# batch that passed smoke and broke a runtests family cost a CI cycle and a re-stacked branch
# (batch 101, 2026-10-07).
#   bash dev/lanes.sh --all      # also the deep TLC instances (>10^6 states, +2-3 min)
#
# Byte identity and registry coverage are skipped on Julia ≥ 1.13 (both baselines record
# 1.12's typed IR); the
# formal lane needs Java (TLC is fetched on first use).
set -uo pipefail
cd "$(dirname "$0")/.."
JULIA="${JULIA:-julia}"
fast=0; [ "${1:-}" = "--fast" ] && fast=1
export TLC_FAST=1; [ "${1:-}" = "--all" ] && export TLC_FAST=0
fail=0
suite() {  # the whole Pkg.test suite as two concurrent shards, then the fuzz pass; all must pass
  local d; d=$(mktemp -d)
  WT_VALIDATE=1 WT_SHARD="0,2" $JULIA --project=. -e 'using Pkg; Pkg.test()' > "$d/shard0.log" 2>&1 &
  local p0=$!
  WT_VALIDATE=1 WT_SHARD="1,2" $JULIA --project=. -e 'using Pkg; Pkg.test()' > "$d/shard1.log" 2>&1 &
  local p1=$!
  wait $p0; local r0=$?
  wait $p1; local r1=$?
  WT_VALIDATE=1 WT_FUZZ=1 $JULIA --project=. -e 'using Pkg; Pkg.test()' > "$d/fuzz.log" 2>&1
  local rf=$?
  if [ $r0 -eq 0 ] && [ $r1 -eq 0 ] && [ $rf -eq 0 ]; then echo "suite: shards 0 and 1 of 2 and the fuzz pass passed"; return 0; fi
  grep -hE "Test Failed|Error During|Expression:|Evaluated:|cause:|FAILED|fail" "$d"/shard*.log "$d/fuzz.log" | head -40
  return 1
}
lane() {  # name, command...
  local name=$1; shift
  local t0=$(date +%s)
  if out=$("$@" 2>&1); then
    printf '  ok   %-14s %3ds  %s\n' "$name" $(( $(date +%s) - t0 )) "$(echo "$out" | tail -1 | cut -c1-90)"
  else
    printf '  FAIL %-14s %3ds\n' "$name" $(( $(date +%s) - t0 )); echo "$out" | grep -E "BROKEN|WRONG|ERR|CHANGED|NEW probe|MISSING|FAIL|Error" | head -12; fail=1
  fi
}
lane ratchet  $JULIA --project=. test/parity_ratchet.jl
lane smoke    $JULIA --project=. test/smoke.jl
if [ $fast -eq 0 ]; then
  if $JULIA -e 'exit(VERSION < v"1.13.0-" ? 0 : 1)'; then
    lane probes $JULIA --project=. test/probe_bytes.jl
    lane coverage $JULIA --project=. test/registry_coverage.jl
  else
    printf '  skip probes         (baseline is 1.12 IR)\n'
  fi
  if command -v java >/dev/null; then lane formal bash dev/formal/run_tlc.sh; rm -rf dev/formal/states
  else printf '  skip formal         (no java)\n'; fi
  # smoke on Julia 1.13 (CI's second version), then every test family CI runs, one process
  if [ "$JULIA" != "julia" ]; then
    printf '  FAIL smoke-1.13     (the gate runs on the default julia, not %s)\n' "$JULIA"; fail=1
  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then
    lane smoke-1.13 julia +1.13 --project=. test/smoke.jl
  else
    printf '  FAIL smoke-1.13     (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1
  fi
  lane suite suite
fi
[ $fail -eq 0 ] && echo "LANES green" || { echo "LANES red"; exit 1; }
