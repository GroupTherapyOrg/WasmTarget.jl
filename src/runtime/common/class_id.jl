# parity(sdk/lib/_internal/wasm/common/class_id.dart): dart's ClassID at the pin, the class ids of
# dart:_internal, its port a Julia method of the module Runtime (src/julia/parity.jl RUNTIME_FILES).

"""
The class id of `value` (dart's `@pragma("wasm:intrinsic") external static WasmI32 getID(Object
value)`): the intrinsifier lowers a call of it to the load of the id from the object's header
(intrinsics.dart's StaticIntrinsic.getID), its body never emitted. dart's Object is Julia's Any, its
WasmI32 Julia's Int32. Natively no object carries a class id, so the body raises; never inlined, so
its call stays a call the intrinsifier finds.
"""
@parity "sdk/lib/_internal/wasm/common/class_id.dart:10 ClassID.getID" @noinline ClassID_get_id(@nospecialize(value::Any))::Int32 =
    _wasm_only(Int32)
