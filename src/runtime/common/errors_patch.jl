# parity(sdk/lib/_internal/wasm/common/errors_patch.dart): dart's runtime patch of dart:core's errors at
# the pin, its ports Julia methods of the module Runtime (src/julia/parity.jl RUNTIME_FILES), compiled
# into every closed world (src/julia/subset.jl RUNTIME_ENTRY_POINTS) as dart compiles a program with
# its patch libraries.

"""
Throws `object` (dart's `@pragma("wasm:intrinsic") external static Never _throw(Object object,
StackTrace stackTrace)`): the intrinsifier lowers a call of it to wasm's `throw` of the program's
exception tag (intrinsics.dart's MemberIntrinsic.errorThrow), its body never emitted; its Julia body,
Julia's own throw, is what inference reads. WasmTarget's tag carries the thrown value alone
(src/tags.jl), so dart's stack trace parameter is dropped. dart's Object is Julia's Any: Julia throws
any value, as dart does. Never inlined, so its call stays a call the intrinsifier finds.
"""
@parity "sdk/lib/_internal/wasm/common/errors_patch.dart:40 Error._throw" @noinline Error__throw(@nospecialize(object::Any))::Union{} = Core.throw(object)

"""
Throws `object` with the current stack trace (dart's `@pragma('wasm:entry-point')
@pragma('wasm:never-inline') static Never _throwWithCurrentStackTrace(Object object)`), the call
dart2wasm's visitThrow makes: never inlined, as dart's pragma says (Julia's @noinline), and kept in
every closed world, as dart's entry-point pragma keeps it (RUNTIME_ENTRY_POINTS), one specialization
for every thrown value (@nospecialize, the compileable signature juliac takes for an entrypoint). The
stack trace is dropped with _throw's parameter.
"""
@parity "sdk/lib/_internal/wasm/common/errors_patch.dart:19 Error._throwWithCurrentStackTrace" @noinline Error__throw_with_current_stack_trace(@nospecialize(object::Any))::Union{} =
    Error__throw(object)
