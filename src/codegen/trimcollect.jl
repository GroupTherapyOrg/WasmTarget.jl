# ============================================================================
# P5-trim: closed-world collection via the upstream juliac --trim machinery
# ============================================================================
#
# JuliaLang/julia#62087 (Keno's WasmGC strategy) proposes that static-compiler
# plugins receive "the list of MethodInstances to compile" from the juliac
# pipeline. The underlying machinery is `Compiler.typeinf_ext_toplevel` /
# `CompilationQueue` / `compile!`: a worklist-driven collection that infers
# the ENTIRE closed transitive callgraph at a consistent world and returns
# alternating (CodeInstance, CodeInfo) pairs, optionally trim-VERIFIED (no
# dynamic dispatch / runtime ccalls remain — with source-located diagnostics).
#
# `collect_closed_world` is that collection run under the WASM overlay
# interpreter, so @overlay methods replace their natives during inference
# (verified: the sinh overlay inlines and only its `exp` callee is
# collected). This is the intended replacement for the homegrown
# retired curated dependency walk, and the integration
# point for a future juliac `--compiler=WasmTarget` plugin interface.
#
# Availability: the three-arg Compiler API exists on 1.12 and 1.13. The
# TRIM_SAFE verifier is materially stronger on 1.13 (1.12 inference leaves
# dead empty-reduce branches dynamic); collection itself (TRIM_UNSAFE
# semantics — what this function does) works on both.

# Julia 1.13 deliberately reports `isconcretetype(Type{T}) == false`, even
# though a closed-world call-site value of that type has exactly one possible
# runtime identity: `T`. Treat these singleton type-object slots as exact for
# specialization alongside ordinary concrete value types.
# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
@inline _closed_world_exact_type(@nospecialize(T))::Bool =
    T isa Type && (isconcretetype(T) ||
        (T isa DataType && T <: Type && length(T.parameters) == 1 &&
         !(T.parameters[1] isa TypeVar)))

# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
@inline function _canonical_type_object_arg(@nospecialize(T), @nospecialize(formal))::Union{Type, Core.TypeofVararg}
    if T isa DataType && T <: Type && length(T.parameters) == 1 &&
       !(T.parameters[1] isa TypeVar)
        # `Core.Typeof(value)` intentionally preserves Type{value} singleton
        # precision; the Wasm runtime representation class is ordinary
        # `typeof(value)` (DataType, UnionAll, ...).
        runtime_class = typeof(T.parameters[1])
        formal === runtime_class && T <: formal && return formal
    end
    return T
end

"""
    _apply_iterate_vararg_target_mi(node, slot_types, lookup_table) -> MethodInstance | nothing

THE call edge of `Core._apply_iterate(iterate, f, t)` when `t` is a runtime-length
Vararg tuple — the one splat shape calls.jl lowers to a DIRECT call
(`_emit_apply_iterate_vararg_call!`).

parity(quarantine: Julia varargs — dart has no runtime-length parameter list, so every
dart call site names a static arity and dart2wasm has no counterpart to this edge).

It is a static edge: `f` is named right there in the call, and `t`'s
`{Object, data, size}` representation IS the callee's one packed parameter. But it
wears a builtin's clothes, so Julia's own collector does not see it. It is the `:splat`
kind of the one edge relation, `_closed_world_edge`, which the collector enrolls by and the
external-leaf prune keeps by. The container's type is its operand's NIR type (`slot_types`
types an argument operand).

`nothing` unless every condition holds: the callee resolves to an ordinary function
(never a builtin/intrinsic — those have no compiled body), the container carries the one
representable layout (`is_runtime_vararg_tuple_type`, structs.jl), and EXACTLY ONE
method answers the open-ended signature. An arity-overloaded callee has no single static
target and stays a loud reject at the call site.
"""
function _apply_iterate_vararg_target_mi(node::NirCall, slot_types::Vector{Type},
                                         lookup_table)::Union{Core.MethodInstance,Nothing}
    (node.callee === Core._apply_iterate && length(node.operands) == 3) || return nothing
    local fref = node.operands[2]
    local f = fref isa NirGlobalRef ? (fref.bound ? fref.value : fref) : nir_const(fref)
    (f isa Function && !(f isa Core.Builtin) && !(f isa Core.IntrinsicFunction)) || return nothing
    local t = node.operands[3]
    local T = t isa NirSSA ? t.julia_type :
              t isa NirArgument ? (1 <= t.n <= length(slot_types) ? slot_types[t.n] : Any) :
              t isa NirGlobalRef ? ((t.bound && isconst(t.mod, t.name)) ?
                                    (t.value isa Type ? Type{t.value} : typeof(t.value)) : Any) :
              t isa NirLiteral ? (t.value isa Type ? Type{t.value} : typeof(t.value)) : Any
    (T isa DataType && is_runtime_vararg_tuple_type(T)) || return nothing
    local sig = Tuple{Core.Typeof(f), Vararg{vararg_tuple_eltype(T)}}
    local matches = CC.findall(sig, lookup_table; limit=-1)
    (matches !== nothing && length(matches) == 1) || return nothing
    return CC.specialize_method(matches[1])
end

"""
    _call_site_arg_type(node, slot_types, joins) -> Type | nothing

The type a call site gives an operand: an SSA value's numeric join (`joins`, from
propagate_numeric_value_types) or its inferred type, an argument's slot type, a constant's
type. A slot, or a GlobalRef whose binding does not exist, has no call-site type to rebuild a
specialization from. Declining is the only sound answer — an invented one would monomorphize
the call onto a signature the program never calls.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function _call_site_arg_type(node::NirNode, slot_types::Vector{Type},
                             joins::Dict{Int,Type})::Union{Type,Nothing}
    T = if node isa NirSSA && haskey(joins, node.id)
        joins[node.id]
    elseif node isa NirSSA
        node.julia_type
    elseif node isa NirArgument && 1 <= node.n <= length(slot_types)
        slot_types[node.n]
    elseif node isa NirGlobalRef && node.bound
        Core.Const(node.value)
    elseif node isa NirLiteral
        Core.Const(node.value)
    else
        nothing
    end
    T === nothing && return nothing
    T = CC.widenconst(T)
    return T isa Type ? T : nothing
end

# The callee of `invoke_in_world(world, f, args...)` when `f` is a constant (a literal or a
# bound global): a function or a type; otherwise nothing (a dynamic callee).
# parity(quarantine: Julia's world-age builtin `Core.invoke_in_world`; dart has no world age, and a closed-world module has exactly one.)
function _invoke_in_world_callee(target::NirNode)::Union{Function,Type,Nothing}
    local f = target isa NirGlobalRef ? (target.bound ? target.value : nothing) :
              target isa NirLiteral ? target.value : nothing
    return (f isa Function || f isa Type) ? f : nothing
end

"""
    _invoke_in_world_target_mi(node, arg_type, lookup_table) -> MethodInstance | nothing

THE call edge of `Core.invoke_in_world(world, f, args...)`, which calls `f(args...)`: a
closed world has one world, so the edge is that call's dispatch in the overlay table — the
one method applicable to the operands' call-site types (`arg_type`). A callee that is not a
constant, an operand with no call-site type, or a call more than one method matches has no
static edge (the call site then rejects as a dynamic call).
parity(quarantine: Julia's world-age builtin `Core.invoke_in_world`; dart has no world age,
and a closed-world module has exactly one.)
"""
function _invoke_in_world_target_mi(node::NirCall, arg_type,
                                    lookup_table)::Union{Core.MethodInstance,Nothing}
    (length(node.operands) >= 2 && _nir_callee_object(node.callee) === Core.invoke_in_world) ||
        return nothing
    local f = _invoke_in_world_callee(node.operands[2])
    f === nothing && return nothing
    local arg_types = Any[]
    for a in @view node.operands[3:end]
        local T = arg_type(a)
        T === nothing && return nothing
        push!(arg_types, T)
    end
    local matches = CC.findall(Tuple{Core.Typeof(f), arg_types...}, lookup_table; limit=-1)
    (matches !== nothing && length(matches) == 1) || return nothing
    return CC.specialize_method(matches[1])
end

# 1.13's collectinvokes! (Compiler typeinfer.jl:1523) follows the `:new` of a Function type to the
# constructed callable's body; 1.12's (typeinfer.jl:1336) has no such edge. The running Julia's
# queue is the ground truth for which edges a closed world follows, so the kind is followed where
# that queue follows it, and a 1.12 world collects what 1.12's queue collects.
# parity(quarantine: Julia's trim collection follows these edges, typeinfer.jl:1523 collectinvokes!; dart's closed world comes from its TFA)
const _FOLLOWS_NEW_FUNCTION_EDGE = VERSION >= v"1.13.0-"

# what each edge kind of `_closed_world_edge` is, for the enrollment reason a failure prints
# parity(quarantine: Julia's trim collection follows these edges, typeinfer.jl:1477 collectinvokes!; dart's closed world comes from its TFA)
const _EDGE_ENROLLMENT = (invoke = "the call", splat = "the call", invoke_in_world = "the call",
                          finalizer = "the finalizer registered by", cfunction = "the function of",
                          new_function = "the body of the callable built by",
                          invoke_modify = "the operator of the atomic modify")

"""
    _closed_world_edge(node, src, slot_types, arg_type, interp) -> (kind, MethodInstance) | nothing

THE edge relation of the closed world: the MethodInstance statement `node` of the body `src`
needs compiled, and its kind. The collector enrolls by it (`_missing_explicit_invoke_mis`), the
external-leaf prune keeps by it (`_prune_external_leaf_subgraphs`) and the plan names each
body's reason by it (`trim_compile_plan`), so a body one of them reaches, the others reach too.
Every edge `CC.collectinvokes!` follows (Compiler typeinfer.jl:1336 on 1.12, :1477 on 1.13):
- `:invoke`, the MethodInstance it names (Julia's abstract one included: the collector
  re-specializes it at the call-site types);
- `:invoke_modify`, the operator it names;
- `:finalizer`, a `Core.finalizer(f, o, …)` call's `f(o)`, at Julia's arity, two to four
  operands (`3 <= length(stmt.args) <= 5`, typeinfer.jl:1353 on 1.12, :1502 on 1.13);
- `:cfunction`, the function a `:cfunction` makes a pointer to, at its declared argument types;
- `:new_function` (1.13, `_FOLLOWS_NEW_FUNCTION_EDGE`), the body of a `:new` of a Function type;
the last three at Julia's own answer, `CC.compileable_specialization_for_call`, as its queue
enqueues them, over each operand's call-site type: WT's `_call_site_arg_type` where Julia reads
`argextype` (typeinfer.jl:1503 on 1.13). And the two static calls a builtin hides that WT lowers as direct calls:
`:splat`, a runtime-Vararg `Core._apply_iterate` (`_apply_iterate_vararg_target_mi`), and
`:invoke_in_world` (`_invoke_in_world_target_mi`). `arg_type` types an operand at its call
site (`_call_site_arg_type`). A statement names at most one edge.

