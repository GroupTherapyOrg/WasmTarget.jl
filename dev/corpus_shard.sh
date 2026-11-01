#!/usr/bin/env bash
# dev/corpus_shard.sh — one shard of dev/corpus.sh, run again past each case whose process its watchdog killed
#
#   bash dev/corpus_shard.sh <output> <state dir> <command...>
#
# Julia cannot be relied on to take a case's interrupt (test/src/dart_tests.jl's hard limit), so a case past its limit
# may end with its process killed, and with it every verdict the shard had left to give (on 665146f1 all four
# shards, 2026-11-01). precedent(ReTestItems: src/ReTestItems.jl:453, v1.9.0 085999065a4c): a test item past its
# timeout has its worker terminated, the item recorded as a timeout error (record_timeout!), and a fresh worker
# started for the next item. WT differs: no coordinator holds the queue, so the shard's process is relaunched whole
# and reads where it stands from two records; the kill comes from the case's own watchdog process, not a Timer in a
# coordinator; and a killed case is failed, never retried. The command gets WT_DART_KILLED and WT_DART_DONE in <state dir>: the
# watchdog appends the case it kills to the first, the shard each group block it finishes to the second. A run whose
# process dies after a new kill is recorded runs again, skipping the finished blocks and failing each killed case by
# name, at most CORPUS_ATTEMPTS times; its output appends to <output>. The exit is the last run's, so a kill is a red
# shard whose failing case is named, its other verdicts kept.
set -uo pipefail
# a literal: one attempt per kill. dev/corpus.sh's 1200-s limit holds about eight 120-s case limits with a relaunch
# each (a process start ~30 s), so a build that kills case after case stops here, red, before that limit cuts it
CORPUS_ATTEMPTS=8
out=${1:?usage: dev/corpus_shard.sh <output> <state dir> <command...>}; state=${2:?usage: dev/corpus_shard.sh <output> <state dir> <command...>}; shift 2
mkdir -p "$state"; : > "$state/killed"; : > "$state/done"; : > "$out"
export WT_DART_KILLED="$state/killed" WT_DART_DONE="$state/done"
for attempt in $(seq 1 $CORPUS_ATTEMPTS); do
  nk=$(wc -l < "$WT_DART_KILLED")
  ( WT_DART_ATTEMPT=$attempt "$@" ) >> "$out" 2>&1; rc=$?   # a subshell, so the shell's note of a killed run lands in the output
  { [ $rc -ne 0 ] && [ "$(wc -l < "$WT_DART_KILLED")" -gt "$nk" ]; } || break
  echo "corpus_shard: attempt $attempt's process was killed at $(tail -n 1 "$WT_DART_KILLED"); the shard runs again past it" >> "$out"
done
exit $rc
