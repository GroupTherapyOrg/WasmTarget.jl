#!/usr/bin/env bash
# The dart-lang/sdk sources the anchors cite, at the commit pinned in dev/PARITY_MASTER.md, for
# L213 (every anchor resolves at the pin): the whole tree at that commit, at the one path WasmTarget
# reads, ~/.cache/wasmtarget/dart-sdk. Whole, never a sparse list: a dart anchor, a reason's path
# citation and a dart precedent each name any file under the checkout's pkg/ or sdk/
# (src/julia/parity.jl parse_anchor, REASON_PATH_RX, _reason_unpinned), far beyond the pin tables
# (pkg/kernel, pkg/analyzer, pkg/front_end, pkg/js_ast, pkg/vm, sdk/lib/_internal/wasm, sdk/lib/_wasm, ...),
# so a list kept here would be a second copy of what src cites and a load on its checkout alone
# refuses the anchor it lacks; the whole tree is what the full clone of every other host holds.
#   bash dev/fetch_dart_sdk.sh
# A directory that is already a checkout at the pinned commit (a full clone, or a symlink to one)
# is used as it is; one an older script left sparse is made whole first.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(grep -oE '[0-9a-f]{40}' "$here/dev/PARITY_MASTER.md" | head -1)
dir=$HOME/.cache/wasmtarget/dart-sdk
if [ -e "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  if [ "$(git -C "$dir" config --get core.sparseCheckout || true)" = true ]; then
    git -C "$dir" sparse-checkout disable
    echo "dart-lang/sdk at $pin: $dir (its sparse list dropped: the whole tree)"
  fi
  echo "dart-lang/sdk at $pin: $dir"
  exit 0
fi
mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/dart-lang/sdk.git
# a directory an older script left sparse, not yet at the pin: the whole tree from here on
git config core.sparseCheckout false
# a lost connection to github.com is retried: three tries, 10 s then 30 s apart, loud on the last
for try in 1 2 3; do
  git fetch -q --depth 1 --filter=blob:none origin "$pin" && break
  [ $try -eq 3 ] && { echo "fetch_dart_sdk: could not fetch dart-lang/sdk at $pin after 3 tries" >&2; exit 1; }
  echo "fetch_dart_sdk: fetch failed (try $try of 3), retrying" >&2
  sleep $((try == 1 ? 10 : 30))
done
git checkout -q --force FETCH_HEAD
echo "dart-lang/sdk at $pin: $dir (the whole tree)"
