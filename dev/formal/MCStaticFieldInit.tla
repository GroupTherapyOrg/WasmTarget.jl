------------------------- MODULE MCStaticFieldInit -----------------------------
(* The lazily initialized static field (src/globals.jl's lazy arm, its getter, *)
(* setter and initializer), over every run of four program steps (reads and    *)
(* writes of two values). Claims: ReadsTruth, NoPlaceholderRead,               *)
(* InitAtMostOnce, Ends. Broken: MCStaticFieldInit{ReadBeforeFlag,SetterNoFlag}*)
(* Broken.cfg, each its header's claim.                                        *)
EXTENDS StaticFieldInit
=============================================================================
