------------------------ MODULE MCClassIdDispatchCascade ------------------------
(* Dispatch instance: every tree over 4 classes (closed world = all concrete), *)
(* an arity-2 selector f and an arity-1 selector h, every Julia method table  *)
(* of up to 2 signatures each (abstract signatures included) -- 5,616 method  *)
(* tables x 24 trees.  Claims: RangeIsa, RangesNest, SlotUnique, DispatchExact *)
(* (single-axis rows and the two-axis cascade), Determinism.                  *)
EXTENDS ClassIdDispatch, TLC
MCSelectors   == {"f", "h"}
MCArity       == ("f" :> 2) @@ ("h" :> 1)
MCMethodSpace == { ("f" :> mf) @@ ("h" :> mh) : mf \in UpTo(Sigs(2), 2), mh \in UpTo(Sigs(1), 2) }
=============================================================================
