------------------------------ MODULE APFloatRound ------------------------------
(***************************************************************************)
(* A TLA+ model of the rounding LLVM's APFloat performs when it converts a *)
(* decimal or hexadecimal string to an IEEE binary float, read from the    *)
(* pinned llvm-project (7a941dfb), llvm/lib/Support/APFloat.cpp, written   *)
(* before WasmTarget's port of it (dev/LEDGER.md D11): round to nearest,   *)
(* ties to even, at the significand's precision boundary.                  *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. A finite value is a significand `sig` and an   *)
(* exponent `exp`, worth sig * 2^(exp - (precision - 1)); a normal one has *)
(* its most significant bit at bit precision - 1, a denormal has exp =     *)
(* minExponent and a narrower significand. A caller (the hex reader, which *)
(* fills the whole part and folds the digits past it into a lost fraction; *)
(* roundSignificandWithExponent, which extracts the top bits of a wider    *)
(* approximation) hands normalize a significand, an exponent and the       *)
(* lost fraction of the bits it already dropped.                           *)
(*   llvm/lib/Support/APFloat.cpp:580 lostFractionThroughTruncation: the   *)
(*     bits dropped are exactly zero, less than half, exactly half or more *)
(*     than half of the new last place, read from the lowest set bit and   *)
(*     the top dropped bit (a shift past the part is less than half).      *)
(*   APFloat.cpp:600 shiftRight / :1426 shiftSignificandRight: the shift,  *)
(*     its lost fraction, exp + bits.                                      *)
(*   APFloat.cpp:611 combineLostFractions: a nonzero less significant      *)
(*     fraction turns ExactlyZero into LessThanHalf and ExactlyHalf into   *)
(*     MoreThanHalf (the sticky bit).                                      *)
(*   APFloat.cpp:1522 IEEEFloat::roundAwayFromZero, rmNearestTiesToEven:   *)
(*     away on MoreThanHalf, or on ExactlyHalf when the kept lsb is 1      *)
(*     (inside normalize the category is fcNormal, so the zero test never  *)
(*     answers).                                                           *)
(*   APFloat.cpp:1560 IEEEFloat::normalize: exponentChange = omsb -        *)
(*     precision; past maxExponent handleOverflow (:1490, infinity under   *)
(*     the nearest modes); below minExponent the change is clamped so the  *)
(*     value is a denormal at minExponent; a negative change shifts left   *)
(*     (exact, asserted: no lost fraction); a positive one shifts right    *)
(*     and combines the lost fractions; then the increment on round-away,  *)
(*     a denormal rounding up taking exp = minExponent, and the carry      *)
(*     (omsb = precision + 1) that renormalises by exp + 1, or overflows   *)
(*     to infinity at maxExponent; a zero significand left is fcZero.      *)
(*   APFloat.cpp:2870 roundSignificandWithExponent's decision: an          *)
(*     approximation of the decimal value with excess precision, in error  *)
(*     by less than HUerr half-ulps (:632 HUerrBound), is truncated only   *)
(*     when HUdistance = 2 * ulpsFromBoundary (:646), its truncated bits'  *)
(*     distance from the half-way boundary, is at least HUerr; else the    *)
(*     loop retries at twice the parts.                                    *)
(*                                                                         *)
(* THE CLAIMS. RoundsCorrectly: for every input value N * 2^Q (N of W      *)
(* bits) and every caller truncation of its T low bits, normalize's result *)
(* is the correctly rounded value, computed independently by brute force   *)
(* over every representable value: the nearest; on a tie the one with an   *)
(* even significand; infinity where the nearest-even rule picks the value  *)
(* 2^(maxExponent + 1) past the largest finite (so a value at or past      *)
(* max + half an ulp overflows, IEEE 754 7.4); zero or a denormal below    *)
(* the normal range. NormalizeAsserts: normalize's assert holds on every  *)
(* input. Canonical: every finite result is a normal of                    *)
(* exactly precision bits in [minExponent, maxExponent] or a denormal at   *)
(* minExponent. ClingerOK: whenever HUdistance >= HUerr, truncating the    *)
(* approximation and rounding it rounds exactly as the true value does,    *)
(* for every true value within the error bound and every bound             *)
(* HUerrBound can return.                                                  *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. The precision is the constant P (double's    *)
(* 53), the exponent range EMin..EMax (double's -1022..1023), the integer  *)
(* part PW bits (64); the claims are about the shift, the lost fraction    *)
(* and the round, whose correctness does not depend on the widths. The     *)
(* inputs are the ones normalize's callers hand it: a caller that dropped *)
(* bits kept every place down to the result's last (CallerKeepsLastPlace:  *)
(* the hex reader's significand fills the part, wider than precision;      *)
(* roundSignificandWithExponent extracts exactly precision bits, or sets   *)
(* exp = minExponent for a denormal); NormalizeAsserts checks that such an *)
(* input meets normalize's assert (APFloat.cpp:1588) that a left shift     *)
(* carries no lost fraction. The sign is not modeled (rounding to          *)
(* nearest is symmetric). The nonFiniteBehavior/nanEncoding arms (the     *)
(* 8-bit formats with no infinity, or NaN as all ones) are not modeled:    *)
(* IEEE double and single take neither. ulpsFromBoundary is modeled at one *)
(* part (count = 0, its first arm), with its unsigned wrap at PW bits; the *)
(* multi-part arms and HUerrBound's own bound (Clinger's analysis of the   *)
(* multiply) are not checked here: ClingerOK assumes the bound and checks  *)
(* the decision built on it. The true value is checked on a grid of a      *)
(* quarter of the approximation's last place, which holds every boundary  *)
(* rounding reads. ClingerOK's scale assumes the approximation's excess    *)
(* bits E satisfy 2^E >= 2 * max HUerr (the true value then never crosses  *)
(* the half-way point of the binade below): LLVM's excess is at least 10   *)
(* bits for double (63 - 53), so its 2^10 is far past 14.                  *)
(*                                                                         *)
(* The Broken variants (Mode): "truncate" -- never round away (the         *)
(* rmTowardZero arm taken for nearest), rejected on RoundsCorrectly;       *)
(* "tiesaway" -- round away on ExactlyHalf whatever the lsb                *)
(* (rmNearestTiesToAway), rejected on RoundsCorrectly; "nocarry" -- no     *)
(* renormalise when the increment carries to precision + 1 bits, rejected  *)
(* on Canonical; "zeroboundary" -- ulpsFromBoundary measured from zero     *)
(* (isNearest false, the directed modes' boundary) under round to nearest, *)
(* rejected on ClingerOK.                                                  *)
(*                                                                         *)
(* No dart anchor: parity(quarantine: dart2wasm's double.parse calls the   *)
(* JS host's parseFloat, sdk/lib/_internal/wasm/js_common/                 *)
(* double_patch.dart:32; Julia's parse(Float64, ...) is jl_strtod_c over   *)
(* the C library's strtod, which WasmTarget ports from LLVM's APFloat).    *)
(***************************************************************************)
EXTENDS Naturals, Integers

CONSTANTS
    P,            \* precision in bits (double: 53)
    EMin, EMax,   \* minExponent, maxExponent (double: -1022, 1023)
    PW,           \* integerPartWidth (64); the significand is one part
    W,            \* the input significand's width in bits
    QMin, QMax,   \* the input's scale: a value N * 2^Q, Q in QMin..QMax
    E,            \* roundSignificandWithExponent's excess precision bits
    Mode          \* "even" (the code) | "truncate" | "tiesaway" | "nocarry" | "zeroboundary"

VARIABLE done
vars == <<done>>

ASSUME P >= 2 /\ EMin < 0 /\ EMax > 0 /\ W <= PW /\ E < PW /\ P + E <= PW
ASSUME EMin - (P - 1) >= QMin       \* every result is a whole number of 2^QMin
ASSUME Mode \in {"even", "truncate", "tiesaway", "nocarry", "zeroboundary"}

Abs(x) == IF x < 0 THEN -x ELSE x
Bit(n, i) == (n \div 2^i) % 2

\* significandMSB() + 1, numbered from 1 (0 for a zero significand): APFloat.cpp:1417
RECURSIVE Bits(_)
Bits(n) == IF n = 0 THEN 0 ELSE 1 + Bits(n \div 2)

\* APInt::tcLSB: the lowest set bit, "UINT_MAX" (any bit count is at most it) for zero
NoLsb == 2^30
RECURSIVE LsbFrom(_, _)
LsbFrom(n, i) == IF Bit(n, i) = 1 THEN i ELSE LsbFrom(n, i + 1)
Lsb(n) == IF n = 0 THEN NoLsb ELSE LsbFrom(n, 0)

LostFractions == {"zero", "less", "half", "more"}

\* APFloat.cpp:580 lostFractionThroughTruncation (one part of PW bits)
LostFrac(n, bits) ==
    LET lsb == Lsb(n)
    IN IF bits <= lsb THEN "zero"
       ELSE IF bits = lsb + 1 THEN "half"
       ELSE IF bits <= PW /\ Bit(n, bits - 1) = 1 THEN "more"
       ELSE "less"

\* APFloat.cpp:611 combineLostFractions
Combine(moreSignificant, lessSignificant) ==
    IF lessSignificant # "zero"
    THEN CASE moreSignificant = "zero" -> "less"
           [] moreSignificant = "half" -> "more"
           [] OTHER -> moreSignificant
    ELSE moreSignificant

\* APFloat.cpp:1522 IEEEFloat::roundAwayFromZero, at bit 0, for rmNearestTiesToEven (category fcNormal)
RoundAway(lf, sig) ==
    CASE Mode = "truncate" -> FALSE
      [] Mode = "tiesaway" -> lf \in {"half", "more"}
      [] OTHER -> lf = "more" \/ (lf = "half" /\ Bit(sig, 0) = 1)

Zero == [kind |-> "zero", sig |-> 0, exp |-> EMin]
Inf == [kind |-> "inf", sig |-> 0, exp |-> EMax + 1]
Fin(s, x) == [kind |-> "finite", sig |-> s, exp |-> x]

\* normalize's rounding, after its shift (APFloat.cpp:1620-1680)
RoundStep(sig, exp, lf, omsb) ==
    IF lf = "zero" THEN (IF omsb = 0 THEN Zero ELSE Fin(sig, exp))
    ELSE IF RoundAway(lf, sig)
    THEN LET exp2 == IF omsb = 0 THEN EMin ELSE exp      \* a denormal rounding up
             sig2 == sig + 1                             \* incrementSignificand
         IN IF Bits(sig2) = P + 1 /\ Mode # "nocarry"
            THEN IF exp2 = EMax THEN Inf                 \* handleOverflow
                 ELSE Fin(sig2 \div 2, exp2 + 1)         \* shiftSignificandRight(1)
            ELSE Fin(sig2, exp2)
    ELSE IF omsb = 0 THEN Zero ELSE Fin(sig, exp)        \* a denormal that underflowed to zero

\* APFloat.cpp:1560 IEEEFloat::normalize, for rmNearestTiesToEven
Normalize(sig0, exp0, lf0) ==
    LET omsb0 == Bits(sig0)
    IN IF omsb0 = 0 /\ lf0 = "zero" THEN Zero            \* exactly zero: canonicalised
       ELSE LET change0 == omsb0 - P
            IN IF exp0 + change0 > EMax THEN Inf         \* handleOverflow: infinity under nearest
               ELSE LET change == IF exp0 + change0 < EMin THEN EMin - exp0 ELSE change0
                    IN IF change < 0
                       THEN Fin(sig0 * 2^(-change), exp0 + change)   \* shiftSignificandLeft, exact
                       ELSE LET lf1 == IF change > 0 THEN Combine(LostFrac(sig0, change), lf0) ELSE lf0
                                omsb1 == IF omsb0 > change THEN omsb0 - change ELSE 0
                            IN RoundStep(sig0 \div 2^change, exp0 + change, lf1, omsb1)

\* the callers' contract: a caller that dropped bits kept every place down to the result's last:
\* at least P bits (the hex reader fills the whole part; roundSignificandWithExponent's tcExtract
\* keeps exactly P), or a last place at or below the smallest denormal's (exp <= minExponent:
\* roundSignificandWithExponent's denormal arm, its extract capped at the whole approximation)
CallerKeepsLastPlace(sig0, exp0, lf0) == lf0 # "zero" => (Bits(sig0) >= P \/ exp0 <= EMin)
\* normalize's assert (APFloat.cpp:1588): reached (not exactly zero, no overflow) with a left shift,
\* there is no lost fraction
AssertHolds(sig0, exp0, lf0) ==
    LET omsb0 == Bits(sig0)
        change0 == omsb0 - P
        change == IF exp0 + change0 < EMin THEN EMin - exp0 ELSE change0
    IN (~(omsb0 = 0 /\ lf0 = "zero") /\ exp0 + change0 <= EMax /\ change < 0) => lf0 = "zero"

\* ---- the inputs: N * 2^Q, its T low bits truncated by the caller with their lost fraction ----
Ns == 0..(2^W - 1)
Qs == QMin..QMax
Ts == 0..W
Sig0(n, t) == n \div 2^t
Exp0(q, t) == q + t + (P - 1)
Result(n, q, t) == Normalize(Sig0(n, t), Exp0(q, t), LostFrac(n, t))
Admits(n, q, t) == CallerKeepsLastPlace(Sig0(n, t), Exp0(q, t), LostFrac(n, t))

\* ---- the correctly rounded value, by brute force, in units of 2^QMin ----
NormalSigs == (2^(P - 1))..(2^P - 1)
Finites == {[v |-> m * 2^(x - (P - 1) - QMin), m |-> m] : m \in NormalSigs, x \in EMin..EMax}
           \cup {[v |-> m * 2^(EMin - (P - 1) - QMin), m |-> m] : m \in 0..(2^(P - 1) - 1)}
Over == [v |-> 2^(EMax + 1 - QMin), m |-> 2^(P - 1)]     \* stands for infinity: an even significand
Candidates == Finites \cup {Over}
Nearest(x, cs) ==
    LET best == {c \in cs : \A d \in cs : Abs(c.v - x) <= Abs(d.v - x)}
    IN IF \E c \in best : c.m % 2 = 0 THEN CHOOSE c \in best : c.m % 2 = 0 ELSE CHOOSE c \in best : TRUE
\* a value: <<"inf", 0>> or <<"finite", v>>
Expected(x) == LET c == Nearest(x, Candidates) IN IF c = Over THEN <<"inf", 0>> ELSE <<"finite", c.v>>
ValueOf(r) == CASE r.kind = "inf" -> <<"inf", 0>>
                [] r.kind = "zero" -> <<"finite", 0>>
                [] OTHER -> <<"finite", r.sig * 2^(r.exp - (P - 1) - QMin)>>

\* ---- roundSignificandWithExponent's decision (APFloat.cpp:2870) ----
\* APFloat.cpp:632 HUerrBound
HUerrBound(inexactMultiply, e1, e2) ==
    IF e1 + e2 = 0 THEN (IF inexactMultiply THEN 2 ELSE 0)
    ELSE (IF inexactMultiply THEN 1 ELSE 0) + 2 * (e1 + e2)
\* sigStatus != opOK is 0 or 1; powHUerr is 0 or 1 (exp >= 0) or 0 or 2 (exp < 0)
HUerrs == {HUerrBound(b, e1, e2) : b \in BOOLEAN, e1 \in 0..1, e2 \in 0..2}
MaxHUerr == 7
ASSUME \A h \in HUerrs : h <= MaxHUerr
ASSUME 2^E >= 2 * MaxHUerr

\* APFloat.cpp:646 ulpsFromBoundary, one part (count = 0), its subtractions unsigned at PW bits
UlpsFromBoundary(parts, bits, isNearest) ==
    LET b1 == bits - 1
        partBits == (b1 % PW) + 1
        part == parts % 2^partBits
        boundary == IF isNearest THEN 2^(partBits - 1) ELSE 0
        U(x) == x % 2^PW
    IN IF U(part - boundary) <= U(boundary - part) THEN U(part - boundary) ELSE U(boundary - part)

\* the approximation: P + E bits, its top bit set (the assert at APFloat.cpp:2924)
Approx == (2^(P + E - 1))..(2^(P + E) - 1)
HUdistance(a) == 2 * UlpsFromBoundary(a, E, Mode # "zeroboundary")
\* the true value, in quarters of the approximation's last place (a half-ulp is 2 of them):
\* strictly within HUerr half-ulps, or the approximation itself when HUerr is 0
Truths(a, h) == IF h = 0 THEN {4 * a} ELSE (4 * a - (2 * h - 1))..(4 * a + (2 * h - 1))
\* tcExtract of the top P bits, lostFractionThroughTruncation of the E below, the round
TruncRounded(a) ==
    LET sig == a \div 2^E
        up == IF LostFrac(a, E) # "zero" /\ RoundAway(LostFrac(a, E), sig) THEN 1 ELSE 0
    IN (sig + up) * 2^E * 4
\* every P-bit value near the approximation's binade, unbounded in exponent
Precise == {[v |-> m * 2^s, m |-> m] : m \in NormalSigs, s \in (E + 1)..(E + 3)}

RoundsCorrectly == done \in BOOLEAN /\
    \A n \in Ns, q \in Qs, t \in Ts : Admits(n, q, t) => ValueOf(Result(n, q, t)) = Expected(n * 2^(q - QMin))
NormalizeAsserts == done \in BOOLEAN /\
    \A n \in Ns, q \in Qs, t \in Ts : Admits(n, q, t) => AssertHolds(Sig0(n, t), Exp0(q, t), LostFrac(n, t))
Canonical == done \in BOOLEAN /\
    \A n \in Ns, q \in Qs, t \in Ts : Admits(n, q, t) =>
        LET r == Result(n, q, t)
        IN r.kind = "finite" =>
            /\ r.exp \in EMin..EMax
            /\ \/ Bits(r.sig) = P
               \/ r.exp = EMin /\ Bits(r.sig) \in 1..(P - 1)
ClingerOK == done \in BOOLEAN /\
    \A a \in Approx, h \in HUerrs : \A x \in Truths(a, h) :
        HUdistance(a) >= h => TruncRounded(a) = Nearest(x, Precise).v

Init == done = FALSE
Next == done' = TRUE
Spec == Init /\ [][Next]_vars

TypeOK == done \in BOOLEAN
=============================================================================
