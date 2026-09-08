# Julia IR Handling
# Interface to Julia's typed intermediate representation

export get_typed_ir

"""
    get_typed_ir(f, arg_types)

Get Julia's typed IR (SSA form) for a function with given argument types.
Returns the CodeInfo object from code_typed.
"""
# P5-trim: when a trim collection is active (compile_module discovery=:trim),
# every (f, arg_types) the pipeline asks about is served the collection's
# PAIRED CodeInfo — one consistent world, overlays applied, no re-inference.
const TRIM_IR_CACHE = Ref{Union{Nothing, IdDict{Any, Tuple{Core.CodeInfo, Any}}}}(nothing)

# ONE inference path. Every typed IR WasmTarget consumes comes from the
# WasmInterpreter (overlays applied, WT's constant-evaluation rule in force):
# the closed-world plan and any standalone query see the SAME IR for the same
# function. (A `nothing` default once ran Julia's native interpreter here, and
# a standalone dump differed from the plan's IR for the same function — hiding
# a branch the plan compiled.) `interp` exists to share one instance within a
# compilation; it is never a different kind of interpreter.
function get_typed_ir(f, arg_types::Tuple; optimize::Bool=true,
                      interp::WasmInterpreter=get_wasm_interpreter())::Tuple{Core.CodeInfo, Any}
    cache = TRIM_IR_CACHE[]
    if cache !== nothing
        hit = get(cache, (f, arg_types), nothing)
        hit !== nothing && return hit[1], hit[2]
    end
    results = Base.code_typed(f, arg_types; optimize=optimize, interp=interp)

    if isempty(results)
        error("No method found for $f with types $arg_types")
    end

    # Return the first (and usually only) result
    code_info, return_type = results[1]
    return code_info, return_type
end

"""
    get_typed_ir(sig::Type{<:Tuple}) -> Vector{Pair{CodeInfo, Any}}

The same one path for a full signature (function type first), as a closure body reached
through an `invoke`'s `MethodInstance.specTypes` is: every match, inferred by the
WasmInterpreter.
"""
function get_typed_ir(sig::Type{<:Tuple}; optimize::Bool=true,
                      interp::WasmInterpreter=get_wasm_interpreter())::Vector
    return Base.code_typed_by_type(sig; optimize=optimize, interp=interp)
end

"""
    infer_return_type(f, argtypes) -> Type

The return type of `f(::argtypes...)` under the one inference path (overlays applied): the
question a box-capture join asks about a write's value. `Any` when inference fails.
"""
function infer_return_type(@nospecialize(f), argtypes::Tuple;
                           interp::WasmInterpreter=get_wasm_interpreter())::Type
    return try
        Base.infer_return_type(f, Tuple{argtypes...}; interp=interp)
    catch
        Any
    end
end

