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
# `build_nir(code_info)` takes NO context: it is a pure function of the CodeInfo, and it
# runs FIRST — before analyze_ssa_types!/analyze_control_flow!/allocate_ssa_locals!, which
# are themselves NIR consumers. Every type on a node is Julia INFERENCE's own answer
# (`code_info.ssavaluetypes`, widened to a plain Julia type; `Any` where inference had
# nothing), never a codegen re-derivation. The WASM-target type (WasmValType) is a
# SEPARATE, later translation owned by the context (`ctx.locals`/`ctx.ssa_locals`) — dart's
# own split between Kernel's DartType and translateType's w.ValueType — so nothing here is
# annotated with a WasmTarget-specific type. That split is also what lets `build_nir` run
# on a CALLEE's CodeInfo (the definite-initialization proof in statements.jl does exactly
# that), where no context exists at all.
#
# Include order: this file loads immediately after codegen/ir.jl (src/WasmTarget.jl), BEFORE
# codegen/types.jl (WasmValType) and codegen/context.jl (AbstractCompilationContext) exist.
#
# Quarantine (Julia-only, no dart Kernel equivalent — dev/MARCH.md §10.1): NirBoundscheck
# (Julia's bounds-check-elision IR, `Expr(:boundscheck, ...)`), NirThrowUndefIfNot,
# NirNewvar, NirNoOp (`:gc_preserve_begin`/`:gc_preserve_end`/`:loopinfo` — hints with no
# runtime effect), and NirUpsilon/NirPhiC (unoptimized-IR exception phis). These carry no
# dart anchor by design. They are CLASSIFIED, not `NirUnsupported`: statements.jl lowers
# every one of them, and dev/formal/NirBuild.tla's claim (5) makes "NirUnsupported ⇒
# reject" a consumer obligation, so a construct with a real lowering must never arrive
# as Unsupported.

export NirNode, NirStmt, NirSSA, NirArgument, NirSlot, NirGlobalRef, NirLiteral,
       NirPhi, NirPi, NirGoto, NirGotoIfNot, NirReturn, NirEnter, NirLeave,
       NirTheException, NirPopException, NirCall, NirInvoke, NirNew, NirForeignCall,
       NirBoundscheck, NirThrowUndefIfNot, NirNewvar, NirNoOp, NirUpsilon, NirPhiC,
       NirUnsupported,
       build_nir, nir_raw_code, nir_value_raw, nir_node, nir_new,
       resolve_invoke_method, resolve_invoke_mi

# ============================================================================
# Node kinds — census: NirSSA/Argument/Slot/GlobalRef (values), NirPhi/Pi (SSA-form),
# NirGoto/GotoIfNot/Return (control), NirEnter/Leave/TheException/PopException (exceptions),
# NirCall/Invoke/New/ForeignCall (calls, resolved identity), NirLiteral (constants),
# NirBoundscheck/ThrowUndefIfNot/Newvar/NoOp/Upsilon/PhiC (the Julia-only quarantine tier),
# NirUnsupported (loud-reject fallback for any head outside this census).
# ============================================================================

abstract type NirNode end

"""A use of an SSA-defined value. `julia_type` is Julia inference's own answer for that
SSA id (`widenconst(code_info.ssavaluetypes[id])`, `Any` when inference had none) — not a
new `infer_value_type` call site: R3 must not increase from this boundary. A context's
refinements on top of it (analyze_ssa_types!'s overrides) stay in `ctx.ssa_types`."""
struct NirSSA <: NirNode
    id::Int
    julia_type::Type
end

struct NirArgument <: NirNode
    n::Int
end

"""A `Core.SlotNumber` use — unoptimized IR's variable slot. `id` is its slot number,
named as Julia names it (slot 1 = self, 2.. = the parameters, then the locals)."""
struct NirSlot <: NirNode
    id::Int
end

"""A `GlobalRef` operand, its binding resolved ONCE here. `bound` says the binding
existed (an unbound GlobalRef is a soundness reject at the consumer, and `value === nothing`
alone cannot distinguish that from a global whose value IS `nothing`)."""
struct NirGlobalRef <: NirNode
    mod::Module
    name::Symbol
    value::Any
    bound::Bool
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
    operands::Vector{NirNode}
