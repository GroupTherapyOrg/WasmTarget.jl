------------------------- MODULE MCCFGStackifyPadWitness -------------------------
(* Two CFGs of five blocks, with every unwind choice Julia's shapes allow,  *)
(* each a witness the exhaustive N=4 instance (MCCFGStackifyPad) has none of *)
(* or checks slowly. In the first, the entry falls to 2, which jumps to 4   *)
(* and unwinds to the pad 3, which jumps to 5; 4 and 5 return: placing the  *)
(* pad leaves 4 preferred, numbered below the pad's successor 5, so only    *)
(* the exception's being a sort region keeps 3 and 5 together. In the       *)
(* second, the entry falls to 2, which unwinds to the pad 4 and falls to 3, *)
(* which may throw to the caller and jumps to 5; the pad falls to 5, which  *)
(* returns: 3 is laid inside the pad's try_table. Every CFG of five blocks  *)
(* is past the gate's share.                                                *)
EXTENDS CFGStackify
MCWitnessCFGs == {<<Term("ft", 0), Term("goto", 4), Term("goto", 5), Term("ret", 0), Term("ret", 0)>>,
                  <<Term("ft", 0), Term("ft", 0), Term("goto", 5), Term("ft", 0), Term("ret", 0)>>}
MCWitnessPads == {3, 4}
=============================================================================
