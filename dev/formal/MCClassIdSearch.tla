---------------------------- MODULE MCClassIdSearch ----------------------------
(* class_id_search (src/code_generator.jl: its linear and binary forms and   *)
(* emit_class_id_range_check), executed instruction by instruction over      *)
(* every sorted, disjoint list of up to N ranges of class ids 0..IdMax, with *)
(* and without a miss, and every id of the W-bit word. Claims: Routes,       *)
(* Misses, AreaSound, Depth, Ends. Broken:                                   *)
(* MCClassIdSearch{ElideWithMiss,SignedLinear}Broken.cfg (Misses),           *)
(* MCClassIdSearch{SplitOffByOne,Unnormalized}Broken.cfg (Routes).           *)
EXTENDS ClassIdSearch
=============================================================================
