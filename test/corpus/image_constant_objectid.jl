# A constant whose identity the program reads keeps the id Julia's image keeps for it (julia/src/staticdata.c:1485
# jl_write_values; src/julia/runtime/hashing.jl image_slot!): its header's identity slot is the image's, pushed by
# pushObjectHeaderFields (code_generator.dart:6070). A run-time choice between two Vector constants makes objectid a
# run-time call on the constant, which Julia folds for the constant named alone: equal to that fold, and unequal to a
# fresh Vector's id
const _IMG_V1 = Int64[1, 2, 3]
const _IMG_V2 = Int64[4, 5]
_g("image_constant_objectid", Any[
    ("image_vector_objectid_folded", (x::Int64) -> objectid(x > 0 ? _IMG_V1 : _IMG_V2) == objectid(_IMG_V1) ? x + 1 : -x, Int64(5)),
    ("image_vector_objectid_fresh", (x::Int64) -> objectid(x > 0 ? _IMG_V1 : _IMG_V2) == objectid(Int64[1, 2, x]) ? -x : x * 2, Int64(5)),
])
