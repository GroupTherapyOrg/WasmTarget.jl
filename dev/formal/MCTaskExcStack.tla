---------------------------- MODULE MCTaskExcStack ----------------------------
(* Every run of top-level host calls, each a program nesting at most MaxFrames try and  *)
(* catch frames, with calls of the exported function from inside the module, over      *)
(* MaxSteps steps and two exception values; a Julia throw or a trap escapes. The Broken *)
(* instances: no entry (NoEntryReset), the reset in the exported function's own         *)
(* prologue (InnerReset), a pop_exception that restores nothing (NoPopRestore).         *)
EXTENDS TaskExcStack
=============================================================================