`nothing` when the statement has no edge or its target is not one MethodInstance. That skips
nothing silently: the statement is then lowered or rejected at its own site. A call with no
static target rejects as a dynamic call. A finalizer, a `:cfunction` and an `:invoke_modify`
have no lowering and reject at their statements (ConsultChain, `record_unsupported!`). A `:new`
builds its struct, and a call of the callable has its own edge.
formal(dev/formal/ClosedWorld.tla): the collector follows every kind of HiddenKinds
(CollectorKinds = HiddenKinds), so the collected world holds every method reachable from the
roots (Completeness)
parity(quarantine: Julia's trim collection follows these edges, typeinfer.jl:1477 collectinvokes!; dart's closed world comes from its TFA)
"""
function _closed_world_edge(node::NirNode, src::Core.CodeInfo, slot_types::Vector{Type}, arg_type,
                            interp)::Union{Tuple{Symbol,Core.MethodInstance},Nothing}
    local kind, mi = :invoke, nothing
    local operand_type(a) = (T = arg_type(a); T === nothing ? Any : T)   # argextype's Any
    if node isa NirInvoke
        mi = node.mi
    elseif node isa NirCall
        local table = CC.method_table(interp)
        if (mi = _apply_iterate_vararg_target_mi(node, slot_types, table)) !== nothing
            kind = :splat
        elseif (mi = _invoke_in_world_target_mi(node, arg_type, table)) !== nothing
            kind = :invoke_in_world
        elseif _nir_callee_object(node.callee) === Core.finalizer && 2 <= length(node.operands) <= 4
            kind = :finalizer
            mi = CC.compileable_specialization_for_call(interp,
                Tuple{operand_type(node.operands[1]), operand_type(node.operands[2])})
        end
    elseif node isa NirNew
        kind = :new_function
        (_FOLLOWS_NEW_FUNCTION_EDGE && node.T <: Function) &&
            (mi = CC.compileable_specialization_for_call(interp, Tuple{node.T, Vararg}))
    elseif node isa NirUnsupported
        # read through the NIR boundary's operands, never the raw Expr (R29a)
        local ops = node.operands
        if node.kind === :invoke_modify && !isempty(ops) && ops[1] isa NirLiteral
            kind = :invoke_modify
            mi = resolve_invoke_mi(ops[1].value)
        elseif node.kind === :cfunction && length(ops) == 5 && ops[4] isa NirLiteral &&
               ops[4].value isa Core.SimpleVector && src.parent isa Core.MethodInstance
            # (pointer type, f, return type, argument types, calling convention); each
            # argument type rewrapped over the host's static parameters, as Julia does
            kind = :cfunction
            mi = CC.compileable_specialization_for_call(interp, Tuple{operand_type(ops[2]),
                (CC.sp_type_rewrap(t, src.parent, false) for t in ops[4].value)...})
        end
    end
    return mi isa Core.MethodInstance ? (kind, mi) : nothing
end

# the operand typer `_closed_world_edge` reads in one body: an operand's call-site type, the
# body's numeric joins computed once (`joins`, per CodeInfo), when an edge first asks
# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
_edge_arg_type(src::Core.CodeInfo, nir::Vector{NirStmt}, slot_types::Vector{Type},
               joins::IdDict{Core.CodeInfo,Dict{Int,Type}})::Function =
    a -> _call_site_arg_type(a, slot_types, get!(() -> propagate_numeric_value_types(nir), joins, src))

"""Return the targets of the collected bodies' edges (`_closed_world_edge`) missing from a
collected world, each recorded in `seen` and `reasons`. An explicit `:invoke` whose concrete
call-site types select another MethodInstance is first retargeted in place to it.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)"""
function _missing_explicit_invoke_mis(codeinfos::Vector{Any}, seen::Set{Any};
                                      reasons::IdDict{Core.MethodInstance,String}=IdDict{Core.MethodInstance,String}())::Vector{Any}
    out = Any[]
    numeric_types = IdDict{Core.CodeInfo,Dict{Int,Type}}()
    interp = WasmInterpreter(Base.RefValue(0))
    lookup_table = CC.method_table(interp)
    for i in 2:2:length(codeinfos)
        src = codeinfos[i]
        src isa Core.CodeInfo || continue
        nir = build_nir(src)
        src_slot_types = nir_slot_types(src)
        arg_type = _edge_arg_type(src, nir, src_slot_types, numeric_types)
        for (k, s) in enumerate(nir)
            local node = s.node
            local edge = _closed_world_edge(node, src, src_slot_types, arg_type, interp)
            edge === nothing && continue
            local kind = edge[1]
            mi = edge[2]
            if kind === :invoke
                original_mi = mi
                # Explicit invoke records the selected Method, but Julia may leave
                # its MethodInstance abstract. WT's subset monomorphizes: rebuild
                # the MI from the concrete call-site SSA types, exactly as the
                # compiler would for an ordinary specialized call.
                if mi isa Core.MethodInstance && node.callee !== nothing
                    f = node.callee isa NirLiteral ? node.callee.value : node.callee
                    arg_types = Any[arg_type(a) for a in node.operands]
                    # Constructors are callable Type objects, not subtypes of
                    # Function. They participate in exactly the same overlay
                    # method-table lookup and concrete MethodInstance
                    # specialization as ordinary functions.
                    if (f isa Function || f isa Type) &&
                       all(_closed_world_exact_type, arg_types)
                        ftype = Tuple{Core.Typeof(f), arg_types...}
                        # Re-resolve with the same overlay table used by the
                        # closed-world compiler. An explicit invoke can retain
                        # Base's abstract Vararg MI even though the concrete
                        # call must dispatch to a Wasm overlay specialization.
                        matches = CC.findall(ftype, lookup_table; limit=-1)
                        # The invoked method itself (or the overlay sharing its signature),
                        # specialized at the concrete types. An explicit
                        # `invoke(f, Tuple{Super}, x)` names a method that dispatch on x's
                        # type does not select — CC.findall leaves a method the selected
                        # one fully covers out of its matches — and Julia calls that method.
                        local invoked_match = nothing
                        if matches !== nothing && mi.def isa Method
                            for m in matches
                                if m.method.sig == mi.def.sig
                                    invoked_match = m
                                    break
                                end
                            end
                        end
                        if invoked_match === nothing && mi.def isa Method && matches !== nothing &&
                           !isempty(matches) && matches[1].method.sig != mi.def.sig &&
                           ftype <: mi.def.sig
                            # shadowed at these types: keep the invoked method
                            if mi.specTypes != ftype
                                local ti_env = ccall(:jl_type_intersection_with_env, Any, (Any, Any),
                                                     ftype, mi.def.sig)::Core.SimpleVector
                                mi = CC.specialize_method(mi.def, ti_env[1], ti_env[2])
                            end
                        elseif matches !== nothing && !isempty(matches)
                            match = invoked_match === nothing ? matches[1] : invoked_match
                            # A Type{T} call-site value sometimes selects a method
                            # declared on its representation class (DataType,
                            # UnionAll, ...). Preserve singleton precision when it
                            # affects dispatch/inference (mapreduce_empty), but do
                            # not manufacture a narrower specialization when the
                            # selected method's exact formal is the representation
                            # class. Re-resolve to prove method identity.
                            msig = Base.unwrap_unionall(match.method.sig)
                            if msig isa DataType && msig <: Tuple &&
                               length(msig.parameters) == length(arg_types) + 1
                                canonical_args = Any[
                                    _canonical_type_object_arg(arg_types[j], msig.parameters[j + 1])
                                    for j in eachindex(arg_types)]
                                canonical_ftype = Tuple{Core.Typeof(f), canonical_args...}
                                if canonical_ftype != ftype
                                    canonical_matches = CC.findall(canonical_ftype, lookup_table; limit=-1)
                                    if canonical_matches !== nothing && !isempty(canonical_matches) &&
                                       canonical_matches[1].method === match.method
                                        ftype = canonical_ftype
                                        match = canonical_matches[1]
                                    end
                                end
                            end
                            # Re-specialization must be idempotent: Compiler may
                            # return a fresh MethodInstance object for the same
                            # overlay method/signature, which would make the joint
                            # reachability worklist manufacture work forever.
                            if mi.specTypes != ftype || mi.def !== match.method
                                mi = CC.specialize_method(match)
                            end
                        end
                    end
                end
                if mi isa Core.MethodInstance && original_mi isa Core.MethodInstance &&
                   mi !== original_mi
                    # Keep the optimized IR valid Julia while making its edge agree
                    # with the Wasm overlay dispatch selected for the concrete call.
                    # Nothing is dropped: the original stays collected wherever Julia's
                    # queue collected it, live if another site still invokes it, dead
                    # code otherwise (ClosedWorld.tla NoGarbage, MARCH 13.17 H9).
                    nir_retarget_invoke!(src, nir, k, mi)
                end
            end
            mi isa Core.MethodInstance || continue
            mi in seen && continue
            push!(seen, mi)
            push!(out, mi)
            reasons[mi] = _enrollment_text(_EDGE_ENROLLMENT[kind], codeinfos[i - 1], src, k, node)
        end
    end
    return out
end

"""
    throw_located_collection_failure(batch, err, bt, compile_one)

