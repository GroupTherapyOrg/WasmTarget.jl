--------------------------- MODULE MCFirstListing ------------------------------
(* Julia's code generator reading the closed world's listing (aotcompile.cpp   *)
(* jl_emit_native_impl, src/julia/nir.jl build_nir): every listing of up to    *)
(* four items over three CodeInstances, two of one MethodInstance. Claims:      *)
(* EveryCIBuilt, FirstWins, OneBody, Terminates. Broken:                        *)
(* MCFirstListing{LastWins,ByMethod}Broken.cfg, each its header's claim.        *)
EXTENDS FirstListing
=============================================================================
