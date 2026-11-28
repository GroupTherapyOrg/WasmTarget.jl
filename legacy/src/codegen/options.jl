# ============================================================================
# options.jl — the debug surface, consolidated.
#
# parity(translator.dart:48-89 TranslatorOptions): dart2wasm reads its debug
# switches ONCE into a typed options object built at the entry point and
# threaded through the translator (`printKernel`, `printWasm`, `verbose`,
# `verifyTypeChecks`, `watchPoints: List<int>`). WasmTarget instead had 17
# scattered `ENV["WT_..."]` reads across src/. This file is the single typed
# replacement: one struct, one env-parsing function, read once by the compile's one entry
# (_compile, src/WasmTargetLegacy.jl) alone into its Translator — read from there, ENV read from
# nowhere else in src (L158).
# ============================================================================

"""
    CompilerOptions

parity(translator.dart:48-89 `TranslatorOptions`). The debug/trace switches
that used to be scattered `ENV["WT_..."]` reads across src/, consolidated into
one typed struct. `trace` is the analogue of dart's `watchPoints: List<int>` —
a set of named trace points, checked with [`tracing`](@ref).
"""
Base.@kwdef struct CompilerOptions
    debug_fn::String = ""
    builder_trace::Bool = false
    audit_value_stack::Bool = false
    log_registry::Bool = false
    trace::Set{Symbol} = Set{Symbol}()
    # the wasm-tools cross-check of a finished module (WT_VALIDATE=1): WT's builder validates
    # every instruction as it is emitted (instructions.dart:494 _verifyTypes, dart's gate), so
    # the external validator is an independent double-check, off unless asked for
    validate::Bool = false
end

"""
    options_from_env() -> CompilerOptions

The only place ENV is read for compiler debug switches. `WT_TRACE` is a
comma-separated list of trace points (`mm`, `strarg`, `closure`, `cc`,
`stubargs`, `condstub`, `deadval`, `locals`) replacing the ad-hoc
`WT_TRACE_*`/`WT_DBG_*`/`WASMTARGET_DEBUG_LOCALS` variables it consolidates. `WT_VALIDATE=1`
turns on the wasm-tools cross-check of every finished module (an entry's `validate` keyword, when
given, decides instead). In src the compile's one entry alone calls it (L158).

parity(dart2wasm.dart:251 parseArguments): the options object is built once from the
invocation (dart's command line, WasmTarget's environment).
"""
function options_from_env()::CompilerOptions
    trace = Set{Symbol}(Symbol(s) for s in split(get(ENV, "WT_TRACE", ""), ',') if !isempty(s))
    return CompilerOptions(;
        debug_fn=get(ENV, "WT_DBG_FN", ""),
        builder_trace=haskey(ENV, "WT_BUILDER_TRACE"),
        audit_value_stack=get(ENV, "WT_AUDIT_VALUE_STACK", "") == "1",
        log_registry=get(ENV, "WT_LOG_REGISTRY", "") == "1",
        trace=trace,
        validate=get(ENV, "WT_VALIDATE", "") == "1",
    )
end

"""
    tracing(ctx, s::Symbol) -> Bool

Is trace point `s` active in the compile's options (its Translator's)? dart's `watchPoints`
analogue.
parity(pkg/dart2wasm/lib/compiler_options.dart:35 WasmCompilerOptions)
"""
tracing(ctx, s::Symbol)::Bool = s in ctx.translator.options.trace
