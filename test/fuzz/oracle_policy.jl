# ============================================================================
# FROZEN ORACLE POLICY — the differential oracle's float-comparison tolerances.
# ============================================================================
# These constants define when a native and a wasm FLOAT result are considered to
# AGREE. They are deliberately isolated in this tiny file: widening a tolerance to
# bury a wrong-value divergence would be reward-hacking the oracle. Changing these
# is a deliberate, human-reviewed act, explained in its commit.
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
