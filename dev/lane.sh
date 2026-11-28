#!/usr/bin/env bash
# dev/lane.sh — the one way a lane makes and removes its worktree; every lane develops in a live
# Kaimon session, the loop's speed rests on.
#
#   bash dev/lane.sh start <name>   # ../.worktrees/<name> on a new branch <name> from origin/wt2, the
#       main tree's Manifest.toml copied in and resolved for the lane's project when it names other
#       extensions (dev/manifest_check.sh), a git-excluded LocalPreferences.toml turning WasmTarget's
#       precompile workload off (a src edit reloads in seconds), the worktree added to Kaimon's projects
#       (~/.config/kaimon/projects.json: enabled, 4 threads, no startup file; every other entry kept),
#       and the call that starts its session printed
#   bash dev/lane.sh stop <name>    # removes the worktree (git refuses a dirty one) and its project entry
#   bash dev/lane.sh manifest <dir> # start's Manifest and preferences step alone, for a tree made another way (the
#       climb's slot clones and measurement trees, dev/climb/climb.py)
#
# KAIMON_PROJECTS names another projects file (the lock's fixed cases use one).
set -euo pipefail
cmd=${1:?usage: dev/lane.sh start|stop|depot|manifest <name>}
# the main tree: the repository whose .git every worktree shares
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
# the main tree's Manifest copied into $1 and, when it names other extensions than $1's project does (WT1's, after
# A2c), resolved for $1's own Project.toml and checked again, or refused (dev/manifest_check.sh); and a git-excluded
# LocalPreferences.toml turning WasmTarget's precompile workload off (a src edit reloads in seconds)
# (the check is the copy beside this script, never the tree's own: a tree's dev/ can be a candidate's, red 1; the
# resolve runs at background QoS, D31)
HERE=$(cd "$(dirname "$0")" && pwd)
manifest() {
    # each file removed first, so a link planted at its name is never written through (council round 4, R3)
    rm -f "$1/Manifest.toml" "$1/LocalPreferences.toml"
    cp "$MAIN/Manifest.toml" "$1/Manifest.toml"
    if ! bash "$HERE/manifest_check.sh" "$1" >/dev/null; then
        (cd "$1" && taskpolicy -b julia --startup-file=no --project=. -e 'using Pkg; Pkg.resolve()')
        mc=$(bash "$HERE/manifest_check.sh" "$1") || { echo "lane: $mc after Pkg.resolve() — refusing"; exit 1; }
    fi
    printf '[WasmTarget]\nprecompile_workload = false\n' > "$1/LocalPreferences.toml"
}
if [ "$cmd" = manifest ]; then manifest "${2:?usage: dev/lane.sh manifest <dir>}"; exit 0; fi
name=${2:?usage: dev/lane.sh start|stop|depot <name>}
case "$name" in */* | .* | "") echo "lane: a lane's name is one path component: $name — refusing"; exit 1 ;; esac
MARCH=${WT_MARCH_BRANCH:-wt2}
WT="$(dirname "$MAIN")/.worktrees/$name"
PROJ=${KAIMON_PROJECTS:-$HOME/.config/kaimon/projects.json}
# adds (add) or removes (remove) the worktree's entry in the projects file, keeping every other entry
projects() {
    python3 -I - "$1" "$PROJ" "$WT" "${JULIA_BIN:-}" <<'PY'
import json, os, sys
op, path, wt, jbin = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(path)) if os.path.exists(path) else {"projects": []}
ps = [p for p in d.get("projects", []) if p.get("project_path") != wt]
if op == "add":
    ps.append({"project_path": wt, "enabled": True,
               "launch_config": {"threads": "4", "startup_file": False, "instantiate": "auto", "julia_bin": jbin}})
d["projects"] = ps
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}
case "$cmd" in
start)
    [ ! -e "$WT" ] || { echo "lane: $WT exists — refusing"; exit 1; }
    git -C "$MAIN" fetch -q origin
    git -C "$MAIN" worktree add -q -b "$name" "$WT" "origin/$MARCH"
    manifest "$WT"
    # the lane's Julia compiles into its private depot, its Kaimon session too (dev/depot.sh)
    JULIA_BIN=$(bash "$WT/dev/depot.sh" julia "$WT") projects add
    echo "lane: $WT on $name from origin/$MARCH $(git -C "$WT" rev-parse --short HEAD), a Kaimon project in $PROJ"
    echo "lane: start its session: mcp__kaimon__start_session(project_path=\"$WT\", private=true)"
    ;;
depot)
    # an existing lane's private depot and its Kaimon session's julia (a lane made before dev/depot.sh)
    [ -d "$WT" ] || { echo "lane: no worktree $WT — refusing"; exit 1; }
    JULIA_BIN=$(bash "$WT/dev/depot.sh" julia "$WT") projects add
    echo "lane: $WT compiles into $WT/.wtd/depot; shut its Kaimon session down and start a new one to take the julia $WT/.wtd/julia (a restart keeps the old julia)"
    ;;
stop)
    projects remove
    if [ -e "$WT" ]; then git -C "$MAIN" worktree remove "$WT"; fi
    echo "lane: $WT removed, its Kaimon project entry gone (the branch $name stays)"
    ;;
*) echo "lane: unknown command $cmd"; exit 1 ;;
esac
