#!/usr/bin/env bash
# Every lane as ONE command (AGENTS.md, "The enforcement stack"; dev/CHARTER.md C10):
# structure → behavior (1.12 and 1.13, TLC beside) → byte identity → the suite; the first red
# lane ends the run. The full matrix is these lanes on CI's runners, `bash dev/gate.sh`
# (gate.yml, one job per lane, 20 min each, L162), at clause closure and never a landing's gate
# (that is `bash dev/check.sh`, run by `bash dev/ship.sh`); this script is their local reproduction, whole or
# one lane.
#
#   bash dev/lanes.sh            # every lane on the default `julia`, which must be 1.12
#   JULIA="julia +1.13" bash dev/lanes.sh   # not a gate: a JULIA= run fails the gate
#   bash dev/lanes.sh --fast     # ratchet + smoke only: the inner loop, never a push
#
# The default run is the full matrix's set of lanes (AGENTS.md, L153), which dev/gate.sh runs on
# CI's runners: it adds the byte probes, the models, smoke on Julia 1.13, the Pkg.test suite
# (test/runtests.jl's QA families) as two concurrent shards (WT_SHARD=0,2 and 1,2), and WT1's smoke
# over the one corpus on both versions, the agreement oracle legacy/'s deletion rule reads.
#   bash dev/lanes.sh --all      # also the deep TLC instances (run_tlc.sh DEEP, ~10 min locally)
#   bash dev/lanes.sh --lane <name> [--part i/N]   # exactly one lane of the default run, with
#       its own checks (a skip still prints FAIL and exits red): ratchet, formal, smoke-1.13,
#       smoke, probes, suite, legacy or legacy-1.13; --part i/N (0 <= i < N) runs part i of the
#       smokes, WT1's among them (WT_SMOKE_PART), formal (TLC_SHARD) or the suite (WT_SHARD=i,N). Each job of
#       .github/workflows/gate.yml (dev/gate.sh) runs one; every other lane is a no-op.
#
# No lane of the default run is skipped green (A12P6): a default `julia` that is not 1.12
# (byte identity records 1.12's typed IR, and the suite stands in for CI's 1.12 shards), no
# working `java` (the formal lane; TLC is fetched on first use) and a JULIA= override each print
# FAIL and turn the gate red.
set -uo pipefail
cd "$(dirname "$0")/.."
JULIA="${JULIA:-julia}"
fast=0; export TLC_FAST=1; only=""; part=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) fast=1 ;;
    --all) export TLC_FAST=0 ;;
    --lane) only="${2:-}"; shift ;;
    --part) part="${2:-}"; shift ;;
    *) echo "lanes.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$only" ]; then
  case " ratchet formal smoke-1.13 smoke probes suite legacy legacy-1.13 " in
    *" $only "*) ;; *) echo "lanes.sh: no lane $only" >&2; exit 2 ;;
  esac
  [ $fast -eq 0 ] || { echo "lanes.sh: --lane runs one lane of the default run, not of --fast" >&2; exit 2; }
fi
if [ -n "$part" ]; then
  pi=${part%/*}; pn=${part#*/}
  if ! [[ $part =~ ^[0-9]+/[1-9][0-9]*$ ]] || [ "$pi" -ge "$pn" ]; then echo "lanes.sh: --part $part: expected i/N with 0 <= i < N" >&2; exit 2; fi
  case "$only" in
    # a part prints each group's seconds (WT_SMOKE_TIMES), the durations test/smoke_times.tsv
    # records and test/smoke.jl deals the parts by
    smoke|smoke-1.13|legacy|legacy-1.13) export WT_SMOKE_PART="$part" WT_SMOKE_TIMES=1 ;;
    formal) export TLC_SHARD="$part" ;;
    suite) ;;
    *) echo "lanes.sh: --part needs --lane smoke, smoke-1.13, legacy, legacy-1.13, formal or suite" >&2; exit 2 ;;
  esac
