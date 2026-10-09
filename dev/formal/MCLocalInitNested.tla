---------------------------- MODULE MCLocalInitNested ----------------------------
(* Fragments three deep, one instruction shorter than MCLocalInit: every   *)
(* program of at most MaxLen = 6 instructions built by every nesting of at *)
(* most MaxFrags = 3 open fragments, so a requirement crosses two fragment *)
(* destinations before it reaches the top builder.                         *)
EXTENDS LocalInit
=============================================================================
