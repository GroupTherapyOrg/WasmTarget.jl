#!/usr/bin/env bash
# dev/manifest_check.sh — whether a worktree's untracked Manifest.toml was resolved for its Project.toml
# (A20P23): the extensions of WasmTarget each names, the one check `dev/land.sh land` refuses on and
# `dev/lane.sh start` resolves on (a Manifest copied from the main tree can name another project's
# extensions, and a package image built over it fails).
#
#   bash dev/manifest_check.sh <worktree>   # exit 0 when they match, 1 printing both lists
set -euo pipefail
d=${1:?usage: dev/manifest_check.sh <worktree>}
want=$(awk '/^\[extensions\]/ { f = 1; next } /^\[/ { f = 0 } f && NF { print $1 }' "$d/Project.toml" | sort | tr '\n' ' ')
have=$([ -f "$d/Manifest.toml" ] && awk '/^ *\[deps\.WasmTarget\.extensions\]/ { f = 1; next } /^ *\[/ { f = 0 } f && NF { print $1 }' "$d/Manifest.toml" | sort | tr '\n' ' ' || true)
[ "$want" = "$have" ] && exit 0
echo "Manifest.toml's WasmTarget extensions (${have:-none}) are not Project.toml's (${want:-none})"
exit 1