end

"""`mi`/`method` are `Union{_,Nothing}` — resolve_invoke_mi/resolve_invoke_method are
deliberately total (never throw) because build_nir must not crash mid-compile on an
exotic `:invoke` shape; invoke.jl's own existing ~4 duplicated resolution sites are
equally defensive (see resolve_invoke_method's docstring)."""
struct NirInvoke <: NirNode
    mi::Union{Core.MethodInstance,Nothing}
    method::Union{Core.Method,Nothing}
    operands::Vector{NirNode}
end

"""`%new(T, fields...)`, with `T` resolved ONCE here from whichever operand shape named it:
a type literal/GlobalRef (`:literal`), a `Core.apply_type` result whose SSA type is
`Type{T}` (`:ssa`), or the constructor's own `#self#` argument, whose `T` is the `:new`
statement's own inferred type (`:argument`). `type_kind` records which; when resolution
FAILED it is `:ssa`/`:argument`/`:unknown` with `T === Any`, and `type_detail` carries the
widened inferred type the attempt consulted (the reject's detail). `field_types` is
`fieldtype.(T, 1:fieldcount(T))` when `T` is concrete, else empty — never throws on an
exotic `T`."""
struct NirNew <: NirNode
    T::Type
    field_types::Vector{Type}
    operands::Vector{NirNode}
    type_kind::Symbol
    type_detail::Type
end

"""`Expr(:foreigncall, name, rettype, argtypes, nreq, cc, args...)` — `operands` holds ONLY
the runtime arguments (raw `args[6:end]`), so a lowering indexes them from 1 and can never
read the ABI preamble by accident. `arg_julia_types` is the declared `Core.SimpleVector` of C
argument types; `ret_julia_type` the declared return type."""
struct NirForeignCall <: NirNode
    c_symbol::Union{Symbol,Nothing}
    arg_julia_types::Vector{Any}
    ret_julia_type::Any
    operands::Vector{NirNode}
end

"""Julia-only, quarantine tier (no dart Kernel equivalent — bounds-check elision has no
AST node in a language without unchecked array access). `flag` is the literal Bool when
`Expr(:boundscheck, flag)`'s arg is a literal Bool, else `nothing`."""
struct NirBoundscheck <: NirNode
    flag::Union{Bool,Nothing}
end

"""Julia-only, quarantine tier: `Expr(:throw_undef_if_not, var, cond)` — Julia's
undefined-capture check (`cond || throw(UndefVarError(var, :local))`); Dart has no
possibly-unassigned captured variables (definite assignment is checked at compile time)."""
struct NirThrowUndefIfNot <: NirNode
    var::Symbol
    cond::NirNode
end

"""Julia-only, quarantine tier: `Core.NewvarNode` — an unoptimized-IR slot declaration.
Wasm locals are default-initialized, so this has no lowering; it is classified rather
than left Unsupported because "no lowering needed" and "no lowering exists" must not
share a node kind."""
struct NirNewvar <: NirNode
    slot::Int
end

"""Julia-only, quarantine tier: an IR head that is a HINT with no runtime effect —
`:gc_preserve_begin`/`:gc_preserve_end` (WasmGC's host collector owns liveness) and
`:loopinfo` (`@simd`). Classified for the same reason as NirNewvar."""
struct NirNoOp <: NirNode
    head::Symbol
end

"""Julia-only, quarantine tier: `Core.UpsilonNode`, the store half of unoptimized IR's
exception phi (its value is written into the associated PhiC's local)."""
struct NirUpsilon <: NirNode
    value::Union{NirNode,Nothing}
end

"""Julia-only, quarantine tier: `Core.PhiCNode`, the read half of unoptimized IR's
exception phi. `values` are the Upsilon statements that write it."""
struct NirPhiC <: NirNode
    values::Vector{NirNode}
end

