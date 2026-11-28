----------------------------- MODULE MCConstantKeys -----------------------------
(* The key the program's constants are interned by (src/constants.jl           *)
(* ensureConstant: StringObject, HeldStrings) over a universe of a value, two  *)
(* Strings of equal contents that are two objects, tuples and structs holding  *)
(* each, a struct holding the second tuple at a field of type Any and two      *)
(* cells, for every program of one or two uses. Claims: SharesOnlySame,         *)
(* EgalByContent, ReadsDefined, ChildrenFirst. Broken: MCConstantKeys{          *)
(* KeyStringEgal,KeyHolderEgal,RefEqStrings}Broken.cfg, each its claim.         *)
EXTENDS ConstantKeys
=============================================================================
