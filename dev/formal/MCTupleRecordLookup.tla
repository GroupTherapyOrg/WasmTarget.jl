------------------------- MODULE MCTupleRecordLookup -------------------------
(* typeof of an open slot's tuple by lookup (TupleRecordLookup.tla), over    *)
(* every value of up to two fields of Int64, Float64 and two nested tuples.  *)
(* Claims: TypeofAgrees, TypeofAnswers. Broken, each refuted by              *)
(* TypeofAgrees: MCTupleRecordLookupArityOnlyBroken.cfg,                     *)
(* MCTupleRecordLookupFirstRowOnMissBroken.cfg,                              *)
(* MCTupleRecordLookupNestedFatalIgnoredBroken.cfg. The lookup as the code   *)
(* returns it: TypeofAgreesR, TypeofAnswersR; Broken, each refuted by        *)
(* TypeofAgreesR: MCTupleRecordLookupNestedFirstRowBroken.cfg,               *)
(* MCTupleRecordLookupNestedFatalIgnoredRBroken.cfg.                         *)
EXTENDS TupleRecordLookup
=============================================================================
