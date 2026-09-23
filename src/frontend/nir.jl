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
# Quarantine tier (Julia-only; no dart Kernel equivalent, so no dart anchor): NirBoundscheck
# (Julia's bounds-check-elision IR, `Expr(:boundscheck, ...)`), NirThrowUndefIfNot,
# NirNewvar, NirNoOp (`:gc_preserve_begin`/`:gc_preserve_end`/`:loopinfo` — hints with no
# runtime effect), and NirUpsilon/NirPhiC (unoptimized-IR exception phis). Each carries a
# `parity(quarantine: …)` anchor naming why Kernel has no counterpart. They are CLASSIFIED, not `NirUnsupported`: statements.jl lowers
# every one of them, and dev/formal/NirBuild.tla's claim (5) makes "NirUnsupported ⇒
# reject" a consumer obligation, so a construct with a real lowering must never arrive
# as Unsupported.

export NirNode, NirStmt, NirSSA, NirArgument, NirSlot, NirGlobalRef, NirLiteral,
       NirPhi, NirPi, NirGoto, NirGotoIfNot, NirReturn, NirEnter, NirLeave,
       NirTheException, NirPopException, NirCall, NirInvoke, NirNew, NirForeignCall,
       NirBoundscheck, NirThrowUndefIfNot, NirNewvar, NirNoOp, NirUpsilon, NirPhiC,
       NirUnsupported,
       build_nir, NirBody, nir_body, nir_literal_values, nir_slot_types, nir_expr_operands, nir_direct_operands, nir_call, nir_text, nir_const, nir_quoted, nir_new, nir_retarget_invoke!,
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

"""`Expr(:leave, refs...)` — `enters` are the operands naming the `Core.EnterNode`
statements whose scopes are left (a `nothing` operand stays a `NirLiteral(nothing)`)."""
struct NirLeave <: NirNode
    enters::Vector{NirNode}
end

struct NirTheException <: NirNode end

"""`Expr(:pop_exception, ref)` — `enter` names the `Core.EnterNode` whose exception is
popped, `nothing` when the statement carried no operand."""
struct NirPopException <: NirNode
    enter::Union{NirNode,Nothing}
