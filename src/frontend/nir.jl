# NIR — the Normalized IR boundary between Julia's typed CodeInfo and codegen.
#
# parity(code_generator.dart:77 typeContext, :135 getStaticType): dart's AstCodeGenerator
# consumes ~81 finite Kernel node kinds and reads every node's type through ONE
# StaticTypeContext, never re-derived per visitor. WT's ground truth is Julia's typed IR
# (Core.CodeInfo) instead of Kernel, but the shape of the boundary is the same idea: build
# a discriminated node once per statement, with already-resolved identities (a Method, a
# MethodInstance, a C symbol, a field list) as struct fields — never `Expr.args[k]` reads
# scattered through the consumers. A consumer holding a NirNode has no way back to
# `Expr.args`; anything it needs was resolved here, once, when the node was built.
#
# Include order: this file loads immediately after codegen/ir.jl (src/WasmTarget.jl), BEFORE
# codegen/types.jl (WasmValType) and codegen/context.jl (AbstractCompilationContext) exist.
# That's deliberate, not an oversight: NIR represents JULIA semantics resolved from CodeInfo;
# the WASM-target type (WasmValType) is a SEPARATE, later translation layered on top (dart's
# own split between Kernel's DartType and translateType's w.ValueType). So nothing here is
# annotated with a WasmTarget-specific type — `ctx` arrives untyped (duck-typed against
# whatever AbstractCompilationContext-shaped object codegen/context.jl defines later) and
# `static_type` fields are `Any` (holds `nothing` or a WasmValType instance once one exists).
#
# Quarantine (Julia-only, no dart Kernel equivalent — DESIGN.md §10.1): NirBoundscheck
# (Julia's bounds-check-elision IR, `Expr(:boundscheck, ...)`) and the NirUnsupported
# `:phic`/`:upsilon` routing for Core.PhiCNode/Core.UpsilonNode (unoptimized-IR exception
# phis). These carry no dart anchor by design.

export NirNode, NirStmt, NirSSA, NirArgument, NirSlot, NirGlobalRef, NirLiteral,
       NirPhi, NirPi, NirGoto, NirGotoIfNot, NirReturn, NirEnter, NirLeave,
       NirTheException, NirPopException, NirCall, NirInvoke, NirNew, NirForeignCall,
       NirBoundscheck, NirUnsupported,
       build_nir, nir_raw_code, resolve_invoke_method, resolve_invoke_mi

# ============================================================================
# Node kinds — census: NirSSA/Argument/Slot/GlobalRef (values), NirPhi/Pi (SSA-form),
# NirGoto/GotoIfNot/Return (control), NirEnter/Leave/TheException/PopException (exceptions),
# NirCall/Invoke/New/ForeignCall (calls, resolved identity), NirLiteral (constants),
# NirUnsupported (loud-reject fallback for any head outside this census).
# ============================================================================

abstract type NirNode end

"""A use of an SSA-defined value. `static_type` is populated ONLY when a wasm local was
already allocated for this SSA id (`ctx.ssa_locals`/`ctx.phi_locals` — a plain array read,
not a new `get_concrete_wasm_type` call site: R5 must not increase from this boundary);
`nothing` otherwise. `julia_type` comes from `ctx.ssa_types` (already computed by
`analyze_ssa_types!` before `build_nir` runs) — not a new `infer_value_type` call: R3 must
not increase either."""
struct NirSSA <: NirNode
    id::Int
    static_type::Any
    julia_type::Type
end

struct NirArgument <: NirNode
    n::Int
end

struct NirSlot <: NirNode
    n::Int
end

"""`value` is the resolved global's current value, or `nothing` if unbound/unresolved."""
struct NirGlobalRef <: NirNode
    mod::Module
    name::Symbol
    value::Any
end

"""A constant operand — literal numbers/strings/symbols/chars/types/QuoteNode payloads,
and the catch-all for any operand shape resolve_operand doesn't otherwise classify."""
struct NirLiteral <: NirNode
    value::Any
end

"""edges[k] / values[k] pair up positionally; `values[k] === nothing` means the k'th edge
has NO assigned value (Core.PhiNode's `isassigned(stmt.values, k) == false`)."""
struct NirPhi <: NirNode
    edges::Vector{Int}
    values::Vector{Union{NirNode,Nothing}}
end

struct NirPi <: NirNode
    value::NirNode
    typ::Type
end

struct NirGoto <: NirNode
    target::Int
end