"""Any head outside the census above. A consumer MUST route this to `record_unsupported!`
(never silently) — never reinterpreted as a no-op. `raw` is the original statement, for the
diagnostic's detail."""
struct NirUnsupported <: NirNode
    head::Symbol
    raw::Any
end

"""One statement's NIR record. `julia_type` is the type of the VALUE this statement
produces (`widenconst(code_info.ssavaluetypes[i])`, `Any` when absent). `line` is its
source line decoded from the CodeInfo's DebugInfo (0 when the IR carries none). `slot` is
the SlotNumber id when the statement is unoptimized IR's `Expr(:(=), SlotNumber(n), rhs)`
assignment and 0 otherwise — in that case `node` classifies the RHS, so a consumer sees
the value-producing operation directly and the assignment is one integer beside it. `raw`
is the ORIGINAL CodeInfo statement — kept so the not-yet-converted consumers
(context.jl/calls.jl/invoke.jl/compile.jl) can still be handed exactly what they expect;
this is the explicit, documented transitional escape hatch of the R29 migration, not a way
for a NIR-aware consumer to read `.args`/`.head` itself."""
struct NirStmt
    node::NirNode
    julia_type::Type
    line::Int32
    slot::Int
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

"""Raw per-position DebugInfo line, 0 when that position carries none. Julia 1.12+ replaced
the flat `codelocs` array with a compressed `Core.DebugInfo`; this is the one decode."""
function _debug_line(di, i::Int)::Int
    try
        return Int(Base.IRShow.getdebugidx(di, i)[1])
    catch
        return 0
    end
end

"""Per-statement source lines for one CodeInfo, in ONE forward pass: a statement whose own
DebugInfo entry is ≤ 0 (a synthesized one) inherits the nearest earlier statement that
carries a concrete line — the same rule diagnostics.jl's per-query `_stmt_line` walks
backward for, computed once here so a consumer reads `ctx.nir[idx].line`."""
function _nir_lines(code_info, n::Int)::Vector{Int32}
    out = zeros(Int32, n)
    di = try; code_info.debuginfo; catch; nothing; end
    di === nothing && return out
    carried = Int32(0)
    for i in 1:n
        ln = _debug_line(di, i)
        ln > 0 && (carried = Int32(ln))
        out[i] = carried
    end
    return out
end

"""Julia inference's own type for every SSA id, widened to a plain Julia type. Unoptimized
IR (may_optimize=false) keeps `Core.Const`/`Core.PartialStruct` lattice elements in
`ssavaluetypes`; every consumer downstream expects a plain type, so the widening happens
once, here. `Any` wherever inference had nothing (including when `ssavaluetypes` is not a
vector at all — an unanalyzed CodeInfo carries a statement COUNT there instead)."""
function _widened_ssa_types(code_info, n::Int)::Vector{Type}
    out = Vector{Type}(undef, n)
    fill!(out, Any)   # `fill(Any, n)` would infer Vector{DataType} and reject a Union member
    ssatypes = code_info.ssavaluetypes
    ssatypes isa Vector || return out
    for i in 1:min(n, length(ssatypes))
        T = ssatypes[i]
        wT = T isa Type ? T : Core.Compiler.widenconst(T)
        wT isa Type && (out[i] = wT)
    end
    return out
end

_nir_ssa_type(types::Vector{Type}, id::Int)::Type = (1 <= id <= length(types)) ? types[id] : Any
_nir_ssa_type(nir::Vector{NirStmt}, id::Int)::Type = (1 <= id <= length(nir)) ? nir[id].julia_type : Any

