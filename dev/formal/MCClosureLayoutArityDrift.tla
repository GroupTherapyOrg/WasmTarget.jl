---------------------- MODULE MCClosureLayoutArityDrift ----------------------
(* Same instance shape as MCClosureLayout (reused via EXTENDS); only the      *)
(* AllowArityDrift CONSTANT differs, set in MCClosureLayoutArityDriftBroken.  *)
(* A distinct .tla name is required because run_tlc.sh derives the module to *)
(* check from a `MC<Name>[Variant]Broken.cfg` by stripping "Broken.cfg".      *)
EXTENDS MCClosureLayout
=============================================================================