struct NirGotoIfNot <: NirNode
    cond::NirNode
    target::Int
end

struct NirReturn <: NirNode
    value::Union{NirNode,Nothing}
end

"""Core.EnterNode (try-region entry). `scope` is dropped — no consumer needs it yet."""
struct NirEnter <: NirNode
    catch_target::Int
end

"""`Expr(:leave, refs...)` — `n` is the count of exception scopes being left."""
struct NirLeave <: NirNode
    n::Int
end

struct NirTheException <: NirNode end
struct NirPopException <: NirNode end

"""`callee` is the RESOLVED function object / Core.IntrinsicFunction when statically known
(GlobalRef/QuoteNode operand), or a NirNode (NirSSA/NirArgument/...) for a dynamic callee
that has no static identity — `Any` because both shapes are legitimate."""
struct NirCall <: NirNode
    callee::Any
    args::Vector{NirNode}
end

"""`mi`/`method` are `Union{_,Nothing}` — resolve_invoke_mi/resolve_invoke_method are
deliberately total (never throw) because build_nir must not crash mid-compile on an
exotic `:invoke` shape; invoke.jl's own existing ~4 duplicated resolution sites are
equally defensive (see resolve_invoke_method's docstring)."""
struct NirInvoke <: NirNode
    mi::Union{Core.MethodInstance,Nothing}
    method::Union{Core.Method,Nothing}
    args::Vector{NirNode}
end

"""`field_types` is `fieldtype.(T, 1:fieldcount(T))` when `T` is concrete, else empty —
never throws on an exotic `T`."""
struct NirNew <: NirNode
    T::Type
    field_types::Vector{Type}
    args::Vector{NirNode}
end

struct NirForeignCall <: NirNode
    c_symbol::Union{Symbol,Nothing}
    arg_julia_types::Vector{Any}
    ret_julia_type::Any
    args::Vector{NirNode}
end

"""Julia-only, quarantine tier (no dart Kernel equivalent — bounds-check elision has no
AST node in a language without unchecked array access). `flag` is the literal Bool when
`Expr(:boundscheck, flag)`'s arg is a literal Bool, else `nothing`."""
struct NirBoundscheck <: NirNode
    flag::Union{Bool,Nothing}
end

"""Any head outside the census above. A consumer MUST route this to `record_unsupported!`
(never silently) — never reinterpreted as a no-op. `raw` is the original statement, for the
diagnostic's detail."""
struct NirUnsupported <: NirNode
    head::Symbol
    raw::Any
end

"""One statement's NIR record. `static_type`/`julia_type` describe the VALUE this statement
produces (mirrors the NirSSA fields above — `nothing`/`Any` when no local was pre-allocated).
`line` is a placeholder (Int32(0)): Julia 1.12+'s CodeInfo replaced the flat `codelocs`
array with a compressed `Core.DebugInfo` object; wiring real source lines through it is
follow-up work no current consumer needs. `raw` is the ORIGINAL CodeInfo statement —
kept so flow.jl/stackified.jl can still hand it to compile_statement!/compile_condition_to_i32!/
emit_return_coerced!/count_ssa_uses! (statements.jl/calls.jl/context.jl — owned by other
branches, not yet NIR-aware); this is the explicit, documented transitional escape hatch,
not a way for a NIR-aware consumer to read `.args`/`.head` itself."""
struct NirStmt
    node::NirNode
    static_type::Any
    julia_type::Type
    line::Int32
    raw::Any
end

# ============================================================================
# resolve_invoke_method / resolve_invoke_mi — the shared MethodInstance/CodeInstance→Method
# resolution. invoke.jl resolves this same shape at ~4 duplicated sites (e.g. ~line 800-808:
# `mi_or_ci = expr.args[1]; mi = mi_or_ci isa MethodInstance ? mi_or_ci : mi_or_ci isa
# CodeInstance ? mi_or_ci.def : nothing`). Phase 5's registry work can adopt these helpers
# without editing invoke.jl here — this march's file-ownership rule keeps that file
# untouched by this branch.
# ============================================================================

"""`:invoke`'s `args[1]` is a MethodInstance directly, or (two-tier compilation) a
CodeInstance whose `.def` is the MethodInstance. Never throws; returns `nothing` for any
other shape (mirrors invoke.jl's existing defensive fallthrough — an unresolvable slot is
a legitimate "fall through to generic handling" outcome there, not an error)."""
function resolve_invoke_mi(mi_or_ci)::Union{Core.MethodInstance,Nothing}
    mi_or_ci isa Core.MethodInstance && return mi_or_ci
    (isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance) && return mi_or_ci.def
    return nothing