"""
    _collect_reachable_ir_types(function_data) -> Set{DataType}

Phase 12B — the CLOSED-WORLD type collector (dart class_info.dart:583-690:
ClassIdNumbering numbers every class of the component ONCE, before codegen, with no
second pass). Walks every function's typed-IR ssa/arg/return types and decomposes
Unions, returning EVERY concrete kind reachable from the IR that can carry a classId —
structs, closures, `Core.Box`, and primitives (`Char`, `Int128`, a user `primitive
type`, …) — so `assign_type_ids!` numbers the whole world in one DFS and
`ensure_type_id!` never needs to allocate one afterwards. PURE COLLECTION —
registration stays lazy (eager registration reorders field resolution and forks
layouts); a collected type registered later receives its pre-assigned id.

Lives here, not compile.jl: like `get_typed_ir`, this is the boundary's OWN input
side — the one place that reads a raw `CodeInfo`'s statements directly (R29a/R29b
exempt ir.jl for exactly that reason).

`Memory`/`MemoryRef` ARE admitted (they are `isstructtype` and reachable — e.g. a
type-value `getfield(Memory{UInt8}, :layout)` inside `copy(::Dict)`'s native
`unsafe_copyto!`, which reads a real classId here even though it never boxes a
`Memory` VALUE); WT lowers them to a wasm ARRAY with no classId struct field, so
`dispatch.jl`'s `_classid_dispatchable` carries its OWN, narrower exclusion for the
one place that matters — treating one as a selector-table dispatch axis, which
needs an actual struct to downcast to (the `_la_sub` regression this guards).

A second walk covers what the INFERRED types above miss: a literal VALUE embedded
directly in a statement's args (constant-folded, never boxed into its own SSA slot —
e.g. inference SROAs `Any[1, 2, 3]` into `Base.getfield((1, 2, 3), i)`, so the tuple
`Tuple{Int64,Int64,Int64}` never appears as any ssa/arg/return type) and an
effectively-final GLOBAL BINDING's bound value (`const D = Dict(...)`; typed IR reads
its fields directly off `GlobalRef(Main, :D)` without ever materializing a
`Dict{...}`-typed SSA value, the same constant-propagation Julia's own inliner uses —
`_lower_getglobal!`, builtins.jl, resolves a GlobalRef to its value the same
way) AND a function passed as ordinary DATA (`Core._apply_iterate(Base.iterate,
Core.tuple, itr)` — a splat lowering — passes the `iterate` FUNCTION itself as `args[2]`,
which needs a classId the same as any other boxed value). IR-structural nodes
(SSAValue, PhiNode, GlobalRef itself, …) are not values and are excluded; the ONE
callee position (`args[1]` of a `:call`, `args[1:2]` of an `:invoke` — the
CodeInstance/MethodInstance plus the GlobalRef naming the target) is skipped instead,
since a statically-dispatched callee is NEVER boxed/isa-checked through
`ensure_type_id!` — admitting it would number a class nothing consumes.

Also walks `slottypes`: an ARGUMENT slot's own type — e.g. a trailing `Vararg{Any,N}`
parameter packs into ONE Tuple-typed slot (`Base.kwerr(kw, args::Vararg{Any,N})`) — is
neither an ssavaluetype (it's not an SSA temporary) nor in a call-site's flattened
argument types; `slottypes` is the only place it appears. And recurses into a
registered struct's OWN field types (a Tuple's own elements included): a field can
itself be a concrete kind that needs a classId nobody else names — e.g. a closure
struct's captured predicate field `f::typeof(iseven)` — so it is not reachable via any
ssa/arg/slot type on its own.
"""
const _IR_META_TYPES = Set{DataType}([
    Expr, Core.SSAValue, Core.Argument, GlobalRef, Core.PhiNode, Core.PhiCNode,
    Core.UpsilonNode, Core.GotoNode, Core.GotoIfNot, Core.ReturnNode, LineNumberNode,
    Core.NewvarNode, Core.SlotNumber, Core.MethodInstance, Core.CodeInstance, Core.CodeInfo,
])

"""
    _collector_static_type(arg, code_info) -> Type

A static, `ctx`-free echo of `infer_value_type` (context.jl) for the branches that
don't need one — used ONLY to reconstruct the composite type `_lower_tuple!` (the ONE
`Core.tuple` lowering) will give a `Core.tuple(...)` call's RESULT, so the collector can
admit that exact composite. SSAValue/Argument read the raw (unrefined) ssa/slot type,
which is what `ctx.ssa_types`/`ctx.arg_types` are themselves seeded from.
"""
function _collector_static_type(@nospecialize(arg), code_info)::Type
    v = arg isa QuoteNode ? arg.value : arg
    if v isa Core.SSAValue
        ssats = code_info.ssavaluetypes
        return (ssats isa Vector && 1 <= v.id <= length(ssats)) ?
               Core.Compiler.widenconst(ssats[v.id]) : Any
    elseif v isa Core.Argument
        slots = code_info.slottypes
        return (slots isa Vector && 1 <= v.n <= length(slots)) ?
               Core.Compiler.widenconst(slots[v.n]) : Any
    elseif v isa GlobalRef
        (isdefined(v.mod, v.name) && isconst(v.mod, v.name)) || return Any
        gv = getfield(v.mod, v.name)
        return gv isa Type ? Type{gv} : typeof(gv)
    elseif v isa Type
        return Type{v}
    elseif v === nothing
        return Nothing
    else
        return typeof(v)
    end
end

