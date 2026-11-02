#!/usr/bin/env bash
# The whole dart corpus, compiled on the march branch's head beside the landings, never in their path.
# A landing compiles none of it (dev/check.sh, WT_LANDING_CORE); every case runs here, once per new head, so a
# landing's cost stays fixed while the corpus deepens.
#
#   bash dev/corpus.sh          loop: each new head of origin/wt2, once; idle a minute between looks
#   bash dev/corpus.sh --once   the current head, once
#
# Each run appends <utc>\t<head>\t<green|red|hung>\t<seconds>\t<first failure> to the common dir's
# wt-corpus.tsv and leaves its output in wt-corpus.out (a red run's also in wt-corpus-red-<head>.out); a red
# head is the next lane's first fix.
# It runs at background QoS (taskpolicy -b: efficiency cores only), taking no check slot, so it never takes
# a performance core a landing's check needs (D31).
set -uo pipefail
MARCH=wt2
cd "$(dirname "$0")/.."
common="$(git rev-parse --path-format=absolute --git-common-dir)"
scratch="$common/wt-corpus"   # kept between runs: its private depot stays warm
tsv="$common/wt-corpus.tsv"; out="$common/wt-corpus.out"
# each case's verdict as a run reaches it (test/src/dart_tests.jl's WT_DART_CASES): <head> <case> <verdict> <CPU-s> <why>
cases="$common/wt-corpus-cases.tsv"
costs="$common/wt-dart-costs.tsv"   # each dart group's seconds in the last green run: the shards' split
# a hard limit no run may outlive (2026-10-28: hangs are never allowed): a literal, naming the case. It is judged by each
# shard's CPU seconds, its finished attempts' and its live processes', never the wall clock, which at background QoS
# measured the scheduler (6732d4a6: shards at 20 to 36% of an efficiency core, 243 to 434 CPU-s in a 1200-s run). The
# wall backstop stands only against a true hang, a run that accrues no CPU: the limit over 0.2, the lowest share
# measured, so at that share the CPU limit fires first
WT_CORPUS_LIMIT=1200
WT_CORPUS_WALL=6000
lock="$common/wt-corpus.lock"
if ! mkdir "$lock" 2>/dev/null; then
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then echo "corpus: already running (pid $holder)"; exit 2; fi
  rm -rf "$lock"; mkdir "$lock" || { echo "corpus: cannot take its lock"; exit 2; }
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