Throw a closed-world collection failure, located: the batch's roots are inferred again one at a
time (`compile_one(mi)`, the failure path only — the success path keeps one batch, so the
collected order and every module's bytes are unchanged), and the first that fails alone is
named with why it was enrolled (`batch`'s reasons: the call, dispatch candidate or closure
body that brought it in, with its statement and source line), its own error and the frames
it was raised through. When no root fails alone, the batch's roots and the original error
are reported. L78: a specialization failure aborts the collection, loudly.
formal(dev/formal/ClosedWorld.tla): a reachable specialization failure ends the run Rejected
parity(pkg/dart2wasm/lib/compile.dart:113 CFECrashError)
"""
function throw_located_collection_failure(batch::Vector{Tuple{Any,String}}, err, bt,
                                          compile_one::Function)::Union{}
    _named(mi, why) = "inferring $(replace(sprint(show, mi), "MethodInstance for " => "")), enrolled as $why"
    for (mi, why) in batch
        try
            compile_one(mi)
        catch e
            throw(WasmInternalError("closed-world collection", 0, "", String[_named(mi, why)], e,
                                    _raised_frames(catch_backtrace(), :throw_located_collection_failure)))
        end
    end
    throw(WasmInternalError("closed-world collection", 0, "",
                            String[_named(mi, why) for (mi, why) in batch],
                            err, _raised_frames(bt, :collect_closed_world)))
end

# infer one root in a fresh partition, as collect_new_pairs! would (the failure path only)
# parity(pkg/dart2wasm/lib/compile.dart:113 CFECrashError)
function _compile_root_alone(mi)::Nothing
    local interp = WasmInterpreter(Base.RefValue(0))
    local ci = Any[]
    local wq = CC.CompilationQueue(; interp)
    local ilq = CC.CompilationQueue(; interp)
    push!(wq, mi)
    CC.compile!(ci, wq; invokelatest_queue=ilq, _COMPILE_KW...)
    CC.compile!(ci, ilq; invokelatest_queue=ilq, _COMPILE_KW...)
    return nothing
end

"""
    _enrollment_text(what, ci, src, idx, node) -> String

Why a MethodInstance entered the closed world: `what` (the call, a dispatch candidate of a
call, …) of statement `idx` of the host whose CodeInstance is `ci`, with the statement's text
and innermost source line — the provenance a collection failure prints.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function _enrollment_text(what::String, ci, src::Core.CodeInfo, idx::Int, node::NirNode)::String
    local frames = stmt_frames(src.debuginfo, idx)
    local loc = isempty(frames) ? "" : " @ " * last(split(first(frames), " @ "))
    return string(what, " `", first(_nir_text(node), 100), "` in ", _collection_host_text(ci), " (statement %", idx, loc, ")")
end

# the host a collected statement sits in, as a diagnostic names it
# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
function _collection_host_text(ci)::String
    local host = ci isa Core.CodeInstance ? ci.def : ci
    host isa Core.MethodInstance || (host = getfield(host, :def))   # an ABIOverride's instance
    return replace(sprint(show, host), "MethodInstance for " => "")
end

"""
    _held_bound_rejection(ci, src, idx, rec) -> WasmCompileError

A constant whose own objects (those no constant walked before it reached) pass the bound of the
walk for the type objects constants hold (10^6 per constant, WT's own bound, not Julia's),
rejected at statement `idx` (its NIR record `rec`) of the host whose
CodeInstance is `ci`, and located as a codegen rejection is: its statement, source line and inline chain innermost
first (as values.jl rejects a cyclic struct constant at its statement).
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world, and the type objects a constant holds are values a program reads; dart's constants are its own front end's, typed by their classes.)
"""
function _held_bound_rejection(ci, src::Core.CodeInfo, idx::Int, rec::NirStmt)::WasmCompileError
    local frames = stmt_frames(src.debuginfo, idx)
    return WasmCompileError(WasmDiagnostic(:unsupported_type, _collection_host_text(ci),
        "a constant whose own objects passed 10^6, the bound of the walk for the type objects a constant holds",
        isempty(frames) ? nothing : String(last(split(first(frames), " @ "))), nothing, idx,
        first(nir_text(rec), 160), frames))
end

"""
The MethodInstances the program's dynamic dispatch sites can reach: for each site, the methods
of its function applicable to its argument types whose dispatch classes the collected program
instantiates (in its signatures or allocations), as dart builds dispatch rows only for the
classes of its closed component; and for a callable constructed and called dynamically, every
method Julia's matching gives the call's static signature, at its intersection (a method with
static parameters at each tuple of candidates over the positions its static parameters
mention).
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from
its front end's whole-program type flow analysis.)
"""
function _dynamic_dispatch_candidate_mis(codeinfos::Vector{Any}, seen::Set{Any},
                                         entry_mis::Vector{Any}=Any[];
                                         reasons::IdDict{Core.MethodInstance,String}=IdDict{Core.MethodInstance,String}(),
                                         held::Set{DataType},
                                         error_args::Set{DataType}=Set{DataType}())::Vector{Any}
    out = Any[]
    # dart builds dispatch rows only for classes in the closed component. Mirror that
    # boundary: a Julia method's concrete dispatch type must occur in the collected
    # program's signatures or allocations. An inferred SSA type is not evidence that
    # its class is instantiated (it may belong to a dead/native implementation path).
    # Enumerating every method below an
    # abstract slot pulled unrelated BigFloat/MPFR code into integer-only modules and
    # forced the now-deleted trap-repair policy.
    runtime_types = Set{DataType}()
    # the type objects a value may be: a literal or a constant global a statement, a phi or a
    # return holds (which over-approximates: a typeassert's, an isa's or an intrinsic's type
    # operand is one too, adding rows and ambiguity questions, never dropping one), and the
    # type object of each class a `typeof` may return; each a candidate by its dispatch type
    # `Type{X}` (formal(dev/formal/Enrollment.tla): a type object is no numbered class,
    # StaticOnly; one a `typeof` makes, LiteralsOnly), a constant tuple's or immutable struct's
    # fields included
    held_type_objects = held   # the caller keeps it for the vtable pre-pass's ambiguity search
    typeof_operand_types = Set{Any}()   # the static type of each `typeof` operand
    observed_type_nodes = Set{Any}()
    # One NIR per collected CodeInfo — this pass walks each body twice (runtime-class
    # observation, then candidate discovery). Call-local: `_missing_explicit_invoke_mis`
    # re-targets invoke edges in place between rounds, so a boundary cached across calls
    # would describe an IR that no longer exists.
    nir_cache = IdDict{Core.CodeInfo,Vector{NirStmt}}()
    nir_for(src::Core.CodeInfo)::Vector{NirStmt} = get!(() -> build_nir(src), nir_cache, src)
    function contains_ffi_type(@nospecialize(T), visited=Set{Any}())
        T in visited && return false
        push!(visited, T)
        T isa DataType || return false
        T <: Ptr && return true
        return any(p -> contains_ffi_type(p, visited), T.parameters)
    end
    function observe_type!(@nospecialize(T))
        T in observed_type_nodes && return
        push!(observed_type_nodes, T)
        if T isa Union
            foreach(observe_type!, Base.uniontypes(T))
        elseif T isa DataType
            # FFI is an explicit 0.5 scope boundary. A class whose representation
            # contains Ptr cannot be a Wasm selector class; if it reaches codegen as
            # a real value, the ordinary unsupported-feature diagnostic remains loud.
            isconcretetype(T) && !contains_ffi_type(T) && push!(runtime_types, T)
            # Instantiated generic fields encode runtime classes in their type
            # arguments (for example DateFormat's Tuple of DatePart{'y'}/Delim
            # nodes). They are part of the closed component even when inference
            # never exposes each nested class as a standalone SSA type.
            foreach(observe_type!, T.parameters)
        elseif T isa UnionAll
            observe_type!(Base.unwrap_unionall(T))
        end
        return
    end
    function observe_runtime_operand!(node::NirNode)
        # Optimized IR may constant-fold `%new(T, fields...)` into an actual
        # immutable `T(...)` object embedded as a call argument (no longer an
        # explicit :new). The boundary classifies such an embedded VALUE as a
        # literal operand; it is stronger evidence of runtime class membership
        # than an inferred SSA type, because it IS the value the collected
        # program stores/passes. An SSA/argument/slot/global operand carries no
        # value here, so only literals are observed.
        local v = node isa NirLiteral ? node.value :
                  (node isa NirGlobalRef && node.bound && isconst(node.mod, node.name)) ? node.value : nothing
        (node isa NirLiteral || v !== nothing) || return
        v isa Expr && return
        local VT = Core.Typeof(v)
        observe_held!(node)
        node isa NirLiteral && observe_type!(VT)
        return
    end
    # a type object held as a value is the candidate Type{X}, whether its values are one
    # pointer or are told by type equality (a Type{X} row that tests type equality rejects,
    # _closure_param_untestable; left out, a value of it ran another method, A10C1)
    # each heap object a constant reaches, by its address: `===` and objectid recurse through an
    # immutable object's fields, so a shared immutable child would be walked once per path
    local held_seen = Set{Ptr{Cvoid}}()
    local held_alive = Any[]   # each visited object, kept alive so no address is reused mid-walk
    local held_site = Ref{Any}(nothing)   # the statement whose operand is being walked
    function observe_held!(node::NirNode)
        local v = node isa NirLiteral ? node.value :
                  (node isa NirGlobalRef && node.bound && isconst(node.mod, node.name)) ? node.value : nothing
        hold!(v)
        return
    end
    # every value a constant reaches: an array's or a Memory's elements, a struct's or tuple's
    # fields, a mutable one's included, each heap object once (a worklist, so neither a shared
    # child nor a long chain multiplies the walk or deepens the stack; a fresh box getfield makes is
    # kept alive, so its address is not reused for another). A module and exactly these
    # runtime structures of Core (a TypeName, a method table and its entries, a Method, a
    # MethodInstance, a CodeInstance, a CodeInfo, a binding, a SimpleVector) are not values a
    # program reads out of a constant (a NamedTuple, a Box are walked): walking them reached the
    # whole method graph, and a constant SimpleVector does not compile yet (MARCH 13.17 A11C9).
    # Past 10^6 objects counted for one constant (its own: each heap object no earlier constant
    # reached, once, and each fresh box getfield or getindex makes of an inline immutable; type
    # objects, bits values and the skipped kinds are not counted) the walk rejects, a
    # WasmCompileError at the statement whose constant it walked.
    function hold!(@nospecialize(root))
        local work = Any[root]
        local own = 0
        while !isempty(work)
            local v = pop!(work)
            if v isa Type
                local VT = Core.Typeof(v)
                VT isa DataType && VT.name === Type.body.name && push!(held_type_objects, VT)
                continue
            end
            (isbits(v) || v isa Module) && continue
            (v isa Core.TypeName || v isa Core.MethodTable || v isa Core.TypeMapEntry ||
             v isa Core.TypeMapLevel || v isa Method || v isa Core.MethodInstance ||
             v isa Core.CodeInstance || v isa Core.CodeInfo || v isa Core.Binding ||
             v isa Core.SimpleVector) && continue
            local addr = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), v)
            addr in held_seen && continue
            push!(held_seen, addr)
            push!(held_alive, v)
            own += 1
            if own > 1_000_000
                throw(_held_bound_rejection(held_site[]::Tuple...))
            end
            if v isa Array || v isa GenericMemory
                for i in eachindex(v)
                    isassigned(v, i) && push!(work, v[i])
                end
            elseif isstructtype(typeof(v))
                for i in 1:nfields(v)
                    isdefined(v, i) && push!(work, getfield(v, i))
                end
            end
        end
        return
    end
    # The operands one statement carries. Every node's `args` hold exactly the
    # runtime operands — a foreigncall's ABI preamble and an invoke's
    # MethodInstance are resolved FIELDS, never operands — so this is the operand
    # set proper. An invoke's callee operand can itself be an embedded callable
    # value, so it joins the scan when the boundary classified it as a literal.
    function statement_operands(node::NirNode)::Vector{NirNode}
        node isa NirCall && return node.operands
        node isa NirNew && return node.operands
        node isa NirForeignCall && return node.operands
        if node isa NirInvoke
            local callee = node.callee
            return callee isa NirLiteral ? NirNode[callee; node.operands] : node.operands
        end
        return NirNode[]
    end
    # Explicit root arguments cross into the component and therefore exist at
    # runtime even if their construction happened in the host.
    for entry in entry_mis
        sig = entry.specTypes
        sig isa DataType && foreach(observe_type!, sig.parameters[2:end])
    end
    for j in 1:2:length(codeinfos)
        (j + 1 <= length(codeinfos) && codeinfos[j] isa Core.CodeInstance &&
         codeinfos[j + 1] isa Core.CodeInfo) || continue
        for (sidx, s0) in enumerate(nir_for(codeinfos[j + 1]))
            local node0 = s0.node
            held_site[] = (codeinfos[j], codeinfos[j + 1], sidx, s0)
            node0 isa NirNew && node0.type_kind === :literal && observe_type!(node0.T)
            # the builtins that allocate a class without a %new instantiate it as surely:
            # a MemoryRef (memoryrefnew), a Memory (jl_alloc_genericmemory), and a tuple
            # (Core.tuple), whose class is its elements' runtime types (tuple_runtime_type,
            # the answer that numbers it and that _lower_tuple! builds)
            if s0.slot == 0 && ((node0 isa NirCall &&
                                 _nir_callee_object(node0.callee) === Core.memoryrefnew) ||
                                (node0 isa NirForeignCall &&
                                 node0.c_symbol === :jl_alloc_genericmemory))
                observe_type!(CC.widenconst(s0.julia_type))
            end
            if node0 isa NirCall && _nir_callee_object(node0.callee) === Core.tuple
                local tt = tuple_runtime_type(node0.operands, nir_slot_types(codeinfos[j + 1]))
                tt === nothing || observe_type!(tt)
            end
            foreach(observe_runtime_operand!, statement_operands(node0))
            # a type object a phi, a pi, an upsilon or a return holds is held as surely
            local carried = node0 isa NirPhi || node0 isa NirPhiC ? node0.values :
                            node0 isa NirReturn || node0 isa NirPi || node0 isa NirUpsilon ? Any[node0.value] : Any[]
            for c in carried
                c isa NirNode && observe_held!(c)
            end
            if node0 isa NirCall && _nir_callee_object(node0.callee) === Core.typeof &&
               length(node0.operands) == 1
                push!(typeof_operand_types,
                      _collector_static_type(node0.operands[1], nir_slot_types(codeinfos[j + 1])))
            end
        end
    end
    # a `typeof` returns the type object of its operand's class: each class a value of the
    # operand's static type can have
    for T in typeof_operand_types
        for C in runtime_types
            isconcretetype(C) && C <: T && push!(held_type_objects, Type{C})
        end
    end
    # a type object's type is its kind (A11C1: `typeof(x)` of a type object x): the kind of each
    # type object a value may be, a held one or a `typeof` result (a DataType)
    if !isempty(typeof_operand_types)
        local kinds = Set{Any}([DataType])
        for H in held_type_objects
            local X = H.parameters[1]
            X isa Type && push!(kinds, typeof(X))
        end
        for K in kinds, T in typeof_operand_types
            typeintersect(T, K) !== Union{} && push!(held_type_objects, Type{K})
        end
    end
    # OBSERVED dynamic-call signatures (SSA callee, inferred arg types) —
    # closure bodies specialize against these (dart's typed vtable entries; Julia's
    # inference makes the body REAL instead of an any-erased stub).
    callable_invocations = Set{Tuple{DataType,Tuple}}()
    i = 1
    _fn_callables = Set{DataType}()   # per-function staging (folded on co-occurrence)
    _fn_dyn_sigs = Set{Tuple}()
    function observe_callable!(@nospecialize(T))
        if T isa Union
            foreach(observe_callable!, Base.uniontypes(T))
        elseif T isa DataType && T <: Function
            if is_closure_type(T)
                local root = T.name.module
                while parentmodule(root) !== root
                    root = parentmodule(root)
                end
                (root === Main || T <: _RuntimeComposition) && push!(_fn_callables, T)
            elseif isdefined(T, :instance)
                # A named/generic function singleton is Dart's static tear-off
                # counterpart. Enrollment remains co-occurrence-gated below.
                push!(_fn_callables, T)
            end
        end
        return
    end
    function flush_callable_invocations!()
        for T in _fn_callables, sig in _fn_dyn_sigs
            push!(callable_invocations, (T, sig))
        end
        empty!(_fn_callables)
        empty!(_fn_dyn_sigs)
        return
    end
    # captured variables' types over the whole world collected so far (record_capture_contents!);
    # a closure body's IR is the one collected, never a second inference
    local collected_ir = IdDict{Any,Tuple{Core.CodeInfo,Any}}()
    for k in 1:2:length(codeinfos)
        (k + 1 <= length(codeinfos) && codeinfos[k] isa Core.CodeInstance && codeinfos[k + 1] isa Core.CodeInfo) || continue
        local cmi = codeinfos[k].def isa Core.MethodInstance ? codeinfos[k].def : codeinfos[k].def.def
        collected_ir[cmi] = (codeinfos[k + 1], codeinfos[k].rettype)
    end
    local closure_ir = mi -> get(collected_ir, mi, nothing)
    capture_record = record_capture_contents(Any[
        (nir_for(codeinfos[k]), nir_slot_types(codeinfos[k]),
         isempty(nir_slot_types(codeinfos[k])) ? nothing : nir_slot_types(codeinfos[k])[1])
        for k in 2:2:length(codeinfos) if codeinfos[k] isa Core.CodeInfo]; closure_ir)
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        # Co-occurrence fold: a function's constructed closures enroll ONLY
        # if that function ALSO makes dynamic (SSA-callee) calls — enrolling every
        # userland closure perturbed modules with purely-static closures (the
        # randsubseq suite regression).
        flush_callable_invocations!()
        host_mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        hsig = host_mi.specTypes
        hparams = (hsig isa DataType && hsig <: Tuple) ? collect(hsig.parameters) : Any[]
        local nir = nir_for(src)
        # Capture typing is a closed-world fact, not merely a codegen hint: the same
        # record codegen types box reads from (capture_read_types) types them here, so a
        # call erased by Core.Box inference enrolls its exact MethodInstance before
        # function indices are frozen.
        local _capture_joins = capture_read_types(nir, nir, capture_record,
                                                  isempty(hparams) ? nothing : hparams[1];
                                                  spectypes=nir_slot_types(src), closure_ir)
        local _call_type = function(a)
            if a isa NirSSA && haskey(_capture_joins, a.id)
                return _capture_joins[a.id]
            elseif a isa NirSSA
                return a.julia_type
            elseif a isa NirArgument
                return (a.n >= 1 && a.n <= length(hparams)) ? hparams[a.n] : Any
            elseif a isa NirGlobalRef
                return a.bound ? Core.Typeof(a.value) : Any
            elseif a isa NirLiteral
                return Core.Typeof(a.value)
            end
            return Any
        end
        # Optimized IR often folds `%new(closure, captures...)` into a constant
        # tuple followed by getfield. The concrete closure types still inhabit SSA
        # types, so collect from that semantic source as well as explicit :new.
        foreach(s -> observe_callable!(s.julia_type), nir)
        for (sidx, s) in enumerate(nir)
            local node = s.node
            # a function a statement holds as a literal operand is a value that statement
            # passes on, as surely as one an SSA type names (a capture-less closure passed to a
            # function that returns it erased reached a dynamic call with no row, MARCH 13.17
            # A7S1 stage 4: native 4, wasm trap)
            # (a builtin's operand is no value passed on: `Core._apply_iterate(Base.iterate, …)`
            # enrolled `iterate` as a callable, batch 101's CI regression)
            if (node isa NirCall && !(_nir_callee_object(node.callee) isa Core.Builtin)) ||
               node isa NirInvoke || node isa NirNew
                for a in node.operands
                    local v = a isa NirLiteral ? a.value :
                              (a isa NirGlobalRef && a.bound && isconst(a.mod, a.name)) ? a.value : nothing
                    (v isa Function && !(v isa Core.Builtin) && !(v isa Core.IntrinsicFunction)) &&
                        observe_callable!(typeof(v))
                end
            end
            # (dart: creating a Lambda compiles its target): a CONSTRUCTED
            # closure enrolls its callable body — the erased/dynamic call site rides
            # the vtable trampoline, which needs the body compiled. Specialized with
            # the method's own sig (abstract slots stay erased; the trampoline passes
            # anyref and the body's funnel machinery narrows internally).
            if node isa NirNew
                # scope: USERLAND closures only — Base/stdlib-internal closures are
                # statically called (never through the vtable); enrolling them all
                # exploded the blast radius (a _growend! trampoline mis-built).
                node.type_kind === :literal &&
                    observe_callable!(node.T)   # staged; folds only on co-occurrence
                continue
            end
            node isa NirCall || continue
            local operands = node.operands
            # OBSERVED dynamic-call signature: an SSA/erased callee with inferrable args
            if node.callee isa NirSSA
                local _dargs = Any[]
                local _dok = true
                for a in operands
                    # the operand's static type as the collector types it (a box read at its
                    # capture join); an abstract one enrolls every method Julia's matching
                    # gives it, each at its intersection (the loop over callable_invocations)
                    local t = _call_type(a)
                    t isa Type || (_dok = false; break)
                    push!(_dargs, t)
                end
                if _dok && !isempty(_dargs)
                    push!(_fn_dyn_sigs, Tuple(_dargs))
                end
            end
            isempty(operands) && continue
            # (a singleton-typed function argument arrives already resolved to its
            # instance — the NIR boundary's one callee resolution)
            local g = _nir_callee_object(node.callee)
            (g isa Function && !(g isa Core.Builtin) && !(g isa Core.IntrinsicFunction)) || continue
            # Resolve arg types from the optimized IR.
            cargs = operands
            atypes = Any[]
            bad = false
            for a in cargs
                t = _call_type(a)
                t isa Type || (bad = true; break)
                push!(atypes, t)
            end
            bad && continue
            # A formerly-erased call whose complete signature is now proven is
            # monomorphic. Enroll exactly Julia's selected method; `seen` keeps
            # ordinary already-collected concrete calls a no-op here.
            absp = Int[j for j in 1:length(atypes) if !_closed_world_exact_type(atypes[j])]
            if isempty(absp)
                local concrete_args = Tuple(atypes)
                p0_hasmethod("tc826", g, concrete_args) || continue
                local m = p0_which("tc827", g, concrete_args)
                local ssig = Tuple{Core.Typeof(g), atypes...}
                ssig <: m.sig || continue
                # the static parameters' values at ssig, as Julia's match computes them (A8C3)
                local cmi = CC.specialize_method(m, ssig,
                    ccall(:jl_type_intersection_with_env, Any, (Any, Any), ssig, m.sig)[2])
                if !(cmi in seen)
                    push!(seen, cmi)
                    push!(out, cmi)
                    reasons[cmi] = _enrollment_text("the dynamic call", ci, src, sidx, node)
                end
                continue
            end
            # Otherwise exactly one abstract position may use a runtime selector.
            length(absp) == 1 || continue
            p = absp[1]
            # Resolve each observed runtime class through Julia's concrete method
            # dispatch. Iterating every abstractly-applicable method and then every
            # runtime class formed a redundant method×class subtype cross-product,
            # and could enroll shadowed methods that Julia would never call. Dart's
            # selector rows likewise contain the concrete target selected for each
            # instantiated class. Discovery still feeds both inline switches and
            # dispatch tables; there is no target-count cap.
            # dart builds a row for every class of the component that can reach the
            # slot: concrete structs, and — boxed behind the same $JlTop classId header —
            # the numerics and the classed String/Symbol (`==(::Any, ::String)` over
            # Any[1, "x", 2.5] needs the Int64/Float64/String rows; without them the
            # switch had no row and trapped at runtime), and a tuple, classed alike.
            for target_type in runtime_types
                (isconcretetype(target_type) &&
                 (isstructtype(target_type) || isprimitivetype(target_type)) &&
                 target_type <: atypes[p]) || continue
                spec = ntuple(j -> j == p ? target_type : atypes[j], length(atypes))
                concrete_args = Tuple{spec...}
                if !p0_hasmethod("tc861", g, concrete_args)
                    # the call throws Julia's MethodError for this class: its args tuple
                    # (formal(dev/formal/ClassIdSwitch.tla): ThrowWhereJuliaThrows)
                    if all(t -> isconcretetype(t) && !(t <: Type), spec)
                        push!(error_args, concrete_args)
                        push!(get!(() -> Set{Any}(), P0_NOMETHOD, Core.Typeof(g)), concrete_args)
                        push!(error_args, Core.Typeof(g))   # the error's `f`, a class too
                    end
                    continue
                end
                m = p0_which("tc870", g, concrete_args)
                ssig = Tuple{Core.Typeof(g), spec...}
                ssig <: m.sig || continue
                # the static parameters' values at ssig, as Julia's match computes them
                cmi = CC.specialize_method(m, ssig,
                    ccall(:jl_type_intersection_with_env, Any, (Any, Any), ssig, m.sig)[2])
                cmi in seen && continue
                push!(seen, cmi)
                push!(out, cmi)
                reasons[cmi] = _enrollment_text("the dispatch candidate for runtime class $(target_type) of",
                                                ci, src, sidx, node)
            end
        end
    end

    flush_callable_invocations!()
    # Each function-local callable/signature pair becomes one typed body
    # specialization. Never form a component-wide Cartesian product: dart's
    # selector rows are call-site scoped, and unrelated same-arity signatures
    # must not enroll new bodies.
    # formal(dev/formal/Enrollment.tla): for every class that may reach the call, the body
    # Julia selects is enrolled: Julia's own matching of the call's static signature
    # (Base._methods_by_ftype) gives every method whose parameter types intersect it, each
    # specialized at the intersection (a method narrower than an erased argument included;
    # the entry tries them in Julia's specificity order, closures.jl). A method with static
    # parameters a match leaves unfixed is enrolled at each tuple of candidates (below)
    local observed_classes = sort!(Any[Any[C for C in runtime_types
                                             if isconcretetype(C) && (isstructtype(C) || isprimitivetype(C))];
                                         collect(held_type_objects)]; by=type_order_key)
    P0_CLASSES[] = observed_classes
    for (_T, ds) in callable_invocations
        # each tuple of candidates for which the callable has no method: the call throws Julia's
        # MethodError there, its args a tuple of the values' classes (a type object's class is
        # its kind), numbered for the entry to build (formal(dev/formal/ClassIdSwitch.tla):
        # ThrowWhereJuliaThrows)
        local _ech = Vector{Any}[dispatch_candidates(P, observed_classes) for P in ds]
        # a method whose signature covers the call's static one leaves no tuple without a method
        local _all = p0_mbf("tc906", Tuple{_T, ds...}, nothing, -1, Base.get_world_counter())
        local _covered = _all !== nothing && any(m -> Tuple{_T, ds...} <: m.method.sig, _all)
        if !_covered && !any(isempty, _ech) && prod(length, _ech; init=1) <= 4096
            for cs in Iterators.product(_ech...)
                local _none = p0_mbf("tc910", Tuple{_T, cs...}, nothing, -1, Base.get_world_counter())
                (_none === nothing || !isempty(_none)) && continue
                local _rt = Any[(C isa DataType && C.name === Type.body.name) ? typeof(C.parameters[1]) : C for C in cs]
                all(t -> t isa DataType && isconcretetype(t), _rt) && (push!(error_args, Tuple{_rt...}); push!(get!(() -> Set{Any}(), P0_NOMETHOD, _T), Tuple{_rt...}))
            end
        end
        local enroll_closure!(cmi, at) = (cmi === nothing || cmi in seen) ? nothing :
            (push!(seen, cmi); push!(out, cmi);
             reasons[cmi] = "the body of the closure $(_T), constructed and called dynamically with ($(join(ds, ", ")))" * at;
             nothing)
        local _mms2 = p0_mbf("tc920", Tuple{_T, ds...}, nothing, -1, Base.get_world_counter())
        for mm in (_mms2 === nothing ? () : _mms2)
            # a match is one signature when its intersection is a DataType and every static
            # parameter has a value; otherwise (a UnionAll, or a static parameter left a TypeVar,
            # A8C6) Julia specializes it at each argument's class when it runs
            if mm.spec_types isa DataType && !any(sp -> sp isa TypeVar, mm.sparams)
                enroll_closure!(CC.specialize_method(mm.method, mm.spec_types, mm.sparams), "")
                continue
            end
            # the classes the program instantiates are every class a value can have (the
            # closed world, as the candidate loop above reads it): the method is enrolled at
            # each tuple of candidates over the positions its static parameters mention, the
            # other positions kept as the call has them (formal(dev/formal/Enrollment.tla):
            # PFix); a method no candidate tuple fixes is reached by no value, the candidates
            # being every class numbered and every type object a value may be (held)
            local msig = Base.unwrap_unionall(mm.method.sig)
            local param(p) = Base.unwrapva(msig.parameters[min(p + 1, length(msig.parameters))])
            local mentions(p) = (P = param(p); P isa TypeVar || Base.has_free_typevars(P))
            local admits(C, p) = (P = param(p); P isa TypeVar && (P = P.ub); typeintersect(C, P) !== Union{})
            local observed = sort!(Any[Any[C for C in runtime_types
                                           if isconcretetype(C) && (isstructtype(C) || isprimitivetype(C))];
                                       collect(held_type_objects)]; by=type_order_key)
            local choices = [!mentions(p) ? Any[ds[p]] :
                             Any[C for C in dispatch_candidates(ds[p], observed) if admits(C, p)] for p in eachindex(ds)]
            for cs in Iterators.product(choices...)
                local cms = p0_mbf("tc945", Tuple{_T, cs...}, nothing, -1, Base.get_world_counter())
                for cm in (cms === nothing ? () : cms)
                    (cm.method === mm.method && cm.spec_types isa DataType) || continue
                    enroll_closure!(CC.specialize_method(cm.method, cm.spec_types, cm.sparams),
                                    ", at the observed classes ($(join(cs, ", ")))")
                end
            end
        end
    end
    return out
