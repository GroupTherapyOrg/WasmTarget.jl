#!/usr/bin/env bash
# The inner loop as ONE command (dev/MARCH.md §5): structure → behavior → byte identity →
# formal (the fast TLC set). Exit code = the commit gate. ~2 minutes steady-state.
#
#   bash dev/lanes.sh            # all four lanes on the default `julia`
#   JULIA="julia +1.13" bash dev/lanes.sh
#   bash dev/lanes.sh --fast     # ratchet + smoke only (~1 min)
#   bash dev/lanes.sh --all      # also the deep TLC instances (>10^6 states, +2-3 min)
#
# Byte identity is skipped on Julia ≥ 1.13 (the baseline records 1.12's typed IR); the
# formal lane needs Java (TLC is fetched on first use).
set -uo pipefail
cd "$(dirname "$0")/.."
JULIA="${JULIA:-julia}"
fast=0; [ "${1:-}" = "--fast" ] && fast=1
export TLC_FAST=1; [ "${1:-}" = "--all" ] && export TLC_FAST=0
fail=0
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
  else
    printf '  skip probes         (baseline is 1.12 IR)\n'
  fi
  if command -v java >/dev/null; then lane formal bash dev/formal/run_tlc.sh; rm -rf dev/formal/states
  else printf '  skip formal         (no java)\n'; fi
fi
[ $fail -eq 0 ] && echo "LANES green" || { echo "LANES red"; exit 1; }
