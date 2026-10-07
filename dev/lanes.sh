#!/usr/bin/env bash
# The inner loop as ONE command (dev/MARCH.md §5): structure → behavior → byte identity →
# formal (the fast TLC set). Exit code = the commit gate. ~2 minutes steady-state.
#
#   bash dev/lanes.sh            # all four lanes on the default `julia`
#   JULIA="julia +1.13" bash dev/lanes.sh
#   bash dev/lanes.sh --fast     # ratchet + smoke only (~5 min): the inner loop, never a push
#
# The default run is the gate before a push (AGENTS.md, L153): it adds the byte probes, the
# registry, the models, smoke on Julia 1.13 and the whole Pkg.test suite in one process
# (WT_NO_SHARD=1, every family CI's shards run), so CI confirms rather than discovers: a
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
    printf '  skip smoke-1.13     (this run is on %s)\n' "$JULIA"
  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then
    lane smoke-1.13 julia +1.13 --project=. test/smoke.jl
  else
    printf '  FAIL smoke-1.13     (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1
  fi
  lane suite env WT_NO_SHARD=1 $JULIA --project=. -e 'using Pkg; Pkg.test()'
fi
[ $fail -eq 0 ] && echo "LANES green" || { echo "LANES red"; exit 1; }