fi
# the lane runs: every lane of the default run, or the one --lane names
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }
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
# the whole Pkg.test suite as concurrent shards, two (WT_SHARD=0,2 and 1,2) or the one
# --part i/N names (WT_SHARD=i,N); all must pass
shards="0,2 1,2"; [ "$only" = suite ] && [ -n "$part" ] && shards="$pi,$pn"
suite() {
  local d s r=0 p pids=(); d=$(mktemp -d)
  for s in $shards; do
    WT_VALIDATE=1 WT_SHARD="$s" $JULIA --project=. -e 'using Pkg; Pkg.test()' > "$d/shard$s.log" 2>&1 &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || r=1; done
  report "$d"/shard*.log
  if [ $r -eq 0 ]; then echo "suite: shards $shards passed"; return 0; fi
  return 1
}
report() {  # under --lane (a CI job's log) the whole log; else a red log's failure lines
  if [ -n "$only" ]; then cat "$@"
  elif [ "${r:-0}" -ne 0 ]; then grep -hE "Test Failed|Error During|Expression:|Evaluated:|cause:|FAILED|fail" "$@" | head -40; fi
}
lane() {  # name, command...: a no-op unless the lane runs (want)
  local name=$1; shift
  want "$name" || return 0
  local t0=$(date +%s)
  if out=$("$@" 2>&1); then
    printf '  ok   %-14s %3ds  %s\n' "$name" $(( $(date +%s) - t0 )) "$(echo "$out" | tail -1 | cut -c1-90)"
    [ -z "$only" ] || echo "$out"
  else
    printf '  FAIL %-14s %3ds\n' "$name" $(( $(date +%s) - t0 ))
    if [ -n "$only" ]; then echo "$out"; else echo "$out" | grep -E "BROKEN|WRONG|ERR|CHANGED|NEW probe|MISSING|FAIL|Error" | head -12; fi
    fail=1
  fi
}
# The first red lane ends the run (stop): a later lane's verdict cannot turn it green, and a
# failure shows at its own lane, not at the end. Lanes that need no common state run side by
# side (bg, then join_bg): smoke on 1.12 and on 1.13, two processes as the suite lane uses, with
# TLC beside them; then the probes; then the suite.
stop() { [ $fail -eq 0 ] || { echo "LANES red"; exit 1; }; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
bg() {  # file, lane name command...: the lane in the background, its verdict line to the file
  local f=$1; shift
  ( fail=0; "$@"; [ $fail -eq 0 ] || touch "$f.fail" ) > "$f" 2>&1 &
}
join_bg() {  # wait for every bg lane, print each verdict in order, fail the gate on any red
  wait; local f
  for f in "$@"; do [ -e "$f" ] && cat "$f"; [ -e "$f.fail" ] && fail=1; done; return 0
}
stop
lane ratchet  $JULIA --project=. test/parity_ratchet.jl
stop
if [ $fast -eq 0 ]; then
  if ! want formal; then :
  elif java -version >/dev/null 2>&1; then bg "$d/formal" lane formal bash dev/formal/run_tlc.sh
  else printf '  FAIL formal         (no working java: TLC needs one, brew install openjdk@17)\n'; fail=1; fi
  # smoke on Julia 1.13 (CI's second version) beside smoke on 1.12
  if ! want smoke-1.13; then :
  elif [ "$JULIA" != "julia" ]; then
    printf '  FAIL smoke-1.13     (the gate runs on the default julia, not %s)\n' "$JULIA"; fail=1
  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then
    bg "$d/s113" lane smoke-1.13 julia +1.13 --project=. test/smoke.jl
  else
    printf '  FAIL smoke-1.13     (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1
  fi
fi
lane smoke    $JULIA --project=. test/smoke.jl
join_bg "$d/s113" "$d/formal"; rm -rf dev/formal/states
stop
if [ $fast -eq 0 ]; then
  if ! want probes && ! want suite; then :
  elif $JULIA -e 'exit(VERSION.major == 1 && VERSION.minor == 12 ? 0 : 1)'; then
    lane probes $JULIA --project=. test/probe_bytes.jl
  else
    printf '  FAIL probes         (the default julia is not 1.12: the probes and the suite are 1.12 lanes; juliaup default 1.12)\n'; fail=1
  fi
  stop
  # every test family CI runs: two concurrent shards (suite() above)
  lane suite suite
  stop
  # WT1, the agreement oracle: its smoke over the one corpus on both versions, side by side
  # (dev/MARCH.md 1.G; legacy/'s deletion rule reads its PASS set beside the rebuild's, 1.F)
  if ! want legacy && ! want legacy-1.13; then :
  elif [ "$JULIA" != "julia" ]; then
    printf '  FAIL legacy         (the gate runs on the default julia, not %s)\n' "$JULIA"; fail=1
  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then
    bg "$d/l113" lane legacy-1.13 julia +1.13 --project=legacy legacy/test/smoke.jl
    lane legacy julia --project=legacy legacy/test/smoke.jl
    join_bg "$d/l113"
  else
    printf '  FAIL legacy-1.13    (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1
  fi
fi
[ $fail -eq 0 ] && echo "LANES green" || { echo "LANES red"; exit 1; }
