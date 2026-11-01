# parity(sdk/lib/_internal/wasm/standalone/stack_trace_patch.dart): dart's standalone patch of
# dart:core's StackTrace at the pin, ported as Julia methods of the module Runtime (src/julia/parity.jl
# RUNTIME_FILES): the current stack trace, the host's, held by the one class implementing StackTrace in
# a standalone module.

"""
A stack trace the embedder made (dart's `final class _EmbedderStackTrace implements StackTrace`), the
host reference `stackTraceGetCurrent` returned. dart's StackTrace is an abstract class of dart:core,
which Julia has no counterpart of (Julia's exceptions carry no stack trace object); in a standalone
module this is its one implementation, so it is the class a stack trace is (Translator.stackTraceInfo).
dart's `toString`, which renders the trace through `stackTraceToString` into an EmbedderStringImpl, is
not ported.
"""
@parity "sdk/lib/_internal/wasm/standalone/stack_trace_patch.dart:21 _EmbedderStackTrace" mutable struct _EmbedderStackTrace
    _embedder_stack_trace::Union{Nothing,WasmExternRef}
    # dart's constructor (line 24), the struct's one inner constructor: the field, null until then, set
    # to the trace it is given
    _EmbedderStackTrace(obj::Union{Nothing,WasmExternRef}) = new(obj)
end

"""
The current stack trace (dart's `@pragma("wasm:entry-point") @pragma('wasm:never-inline') static
StackTrace get current`): the embedder's, held in an _EmbedderStackTrace. Never inlined, as dart's
pragma says (Julia's @noinline), and kept in every closed world that throws (RUNTIME_ENTRY_POINTS),
as dart's entry-point pragma keeps it.
"""
@parity "sdk/lib/_internal/wasm/standalone/stack_trace_patch.dart:15 StackTrace.current" @noinline function StackTrace_current()::_EmbedderStackTrace
    local host_stack_trace = stack_trace_get_current()
    return _EmbedderStackTrace(host_stack_trace)
end
