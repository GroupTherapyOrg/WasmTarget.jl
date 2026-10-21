#!/usr/bin/env bash
# The emission-diff check (dev/CHARTER.md C5, L190; test/emission_fingerprint.jl): every function
# body the head emits for a smoke case and the merge base does not must have been entered by a
# passing differential case (at function entry). The head's side is smoke on Julia 1.12 (`dev/lanes.sh
# --lane smoke` sets WT_EMISSION_DIR). It runs in gate.yml's matrix alone, non-blocking: on every
# landed head (its march/** push) and on a `bash dev/gate.sh` run, never in a landing's gate. The
# base's side is computed once per landed head: gate.yml's run of a commit publishes its own smoke
# rows as that commit's base file, a long-retention artifact named by the key below; a run whose
# base no run published fails, naming the key, until `bootstrap <base>` publishes it. Only when
# src, ext or Project.toml differ from the base is there a base side at all (otherwise no body can
# differ).
#
#   bash dev/emission_diff.sh plan <dir>        # the plan (<dir>/plan.txt), and when the tree differs from the
#                                               # base: its cached base file (<dir>/base.tsv, fetched) and
#                                               # the cases that file lacks compiled by the base's src (<dir>/delta.tsv)
#   bash dev/emission_diff.sh merge <dir>       # the verdict over <dir>: smoke's parts and the plan's files
#   bash dev/emission_diff.sh publish <dir> <out>   # HEAD's base file from smoke's parts in <dir> (the full
#                                               # gate, after a green verdict); prints name=<artifact name>
#   bash dev/emission_diff.sh bootstrap <base>  # push an unattached commit, this checkout's tree with <base>
#                                               # as its parent, to emission-base/<base>-<commit>, where
#                                               # emission-base.yml publishes <base>'s file under this
#                                               # checkout's tests (so its key): run it from the head whose
#                                               # matrix needs the file
#   bash dev/emission_diff.sh bootstrap-part i/K <dir>   # (emission-base.yml) part i of K of every case on the base
#   bash dev/emission_diff.sh bootstrap-publish <dir> <out>   # (emission-base.yml) the base file from those parts
#
# The key: emission-fp-<sha>-<julia version>-<code>, <code> the hash of test/emission_fingerprint.jl
# and the runners' compile (test/utils.jl's _emission_compile), so a base file is read only by the
# fingerprinting that wrote it. The base is HEAD's merge base with the march branch dev/land.sh
# lands on; for a landed head, which is its own merge base, the base is the nearest landed head
# before it: its nearest first-parent ancestor with a published base file (among 50; none fails,
# naming the parent's key).
set -euo pipefail
cd "$(dirname "$0")/.."
march=$(sed -n 's/^MARCH=\${WT_MARCH_BRANCH:-\([^}]*\)}$/\1/p' dev/land.sh)
[ -n "$march" ] || { echo "emission_diff: dev/land.sh names no march branch" >&2; exit 2; }
code=$({ cat test/emission_fingerprint.jl; sed -n '/^function _emission_compile(/,/^end$/p' test/utils.jl; } | git hash-object --stdin | cut -c1-16)
key() { echo "emission-fp-$1-$2-$code"; }   # key <sha> <julia version>
# the newest unexpired artifact of that name, or nothing
artifact() { gh api "repos/{owner}/{repo}/actions/artifacts?name=$1&per_page=100" \
               --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .id // empty'; }
merge_base() { git merge-base "${1:-HEAD}" "origin/$march" || { echo "emission_diff: no merge base with origin/$march" >&2; exit 2; }; }
differs() { ! git diff --quiet "$1" "${2:-HEAD}" -- src ext Project.toml; }
# the merge base's package with the head's tests (the cases, their runners and this check)
base_tree() {
  local tree; tree=$(mktemp -d)
  git archive "$1" | tar -x -C "$tree"
  rm -rf "$tree/test"; cp -R test "$tree/test"
  [ -f Manifest.toml ] && cp Manifest.toml "$tree/"
  ( cd "$tree" && JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.instantiate()' >&2 )
  echo "$tree"
}
compile='(f, ts) -> _emission_compile(f, ts; optimize=false)'
case "${1:-}" in
plan)
  dir=${2:?dir}; mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
  base=$(merge_base)
  ver=$(julia --startup-file=no -e 'print(VERSION)')
  # a landed head is its own merge base: its base is the nearest landed head before it, the
  # nearest first-parent ancestor whose base file a run published
  if [ "$base" = "$(git rev-parse HEAD)" ]; then
    base=""
    for c in $(git rev-list --first-parent --max-count=50 HEAD^); do
      [ -n "$(artifact "$(key "$c" "$ver")")" ] && { base=$c; break; }
    done
    [ -n "$base" ] || { echo "emission_diff: no base file for the landed head's 50 first-parent ancestors: no artifact $(key "$(git rev-parse HEAD^)" "$ver"). gate.yml's green run of a landed head publishes it; for one no run published, run \`bash dev/emission_diff.sh bootstrap $(git rev-parse HEAD^)\` from a checkout of $(git rev-parse HEAD)" >&2; exit 1; }
  fi
  if differs "$base"; then changed=true; else changed=false; fi
  printf 'base=%s\nchanged=%s\n' "$base" "$changed" | tee "$dir/plan.txt"
  [ "$changed" = true ] || exit 0
  name=$(key "$base" "$ver")
  echo "key=$name" | tee -a "$dir/plan.txt"
  id=$(artifact "$name")
  [ -n "$id" ] || { echo "emission_diff: no base file for the base $base: no artifact $name. gate.yml's green run of $base publishes it; for a base no run published, run \`bash dev/emission_diff.sh bootstrap $base\` from a checkout of $(git rev-parse HEAD)" >&2; exit 1; }
  gh api "repos/{owner}/{repo}/actions/artifacts/$id/zip" > "$dir/base.zip"
  ( cd "$dir" && unzip -o -q base.zip && rm base.zip )
  [ -f "$dir/base.tsv" ] || { echo "emission_diff: artifact $name holds no base.tsv" >&2; exit 1; }
  tree=$(base_tree "$base")
  # The head's tests may not load over the base's src (a case generator asks a definition the head
  # adds): then no case compiles on the base, the delta holds the load error alone, and the head's
  # bodies are compared with the cached file's alone, which can only add bodies the base does not
  # emit (stricter, never weaker)
  ( cd "$tree" && julia --project=. -e "
    err = try; include(\"test/smoke.jl\"); nothing; catch e; e; end
    err === nothing && (err = try; _build!(collect(keys(LAZY_FILE))); nothing; catch e; e; end)
    if err === nothing
        EmissionFingerprint.delta_main(\"$dir/delta.tsv\", \"$base\", \"$dir/base.tsv\"; groups=GROUPS, compile=$compile)
    else
        msg = replace(first(sprint(showerror, err), 300), r\"\\s+\" => \" \")
        write(\"$dir/delta.tsv\", \"base\\t$base\\t\$VERSION\\nF\\t(the head's tests over the base's src)\\t\$msg\\n\")
        println(\"emission base delta at $base: the head's tests do not load over the base's src: \$msg; no case compiled on the base\")
    end" )
  ;;
merge)
  dir=${2:?dir}
  changed=$(sed -n 's/^changed=//p' "$dir/plan.txt")
  [ "$changed" = true ] || [ "$changed" = false ] || { echo "emission_diff: $dir/plan.txt names no plan" >&2; exit 2; }
  julia --startup-file=no -e "include(\"test/emission_fingerprint.jl\"); EmissionFingerprint.merge_main(\"$dir\", $([ "$changed" = true ] && echo false || echo true))"
  ;;
publish)
  dir=${2:?dir}; out=${3:?out}; mkdir -p "$out"
  sha=$(git rev-parse HEAD)
  julia --startup-file=no -e "include(\"test/emission_fingerprint.jl\"); EmissionFingerprint.publish_main(\"$dir\", \"$out/base.tsv\", \"$sha\")"
  echo "name=$(key "$sha" "$(head -1 "$out/base.tsv" | cut -f3)")"
  ;;
bootstrap)
  base=$(git rev-parse --verify "${2:?usage: dev/emission_diff.sh bootstrap <base>}^{commit}")
  git fetch -q origin "$march"
  git merge-base --is-ancestor "$base" "origin/$march" || { echo "emission_diff: $base is not on origin/$march" >&2; exit 2; }
  # the commit emission-base.yml runs: this checkout's tree (its workflow, its tests and its
  # fingerprinting, which make the key) with <base> as its one parent, so its merge base with the
  # march branch is <base>; it is on no branch but its own emission-base/ one
  shim=$(git commit-tree "HEAD^{tree}" -p "$base" -m "emission base bootstrap: the base file of $base under the tests of $(git rev-parse HEAD)")
  [ "$(merge_base "$shim")" = "$base" ] || { echo "emission_diff: the bootstrap commit's merge base is not $base" >&2; exit 2; }
  branch="emission-base/${base:0:12}-${shim:0:8}"
  git push -q --force origin "$shim:refs/heads/$branch"
  echo "emission_diff: emission-base.yml publishes the base file of $base on $branch: gh run list --branch $branch"
  ;;
bootstrap-part)
  part=${2:?part i/K}; dir=${3:?dir}; mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
  base=$(merge_base)
  tree=$(base_tree "$base")
  # The plan's rule: the head's tests may not load over the base's src, or not build their lazy
  # groups (a generator asking a definition the head adds); those cases are then left out of the
  # part, an F line naming why, and the rest compiled. A head body the base file lacks must have
  # been entered by a passing case, so a base file with fewer cases is stricter, never weaker, and
  # one is always published
  ( cd "$tree" && julia --project=. -e "
    m = match(r\"^([0-9]+)/([0-9]+)\$\", \"$part\")
    why(e) = replace(first(sprint(showerror, e), 300), r\"\\s+\" => \" \")
    err = try; include(\"test/smoke.jl\"); nothing; catch e; e; end
    lazy = err === nothing ? (try; _build!(collect(keys(LAZY_FILE))); nothing; catch e; e; end) : nothing
    if err === nothing
        EmissionFingerprint.bootstrap_main(\"$part\", \"$dir\", \"$base\"; groups=GROUPS, compile=$compile)
        lazy === nothing || open(io -> println(io, \"F\\t(the head's lazy groups over the base's src)\\t\", why(lazy)),
                                 \"$dir/base-\$(m[1])-of-\$(m[2]).tsv\", \"a\")
    else
        write(\"$dir/base-\$(m[1])-of-\$(m[2]).tsv\", \"bpart\\t$base\\t\$(m[1])\\t\$(m[2])\\t\$VERSION\\nF\\t(the head's tests over the base's src)\\t\$(why(err))\\n\")
    end" )
  ;;
bootstrap-publish)
  dir=${2:?dir}; out=${3:?out}; mkdir -p "$out"
  base=$(merge_base)
  julia --startup-file=no -e "include(\"test/emission_fingerprint.jl\"); EmissionFingerprint.publish_main(\"$dir\", \"$out/base.tsv\", \"$base\")"
  echo "name=$(key "$base" "$(head -1 "$out/base.tsv" | cut -f3)")"
  ;;
*)
  echo "usage: dev/emission_diff.sh plan <dir> | merge <dir> | publish <dir> <out> | bootstrap <base> | bootstrap-part i/K <dir> | bootstrap-publish <dir> <out>" >&2; exit 2 ;;
esac
