#!/usr/bin/env bash
# Dynamic blast-radius probe for the cleanup loop.
# Runs the wide probe corpus once per setting (baseline + each fix_* neutralized + all),
# in a FRESH Julia subprocess each time (clean WT_NEUTRALIZE env, no compile-cache carry),
# then diffs each neutralized digest vs baseline → per-pass blast radius.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
PASSES=(array_len_wrap i32_wrap_after_i32_ops i64_local_in_i32_ops consecutive_local_sets \
        local_get_set_type_mismatch broken_select_instructions numeric_to_ref_local_stores)

run() { # $1=label  $2=WT_NEUTRALIZE value ("" for baseline)
  WT_NEUTRALIZE="$2" julia --project=. test/fuzz/cleanup_probe_corpus.jl > "$OUT/$1.txt" 2>"$OUT/$1.err" \
    || { echo "RUN FAILED: $1"; cat "$OUT/$1.err"; }
}

echo "baseline..."; run baseline ""
for p in "${PASSES[@]}"; do echo "neutralize $p..."; run "$p" "$p"; done
echo "all..."; run all "all"

echo ""
echo "================ DYNAMIC BLAST-RADIUS REPORT ================"
echo "corpus functions: $(wc -l < "$OUT/baseline.txt")"
echo "baseline ERRs: $(grep -c ' ERR ' "$OUT/baseline.txt" || true)"
echo ""
for label in "${PASSES[@]}" all; do
  f="$OUT/$label.txt"
  [ -f "$f" ] || { echo "## $label : (no output)"; continue; }
  # functions whose digest line differs from baseline
  changed=$(diff <(cut -d' ' -f1,3 "$OUT/baseline.txt") <(cut -d' ' -f1,3 "$f") | grep '^>' | awk '{print $2}' | sort -u || true)
  # functions that newly ERR under neutralization (were ok at baseline)
  newerr=$(comm -13 <(grep ' ERR ' "$OUT/baseline.txt" | awk '{print $1}' | sort) \
                    <(grep ' ERR ' "$f" | awk '{print $1}' | sort) || true)
  nchanged=$(echo -n "$changed" | grep -c . || true)
  nnewerr=$(echo -n "$newerr" | grep -c . || true)
  echo "## $label"
  echo "   changed bytes: $nchanged    newly-INVALID: $nnewerr"
  [ "$nchanged" -gt 0 ] && echo "   changed: $(echo $changed | tr '\n' ' ')"
  [ "$nnewerr" -gt 0 ]  && echo "   INVALID: $(echo $newerr | tr '\n' ' ')"
  echo ""
done
echo "digests in: $OUT"
echo "============================================================"
