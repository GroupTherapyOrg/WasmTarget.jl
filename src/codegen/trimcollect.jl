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
    # `Core.Typeof(value)` intentionally preserves Type{value} singleton precision; the Wasm
    # runtime representation class is its kind, the one `Type{X}` element rule's answer
    local runtime_class = type_element_kind(T)
    runtime_class !== nothing && formal === runtime_class && T <: formal && return formal
    return T
end

# ----------------------------------------------------------------------------------------
# THE consult for which methods Julia selects. Collection, planning and the vtable pre-pass
# ask it, and only it: Julia's own matching in the method table WT compiles with, the
# WasmInterpreter's overlay table at its world (get_wasm_interpreter). Base's own table at the
# latest world is another table, which disagrees wherever an overlay replaces a method. A
# statement's codegen reads the plan and asks no table and no inference (L152, L171).
# ----------------------------------------------------------------------------------------

"""
    wt_method_matches(sig; limit=-1) -> MethodLookupResult | nothing

Every method Julia's matching gives `sig` (`CC.findall`) in the WasmInterpreter's method table,
the overlay table at its world, in that table's order: the overlay's matches (most specific
first, a method a fully covering one makes unreachable left out), then, unless the last of them
fully covers `sig`, the base table's matches no overlay signature contains, in the base table's
order; `nothing` past `limit`. For a concrete `sig` the first match is the method a call runs (an
overlay method that applies covers it).
parity(pkg/dart2wasm/lib/translator.dart:108 Translator.hierarchy): the one class hierarchy the
whole compilation consults.
"""
wt_method_matches(@nospecialize(sig); limit::Int=-1)::Union{Nothing, CC.MethodLookupResult} =
    CC.findall(sig, CC.method_table(get_wasm_interpreter()); limit)

"""
    wt_method_which(sig) -> MethodMatch | nothing

The method Julia's dispatch selects for `sig` in the same table (`CC.findsup`, the lookup
`hasmethod`, `which` and `Base._which` make in Base's table): the overlay table's most specific
method covering `sig` when one does, else the base table's, or `nothing` when neither table has
one covering method (none covers it, or the covering ones are ambiguous).
parity(pkg/dart2wasm/lib/translator.dart:108 Translator.hierarchy): the one class hierarchy the
whole compilation consults.
"""
wt_method_which(@nospecialize(sig))::Union{Nothing, Core.MethodMatch} =
    CC.findsup(sig, CC.method_table(get_wasm_interpreter()))[1]

"""
    wt_dispatch_mi(sig) -> MethodInstance | nothing

The MethodInstance a call of signature `sig` runs: `wt_method_which`'s method, specialized at
`sig` with the static parameters Julia's match computes.
parity(pkg/dart2wasm/lib/translator.dart:108 Translator.hierarchy): the one class hierarchy the
whole compilation consults.
"""
function wt_dispatch_mi(@nospecialize(sig))::Union{Nothing, Core.MethodInstance}
    local m = wt_method_which(sig)
    return m === nothing ? nothing : CC.specialize_method(m)
end

"""
    _match_is_one_signature(m) -> Bool

Whether a match of Julia's (a `Core.MethodMatch` the consult gives) is one signature, the
MethodInstance a call at its types runs: its intersection is one DataType, and every static
parameter it leaves a TypeVar is mentioned only where the argument is one value's dispatch type
(a concrete class that is not a kind, or a `Type{X}`). A TypeVar left there Julia leaves at run
time too (`h(x::Union{T,Nothing}) where T` at Nothing runs with T unbound); one left at an
abstract argument Julia fixes per argument class when it runs, and one left at a kind
(DataType, UnionAll, Union, TypeofBottom) per type object, whose dispatch type is its own
`Type{X}` (A8C6). The one rule for a static signature's match and for a candidate tuple's.
formal(dev/formal/Enrollment.tla): a match at an element of NoFix is no signature (OneSig)
parity(quarantine: Julia selects among a callable's methods by specificity and raises for an
ambiguity; a dart closure has one body.)
"""
function _match_is_one_signature(m::Core.MethodMatch)::Bool
    m.spec_types isa DataType || return false
    local vars = TypeVar[]
    local sig = m.method.sig
    while sig isa UnionAll
        push!(vars, sig.var)
        sig = sig.body
    end
    local left = TypeVar[vars[j] for j in eachindex(m.sparams) if m.sparams[j] isa TypeVar && j <= length(vars)]
    isempty(left) && return true
    local declared = (sig::DataType).parameters
    local args = m.spec_types.parameters
    for i in 2:length(args)
        local C = args[i]
        # one value's dispatch type: a concrete class that is not a kind, or a Type{X}
        (Base.isdispatchelem(C) && !(C isa DataType && C <: Type && C.name !== Type.body.name)) && continue
        local P = Base.unwrapva(declared[min(i, length(declared))])
        any(v -> ccall(:jl_has_typevar, Cint, (Any, Any), P, v) != 0, left) && return false
    end
    return true
end

# the most candidate tuples one dynamic call enumerates or the ambiguity search asks about
# parity(quarantine: Julia selects among a callable's methods by specificity and raises for an ambiguity; a dart closure has one body.)
const _CANDIDATE_BOUND = 4096

"""
    _candidate_product(choices, F, sig, site) -> the tuples of candidates

Every tuple of `choices` (one candidate list per argument position of a dynamic call of callable
type `F` at the argument types `sig`), in order, when there are at most _CANDIDATE_BOUND of them;
past the bound the call rejects, at `site` (the first statement making it: its host's
CodeInstance, CodeInfo, index and NIR record), as the ambiguity search past it does (never a
product enumerated without end, or skipped silently).
formal(dev/formal/Enrollment.tla): past the bound the call rejects (ProductBoundIsLoud)
parity(quarantine: Julia selects among a callable's methods by specificity and raises for an
ambiguity; a dart closure has one body.)
"""
function _candidate_product(choices::Vector{Vector{Any}}, @nospecialize(F), sig::Tuple, site::Tuple)::Iterators.ProductIterator
    local n = prod(length, choices; init=1)
    n > _CANDIDATE_BOUND && throw(_collection_rejection(:unsupported_method,
        "a dynamic call of $(F) with ($(join(sig, ", "))) has $(n) tuples of candidate classes, past " *
        "$(_CANDIDATE_BOUND), the most one call enumerates", site...))
    return Iterators.product(choices...)
end

"""
    _wt_matches_with_ambiguous(sig) -> (Vector{MethodMatch}, Bool)

The consult's matching of `sig` with the ambiguous methods kept and the ambiguity reported, the
query `Base.isambiguous` makes (`_methods_by_ftype` with include_ambiguous), merged across the
overlay table as `CC.findall` merges it: the overlay's matches, and when the last of them does
not fully cover `sig`, the base table's matches no overlay signature contains.
parity(pkg/dart2wasm/lib/translator.dart:108 Translator.hierarchy): the one class hierarchy the
whole compilation consults.
"""
function _wt_matches_with_ambiguous(@nospecialize(sig))::Tuple{Vector{Core.MethodMatch},Bool}
    local world = get_wasm_interpreter().world
    local lookup(mt) = (amb = Ref{Int32}(0);
        ms = Base._methods_by_ftype(sig, mt, -1, world, true, Ref{UInt}(typemin(UInt)), Ref{UInt}(typemax(UInt)), amb);
        (collect(Core.MethodMatch, ms::Vector), amb[] != 0))
    local ovl, ovl_amb = lookup(WASM_METHOD_TABLE)
    (!isempty(ovl) && ovl[end].fully_covers) && return ovl, ovl_amb
    local base, base_amb = lookup(nothing)
    local kept = filter(bm -> !any(om -> bm.method.sig <: om.method.sig, ovl), base)
    return vcat(ovl, kept), ovl_amb | base_amb
end

"""
    wt_methods_ambiguous(m1, m2) -> Bool

Whether two methods are ambiguous: some argument types both admit where neither is more specific
and no other method resolves them. Julia's own algorithm (base/reflection.jl `isambiguous`, the
same on 1.12 and 1.13), asked of the consult's matches, so a method only the overlay table
holds takes part as Julia's inference sees it (Base's isambiguous reads Base's table only).
parity(quarantine: Julia selects among a callable's methods by specificity and raises for an
ambiguity; a dart closure has one body.)
"""
function wt_methods_ambiguous(m1::Method, m2::Method)::Bool
    m1 === m2 && return false
    local ti = typeintersect(m1.sig, m2.sig)
    ti === Union{} && return false
    function inner(ti)
        ti === Union{} && return false
        Base.has_bottom_parameter(ti) && return false
        local ms, has_ambig = _wt_matches_with_ambiguous(ti)
        has_ambig || return false
        filter!(m -> !Base.has_bottom_parameter(m.spec_types), ms)
        # the ambiguity reported over the intersection involves both methods, or another pair
        (any(m -> m.method === m1, ms) && any(m -> m.method === m2, ms)) || return false
        # whether the intersection is fully covered once the Union{}-parameter ambiguities are set aside
        local minmax = nothing
        for match in ms
            match.fully_covers || continue
            (minmax === nothing || Base.morespecific(match.method, minmax)) && (minmax = match.method)
        end
        (minmax === nothing || minmax == m1 || minmax == m2) && return true
        for match in ms
            match.method === minmax && continue
            if !Base.morespecific(minmax, match.method)
                (match.fully_covers || !Base.morespecific(match.method, minmax)) && return true
            end
        end
        return false
    end
    if !(ti <: m1.sig && ti <: m2.sig)
        # a non-commutative intersection: the reverse may decide it, else Julia answers "not ambiguous"
        local ti2 = typeintersect(m2.sig, m1.sig)
        (ti2 <: m1.sig && ti2 <: m2.sig) || return false
        ti = ti2
    end
    return inner(ti)