function _collect_reachable_ir_types(function_data)::Set{DataType}
    out = Set{DataType}()
    seen = Set{Any}()
    function reg!(@nospecialize(T))
        T === nothing && return
        T in seen && return
        push!(seen, T)
        if T isa Union
            reg!(T.a); reg!(T.b)
            return
        end
        T isa DataType || return
        # is_runtime_vararg_tuple_type (structs.jl): `Tuple{Vararg{E}}` with a concrete
        # element E is Julia-NON-concrete (unbounded length) but WT gives it ONE
        # registrable {Object, data, size} representation (register_vararg_tuple_type!)
        # — a genuine exception to "classId means concrete leaf", not a gap.
        if is_runtime_vararg_tuple_type(T)
            push!(out, runtime_vararg_canonical(T))   # a non-empty narrowing shares the layout
            return
        end
        if T <: Type && T !== Type && length(T.parameters) == 1
            reg!(T.parameters[1])
            return
        end
        # A Tuple carrying a `Type{X}` element (an error-message tuple's trailing
        # `Int64`, boxed by value) is `isdispatchtuple` — Julia's own "this is one
        # exact compiled signature" test — but NOT `isconcretetype`: Tuple's diagonal
        # rule treats a `Type{X}` parameter as non-concrete even for concrete X.
        is_dispatch_tuple = T <: Tuple && Base.isdispatchtuple(T)
        (isconcretetype(T) || is_dispatch_tuple) || return
        if isstructtype(T)
            push!(out, T)
            for ft in fieldtypes(T)
                reg!(ft)
            end
        elseif isprimitivetype(T)
            push!(out, T)
        end
    end
    for fd in function_data
        code_info = fd[4]
        code_info === nothing && continue
        for at in fd[2]
            reg!(at isa Type ? at : typeof(at))
        end
        reg!(fd[5])
        ssats = code_info.ssavaluetypes
        if ssats isa Vector
            for t in ssats
                reg!(Core.Compiler.widenconst(t))
            end
        end
        slots = code_info.slottypes
        if slots isa Vector
            for t in slots
                reg!(Core.Compiler.widenconst(t))
            end
        end
        for stmt in code_info.code
            # `Core.tuple(a, b, ...)` (builtins.jl `_lower_tuple!`, the ONE Core.tuple
            # lowering) types the CONSTRUCTED tuple from its own per-argument types —
            # `Tuple{[infer_value_type(arg, ctx) for arg in args]...}` — a literal Type
            # argument (e.g. an error-message tuple's trailing `Int64`) becomes the
            # SINGLETON `Type{Int64}`, not the `DataType` Julia's own inference widens
            # the whole tuple's ssavaluetype to. No per-argument walk can reconstruct
            # that composite after the fact, so it is synthesized here the same way.
            if stmt isa Expr && stmt.head === :call && length(stmt.args) > 1
                callee = stmt.args[1]
                callee_v = callee isa GlobalRef ?
                    (isdefined(callee.mod, callee.name) ? getfield(callee.mod, callee.name) : nothing) :
                    callee
                if callee_v === Core.tuple
                    reg!(Tuple{Type[_collector_static_type(a, code_info) for a in stmt.args[2:end]]...})
                elseif callee_v === Core._apply_iterate
                    # a splat's argument pack is a tuple the LOWERING builds (calls.jl's
                    # _apply_iterate route); an empty collection yields Tuple{}, which no
                    # statement of the program names — the class the MethodError path
                    # then reports
                    reg!(Tuple{})
                end
            end
            # The callee position is IR structure, not a value: args[1] of a `:call`
            # (the callee itself) and args[1:2] of an `:invoke` (CodeInstance, then the
            # GlobalRef naming the target) are skipped; every other slot — including a
            # function passed as ordinary DATA, e.g. `_apply_iterate`'s `iterate` arg —
            # is a real value and walked.
            skip_from = stmt isa Expr ?
                (stmt.head === :invoke ? 3 : stmt.head === :call ? 2 : 1) : 1
            args = stmt isa Expr ? stmt.args : (stmt,)
            for i in skip_from:length(args)
                lit = args[i]
                v = lit isa QuoteNode ? lit.value : lit
                if v isa GlobalRef
                    # the value the lowering will read (values.jl's GlobalRef arm bakes a
                    # non-const binding's CURRENT value as a mutable-global initializer,
                    # so its type is reachable too)
                    isdefined(v.mod, v.name) || continue
                    v = getfield(v.mod, v.name)
                end
                v === nothing && continue
                typeof(v) in _IR_META_TYPES && continue
                reg!(v isa Type ? v : typeof(v))
            end
        end
    end
    return out