end

"""
    _fused_multiply_add_mis(codeinfos, scanned) -> Vector{Any}

The `Base.fma_emulated` MethodInstances that the collected bodies' `muladd_float` and
`fma_float` intrinsic calls lower to (julia_numeric_tier.jl `FMA_OPS`), one per float type:
Julia's own software fma, which rounds once.
parity(quarantine: WASM has no scalar FMA instruction, so the intrinsic's lowering is a call
of Julia's software fma, which the closed world must hold.)
"""
function _fused_multiply_add_mis(codeinfos::Vector{Any}, scanned::Base.IdSet{Any})::Vector{Any}
    types = Set{Type}()
    for k in 2:2:length(codeinfos)
        src = codeinfos[k]
        (src isa Core.CodeInfo && !(src in scanned)) || continue
        push!(scanned, src)
        for rec in build_nir(src)
            rec.node isa NirCall || continue
            f = _nir_callee_object(rec.node.callee)
            (f === Core.Intrinsics.muladd_float || f === Core.Intrinsics.fma_float) || continue
            T = CC.widenconst(rec.julia_type)
            (T === Float64 || T === Float32) && push!(types, T)
        end
    end
    return Any[CC.specialize_method(p0_which("tc980fma", Base.fma_emulated, (T, T, T)),
                                    Tuple{typeof(Base.fma_emulated), T, T, T}, Core.svec())
               for T in types]
