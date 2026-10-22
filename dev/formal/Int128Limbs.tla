------------------------------ MODULE Int128Limbs ------------------------------
(***************************************************************************)
(* A TLA+ model of WasmTarget's Int128/UInt128 arithmetic over two i64     *)
(* limbs (src/codegen/int128.jl): every limb algorithm the emitters build, *)
(* checked against integer arithmetic for EVERY operand pair.              *)
(*                                                                         *)
(* WHAT THE REAL CODE DOES. A 128-bit value is a struct {classId, lo, hi}; *)
(* each `*_int` intrinsic on it becomes a sequence of i64 instructions     *)
(* over the two limbs: carry and borrow by unsigned compare (add, sub),    *)
(* Knuth's Algorithm M on 32-bit halves for the low limbs' carry (mul),    *)
(* two's complement with a carry (neg), limb-wise compares, shifts that    *)
(* move a cross term between the limbs, bit counts by limb, and division   *)
(* by one runtime helper: a one-limb fast path, else restoring long        *)
(* division over the 128 bits. Signed division runs on magnitudes.         *)
(*                                                                         *)
(* THE CLAIM. Each algorithm computes Julia's intrinsic exactly: the       *)
(* result modulo 2^128, the shift intrinsics' out-of-range rule (an amount *)
(* at least the width gives 0, or the sign for ashr: intrinsics.cpp        *)
(* selects on `shift >= width`), truncating signed division with the       *)
(* remainder taking the dividend's sign, and the DivideError conditions of *)
(* checked_{s,u}{div,rem}_int.                                             *)
(*                                                                         *)
(* WHAT THIS MODEL ABSTRACTS. The limb width is the constant K (the real   *)
(* code's 64), so an integer is 2K bits; the checked claims are about the  *)
(* limb algorithms, whose correctness does not depend on the width beyond  *)
(* K being even (Algorithm M splits a limb into halves). Each i64          *)
(* instruction is modeled at K bits with wasm's semantics: arithmetic      *)
(* modulo 2^K, a shift amount taken modulo K, unsigned and signed          *)
(* compares, clz/ctz/popcnt, div_u/rem_u. A shift amount is one limb, as   *)
(* in the real code (an i64), so amounts past the full width are covered.  *)
(* The struct and its classId are not modeled: they carry no arithmetic.  *)
(*                                                                         *)
(* The Broken variants: MaskedShift -- the shift emitters as they were     *)
(* until 2026-09-28, which masked the amount to the limb and never treated *)
(* an amount of at least 128 (`Core.Intrinsics.shl_int(Int128(1), 130)`    *)
(* answered 2^66); SignedCompare -- long division that tests the remainder *)
(* against the divisor with the signed compare, wrong for a divisor of     *)
(* 2^127 or more.                                                          *)
(*                                                                         *)
(* formal(src/codegen/int128.jl emit_int128_divrem!): the limb algorithms  *)
(* compute Julia's 128-bit intrinsics exactly for every operand.           *)
(*                                                                         *)
(* No dart anchor: parity(quarantine: dart's int is one i64; Int128 and    *)
(* UInt128 are Julia's, lowered over two i64 limbs).                       *)
(***************************************************************************)
EXTENDS Naturals, Integers

CONSTANTS
    K,            \* limb width in bits (the real code's 64); even
    MaskedShift,   \* BOOLEAN: TRUE = the broken shift emitters
    SignedCompare  \* BOOLEAN: TRUE = long division comparing the remainder signed

VARIABLE done
vars == <<done>>

B == 2^K                 \* a limb's modulus
W == 2 * K               \* the integer's width
M == 2^W                 \* the integer's modulus
HK == K \div 2           \* a half-limb's width (Algorithm M)
H == 2^HK
Limb == 0..(B - 1)
Nums == 0..(M - 1)

ASSUME K % 2 = 0 /\ K >= 2
ASSUME (-3) \div 2 = -2 /\ (-3) % 2 = 1          \* floor division, as ashr needs

\* ---- the i64 instructions, at K bits ----
RECURSIVE BitOp(_, _, _, _)
BitOp(op, a, b, n) ==
    IF n = 0 THEN 0
    ELSE LET x == a % 2
             y == b % 2
             z == CASE op = "and" -> (IF x = 1 /\ y = 1 THEN 1 ELSE 0)
                    [] op = "or"  -> (IF x = 1 \/ y = 1 THEN 1 ELSE 0)
                    [] op = "xor" -> (IF x # y THEN 1 ELSE 0)
         IN z + 2 * BitOp(op, a \div 2, b \div 2, n - 1)
And64(a, b) == BitOp("and", a, b, K)
Or64(a, b)  == BitOp("or", a, b, K)
Xor64(a, b) == BitOp("xor", a, b, K)
Not64(a)    == B - 1 - a
Add64(a, b) == (a + b) % B
Sub64(a, b) == (a - b) % B
Mul64(a, b) == (a * b) % B
S64(a) == IF a >= B \div 2 THEN a - B ELSE a
Shl64(a, s)  == (a * 2^(s % K)) % B
ShrU64(a, s) == a \div 2^(s % K)
ShrS64(a, s) == (S64(a) \div 2^(s % K)) % B
RECURSIVE Clz(_, _)
Clz(a, n) == IF n = 0 THEN 0 ELSE IF a \div 2^(n - 1) % 2 = 1 THEN 0 ELSE 1 + Clz(a, n - 1)
RECURSIVE Ctz(_, _, _)
Ctz(a, i, n) == IF i = n THEN n ELSE IF (a \div 2^i) % 2 = 1 THEN i ELSE Ctz(a, i + 1, n)
RECURSIVE Pop(_, _)
Pop(a, n) == IF n = 0 THEN 0 ELSE (a % 2) + Pop(a \div 2, n - 1)
Clz64(a) == Clz(a, K)
Ctz64(a) == Ctz(a, 0, K)

\* ---- a 128-bit value as two limbs ----
Lo(x) == x % B
Hi(x) == x \div B
Join(lo, hi) == hi * B + lo
S128(x) == IF x >= M \div 2 THEN x - M ELSE x
U128(v) == v % M
Abs(v) == IF v < 0 THEN -v ELSE v

\* ---- the emitters (int128.jl), step for step ----
Add128(a, b) ==   \* emit_int128_add!
    LET lo == Add64(Lo(a), Lo(b))
        carry == IF lo < Lo(a) THEN 1 ELSE 0
    IN Join(lo, Add64(Add64(carry, Hi(a)), Hi(b)))

Sub128(a, b) ==   \* emit_int128_sub!
    LET borrow == IF Lo(a) < Lo(b) THEN 1 ELSE 0
    IN Join(Sub64(Lo(a), Lo(b)), Sub64(Sub64(Hi(a), Hi(b)), borrow))

Neg128(x) ==      \* emit_int128_neg!
    Join(Add64(Not64(Lo(x)), 1), Add64(Not64(Hi(x)), IF Lo(x) = 0 THEN 1 ELSE 0))

Mul128(a, b) ==   \* emit_int128_mul! (Algorithm M for the low limbs' carry)
    LET a0 == And64(Lo(a), H - 1)
        a1 == ShrU64(Lo(a), HK)
        b0 == And64(Lo(b), H - 1)
        b1 == ShrU64(Lo(b), HK)
        t1 == ShrU64(Mul64(a0, b0), HK)
        t2 == Add64(Mul64(a1, b0), t1)
        w1 == And64(t2, H - 1)
        w2 == ShrU64(t2, HK)
        t3 == ShrU64(Add64(Mul64(a0, b1), w1), HK)
        carry == Add64(Add64(Mul64(a1, b1), w2), t3)
        rhi == Add64(Add64(carry, Mul64(Lo(a), Hi(b))), Mul64(Hi(a), Lo(b)))
    IN Join(Mul64(Lo(a), Lo(b)), rhi)

Ult128(a, b) == Hi(a) < Hi(b) \/ (Hi(a) = Hi(b) /\ Lo(a) < Lo(b))            \* emit_int128_ult!
Slt128(a, b) == S64(Hi(a)) < S64(Hi(b)) \/ (Hi(a) = Hi(b) /\ Lo(a) < Lo(b))  \* emit_int128_slt!

\* A shift amount n is one limb. The emitters take n modulo K for the limb shifts and select on
\* n < K; an amount of at least the full width selects the out-of-range result first.
Shl128(x, n) ==   \* emit_int128_shl!
    LET nm == n % K
        lo == IF n >= K THEN 0 ELSE Shl64(Lo(x), nm)
        cross == IF nm = 0 THEN 0 ELSE ShrU64(Lo(x), K - nm)
        hi == IF n < K THEN Or64(Shl64(Hi(x), nm), cross) ELSE Shl64(Lo(x), nm)
    IN IF ~MaskedShift /\ n >= W THEN 0 ELSE Join(lo, hi)

Lshr128(x, n) ==  \* emit_int128_lshr!
    LET nm == n % K
        hi == IF n >= K THEN 0 ELSE ShrU64(Hi(x), nm)
        cross == IF nm = 0 THEN 0 ELSE Shl64(Hi(x), K - nm)
        lo == IF n < K THEN Or64(ShrU64(Lo(x), nm), cross) ELSE ShrU64(Hi(x), nm)
    IN IF ~MaskedShift /\ n >= W THEN 0 ELSE Join(lo, hi)

Ashr128(x, n) ==  \* emit_int128_ashr!
    LET nm == n % K
        sign == ShrS64(Hi(x), K - 1)
        hi == IF n >= K THEN sign ELSE ShrS64(Hi(x), nm)
        cross == IF nm = 0 THEN 0 ELSE Shl64(Hi(x), K - nm)
        lo == IF n < K THEN Or64(ShrU64(Lo(x), nm), cross) ELSE ShrS64(Hi(x), nm)
    IN IF ~MaskedShift /\ n >= W THEN Join(sign, sign) ELSE Join(lo, hi)

\* A "byte" is a half limb here (K \div 2 bits), so a limb holds two and the integer four.
Swap64(a) == (a % H) * H + a \div H                               \* the i64 byte reversal
Bswap128(x) == Join(Swap64(Hi(x)), Swap64(Lo(x)))                  \* emit_int128_bswap!
Unit(x, i) == (x \div H^i) % H
BswapRef(x) == Unit(x, 0) * H^3 + Unit(x, 1) * H^2 + Unit(x, 2) * H + Unit(x, 3)

Ctlz128(x) == IF Hi(x) = 0 THEN K + Clz64(Lo(x)) ELSE Clz64(Hi(x))   \* emit_int128_ctlz!
Cttz128(x) == IF Lo(x) = 0 THEN K + Ctz64(Hi(x)) ELSE Ctz64(Lo(x))   \* emit_int128_cttz!
Ctpop128(x) == Pop(Lo(x), K) + Pop(Hi(x), K)                         \* emit_int128_ctpop!

\* Restoring long division, one bit of the dividend per step from the top: the remainder
\* shifts left taking the next bit, and subtracts the divisor when it is not below it. No bit
\* is shifted out of the remainder's high limb: before a step it is at most the dividend's
\* prefix above that step's bit, below 2^(W-1) (TLC checks this -- UDivRemOK holds without a
\* carry-out term).
Bit(x, i) == IF i >= K THEN And64(ShrU64(Hi(x), i - K), 1) ELSE And64(ShrU64(Lo(x), i), 1)
SetBit(q, i) == IF i >= K THEN Join(Lo(q), Or64(Hi(q), Shl64(1, i - K)))
                ELSE Join(Or64(Lo(q), Shl64(1, i)), Hi(q))
RECURSIVE LongDiv(_, _, _, _, _)
LongDiv(n, d, i, q, r) ==
    IF i < 0 THEN <<q, r>>
    ELSE LET r2 == Join(Or64(Shl64(Lo(r), 1), Bit(n, i)), Or64(Shl64(Hi(r), 1), ShrU64(Lo(r), K - 1)))
             take == IF SignedCompare THEN ~Slt128(r2, d) ELSE ~Ult128(r2, d)
         IN IF take THEN LongDiv(n, d, i - 1, SetBit(q, i), Sub128(r2, d))
            ELSE LongDiv(n, d, i - 1, q, r2)

UDivRem128(n, d) ==   \* the $u128_divrem helper (d # 0)
    IF Hi(n) = 0 /\ Hi(d) = 0 THEN <<Lo(n) \div Lo(d), Lo(n) % Lo(d)>>
    ELSE LongDiv(n, d, W - 1, 0, 0)

SDivRem128(a, b) ==   \* signed division on magnitudes (b # 0)
    LET na == S128(a) < 0
        nb == S128(b) < 0
        qr == UDivRem128(IF na THEN Neg128(a) ELSE a, IF nb THEN Neg128(b) ELSE b)
    IN <<IF na # nb THEN Neg128(qr[1]) ELSE qr[1], IF na THEN Neg128(qr[2]) ELSE qr[2]>>

\* The DivideError conditions the emitters test before dividing.
SDivThrows(a, b) == b = 0 \/ (a = M \div 2 /\ b = M - 1)
RemThrows(a, b) == b = 0

\* ---- Julia's intrinsics, as integer arithmetic ----
TruncQ(x, y) == IF (x >= 0) = (y >= 0) THEN Abs(x) \div Abs(y) ELSE -(Abs(x) \div Abs(y))
TopBits(x) == Clz(x, W)

AddOK == done \in BOOLEAN /\ \A a, b \in Nums : Add128(a, b) = (a + b) % M
SubOK == done \in BOOLEAN /\ \A a, b \in Nums : Sub128(a, b) = (a - b) % M
MulOK == done \in BOOLEAN /\ \A a, b \in Nums : Mul128(a, b) = (a * b) % M
NegOK == done \in BOOLEAN /\ \A a \in Nums : Neg128(a) = (M - a) % M
CompareOK == done \in BOOLEAN /\ \A a, b \in Nums : Ult128(a, b) = (a < b) /\ Slt128(a, b) = (S128(a) < S128(b))
ShiftOK == done \in BOOLEAN /\ \A x \in Nums, n \in Limb :
    /\ Shl128(x, n) = (IF n >= W THEN 0 ELSE (x * 2^n) % M)
    /\ Lshr128(x, n) = (IF n >= W THEN 0 ELSE x \div 2^n)
    /\ Ashr128(x, n) = U128(S128(x) \div 2^(IF n >= W THEN W - 1 ELSE n))
CountOK == done \in BOOLEAN /\ \A x \in Nums :
    /\ Ctlz128(x) = TopBits(x)
    /\ Cttz128(x) = Ctz(x, 0, W)
    /\ Ctpop128(x) = Pop(x, W)
BswapOK == done \in BOOLEAN /\ \A x \in Nums : Bswap128(x) = BswapRef(x)
UDivRemOK == done \in BOOLEAN /\ \A n \in Nums, d \in 1..(M - 1) : UDivRem128(n, d) = <<n \div d, n % d>>
SDivRemOK == done \in BOOLEAN /\ \A a \in Nums, b \in 1..(M - 1) :
    LET qr == SDivRem128(a, b)
    IN /\ qr[1] = U128(TruncQ(S128(a), S128(b)))
       /\ qr[2] = U128(S128(a) - TruncQ(S128(a), S128(b)) * S128(b))
\* intrinsics.cpp: checked_sdiv_int throws unless y # 0 /\ (y # -1 \/ x # typemin);
\* checked_srem_int, checked_udiv_int and checked_urem_int throw exactly when y = 0.
ThrowsOK == done \in BOOLEAN /\ \A a, b \in Nums :
    /\ SDivThrows(a, b) = ~(b # 0 /\ (b # M - 1 \/ a # M \div 2))
    /\ RemThrows(a, b) = (b = 0)

Init == done = FALSE
Next == done' = TRUE
Spec == Init /\ [][Next]_vars

TypeOK == done \in BOOLEAN
=============================================================================