end

"""
    ir_reads_host_layout(ci::Core.CodeInstance) -> Bool

Whether the specialization's inferred source — transitively through its invokes — reads
`DataType.layout`, calls `Core.sizeof` on a type, or makes a foreigncall: the ways a
type-level computation can answer for the HOST's memory layout rather than for the
program (the constant-evaluation rule in interpreter.jl refuses to fold such a call).
Reads the CodeInstance's own `inferred` source (the result of the inference that just
ran — never a nested inference from inside an eligibility query); memoized per
specialization; a CodeInstance without retained source, or a chain deeper than six
invokes, counts as a read (never fold blind).
"""
const _IR_LAYOUT_READ_MEMO = IdDict{Any, Bool}()
function ir_reads_host_layout(ci::Core.CodeInstance, depth::Int=0)::Bool
    depth > 6 && return true
    local mi = ci.def
    local key = mi isa Core.MethodInstance ? mi.specTypes : ci
    haskey(_IR_LAYOUT_READ_MEMO, key) && return _IR_LAYOUT_READ_MEMO[key]
    _IR_LAYOUT_READ_MEMO[key] = false            # cycle guard
    local src = isdefined(ci, :inferred) ? ci.inferred : nothing
    src isa String && (src = try Base._uncompressed_ir(ci, src) catch; nothing end)
    local found = !(src isa Core.CodeInfo)
    if !found
        for st in src.code
            st isa Expr || continue
            if st.head === :call && length(st.args) >= 3
                local callee = st.args[1]
                local nm = callee isa GlobalRef ? callee.name :
                           callee isa Function ? nameof(callee) : nothing
                if nm === :getfield || nm === :getproperty
                    local fld = st.args[3]
                    fld isa QuoteNode && (fld = fld.value)
                    fld === :layout && (found = true; break)
                elseif nm === :sizeof && (callee isa GlobalRef ? callee.mod === Core : callee === Core.sizeof)
                    found = true; break
                end
            elseif st.head === :foreigncall
                found = true; break
            elseif st.head === :invoke
                local tgt = st.args[1]
                if tgt isa Core.CodeInstance
                    ir_reads_host_layout(tgt, depth + 1) && (found = true; break)
                else
                    found = true; break          # an invoke without its CodeInstance: unknown
                end
            end
        end
    end
    _IR_LAYOUT_READ_MEMO[key] = found
    return found
end

"""
    ir_reads_overlaid_method(ci::Core.CodeInstance) -> Bool

Whether the specialization's inferred source — transitively through its invokes — actually
RESOLVES to a Method registered in `WASM_METHOD_TABLE` (an `@overlay` definition): the one
case the constant-evaluation rule's overlay-safety guard (interpreter.jl) exists to catch.
Companion to `ir_reads_host_layout`, same shape, different question: that one asks whether a
fold would read the HOST's memory layout; this one asks whether a fold would silently bypass
an overlay (`Core._call_in_world_total`, which `concrete_eval_call` uses, runs ordinary
runtime dispatch — overlay method tables are an INFERENCE-time redirection with no runtime
counterpart, so folding a call that WOULD have dispatched to an overlaid method during
compilation would bake in the wrong, non-overlaid value).

An `:invoke` is exact — the target Method is the one that runs, no dispatch ambiguity — so
checking its own `external_mt` is definitive proof, not an inference guess (unlike
`nonoverlayed`, which merges conservatively across an entire mutually-recursive call graph
and taints on inference's OWN uncertainty about an active overlay table, not on an actual
overlaid callee — see the constant-evaluation rule's comment for the reproduced case). A
plain unresolved `:call` (dynamic dispatch) is treated as a hit only when its callee is
itself SOMETHING WASM_METHOD_TABLE has an entry for at all (`_wt_overlaid_callables`) — a
builtin/intrinsic call (`isa`, `<:`, `getfield`, …) can never be overlaid (overlay tables
redirect generic-function method lookup; builtins have none) and must not trip this.

An `:invoke`'s target can be a bare `MethodInstance` rather than a `CodeInstance` — REPRODUCED
2026-09-08: exactly for a specialization still mid-inference as part of an active cycle
(`_compute_eltype`'s own self- and mutual recursion through `typejoin`/`tailjoin`), where the
CodeInstance this very query is asking about has no retained source YET because the cycle it
belongs to has not finished converging. Its own `Method` is still checked directly (exact,
independent of any retained source); to recurse further, `_wt_overlaid_codeinfo` falls back to
another cached CodeInstance for the SAME MethodInstance (`.cache` / `.next` chain — commonly a
sysimage/precompiled entry for a Base function this ubiquitous) before giving up — the callee's
BODY is the same regardless of which CodeInstance names it. Memoized per specialization
(keyed by `specTypes`, shared with the MethodInstance-only path so a resolved sibling call
short-circuits the recursion); a chain deeper than six invokes, or no retained source at all
(the direct edge or any fallback), counts as a hit — never fold blind.
"""
const _IR_OVERLAY_READ_MEMO = IdDict{Any, Bool}()

