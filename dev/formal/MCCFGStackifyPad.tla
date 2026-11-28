---------------------------- MODULE MCCFGStackifyPad ---------------------------
(* Every CFG of N Julia blocks with one EH pad, a catch block no terminator *)
(* reaches, the blocks before it unwinding to it, throwing to the caller or *)
(* not throwing, sorted with the exception a region and stackified with its *)
(* try_table as LLVM does, the mismatches found checked against wasm's      *)
(* semantics. N=4, every such CFG; the Broken instances are                 *)
(* MCCFGStackifyPadWitness's, each on a witness CFG of five blocks.         *)
EXTENDS CFGStackify
=============================================================================
