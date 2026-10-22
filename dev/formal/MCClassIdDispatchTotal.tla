------------------------- MODULE MCClassIdDispatchTotal -------------------------
(* MissingMethodTraps (same constants as MCClassIdDispatchCascade): a receiver   *)
(* tuple Julia rejects with MethodError traps -- never runs another row.  Holds  *)
(* by the three Julia-only guards (whole-span reservation with null holes, the   *)
(* classId span guard in caller and trampolines, the per-entry wrapper check of  *)
(* every non-level-1-axis slot).  The Broken instance is the pre-fix call, which *)
(* ran (i) the row of the varying axis when the other axis did not match and     *)
(* (ii) another selector's same-shaped row that first-fit packing had placed at  *)
(* offset + classId (both reproduced in Julia: test/dispatch_method_error.jl).   *)
EXTENDS ClassIdDispatch, TLC
MCSelectors   == {"f", "h"}
MCArity       == ("f" :> 2) @@ ("h" :> 1)
MCMethodSpace == { ("f" :> mf) @@ ("h" :> mh) : mf \in UpTo(Sigs(2), 2), mh \in UpTo(Sigs(1), 2) }
=============================================================================