# Any retained CodeInfo for the given CodeInstance, or — when its own `.inferred` is
# unavailable (mid-cycle) — for another cached CodeInstance of the SAME MethodInstance.
function _wt_overlaid_codeinfo(ci::Core.CodeInstance)::Union{Core.CodeInfo, Nothing}
    local _dbg = ci.def isa Core.MethodInstance && ci.def.def isa Method && ci.def.def.name === :_compute_eltype
    local src = isdefined(ci, :inferred) ? ci.inferred : nothing
    _dbg && Core.println(Core.stderr, "H1DBG3 direct ci.inferred defined=", isdefined(ci,:inferred),
                 " kind=", src === nothing ? "nothing" : typeof(src))
    src isa String && (src = try Base._uncompressed_ir(ci, src) catch e; _dbg && Core.println(Core.stderr, "H1DBG3 decompress err ", e); nothing end)
    src isa Core.CodeInfo && return src
    local mi = ci.def
    mi isa Core.MethodInstance || return nothing
    _dbg && Core.println(Core.stderr, "H1DBG3 mi.cache defined=", isdefined(mi,:cache))
    local c = isdefined(mi, :cache) ? mi.cache : nothing
    local nseen = 0
    while c isa Core.CodeInstance
        nseen += 1
        if c !== ci
            local s2 = isdefined(c, :inferred) ? c.inferred : nothing
            _dbg && Core.println(Core.stderr, "H1DBG3 sibling #", nseen, " inferred=", s2===nothing ? "nothing" : typeof(s2),
                         " min_world=", c.min_world, " max_world=", c.max_world)
            s2 isa String && (s2 = try Base._uncompressed_ir(c, s2) catch; nothing end)
            s2 isa Core.CodeInfo && return s2
        end
        c = isdefined(c, :next) ? c.next : nothing
    end
    return nothing
end

function ir_reads_overlaid_method(ci::Core.CodeInstance, depth::Int=0)::Bool
    if depth > 6
        Core.println(Core.stderr, "H1DBG2 depth>6 at ", ci.def)
        return true
    end
    local mi = ci.def
    local key = mi isa Core.MethodInstance ? mi.specTypes : ci
    haskey(_IR_OVERLAY_READ_MEMO, key) && return _IR_OVERLAY_READ_MEMO[key]
    _IR_OVERLAY_READ_MEMO[key] = false           # cycle guard
    local src = _wt_overlaid_codeinfo(ci)
    local found = src === nothing
    found && Core.println(Core.stderr, "H1DBG2 no-src at ", ci.def)
    if !found
        for st in src.code
            st isa Expr || continue
            if st.head === :invoke
                local tgt = st.args[1]
                local tmi = tgt isa Core.CodeInstance ? tgt.def :
                            tgt isa Core.MethodInstance ? tgt : nothing
                local tm = tmi isa Core.MethodInstance ? tmi.def : nothing
                if tm isa Method && isdefined(tm, :external_mt) && tm.external_mt === WASM_METHOD_TABLE
                    Core.println(Core.stderr, "H1DBG2 HIT invoke overlay ", tm, " from ", ci.def)
                    found = true; break
                elseif tgt isa Core.CodeInstance
                    ir_reads_overlaid_method(tgt, depth + 1) && (found = true; break)
                elseif tmi isa Core.MethodInstance
                    local c = isdefined(tmi, :cache) ? tmi.cache : nothing
                    if c isa Core.CodeInstance
                        ir_reads_overlaid_method(c, depth + 1) && (found = true; break)
                    else
                        Core.println(Core.stderr, "H1DBG2 no cached CI for MI target ", tmi, " from ", ci.def)
                        found = true; break      # no cached CodeInstance at all: unknown
                    end
                else
                    Core.println(Core.stderr, "H1DBG2 invoke neither at ", ci.def, " stmt=", st)
                    found = true; break          # an invoke with neither: unknown
                end
            elseif st.head === :call && length(st.args) >= 1
                local callee = st.args[1]
                local calleev = callee isa GlobalRef ?
                    (isdefined(callee.mod, callee.name) ? getfield(callee.mod, callee.name) : nothing) :
                    callee
                if _wt_is_overlaid_callable(calleev)
                    Core.println(Core.stderr, "H1DBG2 HIT call ", calleev, " from ", ci.def)
                    found = true; break
                end
            end
        end
    end
    _IR_OVERLAY_READ_MEMO[key] = found
    return found
