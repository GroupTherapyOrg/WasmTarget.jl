#!/usr/bin/env bash
# dev/lane.sh — the one way a lane makes and removes its worktree; every lane develops in a live
# Kaimon session, which `dev/land.sh land` requires (dev/kaimon_session.sh).
#
#   bash dev/lane.sh start <name>   # ../.worktrees/<name> on a new branch <name> from origin/wt2, the
#       main tree's Manifest.toml copied in and resolved for the lane's project when it names other
#       extensions (dev/manifest_check.sh), a git-excluded LocalPreferences.toml turning WasmTarget's
#       precompile workload off (a src edit reloads in seconds), the worktree added to Kaimon's projects
#       (~/.config/kaimon/projects.json: enabled, 4 threads, no startup file; every other entry kept),
#       and the call that starts its session printed
#   bash dev/lane.sh stop <name>    # removes the worktree (git refuses a dirty one) and its project entry
#
# KAIMON_PROJECTS names another projects file (the lock's fixed cases use one).
set -euo pipefail
cmd=${1:?usage: dev/lane.sh start|stop <name>}
name=${2:?usage: dev/lane.sh start|stop <name>}
case "$name" in */* | .* | "") echo "lane: a lane's name is one path component: $name — refusing"; exit 1 ;; esac
MARCH=${WT_MARCH_BRANCH:-wt2}
# the main tree: the worktree holding the march branch, as dev/land.sh finds it
MAIN=$(git worktree list --porcelain | awk -v b="branch refs/heads/$MARCH" '/^worktree / { w = substr($0, 10) } $0 == b && m == "" { m = w } END { print m }')
[ -n "$MAIN" ] || { echo "lane: no worktree holds $MARCH — refusing"; exit 1; }
WT="$(dirname "$MAIN")/.worktrees/$name"
PROJ=${KAIMON_PROJECTS:-$HOME/.config/kaimon/projects.json}
# adds (add) or removes (remove) the worktree's entry in the projects file, keeping every other entry
projects() {
    python3 -I - "$1" "$PROJ" "$WT" <<'PY'
import json, os, sys
op, path, wt = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) else {"projects": []}
ps = [p for p in d.get("projects", []) if p.get("project_path") != wt]
if op == "add":
    ps.append({"project_path": wt, "enabled": True,
               "launch_config": {"threads": "4", "startup_file": False, "instantiate": "auto"}})
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
    projects add
    echo "lane: $WT on $name from origin/$MARCH $(git -C "$WT" rev-parse --short HEAD), a Kaimon project in $PROJ"
    echo "lane: start its session: mcp__kaimon__start_session(project_path=\"$WT\", private=true)"
    ;;
stop)
    projects remove
    if [ -e "$WT" ]; then git -C "$MAIN" worktree remove "$WT"; fi
    echo "lane: $WT removed, its Kaimon project entry gone (the branch $name stays)"
    ;;
*) echo "lane: unknown command $cmd"; exit 1 ;;
esac
