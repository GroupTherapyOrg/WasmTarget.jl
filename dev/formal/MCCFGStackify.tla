---------------------------- MODULE MCCFGStackify ----------------------------
(* Every CFG of N Julia blocks (return, goto, fallthrough, goto-if-not),    *)
(* reachable, its entry with no predecessors and reducible, sorted and      *)
(* stackified as LLVM's WebAssemblyCFGSort and WebAssemblyCFGStackify do.   *)
(* Each Broken instance flips Bug to a realistic wrong variant and checks   *)
(* only the claim it breaks. N=4 here (439 CFGs); N=5 (7,126 CFGs) checks  *)
(* green in about 35 s on four workers, past the gate's share.              *)
EXTENDS CFGStackify
=============================================================================
