#!/usr/bin/env bash
# The emission-diff check (dev/CHARTER.md C5, L190; test/emission_fingerprint.jl): every function
# body the head emits for a smoke case and the merge base does not must have been entered by a
# passing differential case (at function entry). The head's side is smoke on Julia 1.12 (`dev/lanes.sh
# --lane smoke` sets WT_EMISSION_DIR). The base's side is computed once per landed head: the full
# gate's run of a commit publishes its own smoke rows as that commit's base file, a long-retention
# artifact named by the key below; a run whose merge base no gate published fails, naming the
# key, until `bootstrap` publishes it. Only when src, ext or Project.toml differ from the merge
# base is there a base side at all (otherwise no body can differ).
#
#   bash dev/emission_diff.sh plan <dir>        # the plan (<dir>/plan.txt), and when the tree differs from the
#                                               # merge base: its cached base file (<dir>/base.tsv, fetched) and
#                                               # the cases that file lacks compiled by the base's src (<dir>/delta.tsv)
#   bash dev/emission_diff.sh merge <dir>       # the verdict over <dir>: smoke's parts and the plan's files
#   bash dev/emission_diff.sh publish <dir> <out>   # HEAD's base file from smoke's parts in <dir> (the full
#                                               # gate, after a green verdict); prints name=<artifact name>
#   bash dev/emission_diff.sh bootstrap [<rev>] # push <rev> to emission-base/<base>, where emission-base.yml
#                                               # publishes the base file of <rev>'s merge base
#   bash dev/emission_diff.sh bootstrap-part i/K <dir>   # (emission-base.yml) part i of K of every case on the base
#   bash dev/emission_diff.sh bootstrap-publish <dir> <out>   # (emission-base.yml) the base file from those parts
#
# The key: emission-fp-<sha>-<julia version>-<code>, <code> the hash of test/emission_fingerprint.jl
# and the runners' compile (test/utils.jl's _emission_compile), so a base file is read only by the
# fingerprinting that wrote it. The merge base is HEAD's with the march branch dev/land.sh lands on.
set -euo pipefail
cd "$(dirname "$0")/.."
march=$(sed -n 's/^MARCH=\${WT_MARCH_BRANCH:-\([^}]*\)}$/\1/p' dev/land.sh)
[ -n "$march" ] || { echo "emission_diff: dev/land.sh names no march branch" >&2; exit 2; }
code=$({ cat test/emission_fingerprint.jl; sed -n '/^function _emission_compile(/,/^end$/p' test/utils.jl; } | git hash-object --stdin | cut -c1-16)
key() { echo "emission-fp-$1-$2-$code"; }   # key <sha> <julia version>
merge_base() { git merge-base "${1:-HEAD}" "origin/$march" || { echo "emission_diff: no merge base with origin/$march" >&2; exit 2; }; }
differs() { ! git diff --quiet "$1" "${2:-HEAD}" -- src ext Project.toml; }
# the merge base's package with the head's tests (the cases, their runners and this check)
base_tree() {
  local tree; tree=$(mktemp -d)
  git archive "$1" | tar -x -C "$tree"
  rm -rf "$tree/test"; cp -R test "$tree/test"
  [ -f Manifest.toml ] && cp Manifest.toml "$tree/"
  # the gate's preferences (the workload off, ci_depot.sh): the base precompiles as the head does
  [ -f LocalPreferences.toml ] && cp LocalPreferences.toml "$tree/"
  ( cd "$tree" && JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=. -e 'using Pkg; Pkg.instantiate()' >&2 )
  echo "$tree"
}
run_in() {  # run_in <tree> <julia expression after `include("test/smoke.jl")`>
  ( cd "$1" && julia --project=. -e "include(\"test/smoke.jl\"); $2" )
}
compile='(f, ts) -> _emission_compile(f, ts; optimize=false)'
case "${1:-}" in
plan)
  dir=${2:?dir}; mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
  base=$(merge_base)
  if differs "$base"; then changed=true; else changed=false; fi
  printf 'base=%s\nchanged=%s\n' "$base" "$changed" | tee "$dir/plan.txt"
  [ "$changed" = true ] || exit 0
  name=$(key "$base" "$(julia --startup-file=no -e 'print(VERSION)')")
  echo "key=$name" | tee -a "$dir/plan.txt"
  id=$(gh api "repos/{owner}/{repo}/actions/artifacts?name=$name&per_page=100" \
         --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .id // empty')
  [ -n "$id" ] || { echo "emission_diff: no base file for the merge base $base: no artifact $name. A full gate's run of $base publishes it; for a base no gate published, run \`bash dev/emission_diff.sh bootstrap\`" >&2; exit 1; }
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
  rev=$(git rev-parse --verify "${2:-HEAD}^{commit}")
  git fetch -q origin "$march"
  base=$(merge_base "$rev")
  branch="emission-base/${base:0:12}-${rev:0:8}"
  git push -q --force origin "$rev:refs/heads/$branch"
  echo "emission_diff: emission-base.yml publishes the base file of $base on $branch: gh run list --branch $branch"
  ;;
bootstrap-part)
  part=${2:?part i/K}; dir=${3:?dir}; mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
  base=$(merge_base)
  tree=$(base_tree "$base")
  run_in "$tree" "EmissionFingerprint.bootstrap_main(\"$part\", \"$dir\", \"$base\"; groups=GROUPS, compile=$compile)"
  ;;
bootstrap-publish)
  dir=${2:?dir}; out=${3:?out}; mkdir -p "$out"
  base=$(merge_base)
  julia --startup-file=no -e "include(\"test/emission_fingerprint.jl\"); EmissionFingerprint.publish_main(\"$dir\", \"$out/base.tsv\", \"$base\")"
  echo "name=$(key "$base" "$(head -1 "$out/base.tsv" | cut -f3)")"
  ;;
*)
  echo "usage: dev/emission_diff.sh plan <dir> | merge <dir> | publish <dir> <out> | bootstrap [<rev>] | bootstrap-part i/K <dir> | bootstrap-publish <dir> <out>" >&2; exit 2 ;;
esac
