----------------------------- MODULE MCRecGroup -----------------------------
(* Every field graph over three struct types and every order codegen asks *)
(* for them. The Broken instances are the placeholder-and-patch            *)
(* registration (a two-type cycle erases a field) and define-then-fill     *)
(* without the component (a forward reference outside any group).         *)
EXTENDS RecGroup
=============================================================================
