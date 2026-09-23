---------------------------- MODULE MCStorageRef ----------------------------
(* Model-checking instance for StorageRef.tla: an Array [1, 2] over a Memory   *)
(* of length 2, element values {1, 2}, Memories of up to 3 slots, 4           *)
(* allocations, and every sequence of 4 operations (write, take a ref, push!, *)
(* popfirst!, resize!) — enough for a popfirst! then a reallocating push!      *)
(* that compacts the offset, with a ref taken before either.                  *)
EXTENDS StorageRef
=============================================================================