"""Resolve one IR operand (an Expr arg, a PhiNode value, a ReturnNode/GotoIfNot payload)
into a NirNode. Total: the final `else` wraps anything unrecognized as NirLiteral rather
than throwing. `types` supplies each SSA id's Julia type — the widened `ssavaluetypes`
during `build_nir`, or an already-built `Vector{NirStmt}` for the transitional
`nir_node(ctx, raw)` bridge, which must resolve to exactly the same nodes."""
function resolve_operand(x, types)::NirNode
    if x isa Core.SSAValue
        return NirSSA(x.id, _nir_ssa_type(types, x.id))
    elseif x isa Core.Argument
        return NirArgument(x.n)
    elseif x isa Core.SlotNumber
        return NirSlot(x.id)
    elseif x isa GlobalRef
        bound = try; isdefined(x.mod, x.name); catch; false; end
        val = bound ? (try; getfield(x.mod, x.name); catch; nothing; end) : nothing
        return NirGlobalRef(x.mod, x.name, val, bound)
    elseif x isa QuoteNode
        return NirLiteral(x.value)
    else
        return NirLiteral(x)
    end
end

"""`:call`'s callee (args[1]) resolved to a function object where statically known, else
kept as the corresponding NirNode operand (dynamic callee — e.g. a closure argument)."""
function resolve_call_callee(x, types)
    if x isa GlobalRef
        try
            return isdefined(x.mod, x.name) ? getfield(x.mod, x.name) : x
        catch
            return x
        end
    elseif x isa QuoteNode
        return x.value
    else
        return resolve_operand(x, types)
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

"""
    extract_foreigncall_name(name_arg) -> Union{Symbol, Nothing}

The C symbol named by a `:foreigncall`'s first argument — the ONE decode of that operand
(context.jl and compile.jl still call it on a raw operand; `_nir_classify` calls it to fill
`NirForeignCall.c_symbol`). Handles the shapes Julia's versions use:
- Julia 1.12: `QuoteNode(:name)` or a bare `:name`
- Julia 1.13: the name wrapped in a tuple — `Expr(:tuple, QuoteNode(:name))` or
  `QuoteNode((:name,))`
Also `GlobalRef` (e.g. `Base.memhash`).
"""
function extract_foreigncall_name(name_arg)::Union{Symbol, Nothing}
    val = if name_arg isa QuoteNode
        name_arg.value
    elseif name_arg isa Symbol
        name_arg
    elseif name_arg isa GlobalRef
        name_arg.name
    elseif name_arg isa Expr && name_arg.head === :tuple && length(name_arg.args) >= 1
        inner = name_arg.args[1]
        inner isa QuoteNode ? inner.value : (inner isa Symbol ? inner : nothing)
    else
        nothing
    end
    if val isa Tuple && length(val) >= 1 && val[1] isa Symbol
        return val[1]
    end
    return val isa Symbol ? val : nothing
end

_nir_field_types(T)::Vector{Type} =
    (T isa Type && isconcretetype(T)) ?
        (try; Type[fieldtype(T, k) for k in 1:fieldcount(T)]; catch; Type[]; end) : Type[]

"""Build a `NirNew` from an already-known concrete type and raw field operands — the entry
calls.jl uses when it SYNTHESIZES a field-wise constructor (there is no `Expr(:new, ...)`
in the IR to classify, so the node is built directly instead of a raw Expr being faked)."""
nir_new(T::Type, args, ctx)::NirNew =
    NirNew(T, _nir_field_types(T), NirNode[nir_node(ctx, a) for a in args], :literal, Any)

"""`%new`'s type operand. A literal/GlobalRef names `T` outright. A `Core.apply_type`
result names it through the SSA's OWN inferred type, which must be a `Type{T}` — read from
the RAW lattice element, exactly as compile_new! read `ssavaluetypes[id]` before this
boundary existed, so the accept/reject frontier is unchanged. A constructor body's
`#self#` (`Core.Argument`) names it through the `:new` statement's own inferred type."""
function _resolve_new_type(type_ref, stmt_idx::Int, code_info)::Tuple{Type,Symbol,Type}
    _raw_ssa(i) = begin
        ssatypes = code_info.ssavaluetypes
        (ssatypes isa Vector && 1 <= i <= length(ssatypes)) ? ssatypes[i] : Any
    end
    _widen(t) = (t isa Type ? t : (try; Core.Compiler.widenconst(t); catch; Any; end))
    if type_ref isa GlobalRef || type_ref isa DataType || type_ref isa Type ||
       (type_ref isa QuoteNode && type_ref.value isa Type)
        T = _resolve_type_operand(type_ref)
        return (T, :literal, Any)
    elseif type_ref isa Core.SSAValue
        ssa_type = _raw_ssa(type_ref.id)
        if ssa_type isa DataType && ssa_type <: Type && length(ssa_type.parameters) >= 1
            P = ssa_type.parameters[1]
            P isa Type && return (P, :literal, Any)
        end
        return (Any, :ssa, _widen(ssa_type))
    elseif type_ref isa Core.Argument
        new_ssa_type = _raw_ssa(stmt_idx)
        if new_ssa_type isa DataType && isconcretetype(new_ssa_type) && isstructtype(new_ssa_type)
            return (new_ssa_type, :literal, Any)
        end
        return (Any, :argument, _widen(new_ssa_type))
    end
    return (Any, :unknown, Any)
