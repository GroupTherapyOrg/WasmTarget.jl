------------------------- MODULE MCClassIdNumbering ---------------------------
(* The class ids and ranges (src/class_info.jl ClassIdNumbering._number,      *)
(* getConcreteClassIdRange, normalize) over every world of Any, Number, Int,  *)
(* Str, Tuple{Any}, Tuple{Int} and Tuple{Str} the class walk can make, in    *)
(* every order it can meet them. Claims: ConcreteDense, AbstractAfter,        *)
(* RangeIsa, Normalized. Broken: MCClassIdNumbering{SharedCounter,OffByOne,   *)
(* NoImplementors,NoAdjacentMerge}Broken.cfg, each its header's claim.        *)
EXTENDS ClassIdNumbering
=============================================================================
