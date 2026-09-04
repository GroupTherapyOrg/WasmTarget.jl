# ============================================================================
# options.jl — the debug surface, consolidated.
#
# parity(translator.dart:48-89 TranslatorOptions): dart2wasm reads its debug
# switches ONCE into a typed options object built at the entry point and
# threaded through the translator (`printKernel`, `printWasm`, `verbose`,
# `verifyTypeChecks`, `watchPoints: List<int>`). WasmTarget instead had 17
# scattered `ENV["WT_..."]` reads across src/. This file is the single typed
# replacement: one struct, one env-parsing function, one global holding the
# active options — read from everywhere else, ENV read from nowhere else.
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
end

"""
    options_from_env() -> CompilerOptions

The only place ENV is read for compiler debug switches. `WT_TRACE` is a
comma-separated list of trace points (`mm`, `strarg`, `closure`, `cc`,
`stubargs`, `retcompat`, `condstub`, `deadval`) replacing the eight ad-hoc
`WT_TRACE_*`/`WT_DBG_*` variables it consolidates.
"""
function options_from_env()::CompilerOptions
    trace = Set{Symbol}(Symbol(s) for s in split(get(ENV, "WT_TRACE", ""), ',') if !isempty(s))
    return CompilerOptions(;
        debug_fn=get(ENV, "WT_DBG_FN", ""),
        builder_trace=haskey(ENV, "WT_BUILDER_TRACE"),
        audit_value_stack=get(ENV, "WT_AUDIT_VALUE_STACK", "") == "1",
        log_registry=get(ENV, "WT_LOG_REGISTRY", "") == "1",
        trace=trace,
    )
end

# The active options, set once per public compile call (see compile/compile_multi/
# compile_from_codeinfo/compile_with_base in WasmTarget.jl) — never read piecemeal.
const OPTIONS = Ref{CompilerOptions}(CompilerOptions())

"""
    tracing(s::Symbol) -> Bool

Is trace point `s` active in the current [`OPTIONS`](@ref)? dart's `watchPoints`
analogue.
"""
tracing(s::Symbol) = s in OPTIONS[].trace
