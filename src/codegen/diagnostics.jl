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
- `julia_loc` — best-effort `"file:line"` of the offending statement, or `nothing`
- `detail`    — optional raw object (Expr / MethodInstance / Type) for debugging
"""
struct WasmDiagnostic
    kind::Symbol
    func_name::String
    construct::String
    julia_loc::Union{Nothing,String}
    detail::Any
end

function Base.show(io::IO, d::WasmDiagnostic)
    loc = d.julia_loc === nothing ? "" : " at $(d.julia_loc)"
    print(io, "[$(d.kind)] in `$(d.func_name)`$loc: $(d.construct)")
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
    print(io, "  unsupported $(_kind_phrase(d.kind)): $(d.construct)\n")
    print(io, "  → implement this construct or file it as a coverage gap.")
end

"""
    WasmValidationError(msg, details)

Thrown when the opt-in independent `wasm-tools validate` cross-check rejects the
emitted module. `details` carries the validator's stderr when available.
"""
struct WasmValidationError <: Exception
    msg::String
    details::String
end
WasmValidationError(msg::AbstractString) = WasmValidationError(String(msg), "")
Base.showerror(io::IO, e::WasmValidationError) =
    print(io, "WasmValidationError: ", e.msg, isempty(e.details) ? "" : "\n" * e.details)

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
    julia_loc(ctx, idx) -> Union{Nothing,String}

Best-effort `"file:line"` for SSA statement `idx`: the method's definition file
combined with the per-statement line where the DebugInfo provides one.
"""
function julia_loc(ctx, idx::Int)
    ci = ctx.code_info
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

  * **`:value_stub`** — the stub would emit a *wrong value* inline
    (e.g. `jl_object_id`→constant, non-zero `memset`). This is unsound regardless
    of reachability, so it throws [`WasmCompileError`](@ref).
  * **`:unsupported_method` / `:unsupported_type`** — reachable or uncertain
    unsupported code rejects instead of leaving a latent runtime trap.

Callers pass the SSA statement `idx` (already in scope at every codegen site) for
source attribution. Pass `soundness_fatal=true` to force rejection.
"""
function record_unsupported!(ctx, kind::Symbol, construct::AbstractString;
                             idx::Int=0, detail=nothing,
                             soundness_fatal::Union{Nothing,Bool}=nothing)
    diag = WasmDiagnostic(kind, _ctx_func_name(ctx), String(construct),
                          idx > 0 ? julia_loc(ctx, idx) : nothing, detail)
    push!(ctx.diagnostics, diag)
    DIAGNOSTICS_SINK[] !== nothing && push!(DIAGNOSTICS_SINK[]::Vector{WasmDiagnostic}, diag)
    fatal = soundness_fatal === nothing ?
            !stmt_is_proven_unreachable(try ctx.code_info.code catch; nothing end, idx) :
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
