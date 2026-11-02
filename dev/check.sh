#!/usr/bin/env bash
# The landing check (dev/ship.sh runs it on every commit it lands): WasmTarget loads, so every
# construction checks itself at load; the ratchet passes (its exit status decides); every test of
# ported code passes (test/src_tests.jl); and TLC checks every model the change touches, each
# Broken instance required to break its claim (dev/formal/run_tlc.sh). D14's band: a 60-s target,
# red past 120 s (140 s until four shards, Dale 2026-11-01; D14_RED below). CHECK_BASE names the commit the change is measured from (default origin/wt2).
set -uo pipefail
cd "$(dirname "$0")/.."
# a check runs only inside a landing (dev/ship.sh sets CHECK_LANDING under the landing lock): with one
# check at a time on the machine, a check outside a landing took the slot between a landing's per-commit
# checks and held three ships behind it (march-monitor-a, 2026-10-28 21:45); to try a change before
# shipping, run its test file at background QoS (taskpolicy -b) with a hard limit
[ "${CHECK_LANDING:-}" = 1 ] || { echo "check: REFUSED — dev/check.sh runs only inside dev/ship.sh, which holds the landing lock; to try a change, run its test file under taskpolicy -b with a hard limit"; exit 2; }
# a line stop: while the common dir's wt-line-stop exists, holding one lane's name, every other lane's check
# refuses at once, so a base that reds every check spends no landing on a certain red, and the named lane
# lands the stop's own fix. check.sh runs from the scratch rebased onto origin/wt2, so a stop binds every
# lane's ship as soon as this lands, whatever autoship.sh its loop runs (a stop by message leaked six loops
# into four certain D14 reds, march-corrector 2026-10-29 13:20)
# The stop is read again as the check's last step, before it answers green: a check already running when the stop
# was set passed and pushed under it, a hand edit landing in the named lane's file (5a89f571 at 14:53:30, a minute
# into a stop naming wt3-skeleton; march-corrector 2026-10-29 14:55)
stop="$(git rev-parse --path-format=absolute --git-common-dir)/wt-line-stop"
line_stop() {
  if [ -f "$stop" ] && [ "$(head -1 "$stop")" != "$(basename "${WT_DEPOT_DIR:-$(pwd)}")" ]; then
    echo "check: REFUSED — line stop: only $(head -1 "$stop") lands until $stop is removed"; exit 2
  fi
}
line_stop
# the depot of the lane being checked: dev/ship.sh checks in a scratch worktree of the lane and
# names the lane in WT_DEPOT_DIR, so its compiled images are the lane's, never a cold depot
. dev/depot.sh; wt_depot_export "${WT_DEPOT_DIR:-$(pwd)}"
# D31: the machine is shared (Dale's own jobs run beside the lanes) and has 4 performance cores; one
# check runs at a time across every lane, its five processes (the ratchet and four shards of the src
# tests) on the performance cores, while every other Julia runs at background QoS on the efficiency
# cores (audit #53, A53E1: two checks at once spilled onto efficiency cores at half speed). One check at a
# time is the landing lock's: a check runs only under it (CHECK_LANDING, above), so it waits on nothing else.
# A separate check slot that anything could take was a second gate on the same thing, and an ad-hoc run
# holding it stalled a landing's check and nine ships behind it for five minutes (2026-10-29 10:01).
export JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=2
# the landing compiles no case of the dart corpus, only proving the native answers a change adds or edits; the
# whole corpus runs beside the landings on wt2's head (dev/corpus.sh, test/src/dart_tests.jl)
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
  # a new dependency's own image is built here, once per lane, outside the judged load stage: the in-repo
  # lib/WasmInterpreter (87b1bcc6) builds about 80 CPU-s of Compiler code, which would turn each lane's first
  # landing after it red on D14 for a cost the lane's change did not add
  # it runs only when the lane's Manifest lacks the dependency (its first check after the dependency lands); a
  # later change to that dependency's source rebuilds inside the judged load stage, as WasmTarget's own does.
  # Its cost is printed, unjudged, so the audit sees each one (march-monitor-a, 11:08)
  WT_NEW_DEPS="$missing_deps" /usr/bin/time -o .wtd/newdeps.time julia --project=. --startup-file=no -e 'using Pkg; Pkg.precompile(split(ENV["WT_NEW_DEPS"]))' >> .wtd/resolve.out 2>&1 ||
    { echo "check: a new dependency does not precompile"; tail -20 .wtd/resolve.out; exit 1; }
  # a few CPU-s is Pkg finding the image already built (a no-op), which is no build to count
  c=$(awk '{ printf "%d", $3 + $5 }' .wtd/newdeps.time)
  [ "$c" -ge 5 ] && echo "check: built the image of new dependency $(echo $missing_deps | tr '\n' ' ')unjudged, $c CPU-s"