end

"""
    _apply_iterate_vararg_target_mi(node, arg_type) -> MethodInstance | nothing

THE call edge of `Core._apply_iterate(iterate, f, t)` when `t` is a runtime-length
Vararg tuple — the one splat shape calls.jl lowers to a DIRECT call
(`_emit_apply_iterate_vararg_call!`).

parity(quarantine: Julia varargs — dart has no runtime-length parameter list, so every
dart call site names a static arity and dart2wasm has no counterpart to this edge).

It is a static edge: `f` is named right there in the call, and `t`'s
`{Object, data, size}` representation IS the callee's one packed parameter. But it
wears a builtin's clothes, so Julia's own collector does not see it. It is the `:splat`
kind of the one edge relation, `_closed_world_edge`, which the collector enrolls by and the
external-leaf prune keeps by. The container is typed by `arg_type`, the call-site type codegen's
call reads (its joins included), as the other two edges a builtin hides are.

`nothing` unless every condition holds: the callee resolves to an ordinary function
(never a builtin/intrinsic — those have no compiled body), the container carries the one
representable layout (`is_runtime_vararg_tuple_type`, structs.jl), and EXACTLY ONE
method answers the open-ended signature. An arity-overloaded callee has no single static
target and stays a loud reject at the call site.
"""
function _apply_iterate_vararg_target_mi(node::NirCall, arg_type)::Union{Core.MethodInstance,Nothing}
    (node.callee === Core._apply_iterate && length(node.operands) == 3) || return nothing
    local fref = node.operands[2]
    local f = nir_operand_callee(fref, arg_type(fref))
    (f isa Function && !(f isa Core.Builtin) && !(f isa Core.IntrinsicFunction)) || return nothing
    local T = arg_type(node.operands[3])
    (T isa DataType && is_runtime_vararg_tuple_type(T)) || return nothing
    local sig = Tuple{Core.Typeof(f), Vararg{vararg_tuple_eltype(T)}}
    local matches = wt_method_matches(sig)
    (matches !== nothing && length(matches) == 1) || return nothing
    return CC.specialize_method(matches[1])
end

"""
    _invoke_in_world_target_mi(node, arg_type) -> MethodInstance | nothing

THE call edge of `Core.invoke_in_world(world, f, args...)`, which calls `f(args...)`: a
closed world has one world, so the edge is that call's dispatch in the overlay table — the
one method applicable to the operands' call-site types (`arg_type`), when it covers them (every
value of those types runs it). A callee that is not a constant has no static edge (the call site
rejects as a dynamic call); a call no one method covers is the dynamic call of `f` it makes
(`_called_function`).
parity(quarantine: Julia's world-age builtin `Core.invoke_in_world`; dart has no world age,
and a closed-world module has exactly one.)
"""
function _invoke_in_world_target_mi(node::NirCall, arg_type)::Union{Core.MethodInstance,Nothing}
    (length(node.operands) >= 2 && _nir_callee_object(node.callee) === Core.invoke_in_world) ||
        return nothing
    local f = nir_operand_callee(node.operands[2], arg_type(node.operands[2]))
    (f isa Function || f isa Type) || return nothing
    local arg_types = Any[arg_type(a) for a in @view node.operands[3:end]]
    local matches = wt_method_matches(Tuple{Core.Typeof(f), arg_types...})
    (matches !== nothing && length(matches) == 1 && matches[1].fully_covers) || return nothing
    return CC.specialize_method(matches[1])
end

"""
    _called_function(node, arg_type) -> (callee, operands)

The function a call statement calls and the operands it passes: its callee and its operands; for
`Core.invoke_in_world(world, f, args...)` with a constant `f` that is no edge (no one method
covers its signature, `_invoke_in_world_target_mi`), `f` and `args`, the dynamic call Julia's
run-time invoke_in_world makes, which the candidate scan enrolls as it does any dynamic call;
`(nothing, NirNode[])` for one that is an edge (its target is collected as the call's) or whose
function is not a constant (a dynamic callee, rejected at its statement).
formal(dev/formal/ClosedWorld.tla): a call no one method covers is a dynamic site (WorldSites),
never neither an edge nor a site
parity(quarantine: Julia's world-age builtin `Core.invoke_in_world`; dart has no world age,
and a closed-world module has exactly one.)
"""
function _called_function(node::NirCall, arg_type)::Tuple{Any,Vector{NirNode}}
    local callee = _nir_callee_object(node.callee)
    callee === Core.invoke_in_world || return (callee, node.operands)
    length(node.operands) >= 2 || return (nothing, NirNode[])
    local f = nir_operand_callee(node.operands[2], arg_type(node.operands[2]))
    (!(f isa Function || f isa Type) || _invoke_in_world_target_mi(node, arg_type) !== nothing) && return (nothing, NirNode[])
    return (f, node.operands[3:end])
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
external-leaf prune keeps by it (`_prune_external_leaf_subgraphs`) and the collector's walk
records each target's reason by it (`_missing_explicit_invoke_mis`, which the plan reads), so a
body one of them reaches, the others reach too.
Every edge `CC.collectinvokes!` follows (Compiler typeinfer.jl:1336 on 1.12, :1477 on 1.13):
- `:invoke`, the MethodInstance it names (Julia's abstract one included: the collector
  re-specializes it at the call-site types);
- `:invoke_modify`, the operator it names;
- `:finalizer`, a `Core.finalizer(f, o, …)` call's `f(o)`, at Julia's arity, two to four
  operands (`3 <= length(stmt.args) <= 5`, typeinfer.jl:1353 on 1.12, :1502 on 1.13);
- `:cfunction`, the function a `:cfunction` makes a pointer to, at its declared argument types;
- `:new_function` (1.13, `_FOLLOWS_NEW_FUNCTION_EDGE`), the body of a `:new` of a Function type;
the last three at Julia's own answer, `CC.compileable_specialization_for_call`, as its queue
enqueues them: a finalizer's and a `:cfunction`'s operands typed by Julia's `argextype`
(typeinfer.jl:1353, :1361 on 1.12.7; :1502, :1510 on 1.13.1), `value_type` over the body's slot
types and the boundary's SSA types, no join; a `:new`'s at `Tuple{T, Vararg}`, typing no operand
(:1523 on 1.13.1). And the
two static calls a builtin hides that WT lowers as direct calls: `:splat`, a runtime-Vararg
`Core._apply_iterate` (`_apply_iterate_vararg_target_mi`), and `:invoke_in_world`
(`_invoke_in_world_target_mi`). Those two and the `:invoke` re-specialization type their
operands by `arg_type`, the call-site type codegen's call reads (`_edge_arg_type`: value_type
over the body's numeric joins), so the MethodInstance collected is the one codegen calls. A
statement names at most one edge.

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
    local argextype(a) = value_type(a, slot_types, nothing)   # Julia's queue's operand type
    if node isa NirInvoke
        mi = node.mi
    elseif node isa NirCall
        if (mi = _apply_iterate_vararg_target_mi(node, arg_type)) !== nothing
            kind = :splat
        elseif (mi = _invoke_in_world_target_mi(node, arg_type)) !== nothing
            kind = :invoke_in_world
        elseif _nir_callee_object(node.callee) === Core.finalizer && 2 <= length(node.operands) <= 4
            kind = :finalizer
            mi = CC.compileable_specialization_for_call(interp,
                Tuple{argextype(node.operands[1]), argextype(node.operands[2])})
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
            mi = CC.compileable_specialization_for_call(interp, Tuple{argextype(ops[2]),
                (CC.sp_type_rewrap(t, src.parent, false) for t in ops[4].value)...})
        end
    end
    return mi isa Core.MethodInstance ? (kind, mi) : nothing
end

"""
The capture typing of the collection's latest round (`_dynamic_dispatch_candidate_mis` computes
it over the whole world collected so far, and the last round's is the closed world's): the type
of every captured variable (record_capture_contents) and each collected body's capture-read
joins (capture_read_types). The plan keeps both; codegen reads them from it.
parity(closures.dart:1436 Capture.type): a captured variable's type comes from its declaration,
the one type every read and write of it shares.
"""
mutable struct _CaptureTyping
    record::Dict{Tuple{Type,Symbol},Type}
    joins::IdDict{Core.MethodInstance,Dict{Int,Type}}
end
# parity(closures.dart:1436 Capture.type): no captured variable typed yet.
_CaptureTyping()::_CaptureTyping =
    _CaptureTyping(Dict{Tuple{Type,Symbol},Type}(), IdDict{Core.MethodInstance,Dict{Int,Type}}())

"""
    _numeric_joins!(joins, src, nir, slot_types) -> Dict{Int,Type}

The numeric joins of one collected body (propagate_numeric_value_types over the boundary's
types, the slot types typing its arguments), computed once per body and kept in `joins`, the
collection's one memo (ClosedWorld's `numeric_joins`): they type the edges' operands here, and
with the capture reads they are the plan's joins (`plan.joins`), which codegen reads. Their
return-type questions go to the one inference entry (infer_return_type): collection asks
Julia's inference, codegen does not (L152).
parity(quarantine: Julia leaves a scalar-replaced `Core.Box` capture's numeric accumulator typed
`Any`; dart types a captured variable by its declared type, closures.dart:1579
translateTypeOfLocalVariable.)
"""
_numeric_joins!(joins::IdDict{Core.CodeInfo,Dict{Int,Type}}, src::Core.CodeInfo,
                nir::Vector{NirStmt}, slot_types::Vector{Type})::Dict{Int,Type} =
    get!(() -> propagate_numeric_value_types(nir, nir; slot_types,
                                             rettype=infer_return_type), joins, src)

