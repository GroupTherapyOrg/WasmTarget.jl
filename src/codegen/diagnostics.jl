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

parity(target.dart:719-751 DiagnosticReporter): a located, structured report — never a
bare string. With closed-world inlining a statement can sit hundreds of statements deep
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
WasmDiagnostic(kind::Symbol, func_name::AbstractString, construct::AbstractString,
               julia_loc::Union{Nothing,AbstractString}, detail) =
    WasmDiagnostic(kind, String(func_name), String(construct),
                   julia_loc === nothing ? nothing : String(julia_loc), detail, 0, "", String[])

function Base.show(io::IO, d::WasmDiagnostic)
    loc = d.julia_loc === nothing ? "" : " at $(d.julia_loc)"
    print(io, "[$(d.kind)] in `$(d.func_name)`$loc: $(d.construct)")
    d.stmt_idx > 0 && print(io, " (statement %", d.stmt_idx, ": ", d.stmt, ")")
end

"""Print the inline chain, innermost first, indented under a diagnostic."""
function _show_frames(io::IO, d::WasmDiagnostic)
    isempty(d.frames) && return
    print(io, "\n  statement %", d.stmt_idx, ": ", d.stmt)
    for (i, f) in enumerate(d.frames)
        print(io, "\n  ", i == 1 ? "in " : " ← ", f)
    end
end

_kind_phrase(k::Symbol) =
    k === :unsupported_method    ? "method" :
    k === :unsupported_intrinsic ? "intrinsic" :
    k === :unsupported_type      ? "type" :
    k === :value_stub            ? "operation (a stub here would compute a wrong result)" :
    k === :ir_node               ? "IR node" : String(k)

"""
    WasmCompileError(diag)

Thrown when codegen cannot translate a construct without fabricating a value.
Carries the [`WasmDiagnostic`](@ref) so callers can inspect `.diag`.
"""
struct WasmCompileError <: Exception
    diag::WasmDiagnostic
    all::Vector{WasmDiagnostic}   # every diagnostic recorded before the fatal one (the full ledger)
end
WasmCompileError(diag::WasmDiagnostic) = WasmCompileError(diag, WasmDiagnostic[diag])

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
"""
struct WasmValidationError <: Exception
    msg::String
    details::String
    bytes::Vector{UInt8}
end
WasmValidationError(msg::AbstractString, details::AbstractString) =
    WasmValidationError(String(msg), String(details), UInt8[])
WasmValidationError(msg::AbstractString) = WasmValidationError(String(msg), "", UInt8[])
Base.showerror(io::IO, e::WasmValidationError) =
    print(io, "WasmValidationError: ", e.msg, isempty(e.details) ? "" : "\n" * e.details,
          isempty(e.bytes) ? "" : "\n($(length(e.bytes)) bytes of rejected module in `.bytes`)")

# --- Source attribution -----------------------------------------------------
# ctx.code_info is a Core.CodeInfo for normal compilation and a SimpleIR wrapper
# for the in-place (self-hosting) path; both branches are guarded so either works.

# Per-statement line from the CodeInfo's DebugInfo (Julia 1.12: Core.DebugInfo).
# getdebugidx returns (line, file, edge); line ≤ 0 means "inherited/none", so we
# walk backward to the nearest statement that carries a concrete line.
function _stmt_line(ci, idx::Int)
    try
        di = ci.debuginfo
        i = idx
        while i >= 1
            t = Base.IRShow.getdebugidx(di, i)
            ln = Int(t[1])
            ln > 0 && return ln
            i -= 1
        end
    catch
    end
    return nothing
end

# Method definition "(file, line)" — the always-available anchor.
function _method_loc(ci)
    try
        mi = ci.debuginfo.def
        if mi isa Core.MethodInstance && mi.def isa Method
            m = mi.def
            return (string(m.file), Int(m.line))
        end
    catch
    end
    return nothing
end

"""
    stmt_frames(ci, idx) -> Vector{String}

The inline chain of SSA statement `idx`, innermost first — `"method @ file:line"` per
frame — decoded from the CodeInfo's DebugInfo edges (Julia 1.12+: `Core.DebugInfo`).
A statement with no location of its own (a synthesized one) takes the nearest earlier
statement's chain. Empty when the IR carries no debug info at all.
"""
function stmt_frames(ci, idx::Int)::Vector{String}
    frames = String[]
    try
        di = ci.debuginfo
        i = idx
        while i >= 1
            t = Base.IRShow.getdebugidx(di, i)
            Int(t[1]) > 0 && break
            i -= 1
        end
        i >= 1 || return frames
        nodes = Base.IRShow.buildLineInfoNode(di, di.def, i)   # outermost first
        for n in Iterators.reverse(nodes)
            m = n.method
            name = m isa Core.MethodInstance ? sprint(show, m) :
                   m isa Method ? string(m.name) : string(m)
            name = replace(name, "MethodInstance for " => "")
            push!(frames, string(name, " @ ", n.file, ":", n.line))
        end
    catch
    end
    return frames
end

"""
    julia_loc(ctx, idx) -> Union{Nothing,String}