end

"""
The closed world one collection built (collect_closed_world): the collected (CodeInstance,
CodeInfo) pairs; the dynamic-dispatch selector roots, distinct from the ordinary dependencies
their compilation reaches; the callable types whose bodies the candidate fixpoint enrolled;
why each MethodInstance entered it, for a later failure — declaring its signature — to name;
and the `Type{X}` of each type object a value may be (`held_type_objects`), a candidate wherever
a class is.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
struct ClosedWorld
    codeinfos::Vector{Any}                # alternating CodeInstance, CodeInfo
    dynamic_roots::Set{Core.MethodInstance}          # enrolled as selector candidates
    callable_types::Set{DataType}                    # callable types whose bodies the candidate fixpoint enrolled
    enrolled_as::IdDict{Core.MethodInstance,String}  # why each entered the closed world
    held_type_objects::Set{DataType}                 # the Type{X} of each type object the program holds
    error_args_types::Set{DataType}                  # the args tuple (and `f`) of each MethodError a dynamic call throws
end

"""Cut the bodies of declared imports (external leaves) out of a collection before it merges:
keep the code the entries reach over the closed world's edges (`_closed_world_edge`, the
relation the collector enrolls by), never walking into or keeping an import's body. It runs at
every merge, on Julia's first collection and on each later round's compile! output, and is the
collection's only cut: a body an edge of a kept body names is kept, whatever its kind.
parity(quarantine: Julia's native fallback bodies of a declared import are inferred with its
callers but are not the Wasm component's; dart's imports have no Dart body.)"""
function _prune_external_leaf_subgraphs(codeinfos::Vector{Any}, entries::Vector{Any},
                                        external_leaves::Set{Any})::Vector{Any}
    isempty(external_leaves) && return codeinfos
    interp = WasmInterpreter(Base.RefValue(0))
    joins = IdDict{Core.CodeInfo,Dict{Int,Type}}()
    pairs = Dict{Any,Tuple{Any,Core.CodeInfo}}()
    for i in 1:2:length(codeinfos)
        (i + 1 <= length(codeinfos) && codeinfos[i] isa Core.CodeInstance &&
         codeinfos[i + 1] isa Core.CodeInfo) || continue
        mi = codeinfos[i].def isa Core.MethodInstance ? codeinfos[i].def : codeinfos[i].def.def
        pairs[mi] = (codeinfos[i], codeinfos[i + 1])
    end
    reachable = Set{Any}()
    queue = Any[entries...]
    while !isempty(queue)
        mi = pop!(queue)
        mi in reachable && continue
        push!(reachable, mi)
        mi in external_leaves && continue
        pair = get(pairs, mi, nothing)
        pair === nothing && continue
        local pair_slot_types = nir_slot_types(pair[2])
        local pair_nir = build_nir(pair[2])
        local arg_type = _edge_arg_type(pair[2], pair_nir, pair_slot_types, joins)
        # every edge, of every kind the collector enrolls by: a kind missing here would cut a
        # body Julia's queue collected through it (1.13's `:new` of a closure, b107)
        for s in pair_nir
            local edge = _closed_world_edge(s.node, pair[2], pair_slot_types, arg_type, interp)
            edge === nothing || push!(queue, edge[2])
        end
    end
    out = Any[]
    for i in 1:2:length(codeinfos)
        (i + 1 <= length(codeinfos) && codeinfos[i] isa Core.CodeInstance &&
         codeinfos[i + 1] isa Core.CodeInfo) || continue
        mi = codeinfos[i].def isa Core.MethodInstance ? codeinfos[i].def : codeinfos[i].def.def
        mi in reachable || continue
        mi in external_leaves && continue
        push!(out, codeinfos[i], codeinfos[i + 1])
    end
    return out
end

# Julia 1.13.0-rc4 added a REQUIRED `external_linkage::Bool` keyword to
# Compiler.compile! (typeinfer.jl): `true` skips a CodeInstance already compiled
# into the sysimage and links to it instead — juliac's case. WasmTarget has no
# image to link against; every reachable method must enter the closed world, so
# the value is `false` — the ClosedWorld.tla Completeness invariant, stated as a
# keyword. Keyed on the method's actual signature, not on a version number.
# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
const _COMPILE_KW = :external_linkage in Base.kwarg_decl(first(methods(CC.compile!))) ?
    (; external_linkage = false) : (;)

# formal(dev/formal/ClosedWorld.tla): the shared edge/dynamic-dispatch/intrinsic-body
# fixpoint below collects every method reachable from the roots (Completeness) and no
# declared import's body at any round (LeavesNeverCollected), never stops early, never
# drops a collected body, and never silently drops a reachable method whose specialization
# fails. It does not guarantee minimality: a widened original Julia's queue materialized that
# no live edge names stays collected as dead code (NoGarbage, MARCH 13.17 H9). Every dynamic
# candidate is a dispatch root, collected first or not (RootsComplete).
"""
    collect_closed_world(entries::Vector{Any}; verify::Bool=false) -> ClosedWorld

