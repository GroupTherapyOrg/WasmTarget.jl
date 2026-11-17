#!/usr/bin/env bash
# The dart-lang/sdk sources the anchors cite, at the commit pinned in dev/PARITY_MASTER.md, for
# L213 (every anchor resolves at the pin): a sparse checkout of pkg/dart2wasm/lib and
# pkg/wasm_builder/lib, the two directories src/julia/parity.jl's pin table draws from, at the one
# path WasmTarget reads, ~/.cache/wasmtarget/dart-sdk.
#   bash dev/fetch_dart_sdk.sh
# A directory that is already a checkout at the pinned commit (a full clone, or a symlink to one)
# is used as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(grep -oE '[0-9a-f]{40}' "$here/dev/PARITY_MASTER.md" | head -1)
dir=$HOME/.cache/wasmtarget/dart-sdk
if [ -e "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  echo "dart-lang/sdk at $pin: $dir"
  exit 0
fi
mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/dart-lang/sdk.git
git config core.sparseCheckout true
printf '%s\n' pkg/dart2wasm/lib/ pkg/wasm_builder/lib/ > .git/info/sparse-checkout
# a lost connection to github.com is retried: three tries, 10 s then 30 s apart, loud on the last
for try in 1 2 3; do
  git fetch -q --depth 1 --filter=blob:none origin "$pin" && break
  [ $try -eq 3 ] && { echo "fetch_dart_sdk: could not fetch dart-lang/sdk at $pin after 3 tries" >&2; exit 1; }
  echo "fetch_dart_sdk: fetch failed (try $try of 3), retrying" >&2
  sleep $((try == 1 ? 10 : 30))
done
git checkout -q --force FETCH_HEAD
echo "dart-lang/sdk at $pin: $dir (pkg/dart2wasm/lib, pkg/wasm_builder/lib)"
