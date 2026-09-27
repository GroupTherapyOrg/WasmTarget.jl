#!/usr/bin/env bash
# The dart-lang/sdk files src/ cites, at the commit pinned in dev/PARITY_MASTER.md, for
# L132 (every parity anchor resolves). A sparse checkout of exactly the cited files: the list
# is derived from the anchors themselves, so a new anchor needs no edit here.
#   bash dev/fetch_dart_sdk.sh [dir]   dir defaults to $WT_DART_SDK, else
#                                      ~/.cache/wasmtarget/dart-sdk (where L132 looks)
# A directory that is already a checkout at the pinned commit (a full clone, or a symlink to
# one) is used as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(grep -oE '[0-9a-f]{40}' "$here/dev/PARITY_MASTER.md" | head -1)
dir=${1:-${WT_DART_SDK:-$HOME/.cache/wasmtarget/dart-sdk}}
if [ -e "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  echo "dart-lang/sdk at $pin: $dir"
  exit 0
fi
# a cited path is relative to pkg/dart2wasm/lib unless it names its package or sdk/lib
paths=$(grep -rhoE 'parity(-region)?\([A-Za-z0-9_/.-]+\.dart:' "$here/src" |
  sed -E 's/^parity(-region)?\(//; s/:$//' | sort -u |
  while read -r p; do
    if [[ $p == pkg/* || $p == sdk/* ]]; then echo "$p"; else echo "pkg/dart2wasm/lib/$p"; fi
  done)
mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/dart-lang/sdk.git
git config core.sparseCheckout true
printf '%s\n' $paths > .git/info/sparse-checkout
git fetch -q --depth 1 --filter=blob:none origin "$pin"
git checkout -q --force FETCH_HEAD
echo "dart-lang/sdk at $pin: $dir ($(printf '%s\n' $paths | wc -l | tr -d ' ') cited files)"
