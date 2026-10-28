#!/usr/bin/env bash
# The full matrix's verdict (AGENTS.md; dev/CHARTER.md C10). A landing's evidence is `bash dev/check.sh`,
# run by `bash dev/ship.sh`, never this.
#
#   bash dev/gate.sh [<rev>]   # <rev> (HEAD by default), a commit on origin's wt2
#
# The full matrix is .github/workflows/gate.yml on CI's runners, every lane of `bash dev/lanes.sh`'s
# default run as its own job (the first red job cancels the rest). It runs at clause closure: on the
# push of a wt2 head carrying `Closes: C<n>` (a landing, `bash dev/ship.sh`) or a dispatch, never
# holding a landing; the one final full gate before PR #128 merges is that run on the exact merge
# head. This command pushes nothing (one branch on origin, wt2: Dale 2026-10-28): it finds the
# Gate run of the commit on wt2, says how to get one when there is none, waits for it, and prints
# one verdict line per lane, the slowest lane job against the budget gate.yml's lane timeout sets
# (a job the budget cut off is marked past it), and `LANES green` or `LANES red`. Exit 0 only on
# green. A verdict the GitHub API would not give (every read retried three times, the waits between
# them growing) is `LANES unknown`, exit 3: a lost connection is never read as a red run. It runs no
# Julia on this machine.
set -uo pipefail
cd "$(dirname "$0")/.."
MARCH=wt2
command -v gh >/dev/null || { echo "gate: needs the GitHub CLI (gh)" >&2; exit 2; }
# an API read, retried: three tries, 10 s then 30 s apart; its output, or nothing and status 1
api() { local out k; for k in 1 2 3; do out=$("$@" 2>/dev/null) && { printf '%s' "$out"; return 0; }
          [ $k -lt 3 ] && sleep $((k == 1 ? 10 : 30)); done; return 1; }
verdict=LANES
rev=${1:-HEAD}
sha=$(git rev-parse --verify -q "$rev^{commit}") || { echo "gate: no commit $rev" >&2; exit 2; }
s0=$(date +%s)
git fetch -q origin "$MARCH" || { echo "gate: cannot fetch origin/$MARCH" >&2; exit 2; }
git merge-base --is-ancestor "$sha" "origin/$MARCH" ||
  { echo "gate: $(git log -1 --format='%h %s' "$sha" | cut -c1-80) is not on origin/$MARCH: land it with bash dev/ship.sh" >&2; exit 2; }
echo "gate: $(git log -1 --format='%h %s' "$sha" | cut -c1-80) on $MARCH"
# the run a wt2 push of this commit started, by name, not --workflow (which finds only a workflow on
# the default branch; a gate.yml that does not parse is named by its path, and its run is red); a
# push just made may take a minute to show its run
run=""
for _ in $(seq 12); do
  run=$(api gh run list --branch "$MARCH" --limit 100 --json databaseId,headSha,workflowName,displayTitle \
       --jq "[.[] | select(.headSha == \"$sha\" and (.workflowName == \"Gate\" or .workflowName == \".github/workflows/gate.yml\"))][0] |
             select(. != null) | \"\\(.databaseId)\\t\\(.displayTitle)\"")
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "gate: no gate.yml run for ${sha:0:8} on $MARCH: the full matrix runs on the wt2 push of a head carrying \`Closes: C<n>\`; land one with bash dev/ship.sh" >&2; exit 2; }
id=${run%%$'\t'*}; title=${run#*$'\t'}
if [ "$title" = "Gate (no closure)" ]; then
  echo "gate: run $id ran no matrix: ${sha:0:8} carries no \`Closes: C<n>\`; the full matrix runs on the wt2 push of a head that does (bash dev/ship.sh)" >&2; exit 2
fi
echo "gate: run $id  $(api gh run view "$id" --json url --jq .url)"
# the run is done when the API says completed: a watch the connection drops is resumed, and a run
# whose status the API will not give after the retries has no verdict
until [ "$(api gh run view "$id" --json status --jq .status)" = completed ]; do
  gh run watch "$id" --interval 30 >/dev/null 2>&1 || sleep 30
  api gh run view "$id" --json status --jq .status >/dev/null ||
    { echo "gate: the API gives no status for run $id: no verdict"; echo "$verdict unknown"; exit 3; }
done
# the budget B, minutes per lane job: the lane job's timeout in gate.yml, the one source (L162)
budget=$(awk '/^  lane:$/ { inlane = 1; next } /^  [a-z][a-z-]*:$/ { inlane = 0 }
              inlane && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate.yml)
[ -n "$budget" ] || { echo "gate: gate.yml's lane job has no timeout-minutes, the budget" >&2; exit 2; }
# a job whose step failed is red, though its own `Cancel the run` step leaves it cancelled
api gh run view "$id" --json jobs --jq '.jobs[] | [(if any(.steps[]?; .conclusion == "failure") then "failure" else .conclusion end), .name,
    (if (.startedAt // "") != "" and (.completedAt // "") != "" and .startedAt < .completedAt
     then ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601) | tostring) else "" end)] | @tsv' |
  awk -F'\t' -v B="$budget" '{ v = $1 == "success" ? "ok  " : $1 == "failure" ? "FAIL" : "--  ";
                 past = ($3 != "" && $3 + 0 >= B * 60) ? sprintf("  PAST THE %d-MINUTE BUDGET", B) : "";
                 printf "  %s %-16s %6s  %s%s\n", v, $2, ($3 == "" ? "" : $3 "s"), ($1 == "success" ? "" : $1), past
                 if ($2 != "closure" && $3 != "" && $3 + 0 > slow) { slow = $3 + 0; slowest = $2 } }
               END { if (slowest != "") printf "gate: slowest lane job %s %d s of the budget %d min (%d s)%s\n",
                       slowest, slow, B, B * 60, (slow >= B * 60 ? ", PAST IT" : "") }'
conclusion=$(api gh run view "$id" --json conclusion --jq .conclusion)
echo "gate: wall $(( $(date +%s) - s0 ))s"
if [ "$conclusion" = success ]; then echo "$verdict green"; exit 0; fi
# only a conclusion the API gave is red; none (a lost connection, an empty read) is unknown
if [ -z "$conclusion" ]; then echo "gate: the API gives no conclusion for run $id: no verdict"; echo "$verdict unknown"; exit 3; fi
echo "the red lane's log: gh run view $id --log-failed"
echo "$verdict red"; exit 1
