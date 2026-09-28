------------------------------ MODULE MCInt128Limbs ------------------------------
(* Four-bit limbs: an eight-bit integer, every operand pair, shift amounts 0..15 (past the *)
(* width of 8). The positive instance checks the emitters as fixed; MCInt128LimbsBroken    *)
(* masks the shift amount (the emitters until 2026-09-28) and TLC must reject it on        *)
(* ShiftOK; MCInt128LimbsCompareBroken compares the remainder signed.                    *)
EXTENDS Int128Limbs
=============================================================================
