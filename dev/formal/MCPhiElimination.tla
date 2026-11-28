-------------------------- MODULE MCPhiElimination --------------------------
(* Every CFG of N blocks after codegen's top block, every reachable block  *)
(* holding 1..MaxPhis PhiNodes with every choice of each edge's value, the *)
(* lowering of eliminate_phi_nodes and lower_phi_node, and every path of   *)
(* the lowered program. Each Broken instance flips Bug to a realistic      *)
(* wrong variant and checks only the claim it breaks.                      *)
EXTENDS PhiElimination
=============================================================================
