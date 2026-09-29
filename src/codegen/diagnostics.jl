# ============================================================================
# Compiler Diagnostics — source-attributed failure reporting
# ============================================================================
#
# WasmTarget aims to be "correct-or-loud, never silently wrong". When codegen
# meets a construct it cannot translate, it routes through `record_unsupported!`
# below instead of silently emitting an `unreachable` trap. Wrong-value fallbacks
# raise `WasmCompileError`; dart-style unsupported paths carry a diagnostic and a
# validating trap. There is no permissive mode.

"""
    WasmDiagnostic

A single reason codegen could not fully translate a construct.

- `kind`      — category (`:unsupported_method`, `:unsupported_intrinsic`,
                `:unsupported_type`, `:value_stub`, `:ir_node`)
- `func_name` — name of the function being compiled
- `construct` — human-readable description of what wasn't handled
- `julia_loc` — `"file:line"` of the offending statement's INNERMOST source frame
                (the inlined Base method it came from, when it came from one), or `nothing`
- `detail`    — optional raw object (Expr / MethodInstance / Type) for debugging
- `stmt_idx`  — the SSA statement index in the compiled function's IR (0 = none)
- `stmt`      — that statement, printed
- `frames`    — the inline chain innermost-first, each `"method @ file:line"`, decoded
                from the CodeInfo's DebugInfo edges; the last entry is the compiled
                function itself

parity(pkg/_fe_analyzer_shared/lib/src/messages/codes.dart:144 LocatedMessage): a located,
structured report — never a bare string. With closed-world inlining a statement can sit hundreds of statements deep
inside a root function; the chain names the Base method it really belongs to.
"""
struct WasmDiagnostic
    kind::Symbol
    func_name::String
    construct::String
    julia_loc::Union{Nothing,String}
    detail::Any
    stmt_idx::Int
    stmt::String
    frames::Vector{String}
end
# parity(pkg/_fe_analyzer_shared/lib/src/messages/codes.dart:153 LocatedMessage): the
# constructor; a report made before a statement is known carries statement 0 and no chain.
WasmDiagnostic(kind::Symbol, func_name::AbstractString, construct::AbstractString,
               julia_loc::Union{Nothing,AbstractString}, detail)::WasmDiagnostic =
    WasmDiagnostic(kind, String(func_name), String(construct),
                   julia_loc === nothing ? nothing : String(julia_loc), detail, 0, "", String[])

# parity(pkg/front_end/lib/src/api_prototype/terminal_color_support.dart:14 printDiagnosticMessage)
function Base.show(io::IO, d::WasmDiagnostic)
    loc = d.julia_loc === nothing ? "" : " at $(d.julia_loc)"
    print(io, "[$(d.kind)] in `$(d.func_name)`$loc: $(d.construct)")
    d.stmt_idx > 0 && print(io, " (statement %", d.stmt_idx, ": ", d.stmt, ")")
end

"""
Print the inline chain, innermost first, indented under a diagnostic.

parity(pkg/front_end/lib/src/api_prototype/terminal_color_support.dart:14 printDiagnosticMessage)
"""
function _show_frames(io::IO, d::WasmDiagnostic)::Nothing
    isempty(d.frames) && return
    print(io, "\n  statement %", d.stmt_idx, ": ", d.stmt)
    for (i, f) in enumerate(d.frames)
        print(io, "\n  ", i == 1 ? "in " : " ← ", f)
    end
end

"""
    WasmInternalError(func_name, stmt_idx, stmt, frames, cause, stacktrace)

The internal tier: a codegen bug — a builder stack imbalance, an `error(...)`, a
MethodError inside the compiler — raised while a statement was being compiled. It is NOT a diagnostic about the user's program, so it
does not enter the ledger; but it is located exactly like one, so a compiler bug names
the statement and inline chain it surfaced at. `cause` is the original exception and
`stacktrace` the compiler frames it was raised through, innermost first, out to the frame
that caught it (`_raised_frames`) — so the bug names the compiler source line as well as
the statement.

parity(compile.dart:113 CFECrashError)
"""
struct WasmInternalError <: Exception
    func_name::String
    stmt_idx::Int
    stmt::String
    frames::Vector{String}
    cause::Any
    stacktrace::Vector{Base.StackTraces.StackFrame}
end

# the package's src directory, which a frame's file is shown relative to
# parity(compile.dart:120 CFECrashError.toString)
const _WT_SRC_DIR = dirname(@__DIR__)