fi
# an in-repo dependency (lib/<name>, a path source) this change leaves untouched is built here too, unjudged: a
# lane whose Manifest already named lib/WasmInterpreter still built its image inside the judged load the first
# time its depot met it (31 CPU-s, wt3-codegen, 11:36). A change that edits lib/<name> pays its rebuild inside
# the judged load, as WasmTarget's own does; each unjudged build prints its cost for the audit
# test/DartCorpus, the dart tests' corpus image, is one more: loaded through LOAD_PATH by test/DartCorpus/load.jl, its
# image built from test/smoke_corpus.jl and the package, so a change leaving those untouched builds it here (once per
# corpus content, into the common dir's shared depot) and one that edits them pays the build inside the judged load
unjudged_build() {   # <name> <paths the image is built from> -- <command>
  local name=$1; shift; local paths=(); while [ "$1" != -- ]; do paths+=("$1"); shift; done; shift
  git diff --quiet "${CHECK_BASE:-HEAD~1}" HEAD -- "${paths[@]}" 2>/dev/null || return 0
  /usr/bin/time -o ".wtd/dep.$name.time" "$@" >> .wtd/resolve.out 2>&1 ||
    { echo "check: $name does not precompile"; tail -20 .wtd/resolve.out; exit 1; }
  c=$(awk '{ printf "%d", $3 + $5 }' ".wtd/dep.$name.time")
  [ "$c" -ge 5 ] && echo "check: built the image of in-repo dependency $name unjudged, $c CPU-s"
  return 0
}
for d in lib/*/; do
  name=$(basename "$d"); grep -qE "^$name *=" Project.toml || continue
  unjudged_build "$name" "$d" -- julia --project=. --startup-file=no -e "using Pkg; Pkg.precompile(\"$name\")"
done
unjudged_build DartCorpus test/smoke_corpus.jl test/DartCorpus -- julia --project=. --startup-file=no test/DartCorpus/load.jl
# dev/SkeletonImage (dev/SkeletonImage/src/SkeletonImage.jl), the generator's image the ratchet's L210 loads (dev/skeleton.jl and its reader's compiled
# code): one more, a change leaving dev/skeleton.jl and the package untouched building it here
unjudged_build SkeletonImage dev/skeleton.jl dev/SkeletonImage -- julia --project=. --startup-file=no -e 'push!(LOAD_PATH, joinpath(pwd(), "dev", "SkeletonImage")); using SkeletonImage'
# a change to WasmTarget's source pays its precompile inside the judged load, every attempt: the depot's
# WasmTarget images go first, so a retry of the same tree in the same scratch path cannot load the image its red
# attempt built and read "load 0" (779986b2 landed a change to src/ on "120 s (load 0 ...)", its precompile
# cached by the stale loop's earlier attempt, march-monitor-a 12:46). Its dependencies' images stay. The depot is the
# lane's own and one check runs at a time under the landing lock, so no other process is loading these images; every
# file the image tracks (each include, include_dependency) is under src/, and Manifest.toml is not in git
if ! git diff --quiet "$base" HEAD -- src Project.toml 2>/dev/null; then
  rm -rf "${JULIA_DEPOT_PATH%%:*}"/compiled/v*/WasmTarget
