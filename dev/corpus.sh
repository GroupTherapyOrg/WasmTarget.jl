#!/usr/bin/env bash
# The whole dart corpus, compiled on the march branch's head beside the landings, never in their path.
# A landing compiles a fixed core of it (dev/check.sh, WT_LANDING_CORE); what grows with the port runs
# here, once per new head, so a landing's cost stays fixed while the corpus deepens.
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
# a hard limit no run may outlive (2026-10-28: hangs are never allowed): a literal, naming the case
WT_CORPUS_LIMIT=1200
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
    : > "$WT_PROGRESS"
    # the corpus in CORPUS_SHARDS shards side by side (test/src/dart_tests.jl's WT_DART_SHARD), each on the
    # efficiency cores, so its wall time stays inside its limit as the ported dart tests grow (one run took
    # 346 s, then 733 s two hours later, 2026-10-28)
    CORPUS_SHARDS=3; jpids=""
    for k in $(seq 1 $CORPUS_SHARDS); do
      : > "$WT_PROGRESS.$k"
      WT_PROGRESS="$WT_PROGRESS.$k" WT_DART_SHARD="$k/$CORPUS_SHARDS" taskpolicy -b julia --project=. --startup-file=no -e '
        using Test
        wt_progress(s::AbstractString) = write(ENV["WT_PROGRESS"], s)
        @testset "corpus" begin include("test/src/dart_tests.jl") end' > "$out.$k" 2>&1 & jpids="$jpids $!"
    done
    s0=$(date +%s)
    alive() { for p in $jpids; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
    while alive; do
      if [ $(( $(date +%s) - s0 )) -gt "$WT_CORPUS_LIMIT" ]; then
        cat "$out".[0-9]* > "$out"
        echo "corpus: past the hard limit of ${WT_CORPUS_LIMIT}s at: $(cat "$WT_PROGRESS".[0-9]* | tr '\n' ' ')" >> "$out"
        for p in $jpids; do pkill -P $p 2>/dev/null; kill $p 2>/dev/null; done; exit 124
      fi
      sleep 5
    done
    rc=0; for p in $jpids; do wait $p || rc=1; done
    cat "$out".[0-9]* > "$out"
    exit $rc
  ); rc=$?
  t=$(( $(date +%s) - r0 ))
  case $rc in 0) result=green;; 124) result=hung;; *) result=red;; esac
  first=$(grep -m1 -E 'Test Failed|Error During Test|past the hard limit|LoadError' "$out" | tr '\t' ' ' | cut -c1-200)
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
