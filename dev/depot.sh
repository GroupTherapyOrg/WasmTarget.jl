#!/usr/bin/env bash
# dev/depot.sh — a worktree's private first Julia depot (audit 37: twelve worktrees and the gate's
# scratch checkouts shared ~/.julia/compiled/v1.12/WasmTarget, where Julia keeps at most ten images
# of one package, so each tree's image evicted another's and every gate ran cold). Compiled images go
# to <worktree>/.wtd/depot (.wtd/ is git-excluded); packages, registries and artifacts still come from
# the shared depot and Julia's bundled ones, which the trailing empty entry adds.
#
#   . dev/depot.sh; wt_depot_export <dir>   (sourced) exports JULIA_DEPOT_PATH for <dir>
#   bash dev/depot.sh path <dir>            prints that value for <dir>
#   bash dev/depot.sh julia <dir>           writes <dir>/.wtd/julia, a julia that runs with that depot
#                                           (a Kaimon session's julia_bin: dev/lane.sh), prints its path
#
# WT_SHARED_DEPOT names the shared depot (default ~/.julia).

# the JULIA_DEPOT_PATH of directory $1: its private depot first, then the shared and bundled ones
wt_depot_path() {
    printf '%s/.wtd/depot:%s:' "$(cd "$1" && pwd)" "${WT_SHARED_DEPOT:-$HOME/.julia}"
}

# export JULIA_DEPOT_PATH for directory $1, its private depot made
wt_depot_export() {
    mkdir -p "$1/.wtd/depot"
    JULIA_DEPOT_PATH=$(wt_depot_path "$1")
    export JULIA_DEPOT_PATH
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        path)
            wt_depot_path "$2"
            ;;
        julia)
            mkdir -p "$2/.wtd/depot"
            dir=$(cd "$2" && pwd)
            printf '#!/bin/sh\n# written by dev/depot.sh: julia with the private depot of %s\nJULIA_DEPOT_PATH="%s" exec julia "$@"\n' \
                "$dir" "$(wt_depot_path "$dir")" > "$dir/.wtd/julia"
            chmod +x "$dir/.wtd/julia"
            echo "$dir/.wtd/julia"
            ;;
        *)
            echo "usage: bash dev/depot.sh path|julia <dir>  (or source it: . dev/depot.sh; wt_depot_export <dir>)" >&2
            exit 2
            ;;
    esac
fi