`"file:line"` of SSA statement `idx`'s innermost source frame (the Base method it was
inlined from, when it was); the method's own definition line when the statement has
no location.
"""
function julia_loc(ctx, idx::Int)
    ci = ctx.code_info
    frames = stmt_frames(ci, idx)
    if !isempty(frames)
        at = findlast(" @ ", frames[1])
        at !== nothing && return frames[1][at.stop+1:end]
    end
    ml = _method_loc(ci)
    sl = _stmt_line(ci, idx)
    if ml !== nothing
        file, mline = ml
        return string(file, ":", sl === nothing ? mline : sl)
    elseif sl !== nothing
        return string("line ", sl)
    end
    return nothing
end

function _ctx_func_name(ctx)
    try
        ctx.func_ref !== nothing && return string(nameof(ctx.func_ref))
    catch
    end
    return "func_$(ctx.func_idx)"
end

# --- The choke point --------------------------------------------------------

"""
    DIAGNOSTICS_SINK

When set (see `compile(...; diagnostics_sink=...)`), every `WasmDiagnostic` recorded by any
compilation context is mirrored here.
This is the caller-facing ledger: tools like Snapshot.jl read it to explain *why* a
compilation degraded, with source attribution per diagnostic.
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
"""
# formal(dev/formal/Diagnostics.tla): fatal/trap resolution is a kind-independent function of the caller's soundness_fatal hint and CFG-proven reachability, classified here before any emission is attempted (parity: target.dart:719 two-tier diagnostics).
function record_unsupported!(ctx, kind::Symbol, construct::AbstractString;
                             idx::Int=0, detail=nothing,
                             soundness_fatal::Union{Nothing,Bool}=nothing)
    idx > 0 || (idx = try; ctx.current_stmt_idx; catch; 0; end)   # helpers without an idx
    local _ci = try; ctx.code_info; catch; nothing; end
    local _stmt = idx > 0 ? (try; first(string(_ci.code[idx]), 160); catch; ""; end) : ""
    diag = WasmDiagnostic(kind, _ctx_func_name(ctx), String(construct),
                          idx > 0 ? julia_loc(ctx, idx) : nothing, detail,
                          idx, _stmt, idx > 0 ? stmt_frames(_ci, idx) : String[])
    push!(ctx.diagnostics, diag)
    DIAGNOSTICS_SINK[] !== nothing && push!(DIAGNOSTICS_SINK[]::Vector{WasmDiagnostic}, diag)
    fatal = soundness_fatal === nothing ?
            !stmt_is_proven_unreachable(try _ci.code catch; nothing end, idx) :
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
    emit_unsupported_stub!(ctx, bytes, kind, construct; idx=0, detail=nothing, soundness_fatal=true) -> Nothing

Category-C funnel. Use this — instead of a bare
`push!(bytes, Opcode.UNREACHABLE)` — whenever the stub replaces a construct that would
**return a value natively** but WT cannot lower (Int128 ops, externref-as-numeric/boxing,
`Core.svec`, `:new` of an unresolved type, the typeId dispatch-ladder miss, deferred parse
intrinsics, …). Routes through [`record_unsupported!`], which rejects wrong-value
fallbacks and reports dart-style unsupported traps. There is no permissive mode.

Do NOT use this for (A) structural dead-code unreachables (genuinely-unreachable points the
validator requires) or (B) native-throws parity stubs (`Union{}`-return / `throw_*`/`kwerr`
helpers) — those stay bare `unreachable` (sound; erroring would reject most of Base — see
`test/fuzz/STRICT_MODE_INVENTORY.md`).

Builder-native form (first method): emits its unreachable straight on `b`.
"""
function emit_unsupported_stub!(ctx, b::InstrBuilder, kind::Symbol,
                                construct::AbstractString; idx::Int=0, detail=nothing,
                                soundness_fatal::Bool=true)
    local _code2 = try ctx.code_info.code catch; nothing end
    local _dead2 = stmt_is_proven_unreachable(_code2, idx)
    record_unsupported!(ctx, kind, construct; idx=idx, detail=detail,
                        soundness_fatal=(soundness_fatal && !_dead2))
    unreachable!(b)  # structural trap after recorded, proven-dead unsupported lowering
    ctx.last_stmt_was_stub = true
    return nothing
end

function emit_unsupported_stub!(ctx, bytes::Vector{UInt8}, kind::Symbol,
                                construct::AbstractString; idx::Int=0, detail=nothing,
                                soundness_fatal::Bool=true)
    # A trap is retained only for a block the Julia CFG proves unreachable.
    local _code = try ctx.code_info.code catch; nothing end
    local _dead = stmt_is_proven_unreachable(_code, idx)
    record_unsupported!(ctx, kind, construct; idx=idx, detail=detail,
                        soundness_fatal=(soundness_fatal && !_dead))
    push!(bytes, Opcode.UNREACHABLE)
    ctx.last_stmt_was_stub = true
    return nothing
end