end

"""Classify one raw CodeInfo statement into a NirNode. Total (never throws) — any Expr
head outside the census, or any statement shape not otherwise recognized, becomes
NirUnsupported/NirLiteral rather than crashing build_nir."""
function _nir_classify(stmt, i::Int, code_info, types::Vector{Type})::NirNode
    if stmt === nothing
        return NirLiteral(nothing)
    elseif stmt isa Core.ReturnNode
        return NirReturn(isdefined(stmt, :val) ? resolve_operand(stmt.val, types) : nothing)
    elseif stmt isa Core.GotoNode
        return NirGoto(stmt.label)
    elseif stmt isa Core.GotoIfNot
        return NirGotoIfNot(resolve_operand(stmt.cond, types), stmt.dest)
    elseif stmt isa Core.PhiNode
        vals = Vector{Union{NirNode,Nothing}}(undef, length(stmt.values))
        for k in eachindex(stmt.values)
            vals[k] = isassigned(stmt.values, k) ? resolve_operand(stmt.values[k], types) : nothing
        end
        return NirPhi(Int[Int(e) for e in stmt.edges], vals)
    elseif stmt isa Core.PiNode
        return NirPi(resolve_operand(stmt.val, types), stmt.typ)
    elseif isdefined(Core, :EnterNode) && stmt isa Core.EnterNode
        return NirEnter(stmt.catch_dest)
    elseif stmt isa Core.NewvarNode
        return NirNewvar(stmt.slot isa Core.SlotNumber ? stmt.slot.id : 0)
    elseif isdefined(Core, :PhiCNode) && stmt isa Core.PhiCNode
        return NirPhiC(NirNode[resolve_operand(v, types) for v in stmt.values])
    elseif isdefined(Core, :UpsilonNode) && stmt isa Core.UpsilonNode
        return NirUpsilon(isdefined(stmt, :val) ? resolve_operand(stmt.val, types) : nothing)
    elseif stmt isa Expr
        head = stmt.head
        args = stmt.args
        if head === :call && !isempty(args)
            callee = resolve_call_callee(args[1], types)
            cargs = NirNode[resolve_operand(a, types) for a in @view args[2:end]]
            return NirCall(callee, cargs)
        elseif head === :invoke && !isempty(args)
            mi_or_ci = args[1]
            cargs = length(args) >= 3 ? NirNode[resolve_operand(a, types) for a in @view args[3:end]] : NirNode[]
            return NirInvoke(resolve_invoke_mi(mi_or_ci), resolve_invoke_method(mi_or_ci), cargs)
        elseif head === :new && !isempty(args)
            T, kind, detail = _resolve_new_type(args[1], i, code_info)
            cargs = length(args) >= 2 ? NirNode[resolve_operand(a, types) for a in @view args[2:end]] : NirNode[]
            return NirNew(T, _nir_field_types(T), cargs, kind, detail)
        elseif head === :foreigncall
            c_symbol = !isempty(args) ? extract_foreigncall_name(args[1]) : nothing
            ret_t = length(args) >= 2 ? args[2] : Any
            arg_ts = (length(args) >= 3 && args[3] isa Core.SimpleVector) ? collect(Any, args[3]) : Any[]
            cargs = length(args) >= 6 ? NirNode[resolve_operand(a, types) for a in @view args[6:end]] : NirNode[]
            return NirForeignCall(c_symbol, arg_ts, ret_t, cargs)
        elseif head === :boundscheck
            flag = (!isempty(args) && args[1] isa Bool) ? args[1] : nothing
            return NirBoundscheck(flag)
        elseif head === :throw_undef_if_not && length(args) == 2 && args[1] isa Symbol
            return NirThrowUndefIfNot(args[1], resolve_operand(args[2], types))
        elseif head === :leave
            return NirLeave(length(args))
        elseif head === :pop_exception
            return NirPopException()
        elseif head === :the_exception
            return NirTheException()
        elseif head === :gc_preserve_begin || head === :gc_preserve_end || head === :loopinfo
            return NirNoOp(head)
        else
            return NirUnsupported(head, stmt)
        end
    else
        return resolve_operand(stmt, types)
    end
