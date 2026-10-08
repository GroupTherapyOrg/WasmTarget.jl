#!/usr/bin/env bash
# Every lane as ONE command (AGENTS.md, "The enforcement stack"; dev/CHARTER.md C10):
# structure → behavior → byte identity → formal (the fast TLC set). Exit code = the gate
# before a push. Measured 2026-10-07 (mostly AC power): the whole run 50 min, smoke 408 s,
# the suite lane (two shards, then fuzz) 1492 s.
#
#   bash dev/lanes.sh            # every lane on the default `julia`, which must be 1.12
#   JULIA="julia +1.13" bash dev/lanes.sh   # not a gate: a JULIA= run fails the gate
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
# No lane of the default run is skipped green (A12P6): a default `julia` that is not 1.12
# (byte identity and registry coverage record 1.12's typed IR, and the suite stands in for
# CI's 1.12 shards), no working `java` (the formal lane; TLC is fetched on first use) and a
# JULIA= override each print FAIL and turn the gate red.
set -uo pipefail
cd "$(dirname "$0")/.."
JULIA="${JULIA:-julia}"
fast=0; [ "${1:-}" = "--fast" ] && fast=1
export TLC_FAST=1; [ "${1:-}" = "--all" ] && export TLC_FAST=0
fail=0
# the wasm engine is CI's (ci.yml's node-version, the one source): a gate on another Node passes
# what CI's traps (batch 108: V8 12.4, Node 22, traps entering a try_table with a reference result)
NODE_MAJOR=$(sed -n "s/^ *node-version: *'\{0,1\}\([0-9][0-9]*\).*/\1/p" .github/workflows/ci.yml | head -1)
ci_node="$(brew --prefix "node@$NODE_MAJOR" 2>/dev/null)/bin"
[ -x "$ci_node/node" ] && export PATH="$ci_node:$PATH"
node_major=$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
printf '  node %s (CI: %s)\n' "$(node --version 2>/dev/null)" "$NODE_MAJOR"
if [ -z "$NODE_MAJOR" ] || [ "$node_major" != "$NODE_MAJOR" ]; then
  printf '  FAIL node           (the wasm engine is not CI'"'"'s Node %s: brew install node@%s)\n' "$NODE_MAJOR" "$NODE_MAJOR"; fail=1
fi
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
  if $JULIA -e 'exit(VERSION.major == 1 && VERSION.minor == 12 ? 0 : 1)'; then
    lane probes $JULIA --project=. test/probe_bytes.jl
    lane coverage $JULIA --project=. test/registry_coverage.jl
  else
    printf '  FAIL probes         (the default julia is not 1.12: probes, coverage and the suite are 1.12 lanes; juliaup default 1.12)\n'; fail=1
  fi
  if java -version >/dev/null 2>&1; then lane formal bash dev/formal/run_tlc.sh; rm -rf dev/formal/states
  else printf '  FAIL formal         (no working java: TLC needs one, brew install openjdk@17)\n'; fail=1; fi
  # smoke on Julia 1.13 (CI's second version), then every test family CI runs: two
  # concurrent shards, then the fuzz pass (suite() above)
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
