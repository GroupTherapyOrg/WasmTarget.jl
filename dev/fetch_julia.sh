#!/usr/bin/env bash
# Julia's own C and C++ sources the src/julia ports cite, at the commit of the julia WasmTarget runs
# (JULIA_PIN in src/julia/parity.jl, Julia 1.12.7; dev/LEDGER.md D45: nothing bespoke, a pinned near
# 1:1 match ported): a sparse checkout of the units JULIA_FILES names, at the one path WasmTarget
# reads, ~/.cache/wasmtarget/julia.
#   bash dev/fetch_julia.sh
# A directory that is already a checkout at the pinned commit takes the sparse list as it stands.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pin=$(grep -oE 'const JULIA_PIN::String = "[0-9a-f]{40}"' "$here/src/julia/parity.jl" | grep -oE '[0-9a-f]{40}')
dir=$HOME/.cache/wasmtarget/julia
mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/JuliaLang/julia.git
git config core.sparseCheckout true
# each unit of JULIA_FILES ("julia/src/<name>"), its .h, .c and .cpp
grep -oE '"julia/src/[A-Za-z0-9_]+"' "$here/src/julia/parity.jl" | tr -d '"' | sed 's|^julia/||' |
  while read -r u; do printf '%s.h\n%s.c\n%s.cpp\n' "$u" "$u" "$u"; done > .git/info/sparse-checkout
if [ "$(git rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  git read-tree -mu HEAD
  echo "JuliaLang/julia at $pin: $dir"
  exit 0
fi
# a lost connection to github.com is retried: three tries, 10 s then 30 s apart, loud on the last
for try in 1 2 3; do
  git fetch -q --depth 1 --filter=blob:none origin "$pin" && break
  [ $try -eq 3 ] && { echo "fetch_julia: could not fetch JuliaLang/julia at $pin after 3 tries" >&2; exit 1; }
  echo "fetch_julia: fetch failed (try $try of 3), retrying" >&2
  sleep $((try == 1 ? 10 : 30))
done
git checkout -q --force FETCH_HEAD
echo "JuliaLang/julia at $pin: $dir (the units of JULIA_FILES)"