end

"""MethodInstance/CodeInstance → Method. Never throws."""
function resolve_invoke_method(mi_or_ci)::Union{Core.Method,Nothing}
    mi = resolve_invoke_mi(mi_or_ci)
    return (mi isa Core.MethodInstance && mi.def isa Method) ? mi.def : nothing
end

# ============================================================================
# build_nir — the ONE pass that consumes a CodeInfo and produces the boundary. Everything
# below is intentionally total (never throws) — a build_nir crash would break every
# compile, not just the classification decision a consumer reads.
# ============================================================================

"""Best-effort local wasm type for an already-defined SSA id, reusing ctx.locals/
ctx.ssa_locals/ctx.phi_locals (all already computed by the time build_nir runs) — NOT a
new get_concrete_wasm_type call site. `nothing` when no local was allocated for this id."""
function _nir_local_static_type(ctx, id::Int)
    if haskey(ctx.ssa_locals, id)
        idx = ctx.ssa_locals[id] - ctx.n_params + 1
        return (idx >= 1 && idx <= length(ctx.locals)) ? ctx.locals[idx] : nothing
    elseif haskey(ctx.phi_locals, id)
        idx = ctx.phi_locals[id] - ctx.n_params + 1
        return (idx >= 1 && idx <= length(ctx.locals)) ? ctx.locals[idx] : nothing
    end
    return nothing
end

"""Resolve one IR operand (an Expr arg, a PhiNode value, a ReturnNode/GotoIfNot payload)
into a NirNode. Total: the final `else` wraps anything unrecognized as NirLiteral rather
than throwing."""
function resolve_operand(x, ctx)::NirNode
    if x isa Core.SSAValue
        jt = get(ctx.ssa_types, x.id, Any)
        return NirSSA(x.id, _nir_local_static_type(ctx, x.id), jt isa Type ? jt : Any)
    elseif x isa Core.Argument
        return NirArgument(x.n)
    elseif x isa Core.SlotNumber
        return NirSlot(x.n)
    elseif x isa GlobalRef
        val = try
            isdefined(x.mod, x.name) ? getfield(x.mod, x.name) : nothing
        catch
            nothing
        end
        return NirGlobalRef(x.mod, x.name, val)
    elseif x isa QuoteNode
        return NirLiteral(x.value)
    else
        return NirLiteral(x)
    end
end

"""`:call`'s callee (args[1]) resolved to a function object where statically known, else
kept as the corresponding NirNode operand (dynamic callee — e.g. a closure argument)."""
function resolve_call_callee(x, ctx)
    if x isa GlobalRef
        try
            return isdefined(x.mod, x.name) ? getfield(x.mod, x.name) : x
        catch
            return x
        end
    elseif x isa QuoteNode
        return x.value
    else
        return resolve_operand(x, ctx)
    end
end

function _resolve_type_operand(x)
    x isa Type && return x
    if x isa GlobalRef
        try
            isdefined(x.mod, x.name) || return Any
            v = getfield(x.mod, x.name)
            return v isa Type ? v : Any
        catch
            return Any
        end
    end
    (x isa QuoteNode && x.value isa Type) && return x.value
    return Any
end

function _resolve_foreigncall_symbol(x)::Union{Symbol,Nothing}
    if x isa QuoteNode && x.value isa Symbol
        return x.value
    elseif x isa Symbol
        return x
    elseif x isa GlobalRef
        return x.name
    else
        return nothing
    end
end