end

"""Build the NIR boundary for one function's CodeInfo, positionally aligned with
`code_info.code` (`nir[i]` classifies `code_info.code[i]`). A pure function of the
CodeInfo: it runs BEFORE the context's analysis passes, which are themselves NIR
consumers, and can therefore also be run on a callee's CodeInfo where no context exists.
Every type on a node is Julia inference's own answer, widened once here — R3/R5 unaffected
(0 new `infer_value_type`/`get_concrete_wasm_type` call sites)."""
# formal(dev/formal/NirBuild.tla): classification is total (every statement kind maps to Known or Unsupported, never a silent no-op) and positionally aligned (nir[i] always describes code[i]); resolved identities and static types are computed exactly once, never re-derived by a consumer.
function build_nir(code_info::Core.CodeInfo)::Vector{NirStmt}
    code = code_info.code
    n = length(code)
    types = _widened_ssa_types(code_info, n)
    lines = _nir_lines(code_info, n)
    out = Vector{NirStmt}(undef, n)
    for i in 1:n
        stmt = code[i]
        # Unoptimized IR (may_optimize=false) assigns into a slot:
        # `Expr(:(=), SlotNumber(n), rhs)`. The assignment is ONE integer on the record;
        # `node` classifies the rhs, so every consumer sees the value-producing operation
        # itself rather than an envelope it has to unwrap by reading `.args`.
        slot = 0
        classified = stmt
        if stmt isa Expr && stmt.head === :(=) && length(stmt.args) >= 2 &&
           stmt.args[1] isa Core.SlotNumber
            slot = stmt.args[1].id
            classified = stmt.args[2]
        end
        out[i] = NirStmt(_nir_classify(classified, i, code_info, types),
                         types[i], lines[i], slot, stmt)
    end
    return out
end

"""Does `node` use `subject` — an SSA definition (`NirSSA`, matched by id) or a parameter
(`NirArgument`, matched by slot) — as an operand, transitively through its own operands?
ONE reference test covering every node kind. An `Expr`-shaped walk has to be written per
consumer, and the two that existed disagreed: `references_ssa` (context.jl) silently
misses PhiNode/PiNode operands, which the storage-relative pointer-escape proof depends
on seeing. A NirUnsupported node has no resolved operands, so its raw statement is walked:
an unrecognized consumer must never look like a non-consumer."""
function nir_uses(node::NirNode, subject::NirNode)::Bool
    _same(x) = (subject isa NirSSA && x isa NirSSA && x.id == subject.id) ||
               (subject isa NirArgument && x isa NirArgument && x.n == subject.n)
    _same(node) && return true
    _r(x) = x !== nothing && nir_uses(x, subject)
    node isa NirPi && return _r(node.value)
    node isa NirPhi && return any(_r, node.values)
    node isa NirPhiC && return any(_r, node.values)
    node isa NirReturn && return _r(node.value)
    node isa NirGotoIfNot && return _r(node.cond)
    node isa NirUpsilon && return _r(node.value)
    node isa NirThrowUndefIfNot && return _r(node.cond)
    node isa NirCall && return (node.callee isa NirNode && _r(node.callee)) || any(_r, node.operands)
    node isa NirInvoke && return any(_r, node.operands)
    node isa NirNew && return any(_r, node.operands)
    node isa NirForeignCall && return any(_r, node.operands)
    node isa NirUnsupported && return _raw_uses(node.raw, subject)
    return false