# is a frame in WT's own source?
# parity(compile.dart:120 CFECrashError.toString)
_in_wt_src(f::Base.StackTraces.StackFrame)::Bool = (file = String(f.file); startswith(file, _WT_SRC_DIR))

"""
    _raised_frames(bt, entry) -> Vector{StackFrame}

The frames of backtrace `bt` (a `catch_backtrace()`) from where its exception was raised out to
the first frame of function `entry` — the frame that caught it — innermost first. The frames
past `entry` are the compilation pipeline, the same for every statement.
parity(compile.dart:345 CFECrashError): the crash carries the stack it was raised on.
"""
function _raised_frames(bt, entry::Symbol)::Vector{Base.StackTraces.StackFrame}
    local st = Base.stacktrace(bt)
    local k = findfirst(f -> f.func === entry, st)
    return k === nothing ? st : st[1:k]
end

# the innermost frame in WT's own source: where the codegen bug was raised
# parity(compile.dart:120 CFECrashError.toString)
function _wt_raise_site(st::Vector{Base.StackTraces.StackFrame})::Union{Base.StackTraces.StackFrame,Nothing}
    local k = findfirst(_in_wt_src, st)
    return k === nothing ? nothing : st[k]
end

# a frame as `function @ path:line`, the path relative to src/ for WT's own frames
# parity(compile.dart:120 CFECrashError.toString)
function _frame_text(f::Base.StackTraces.StackFrame)::String
    local file = String(f.file)
    _in_wt_src(f) && (file = "src/" * relpath(file, _WT_SRC_DIR))
    return string(f.func, " @ ", file, ":", f.line, f.inlined ? " [inlined]" : "")
end

# parity(compile.dart:120 CFECrashError.toString)
function Base.showerror(io::IO, e::WasmInternalError)
    print(io, "WasmInternalError: codegen bug while compiling `", e.func_name, "`")
    local site = _wt_raise_site(e.stacktrace)
    site === nothing || print(io, ", raised at ", _frame_text(site))
    if e.stmt_idx > 0
        print(io, "\n  statement %", e.stmt_idx, ": ", e.stmt)
        for (i, f) in enumerate(e.frames)
            print(io, "\n  ", i == 1 ? "in " : " ← ", f)
        end
    end
    print(io, "\n  cause: ")
    showerror(io, e.cause)
    isempty(e.stacktrace) && return
    print(io, "\n  raised through:")
    for f in e.stacktrace
        print(io, "\n    ", _frame_text(f))
    end
end

# parity(pkg/_fe_analyzer_shared/lib/src/messages/codes.dart:91 MessageCode)
_kind_phrase(k::Symbol)::String =
    k === :unsupported_method    ? "method" :
    k === :unsupported_intrinsic ? "intrinsic" :
    k === :unsupported_type      ? "type" :
    k === :value_stub            ? "operation (a stub here would compute a wrong result)" :
    k === :ir_node               ? "IR node" : String(k)

"""
    WasmCompileError(diag)

Thrown when codegen cannot translate a construct without fabricating a value.
Carries the [`WasmDiagnostic`](@ref) so callers can inspect `.diag`.

parity(compile.dart:132 CFECompileTimeErrors)
"""
struct WasmCompileError <: Exception
    diag::WasmDiagnostic
    all::Vector{WasmDiagnostic}   # every diagnostic recorded before the fatal one (the full ledger)
end
# parity(compile.dart:135 CFECompileTimeErrors): the constructor; a single rejection is its own
# ledger.
WasmCompileError(diag::WasmDiagnostic)::WasmCompileError = WasmCompileError(diag, WasmDiagnostic[diag])

# parity(pkg/front_end/lib/src/api_prototype/terminal_color_support.dart:14 printDiagnosticMessage)
function Base.showerror(io::IO, e::WasmCompileError)
    d = e.diag
    loc = d.julia_loc === nothing ? "" : " at $(d.julia_loc)"
    print(io, "WasmCompileError: cannot compile `$(d.func_name)`$loc\n")
    print(io, "  unsupported $(_kind_phrase(d.kind)): $(d.construct)")
    _show_frames(io, d)
    print(io, "\n  → implement this construct or file it as a coverage gap.")
end

"""
    WasmValidationError(msg, details, bytes=UInt8[])

Thrown when the opt-in independent `wasm-tools validate` cross-check rejects the
emitted module. `details` carries the validator's stderr when available; `bytes`
carries the rejected module itself (dart2wasm always writes its output — this is
the equivalent: the error carries what would have been written).
parity(quarantine: the error a failed wasm-tools validation raises (WT_VALIDATE); dart's builder asserts while it builds.)
"""
struct WasmValidationError <: Exception
    msg::String
    details::String
    bytes::Vector{UInt8}
