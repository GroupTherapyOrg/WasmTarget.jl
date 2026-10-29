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
# D31: the machine is shared (Dale's own jobs run beside the lanes) and has 4 performance cores; one
# check runs at a time across every lane, its four processes (the ratchet and three shards of the src
# tests) one per performance core, while every other Julia runs at background QoS on the efficiency
# cores (audit #53, A53E1: two checks at once spilled onto efficiency cores at half speed). The check
# holds the one slot in the repository's common dir; a slot whose holder died is freed. The wait is reported and not counted in D14's band, which times the check itself.
slots="$(git rev-parse --path-format=absolute --git-common-dir)/wt-check-slots"; mkdir -p "$slots"
w0=$(date +%s); slot=""
ids="1"
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
# the landing compiles a fixed core of the dart corpus, never a set that grows with the port; the whole
# corpus runs beside the landings on wt2's head (dev/corpus.sh, test/src/dart_tests.jl)
export WT_LANDING_CORE=1
mkdir -p .wtd; s0=$(date +%s)
base=${CHECK_BASE:-origin/wt2}
# the ratchet and the tests of ported code run side by side (two processes, one thread each): the
# landing-lock holder's re-check is the loop's one serial step, so its wall is the slower of the two
# a dependency the project names but the (gitignored) Manifest lacks is resolved first, once: a
# change adding a [deps] entry (Binaryen_jll for the opt phase) would otherwise fail every lane's load
missing_deps=$(sed -n '/^\[deps\]/,/^\[/p' Project.toml | sed -nE 's/^([A-Za-z0-9_]+) *=.*/\1/p' |
  while read -r d; do grep -q "^\[\[deps\.$d\]\]" Manifest.toml 2>/dev/null || echo "$d"; done)
if [ -n "$missing_deps" ]; then
  echo "check: resolving the Manifest for $(echo $missing_deps | tr '\n' ' ')"
  julia --project=. --startup-file=no -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()' > .wtd/resolve.out 2>&1 ||
    { echo "check: the Manifest does not resolve"; tail -20 .wtd/resolve.out; exit 1; }
fi
# each stage's CPU seconds (user + sys) go to .wtd/<stage>.time for D14's band, below
/usr/bin/time -l -o .wtd/load.time julia --project=. --startup-file=no -e 'using WasmTarget' > .wtd/load.out 2>&1 || { echo "check: WasmTarget does not load"; tail -30 .wtd/load.out; exit 1; }
# a hard limit no stage may outlive, whatever the load: a hang is red within minutes and names the
# test file and case it was running (WT_PROGRESS), never an hour of a pinned core (2026-10-28: a
# shared-DAG constant hashed in 2^40 steps and held a landing for 50 minutes)
WT_HARD_LIMIT=480   # a literal, never set from a lane's shell (A50E1); band: today's slowest loaded check is ~170 s
/usr/bin/time -l -o .wtd/ratchet.time julia --project=. --startup-file=no test/parity_ratchet.jl > .wtd/ratchet.out 2>&1 & rpid=$!
SHARDS=3; tpids=""
for k in $(seq 1 $SHARDS); do
  : > ".wtd/progress.$k"
  WT_PROGRESS="$PWD/.wtd/progress.$k" WT_SRC_SHARD="$k/$SHARDS" /usr/bin/time -l -o ".wtd/src_tests.$k.time" \
    julia --project=. --startup-file=no test/src_tests.jl > ".wtd/src_tests.$k.out" 2>&1 & tpids="$tpids $!"
done
running() { kill -0 $rpid 2>/dev/null && return 0; for p in $tpids; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
hung=""
while running; do
  if [ $(( $(date +%s) - s0 )) -gt "$WT_HARD_LIMIT" ]; then
    kill -0 $rpid 2>/dev/null && { hung="the ratchet"; pkill -P $rpid 2>/dev/null; kill $rpid 2>/dev/null; }
    k=0; for p in $tpids; do k=$((k + 1))
      kill -0 $p 2>/dev/null && { hung="${hung:+$hung and }src tests shard $k, at: $(cat ".wtd/progress.$k" 2>/dev/null)"; pkill -P $p 2>/dev/null; kill $p 2>/dev/null; }
    done
    break
  fi
  sleep 2
done
if [ -n "$hung" ]; then echo "check: RED — past the hard limit of ${WT_HARD_LIMIT}s, a hang or a blow-up: $hung"; exit 1; fi
wait $rpid; rc=$?
trc=0; for p in $tpids; do wait $p || trc=1; done
cat .wtd/src_tests.[0-9]*.out > .wtd/src_tests.out
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
echo "check: src tests $(awk '/^src /{ p += $3; t += $NF+0 } END { print p }' .wtd/src_tests.out) passed in $SHARDS shards; $(grep -cE '^src ' .wtd/src_tests.out) of $SHARDS reported" 
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
# D14's band judges the check's own cost, never the machine's: the CPU seconds of its critical path,
# the load stage then the slowest of the parallel stages. A process's CPU seconds do not grow while
# it waits for a core, so another job's load cannot turn a landing red, and a check that grew can never
# hide behind a loaded machine (A52E2: the wall-clock band read "UNJUDGED" at every load of 4 or more).
# An efficiency core spends about twice the CPU seconds; background Julia runs at taskpolicy -b (corpus.sh)
# so a check, at foreground QoS, keeps the performance cores
# /usr/bin/time -l: its first line holds real, user and sys; a later line the instructions retired, which
# no core type or load moves (printed beside the band, the measure A53E1 proposes)
cpu() { awk 'NR == 1 { printf "%d", $3 + $5 }' ".wtd/$1.time"; }
gi() { awk '/instructions retired/ { printf "%d", $1 / 1e9 }' ".wtd/$1.time"; }
c_load=$(cpu load); c_ratchet=$(cpu ratchet); path_par=$c_ratchet; shards=""
for k in $(seq 1 $SHARDS); do c=$(cpu "src_tests.$k"); shards="$shards $c"; [ "$c" -gt "$path_par" ] && path_par=$c; done
path=$(( c_load + path_par ))
echo "check: ${path} CPU-s on the critical path (load ${c_load}, ratchet ${c_ratchet}, src shards${shards}); ${wall}s wall; G instructions: load $(gi load), ratchet $(gi ratchet), shards$(for k in $(seq 1 $SHARDS); do printf ' %s' "$(gi "src_tests.$k")"; done)"
[ $path -gt 120 ] && { echo "check: RED — ${path} CPU-s, past D14's band (a 60-s target, red past 120 s)"; exit 1; }
echo "check: green (${wall}s)"