Collect the closed transitive callgraph for the given entry
`MethodInstance`s under the WASM overlay interpreter. With `verify=true`,
run the upstream trim verifier (throws `Core.TrimFailure` with
source-located diagnostics when dynamic dispatch remains — the same
"abstract inference unsupported" boundary WasmTarget's diagnostics guard,
but reported far better).
WASMTARGET dynamic dispatch: trim/inference drops `dynamic` calls (open-world) —
the applicable method specializations are never collected, so func_registry has
nothing for the call site to dispatch over. Scan the collected IR for dynamic
calls `g(…, x::abstract, …)` and return the MethodInstances of the applicable
CONCRETE-STRUCT specializations, so a follow-up collection round compiles them
(then `_try_inline_typeid_dispatch` builds a runtime typeId switch over them).
Surfaced by Markdown.plain/show recursion over heterogeneous AST nodes.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from
its front end's whole-program type flow analysis.)
"""
function collect_closed_world(entries::Vector{Any}; verify::Bool=false,
                              external_leaves::Set{Any}=Set{Any}())::ClosedWorld
    local callable_types = Set{DataType}()
    local dynamic_roots = Set{Core.MethodInstance}()
    local held_types = Set{DataType}()
    local error_args_types = Set{DataType}()
    # Fresh cache partition per collection: see cache_token in WasmInterpreter.
    interp = WasmInterpreter(Base.RefValue(0))
    invokelatest_queue = CC.CompilationQueue(; interp)
    codeinfos = Any[]
    workqueue = CC.CompilationQueue(; interp)
    append!(workqueue, entries)
    CC.compile!(codeinfos, workqueue; invokelatest_queue, _COMPILE_KW...)
    CC.compile!(codeinfos, invokelatest_queue; invokelatest_queue, _COMPILE_KW...)
    # Imports are typed call-graph leaves. Julia inference may inspect their
    # native fallback bodies, but those bodies and their dependencies do not
    # belong to the Wasm component. Cut them before invoke completion and
    # dynamic-dispatch discovery so external implementation details can never
    # contaminate the closed world.
    codeinfos = _prune_external_leaf_subgraphs(codeinfos, entries, external_leaves)
    # Julia's queue may leave an explicit invoke with an abstract callable slot
    # as an IR edge without materializing its body (e.g. Base.with_output_color's
    # `Function` argument). A closed world cannot defer that edge to codegen.
    # Enroll every edge's target (_closed_world_edge) to a fixpoint before selector discovery.
    base_mis = Set{Any}()
    mi_key(mi) = (mi.def, mi.specTypes)
    base_mi_keys = Set{Any}()
    for k in 1:2:length(codeinfos)
        if k + 1 <= length(codeinfos) && codeinfos[k] isa Core.CodeInstance &&
           codeinfos[k + 1] isa Core.CodeInfo
            mi = codeinfos[k].def
            push!(base_mis, mi)
            push!(base_mi_keys, mi_key(mi))
        end
    end
    invoke_seen = union(copy(base_mis), external_leaves)
    seen_disp = Set{Any}()
    # why each MethodInstance entered the closed world, for a collection failure to name (the
    # plan adds each body's edge targets Julia's queue collected, trim_compile_plan)
    enrolled_by = IdDict{Core.MethodInstance,String}(e => "a compilation entry" for e in entries)

    # Explicit invokes and dynamic-dispatch candidates form ONE reachability
    # problem. Either class can add IR containing edges of the other class, so
    # sequential fixpoints are insufficient. Iterate both collectors together
    # until neither can add a MethodInstance; every collection uses a fresh
    # interpreter/cache partition and only new pairs are merged.
    function collect_new_pairs!(mis; why::String="a compilation entry")
        isempty(mis) && return false
        local batch = Tuple{Any,String}[]   # (resolved root, why it was enrolled)
        fresh_interp = WasmInterpreter(Base.RefValue(0))
        fresh_ci = Any[]
        fresh_wq = CC.CompilationQueue(; interp=fresh_interp)
        fresh_ilq = CC.CompilationQueue(; interp=fresh_interp)
        added = false
        for root_mi in mis
            # Resolve in the partition's overlay method table. Reusing a native
            # MethodInstance manufactures the wrong static-parameter environment
            # when an overlay or UnionAll match participates, even when its printed
            # `specTypes` happens to be identical.
            matches = CC.findall(root_mi.specTypes,
                CC.method_table(fresh_interp); limit=-1)
            (matches === nothing || isempty(matches)) &&
                error("no Wasm overlay match for closed-world root $(root_mi.specTypes)")
            # the root's own method (or the overlay that shares its signature): an explicit
            # `invoke` of a less specific method names that method, which dispatch on its
            # argument types alone would not select
            local pick = 0
            if root_mi.def isa Method
                for (k, m) in enumerate(matches)
                    if m.method.sig == root_mi.def.sig
                        pick = k
                        break
                    end
                end
            end
            resolved_mi = pick > 0 ? CC.specialize_method(matches[pick]) :
                (root_mi.def isa Method && matches[1].method.sig != root_mi.def.sig &&
                 root_mi.specTypes <: root_mi.def.sig) ?
                    CC.specialize_method(root_mi.def, root_mi.specTypes, root_mi.sparam_vals) :
                    CC.specialize_method(matches[1])
            # Candidate discovery initially selects with Julia dispatch, then
            # collection canonicalizes through the Wasm overlay table. Record the
            # canonical MI as a selector root too: the collected body is the overlay
            # one, and the plan keys its dispatch candidates by the collected MI
            # (`mi in world.dynamic_roots`), not by its native precursor of the
            # same signature but a different Method object.
            root_mi in dynamic_roots && push!(dynamic_roots, resolved_mi)
            push!(fresh_wq, resolved_mi)
            push!(batch, (resolved_mi, get(enrolled_by, root_mi, why)))
            haskey(enrolled_by, resolved_mi) || (enrolled_by[resolved_mi] = batch[end][2])
        end
        try
            CC.compile!(fresh_ci, fresh_wq; invokelatest_queue=fresh_ilq, _COMPILE_KW...)
            CC.compile!(fresh_ci, fresh_ilq; invokelatest_queue=fresh_ilq, _COMPILE_KW...)
        catch err
            # an interrupt or exhausted memory is the process's, not a root's: never re-inferred
            (err isa WasmInternalError || err isa InterruptException || err isa OutOfMemoryError) && rethrow()
            throw_located_collection_failure(batch, err, catch_backtrace(), _compile_root_alone)
        end
        # Every compile! output is cut by the external leaves before it merges, exactly as the
        # first collection is (above): a later round's root may call a declared import, and
        # Julia's queue then infers the import's native fallback body with it. That body is
        # not the Wasm component's, and merged it would compile in the import's place.
        fresh_ci = _prune_external_leaf_subgraphs(fresh_ci, Any[first.(batch)...], external_leaves)
        for k in 1:2:length(fresh_ci)
            (fresh_ci[k] isa Core.CodeInstance &&
             fresh_ci[k + 1] isa Core.CodeInfo) || continue
            mi = fresh_ci[k].def
            mi_key(mi) in base_mi_keys && continue
            push!(base_mis, mi)
            push!(base_mi_keys, mi_key(mi))
            push!(codeinfos, fresh_ci[k], fresh_ci[k + 1])
            added = true
        end
        return added
    end

    fma_scanned = Base.IdSet{Any}()
    # the loop only adds: no collected body is ever dropped (dart's worklist only adds too)
    while true
        changed = collect_new_pairs!(_missing_explicit_invoke_mis(
            codeinfos, invoke_seen; reasons=enrolled_by))

        extra = _dynamic_dispatch_candidate_mis(codeinfos, seen_disp, entries; reasons=enrolled_by, held=held_types,
                                                error_args=error_args_types)
        # Every candidate is a dispatch root, and its callable type a callable type, whether or
        # not its body is collected already: on 1.13 Julia's queue collects a closure body by
        # its `:new` before the dynamic step names it, and the plan's rows must not depend on
        # which edge reached the body first (ClosedWorld.tla RootsComplete). Only the bodies
        # still missing are collected.
        union!(dynamic_roots, extra)
        for mi in extra
            local st = mi.specTypes
            if st isa DataType && st <: Tuple && length(st.parameters) >= 1
                local ft = st.parameters[1]
                ft isa DataType && ft <: Function && push!(callable_types, ft)
            end
        end
        changed |= collect_new_pairs!(Any[mi for mi in extra if !(mi_key(mi) in base_mi_keys)])
        fma_mis = Any[mi for mi in _fused_multiply_add_mis(codeinfos, fma_scanned)
                   if !(mi_key(mi) in base_mi_keys)]
        changed |= collect_new_pairs!(fma_mis;
                                      why="the Julia body of the fma/muladd intrinsic lowering")
        changed || break
    end

    # WASMTARGET dynamic dispatch: discover every target admitted by the closed component.
    # It is compilation correctness and has no environment opt-out or arbitrary round/method ceiling.
    # T1.1 step 1 (NON-PERTURBING collection): specializations reached only via `dynamic`
    # calls (markdown plain/show over heterogeneous AST nodes, abstract-keyed Dict
    # hash/isequal, …) are collected in a SEPARATE interpreter + collection, then only the
    # NEW (CodeInstance, CodeInfo) pairs are MERGED into `codeinfos` (deduped by
    # MethodInstance). The previous approach re-ran CC.compile! on the SHARED `interp`
    # after the base pass, which perturbed base inference (re-collected already-present MIs
    # with different IR → order-dependent codegen bugs in unrelated code). A fresh interp
    # (distinct cache_owner) + merge leaves every base pair byte-identical, so enabling
    # discovery cannot change how base functions compile (the COLLECTION layer). Registry
    # isolation — candidates hidden from get_function's signature lookup, an :invoke still
    # reaching one by its MethodInstance — is step 2 (FunctionInfo.is_candidate). With layers
    # 1+2 in place, plus discovery yielding
    # to for megamorphic (≥9-method) functions, the base pass is byte-identical
    # whether or not discovery runs.
    if verify
        CC.verify_typeinf_trim(codeinfos, #= onlywarn =# false)
    end
    return ClosedWorld(codeinfos, dynamic_roots, callable_types, enrolled_by, held_types, error_args_types)
end

"""
    entry_method_instance(f, arg_types::Tuple) -> MethodInstance

Resolve the `MethodInstance` for `f(::arg_types...)` — the entry handle
`collect_closed_world` consumes.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function entry_method_instance(f, arg_types::Tuple)::Core.MethodInstance
    tt = Tuple{Core.Typeof(f), arg_types...}
    m = p0_which("tc1266entry", f, arg_types)
    return CC.specialize_method(m, tt, Core.svec())
end


"""
The compile inputs one closed world yields (trim_compile_plan): every function to compile as
(f, arg_types, name, MethodInstance) — entries keep their given names, the rest get deduped
names; the (f, arg_types) and MethodInstance → (CodeInfo, rettype) cache get_typed_ir serves,
so every function compiles from the collection's consistent-world IR; the (f, arg_types) keys
discovered solely as dynamic-dispatch candidates; the MethodInstances reached only through an
`invoke` of a method dispatch would not select for their argument types; the callable types
the candidate fixpoint enrolled; why each MethodInstance was enrolled; and the `Type{X}` of each
type object a value may be (ClosedWorld's `held_type_objects`), which the vtable pre-pass's
ambiguity search asks about.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
struct ClosedWorldPlan
    functions::Vector{Any}
    ir_cache::IdDict{Any,Tuple{Core.CodeInfo,Any}}
    dispatch_candidates::Set{Any}
    invoke_only::Set{Core.MethodInstance}
    callable_types::Set{DataType}
    enrolled_as::IdDict{Core.MethodInstance,String}
    held_type_objects::Set{DataType}   # the Type{X} of each type object the program holds
    error_args_types::Set{DataType}    # the args tuple of each MethodError a dynamic call throws
end

"""
    plan_ir(plan, mi) -> (CodeInfo, return type)

