#!/usr/bin/env bash
# The gate's TLC verdicts by content (dev/CHARTER.md C10, L193): a formal part's verdict is a
# function of what it checks alone, the models and instances under dev/formal (run_tlc.sh, the
# pinned tla2tools.jar it fetches, the dealing of the parts), the lane that runs it (dev/lanes.sh, gate.yml),
# the part and the Java that runs TLC. A green part publishes its verdict as an artifact named by
# the hash of all of these; a later gate whose part hashes the same reuses that verdict instead of
# model checking again, and any change to a model, an instance, the harness, the lane or Java
# names another artifact, which no run published, so the part runs. TLC's search over a finite
# instance is exhaustive (a Broken instance runs on one worker, run_tlc.sh), so the same input
# gives the same verdict: the reuse is the computation's result, never a skip.
#
#   bash dev/tlc_verdict.sh key <i/N>      # the artifact name: tlc-<i>of<N>-<hash>
#   bash dev/tlc_verdict.sh lookup <i/N>   # hit=true and the run that published it, or hit=false
#   bash dev/tlc_verdict.sh record <i/N> <dir>   # (after a green part) <dir>/verdict.txt, name=<key>
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=${1:?usage: dev/tlc_verdict.sh key|lookup|record <i/N> [<dir>]}
part=${2:?part i/N}
[[ $part =~ ^[0-9]+/[1-9][0-9]*$ ]] || { echo "tlc_verdict: part $part: expected i/N" >&2; exit 2; }
key() {
  local java; java=$(java -version 2>&1 | head -1) || { echo "tlc_verdict: no working java" >&2; exit 2; }
  # every tracked file under dev/formal, the lane and the workflow that calls it, by path and
  # content (the working tree's)
  local h; h=$( { for f in $(git ls-files dev/formal dev/lanes.sh .github/workflows/gate.yml); do printf '%s %s\n' "$f" "$(git hash-object "$f")"; done
                 printf 'part %s\n' "$part"; } | git hash-object --stdin | cut -c1-20)
  echo "tlc-${part%/*}of${part#*/}-$h"
}
out=${GITHUB_OUTPUT:-/dev/stdout}
case "$cmd" in
key) key ;;
lookup)
  n=$(key)
  run=$(gh api "repos/{owner}/{repo}/actions/artifacts?name=$n&per_page=100" \
          --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .workflow_run.id // empty')
  if [ -n "$run" ]; then
    echo "  ok   formal part $part: the verdict of run $run, whose models, instances, lane and Java hash the same ($n)"
    echo "hit=true" >> "$out"
  else
    echo "  formal part $part: no verdict for $n: model checking"
    echo "hit=false" >> "$out"
  fi
  ;;
record)
  dir=${3:?dir}; mkdir -p "$dir"
  n=$(key)
  printf 'green\t%s\t%s\n' "$n" "$(git rev-parse HEAD)" > "$dir/verdict.txt"
  echo "name=$n" >> "$out"
  ;;
*) echo "tlc_verdict: unknown command $cmd" >&2; exit 2 ;;
esac
