# ============================================================================
# FROZEN ORACLE POLICY — the differential oracle's float-comparison tolerances.
# ============================================================================
# These constants define when a native and a wasm FLOAT result are considered to
# AGREE. They are deliberately isolated in this tiny file and HASH-PINNED
# (`oracle_policy.jl.sha256`, checked by `loop_guard.sh`) so the autonomous
# soundness /loop cannot silently WIDEN tolerance to bury a wrong-value
# divergence — that would be reward-hacking the oracle (see test/fuzz/LOOP.md §3).
#
# Changing these is a HUMAN-ONLY, deliberate act: edit the value, then re-pin with
#   shasum -a 256 test/fuzz/oracle_policy.jl > test/fuzz/oracle_policy.jl.sha256
# and explain why in the commit. The loop itself must never touch this file.
#
# Values: integers / bools / strings / chars must match EXACTLY (no tolerance —
# enforced in `vals_match`). Floats match on NaN==NaN, signed-Inf, exact
# equality, or ULP-tolerant `isapprox` with these bounds — wasm's libm differs
# from openlibm for transcendentals, so a small nonzero rtol is required to avoid
# false divergences, while staying tight enough to catch real wrong-value bugs.
module FuzzOraclePolicy

export ORACLE_RTOL, ORACLE_ATOL

const ORACLE_RTOL = 1e-9
const ORACLE_ATOL = 1e-12

end # module FuzzOraclePolicy