fi
# the shared checkout of Julia's sources the pinned anchors read (~/.cache/wasmtarget/julia) holds every unit this
# tree's JULIA_FILES names before WasmTarget loads: a tree on an older base running its own older dev/fetch_julia.sh
# rewrites the shared sparse list without the newer units, and every lane's load then fails check_quarantine_pinned
# ("WasmTarget does not load"; src/support stripped at 17:14Z, after 686966ac cited it). This tree's script only grows
# the list and, at the pinned commit, only re-reads the tree, with no fetch (unjudged, a second or two)
bash dev/fetch_julia.sh > .wtd/fetch_julia.out 2>&1 || { echo "check: the julia checkout cannot be made"; tail -5 .wtd/fetch_julia.out; exit 1; }
# every stage runs under dev/tree_instructions.jl, which writes to .wtd/<stage>.gi what its whole process tree retired, each
# process read at its exit: its instructions and those on performance cores, its CPU seconds and those on performance
# cores, and the stage's own process's instructions (the load's precompile runs in a child process rusage does not
# report, and the shards' node and wasm-opt are children too). D14's band reads them below. The counter's plant runs
# first: a tree whose grandchild does fixed work, counted whole, each split inside its whole, and a run at background
# QoS read wholly on efficiency cores
julia --startup-file=no dev/tree_instructions.jl --plant > .wtd/tree_plant.out 2>&1 || { echo "check: the load's instruction counter fails its plant: $(tail -1 .wtd/tree_plant.out)"; exit 1; }
julia --startup-file=no dev/tree_instructions.jl .wtd/load.gi julia --project=. --startup-file=no -e 'using WasmTarget' > .wtd/load.out 2>&1 || { echo "check: WasmTarget does not load"; tail -30 .wtd/load.out; exit 1; }
# a hard limit no stage may outlive, whatever the load: a hang is red within minutes and names the
# test file and case it was running (WT_PROGRESS), never an hour of a pinned core (2026-10-28: a
# shared-DAG constant hashed in 2^40 steps and held a landing for 50 minutes)
WT_HARD_LIMIT=480   # a literal, never set from a lane's shell (A50E1); band: today's slowest loaded check is ~170 s
julia --startup-file=no dev/tree_instructions.jl .wtd/ratchet.gi julia --project=. --startup-file=no test/parity_ratchet.jl > .wtd/ratchet.out 2>&1 & rpid=$!
# five shards beside the ratchet: each shard's instructions, which D14's band judges, are its own ~49 CPU-s first
# compile of WasmTarget plus a fifth of the suite's tests, and the suite grows with every port (the judged path read
# 105-113 s at three shards, 2026-10-29 09:09; at four, every change to src/ read 121 s, load 13 + a shard of 108,
# its tests all green, 2026-11-01 11:20, wt3-memory); a fifth shard takes ~11 s off the slowest, at one more process
# and a slower wall clock, which the band does not judge. A sixth is a STOPGAP (D20): split by instructions
# (25f5d125) the shards still read 477-620 G, about 305 G of each being its own load and first compile of
# WasmTarget's pipeline, so a change to src/ read 125 s (load 13 + a shard of 112 s, its tests green), red, 2026-11-01. It is deleted, back
# to four (A67E1), by the commit that cuts that first-compile cost (wt3-latency). A seventh was tried and reverted
# (A71E1): it took the slowest shard from 589 to 575 G, about 3 s, for one more ~300 G first compile and an eighth Julia
# process on four performance cores (D31)
SHARDS=6; tpids=""
costs="$(git rev-parse --path-format=absolute --git-common-dir)/wt-src-instr.tsv"; rm -f .wtd/src_costs.*
# the shards take files from one queue (test/src_tests.jl), each claimed by a directory made here
rm -rf .wtd/claims; mkdir -p .wtd/claims
for k in $(seq 1 $SHARDS); do
  : > ".wtd/progress.$k"
  WT_PROGRESS="$PWD/.wtd/progress.$k" WT_SRC_SHARD="$k/$SHARDS" WT_SRC_CLAIMS="$PWD/.wtd/claims" WT_SRC_COSTS="$costs" WT_SRC_COSTS_OUT="$PWD/.wtd/src_costs.$k" julia --startup-file=no dev/tree_instructions.jl ".wtd/src_tests.$k.gi" \
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
# every shard reports its summary, or the check is red: a shard whose output is lost passed on its exit status alone, its
# tests unread (fd65f41e's check read "0 of 6 reported" and was green, D9)
reported=$(grep -cE '^src ' .wtd/src_tests.out)
[ "$reported" -eq "$SHARDS" ] || { echo "check: src tests red, $reported of $SHARDS shards reported a summary"; exit 1; }
# the ratchet reports its charter block, or the check is red, for the same reason
grep -q '── charter' .wtd/ratchet.out || { echo "check: the ratchet reported no charter block (its output is lost or cut short)"; exit 1; }
# a check whose tests pass replaces the kept file costs (instructions, G) with its measured ones, file by file, for
# the next check's split, whatever D14's band then reads, since a file's instructions are its own; a row
# for a file this tree, origin/wt2 rebased under the lane, does not hold is dropped, so one lane's unlanded file
# never steers another tree's split (A62E1: a shelved split's dart_core_1..3.jl rows stood in the table)
# (each row is the file, its newest measure and the one before, which test/src_tests.jl costs at their larger)
cat .wtd/src_costs.* 2>/dev/null | awk -F'\t' 'NR == FNR { c[$1] = $2; next } { c[$1] = $2 "\t" ($1 in c ? c[$1] : $2) } END { for (f in c) print f "\t" c[f] }' \
  "$( [ -f "$costs" ] && echo "$costs" || echo /dev/null )" - | sort |
  while IFS="$(printf '\t')" read -r f s; do [ -f "test/src/$f" ] && printf '%s\t%s\n' "$f" "$s"; done > "$costs.new" && mv "$costs.new" "$costs"
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
# D14's band judges the check's own cost in seconds of a performance core (A53E1), read from each stage's whole process
# tree at each process's exit (dev/tree_instructions.jl, rusage_info_v6): the instructions it retired on performance
# cores at that stage's performance-core rate, plus the CPU seconds it spent on efficiency cores, one for one, plus the
# CPU seconds of its processes that reported nothing, one for one (the kernel's whole-tree CPU less the reported:
# perl- and bash-wrapped node, a process killed by a signal or ended by _exit, A81E1). An efficiency core is never
# faster than a performance core on the same work (a lower clock and a narrower core; measured, an efficiency core ran
# Julia's work 1.56 to 3.0 times slower: a julia tree with a 4x10^8-iteration loop, the plant's tree, the load), so its
# seconds stand for at least a performance core's time for that work; Apple's counters read efficiency-core
# instructions low for some instruction mixes (a Julia hash loop, compiled once: 12.2 G on a performance core, 6.2 G on
# an efficiency core), so those are not used. The performance-core instructions are counted exactly, and another
# job's load does not move them, where CPU seconds inflate under contention (the same 417 G read 77 CPU-s, then 101,
# 2026-10-28). Each rate is the lowest of three exact splits of that stage on a green check, so the performance-core
# term reads at or above the time it took (the shards' and the ratchet's splits are printed truncated to whole
# seconds, so each rate divides by the next whole second). Intent: never read low. Band: high by the efficiency cores'
# slowdown on that share (1.0 to about 2.2 for the shards, whose counted efficiency-core rate is half their
# performance-core rate) and by a stage's rate above its lowest (the three splits of each stage span about 12%).
# The shards, three green dev-only checks, 2026-11-02 (performance-core G in performance-core seconds, the lowest of
# each check's six): fd65f41e 375 G in 36 s, f4ea3125 372 in 34, 6baa3349 362 in 36: 362/37 = 9.78
RATE_P_SRC=9.7
# the ratchet, the same checks: fd65f41e 317 G in 27 s, f4ea3125 315 in 26, 6baa3349 317 in 28: 317/29 = 10.9
RATE_P_RATCHET=10.9
# the load of a change to src/, its image removed, three runs at default QoS on a quiet machine, 2026-11-02: 183.9 G in
# 14.86 s (12.38), 182.1 in 15.08 (12.08), 183.6 in 14.68 (12.50): its image codegen runs on several threads at a high
# instruction rate
RATE_P_LOAD=12.0
# a stage's .gi (dev/tree_instructions.jl): G, G on performance cores, CPU-s, CPU-s on performance cores, its own process's
# G, and the CPU-s of its processes that reported nothing (the kernel's whole-tree CPU less the reported)
cpu() { awk '{ printf "%d", $3 + $6 }' ".wtd/$1.gi"; }
# a stage's judged seconds: its performance-core G at its rate, plus its efficiency-core seconds, plus its unreported
# seconds, each at least a performance core's second (A81E1)
ps_of() { awk -v r="$2" '{ printf "%d", $2 / r + ($3 - $4) + $6 }' ".wtd/$1.gi"; }
# a stage's split as the band reads it: performance-core G, efficiency-core seconds, unreported seconds
split_of() { awk '{ printf "%.1f G + %.1f s + %.1f s", $2, $3 - $4, $6 }' ".wtd/$1.gi"; }
# a stage whose performance cores ran slower than its rate reads low there: named, and its rate is re-measured from
# three fresh splits before the next commit that touches it (A80S1)
slow_of() { awk -v r="$2" -v n="$1" '$4 > 1 && $2 / $4 < r { printf " %s ran %.1f G a performance-core second, under its rate %s;", n, $2 / $4, r }' ".wtd/$1.gi"; }
c_load=$(ps_of load $RATE_P_LOAD); p_ratchet=$(ps_of ratchet $RATE_P_RATCHET); path_par=$p_ratchet; shards=""; cpus="$(cpu ratchet)"; splits="$(split_of ratchet)"
slow="$(slow_of load $RATE_P_LOAD)$(slow_of ratchet $RATE_P_RATCHET)"
for k in $(seq 1 $SHARDS); do p=$(ps_of "src_tests.$k" $RATE_P_SRC); shards="$shards $p"; cpus="$cpus $(cpu "src_tests.$k")"; splits="$splits; $(split_of "src_tests.$k")"; slow="$slow$(slow_of "src_tests.$k" $RATE_P_SRC)"; [ "$p" -gt "$path_par" ] && path_par=$p; done
path=$(( c_load + path_par ))
echo "check: ${path} s on the critical path (load ${c_load}, ratchet ${p_ratchet}, src shards${shards}; performance-core G + efficiency-core seconds + unreported seconds: load $(split_of load); ratchet ${splits}); ${wall}s wall; CPU-s, unjudged: load $(cpu load), ${cpus}"
[ -z "$slow" ] || echo "check: note, a stage's performance cores ran under its rate, so it reads low there:${slow}"
# D14's band is red past 120 s; Dale raised it to 140 s on 2026-11-01 ("Raise to 140 s until the cut") while every
# change to src/ read 121-126 s on each shard's ~300 G first compile of WasmTarget, then to 160 s the same day ("Raise
# to 160 until the cuts") once the load counted whole by instructions read ~33 s and a src path ~155 s (load 33 +
# max(ratchet 112, shards 122)). It stepped to 140 s when cuts 1 and 2 of the shards' first compile landed (7a2f804e, d0444541: the
# first compile 348 -> 263 G; d0444541's own src check read 131 s) with the ratchet's L210 cache (ad31d8f6), and steps
# to 120 s with SHARDS back to four (wt3-latency, A67E1/A68E2); the 60-s target is unchanged
D14_RED=140
# the band and the shard count are one schedule, the option Dale chose: 140 s while SHARDS is above four, 120 s at four
# or fewer. D14_RED stays a literal (dev/ship.sh's retry cap reads it from origin), so a mismatch is refused here (A81S1)
[ $(( SHARDS > 4 ? 140 : 120 )) -eq $D14_RED ] || { echo "check: RED — D14_RED=$D14_RED disagrees with SHARDS=$SHARDS (140 s while SHARDS > 4, then 120 s, the option Dale chose)"; exit 1; }
# today's judged path fell by measure alone, nothing the check runs changed: 156 (CPU-s) -> 131 (f8afd6e5) -> ~95
# (89a5deb2), 2026-11-01/02; D14's intent is about a minute of wall, so a judged path under 120 is not D14 met
[ $path -gt $D14_RED ] && { echo "check: RED — ${path} s, past D14's band (a 60-s target, red past ${D14_RED} s until four shards, then 120 s)"; exit 1; }
line_stop
echo "check: green (${wall}s)"
