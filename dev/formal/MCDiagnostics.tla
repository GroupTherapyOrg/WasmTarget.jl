---------------------------- MODULE MCDiagnostics ----------------------------
(* Model-checking instance for Diagnostics.tla: five statements exercising     *)
(* the funnel's fatal-formula.                                                *)
(*   s1  Kind=normal                              -- never enters the funnel  *)
(*   s2  Kind=value_stub,          ForceReject     -- e.g. jl_alloc_string,    *)
(*       Memory-constant materialization: soundness_fatal=true regardless of  *)
(*       reachability (7 of the 13 value_stub call sites)                     *)
(*   s3  Kind=value_stub,          Default, ProvenDead=TRUE  -- e.g. memset/   *)
(*       objectid/struct-field-undefined when the CFG proves the block dead   *)
(*       (the other 6 value_stub call sites -- see the FINDING in the header) *)
(*   s4  Kind=unsupported_method,  Default, ProvenDead=FALSE -- a live,       *)
(*       reachable emit_unsupported_stub! site (21 call sites, all Default)   *)
(*   s5  Kind=unsupported_method,  ForceReject     -- the eval/readline       *)
(*       class: statically checked and rejected before any recursion         *)
(*       (invoke.jl:825-834, statements.jl:1262)                              *)
EXTENDS Diagnostics

StmtsDef == {"s1", "s2", "s3", "s4", "s5"}

KindDef == [
    s1 |-> "normal",
    s2 |-> "value_stub",
    s3 |-> "value_stub",
    s4 |-> "unsupported_method",
    s5 |-> "unsupported_method"]

CallerHintDef == [
    s1 |-> "Default",
    s2 |-> "ForceReject",
    s3 |-> "Default",
    s4 |-> "Default",
    s5 |-> "ForceReject"]

ProvenDeadDef == [
    s1 |-> FALSE,
    s2 |-> FALSE,
    s3 |-> TRUE,
    s4 |-> FALSE,
    s5 |-> FALSE]

\* Every current call site classifies before attempting emission (see header).
ClassifyAtBoundaryDef == [t \in Stmts |-> TRUE]

=============================================================================
