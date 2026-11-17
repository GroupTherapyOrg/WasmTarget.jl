--------------------------- MODULE MCNirHandoff --------------------------------
(* The handoff from Julia's trim inference to the NIR (src/julia/subset.jl     *)
(* check_subset, src/julia/nir.jl build_nir) over a universe of an entry, two *)
(* ccallables it reaches, a plain callee and a ccallable only an abstract     *)
(* record would reach; every world Julia may give (which ccallables it lists  *)
(* twice, which repeats differ, which body holds a form outside the census)   *)
(* and every build order explored. Claims: CcallablesJudged, QueuedReached,   *)
(* OneBodyPerCI, Complete, RepeatAsserted, Aligned, RejectsOnlyGaps,          *)
(* Terminates. Broken: MCNirHandoff{AbstractRecord,QueueAll,NoDedup,          *)
(* UnreadRepeat,SkipOdd,RecordAsBody,KeepIntrinsic}Broken.cfg, each its      *)
(* header's claim.                                                          *)
EXTENDS NirHandoff
=============================================================================
