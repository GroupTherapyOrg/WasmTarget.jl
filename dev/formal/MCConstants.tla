----------------------------- MODULE MCConstants -------------------------------
(* The program's constants (src/constants.jl ensureConstant, createConstant,   *)
(* _defineConstantInModuleRecursive) over a universe of a value, a string,    *)
(* immutables egal and not, isequal tuples of two classes, a forced-lazy      *)
(* constant and its holder, two mutable cells of equal contents and a cell    *)
(* holding itself, cells with an #undef field Julia allows and one it rules *)
(* out, for every program of one or two uses. Claims: SharesOnlyEgal,         *)
(* ChildrenFirst, EagerChildrenEager, OperandsTyped, CyclesReject,            *)
(* NoFabrication, DeterministicNumbering. Broken: MCConstants{KeyIsequal,     *)
(* ParentFirst,IgnoreChildLaziness,OwnType,NoCycleCheck,Fabricate,HashOrder, *)
(* ReverseUses}Broken.cfg, each its claim.                                    *)
EXTENDS Constants
=============================================================================