"""Classify one raw CodeInfo statement into a NirNode. Total (never throws) — any Expr
head outside the census, or any statement shape not otherwise recognized, becomes
NirUnsupported/NirLiteral rather than crashing build_nir."""
function _nir_classify(stmt, ctx)::NirNode
    if stmt === nothing
        return NirLiteral(nothing)
    elseif stmt isa Core.ReturnNode
        return NirReturn(isdefined(stmt, :val) ? resolve_operand(stmt.val, ctx) : nothing)
    elseif stmt isa Core.GotoNode
        return NirGoto(stmt.label)
    elseif stmt isa Core.GotoIfNot
        return NirGotoIfNot(resolve_operand(stmt.cond, ctx), stmt.dest)
    elseif stmt isa Core.PhiNode
        vals = Vector{Union{NirNode,Nothing}}(undef, length(stmt.values))
        for k in eachindex(stmt.values)
            vals[k] = isassigned(stmt.values, k) ? resolve_operand(stmt.values[k], ctx) : nothing
        end
        return NirPhi(Int[Int(e) for e in stmt.edges], vals)
    elseif stmt isa Core.PiNode
        return NirPi(resolve_operand(stmt.val, ctx), stmt.typ)
    elseif isdefined(Core, :EnterNode) && stmt isa Core.EnterNode
        return NirEnter(stmt.catch_dest)
    elseif isdefined(Core, :PhiCNode) && stmt isa Core.PhiCNode
        return NirUnsupported(:phic, stmt)   # quarantine: unoptimized-IR exception phi
    elseif isdefined(Core, :UpsilonNode) && stmt isa Core.UpsilonNode
        return NirUnsupported(:upsilon, stmt)   # quarantine: unoptimized-IR exception phi
    elseif stmt isa Expr
        head = stmt.head
        args = stmt.args
        if head === :call && !isempty(args)
            callee = resolve_call_callee(args[1], ctx)
            cargs = NirNode[resolve_operand(a, ctx) for a in @view args[2:end]]
            return NirCall(callee, cargs)
        elseif head === :invoke && !isempty(args)
            mi_or_ci = args[1]
            cargs = length(args) >= 3 ? NirNode[resolve_operand(a, ctx) for a in @view args[3:end]] : NirNode[]
            return NirInvoke(resolve_invoke_mi(mi_or_ci), resolve_invoke_method(mi_or_ci), cargs)
        elseif head === :new && !isempty(args)
            T = _resolve_type_operand(args[1])
            fts = Type[]
            if T isa Type && isconcretetype(T)
                try
                    fts = Type[fieldtype(T, k) for k in 1:fieldcount(T)]
                catch
                    fts = Type[]
                end
            end
            cargs = length(args) >= 2 ? NirNode[resolve_operand(a, ctx) for a in @view args[2:end]] : NirNode[]
            return NirNew(T isa Type ? T : Any, fts, cargs)
        elseif head === :foreigncall
            c_symbol = !isempty(args) ? _resolve_foreigncall_symbol(args[1]) : nothing
            ret_t = length(args) >= 2 ? args[2] : Any
            arg_ts = (length(args) >= 3 && args[3] isa Core.SimpleVector) ? collect(Any, args[3]) : Any[]
            cargs = length(args) >= 6 ? NirNode[resolve_operand(a, ctx) for a in @view args[6:end]] : NirNode[]
            return NirForeignCall(c_symbol, arg_ts, ret_t, cargs)
        elseif head === :boundscheck
            flag = (!isempty(args) && args[1] isa Bool) ? args[1] : nothing
            return NirBoundscheck(flag)
        elseif head === :leave
            return NirLeave(length(args))
        elseif head === :pop_exception
            return NirPopException()
        elseif head === :the_exception
            return NirTheException()
        else
            return NirUnsupported(head, stmt)
        end
    else
        return resolve_operand(stmt, ctx)
    end
end

"""Build the NIR boundary for one function's CodeInfo, positionally aligned with
`code_info.code` (`nir[i]` classifies `code_info.code[i]`). Must run AFTER
`ctx.ssa_types`/`ctx.locals`/`ctx.ssa_locals`/`ctx.phi_locals` are populated (i.e. after
analyze_ssa_types!/analyze_control_flow!/allocate_ssa_locals! in the CompilationContext
constructor) — those are what let this pass reuse already-computed types/locals instead of
adding new get_concrete_wasm_type/infer_value_type call sites (R3/R5 unaffected: 0 added)."""
function build_nir(code_info::Core.CodeInfo, ctx)::Vector{NirStmt}
    code = code_info.code
    n = length(code)
    out = Vector{NirStmt}(undef, n)
    for i in 1:n
        stmt = code[i]
        jt = get(ctx.ssa_types, i, Any)
        node = _nir_classify(stmt, ctx)
        out[i] = NirStmt(node, _nir_local_static_type(ctx, i), jt isa Type ? jt : Any, Int32(0), stmt)
    end
    return out
end

"""Reconstruct the raw statement array from `ctx.nir` — the ONE place a not-yet-NIR-aware
consumer (has_try_catch/find_try_regions/compile_statement!/...) gets back exactly
`code_info.code`, without that consumer ever writing the identifier `code_info` itself."""
nir_raw_code(ctx) = Any[s.raw for s in ctx.nir]