run_head() {
  local head=$1 r0 t rc result first
  r0=$(date +%s)
  if [ -d "$scratch/.git" ] || [ -f "$scratch/.git" ]; then git -C "$scratch" checkout -q --detach "$head" || return 1
  else rm -rf "$scratch"; git worktree add -q --detach "$scratch" "$head" || return 1; fi
  [ -f Manifest.toml ] && cp Manifest.toml "$scratch/Manifest.toml"
  (
    cd "$scratch" && . dev/depot.sh && wt_depot_export "$scratch"
    export JULIA_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=2 WT_PROGRESS="$scratch/.wtd/progress"
    # the run's verdicts start empty for its head (a head run again is counted afresh), each shard appending its own
    export WT_DART_CASES="$cases" WT_DART_HEAD="$(git rev-parse --short "$head")"
    [ -f "$cases" ] && { awk -F'\t' -v h="$WT_DART_HEAD" '$1 != h' "$cases" > "$cases.new"; mv "$cases.new" "$cases"; }
    : > "$WT_PROGRESS"
    # the corpus in CORPUS_SHARDS shards side by side (test/src/dart_tests.jl's WT_DART_SHARD), each on the
    # efficiency cores, so its wall time stays inside its limit as the ported dart tests grow (one run took
    # 346 s, then 733 s two hours later, 2026-10-28); four since 918 s on 2db99073 (2026-10-29), the six efficiency
    # cores holding four shards beside the lanes' background runs
    # the shards split by each group's measured seconds (wt-dart-costs.tsv, kept from the last green run), so their
    # compiles and node runs end together (a split by index put 859 modules in one shard, which hung, a5e89d25)
    CORPUS_SHARDS=4; jpids=""; rm -f "$scratch"/.wtd/shard.*.time "$scratch"/.wtd/shard.*.cpu "$scratch"/.wtd/dart_costs.*
    # each shard runs under dev/corpus_shard.sh, again past a case whose process its watchdog killed, so one hang
    # costs a restart and its case's verdict, never the shard's other verdicts (665146f1, 2026-11-01)
    for k in $(seq 1 $CORPUS_SHARDS); do
      : > "$WT_PROGRESS.$k"
      WT_PROGRESS="$WT_PROGRESS.$k" WT_DART_SHARD="$k/$CORPUS_SHARDS" WT_DART_COSTS="$costs" WT_DART_COSTS_OUT="$scratch/.wtd/dart_costs.$k" \
        bash dev/corpus_shard.sh "$out.$k" "$scratch/.wtd/shard.$k" taskpolicy -b /usr/bin/time -o "$scratch/.wtd/shard.$k.time" julia --project=. --startup-file=no -e '
        using Test
        wt_progress(s::AbstractString) = write(ENV["WT_PROGRESS"], s)
        @testset "corpus" begin include("test/src/dart_tests.jl") end' & jpids="$jpids $!"
    done
    # a shard's whole process tree, read before any of it is signalled (a child whose parent died is no longer its child)
    treepids() { local c; echo "$1"; for c in $(pgrep -P "$1"); do treepids "$c"; done; }
    # shard k's CPU seconds so far: its finished attempts' (dev/corpus_shard.sh's `times`, in its state dir) and its live
    # processes' (ps); /usr/bin/time writes nothing for a process killed under it, so a hung run's CPU-s are read here
    shard_cpu() {
      local done; done=$(cat "$scratch/.wtd/shard.$1/cpu" 2>/dev/null || echo 0)
      ps -o time= -p "$(treepids "$2" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null |
        awk -F: -v d="$done" '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; t += s } END { printf "%d\n", t + d }'
    }
    s0=$(date +%s)
    alive() { for p in $jpids; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
    while alive; do
      k=0; over=""
      for p in $jpids; do
        k=$((k + 1)); shard_cpu "$k" "$p" > "$scratch/.wtd/shard.$k.cpu"
        [ "$(cat "$scratch/.wtd/shard.$k.cpu")" -gt "$WT_CORPUS_LIMIT" ] && over="shard $k past ${WT_CORPUS_LIMIT} CPU-s"
      done
      [ $(( $(date +%s) - s0 )) -gt "$WT_CORPUS_WALL" ] && over="past the ${WT_CORPUS_WALL}-s wall backstop"
      if [ -n "$over" ]; then
        cat "$out".[0-9]* > "$out"
        echo "corpus: past the hard limit ($over) at: $(cat "$WT_PROGRESS".[0-9]* | tr '\n' ' ')" >> "$out"
        # a julia deep in a compile may outlive SIGTERM: three hung runs left their shards running with no
        # parent, holding swap for half an hour (march-corrector, 10:55); a shard still alive 10 s later is killed
        echo "corpus: each shard's CPU-s at the hard limit, at $(( $(date +%s) - s0 ))s wall: $(cat "$scratch"/.wtd/shard.[0-9]*.cpu | tr '\n' ' ')" >> "$out"
        tree=$(for p in $jpids; do treepids "$p"; done)
        kill $tree 2>/dev/null; sleep 10; kill -9 $tree 2>/dev/null; exit 124
      fi
      sleep 5
    done
    rc=0; for p in $jpids; do wait $p || rc=1; done
    cat "$out".[0-9]* > "$out"
    # a green run's measured group costs replace the kept ones, group by group, for the next run's split
    [ $rc -eq 0 ] && cat "$scratch"/.wtd/dart_costs.* 2>/dev/null | awk -F'\t' 'NR == FNR { c[$1] = $2; next } { c[$1] = $2 } END { for (g in c) print g "\t" c[g] }' \
      "$( [ -f "$costs" ] && echo "$costs" || echo /dev/null )" - | sort > "$costs.new" && mv "$costs.new" "$costs"
    exit $rc
  ); rc=$?
  t=$(( $(date +%s) - r0 ))
  case $rc in 0) result=green;; 124) result=hung;; *) result=red;; esac
  first=$(grep -m1 -E 'Test Failed|Error During Test|hard limit|LoadError' "$out" | tr '\t' ' ' | cut -c1-200)
  # each shard's CPU seconds beside the run's wall: a starved run (CPU far below wall, the machine swapping or
  # crowded) reads apart from a real per-case cost increase (march-corrector, 10:55)
  # each shard's CPU-s over all its attempts, as the limit read them at its last look (shard_cpu); /usr/bin/time's
  # file holds one attempt's, and nothing for one killed under it
  cpu=$(for f in "$scratch"/.wtd/shard.[0-9]*.cpu; do printf '%s ' "$(cat "$f")"; done 2>/dev/null)
  first="${first}${cpu:+ [shard CPU-s: ${cpu% }]}"
  # each shard's first warm-up, its seconds and G instructions: against its 300-s limit (test/src/dart_tests.jl's
  # DART_WARMUP_LIMIT) the trend shows in the row before the limit fires; its G steady, its seconds are contention
  warm=$(sed -n 's/^dart tests: dart_warmup\/[0-9]*-of-[0-9]* the warm-up compile, attempt 1 took \([0-9.]*\) s, \([0-9.]*\) G instructions.*/\1s\/\2G/p' "$out" | tr '\n' ' ')
  first="${first}${warm:+ [warm-up: ${warm% }]}"
  # the cases reached, counted from their verdicts whether the run finished or its limit cut it: a case's last row
  counts=$(awk -F'\t' -v h="$(git rev-parse --short "$head")" '$1 == h { v[$2] = $3 }
    END { for (k in v) { c[v[k]]++; n++ } printf "%d pass, %d fail, %d reject, %d timeout of %d reached", c["pass"], c["fail"], c["reject"], c["timeout"], n }' \
    "$( [ -f "$cases" ] && echo "$cases" || echo /dev/null )")
  first="$counts; $first"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short "$head")" "$result" "$t" "$first" >> "$tsv"
  # a red run's whole output outlives the next run, which truncates wt-corpus.out at its start: kept as
  # wt-corpus-red-<head>.out, the latest three (a red's cases were read from a file the next run had
  # already emptied, twice on 2026-10-28)
  if [ "$result" != green ]; then
    cp "$out" "$common/wt-corpus-red-$(git rev-parse --short "$head").out"
    ls -t "$common"/wt-corpus-red-*.out 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
  fi
  echo "corpus: $(git rev-parse --short "$head") $result in ${t}s${first:+ — $first}"
}

while :; do
  git fetch -q origin "$MARCH" || { sleep 60; continue; }
  head=$(git rev-parse "origin/$MARCH")
  last=$(tail -1 "$tsv" 2>/dev/null | cut -f2)
  if [ "$(git rev-parse --short "$head")" != "$last" ]; then run_head "$head"; fi
  [ "${1:-}" = --once ] && break
  sleep 60
done
