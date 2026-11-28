------------------------------ MODULE MCAPFloatRound ------------------------------
(* A 3-bit precision with exponents -1..2 (denormals 1/8, 2/8, 3/8; the largest finite 7; *)
(* infinity from 7.5), one 8-bit part, inputs N * 2^Q of 7 bits with Q in -13..3 (from    *)
(* values below half the smallest denormal to past the overflow edge, shifts past the     *)
(* part) and every caller truncation T in 0..7; the decision of roundSignificandWithExponent *)
(* over 4 excess bits. The positive instance checks the code as read; the Broken cfgs     *)
(* flip Mode: Truncate and TiesAway are rejected on RoundsCorrectly, NoCarry on Canonical, *)
(* ZeroBoundary on ClingerOK.                                                             *)
EXTENDS APFloatRound

\* a cfg writes no negative literal: the negative constants are these definitions
MCEMin == -1
MCQMin == -13
=============================================================================