end

"""
    _wt_overlaid_callables() -> Set{Any}

Every callable KEY that has at least one method registered in `WASM_METHOD_TABLE` — an
`@overlay WASM_METHOD_TABLE` definition's own function value for an ordinary function
overlay (`typeof(solve)`'s singleton instance), or its `Core.TypeName` for a `Type{X}(...)`
constructor overlay (dart's own class-identity key: `Dict{Int,String}` and the template
`Dict{K,V}` a constructor overlay is written against share one `TypeName`, so a concrete
call site matches a parametric overlay definition). Read from the table itself — never a
name list: a new overlay adds itself here automatically. Feeds `ir_reads_overlaid_method`
and `_wt_is_overlaid_callable`.

Package extensions (`ext/WasmTarget*Ext.jl`) register their own `@overlay WMT` methods
lazily, on `using` — AFTER WasmTarget's own module init — so this cannot cache past the
first call: it re-scans whenever the table's own method count has grown since the last
scan (cheap — `Base.MethodList` iteration, not a fold), never once at some arbitrary
earlier point that would silently miss a later extension's overlays.
"""
const _WT_OVERLAID_CALLABLES = Ref{Set{Any}}(Set{Any}())
const _WT_OVERLAID_CALLABLES_COUNT = Ref{Int}(-1)
function _wt_overlaid_callables()::Set{Any}
    ms = collect(Base.MethodList(WASM_METHOD_TABLE))
    length(ms) == _WT_OVERLAID_CALLABLES_COUNT[] && return _WT_OVERLAID_CALLABLES[]
    out = Set{Any}()
    for m in ms
        sig = Base.unwrap_unionall(m.sig)
        sig isa DataType && !isempty(sig.parameters) || continue
        ft = sig.parameters[1]
        ft isa DataType || continue
        if ft <: Type && length(ft.parameters) == 1
            # a `Type{X}(...)` constructor overlay: key by X's TypeName, concrete or not
            local tval = ft.parameters[1]
            local tn = tval isa DataType ? tval.name :
                       tval isa UnionAll ? Base.unwrap_unionall(tval).name : nothing
            tn !== nothing && push!(out, tn)
        elseif isdefined(ft, :instance)
            push!(out, ft.instance)
        end
    end
    _WT_OVERLAID_CALLABLES[] = out
    _WT_OVERLAID_CALLABLES_COUNT[] = length(ms)
    return out
end

"""
    _wt_is_overlaid_callable(@nospecialize(v)) -> Bool

Whether a raw IR operand `v`, used as a `:call`'s callee, might dispatch into
`WASM_METHOD_TABLE`: either `v` itself is a function/type WT has overlaid, or (for a `Type`
value used as a constructor callee) its `TypeName` is. A builtin/intrinsic value (`isa`,
`<:`, `getfield`, …) matches neither and returns `false`.
"""
function _wt_is_overlaid_callable(@nospecialize(v))::Bool
    v === nothing && return false
    local cs = _wt_overlaid_callables()
    v in cs && return true
    if v isa Type
        local tn = v isa DataType ? v.name : v isa UnionAll ? Base.unwrap_unionall(v).name : nothing
        return tn !== nothing && tn in cs
    end
    return false
end
