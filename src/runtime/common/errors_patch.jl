# parity(sdk/lib/_internal/wasm/common/errors_patch.dart): dart's runtime patch of dart:core's errors at
# the pin, its ports Julia methods of the module Runtime (src/julia/parity.jl RUNTIME_FILES), compiled
# into every closed world (src/julia/packages.jl RUNTIME_ROOTS) as dart compiles a program with
# its patch libraries.

"""
Throws `object` with `stack_trace` (dart's `@pragma("wasm:intrinsic") external static Never
_throw(Object object, StackTrace stackTrace)`): the intrinsifier lowers a call of it to wasm's `throw`
of the program's exception tag, both values its payload (intrinsics.dart's MemberIntrinsic.errorThrow),
its body never emitted; its Julia body, Julia's own throw, is what inference reads. dart's Object is
Julia's Any: Julia throws any value, as dart does; dart's StackTrace is the standalone runtime's
_EmbedderStackTrace. Never inlined, so its call stays a call the intrinsifier finds.
"""
@parity "sdk/lib/_internal/wasm/common/errors_patch.dart:40 Error._throw" @noinline Error__throw(@nospecialize(object::Any), stack_trace::_EmbedderStackTrace)::Union{} = Core.throw(object)

"""
Throws `object` with the current stack trace (dart's `@pragma('wasm:entry-point')
@pragma('wasm:never-inline') static Never _throwWithCurrentStackTrace(Object object)`), the call
dart2wasm's visitThrow makes: never inlined, as dart's pragma says (Julia's @noinline), and kept in
every closed world, as dart's entry-point pragma keeps it (RUNTIME_ROOTS), one specialization
for every thrown value (@nospecialize, the compileable signature juliac takes for an entrypoint),
the stack trace StackTrace.current's.
"""
@parity "sdk/lib/_internal/wasm/common/errors_patch.dart:19 Error._throwWithCurrentStackTrace" @noinline Error__throw_with_current_stack_trace(@nospecialize(object::Any))::Union{} =
    Error__throw(object, StackTrace_current())

"""
Throws the error of a failed cast of `operand` to `type` (dart's `@pragma("wasm:entry-point") static
Never _throwAsCheckError(Object? operand, Type? type)`), the call dart2wasm's as checker makes where
its type test fails. dart builds a `_TypeError` whose message names both; Julia's failed typeassert
raises Julia's own error, `TypeError(:typeassert, "", expected, got)`, the struct jl_type_error_rt
builds (julia/src/rtutils.c:113 jl_type_error_rt, `got` the value itself, the context empty), which is
thrown as dart throws its error, by Error._throw with StackTrace.current. dart's Object? is Julia's Any and its Type? Julia's
Type, never `nothing` (the as checker always passes the tested type's constant); never inlined, an entry point every closed world keeps (RUNTIME_ROOTS).
"""
@parity "sdk/lib/_internal/wasm/common/errors_patch.dart:76 _TypeError._throwAsCheckError" @noinline _TypeError__throw_as_check_error(@nospecialize(operand::Any), @nospecialize(type::Type))::Union{} =
    Error__throw(TypeError(:typeassert, "", type, operand), StackTrace_current())
