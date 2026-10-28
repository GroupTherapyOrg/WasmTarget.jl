#!/usr/bin/env bash
# dev/lane.sh — the one way a lane makes and removes its worktree; every lane develops in a live
# Kaimon session, the loop's speed rests on (dev/kaimon_session.sh).
#
#   bash dev/lane.sh start <name>   # ../.worktrees/<name> on a new branch <name> from origin/wt3, the
#       main tree's Manifest.toml copied in and resolved for the lane's project when it names other
#       extensions (dev/manifest_check.sh), a git-excluded LocalPreferences.toml turning WasmTarget's
#       precompile workload off (a src edit reloads in seconds), the worktree added to Kaimon's projects
#       (~/.config/kaimon/projects.json: enabled, 4 threads, no startup file; every other entry kept),
#       and the call that starts its session printed
#   bash dev/lane.sh stop <name>    # removes the worktree (git refuses a dirty one) and its project entry
#
# KAIMON_PROJECTS names another projects file (the lock's fixed cases use one).
set -euo pipefail
cmd=${1:?usage: dev/lane.sh start|stop|depot <name>}
name=${2:?usage: dev/lane.sh start|stop|depot <name>}
case "$name" in */* | .* | "") echo "lane: a lane's name is one path component: $name — refusing"; exit 1 ;; esac
MARCH=${WT_MARCH_BRANCH:-wt3}
# the main tree: the repository whose .git every worktree shares
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
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
    cp "$MAIN/Manifest.toml" "$WT/Manifest.toml"
    # the main tree's Manifest can name another project's extensions (WT1's, after A2c): resolved for the
    # lane's own Project.toml when dev/manifest_check.sh says so, and checked again, or the lane refuses
    if ! bash "$WT/dev/manifest_check.sh" "$WT" >/dev/null; then
        (cd "$WT" && julia --startup-file=no --project=. -e 'using Pkg; Pkg.resolve()')
        mc=$(bash "$WT/dev/manifest_check.sh" "$WT") || { echo "lane: $mc after Pkg.resolve() — refusing"; exit 1; }
    fi
    printf '[WasmTarget]\nprecompile_workload = false\n' > "$WT/LocalPreferences.toml"
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
