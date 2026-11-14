#!/usr/bin/env bash
# Julia's own C and C++ sources the src/julia ports cite, at the commit of the julia WasmTarget runs
# (JULIA_PIN in src/julia/parity.jl, Julia 1.12.7; dev/LEDGER.md D45: nothing bespoke, a pinned near
# 1:1 match ported): a sparse checkout of the units JULIA_FILES names, at the one path WasmTarget
# reads, ~/.cache/wasmtarget/julia. Then the pins derived from it (D42, D45): the C library Julia
# links and Base ccalls, at the commit Julia's own deps/<lib>.version names at JULIA_PIN, read from
# the checkout, never typed: JuliaStrings/utf8proc at ~/.cache/wasmtarget/utf8proc.
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
# the sparse list is a function of the pin alone (A73E2): Julia's C and C++ sources (src/, with src/support and its other
# directories), Base's .jl files (base/) and the compiler's (Compiler/src/), whole, so any tree's JULIA_FILES finds every
# unit it names and no tree's list can take another's unit away; a tree whose script still writes a per-unit list
# (before 9743c109) shrinks it only until the next landing check runs this one (dev/check.sh, 110c2936). The units of
# JULIA_FILES are checked against the checkout by L213, never fetched one by one
# deps/utf8proc.version, the derived pin's commit (below), is read from the same checkout
{ cat .git/info/sparse-checkout 2>/dev/null; printf 'src/\nbase/\nCompiler/src/\ndeps/utf8proc.version\n'; } | sort -u > .git/info/sparse-checkout.new
mv .git/info/sparse-checkout.new .git/info/sparse-checkout
# a lost connection to github.com is retried: three tries, 10 s then 30 s apart, loud on the last
fetch_pin() {   # <repository> <commit>, in the current directory's checkout
  for try in 1 2 3; do
    git fetch -q --depth 1 --filter=blob:none origin "$2" && return 0
    [ $try -eq 3 ] && { echo "fetch_julia: could not fetch $1 at $2 after 3 tries" >&2; exit 1; }
    echo "fetch_julia: fetch of $1 failed (try $try of 3), retrying" >&2
    sleep $((try == 1 ? 10 : 30))
  done
}
if [ "$(git rev-parse HEAD 2>/dev/null)" = "$pin" ]; then
  git read-tree -mu HEAD
  echo "JuliaLang/julia at $pin: $dir"
else
  fetch_pin JuliaLang/julia "$pin"
  git checkout -q --force FETCH_HEAD
  echo "JuliaLang/julia at $pin: $dir (the units of JULIA_FILES)"
fi
# utf8proc, Julia's Unicode library (libjulia links it; Base.Unicode ccalls it): its commit is UTF8PROC_SHA1 in
# deps/utf8proc.version at JULIA_PIN, the line Julia's own build reads (deps/utf8proc.mk), and the resolver
# (src/julia/parity.jl _c_pin_checkout) reads the same line, so the checkout and the anchors agree by construction
u8=$(sed -n 's/^UTF8PROC_SHA1=\([0-9a-f]\{40\}\)$/\1/p' "$dir/deps/utf8proc.version")
[ -n "$u8" ] || { echo "fetch_julia: $dir/deps/utf8proc.version names no UTF8PROC_SHA1 at $pin" >&2; exit 1; }
udir=$HOME/.cache/wasmtarget/utf8proc
mkdir -p "$udir"
cd "$udir"
[ -d .git ] || git init -q
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/JuliaStrings/utf8proc.git
if [ "$(git rev-parse HEAD 2>/dev/null)" != "$u8" ]; then
  fetch_pin JuliaStrings/utf8proc "$u8"
  git checkout -q --force FETCH_HEAD
fi
echo "JuliaStrings/utf8proc at $u8 (deps/utf8proc.version at $pin): $udir"
