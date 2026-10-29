#!/usr/bin/env bash
# The llvm-project sources the stackifier's anchors cite, at the commit pinned in
# dev/PARITY_MASTER.md (the second oracle: LLVM's WebAssembly backend, where dart2wasm has no
# counterpart, D42): a sparse checkout of llvm/lib/Target/WebAssembly and the loop and dominator
# headers it rests on, at the one path WasmTarget reads, ~/.cache/wasmtarget/llvm-project.
#   bash dev/fetch_llvm.sh
# A directory that is already a checkout at the pinned commit takes the sparse list as it stands.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(grep -oE 'llvm/llvm-project \*\*`[0-9a-f]{40}' "$here/dev/PARITY_MASTER.md" | grep -oE '[0-9a-f]{40}')
dir=$HOME/.cache/wasmtarget/llvm-project
mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/llvm/llvm-project.git
git config core.sparseCheckout true
printf '%s\n' llvm/lib/Target/WebAssembly/ \
  llvm/include/llvm/CodeGen/MachineLoopInfo.h llvm/include/llvm/CodeGen/MachineDominators.h \
  llvm/include/llvm/Support/GenericLoopInfo.h llvm/include/llvm/Support/GenericLoopInfoImpl.h \
  llvm/include/llvm/Support/GenericDomTree.h llvm/lib/CodeGen/MachineBasicBlock.cpp \
  llvm/lib/CodeGen/PHIElimination.cpp llvm/include/llvm/Analysis/DominanceFrontier.h \
  llvm/include/llvm/Analysis/DominanceFrontierImpl.h llvm/include/llvm/CodeGen/MachineDominanceFrontier.h \
  > .git/info/sparse-checkout
# a checkout already at the pin takes the sparse list as it stands now, a file a port added included
if [ "$(git rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  git read-tree -mu HEAD
  echo "llvm/llvm-project at $pin: $dir"
  exit 0
fi
# a lost connection to github.com is retried: three tries, 10 s then 30 s apart, loud on the last
for try in 1 2 3; do
  git fetch -q --depth 1 --filter=blob:none origin "$pin" && break
  [ $try -eq 3 ] && { echo "fetch_llvm: could not fetch llvm/llvm-project at $pin after 3 tries" >&2; exit 1; }
  echo "fetch_llvm: fetch failed (try $try of 3), retrying" >&2
  sleep $((try == 1 ? 10 : 30))
done
git checkout -q --force FETCH_HEAD
echo "llvm/llvm-project at $pin: $dir (llvm/lib/Target/WebAssembly, the loop and dominator headers)"