The collected closed world's typed IR of one MethodInstance: the only IR codegen reads (L152).
A MethodInstance outside the closed world is an error, never a second inference (which would
run another interpreter, at another world, in another cache partition).
parity(quarantine: Julia's typed IR is WT's frontend input, asked of Julia's own inference; dart2wasm receives Kernel already built by the CFE.)
"""
function plan_ir(plan::ClosedWorldPlan, mi::Core.MethodInstance)::Tuple{Core.CodeInfo,Any}
    local hit = get(plan.ir_cache, mi, nothing)
    hit === nothing && error("$(mi) is outside the collected closed world; codegen reads the " *
                             "collection's IR, never a second inference")
    return hit[1], hit[2]
end

"""
    trim_compile_plan(entries_named) -> ClosedWorldPlan

Run `collect_closed_world` over the named entry points and derive the compile inputs
(ClosedWorldPlan).

Skipped (with a debug note): non-singleton callables (stateful closures —
their call sites inline or carry the closure value; no module-level
function entry to register) and Core/internal entries without a usable
function object.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function trim_compile_plan(entries_named::Vector; external_entries::Vector=Any[])::ClosedWorldPlan
    entry_mis = Any[]
    entry_keys = Dict{Any, String}()   # mi → requested name
    entry_values = Dict{Any,Any}()     # explicit capturing-closure instances
    for (f, arg_types, name) in entries_named
        mi = entry_method_instance(f, arg_types)
        push!(entry_mis, mi)
        entry_keys[mi] = name
        entry_values[mi] = f
    end
    external_mis = Set{Any}()
    for entry in external_entries
        f, arg_types = entry[1], entry[2]
        push!(external_mis, entry_method_instance(f, arg_types))
    end
    empty!(P0_NOMETHOD)
    local world = collect_closed_world(entry_mis; external_leaves=external_mis)
    codeinfos = world.codeinfos

    functions = Any[]
    ir_cache = IdDict{Any, Tuple{Core.CodeInfo, Any}}()
    collected_method_specs = Set{Any}()
    for j in 1:2:length(codeinfos)
        j + 1 <= length(codeinfos) || continue
        codeinfos[j] isa Core.CodeInstance || continue
        codeinfos[j + 1] isa Core.CodeInfo || continue
        cmi = codeinfos[j].def isa Core.MethodInstance ? codeinfos[j].def : codeinfos[j].def.def
        push!(collected_method_specs, (cmi.def, cmi.specTypes))
    end
    # A capturing closure a collected body invokes statically (Base's reallocating
    # `_growend!`/`_growbeg!` closures) is a direct call of a known method: its body is
    # compiled like the invoker's, keyed by the closure type (dart: a closure's target is
    # compiled when the closure is created). Dynamic calls of Base closures stay out.
    # Each edge target Julia's queue collected (_closed_world_edge: an :invoke callee, an
    # atomic modify's operator, 1.13's constructed closure body, ...) is enrolled by the first
    # statement naming it.
    invoked_closures = Set{DataType}()
    local enrolled_as = world.enrolled_as
    local edge_interp = WasmInterpreter(Base.RefValue(0))
    local edge_joins = IdDict{Core.CodeInfo,Dict{Int,Type}}()
    for j in 1:2:length(codeinfos)
        (j + 1 <= length(codeinfos) && codeinfos[j + 1] isa Core.CodeInfo) || continue
        local src = codeinfos[j + 1]
        local nir = build_nir(src)
        local slot_types = nir_slot_types(src)
        local arg_type = _edge_arg_type(src, nir, slot_types, edge_joins)
        for (k, s) in enumerate(nir)
            local n = s.node
            local edge = _closed_world_edge(n, src, slot_types, arg_type, edge_interp)
            edge === nothing && continue
            haskey(enrolled_as, edge[2]) ||
                (enrolled_as[edge[2]] = _enrollment_text(_EDGE_ENROLLMENT[edge[1]], codeinfos[j], src, k, n))
            edge[1] === :invoke || continue
            local st = edge[2].specTypes
            (st isa DataType && length(st.parameters) >= 1) || continue
            local ft = st.parameters[1]
            ft isa DataType && is_closure_type(ft) && push!(invoked_closures, ft)
        end
    end
    # Functions pulled in only by dispatch-candidate discovery are registered as
    # candidates rather than ordinary direct-call targets.
    dispatch_candidates = Set{Any}()
    # Pre-seed with entry names: a discovered function processed before its
    # same-named entry must not claim the entry's export name (duplicate-export
    # validation failure in multi-function modules).
    used_names = Set{String}(values(entry_keys))
    # One function per MethodInstance (dart keys a function by its member's Reference). Two
    # methods can share one specialization's argument types — Base calls a less specific
    # method with `invoke(f, Tuple{Super}, x)` — so (f, arg_types) does not name a function.
    seen_mis = Set{Tuple{Any, Any}}()          # (mi.def, mi.specTypes)
    mis_by_sig = Dict{Tuple{Any, Any}, Vector{Any}}()
    i = 1
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        sig = mi.specTypes
        # a collected body whose specialization is not one signature (a UnionAll, left by a
        # method with static parameters) would be planned as no function: a call reaching it
        # would run another
        (sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1) ||
            throw(WasmInternalError(string(mi), 0, "",
                String["planning the closed world: $(mi) was collected at $(sig), not one signature"],
                ErrorException("a collected MethodInstance whose specTypes is not a DataType"),
                Base.StackTraces.StackFrame[]))
        ftyp = sig.parameters[1]
        f = get(entry_values, mi, nothing)
        if f !== nothing
            # Explicit roots retain their actual value. This is load-bearing for
            # capturing closures: the type has no singleton instance, while root
            # bindings may validly substitute every captured field and elide the
            # runtime closure context.
        elseif ftyp isa DataType && isdefined(ftyp, :instance)
            f = ftyp.instance            # singleton functions incl. Core.kwcall
        elseif ftyp isa DataType && ftyp <: Type && length(ftyp.parameters) >= 1
            f = ftyp.parameters[1]       # constructors: Type{T} → T
            (f isa DataType || f isa UnionAll) || (f = nothing)
        elseif ftyp isa DataType && is_closure_type(ftyp)
            # A CAPTURING closure has no instance — key its body by the
            # closure TYPE (the vtable machinery resolves by type; no static
            # caller resolves these by value). dart: creating a Lambda compiles
            # its target. USERLAND ONLY: converting Base-internal closure pairs
            # (previously skipped) changed unrelated compiles — randsubseq's
            # internals regressed in the suite context (the march-16 gate catch).
            (ftyp in world.callable_types || ftyp in invoked_closures ||
             ftyp <: _RuntimeComposition) && (f = ftyp)
        end
        if f === nothing
            @debug "trim_compile_plan: skipping non-singleton callable" sig
            continue
        end
        arg_types = Tuple(sig.parameters[2:end])
        # Inference may additionally collect `f(::Type{T})` for a method whose
        # declared formal is the type object's runtime representation class
        # (`DataType`, `UnionAll`, ...). If the same collection already contains
        # that canonical specialization, the singleton copy is redundant and
        # can expose constant-specific inlining that the Wasm ABI cannot
        # distinguish. Keep explicit Type{T} roots, but collapse transitive copies
        # only when method identity + canonical spec are both present.
        if !haskey(entry_keys, mi)
            local msig = Base.unwrap_unionall(mi.def.sig)
            if msig isa DataType && msig <: Tuple &&
               length(msig.parameters) == length(arg_types) + 1
                local canonical_args = Tuple(
                    _canonical_type_object_arg(arg_types[j], msig.parameters[j + 1])
                    for j in eachindex(arg_types))
                local canonical_sig = Tuple{sig.parameters[1], canonical_args...}
                if canonical_args != arg_types &&
                   (mi.def, canonical_sig) in collected_method_specs
                    continue
                end
            end
        end
        # An unspecialized `Vararg{T}` is not a physical Wasm parameter. Calls
        # with a known arity are represented by their concrete specialization;
        # intrinsic/error constructors are lowered at the call site. Never let
        # the open-ended signature become a second, fake compilation route.
        # THE ONE EXCEPTION, and it is a representation fact, not a route: a
        # homogeneous runtime Vararg tuple (`is_runtime_vararg_tuple_type`,
        # structs.jl) IS one physical parameter — the `{Object, data, size}`
        # struct the splat call site already holds. The signature becomes that
        # single packed parameter, which is what the body reads: values.jl's
        # `packed_vararg_source_type` returns `nothing` for a one-parameter tail
        # that already IS the source tuple, so the argument is a direct
        # `local.get` of the struct instead of a reconstructed fixed tuple.
        # parity(quarantine: Julia varargs).
        if any(T -> T isa Core.TypeofVararg, arg_types)
            local packed_vararg = Tuple{arg_types...}
            is_runtime_vararg_tuple_type(packed_vararg) || continue
            arg_types = (packed_vararg,)
        end
        # `check_world_bounded(::TypeName)` is a closed-world metadata operation,
        # lowered directly at its call site from TypeName constants. Enrolling
        # Base's mutable BindingPartition walker would create a second runtime
        # route and require Julia-internal mutable-world objects WT does not own.
        ((f === Base.check_world_bounded || f === _closed_world_type_bounds) &&
         arg_types == (Core.TypeName,)) && continue
        ((f === Base.isvisible || f === _closed_world_isvisible) &&
         arg_types == (Symbol, Module, Module)) && continue
        # a discovery candidate can repeat an explicitly listed specialization (the first
        # occurrence wins: entries are processed first)
        ((mi.def, mi.specTypes) in seen_mis) && continue
        push!(seen_mis, (mi.def, mi.specTypes))
        push!(get!(() -> Any[], mis_by_sig, (f, arg_types)), mi)
        # name: requested for entries, deduped method name otherwise
        name = get(entry_keys, mi, nothing)
        if name === nothing
            base = mi.def isa Method ? string(mi.def.name) : string(nameof(f))
            name = base
            n = 1
            while name in used_names
                name = string(base, "_", n)
                n += 1
            end
        end
        push!(used_names, name)
        push!(functions, (f, arg_types, name, mi))
        ir_cache[mi] = (src, ci.rettype)
        # Only discovery ROOTS are selector candidates. Dependencies compiled
        # transitively with a root remain ordinary cross-call-visible functions.
        if mi in world.dynamic_roots && !haskey(entry_keys, mi)
            push!(dispatch_candidates, (f, arg_types))
        end
    end
    # (f, arg_types) names the function Julia's dispatch selects for those types: where two
    # collected methods share them, the other one is reached only by its `invoke`
    # (FunctionInfo.invoke_only) and never by a call that names (f, arg_types).
    invoke_only = Set{Core.MethodInstance}()
    local mt = CC.method_table(get_wasm_interpreter())
    for (key, mis) in mis_by_sig
        local winner = if length(mis) == 1
            only(mis)
        else
            local match = CC.findsup(first(mis).specTypes, mt)[1]
            local w = match === nothing ? nothing : findfirst(m -> m.def === match.method, mis)
            w === nothing ? nothing : mis[w]
        end
        winner === nothing || (ir_cache[key] = ir_cache[winner])
        for m in mis
            m === winner || push!(invoke_only, m)
        end
    end
    # every planned function says why it is in the closed world; one that cannot is a
    # collector defect, raised here rather than guessed at when a later failure names it
    for fn in functions
        haskey(enrolled_as, fn[4]) || throw(WasmInternalError(fn[3], 0, "",
            String["planning the closed world: $(fn[3]) was collected with no recorded reason"],
            ErrorException("no enrollment reason for $(fn[4])"), Base.StackTraces.StackFrame[]))
    end
    return ClosedWorldPlan(functions, ir_cache, dispatch_candidates, invoke_only,
                           world.callable_types, enrolled_as, world.held_type_objects,
                           world.error_args_types)
end

# ============================================================================
# The closed-world type collector — reads the NIR bodies the planner built
# ============================================================================

# parity(quarantine: Julia's IR node types — Expr, SSAValue, PhiNode, … — which a CodeInfo holds
# as literal operands but which are IR structure, never program values.)
const _IR_META_TYPES = Set{DataType}([
    Expr, Core.SSAValue, Core.Argument, GlobalRef, Core.PhiNode, Core.PhiCNode,
    Core.UpsilonNode, Core.GotoNode, Core.GotoIfNot, Core.ReturnNode, LineNumberNode,
    Core.NewvarNode, Core.SlotNumber, Core.MethodInstance, Core.CodeInstance, Core.CodeInfo,
])

"""
    tuple_runtime_type(operands, slot_types) -> Union{Nothing, DataType}

The type of the tuple `Core.tuple` builds from these operands, as jl_f_tuple types it, by each
value's runtime type: a constant operand's value is known, so its type is (a type object's is
its kind, `typeof(Vector)` is UnionAll); any other operand of a concrete static type that is
not a `Type{…}` has that type; a `Type{X}` operand has `typeof(X)`. That last answer is exact
only when X has a unique representation (Julia's tuple_tfunc, `hasuniquerep`): a value equal to
a tuple type with abstract or Vararg parameters may be a UnionAll or a Union, so its tuple is
of another class; telling which at run time is MARCH 13.14's (rejecting there instead would
reject Base's own `_tuple_error(T, x)`). Any other operand leaves the type known only at run
time: nothing. The one answer for `_lower_tuple!`, the collector's
numbering and observation, and a MethodError's args tuple.
parity(quarantine: a Julia tuple is typed by its elements' runtime types; a dart record's shape
is static.)
"""
function tuple_runtime_type(operands::AbstractVector, slot_types::AbstractVector)::Union{Nothing, DataType}
    local rt = Type[]
    for a in operands
        local has, val = a isa NirLiteral ? (true, a.value) :
            (a isa NirGlobalRef && a.bound && isconst(a.mod, a.name)) ? (true, a.value) : (false, nothing)
        if has
            push!(rt, typeof(val))      # a type object's runtime type is its kind
            continue
        end
        local T = _collector_static_type(a, slot_types)
        if T isa DataType && T.name === Type.body.name && length(T.parameters) == 1 &&
           T.parameters[1] isa Type && !(T.parameters[1] isa TypeVar)
            push!(rt, typeof(T.parameters[1]))
        elseif T isa DataType && isconcretetype(T)
            push!(rt, T)
        else
            return nothing
        end
    end
    return Tuple{rt...}
end

"""
    methoderror_args_types(operands, slot_types) -> Union{Nothing, Tuple{Int, Type, Vector{Type}}}

For a MethodError's args tuple whose type `tuple_runtime_type` cannot state, because one
operand's runtime type is known only at run time: that position `p`, its static type, and the
runtime type of every other position (`rt[p]` a placeholder). The tuple is then
`Tuple{rt[1:p-1]..., C, rt[p+1:end]...}` for the class C the value has, which the collector
numbers for each class under the static type and the throw tells at run time by its classId.
Nothing when the tuple's type is stated, or when more than one position is known only at run
time (that throw traps, MARCH 13.17 A3S1).
formal(dev/formal/ClassIdSwitch.tla): the MethodError's args are the value's class (ErrorIsJulias).
parity(quarantine: a Julia MethodError carries its arguments' tuple, typed by their runtime
types; dart's NoSuchMethodError carries an Invocation of its arguments.)
"""
function methoderror_args_types(operands::AbstractVector, slot_types::AbstractVector)::Union{Nothing, Tuple{Int, Type, Vector{Type}}}
    local rt = Type[]
    local p = 0
    for (j, a) in enumerate(operands)
        local t = tuple_runtime_type(NirNode[a], slot_types)
        if t === nothing
            p == 0 || return nothing
            p = j
            push!(rt, Any)
        else
            push!(rt, t.parameters[1])
        end
    end
    p == 0 && return nothing
    return (p, _collector_static_type(operands[p], slot_types), rt)
end

"""
    _collector_static_type(operand, slot_types) -> Type

A static, `ctx`-free echo of `infer_value_type` (context.jl) for the branches that
don't need one — used to reconstruct the composite a call builds (`Core.tuple`'s result,
`Core.throw_methoderror`'s args tuple), so the collector admits the exact class codegen
then builds from the same answer. An SSA use or an argument reads the inferred type the NIR
boundary recorded for it (the same source `ctx.ssa_types`/`ctx.slot_types` are seeded
from); a constant global reads its bound value; a literal its own type.
parity(code_generator.dart:135 getStaticType): an operand's type read through one context.
"""
function _collector_static_type(operand::NirNode, slot_types::AbstractVector)::Type
    if operand isa NirSSA
        return operand.julia_type
    elseif operand isa NirArgument
        return 1 <= operand.n <= length(slot_types) ? slot_types[operand.n] : Any
    elseif operand isa NirGlobalRef
        (operand.bound && isconst(operand.mod, operand.name)) || return Any
        return operand.value isa Type ? Type{operand.value} : typeof(operand.value)
    elseif operand isa NirLiteral
        v = operand.value
        return v isa Type ? Type{v} : v === nothing ? Nothing : typeof(v)
    end
    return Any
end

"""
    _collected_operand_value(operand) -> (Bool, value)

The program value an operand materializes when the NIR boundary knows it statically: a
literal's value (a quoted global read through to its binding), or a bound global's current value (values.jl's global arm bakes a
non-const binding's CURRENT value as a mutable-global initializer, so its type is
reachable too). `(false, nothing)` for an SSA use, an argument, a slot or an unbound
global — values whose types the inferred types already carry.
parity(constants.dart:298 Constants.ensureConstant): a constant operand is a value the module
materializes.
"""
function _collected_operand_value(operand::NirNode)::Tuple{Bool, Any}
    if operand isa NirLiteral
        v = operand.value
        v isa GlobalRef || return (true, v)
        return isdefined(v.mod, v.name) ? (true, getfield(v.mod, v.name)) : (false, nothing)
    end
    (operand isa NirGlobalRef && operand.bound) && return (true, operand.value)
    return (false, nothing)
end

"""
    _collect_reachable_ir_types(function_data) -> Set{DataType}

Phase 12B — the CLOSED-WORLD type collector (dart class_info.dart:864
ClassIdNumbering._number numbers every class of the component ONCE, before codegen, with
no second pass). Reads every function's NIR body (`function_data[i][8]`, built once by the
NIR boundary) — its statements' and slots' inferred types, its signature and return type —
and decomposes Unions, returning EVERY concrete kind reachable from the program that can
carry a classId — structs, closures, `Core.Box`, and primitives (`Char`, `Int128`, a user
`primitive type`, …) — so `assign_type_ids!` numbers the whole world in one DFS and
`ensure_type_id!` never needs to allocate one afterwards. PURE COLLECTION — registration
stays lazy (eager registration reorders field resolution and forks layouts); a collected
type registered later receives its pre-assigned id.

`Memory`/`MemoryRef` ARE admitted (they are `isstructtype` and reachable — e.g. a
type-value `getfield(Memory{UInt8}, :layout)` inside `copy(::Dict)`'s native
`unsafe_copyto!`, which reads a real classId here even though it never boxes a
`Memory` VALUE); WT lowers them to a wasm ARRAY with no classId struct field, so
`dispatch.jl`'s `_classid_dispatchable` carries its OWN, narrower exclusion for the
one place that matters — treating one as a selector-table dispatch axis, which
needs an actual struct to downcast to (the `_la_sub` regression this guards).

A second walk covers what the INFERRED types miss: a value an operand carries itself.
A literal embedded in a statement (constant-folded, never boxed into its own SSA slot —
e.g. inference SROAs `Any[1, 2, 3]` into `Base.getfield((1, 2, 3), i)`, so the tuple
`Tuple{Int64,Int64,Int64}` is no statement's type), an effectively-final GLOBAL BINDING's
bound value (`const D = Dict(...)`; typed IR reads its fields directly off the global
without ever materializing a `Dict{...}`-typed SSA value — `_lower_getglobal!`,
builtins.jl, resolves a global to its value the same way), and a function passed as
ordinary DATA (`Core._apply_iterate(Base.iterate, Core.tuple, itr)` passes the `iterate`
FUNCTION itself as an operand, which needs a classId like any other boxed value). A
call's or invoke's CALLEE is not an operand — a statically-dispatched callee is never
boxed or isa-checked through `ensure_type_id!` — and neither is the C-call preamble of a
foreigncall (its symbol, ABI types and calling convention): only its runtime arguments
are values.

Also reads the slot types: an ARGUMENT slot's own type — e.g. a trailing `Vararg{Any,N}`
parameter packs into ONE Tuple-typed slot (`Base.kwerr(kw, args::Vararg{Any,N})`) — is
neither a statement's type nor in a call-site's flattened argument types. And recurses into a
registered struct's OWN field types (a Tuple's own elements included): a field can
itself be a concrete kind that needs a classId nobody else names — e.g. a closure
struct's captured predicate field `f::typeof(iseven)` — so it is not reachable via any
statement or slot type on its own.
parity(class_info.dart:864 ClassIdNumbering._number): the class set the numbering walks, gathered
before any id is assigned.
"""
function _collect_reachable_ir_types(function_data)::Set{DataType}
    out = Set{DataType}()
    seen = Set{Any}()
    # a throw_methoderror whose args tuple is typed at run time: (p, static type, rt)
    local error_args = Tuple{Int, Type, Vector{Type}}[]
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
        # element E is not a Julia value's type (a value is an NTuple{n,E}), but WT gives
        # every length one {Object, data, size} representation (register_vararg_tuple_type!)
        # whose header names this class, which no value has: typeof rejects, an isa against a
        # tuple type tests the lengths it admits, and a widening of it to a slot of any class
        # rejects, at its statement or in convert_type!, and a PiNode with a local of its own
        # narrowing it to its NTuple builds that NTuple (emit_vararg_to_fixed_tuple!; one with no
        # local, re-emitted where it is read, does not: MARCH 13.17 A9E3)
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
    function value!(operand)
        operand isa NirNode || return
        has, v = _collected_operand_value(operand)
        (has && v !== nothing) || return
        typeof(v) in _IR_META_TYPES && return
        reg!(v isa Type ? v : typeof(v))
        v isa Type || contents!(v, IdSet{Any}())
    end
    # A constant's contents are values the module materializes too (Dates.ISDAYOFWEEK, a
    # Dict of function singletons): the class of every value its object graph reaches —
    # fields, tuple elements, assigned Array/Memory elements — is numbered, as dart numbers
    # the classes of every constant it emits. Bounded: a graph past 4096 objects stops there.
    function contents!(@nospecialize(v), seen::IdSet{Any})
        (length(seen) >= 4096 || v in seen) && return
        push!(seen, v)
        T = typeof(v)
        (v isa Type || v isa Module || v isa Symbol || v isa String || v isa Core.TypeName ||
         T in _IR_META_TYPES) && return
        if v isa Union{Array, GenericMemory}
            for i in eachindex(v)
                isassigned(v, i) || continue
                local x = v[i]
                x isa Type || (reg!(typeof(x)); contents!(x, seen))
            end
        elseif isstructtype(T) && !isprimitivetype(T)
            for i in 1:fieldcount(T)
                isdefined(v, i) || continue
                local x = getfield(v, i)
                x isa Type || (reg!(typeof(x)); contents!(x, seen))
            end
        end
    end
    for fd in function_data
        # Base.rethrow's body (emit_rethrow!) throws Julia's ErrorException at depth 0
        fd[1] === Base.rethrow && (reg!(ErrorException); reg!(String))
        body = fd[8]
        body === nothing && continue
        for at in fd[2]
            reg!(at isa Type ? at : typeof(at))
        end
        reg!(fd[5])
        for rec in body.stmts
            reg!(rec.julia_type)
        end
        for t in body.slot_types
            reg!(t)
        end
        for rec in body.stmts
            node = rec.node
            if node isa NirCall
                # `Core.tuple(a, b, ...)` builds a tuple of its elements' runtime types, the
                # class `_lower_tuple!` builds from the same answer (tuple_runtime_type)
                if node.callee === Core.tuple
                    reg!(tuple_runtime_type(node.operands, body.slot_types))
                elseif node.callee === Core.throw_methoderror
                    # the MethodError it throws and its args tuple (calls.jl
                    # _emit_throw_methoderror!, from the same operand types)
                    reg!(MethodError)
                    local _tt = tuple_runtime_type(node.operands[2:end], body.slot_types)
                    if _tt === nothing
                        local _ea = methoderror_args_types(node.operands[2:end], body.slot_types)
                        _ea === nothing || push!(error_args, _ea)
                    else
                        reg!(_tt)
                    end
                elseif node.callee === Core._apply_iterate
                    # a splat's argument pack is a tuple the LOWERING builds (calls.jl's
                    # _apply_iterate route); an empty collection yields Tuple{}, which no
                    # statement of the program names — the class the MethodError path
                    # then reports
                    reg!(Tuple{})
                end
                foreach(value!, node.operands)
            elseif node isa NirInvoke || node isa NirForeignCall || node isa NirNoOp ||
                   node isa NirUnsupported
                foreach(value!, node.operands)
            elseif node isa NirNew
                value!(node.type_operand)
                foreach(value!, node.operands)
            elseif node isa NirLeave
                foreach(value!, node.enters)
            elseif node isa NirPopException
                value!(node.enter)
            elseif node isa NirLiteral || node isa NirGlobalRef
                value!(node)                    # a statement that IS a value
            end
        end
    end
    # the args tuple of each such throw, for every class a value at its open position may have
    # (the classes numbered above; a tuple class added here is no candidate of another throw)
    local classes = collect(out)
    for (p, S, rt) in error_args, C in classes
        (isconcretetype(C) && C <: S && !(C <: Type) && (isstructtype(C) || isprimitivetype(C))) || continue
        push!(out, Tuple{(j == p ? C : rt[j] for j in eachindex(rt))...})
    end
    return out
end
