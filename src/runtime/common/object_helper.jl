# parity(sdk/lib/_internal/wasm/common/object_helper.dart): dart:_object_helper at the pin, the
# accessors of the hidden identity hash field every object carries in its header (dart2wasm/lib/
# class_info.dart:29 FieldIndex.identityHash, src/class_info.jl FieldIndex_identity_hash), their ports
# Julia methods of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
The identity hash field of `obj` (dart's `@pragma("wasm:intrinsic") external int
getIdentityHashField(Object obj)`): the intrinsifier lowers a call of it to the read of the field from
the object's header, zero-extended to dart's int (intrinsics.dart's StaticIntrinsic.getIdentityHashField),
its body never emitted. dart's Object is Julia's Any, its int Julia's Int64. Natively no object carries
the field, so the body raises; never inlined, so its call stays a call the intrinsifier finds.
"""
@parity "sdk/lib/_internal/wasm/common/object_helper.dart:9 getIdentityHashField" @noinline get_identity_hash_field(@nospecialize(obj::Any))::Int64 =
    _wasm_only(Int64)

"""
Stores `hash` in the identity hash field of `obj` (dart's `@pragma("wasm:intrinsic") external void
setIdentityHashField(Object obj, int hash)`): the intrinsifier lowers a call of it to the write of the
field, `hash` truncated to the field's i32 (intrinsics.dart's StaticIntrinsic.setIdentityHashField).
dart's void is Julia's nothing. Natively no object carries the field, so the body raises.
"""
@parity "sdk/lib/_internal/wasm/common/object_helper.dart:11 setIdentityHashField" @noinline set_identity_hash_field(@nospecialize(obj::Any), hash::Int64)::Nothing =
    (_wasm_only(Int64); nothing)
