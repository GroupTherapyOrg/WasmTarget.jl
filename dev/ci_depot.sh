#!/usr/bin/env bash
# The gate's Julia depot across gate branches (dev/CHARTER.md C10, L193): a lane job restores the
# packages, artifacts and dependency images a previous gate run published, so no job precompiles
# the dependencies again. GitHub scopes an actions/cache entry to its branch and the default
# branch, and every batch gates on its own gate/<name> branch, so a cache never reached the next
# batch: each new gate branch precompiled its 136 test dependencies in 323-466 s per job (run
# 37943322602). An artifact is repository-wide; the newest one of the depot's name is restored.
#
#   bash dev/ci_depot.sh name <cfg>        # the artifact name: depot-<cfg>-<julia version>-<target>
#   bash dev/ci_depot.sh restore <cfg>     # the newest such artifact into ~/.julia, then a marker
#   bash dev/ci_depot.sh save <cfg> <dir>  # after the lane: when it compiled a dependency image the
#                                          # restored depot lacked, the depot into <dir>/depot.tar.zst
#                                          # and save=true for the upload step; else save=false
#
# The depot holds no WasmTarget image (each job compiles the package under test itself, ~10 s
# with the workload off, LocalPreferences.toml), so what a job restores never stands for the tree
# it tests. A restored image is used only if Julia's own staleness check accepts it (the source
# files' hashes, the build ids of its dependencies, the CPU target); anything else is recompiled,
# so a stale or foreign depot costs time, never a wrong verdict. The image target is the
# workflow's JULIA_CPU_TARGET, Julia's own multi-target list, so an image compiled on one runner
# CPU model loads on the others (a native image compiled on one model was recompiled on another:
# 7 of 9 jobs rebuilt the restored environment, run 37891241960).
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=${1:?usage: dev/ci_depot.sh name|restore|save <cfg> [<dir>]}
cfg=${2:?cfg}
case "$cfg" in lanes|lanes-1.13|suite) ;; *) echo "ci_depot: no depot $cfg (lanes, lanes-1.13 or suite)" >&2; exit 2 ;; esac
J=julia; [ "$cfg" = lanes-1.13 ] && J="julia +1.13"
depot="${JULIA_DEPOT_PATH:-$HOME/.julia}"; depot=${depot%%:*}
marker="$depot/.ci_depot_restored"
name() {
  [ -n "${JULIA_CPU_TARGET:-}" ] || { echo "ci_depot: JULIA_CPU_TARGET is unset: a native image loads on one CPU model only" >&2; exit 2; }
  echo "depot-$cfg-$($J --startup-file=no -e 'print(VERSION)')-$(printf '%s' "$JULIA_CPU_TARGET" | git hash-object --stdin | cut -c1-8)"
}
case "$cmd" in
name) name ;;
restore)
  n=$(name); mkdir -p "$depot"
  id=$(gh api "repos/{owner}/{repo}/actions/artifacts?name=$n&per_page=100" \
         --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .id // empty')
  if [ -n "$id" ]; then
    t0=$(date +%s)
    gh api "repos/{owner}/{repo}/actions/artifacts/$id/zip" > "$RUNNER_TEMP/depot.zip"
    unzip -p "$RUNNER_TEMP/depot.zip" depot.tar.zst | zstd -dc | tar -x -C "$depot"
    rm -f "$RUNNER_TEMP/depot.zip"
    echo "ci_depot: restored $n (artifact $id) in $(( $(date +%s) - t0 )) s"
  else
    echo "ci_depot: no artifact $n: this job precompiles the dependencies and publishes the depot"
  fi
  touch "$marker"
  ;;
save)
  dir=${3:?dir}; mkdir -p "$dir"
  out=${GITHUB_OUTPUT:-/dev/stdout}
  [ -e "$marker" ] || { echo "ci_depot: no restore marker in $depot" >&2; exit 2; }
  # a dependency image this job compiled: the restored depot lacked it (or Julia rejected it)
  new=$(find "$depot/compiled" -newer "$marker" -type f \( -name '*.ji' -o -name '*.so' \) 2>/dev/null |
        grep -v '/WasmTarget[^/]*/' | wc -l | tr -d ' ')
  echo "ci_depot: $new dependency image files compiled by this job"
  if [ "$new" -eq 0 ]; then echo "save=false" >> "$out"; exit 0; fi
  ( cd "$depot" && tar -cf - --exclude='compiled/*/WasmTarget*' \
      $(for d in compiled packages artifacts scratchspaces; do [ -d "$d" ] && echo "$d"; done) ) |
    zstd -T0 -3 -q -o "$dir/depot.tar.zst"
  echo "ci_depot: $(du -h "$dir/depot.tar.zst" | cut -f1) to publish as $(name)"
  echo "save=true" >> "$out"
  echo "name=$(name)" >> "$out"
  ;;
*) echo "ci_depot: unknown command $cmd" >&2; exit 2 ;;
esac