end
# parity(quarantine: the error a failed wasm-tools validation raises (WT_VALIDATE); dart's builder asserts while it builds.)
WasmValidationError(msg::AbstractString, details::AbstractString)::WasmValidationError =
    WasmValidationError(String(msg), String(details), UInt8[])
# parity(quarantine: the error a failed wasm-tools validation raises (WT_VALIDATE); dart's builder asserts while it builds.)
WasmValidationError(msg::AbstractString)::WasmValidationError = WasmValidationError(String(msg), "", UInt8[])
# parity(quarantine: the error a failed wasm-tools validation raises (WT_VALIDATE); dart's builder asserts while it builds.)
Base.showerror(io::IO, e::WasmValidationError) =
    print(io, "WasmValidationError: ", e.msg, isempty(e.details) ? "" : "\n" * e.details,
          isempty(e.bytes) ? "" : "\n($(length(e.bytes)) bytes of rejected module in `.bytes`)")

# --- Source attribution -----------------------------------------------------
# A located report reads the compiled function's NIR (a statement's line and printed
# form) and its DebugInfo (the inline chain, the method's definition site) — both carried
# by the compilation context from the one NIR boundary. Its DebugInfo decodes every Int
# position (in range, out of range, empty or stripped codelocs) to a location or to none,
# so attribution reads it directly.

# parity(code_generator.dart:190 setSourceMapFileOffset): the NIR a located report reads.
_ctx_nir(ctx)::Vector{NirStmt} = ctx.nir
# parity(code_generator.dart:190 setSourceMapFileOffset): the DebugInfo a located report decodes.
_ctx_debuginfo(ctx)::Union{Core.DebugInfo,Nothing} = ctx.debuginfo

# Per-statement line — the NIR boundary's `NirStmt.line` (frontend/nir.jl `_nir_lines`:
# a position whose own DebugInfo entry is ≤ 0 takes the nearest earlier concrete line);
# `nothing` when the IR carries no line for it.
# parity(code_generator.dart:190 setSourceMapFileOffset): the line recorded on the node, read once.
function _stmt_line(ctx, idx::Int)::Union{Nothing,Int}
    nir = _ctx_nir(ctx)
    1 <= idx <= length(nir) || return nothing
    ln = Int(nir[idx].line)
    return ln > 0 ? ln : nothing
end

# The statement as a located report prints it: its NIR record.
# parity(code_generator.dart:726 _printLocation): the failing node a located report names.
_stmt_text(ctx, idx::Int)::String =
    (nir = _ctx_nir(ctx); 1 <= idx <= length(nir) ? first(nir_text(nir[idx]), 160) : "")

# Method definition "(file, line)" — the always-available anchor.
# parity(quarantine: Julia source positions live in the CodeInfo's compressed Core.DebugInfo (per-statement codelocs plus inline edges), not on the node as a Kernel fileOffset)
function _method_loc(di)::Union{Nothing,Tuple{String,Int}}
    di isa Core.DebugInfo || return nothing
    mi = di.def
    if mi isa Core.MethodInstance && mi.def isa Method
        m = mi.def
        return (string(m.file), Int(m.line))
    end
    return nothing
end

"""
    stmt_frames(di, idx) -> Vector{String}

The inline chain of SSA statement `idx`, innermost first — `"method @ file:line"` per
frame — decoded from the function's DebugInfo edges (Julia 1.12+: `Core.DebugInfo`).
A statement with no location of its own (a synthesized one) takes the nearest earlier
statement's chain. Empty when the IR carries no debug info at all.

parity(quarantine: Julia source positions live in the CodeInfo's compressed Core.DebugInfo (per-statement codelocs plus inline edges), not on the node as a Kernel fileOffset)
"""
function stmt_frames(di, idx::Int)::Vector{String}
    frames = String[]
    for n in Iterators.reverse(_stmt_line_nodes(di, idx))
        m = n.method
        name = m isa Core.MethodInstance ? sprint(show, m) :
               m isa Method ? string(m.name) : string(m)
        name = replace(name, "MethodInstance for " => "")
        push!(frames, string(name, " @ ", n.file, ":", n.line))
    end
    return frames
end

