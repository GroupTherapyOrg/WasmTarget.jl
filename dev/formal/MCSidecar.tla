-------------------------- MODULE MCSidecar --------------------------------
(* Model-checking instance for Sidecar.tla. Three sequential calls, kept     *)
(* deliberately tiny for a fast TLC run while covering everything the task   *)
(* asked for:                                                               *)
(*                                                                          *)
(*   call 1 -- plain: x = A1, y = A2, n = 2.                                *)
(*   call 2 -- ALIASED: x = A1 AND y = A1 (the SAME GC array), n = 2.       *)
(*   call 3 -- DEGENERATE: n = 0 (alloc(0) is called twice in a row, so     *)
(*             xptr = yptr here -- harmless, since the copy/compute loops   *)
(*             for a zero-length call never execute).                      *)
(*                                                                          *)
(* Cap = 4 is sized to exactly fit one call's 2*n = 4 scratch elements, so a *)
(* real reset is REQUIRED between calls 1 and 2 for call 2 to fit -- this is *)
(* what makes the Broken (skip-reset) variant fail fast, on the very first   *)
(* call boundary.                                                          *)
(***************************************************************************)
EXTENDS Sidecar

CONSTANTS A1, A2   \* two abstract GC-array identities (TLC model values)

MCArrayIds == {A1, A2}
MCN         == (1 :> 2) @@ (2 :> 2) @@ (3 :> 0)
MCXArr      == (1 :> A1) @@ (2 :> A1) @@ (3 :> A2)
MCYArr      == (1 :> A2) @@ (2 :> A1) @@ (3 :> A1)   \* call 2: XArr = YArr = A1 (aliased)
MCA         == (1 :> 1) @@ (2 :> 2) @@ (3 :> 0)
MCGC        == A1 :> ((0 :> 1) @@ (1 :> 2)) @@
               A2 :> ((0 :> 3) @@ (1 :> 1))
=============================================================================