end

nir_refs_ssa(node::NirNode, id::Int)::Bool = nir_uses(node, NirSSA(id, Any))

function _raw_uses(x, subject::NirNode)::Bool
    subject isa NirSSA && x isa Core.SSAValue && return x.id == subject.id
    subject isa NirArgument && x isa Core.Argument && return x.n == subject.n
    x isa Expr && return any(a -> _raw_uses(a, subject), x.args)
    x isa Core.PiNode && return _raw_uses(x.val, subject)
    x isa Core.PhiNode && return any(i -> isassigned(x.values, i) && _raw_uses(x.values[i], subject),
                                     eachindex(x.values))
    (x isa Core.ReturnNode && isdefined(x, :val)) && return _raw_uses(x.val, subject)
    x isa Core.GotoIfNot && return _raw_uses(x.cond, subject)
    return false
end

"""True for the node kinds an `Expr` statement classifies to. compile_statement! emits
those through a per-statement FRAGMENT builder (the value they may leave on the stack is
then stored/coerced/dropped by one tail); the IR-node kinds — return/goto/phi/pi/enter/
upsilon/newvar — emit straight onto the caller's builder. The split is the statement
visitor's, not the boundary's, so it is stated here once instead of being re-derived as a
list of `isa` tests at the dispatch."""
_nir_from_expr(node::NirNode)::Bool =
    node isa NirCall || node isa NirInvoke || node isa NirNew || node isa NirForeignCall ||
    node isa NirBoundscheck || node isa NirThrowUndefIfNot || node isa NirLeave ||
    node isa NirPopException || node isa NirTheException || node isa NirNoOp ||
    node isa NirUnsupported

"""Reconstruct the raw statement array from `ctx.nir` — the ONE place a not-yet-NIR-aware
consumer (has_try_catch/find_try_regions/compile_call!/...) gets back exactly
`code_info.code`, without that consumer ever writing the identifier `code_info` itself."""
nir_raw_code(ctx) = Any[s.raw for s in ctx.nir]

"""The raw statement a NIR record's `node` classifies — the original statement, or its RHS
when the record is a slot assignment. The transitional hand-off to the consumers that still
take a raw `Expr` (compile_call!/compile_invoke!/is_passthrough_statement); it exists so
statements.jl never unwraps `Expr(:(=), …).args[2]` itself."""
nir_value_raw(s::NirStmt)::Any = s.slot > 0 ? s.raw.args[2] : s.raw

"""Resolve a RAW IR operand a not-yet-converted consumer still holds into its NirNode, with
the SSA types the boundary already computed. The bridge INTO the node world."""
nir_node(ctx, x)::NirNode = x isa NirNode ? x : resolve_operand(x, ctx.nir)

"""The inverse: a node back to the raw operand `Expr.args` carried. Transitional — it exists
only until the value channel itself takes a NirNode, and is deleted then. A Symbol literal is
re-quoted, as `Expr.args` carried it, so the channel does not mistake it for a binding."""
function nir_operand(node::NirNode)
    node isa NirSSA && return Core.SSAValue(node.id)
    node isa NirArgument && return Core.Argument(node.n)
    node isa NirSlot && return Core.SlotNumber(node.id)
    node isa NirGlobalRef && return GlobalRef(node.mod, node.name)
    # A Symbol or an IR-reference VALUE is re-quoted, exactly as `Expr.args` carried it, so
    # the raw-shaped consumer does not mistake a literal for a binding or an SSA reference.
    node isa NirLiteral && return (node.value isa Symbol || node.value isa Core.SSAValue ||
                                   node.value isa Core.Argument || node.value isa Core.SlotNumber) ?
        QuoteNode(node.value) : node.value
    error("nir_operand: $(nameof(typeof(node))) is not a value operand")
end
