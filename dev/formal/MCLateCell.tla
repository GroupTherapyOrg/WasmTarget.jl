---------------------------- MODULE MCLateCell ---------------------------------
(* The late final cell (src/julia/late.jl Late{T}, _late_get, _late_set!),     *)
(* with and without an initializer, over every run of three client steps     *)
(* (reads and assignments of two values) and every init body (it returns      *)
(* either value, throws, or reads its own field). Claims: Stable, ReadsAgree, *)
(* NoDefaultRead, InitAtMostOnce, OneInitAtATime, RejectsOnlyMisuse, Ends.    *)
(* Broken: MCLateCell{DefaultRead,NoMemo,CycleReruns,ThrowSticks,Overwrite}   *)
(* Broken.cfg, each its header's claim.                                       *)
EXTENDS LateCell
=============================================================================
