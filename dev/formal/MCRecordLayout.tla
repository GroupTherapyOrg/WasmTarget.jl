-------------------------- MODULE MCRecordLayout -------------------------------
(* A record's layout (src/records.jl RecordShape, fromType, ==, getNameIndex,  *)
(* getPositionalIndex) for every pair of record types among the NamedTuples   *)
(* of up to three distinct names in every order, the Tuples of up to two      *)
(* parameters and two open tuple types. Claims: IndexIsPlace, EqualIsLayout,  *)
(* OpenRejects. Broken: MCRecordLayout{SortedIndex,NamesOnly,OpenAsEmpty}     *)
(* Broken.cfg, each its header's claim.                                       *)
EXTENDS RecordLayout
=============================================================================