# The line-info nodes of statement `idx`, outermost first — the one decoding of a function's
# DebugInfo that stmt_frames and stmt_source_info share; a statement with no location of its
# own takes the nearest earlier statement's.
# parity(quarantine: Julia source positions live in the CodeInfo's compressed Core.DebugInfo (per-statement codelocs plus inline edges), not on the node as a Kernel fileOffset)
function _stmt_line_nodes(di, idx::Int)::Vector{Any}
    di isa Core.DebugInfo || return Any[]
    i = idx
    while i >= 1
        t = Base.IRShow.getdebugidx(di, i)
        Int(t[1]) > 0 && break
        i -= 1
    end
    i >= 1 || return Any[]
    return Any[Base.IRShow.buildLineInfoNode(di, di.def, i)...]
end

"""
    stmt_source_info(ctx, idx) -> Union{SourceInfo,Nothing}

The source a statement's instructions map to: its innermost frame's file and line (0-based,
the source map's convention; Julia records no column), named by its inline chain innermost
first — the provenance a compile-time rejection prints, carried into the module so a trap is
located the same way. `nothing` for a statement with no location.
parity(pkg/dart2wasm/lib/code_generator.dart:190 CodeGenerator.setSourceMapFileOffset)
"""
function stmt_source_info(ctx, idx::Int)::Union{SourceInfo,Nothing}
    local nodes = _stmt_line_nodes(_ctx_debuginfo(ctx), idx)
    isempty(nodes) && return nothing
    local inner = nodes[end]
    # each frame by its method's name, as a Julia stacktrace heads a frame: a MethodInstance's
    # full signature prints its type parameters whole, megabytes for a solver's inlined body
    local chain = String[]
    for n in Iterators.reverse(nodes)
        local m = n.method
        local name = m isa Core.MethodInstance ? (m.def isa Method ? string(m.def.module, ".", m.def.name) : string(m.def)) :
                     m isa Method ? string(m.module, ".", m.name) : string(m)
        push!(chain, string(name, " @ ", n.file, ":", n.line))
    end
    return SourceInfo(string(inner.file), max(Int(inner.line) - 1, 0), 0, join(chain, " ← "))
end

"""
    julia_loc(ctx, idx) -> Union{Nothing,String}

`"file:line"` of SSA statement `idx`'s innermost source frame (the Base method it was
inlined from, when it was); the method's own definition line when the statement has
no location.

parity(quarantine: Julia source positions live in the CodeInfo's compressed Core.DebugInfo (per-statement codelocs plus inline edges), not on the node as a Kernel fileOffset)
"""
function julia_loc(ctx, idx::Int)::Union{Nothing,String}
    di = _ctx_debuginfo(ctx)
    frames = stmt_frames(di, idx)
    if !isempty(frames)
        at = findlast(" @ ", frames[1])
        at !== nothing && return frames[1][at.stop+1:end]
    end
    ml = _method_loc(di)
    sl = _stmt_line(ctx, idx)
    if ml !== nothing
        file, mline = ml
        return string(file, ":", sl === nothing ? mline : sl)
    elseif sl !== nothing
        return string("line ", sl)
    end
    return nothing
end

"""
    located_internal_error(ctx, idx, cause, bt) -> WasmInternalError

Wrap a non-diagnostic exception raised while statement `idx` was being compiled
with the statement, its inline chain, and the compiler frames it was raised through
(`bt`, the `catch_backtrace()` of the catch in compile_statement!).

parity(compile.dart:345 CFECrashError)
"""
function located_internal_error(ctx, idx::Int, cause, bt)::WasmInternalError
    return WasmInternalError(_ctx_func_name(ctx), idx, _stmt_text(ctx, idx),
                             stmt_frames(_ctx_debuginfo(ctx), idx), cause,
                             _raised_frames(bt, :compile_statement!))
end

# parity(pkg/dart2wasm/lib/target.dart:719 DiagnosticReporter.report)
function _ctx_func_name(ctx)::String
    f = ctx.func_ref
    # A callable that is neither a Function nor a Type (a functor instance) has no `nameof`.
    (f !== nothing && applicable(nameof, f)) && return string(nameof(f))
    return "func_$(ctx.func_idx)"
end

# --- The choke point --------------------------------------------------------

"""
    DIAGNOSTICS_SINK

When set (see `compile(...; diagnostics_sink=...)`), every `WasmDiagnostic` recorded by any
compilation context is mirrored here.
This is the caller-facing ledger: tools like Snapshot.jl read it to explain *why* a
compilation degraded, with source attribution per diagnostic.
parity(pkg/dart2wasm/lib/target.dart:719 DiagnosticReporter.report)
"""
const DIAGNOSTICS_SINK = Base.RefValue{Union{Nothing,Vector{WasmDiagnostic}}}(nothing)