end

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
equally defensive (see resolve_invoke_method's docstring).

`callee` is the statement's OWN callee operand (`args[2]`), resolved exactly like
NirCall's — a function object when statically known, a NirNode when the invoked value is
an SSA/argument (a closure VALUE invoked through its known MethodInstance), `nothing` when
the statement carried none. It is NOT recoverable from `mi.specTypes.parameters[1]`: that
names the closure's TYPE for a value callee, so a consumer gating on "is the callee a
function object" answers differently — the closed-world collector's re-specialization gate
(trimcollect.jl) does exactly that, and would flip from decline to accept."""
struct NirInvoke <: NirNode
    mi::Union{Core.MethodInstance,Nothing}
    method::Union{Core.Method,Nothing}
    callee::Any
    operands::Vector{NirNode}
end

"""`%new(T, fields...)`, with `T` resolved ONCE here from whichever operand shape named it.

`type_kind` is HOW the type was named and nothing else — `:literal` (a type literal or
GlobalRef), `:ssa` (a `Core.apply_type` result, read through the SSA's own `Type{T}`),
`:argument` (the constructor's own `#self#`, read through the `:new` statement's own
inferred type), `:unknown` (no recognized shape). It is never overwritten by the outcome:
`type_resolved` is the separate fact of whether resolution SUCCEEDED. Keeping them apart
matters — a consumer that wants "was this type written down literally" (the closed-world
collector's runtime-class observation and the F3 captor-field walk both do, because the
raw code they replace saw nothing for the SSA-named case) cannot get it from a `type_kind`
that reports `:literal` for every success.

When `type_resolved` is false, `T === Any` and `type_detail` carries the widened inferred
type the attempt consulted (the reject's detail); `type_detail` is `Any` otherwise.
`field_types` is `fieldtype.(T, 1:fieldcount(T))` when `T` is concrete, else empty — never
throws on an exotic `T`. `type_operand` is the operand that named the type (an SSA use when
`type_kind === :ssa`), resolved like any other operand."""
struct NirNew <: NirNode
    T::Type
    field_types::Vector{Type}
    type_operand::NirNode
    operands::Vector{NirNode}
    type_kind::Symbol
    type_resolved::Bool
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
share a node kind.
parity(quarantine: Core.NewvarNode — Kernel declares a variable and its initializer in one
VariableDeclaration (pkg/kernel/lib/src/ast/variables.dart:2437); unoptimized Julia IR splits the declaration out.)"""
struct NirNewvar <: NirNode
    slot::Int
end

"""Julia-only, quarantine tier: an IR head that is a HINT with no runtime effect —
`:gc_preserve_begin`/`:gc_preserve_end` (WasmGC's host collector owns liveness) and
`:loopinfo` (`@simd`). Classified for the same reason as NirNewvar. `operands` are the
values the hint names (the preserved objects; the `:gc_preserve_begin` token an end closes).
parity(quarantine: GC-liveness and loop hints — Kernel has no gc_preserve or @simd node.)"""
struct NirNoOp <: NirNode
    kind::Symbol
    operands::Vector{NirNode}
end

"""Julia-only, quarantine tier: `Core.UpsilonNode`, the store half of unoptimized IR's
exception phi (its value is written into the associated PhiC's local).
parity(quarantine: unoptimized-IR exception phi — a catch-visible Dart variable is an ordinary
Kernel local, so no store/read pair exists.)"""
struct NirUpsilon <: NirNode
    value::Union{NirNode,Nothing}
end

"""Julia-only, quarantine tier: `Core.PhiCNode`, the read half of unoptimized IR's
exception phi. `values` are the Upsilon statements that write it.
parity(quarantine: unoptimized-IR exception phi, the read half of NirUpsilon's store.)"""
struct NirPhiC <: NirNode
    values::Vector{NirNode}
end

"""Any head outside the census above. A consumer MUST route this to `record_unsupported!`
(never silently) — never reinterpreted as a no-op. `operands` are every value operand the
statement contains, nested expressions included, so a use query never mistakes an
unrecognized consumer for a non-consumer; `raw` is the original statement, for the
diagnostic's detail only."""
struct NirUnsupported <: NirNode
    kind::Symbol
    operands::Vector{NirNode}
    raw::Any
end

"""One statement's NIR record. `julia_type` is the type of the VALUE this statement
produces (`widenconst(code_info.ssavaluetypes[i])`, `Any` when absent). `line` is its
source line decoded from the CodeInfo's DebugInfo (0 when the IR carries none). `slot` is
the SlotNumber id when the statement is unoptimized IR's `Expr(:(=), SlotNumber(n), rhs)`
assignment and 0 otherwise — in that case `node` classifies the RHS, so a consumer sees
the value-producing operation directly and the assignment is one integer beside it."""
struct NirStmt
    node::NirNode
    julia_type::Type
    line::Int32
    slot::Int
end

# ============================================================================
# resolve_invoke_method / resolve_invoke_mi — the shared MethodInstance/CodeInstance→Method
# resolution. invoke.jl resolves this same shape at ~4 duplicated sites (e.g. ~line 800-808:
# `mi_or_ci = expr.args[1]; mi = mi_or_ci isa MethodInstance ? mi_or_ci : mi_or_ci isa
# CodeInstance ? mi_or_ci.def : nothing`). Those sites go when invoke.jl is converted and
# reads `NirInvoke.mi` instead; dev/formal/NirBuild.tla's claim (3) is exactly the premise
# that lets them: every duplicate would have resolved the SAME identity.
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
the flat `codelocs` array with a compressed `Core.DebugInfo`; this is the one decode.
parity(code_generator.dart:190 setSourceMapFileOffset): the source position dart reads from
TreeNode.fileOffset (pkg/kernel/lib/src/ast/misc.dart:71); Julia stores it in Core.DebugInfo."""
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
backward for, computed once here so a consumer reads `ctx.nir[idx].line`.

MEASURED (2026-09-08): every line is 0 for the IR WT actually compiles, because
`get_typed_ir` calls `Base.code_typed` with the DEFAULT `debuginfo=:none`, whose CodeInfo
carries an empty `Core.DebugInfo` (no codelocs, no linetable, no edges). The same input
starves diagnostics.jl's `_stmt_line`/`stmt_frames`, so a located diagnostic falls back to
the method's definition line and its inline chain is empty. Asking for `debuginfo=:source`
in ir.jl restores both (verified: 7/7 statements lined, a real 3-frame chain) — a change to
the one inference path, not to this decode.
parity(code_generator.dart:190 setSourceMapFileOffset): one source line per node, read once."""
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
vector at all — an unanalyzed CodeInfo carries a statement COUNT there instead).
parity(code_generator.dart:135 getStaticType): every node's type read once through one context."""
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

"""Julia inference's type for every slot of one CodeInfo (slot 1 = `#self#`, then the
parameters, then the locals), widened once here exactly as `_widened_ssa_types` widens the
SSA types; `Any` wherever inference had nothing, empty when the CodeInfo carries no slot
table — the source contract an `Argument`/`SlotNumber` operand is typed by.
parity(code_generator.dart:135 getStaticType): a variable's type read once through one context."""
function nir_slot_types(code_info::Core.CodeInfo)::Vector{Type}
    slottypes = code_info.slottypes
    slottypes isa Vector || return Type[]
    out = Vector{Type}(undef, length(slottypes))
    fill!(out, Any)
    for i in eachindex(slottypes)
        T = slottypes[i]
        wT = T isa Type ? T : Core.Compiler.widenconst(T)
        wT isa Type && (out[i] = wT)
    end
    return out
end

# parity(code_generator.dart:135 getStaticType): an SSA operand's type is its defining node's.
_nir_ssa_type(types::Vector{Type}, id::Int)::Type = (1 <= id <= length(types)) ? types[id] : Any
_nir_ssa_type(nir::Vector{NirStmt}, id::Int)::Type = (1 <= id <= length(nir)) ? nir[id].julia_type : Any

"""Resolve one IR operand (an Expr arg, a PhiNode value, a ReturnNode/GotoIfNot payload)
into a NirNode. Total: the final `else` wraps anything unrecognized as NirLiteral rather
than throwing. `types` supplies each SSA id's Julia type — the widened `ssavaluetypes`
during `build_nir` (the `Vector{NirStmt}` method of `_nir_ssa_type` serves a consumer that
already holds the built records)."""
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

"""A `:call`'s callee resolved to the function it statically names, else kept as its operand
node. Beyond `resolve_call_callee`, a callee that is a VALUE with a static identity is that
identity: an SSA use whose defining statement is a global reference (unoptimized IR's
`%1 = Base.add_int; (%1)(x, y)`) or whose inferred type is a `Core.Const`, and an argument
whose inferred slot type is a singleton function type (`mapreduce_first(f::typeof(length),
…)`'s `f(x)`) — a value of a singleton type IS its instance, Julia's own answer.
parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): the call node carries
its resolved target, resolved once."""
function _resolve_nircall_callee(x, code_info, types, slot_types::Vector{Type})::Any
    if x isa Core.SSAValue && 1 <= x.id <= length(code_info.code)
        def = code_info.code[x.id]
        def isa GlobalRef && return resolve_call_callee(def, types)
        ssatypes = code_info.ssavaluetypes
        T = (ssatypes isa Vector && x.id <= length(ssatypes)) ? ssatypes[x.id] : nothing
        T isa Core.Const && return T.val
    elseif x isa Core.Argument && 1 <= x.n <= length(slot_types)
        T = slot_types[x.n]
        (T isa DataType && Base.issingletontype(T) && T <: Function) && return T.instance
    end
    return resolve_call_callee(x, types)
end

"""The callee OBJECT a NirCall/NirInvoke names, or `nothing` when there is none: a `NirNode`
callee is dynamic (an SSA/argument value with no static identity), and a `GlobalRef` that
survived the boundary's resolution was unbound. A callee the IR embeds as the object itself
is neither a GlobalRef nor a QuoteNode, so the boundary classifies it as a literal operand —
unwrapped here, and only when it is callable.
parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): Kernel's call node carries
its resolved target; this reads back the target `resolve_call_callee` resolved once."""
function _nir_callee_object(@nospecialize(callee))::Any
    callee isa NirLiteral && return (callee.value isa Function ? callee.value : nothing)
    (callee isa NirNode || callee isa GlobalRef || callee === nothing) && return nothing
    return callee
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
parity(quarantine: the C symbol of a Julia `:foreigncall`, whose operand shape differs
between 1.12 and 1.13; dart resolves FFI natives in the CFE ffi transformer, before Kernel reaches codegen.)
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

# parity(code_generator.dart:1637 visitConstructorInvocation): the field list a ConstructorInvocation
# (pkg/kernel/lib/src/ast/expressions.dart:2907) initializes, read from the class once.
_nir_field_types(T)::Vector{Type} =
    (T isa Type && isconcretetype(T)) ?
        (try; Type[fieldtype(T, k) for k in 1:fieldcount(T)]; catch; Type[]; end) : Type[]

"""Build a `NirNew` from an already-known concrete type and raw field operands — the entry
calls.jl uses when it SYNTHESIZES a field-wise constructor (there is no `Expr(:new, ...)`
in the IR to classify, so the node is built directly instead of a raw Expr being faked).
parity(code_generator.dart:1637 visitConstructorInvocation): a synthesized field-wise constructor
is the same node kind as a literal `%new`."""
nir_new(T::Type, args::AbstractVector{<:NirNode})::NirNew =
    NirNew(T, _nir_field_types(T), NirLiteral(T), NirNode[args...], :literal, true, Any)

"""The constant an operand names — a literal's value — or the operand node itself when it
is a runtime value (an SSA use, an argument, a slot) or a global binding.
parity(pkg/kernel/lib/src/ast/expressions.dart:5070 ConstantExpression): a constant operand
carries its constant."""
nir_const(@nospecialize(x))::Any = x isa NirLiteral ? x.value : x

"""True for a literal Julia's IR had to quote — a value that is not self-quoting (a Symbol, a
Module, a TypeName, an IR reference, …): Julia embeds constants with `Base.quoted`, which
wraps exactly the values `Base.is_self_quoting` rejects, so this is Julia's own rule.
parity(pkg/kernel/lib/src/ast/expressions.dart:5070 ConstantExpression): a constant operand
carries its constant."""
nir_quoted(x)::Bool = x isa NirLiteral && !Base.is_self_quoting(x.value)

"""A call codegen builds from an operand that names its callee — `invoke_in_world(w, f,
xs...)` calls `f` — with the callee resolved as the boundary resolves a written call's: a
bound global is its object, an unbound one stays a `GlobalRef`, anything else is the operand.
parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): a call node carries its
resolved target."""
function nir_call(callee::NirNode, operands::AbstractVector{<:NirNode})::NirCall
    target = callee isa NirGlobalRef ?
        (callee.bound ? callee.value : GlobalRef(callee.mod, callee.name)) : callee
    return NirCall(target, NirNode[operands...])
end

"""`%new`'s type operand → `(T, naming shape, resolved?, detail)`. A literal/GlobalRef names
`T` outright. A `Core.apply_type` result names it through the SSA's OWN inferred type, which
must be a `Type{T}` — read from the RAW lattice element, exactly as compile_new! read
`ssavaluetypes[id]` before this boundary existed, so the accept/reject frontier is
unchanged. A constructor body's `#self#` (`Core.Argument`) names it through the `:new`
statement's own inferred type. The shape is reported whether or not resolution succeeded.
parity(pkg/kernel/lib/src/ast/expressions.dart:2907 ConstructorInvocation): Kernel names the
constructed class on the node; Julia names it through an operand this resolves once."""
function _resolve_new_type(type_ref, stmt_idx::Int, code_info)::Tuple{Type,Symbol,Bool,Type}
    _raw_ssa(i) = begin
        ssatypes = code_info.ssavaluetypes
        (ssatypes isa Vector && 1 <= i <= length(ssatypes)) ? ssatypes[i] : Any
    end
    _widen(t) = (t isa Type ? t : (try; Core.Compiler.widenconst(t); catch; Any; end))
    if type_ref isa GlobalRef || type_ref isa DataType || type_ref isa Type ||
       (type_ref isa QuoteNode && type_ref.value isa Type)
        # A literal that does not name a Type resolves to `Any` and still counts as
        # resolved — exactly as before this boundary existed, the value was handed on and
        # failed downstream rather than taking one of the two type-instability rejects.
        return (_resolve_type_operand(type_ref), :literal, true, Any)
    elseif type_ref isa Core.SSAValue
        ssa_type = _raw_ssa(type_ref.id)
        if ssa_type isa DataType && ssa_type <: Type && length(ssa_type.parameters) >= 1
            P = ssa_type.parameters[1]
            P isa Type && return (P, :ssa, true, Any)
        end
        return (Any, :ssa, false, _widen(ssa_type))
    elseif type_ref isa Core.Argument
        new_ssa_type = _raw_ssa(stmt_idx)
        if new_ssa_type isa DataType && isconcretetype(new_ssa_type) && isstructtype(new_ssa_type)
            return (new_ssa_type, :argument, true, Any)
        end
        return (Any, :argument, false, _widen(new_ssa_type))
    end
    return (Any, :unknown, false, Any)
end

"""Every value operand inside an unrecognized expression, nested expressions flattened in
order — what a use query needs from a statement no arm classified.
parity(quarantine: the operand census of a Julia Expr head with no Kernel counterpart.)"""
function _nir_nested_operands(ex::Expr, types)::Vector{NirNode}
    out = NirNode[]
    for a in ex.args
        a isa Expr ? append!(out, _nir_nested_operands(a, types)) : push!(out, resolve_operand(a, types))
    end
    return out
end

"""Classify one raw CodeInfo statement into a NirNode. Total (never throws) — any Expr
head outside the census, or any statement shape not otherwise recognized, becomes
NirUnsupported/NirLiteral rather than crashing build_nir."""
function _nir_classify(stmt, i::Int, code_info, types::Vector{Type},
                       slot_types::Vector{Type})::NirNode
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
            callee = _resolve_nircall_callee(args[1], code_info, types, slot_types)
            cargs = NirNode[resolve_operand(a, types) for a in @view args[2:end]]
            return NirCall(callee, cargs)
        elseif head === :invoke && !isempty(args)
            mi_or_ci = args[1]
            callee = length(args) >= 2 ? resolve_call_callee(args[2], types) : nothing
            cargs = length(args) >= 3 ? NirNode[resolve_operand(a, types) for a in @view args[3:end]] : NirNode[]
            return NirInvoke(resolve_invoke_mi(mi_or_ci), resolve_invoke_method(mi_or_ci),
                             callee, cargs)
        elseif head === :new && !isempty(args)
            T, kind, resolved, detail = _resolve_new_type(args[1], i, code_info)
            cargs = length(args) >= 2 ? NirNode[resolve_operand(a, types) for a in @view args[2:end]] : NirNode[]
            return NirNew(T, _nir_field_types(T), resolve_operand(args[1], types), cargs,
                          kind, resolved, detail)
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
            return NirLeave(NirNode[resolve_operand(a, types) for a in args])
        elseif head === :pop_exception
            return NirPopException(isempty(args) ? nothing : resolve_operand(args[1], types))
        elseif head === :the_exception
            return NirTheException()
        elseif head === :gc_preserve_begin || head === :gc_preserve_end || head === :loopinfo
            return NirNoOp(head, NirNode[resolve_operand(a, types) for a in args])
        else
            return NirUnsupported(head, _nir_nested_operands(stmt, types), stmt)
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
(0 new `infer_value_type`/`get_concrete_wasm_type` call sites).
formal(dev/formal/NirBuild.tla): classification is total (every statement kind maps to Known or Unsupported, never a silent no-op) and positionally aligned (nir[i] always describes code[i]); resolved identities and static types are computed exactly once, never re-derived by a consumer.
"""
function build_nir(code_info::Core.CodeInfo)::Vector{NirStmt}
    code = code_info.code
    n = length(code)
    types = _widened_ssa_types(code_info, n)
    slot_types = nir_slot_types(code_info)
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
        out[i] = NirStmt(_nir_classify(classified, i, code_info, types, slot_types),
                         types[i], lines[i], slot)
    end
    return out
end

"""One function body at the boundary: its statements, its slots' inferred types, and its
source-location table — everything codegen reads from Julia's typed IR, built once.
parity(code_generator.dart:77 typeContext): the one context a function's nodes are read through."""
struct NirBody
    stmts::Vector{NirStmt}
    slot_types::Vector{Type}
    debuginfo::Union{Core.DebugInfo, Nothing}
end

"""The NIR body of one typed CodeInfo — `build_nir`, `nir_slot_types` and the DebugInfo.
parity(code_generator.dart:77 typeContext): the one context a function's nodes are read through."""
nir_body(code_info::Core.CodeInfo)::NirBody =
    NirBody(build_nir(code_info), nir_slot_types(code_info), code_info.debuginfo)

"""Every literal value one statement carries as `Expr.args` did — an expression's literal
operands (its literal callee and a `%new`'s literal type included) and a
`throw_undef_if_not`'s variable name, a slot's literal right-hand side, or the statement
itself when it is a literal. The constants a module must materialize before its function
indices freeze (compile.jl's long-string pre-pass).
parity(constants.dart:454 Constants.ensureConstant): constants are collected before codegen."""
function nir_literal_values(rec::NirStmt)::Vector{Any}
    node = rec.node
    ops = rec.slot > 0 ? nir_direct_operands(rec) :
          _nir_from_expr(node) ? nir_expr_operands(node) : NirNode[node]
    out = Any[x.value for x in ops if x isa NirLiteral]
    rec.slot == 0 && node isa NirThrowUndefIfNot && push!(out, node.var)
    return out
end

"""Does `node` use `subject` — an SSA definition (`NirSSA`, matched by id) or a parameter
(`NirArgument`, matched by slot) — as an operand, transitively through its own operands?
ONE reference test covering every node kind. An `Expr`-shaped walk has to be written per
consumer, and the two that existed disagreed: `references_ssa` (context.jl) silently
misses PhiNode/PiNode operands, which the storage-relative pointer-escape proof depends
on seeing. A NirUnsupported node carries every operand it contains, nested ones included:
an unrecognized consumer must never look like a non-consumer.
parity(quarantine: SSA use query — Kernel is a tree whose values are variables read by
VariableGet (pkg/kernel/lib/src/ast/expressions.dart:203); Julia IR names values by SSA id.)"""
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
    node isa NirInvoke && return (node.callee isa NirNode && _r(node.callee)) || any(_r, node.operands)
    node isa NirNew && return _r(node.type_operand) || any(_r, node.operands)
    node isa NirForeignCall && return any(_r, node.operands)
    node isa NirLeave && return any(_r, node.enters)
    node isa NirPopException && return _r(node.enter)
    node isa NirNoOp && return any(_r, node.operands)
    node isa NirUnsupported && return any(_r, node.operands)
    return false
end

# parity(quarantine: SSA use query by id, the NirSSA case of nir_uses.)
nir_refs_ssa(node::NirNode, id::Int)::Bool = nir_uses(node, NirSSA(id, Any))

"""The value operands an expression-kind node reads, in `Expr.args` order: the dynamic callee
of a call/invoke first, the type operand of a `%new`, then the arguments. Empty for the IR
node kinds (return/goto/phi/pi/…), whose operands are their own fields.
parity(quarantine: the operand list of a Julia Expr statement, the SSA-use census Kernel's
tree shape makes unnecessary.)"""
function nir_expr_operands(node::NirNode)::Vector{NirNode}
    if node isa NirCall || node isa NirInvoke
        return node.callee isa NirNode ? NirNode[node.callee; node.operands] : node.operands
    end
    node isa NirNew && return NirNode[node.type_operand; node.operands]
    node isa NirForeignCall && return node.operands
    node isa NirLeave && return node.enters
    node isa NirPopException && return node.enter === nothing ? NirNode[] : NirNode[node.enter]
    node isa NirNoOp && return node.operands
    node isa NirThrowUndefIfNot && return NirNode[node.cond]
    node isa NirUnsupported && return node.operands
    return NirNode[]
end

"""One NIR record printed in Julia's IR notation (`%3`, `_2`, `callee(args…)`, `goto #7 if
not %5`, …) — what a located diagnostic shows as the statement codegen was compiling. A
slot assignment prints as `_n = …`; an unclassified statement prints its source form.
parity(target.dart:719 DiagnosticReporter): a located report names the node it was raised on."""
function nir_text(rec::NirStmt)::String
    body = _nir_text(rec.node)
    return rec.slot > 0 ? string("_", rec.slot, " = ", body) : body
end

# parity(target.dart:719 DiagnosticReporter): one node's printed form (see nir_text).
function _nir_text(x)::String
    x === nothing && return "#undef"
    x isa NirSSA && return string("%", x.id)
    (x isa NirArgument) && return string("_", x.n)
    (x isa NirSlot) && return string("_", x.id)
    x isa NirGlobalRef && return string(x.mod, ".", x.name)
    x isa NirLiteral && return repr(x.value)
    _args(ops) = join((_nir_text(o) for o in ops), ", ")
    _callee(c) = c isa NirNode ? _nir_text(c) : string(c)
    x isa NirCall && return string(_callee(x.callee), "(", _args(x.operands), ")")
    x isa NirInvoke && return string("invoke ", x.mi === nothing ? _callee(x.callee) : string(x.mi),
                                     "(", _args(x.operands), ")")
    x isa NirNew && return string("%new(", x.T, isempty(x.operands) ? "" : ", ", _args(x.operands), ")")
    x isa NirForeignCall && return string("foreigncall(", repr(x.c_symbol),
                                          isempty(x.operands) ? "" : ", ", _args(x.operands), ")")
    x isa NirReturn && return string("return ", _nir_text(x.value))
    x isa NirGoto && return string("goto #", x.target)
    x isa NirGotoIfNot && return string("goto #", x.target, " if not ", _nir_text(x.cond))
    x isa NirPhi && return string("φ (", join((string("#", e, " => ", _nir_text(v))
                                              for (e, v) in zip(x.edges, x.values)), ", "), ")")
    x isa NirPi && return string("π (", _nir_text(x.value), ", ", x.typ, ")")
    x isa NirEnter && return string("enter #", x.catch_target)
    x isa NirLeave && return string("leave ", _args(x.enters))
    x isa NirPopException && return string("pop_exception ", _nir_text(x.enter))
    x isa NirTheException && return "the_exception"
    x isa NirBoundscheck && return string("boundscheck(", x.flag === nothing ? "" : x.flag, ")")
    x isa NirThrowUndefIfNot && return string("throw_undef_if_not(", repr(x.var), ", ", _nir_text(x.cond), ")")
    x isa NirNewvar && return string("newvar _", x.slot)
    x isa NirNoOp && return string(x.kind, "(", _args(x.operands), ")")
    x isa NirUpsilon && return string("ϒ (", _nir_text(x.value), ")")
    x isa NirPhiC && return string("φᶜ (", _args(x.values), ")")
    x isa NirUnsupported && return string(x.raw)
    return string(x)
end

"""The operands one statement lists directly, as its `Expr.args` did: an expression's
operands (`nir_expr_operands`), or — for an assignment into a slot — the assigned value
when it is itself an operand rather than an expression. Empty for the IR node kinds
(return/goto/phi/pi/…), whose operands are their own fields.
parity(quarantine: the operand list of a Julia Expr statement, the SSA-use census Kernel's
tree shape makes unnecessary.)"""
function nir_direct_operands(rec::NirStmt)::Vector{NirNode}
    node = rec.node
    if rec.slot > 0
        return (node isa NirSSA || node isa NirArgument || node isa NirSlot ||
                node isa NirGlobalRef || node isa NirLiteral) ? NirNode[node] : NirNode[]
    end
    return _nir_from_expr(node) ? nir_expr_operands(node) : NirNode[]
end

"""True for the node kinds an `Expr` statement classifies to. compile_statement! emits
those through a per-statement FRAGMENT builder (the value they may leave on the stack is
then stored/coerced/dropped by one tail); the IR-node kinds — return/goto/phi/pi/enter/
upsilon/newvar — emit straight onto the caller's builder. The split is the statement
visitor's, not the boundary's, so it is stated here once instead of being re-derived as a
list of `isa` tests at the dispatch.
parity(code_generator.dart:714 translateStatement, :665 translateExpression): the statement/expression split."""
_nir_from_expr(node::NirNode)::Bool =
    node isa NirCall || node isa NirInvoke || node isa NirNew || node isa NirForeignCall ||
    node isa NirBoundscheck || node isa NirThrowUndefIfNot || node isa NirLeave ||
    node isa NirPopException || node isa NirTheException || node isa NirNoOp ||
    node isa NirUnsupported

"""Re-target statement `i`'s `:invoke` at `mi` — the ONE write into an invoke's target
operand. The closed-world collector (trimcollect.jl) rebuilds an explicit invoke's
MethodInstance from the concrete call-site types when Julia left it abstract, and the
collected IR must keep agreeing with the edge it hands to inference (the planner builds its
NIR from that CodeInfo again), so BOTH the CodeInfo's statement and the record's NirInvoke
are rewritten here — at the boundary, rather than a consumer splicing `Expr.args` behind its
back. Loud on a statement that is not an `:invoke`.
parity(translator.dart:115 directCallMetadata): the whole-program analysis's per-call-site target,
recorded on the node codegen reads (dart: TFA's DirectCallMetadata, keyed by the Kernel node)."""
function nir_retarget_invoke!(code_info::Core.CodeInfo, nir::Vector{NirStmt}, i::Int,
                              mi::Core.MethodInstance)::Nothing
    s = nir[i]
    node = s.node
    node isa NirInvoke || error(
        "nir_retarget_invoke!: statement $i is a $(nameof(typeof(node))), not an :invoke")
    stmt = code_info.code[i]
    s.slot > 0 && (stmt = stmt.args[2])   # a slot assignment's right-hand side
    stmt.args[1] = mi
    nir[i] = NirStmt(NirInvoke(mi, resolve_invoke_method(mi), node.callee, node.operands),
                     s.julia_type, s.line, s.slot)
    return nothing
end