# the operand typer `_closed_world_edge` reads in one body: an operand's call-site type, value_type
# over the body's joins (`_body_joins`: numeric and captured-box), the ones codegen's call reads
# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
function _edge_arg_type(src::Core.CodeInfo, mi::Core.MethodInstance, nir::Vector{NirStmt},
                        slot_types::Vector{Type}, joins::IdDict{Core.CodeInfo,Dict{Int,Type}},
                        capture::_CaptureTyping)::Function
    local body = _body_joins(joins, capture, mi, src, nir, slot_types)
    return a -> value_type(a, slot_types, body)
end

"""
    _collected_pairs(codeinfos) -> Vector{Tuple{CodeInstance,MethodInstance,CodeInfo}}

The collected world's bodies, in collection order: `codeinfos` alternates a CodeInstance and
its CodeInfo (Compiler's `compile!` output), and each pair is read here, with its
MethodInstance (`ci.def`, or an ABI override's `def`), by every walk of the collection.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function _collected_pairs(codeinfos::Vector{Any})::Vector{Tuple{Core.CodeInstance,Core.MethodInstance,Core.CodeInfo}}
    local out = Tuple{Core.CodeInstance,Core.MethodInstance,Core.CodeInfo}[]
    for k in 1:2:length(codeinfos) - 1
        local ci, src = codeinfos[k], codeinfos[k + 1]
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        push!(out, (ci, ci.def isa Core.MethodInstance ? ci.def : ci.def.def, src))
    end
    return out
end

"""Return the targets of the collected bodies' edges (`_closed_world_edge`) missing from a
collected world, each recorded in `seen`. Every edge's target has its reason recorded in
`reasons` (the first statement naming it), collected already or not, and the closure or functor
type of each `:invoke`'s target in `invoked_closures`: the walk is the collection's one walk of the edges, and
the plan reads what it records. An explicit `:invoke` whose concrete call-site types select
another MethodInstance is retargeted in place to it, recomputed every round from Julia's own
MethodInstance (the one its IR held before any round retargeted it, kept in `invoke_originals`):
the operand types are read from the world collected so far, and a captor a later round collects
can widen them, so a round's retarget is never kept on its own (a site the final world's typing
does not retarget is restored).
formal(dev/formal/ClosedWorld.tla): every collected body has the reason the collector recorded
(ReasonsComplete), and no :invoke at the fixpoint calls a replacement the final world's typing
does not select (RetargetsSound)
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)"""
function _missing_explicit_invoke_mis(codeinfos::Vector{Any}, seen::Set{Any};
                                      numeric_joins::IdDict{Core.CodeInfo,Dict{Int,Type}},
                                      capture::_CaptureTyping,
                                      reasons::IdDict{Core.MethodInstance,String},
                                      invoked_closures::Set{DataType},
                                      invoke_originals::IdDict{Core.CodeInfo,Dict{Int,Core.MethodInstance}})::Vector{Any}
    out = Any[]
    interp = WasmInterpreter(Base.RefValue(0))
    for (host_ci, host_mi, src) in _collected_pairs(codeinfos)
        nir = build_nir(src)
        src_slot_types = nir_slot_types(src)
        arg_type = _edge_arg_type(src, host_mi, nir, src_slot_types, numeric_joins, capture)
        for (k, s) in enumerate(nir)
            local node = s.node
            local edge = _closed_world_edge(node, src, src_slot_types, arg_type, interp)
            edge === nothing && continue
            local kind = edge[1]
            mi = edge[2]
            if kind === :invoke
                # the IR's target now, and Julia's own, from which this round recomputes it
                local current_mi = mi
                local originals = get(invoke_originals, src, nothing)
                original_mi = originals === nothing ? mi : get(originals, k, mi)
                mi = original_mi
                # Explicit invoke records the selected Method, but Julia may leave
                # its MethodInstance abstract. WT's subset monomorphizes: rebuild
                # the MI from the concrete call-site SSA types, exactly as the
                # compiler would for an ordinary specialized call.
                if mi isa Core.MethodInstance && node.callee !== nothing
                    f = node.callee
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
                        matches = wt_method_matches(ftype)
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
                                    canonical_matches = wt_method_matches(canonical_ftype)
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
                if mi isa Core.MethodInstance && mi !== current_mi
                    # Keep the optimized IR valid Julia while making its edge agree
                    # with the Wasm overlay dispatch selected for the concrete call, or
                    # restore Julia's target where this round's operand types no longer
                    # select another. Nothing is dropped: a body an earlier target named
                    # stays collected, live if another site still invokes it, dead code
                    # otherwise (ClosedWorld.tla NoGarbage, MARCH 13.17 H9).
                    get!(() -> Dict{Int,Core.MethodInstance}(), invoke_originals, src)[k] = original_mi
                    nir_retarget_invoke!(src, nir, k, mi)
                end
            end
            mi isa Core.MethodInstance || continue
            haskey(reasons, mi) || (reasons[mi] = _enrollment_text(_EDGE_ENROLLMENT[kind], host_ci, src, k, node))
            if kind === :invoke
                local st = mi.specTypes
                (st isa DataType && length(st.parameters) >= 1 &&
                 is_stateful_receiver_type(st.parameters[1])) && push!(invoked_closures, st.parameters[1])
            end
            mi in seen && continue
            push!(seen, mi)
            push!(out, mi)
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
parity(pkg/dart2wasm/lib/compile.dart:113 CFECrashError): the crash it reports, with the error and
the stack it was raised on.
parity(quarantine: Julia's compile! infers a batch of roots and its failure names none of them, so
WT infers the batch's roots again one at a time, on the failure path only, to name the one that
fails; dart's CFE reports the member it crashed on.)
"""
function throw_located_collection_failure(batch::Vector{Tuple{Any,String}}, err, bt,
                                          compile_one::Function)::Union{}
    _named(mi, why) = "inferring $(replace(sprint(show, mi), "MethodInstance for " => "")), enrolled as $why"
    for (mi, why) in batch
        try
            compile_one(mi)
        catch e
            # an interrupt or exhausted memory is the process's, not a root's
            (e isa InterruptException || e isa OutOfMemoryError) && rethrow()
            throw(WasmInternalError("closed-world collection", 0, "", String[_named(mi, why)], e,
                                    _raised_frames(catch_backtrace(), :throw_located_collection_failure)))
        end
    end
    throw(WasmInternalError("closed-world collection", 0, "",
                            String[_named(mi, why) for (mi, why) in batch],
                            err, _raised_frames(bt, :collect_closed_world)))
end

# infer one root in a fresh partition, as collect_new_pairs! would (the failure path only)
# parity(quarantine: the re-inference throw_located_collection_failure names a failing root by; Julia's compile! names none of a batch's roots.)
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
    _collection_rejection(kind, why, ci, src, idx, rec) -> WasmCompileError

A program the collection rejects at statement `idx` (its NIR record `rec`) of the host whose
CodeInstance is `ci`, saying `why`, located as a codegen rejection is: its statement, source line
and inline chain innermost first (as values.jl rejects a cyclic struct constant at its
statement). Two bounds reject through it: a constant whose own objects (those no constant walked
before it reached) pass the walk's bound for the type objects constants hold (10^6 per constant,
WT's own bound, not Julia's), at the statement holding it; and a dynamic call whose candidate
tuples pass _CANDIDATE_BOUND (_candidate_product), at the first statement making it.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world, and the type objects a constant holds are values a program reads; dart's constants are its own front end's, typed by their classes.)
"""
function _collection_rejection(kind::Symbol, why::String, ci, src::Core.CodeInfo, idx::Int, rec::NirStmt)::WasmCompileError
    local frames = stmt_frames(src.debuginfo, idx)
    return WasmCompileError(WasmDiagnostic(kind, _collection_host_text(ci), why,
        isempty(frames) ? nothing : String(last(split(first(frames), " @ "))), nothing, idx,
        first(nir_text(rec), 160), frames))
end

"""
    _capture_typing!(capture, codeinfos)

Type the captured variables of the world collected so far: the record (record_capture_contents)
over every collected body, every body of a callable type read as one of its type's bodies
(closure_bodies), and each body's captured-box reads (capture_read_types). It runs at the start
of each collection round, before the round's edges are typed, so the round's typers read it; the
last round's, over the final world, is the closed world's.
parity(closures.dart:1436 Capture.type): a captured variable's type comes from its declaration,
the one type every read and write of it shares.
"""
function _capture_typing!(capture::_CaptureTyping, codeinfos::Vector{Any})::Nothing
    local pairs = _collected_pairs(codeinfos)
    local bodies_by_type = IdDict{Any,Vector{Tuple{Core.MethodInstance,Core.CodeInfo}}}()
    for (_, cmi, csrc) in pairs
        local cst = cmi.specTypes
        (cst isa DataType && cst <: Tuple && length(cst.parameters) >= 1) || continue
        push!(get!(() -> Tuple{Core.MethodInstance,Core.CodeInfo}[], bodies_by_type, cst.parameters[1]),
              (cmi, csrc))
    end
    local closure_bodies = T -> get(bodies_by_type, T, Tuple{Core.MethodInstance,Core.CodeInfo}[])
    local nirs = IdDict{Core.CodeInfo,Vector{NirStmt}}(src => build_nir(src) for (_, _, src) in pairs)
    capture.record = record_capture_contents(Any[
        (nirs[csrc], nir_slot_types(csrc),
         isempty(nir_slot_types(csrc)) ? nothing : nir_slot_types(csrc)[1])
        for (_, _, csrc) in pairs]; closure_bodies, rettype=infer_return_type)
    empty!(capture.joins)
    for (_, mi, src) in pairs
        local st = nir_slot_types(src)
        capture.joins[mi] = capture_read_types(nirs[src], nirs[src], capture.record,
                                               isempty(st) ? nothing : st[1];
                                               spectypes=st, closure_bodies, rettype=infer_return_type)
    end
    return nothing
end

"""
    _body_joins(numeric_joins, capture, mi, src, nir, slot_types) -> Dict{Int,Type}

