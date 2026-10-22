-------------------------- MODULE MCClassIdNumbering --------------------------
(* Every tree over 4 classes (24 shapes), every choice of abstract leaves,      *)
(* under every sibling order (24), the                                           *)
(* closed world numbered by dart's one walk (class_info.dart:864).  Claims:     *)
(* ConcreteDense, AbstractAfter, RangeIsa, Determinism.                         *)
(* Broken: MCClassIdNumberingOffByOneBroken.cfg (a range ends at the counter,   *)
(* RangeIsa violated) and MCClassIdNumberingSharedCounterBroken.cfg (abstract   *)
(* classes take concrete ids, ConcreteDense violated).                          *)
EXTENDS ClassIdNumbering
=============================================================================