"""
    record_unsupported!(ctx, kind, construct; idx=0, detail=nothing, soundness_fatal=nothing) -> Nothing

Single funnel for "codegen cannot fully translate this". Always records a
[`WasmDiagnostic`](@ref) on `ctx.diagnostics` (so every gap is queryable, even
when compilation proceeds).

By default compilation is rejected. A diagnosed trap is permitted only when the
current Julia CFG proves the statement unreachable. `soundness_fatal=true` forces
rejection; `false` is reserved for callers that already possess an equally strong
structural proof.

The resolution is a function of the caller's `soundness_fatal` hint and CFG-proven
reachability ONLY — never of `kind` (dev/formal/Diagnostics.tla checks exactly this;
an earlier version of this docstring claimed `:value_stub` was unconditionally fatal,
which the code never enforced). A CFG-dead statement may take a trap whatever its
kind, because it never executes. The kinds classify the diagnostic for the reader:

  * **`:value_stub`** — a stub would have emitted a *wrong value* inline
    (e.g. `jl_object_id`→constant, non-zero `memset`); callers that know the site is
    live pass `soundness_fatal=true`.
  * **`:unsupported_method` / `:unsupported_type`** — reachable or uncertain
    unsupported code rejects instead of leaving a latent runtime trap.

Callers pass the SSA statement `idx` (already in scope at every codegen site) for
source attribution. Pass `soundness_fatal=true` to force rejection.
formal(dev/formal/Diagnostics.tla): fatal/trap resolution is a kind-independent function of the caller's soundness_fatal hint and CFG-proven reachability, classified here before any emission is attempted.
parity(pkg/kernel/lib/target/targets.dart:84 DiagnosticReporter.report)
"""
function record_unsupported!(ctx, kind::Symbol, construct::AbstractString;
                             idx::Int=0, detail=nothing,
                             soundness_fatal::Union{Nothing,Bool}=nothing)::Nothing
    idx > 0 || (idx = ctx.current_stmt_idx)   # helpers without an idx
    diag = WasmDiagnostic(kind, _ctx_func_name(ctx), String(construct),
                          idx > 0 ? julia_loc(ctx, idx) : nothing, detail,
                          idx, _stmt_text(ctx, idx),
                          idx > 0 ? stmt_frames(_ctx_debuginfo(ctx), idx) : String[])
    push!(ctx.diagnostics, diag)
    DIAGNOSTICS_SINK[] !== nothing && push!(DIAGNOSTICS_SINK[]::Vector{WasmDiagnostic}, diag)
    fatal = soundness_fatal === nothing ?
            !stmt_is_proven_unreachable(_ctx_nir(ctx), idx) :
            soundness_fatal
    if fatal
        _sink = DIAGNOSTICS_SINK[]
        throw(WasmCompileError(diag, _sink === nothing ? WasmDiagnostic[diag] : copy(_sink)))
    else
        @warn "WasmTarget unsupported path emits a validating trap" diagnostic=diag
    end
    return nothing
end

"""
    emit_unsupported_stub!(ctx, b, kind, construct; idx=0, detail=nothing, soundness_fatal=true) -> Nothing

Category-C funnel. Use this — never a bare `unreachable!` — whenever the stub replaces a construct that would
**return a value natively** but WT cannot lower (Int128 ops, externref-as-numeric/boxing,
`Core.svec`, `:new` of an unresolved type, the typeId dispatch-ladder miss, deferred parse
intrinsics, …). Routes through [`record_unsupported!`], which rejects wrong-value
fallbacks and reports dart-style unsupported traps. There is no permissive mode.

Do NOT use this for (A) structural dead-code unreachables (genuinely-unreachable points the
validator requires) or (B) native-throws parity stubs (`Union{}`-return / `throw_*`/`kwerr`
helpers) — those stay bare `unreachable` (sound; erroring would reject most of Base).

Builder-native form (first method): emits its unreachable straight on `b`.

parity(code_generator.dart:5084 UnreachableCodeGenerator)
"""
function emit_unsupported_stub!(ctx, b::InstrBuilder, kind::Symbol,
                                construct::AbstractString; idx::Int=0, detail=nothing,
                                soundness_fatal::Bool=true)::Nothing
    local _dead2 = stmt_is_proven_unreachable(_ctx_nir(ctx), idx)
    record_unsupported!(ctx, kind, construct; idx=idx, detail=detail,
                        soundness_fatal=(soundness_fatal && !_dead2))
    unreachable!(b)  # structural trap after recorded, proven-dead unsupported lowering
    ctx.last_stmt_was_stub = true
    return nothing
end

