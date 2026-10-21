------------------------------- MODULE MCUndef -------------------------------
(* Four slots, one of each kind, every sequence of four operations: stores *)
(* of `nothing` (where the kind admits it) and of an object, unsets,        *)
(* isassigned and reads. MCEnc is the code's encoding; each Broken          *)
(* instance swaps in one wrong encoding.                                    *)
EXTENDS Undef
MCSlots == {"s1", "s2", "s3", "s4"}
MCKind == [s \in MCSlots |-> CASE s = "s1" -> "ref" [] s = "s2" -> "union" [] s = "s3" -> "any" [] OTHER -> "inline"]
Ref == [undef |-> "null", check |-> TRUE, held |-> "own"]
Sentinel == [undef |-> "sentinel", check |-> TRUE, held |-> "any"]
Inline == [undef |-> "none", check |-> FALSE, held |-> "own"]
MCEnc == [k \in Kinds |-> CASE k = "ref" -> Ref [] k = "inline" -> Inline [] OTHER -> Sentinel]
\* an Any slot's #undef its null, the null `nothing` is
MCEncAnyAsNull == [MCEnc EXCEPT !["any"] = Ref]
\* a Union{Nothing,S} slot held as S's nullable reference, its #undef the null
MCEncUnionAsNull == [MCEnc EXCEPT !["union"] = Ref]
\* the undefined value stored in S's own nullable reference, which cannot hold it
MCEncUnionConcrete == [MCEnc EXCEPT !["union"] = [Sentinel EXCEPT !.held = "own"]]
\* a no-nothing slot's null read unchecked (a null dereference)
MCEncRefUnchecked == [MCEnc EXCEPT !["ref"] = [Ref EXCEPT !.check = FALSE]]
\* the undefined value of an Any slot read as a value
MCEncAnyUnchecked == [MCEnc EXCEPT !["any"] = [Sentinel EXCEPT !.check = FALSE]]
\* an inline isbits union's null (its `nothing`) tested as #undef
MCEncInlineChecked == [MCEnc EXCEPT !["inline"] = Ref]
=============================================================================
