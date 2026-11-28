---------------------------- MODULE MCDataTypeEgal ----------------------------
(* jl_egal_types's DataType arm (src/julia/runtime/jltypes.jl:148-159, the *)
(* class-id table of src/intrinsics.jl:1555-1582) and the port's walk, over *)
(* every pair of DataTypeEgal's UnionAlls and the table of every order of  *)
(* its classes. Claims: Agrees, NameTable, Ends. Broken:                    *)
(* MCDataTypeEgal{NoTypeName,NoLength}Broken.cfg (Agrees),                 *)
(* MCDataTypeEgalTableByClassBroken.cfg (NameTable).                       *)
EXTENDS DataTypeEgal
=============================================================================
