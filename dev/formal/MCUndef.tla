------------------------------- MODULE MCUndef -------------------------------
(* Six slots, one of each type kind the code tells apart, every sequence   *)
(* of five operations: an allocation or a constant's slot, then stores of  *)
(* `nothing` (where the type admits it) and of an object, unsets,          *)
(* isassigned and reads. MCRule is the code's rules; each Broken instance  *)
(* flips one.                                                              *)
EXTENDS Undef
MCSlots == {"str", "unionstr", "any", "number", "inlineunion", "somestr"}
MCTy == [s \in MCSlots |->
    CASE s = "str"         -> [boxed |-> TRUE,  ptr |-> FALSE, admits |-> FALSE, repr |-> "concrete"]  \* String
      [] s = "unionstr"    -> [boxed |-> TRUE,  ptr |-> FALSE, admits |-> TRUE,  repr |-> "concrete"]  \* Union{Nothing,String}
      [] s = "any"         -> [boxed |-> TRUE,  ptr |-> FALSE, admits |-> TRUE,  repr |-> "anyh"]      \* Any
      [] s = "number"      -> [boxed |-> TRUE,  ptr |-> FALSE, admits |-> FALSE, repr |-> "anyh"]      \* Number
      [] s = "inlineunion" -> [boxed |-> FALSE, ptr |-> FALSE, admits |-> TRUE,  repr |-> "concrete"]  \* Union{Nothing,Int64}, its nullable box
      [] OTHER             -> [boxed |-> FALSE, ptr |-> TRUE,  admits |-> FALSE, repr |-> "concrete"]] \* Some{String}
MCRule == [firstptr |-> TRUE, promote |-> TRUE, sentinel |-> TRUE, bytype |-> FALSE,
           checknull |-> TRUE, checksentinel |-> TRUE, inlinetest |-> FALSE, constundef |-> TRUE]
\* no undefined value: an Any slot's #undef the null `nothing` is
MCRuleAnyAsNull == [MCRule EXCEPT !.sentinel = FALSE]
\* a Union{Nothing,S} slot left in S's own nullable reference: undef_slot marks it with the null
MCRuleUnionAsNull == [MCRule EXCEPT !.promote = FALSE]
\* S's own reference kept and the sentinel decided by the type alone: the undefined value in a
\* reference that cannot hold it
MCRuleUnionConcrete == [MCRule EXCEPT !.promote = FALSE, !.bytype = TRUE]
\* a null read unchecked (a null dereference)
MCRuleRefUnchecked == [MCRule EXCEPT !.checknull = FALSE]
\* the undefined value read as a value
MCRuleAnyUnchecked == [MCRule EXCEPT !.checksentinel = FALSE]
\* a pointer-free inline slot's null (its `nothing`) tested as #undef
MCRuleInlineChecked == [MCRule EXCEPT !.inlinetest = TRUE]
\* pointer_slot by allocatedinline alone: an inline struct with a pointer field is no pointer
MCRuleInlinePointer == [MCRule EXCEPT !.firstptr = FALSE]
\* a constant's unset slot emitted as the null
MCRuleConstAsNull == [MCRule EXCEPT !.constundef = FALSE]
=============================================================================