One collected body's joins, the ones codegen applies (plan_joins): its numeric joins
(_numeric_joins!) with its captured-box reads (the capture typing's), so every collection typer
(an edge's operands, a dynamic call's) reads the operand types codegen's call reads. A body the
capture typing has not reached yet (collected this round) has its numeric joins only, until the
next round types it.
parity(pkg/dart2wasm/lib/translator.dart:119 Translator.inferredTypeMetadata): the type flow
analysis's per-node types, one answer for every reader.
"""
_body_joins(numeric_joins::IdDict{Core.CodeInfo,Dict{Int,Type}}, capture::_CaptureTyping,
            mi::Core.MethodInstance, src::Core.CodeInfo, nir::Vector{NirStmt},
            slot_types::Vector{Type})::Dict{Int,Type} =
    merge(copy(_numeric_joins!(numeric_joins, src, nir, slot_types)),
          get(capture.joins, mi, Dict{Int,Type}()))

"""
The classes WT's lowering instantiates with no `%new` in Julia's IR: the exceptions a lowered
intrinsic (a DivideError, an InexactError), a MethodError arm, a bounds or type check and a
rethrow at depth 0 throw (calls.jl, int128.jl, generate.jl), and the String a lowered
ErrorException carries. A program holds one only through a `catch` (`the_exception`, typed `Any`,
so no statement's type names it) or the exception stack (jl_current_exception, jl_get_excstack).
The one list: compile.jl registers its exception structs before the numbering, and the one class
set holds every class of it as a root in a program that can hold one (closed_world_classes),
whatever the program's IR names, as dart's flow analysis takes a class the backend instantiates,
marked with an entry-point pragma, as allocated. dart allocates such a class unconditionally; the
gate on a program that can hold one is WT's own, and loses nothing: the lowering's classes are
numbered by their registration whether or not the set holds them, so an exception that escapes
uncaught is still named. (What the lowering materializes for a type
object, its TypeName, Module, SimpleVector, is a value the program reads with a builtin, whose
result's class the set observes where it is read.)
parity(pkg/vm/lib/transformations/type_flow/native_code.dart:116 PragmaEntryPointsVisitor.visitClass)
"""
const LOWERING_INSTANTIATED_CLASSES = (ErrorException, ArgumentError, OverflowError, DivideError,
                                       StackOverflowError, OutOfMemoryError, BoundsError, TypeError,
                                       DomainError, InexactError, KeyError, MethodError,
                                       AssertionError, UndefVarError, FieldError, String)

"""
The classes a value of the closed world may have, one set (closed_world_classes): every concrete
class a value of the collected program may have but one (below), by one statement rule and its
roots: the class
of every statement of a collected body whose inferred type is concrete (whatever makes the value:
a `%new`, a builtin, an intrinsic, a foreign call, an `:invoke`, a declared import's result), with
the classes its type parameters name; a tuple `Core.tuple` builds, by its elements' runtime types;
every value a statement, phi or return carries by _collected_operand_value's rule (a literal, its
value unresolved, a quoted GlobalRef the GlobalRef object; a bound global's value, constant or
not) and everything that value holds; a vararg method's packed tuple, a value no statement makes
(WT rebuilds it from the flattened parameters), from the body's slot; an entry's argument classes
and its own callable; and, in a program that can hold an
exception, every class WT's lowering instantiates (LOWERING_INSTANTIATED_CLASSES), `runtime`; and the `Type{X}` of each type object a value
may be (a constant operand's, and each class a `typeof` may return, with its kind), `held`. The
enrollment, the no-method records, the union-split MethodError tuples and the vtable pre-pass's
ambiguity search read it, and the numbering numbers every class of it. What a carried value holds
is walked once, here (`hold!`): the class of every value it reaches is observed whatever it is (an
IR node, a binding or a module included), since a class no value has costs bytes and a class
dropped where a value has it a wrong answer; past 10^6 own objects the walk rejects at the
statement carrying it, and no other walk reads what a value holds (the numbering reads it from
this set). The one exception: a value a builtin typed `Any` reads out of a type object's
parameters (`Core._svec_ref(T.parameters, i)`: the 0x01 of `Val{0x01}`, the 3 of `NTuple{3,Int}`, a
Char or a Symbol), which observe_type! (it skips a parameter that is no type) and hold! (it does not
walk a type object) never see; the numbering before held none of them either (MARCH 13.17 H13).
parity(pkg/dart2wasm/lib/class_info.dart:666 ClassInfoCollector.collect): one class list, numbered
once, whose concrete (allocated) classes every selector's targets range over
(dispatch_table.dart:501 DispatchTable.build).
"""
struct ClosedWorldClasses
    runtime::Set{DataType}   # every concrete class a value may have
    held::Set{DataType}      # the Type{X} of each type object a value may be
end

"""
    closed_world_class_list(classes) -> Vector{DataType}

The classes of the one set a dispatch row can test (a concrete struct or primitive class), in
type_order_key's order: the candidates of an argument position, the classes a MethodError's args
tuple ranges over, and the classes the numbering must number.
parity(pkg/dart2wasm/lib/class_info.dart:666 ClassInfoCollector.collect): the one class list.
"""
closed_world_class_list(classes::ClosedWorldClasses)::Vector{DataType} =
    sort!(DataType[C for C in classes.runtime if isconcretetype(C) && (isstructtype(C) || isprimitivetype(C))];
          by=type_order_key)

"""
    class_candidates(classes) -> Vector{Any}

Every candidate a dispatch position may take from the one set: its classes
(closed_world_class_list), then the `Type{X}` of each type object a value may be, each in
type_order_key's order (formal(dev/formal/Enrollment.tla): a type object is no numbered class,
StaticOnly).
parity(pkg/dart2wasm/lib/class_info.dart:666 ClassInfoCollector.collect): the one class list.
"""
class_candidates(classes::ClosedWorldClasses)::Vector{Any} =
    Any[closed_world_class_list(classes); sort!(collect(classes.held); by=type_order_key)]

"""
    closed_world_classes(codeinfos, entry_mis, nir_for) -> ClosedWorldClasses

The one class set (ClosedWorldClasses) over the collected world: each body's NIR (`nir_for`, the
round's one boundary per CodeInfo), walked once. Computed every round of the collection's
fixpoint over the world collected so far; the last round's is the closed world's.
formal(dev/formal/Enrollment.tla): one class set; an ambiguity is asked only over its classes
(AskNumbered) and a candidate is one of them (InSet)
parity(pkg/dart2wasm/lib/class_info.dart:666 ClassInfoCollector.collect)
"""
function closed_world_classes(codeinfos::Vector{Any}, entry_mis::Vector{Any},
                              nir_for::Function)::ClosedWorldClasses
    # dart builds dispatch rows only for the classes of its closed component: here every class a
    # statement of a collected body is concretely typed by, every value a statement carries and
    # what it holds, the entries' arguments and the classes the lowering instantiates. A class
    # no value has costs bytes; a class dropped where a value has it is a wrong answer.
    runtime_types = Set{DataType}()
    # the type objects a value may be: a literal or a constant global a statement, a phi or a
    # return holds (which over-approximates: a typeassert's, an isa's or an intrinsic's type
    # operand is one too, adding rows and ambiguity questions, never dropping one), and the
    # type object of each class a `typeof` may return; each a candidate by its dispatch type
    # `Type{X}` (formal(dev/formal/Enrollment.tla): a type object is no numbered class,
    # StaticOnly; one a `typeof` makes, LiteralsOnly), a constant tuple's or immutable struct's
    # fields included
    held_type_objects = Set{DataType}()
    typeof_operand_types = Set{Any}()   # the static type of each `typeof` operand
    observed_type_nodes = Set{Any}()
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
        # A value a statement carries (an operand, or the statement itself) is one the collected
        # program stores or passes, by the one rule of what a statement carries,
        # _collected_operand_value: a literal (optimized IR constant-folds `%new(T, fields...)`
        # into the object itself; a quoted GlobalRef is the GlobalRef object) or a bound
        # global's value, constant or not (values.jl bakes a non-constant one's current value as
        # its mutable global's initializer), whatever it is (`nothing` included); its class is
        # observed and everything it holds walked (hold!). An SSA, argument or slot operand
        # carries no value here; the class of its value is observed where that value is built.
        local has, v = _collected_operand_value(node)
        (has && !(v isa Expr)) || return
        hold!(v)
        observe_type!(Core.Typeof(v))
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
    # every value a constant reaches, whose class is observed and whose type objects are held:
    # an array's or a Memory's elements, a struct's or tuple's fields, a mutable one's included,
    # each heap object once (a worklist, so neither a shared
    # child nor a long chain multiplies the walk or deepens the stack; a fresh box getfield makes is
    # kept alive, so its address is not reused for another). A module and exactly these
    # runtime structures of Core (a TypeName, a method table and its entries, a Method, a
    # MethodInstance, a CodeInstance, a CodeInfo, a binding, a SimpleVector) are not walked
    # into, a bound on the walk, not a claim that they are no values: their own class is observed
    # (a NamedTuple, a Box are walked): walking them reached the
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
            # every other value the constant reaches is a value of its class, an isbits one, a
            # module and a runtime structure included (a constant `Any[QB2(1)]` holds a QB2)
            observe_type!(typeof(v))
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
                throw(_collection_rejection(:unsupported_type,
                    "a constant whose own objects passed 10^6, the bound of the walk for the type objects a constant holds",
                    held_site[]::Tuple...))
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
    # The operands one statement carries: every node's `args` hold exactly the runtime operands
    # (a foreigncall's ABI preamble and an invoke's MethodInstance are resolved fields). A callee
    # is never evidence of an instantiated class, a NirCall's and a NirInvoke's alike: it is the
    # call's static target (a function, a constructor, a builtin, an intrinsic), not a value the
    # call passes on, as a dart static target is not (a function used as a value is an operand);
    # the class a constructor builds is observed at its %new, in the constructor's body.
    function statement_operands(node::NirNode)::Vector{NirNode}
        (node isa NirCall || node isa NirInvoke || node isa NirNew || node isa NirForeignCall) &&
            return node.operands
        return NirNode[]
    end
    # the classes WT's lowering instantiates are roots, reason "instantiated by lowering", in a
    # program that can hold one: a caught MethodError or DivideError is a value as surely as one the
    # program builds, and a program holds one only through a catch (`the_exception`) or the
    # exception stack (jl_current_exception, jl_get_excstack)
    local holds_exceptions = any(((_, _, src),) -> any(s -> s.node isa NirTheException ||
            (s.node isa NirForeignCall && s.node.c_symbol in (:jl_current_exception, :jl_get_excstack)),
        nir_for(src)), _collected_pairs(codeinfos))
    holds_exceptions && foreach(observe_type!, LOWERING_INSTANTIATED_CLASSES)
    # Explicit root arguments cross into the component and therefore exist at
    # runtime even if their construction happened in the host.
    for entry in entry_mis
        sig = entry.specTypes
        # its callable too: the `#self#` argument is a value of the entry's own class
        sig isa DataType && foreach(observe_type!, sig.parameters)
    end
    for (ci_j, mi_j, src_j) in _collected_pairs(codeinfos)
        # a vararg method's packed tuple is a value no statement makes (WT rebuilds it from the
        # flattened parameters): its class is observed from the body's slot
        if mi_j.def isa Method && mi_j.def.isva
            local st_j = nir_slot_types(src_j)
            length(st_j) >= mi_j.def.nargs && observe_type!(st_j[mi_j.def.nargs])
        end
        for (sidx, s0) in enumerate(nir_for(src_j))
            local node0 = s0.node
            held_site[] = (ci_j, src_j, sidx, s0)
            # THE statement rule: a statement whose inferred type is concrete has a value of that
            # class, whatever makes it (a %new, a builtin's allocation or read, an intrinsic, a
            # foreign call, an :invoke, a declared import's result the host makes); its type
            # parameters are walked too (observe_type!), the classes an instantiated generic names
            local made = CC.widenconst(s0.julia_type)
            (made isa DataType && isconcretetype(made)) && observe_type!(made)
            # a tuple Core.tuple builds is of its elements' runtime types (tuple_runtime_type, the
            # answer that numbers it and that _lower_tuple! builds), which a constant element
            # states more exactly than the statement's inferred type
            if node0 isa NirCall && _nir_callee_object(node0.callee) === Core.tuple
                local tt = tuple_runtime_type(node0.operands, nir_slot_types(src_j))
                tt === nothing || observe_type!(tt)
            end
            foreach(observe_runtime_operand!, statement_operands(node0))
            # a statement that is a value (`%1 = Main.g`, the form of a non-constant global's read)
            (node0 isa NirLiteral || node0 isa NirGlobalRef) && observe_runtime_operand!(node0)
            # a constant a phi, a pi, an upsilon or a return carries is a value as surely as an
            # operand's: its class is observed, its type objects held
            local carried = node0 isa NirPhi || node0 isa NirPhiC ? node0.values :
                            node0 isa NirReturn || node0 isa NirPi || node0 isa NirUpsilon ? Any[node0.value] : Any[]
            for c in carried
                c isa NirNode && observe_runtime_operand!(c)
            end
            if node0 isa NirCall && _nir_callee_object(node0.callee) === Core.typeof &&
               length(node0.operands) == 1
                push!(typeof_operand_types,
                      value_type(node0.operands[1], nir_slot_types(src_j), nothing))
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
    return ClosedWorldClasses(runtime_types, held_type_objects)
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
function _dynamic_dispatch_candidate_mis(codeinfos::Vector{Any}, seen::Set{Any};
                                         reasons::IdDict{Core.MethodInstance,String},
                                         classes::ClosedWorldClasses,
                                         nir_for::Function,
                                         no_method::IdDict{DataType,Set{DataType}},
                                         numeric_joins::IdDict{Core.CodeInfo,Dict{Int,Type}},
                                         capture::_CaptureTyping)::Vector{Any}
    out = Any[]
    # the one class set (closed_world_classes): dart builds dispatch rows only for the classes of
    # its closed component, and an inferred SSA type is no evidence that its class is instantiated
    local runtime_types = classes.runtime
    # OBSERVED dynamic-call signatures (SSA callee, inferred arg types) —
    # closure bodies specialize against these (dart's typed vtable entries; Julia's
    # inference makes the body REAL instead of an any-erased stub).
    callable_invocations = Set{Tuple{DataType,Tuple}}()
    invocation_site = Dict{Tuple{DataType,Tuple},Tuple}()   # each pair's first statement (a rejection's site)
    _fn_callables = Set{DataType}()   # per-function staging (folded on co-occurrence)
    _fn_dyn_sigs = Set{Tuple}()
    _fn_dyn_site = Dict{Tuple,Tuple}()   # each signature's first statement in the function
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
            haskey(invocation_site, (T, sig)) || (invocation_site[(T, sig)] = _fn_dyn_site[sig])
        end
        empty!(_fn_callables)
        empty!(_fn_dyn_sigs)
        empty!(_fn_dyn_site)
        return
    end
    local pairs = _collected_pairs(codeinfos)
    for (ci, host_mi, src) in pairs
        # Co-occurrence fold: a function's constructed closures enroll ONLY
        # if that function ALSO makes dynamic (SSA-callee) calls — enrolling every
        # userland closure perturbed modules with purely-static closures (the
        # randsubseq suite regression).
        flush_callable_invocations!()
        hsig = host_mi.specTypes
        hparams = (hsig isa DataType && hsig <: Tuple) ? collect(hsig.parameters) : Any[]
        local nir = nir_for(src)
        # A dynamic call's operands are typed as codegen's call reads them: by the body's joins,
        # its numeric joins and its captured-box reads (_body_joins), so a call erased by
        # Core.Box inference enrolls its exact MethodInstance before function indices are frozen.
        local _call_type = let st = nir_slot_types(src), j = _body_joins(numeric_joins, capture, host_mi, src, nir, st)
            a -> value_type(a, st, j)
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
                              (a isa NirGlobalRef && a.constant) ? a.value : nothing
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
                    haskey(_fn_dyn_site, Tuple(_dargs)) || (_fn_dyn_site[Tuple(_dargs)] = (ci, src, sidx, s))
                end
            end
            # (a singleton-typed function argument arrives already resolved to its
            # instance — the NIR boundary's one callee resolution); the call an `invoke_in_world`
            # with no static edge makes is a dynamic call of its function (_called_function)
            local g, cargs = _called_function(node, _call_type)
            (g isa Function && !(g isa Core.Builtin) && !(g isa Core.IntrinsicFunction)) || continue
            isempty(cargs) && continue
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
                local ssig = Tuple{Core.Typeof(g), atypes...}
                local selected = wt_method_which(ssig)
                selected === nothing && continue
                local m = selected.method
                (ssig <: m.sig && _match_is_one_signature(selected)) || continue
                # specialized at Julia's match, with its static parameters' values (A8C3)
                local cmi = CC.specialize_method(selected)
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
            # the callee's no-method record exists from here, empty when it has a method for every
            # class that reaches the call: its MethodError reads the record, never a default
            get!(() -> Set{DataType}(), no_method, Core.Typeof(g))
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
                ssig = Tuple{Core.Typeof(g), spec...}
                local selected = wt_method_which(ssig)
                if selected === nothing
                    # the call throws Julia's MethodError for this class: its args tuple, recorded
                    # for this callee (formal(dev/formal/ClassIdSwitch.tla): ThrowWhereJuliaThrows)
                    all(t -> isconcretetype(t) && !(t <: Type), spec) &&
                        _record_no_method!(no_method, Core.Typeof(g), Tuple{spec...})
                    continue
                end
                m = selected.method
                # a match at a kind facing a Type{S} is no signature: the type object's own Type{X}
                # candidate gives the row (_match_is_one_signature)
                (ssig <: m.sig && _match_is_one_signature(selected)) || continue
                # specialized at Julia's match, with its static parameters' values
                cmi = CC.specialize_method(selected)
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
    # (wt_method_matches) gives every method whose parameter types intersect it, each
    # specialized at the intersection (a method narrower than an erased argument included;
    # the entry tries them in Julia's specificity order, closures.jl). A method with static
    # parameters a match leaves unfixed is enrolled at each tuple of candidates (below)
    local observed_classes = class_candidates(classes)
    for (_T, ds) in callable_invocations
        get!(() -> Set{DataType}(), no_method, _T)   # the callable's record, empty or not
        # each tuple of candidates for which the callable has no method: the call throws Julia's
        # MethodError there, its args a tuple of the values' classes (a type object's class is
        # its kind), numbered for the entry to build (formal(dev/formal/ClassIdSwitch.tla):
        # ThrowWhereJuliaThrows)
        local _ech = Vector{Any}[dispatch_candidates(P, observed_classes) for P in ds]
        # Julia's matching of the call's static signature, asked once: a method whose signature
        # covers it leaves no tuple without a method
        local _mms = wt_method_matches(Tuple{_T, ds...})
        local _covered = _mms !== nothing && any(m -> Tuple{_T, ds...} <: m.method.sig, _mms)
        if !_covered
            for cs in _candidate_product(_ech, _T, ds, invocation_site[(_T, ds)])
                local _none = wt_method_matches(Tuple{_T, cs...})
                (_none === nothing || !isempty(_none)) && continue
                local _rt = Any[something(type_element_kind(C), C) for C in cs]
                all(t -> t isa DataType && isconcretetype(t), _rt) && _record_no_method!(no_method, _T, Tuple{_rt...})
            end
        end
        local enroll_closure!(cmi, at) = (cmi === nothing || cmi in seen) ? nothing :
            (push!(seen, cmi); push!(out, cmi);
             reasons[cmi] = "the body of the closure $(_T), constructed and called dynamically with ($(join(ds, ", ")))" * at;
             nothing)
        for mm in (_mms === nothing ? () : _mms)
            # a match that is one signature is enrolled as it is; otherwise (a UnionAll, or a
            # static parameter left a TypeVar at a kind, A8C6) Julia specializes it at each
            # argument's class when it runs
            if _match_is_one_signature(mm)
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
            local choices = [!mentions(p) ? Any[ds[p]] :
                             Any[C for C in dispatch_candidates(ds[p], observed_classes) if admits(C, p)] for p in eachindex(ds)]
            for cs in _candidate_product(choices, _T, ds, invocation_site[(_T, ds)])
                local cms = wt_method_matches(Tuple{_T, cs...})
                for cm in (cms === nothing ? () : cms)
                    (cm.method === mm.method && _match_is_one_signature(cm)) || continue
                    enroll_closure!(CC.specialize_method(cm.method, cm.spec_types, cm.sparams),
                                    ", at the observed classes ($(join(cs, ", ")))")
                end
            end
        end
    end
    return out
end

"""
    _record_no_method!(no_method, F, T)

Record that callable type `F` has no method for the args tuple `T` (Julia's matching in the
consult found none): the callee's no-method record, which the plan carries and the MethodError
of a dynamic call of `F` reads (`no_method`), never another callee's.
formal(dev/formal/ClassIdSwitch.tla): the no-row block reads only the callee's Record.
parity(pkg/dart2wasm/lib/dynamic_dispatchers.dart:178 _generateMethodCode): the call's no-match
block, its error built from its own arguments.
"""
_record_no_method!(no_method::IdDict{DataType,Set{DataType}}, F::DataType, T::DataType)::Nothing =
    (push!(get!(() -> Set{DataType}(), no_method, F), T); nothing)

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
    for (_, _, src) in _collected_pairs(codeinfos)
        src in scanned && continue
        push!(scanned, src)
        for rec in build_nir(src)
            rec.node isa NirCall || continue
            f = _nir_callee_object(rec.node.callee)
            (f === Core.Intrinsics.muladd_float || f === Core.Intrinsics.fma_float) || continue
            T = CC.widenconst(rec.julia_type)
            numeric_register(T) in (F32, F64) && push!(types, T)
        end
    end
    return Any[wt_dispatch_mi(Tuple{typeof(Base.fma_emulated), T, T, T}) for T in types]
end

"""
The closed world one collection built (collect_closed_world): the collected (CodeInstance,
CodeInfo) pairs; the dynamic-dispatch selector roots, distinct from the ordinary dependencies
their compilation reaches; the callable types whose bodies the candidate fixpoint enrolled;
why each MethodInstance entered it, for a later failure — declaring its signature — to name;
the one class set (`classes`, closed_world_classes: the classes a value may have and the
`Type{X}` of each type object a value may be); the closure types an `:invoke` calls; per callable
type, the args tuples it has no method for; the `Base.fma_emulated`
MethodInstance it roots for each fma lowering, by signature; each body's numeric joins
(_numeric_joins!); and the capture typing of its last round (_CaptureTyping).
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
struct ClosedWorld
    codeinfos::Vector{Any}                # alternating CodeInstance, CodeInfo
    dynamic_roots::Set{Core.MethodInstance}          # enrolled as selector candidates
    callable_types::Set{DataType}                    # callable types whose bodies the candidate fixpoint enrolled
    enrolled_as::IdDict{Core.MethodInstance,String}  # why each entered the closed world
    classes::ClosedWorldClasses                      # the one class set (closed_world_classes)
    invoked_closures::Set{DataType}                  # the closure and functor types an :invoke calls
    no_method::IdDict{DataType,Set{DataType}}        # per callable type, the args tuples it has no method for
    lowering_callees::Dict{Type,Core.MethodInstance} # each fma lowering's Base.fma_emulated, by signature
    numeric_joins::IdDict{Core.CodeInfo,Dict{Int,Type}}  # each body's numeric joins (_numeric_joins!)
    capture::_CaptureTyping                          # the captured variables' types, the bodies' capture reads
end

"""Cut the bodies of declared imports (external leaves) out of a collection before it merges:
keep the code the entries reach over the closed world's edges (`_closed_world_edge`, the
relation the collector enrolls by), never walking into or keeping an import's body. It runs at
every merge, on Julia's first collection and on each later round's compile! output, and is the
collection's only cut: a body an edge of a kept body names is kept, whatever its kind.
parity(quarantine: Julia's native fallback bodies of a declared import are inferred with its
callers but are not the Wasm component's; dart's imports have no Dart body.)"""
function _prune_external_leaf_subgraphs(codeinfos::Vector{Any}, entries::Vector{Any},
                                        external_leaves::Set{Any};
                                        numeric_joins::IdDict{Core.CodeInfo,Dict{Int,Type}},
                                        capture::_CaptureTyping)::Vector{Any}
    isempty(external_leaves) && return codeinfos
    interp = WasmInterpreter(Base.RefValue(0))
    pairs = Dict{Any,Tuple{Any,Core.CodeInfo}}()
    for (ci, mi, src) in _collected_pairs(codeinfos)
        pairs[mi] = (ci, src)
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
        local arg_type = _edge_arg_type(pair[2], mi, pair_nir, pair_slot_types, numeric_joins, capture)
        # every edge, of every kind the collector enrolls by: a kind missing here would cut a
        # body Julia's queue collected through it (1.13's `:new` of a closure, b107)
        for s in pair_nir
            local edge = _closed_world_edge(s.node, pair[2], pair_slot_types, arg_type, interp)
            edge === nothing || push!(queue, edge[2])
        end
    end
    out = Any[]
    for (ci, mi, src) in _collected_pairs(codeinfos)
        mi in reachable || continue
        mi in external_leaves && continue
        push!(out, ci, src)
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
    local classes = ClosedWorldClasses(Set{DataType}(), Set{DataType}())
    local invoked_closures = Set{DataType}()
    local no_method = IdDict{DataType,Set{DataType}}()
    local lowering_callees = Dict{Type,Core.MethodInstance}()
    local numeric_joins = IdDict{Core.CodeInfo,Dict{Int,Type}}()
    local capture = _CaptureTyping()
    # Fresh cache partition per collection: see cache_token in WasmInterpreter.
    interp = WasmInterpreter(Base.RefValue(0))
    invokelatest_queue = CC.CompilationQueue(; interp)
    codeinfos = Any[]
    workqueue = CC.CompilationQueue(; interp)
    append!(workqueue, entries)
    try
        CC.compile!(codeinfos, workqueue; invokelatest_queue, _COMPILE_KW...)
        CC.compile!(codeinfos, invokelatest_queue; invokelatest_queue, _COMPILE_KW...)
    catch err
        # located as every later round's failure is (collect_new_pairs!): the entry that fails
        # alone, named with its reason
        (err isa WasmInternalError || err isa InterruptException || err isa OutOfMemoryError) && rethrow()
        throw_located_collection_failure(Tuple{Any,String}[(e, "a compilation entry") for e in entries],
                                         err, catch_backtrace(), _compile_root_alone)
    end
    # Imports are typed call-graph leaves. Julia inference may inspect their
    # native fallback bodies, but those bodies and their dependencies do not
    # belong to the Wasm component. Cut them before invoke completion and
    # dynamic-dispatch discovery so external implementation details can never
    # contaminate the closed world.
    codeinfos = _prune_external_leaf_subgraphs(codeinfos, entries, external_leaves; numeric_joins, capture)
    # Julia's queue may leave an explicit invoke with an abstract callable slot
    # as an IR edge without materializing its body (e.g. Base.with_output_color's
    # `Function` argument). A closed world cannot defer that edge to codegen.
    # Enroll every edge's target (_closed_world_edge) to a fixpoint before selector discovery.
    base_mis = Set{Any}()
    mi_key(mi) = (mi.def, mi.specTypes)
    base_mi_keys = Set{Any}()
    for (_, mi, _) in _collected_pairs(codeinfos)
        push!(base_mis, mi)
        push!(base_mi_keys, mi_key(mi))
    end
    invoke_seen = union(copy(base_mis), external_leaves)
    # each retargeted :invoke's own MethodInstance, by body and statement: every round recomputes
    # the site from it (_missing_explicit_invoke_mis)
    invoke_originals = IdDict{Core.CodeInfo,Dict{Int,Core.MethodInstance}}()
    seen_disp = Set{Any}()
    # why each MethodInstance entered the closed world, for a collection failure to name: the
    # collector's walk of the edges records every target's (_missing_explicit_invoke_mis), the
    # dynamic step every candidate's, and the plan reads them
    enrolled_by = IdDict{Core.MethodInstance,String}(e => "a compilation entry" for e in entries)

    # Explicit invokes and dynamic-dispatch candidates form ONE reachability
    # problem. Either class can add IR containing edges of the other class, so
    # sequential fixpoints are insufficient. Iterate both collectors together
    # until neither can add a MethodInstance; every collection uses a fresh
    # interpreter/cache partition and only new pairs are merged.
    # each root's reason is the one its enrollment recorded (enrolled_by); a root with none is a
    # collector defect, raised here
    function collect_new_pairs!(mis)
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
            matches = wt_method_matches(root_mi.specTypes)
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
            local why = get(enrolled_by, root_mi, nothing)
            why === nothing && throw(WasmInternalError(string(root_mi), 0, "",
                String["collecting the closed world: $(root_mi) was enrolled with no recorded reason"],
                ErrorException("a closed-world root with no enrollment reason"), Base.StackTraces.StackFrame[]))
            push!(batch, (resolved_mi, why))
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
        fresh_ci = _prune_external_leaf_subgraphs(fresh_ci, Any[first.(batch)...], external_leaves; numeric_joins, capture)
        for (fci, mi, fsrc) in _collected_pairs(fresh_ci)
            mi_key(mi) in base_mi_keys && continue
            push!(base_mis, mi)
            push!(base_mi_keys, mi_key(mi))
            push!(codeinfos, fci, fsrc)
            added = true
        end
        return added
    end

    fma_scanned = Base.IdSet{Any}()
    # the loop only adds: no collected body is ever dropped (dart's worklist only adds too)
    while true
        # the round's capture typing, over the world collected so far, before any typer reads it
        _capture_typing!(capture, codeinfos)
        changed = collect_new_pairs!(_missing_explicit_invoke_mis(
            codeinfos, invoke_seen; numeric_joins, capture, reasons=enrolled_by, invoked_closures,
            invoke_originals))

        # one NIR per collected CodeInfo for this round's two walks (the class set, then the
        # candidates); round-local: `_missing_explicit_invoke_mis` re-targets invoke edges in place
        # between rounds, so a boundary cached across rounds would describe an IR that no longer exists
        local nir_cache = IdDict{Core.CodeInfo,Vector{NirStmt}}()
        local nir_for = src -> get!(() -> build_nir(src), nir_cache, src)
        classes = closed_world_classes(codeinfos, entries, nir_for)
        extra = _dynamic_dispatch_candidate_mis(codeinfos, seen_disp; reasons=enrolled_by, classes, nir_for,
                                                no_method, numeric_joins, capture)
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
        local fma_roots = _fused_multiply_add_mis(codeinfos, fma_scanned)
        for mi in fma_roots
            lowering_callees[mi.specTypes] = mi   # the lowering's callee, as rooted
            haskey(enrolled_by, mi) || (enrolled_by[mi] = "the Julia body of the fma/muladd intrinsic lowering")
        end
        fma_mis = Any[mi for mi in fma_roots if !(mi_key(mi) in base_mi_keys)]
        changed |= collect_new_pairs!(fma_mis)
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
    return ClosedWorld(codeinfos, dynamic_roots, callable_types, enrolled_by, classes, invoked_closures,
                       no_method, lowering_callees, numeric_joins, capture)
end

"""
    entry_method_instance(f, arg_types::Tuple) -> MethodInstance

Resolve the `MethodInstance` for `f(::arg_types...)` — the entry handle
`collect_closed_world` consumes.
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function entry_method_instance(f, arg_types::Tuple)::Core.MethodInstance
    tt = Tuple{Core.Typeof(f), arg_types...}
    local m = wt_method_which(tt)
    # no method: `which`'s error, the MethodError a call would throw
    m === nothing && throw(ErrorException(sprint(io -> (println(io, "Calling invoke(f, t, args...) would throw:");
                                                     Base.showerror(io, MethodError(f, arg_types))))))
    return CC.specialize_method(m)   # at Julia's match, its static parameters' values included
end


"""
The compile inputs one closed world yields (trim_compile_plan), every per-function fact keyed by
its MethodInstance, as dart's TFA metadata is keyed by its tree node: every function to compile
as (f, arg_types, name, MethodInstance) — entries keep their given names, the rest get deduped
names; each MethodInstance's (CodeInfo, rettype), so every function compiles from the
collection's consistent-world IR (plan_ir); the MethodInstances discovered as dynamic-dispatch
candidates; the MethodInstances reached only through an `invoke` of a method dispatch would not
select for their argument types; the callable types the candidate fixpoint enrolled; why each
MethodInstance was enrolled; the one class set (closed_world_classes), which the numbering
numbers and the union-split MethodError tuples and the vtable pre-pass's ambiguity search read; the
MethodInstances compiled from a bespoke body (L133) with that body's generator; per callable
type, the args tuples it has no method for, each sorted by type_order_key (the MethodError of a
dynamic call reads its callee's, and the numbering takes every key and tuple); and the
MethodInstance each lowering that calls a Julia function by name calls, keyed by its signature
(`Base.fma_emulated` for the fma intrinsics); and each planned body's joins (plan_joins), its
captured-box reads typed by the record of every captured variable, computed once in collection.
parity(pkg/dart2wasm/lib/translator.dart:115 Translator.directCallMetadata): the front end's
per-node answers, which codegen reads and never recomputes.
"""
struct ClosedWorldPlan
    functions::Vector{Any}
    ir_cache::IdDict{Core.MethodInstance,Tuple{Core.CodeInfo,Type}}
    candidate_mis::Set{Core.MethodInstance}
    invoke_only::Set{Core.MethodInstance}
    callable_types::Set{DataType}
    enrolled_as::IdDict{Core.MethodInstance,String}
    classes::ClosedWorldClasses        # the one class set (closed_world_classes)
    bespoke::IdDict{Core.MethodInstance,Function}
    no_method::IdDict{DataType,Vector{DataType}}
    lowering_callees::Dict{Type,Core.MethodInstance}
    external_leaves::Vector{Any}   # (callable, argument types, MethodInstance) of each declared import
    joins::IdDict{Core.MethodInstance,Dict{Int,Type}}   # each planned body's joins (numeric, capture reads)
end

"""
    plan_ir(plan, mi) -> (CodeInfo, return type)

The collected closed world's typed IR of one MethodInstance: the only IR codegen reads (L152).
A MethodInstance outside the closed world is an error, never a second inference (which would
run another interpreter, at another world, in another cache partition).
parity(quarantine: Julia's typed IR is WT's frontend input, asked of Julia's own inference; dart2wasm receives Kernel already built by the CFE.)
"""
function plan_ir(plan::ClosedWorldPlan, mi::Core.MethodInstance)::Tuple{Core.CodeInfo,Type}
    local hit = plan_ir_or_nothing(plan, mi)
    hit === nothing && error("$(mi) is outside the collected closed world; codegen reads the " *
                             "collection's IR, never a second inference")
    return hit
end

"""
    plan_ir_or_nothing(plan, mi) -> (CodeInfo, return type) | nothing

plan_ir for a lookup that misses by design: a body the closed world does not hold (a declared
import's, which is not the module's; a captor body no edge reached, whose writes never run).
The caller states which, and a miss is never a second inference.
parity(quarantine: Julia's typed IR is WT's frontend input, asked of Julia's own inference; dart2wasm receives Kernel already built by the CFE.)
"""
function plan_ir_or_nothing(plan::ClosedWorldPlan, mi::Core.MethodInstance)::Union{Nothing,Tuple{Core.CodeInfo,Type}}
    local hit = get(plan.ir_cache, mi, nothing)
    return hit === nothing ? nothing : (hit[1], hit[2])
end

"""
    plan_joins(plan, mi) -> Dict{Int,Type}

The joins of a planned body, SSA id => the type Julia's erased `Any` (or Union) carries there:
its numeric joins (NumericJoin.tla) and its captured-box reads (CaptureType.tla,
BoxValueTypes.tla), computed once in collection with the inputs codegen would have used.
Codegen reads them here and computes none; a MethodInstance the plan holds none for is an error.
parity(pkg/dart2wasm/lib/translator.dart:119 Translator.inferredTypeMetadata): the type flow
analysis's per-node types, computed before codegen and read by it.
"""
function plan_joins(plan::ClosedWorldPlan, mi::Core.MethodInstance)::Dict{Int,Type}
    local hit = get(plan.joins, mi, nothing)
    hit === nothing && error("$(mi) has no joins in the plan: codegen reads the collection's joins, never its own")
    return hit
end

"""
    plan_lowering_callee(plan, sig) -> MethodInstance | nothing

The MethodInstance the plan records for a lowering that calls a Julia function by name, at its
signature `sig` (ClosedWorldPlan's `lowering_callees`), or `nothing` when the closed world holds
none.
parity(pkg/dart2wasm/lib/translator.dart:115 Translator.directCallMetadata): the front end's
per-node answers, which codegen reads and never recomputes.
"""
plan_lowering_callee(plan::ClosedWorldPlan, @nospecialize(sig::Type))::Union{Nothing,Core.MethodInstance} =
    get(plan.lowering_callees, sig, nothing)

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
    local external_leaves = Any[]   # (callable, argument types, MethodInstance) of each declared import
    for entry in external_entries
        f, arg_types = entry[1], entry[2]
        local xmi = entry_method_instance(f, arg_types)
        push!(external_mis, xmi)
        push!(external_leaves, (f, Tuple(arg_types), xmi))
    end
    local world = collect_closed_world(entry_mis; external_leaves=external_mis)
    return plan_closed_world(world, entry_keys, entry_values, external_leaves)
end

"""
    plan_closed_world(world, entry_keys, entry_values, external_leaves) -> ClosedWorldPlan

The compile inputs (ClosedWorldPlan) one collected closed world yields, its entries named by
`entry_keys` (MethodInstance => requested name) with their values `entry_values`, and the declared
imports `external_leaves`. It reads the world and writes none of it: every reason, joins memo and
record stays the collection's (formal(dev/formal/ClosedWorld.tla): ReasonsComplete).
parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
"""
function plan_closed_world(world::ClosedWorld, entry_keys::Dict{Any,String}, entry_values::Dict{Any,Any},
                           external_leaves::Vector{Any})::ClosedWorldPlan
    codeinfos = world.codeinfos

    functions = Any[]
    ir_cache = IdDict{Core.MethodInstance, Tuple{Core.CodeInfo, Type}}()
    collected_method_specs = Set{Any}()
    local pairs = _collected_pairs(codeinfos)
    for (_, cmi, _) in pairs
        push!(collected_method_specs, (cmi.def, cmi.specTypes))
    end
    # A capturing closure a collected body invokes statically (Base's reallocating
    # `_growend!`/`_growbeg!` closures) is a direct call of a known method: its body is
    # compiled like the invoker's, keyed by the closure type (dart: a closure's target is
    # compiled when the closure is created). Dynamic calls of Base closures stay out. The
    # collector's walk of the edges recorded those closure types and every body's reason; the
    # plan reads the world and writes none of it.
    local invoked_closures = world.invoked_closures
    local enrolled_as = world.enrolled_as
    # the planner's own copy of the joins memo, so the world's is never written
    local numeric_joins = copy(world.numeric_joins)
    # Functions pulled in only by dispatch-candidate discovery are registered as
    # candidates rather than ordinary direct-call targets, keyed by their MethodInstance (a
    # closure body's planned argument types lack the closure type its function prepends).
    candidate_mis = Set{Core.MethodInstance}()
    # the functions compiled from a bespoke body instead of their IR (L133), decided here once
    bespoke = IdDict{Core.MethodInstance,Function}()
    # the callable types a vtable is built for (a closure type planned as its body's function, or a
    # singleton callable the candidate fixpoint enrolled), each with a no-method record
    planned_callables = Set{DataType}()
    # Pre-seed with entry names: a discovered function processed before its
    # same-named entry must not claim the entry's export name (duplicate-export
    # validation failure in multi-function modules).
    used_names = Set{String}(values(entry_keys))
    # One function per MethodInstance (dart keys a function by its member's Reference). Two
    # methods can share one specialization's argument types — Base calls a less specific
    # method with `invoke(f, Tuple{Super}, x)` — so (f, arg_types) does not name a function.
    seen_mis = Set{Tuple{Any, Any}}()          # (mi.def, mi.specTypes)
    mis_by_sig = Dict{Tuple{Any, Any}, Vector{Any}}()
    # each planned body's joins, read by codegen (numeric_local_joins): its numeric joins and its
    # capture reads, each computed once in collection (ClosedWorld's numeric_joins, capture)
    local joins = IdDict{Core.MethodInstance,Dict{Int,Type}}()
    for (ci, mi, src) in pairs
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
        elseif ftyp isa DataType && ftyp in invoked_closures
            # A functor an :invoke calls (Julia leaves the call uninlined when it always
            # throws): keyed by its type like a capturing closure, its function takes the
            # object first. Dispatch never selects it, so it has no vtable.
            f = ftyp
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
        (f isa DataType && is_closure_type(f)) && push!(planned_callables, f)
        (f isa Function && typeof(f) in world.callable_types) && push!(planned_callables, typeof(f))
        ir_cache[mi] = (src, ci.rettype)
        local capture_joins = get(world.capture.joins, mi, nothing)
        capture_joins === nothing && throw(WasmInternalError(name, 0, "",
            String["planning the closed world: the capture reads of $(mi)"],
            ErrorException("the collection's last round typed no capture reads for a planned body"),
            Base.StackTraces.StackFrame[]))
        joins[mi] = _body_joins(numeric_joins, world.capture, mi, src, build_nir(src), nir_slot_types(src))
        local gen = mi.def isa Method ? get(STANDALONE_INTRINSIC_BODIES, mi.def, nothing) : nothing
        gen === nothing || (bespoke[mi] = gen)
        # Only discovery ROOTS are selector candidates. Dependencies compiled
        # transitively with a root remain ordinary cross-call-visible functions.
        if mi in world.dynamic_roots && !haskey(entry_keys, mi)
            push!(candidate_mis, mi)
        end
    end
    # (f, arg_types) names the function Julia's dispatch selects for those types: where two
    # collected methods share them, the other one is reached only by its `invoke`
    # (FunctionInfo.invoke_only) and never by a call that names (f, arg_types).
    invoke_only = Set{Core.MethodInstance}()
    for (_, mis) in mis_by_sig
        local winner = if length(mis) == 1
            only(mis)
        else
            local match = wt_method_which(first(mis).specTypes)
            local w = match === nothing ? nothing : findfirst(m -> m.def === match.method, mis)
            w === nothing ? nothing : mis[w]
        end
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
    # each callee's no-method tuples, in one deterministic order; a planned callable with a
    # vtable whose dynamic call the collector enrolled no tuple for has its (empty) record too
    local no_method = IdDict{DataType,Vector{DataType}}(
        F => sort!(collect(Ts); by=type_order_key) for (F, Ts) in world.no_method)
    for F in planned_callables
        haskey(no_method, F) || (no_method[F] = DataType[])
    end
    # the function each named-callee lowering calls: the collector's root, which the closed world
    # holds (one it does not is a collector defect, raised here, naming the root)
    for (sig, lmi) in world.lowering_callees
        haskey(ir_cache, lmi) || throw(WasmInternalError(string(sig), 0, "",
            String["planning the closed world: the fma lowering's root $(lmi) was collected under another MethodInstance or not at all"],
            ErrorException("a lowering callee outside the closed world"), Base.StackTraces.StackFrame[]))
    end
    return ClosedWorldPlan(functions, ir_cache, candidate_mis, invoke_only,
                           world.callable_types, enrolled_as, world.classes,
                           bespoke, no_method, copy(world.lowering_callees), external_leaves,
                           joins)
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
    type_element_kind(P) -> Union{Nothing, Type}

The runtime type of a value of static type `P = Type{X}`: X's kind, `typeof(X)` (DataType,
Union, UnionAll or Core.TypeofBottom), as jl_f_tuple types a type object element; `nothing` for
any other `P`. The one `Type{X}` element rule: tuple_runtime_type, a tuple type's registration
(_canonical_tuple_type), a MethodError's args tuple and a type-object argument's canonical
signature (_canonical_type_object_arg) read it.
parity(quarantine: Julia types a type object element by its kind; a dart record's field types
are static.)
"""
type_element_kind(@nospecialize(P))::Union{Nothing, Type} =
    (P isa DataType && P.name === Type.body.name && length(P.parameters) == 1 &&
     P.parameters[1] isa Type) ? typeof(P.parameters[1]) : nothing

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
            (a isa NirGlobalRef && a.constant) ? (true, a.value) : (false, nothing)
        if has
            push!(rt, typeof(val))      # a type object's runtime type is its kind
            continue
        end
        local T = value_type(a, slot_types, nothing)
        local K = type_element_kind(T)
        if K !== nothing
            push!(rt, K)
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
    return (p, value_type(operands[p], slot_types, nothing), rt)
end

"""
    _collected_operand_value(operand) -> (Bool, value)

The program value an operand materializes when the NIR boundary knows it statically: a
literal's value, unresolved (a quoted GlobalRef is the GlobalRef object, as Julia's
interpreter evaluates a QuoteNode to its payload, jl_quotenode_value, and value_type and codegen
read it), or a bound global's current value (values.jl's global arm bakes a
non-const binding's CURRENT value as a mutable-global initializer, so its type is
reachable too). `(false, nothing)` for an SSA use, an argument, a slot or an unbound
global — values whose types the inferred types already carry.
parity(constants.dart:298 Constants.ensureConstant): a constant operand is a value the module
materializes.
"""
function _collected_operand_value(operand::NirNode)::Tuple{Bool, Any}
    operand isa NirLiteral && return (true, operand.value)
    (operand isa NirGlobalRef && operand.bound) && return (true, operand.value)
    return (false, nothing)
end

"""
    _collect_reachable_ir_types(function_data, bespoke, classes) -> Set{DataType}

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
are values. What a constant holds is not walked here: every class of the one class set
(`classes`, closed_world_classes, whose walk of a constant's contents is the one) is numbered
through reg!, its field types with it.

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
function _collect_reachable_ir_types(function_data, bespoke::IdDict{Core.MethodInstance,Function},
                                     classes::ClosedWorldClasses)::Set{DataType}
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
    end
    for fd in function_data
        # a bespoke body is rethrow's (L133 holds the table to it), and emit_rethrow! throws
        # Julia's ErrorException at depth 0
        haskey(bespoke, fd[9]) && (reg!(ErrorException); reg!(String))
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
    # every class of the one set is numbered, with its field types (reg!): a class a value may
    # have has an id whether or not a planned body names it, and the classes a constant holds are
    # the set's (closed_world_classes' one walk of a constant's contents, hold!). A class the
    # lowering instantiates is numbered as the struct compile.jl registers before the numbering
    # (and String by assign_type_ids!'s classed list), its layout's own (a TypeError's field typed
    # by a union holding GlobalRef is no value the lowering makes)
    for C in closed_world_class_list(classes)
        C in LOWERING_INSTANTIATED_CLASSES || reg!(C)
    end
    # the args tuple of each such throw, for every class a value at its open position may have:
    # the one class set's (closed_world_classes; a tuple class added here is no value's class)
    for (p, S, rt) in error_args, C in closed_world_class_list(classes)
        (C <: S && !(C <: Type)) || continue
        push!(out, Tuple{(j == p ? C : rt[j] for j in eachindex(rt))...})
    end
    return out
end
