# F3 — dart2wasm-aligned mutable closure capture (`Core.Box`). See dev/HISTORY.md#closures-and-dynamic-dispatch.
#
# THE PURE PRINCIPLE (dart2wasm, closures.dart:1102-1115): a captured cell is typed by the
# VARIABLE'S OWN TYPE (`translateTypeOfLocalVariable`) — `int`→`i64` field, `dynamic`→top type
# (boxed). Julia erases this by reifying every mutated capture as `Core.Box{contents::Any}`, so the
# pure equivalent is to RECOMPUTE the variable's inferred type = the JOIN of all its assignments
# (enclosing init + every closure write, each write's result type computed via
# `Core.Compiler.return_type` past the box's `Any`-erasure). CONCRETE join → typed `Box{i64}`;
# `Union`/abstract/`Any` → anyref `Box` (dart2wasm's top-type field). This reconstructs what
# dart2wasm gets for free from Dart's static types — NOT a heuristic, NOT "type by init and hope".
#
# This file owns the pure inference over typed IR. `compute_numeric_joins!` invokes it once per
# context phase; specialized `Box{contents}` layouts flow through %new, setfield!/getfield, and
# closure capture fields. Unit-tested in test/f3_box_capture_l0.jl.
#
# Every analysis here reads the NIR boundary (`Vector{NirStmt}`), never a raw statement: the box
# pattern IS a node pattern — a `NirCall` on the RESOLVED `setfield!`/`getfield` object, a `NirNew`
# whose `T` is `Core.Box`, a `NirPi`/`NirPhi` carrying it forward. The callee identity comes from
# the boundary's one resolution, so a same-named function in another module can never be mistaken
# for `Core.setfield!` (the L124 rule). `build_nir` is a pure function of a CodeInfo, so the closure
# bodies this file walks (retrieved through `get_typed_ir`) go through the same boundary.

const _F3_CC = Core.Compiler

"""The caller's type answer for one SSA id, widened once. `sst` is whatever the caller holds:
the NIR itself (each node's own type — Julia inference's widened answer for that SSA), a raw
per-SSA lattice vector, or a context's REFINED map (`Dict`/`IntKeyMap`). All three read through
one get-safe accessor, so a refinement the context proved still wins over inference's answer."""
_f3_ssa_type(sst::Vector{NirStmt}, id::Int)::Type = _nir_ssa_type(sst, id)
function _f3_ssa_type(sst, id::Int)::Type
    t = try
        get(sst, id, Any)
    catch
        (1 <= id <= length(sst)) ? sst[id] : Any
    end
    t isa Type && return t
    return try; _F3_CC.widenconst(t); catch; Any; end
end

"""The Julia type a literal operand contributes as a call argument. A type literal argues as
`Type` (the call site passes the type OBJECT), everything else as its own concrete type."""
_f3_literal_type(@nospecialize(v))::Type = v isa Type ? Type : typeof(v)

"""The callee OBJECT a NirCall/NirInvoke names, or `nothing` when there is none: a `NirNode`
callee is dynamic (an SSA/argument value with no static identity), and a `GlobalRef` that
survived the boundary's resolution was unbound. A callee the IR embeds as the object itself
is neither a GlobalRef nor a QuoteNode, so the boundary classifies it as a literal operand —
unwrapped here, and only when it is callable.

Not in nir.jl only because stage 1 of the R29 migration owns that file; it belongs beside
`resolve_call_callee`, which is the resolution this reads back."""
function _nir_callee_object(@nospecialize(callee))::Any
    callee isa NirLiteral && return (callee.value isa Function ? callee.value : nothing)
    (callee isa NirNode || callee isa GlobalRef || callee === nothing) && return nothing
    return callee
end

_f3_is_contents(x)::Bool = x isa NirLiteral && x.value === :contents

"""The `(box, value)` operands of a `setfield!(box, :contents, value)` call node (ANY box),
or `nothing` when the node is not one. Keyed on the resolved `setfield!` object the boundary
already produced — a same-named function in another module is a different callee."""
function _f3_contents_write(node::NirNode)::Union{Nothing,Tuple{NirNode,NirNode}}
    node isa NirCall || return nothing
    node.callee === setfield! || return nothing
    local operands = node.args
    (length(operands) >= 3 && _f3_is_contents(operands[2])) || return nothing
    return (operands[1], operands[3])
end

# Is `a` a `getfield(_, :contents)` read in `nir` (the box's contents, whatever box)?
function _f3_is_box_read(a, nir::Vector{NirStmt})::Bool
    a isa NirSSA || return false
    1 <= a.id <= length(nir) || return false
    local node = nir[a.id].node
    node isa NirCall || return false
    node.callee === getfield || return false
    local operands = node.args
    return length(operands) >= 2 && _f3_is_contents(operands[2])
end

# Does `arg` reference the box created at SSA index `box_id`? Direct `%box_id` or `PiNode(%box_id,…)`.
function _f3_refers_to_box(arg, box_id::Int, nir::Vector{NirStmt})::Bool
    arg isa NirSSA || return false
    arg.id == box_id && return true
    if 1 <= arg.id <= length(nir)
        local node = nir[arg.id].node
        if node isa NirPi && node.value isa NirSSA && node.value.id == box_id
            return true
        end
    end
    return false
end

# Concrete Julia type of an IR operand, with box-contents reads typed as `T` and `NirArgument`s
# resolved through `spectypes` (the method's signature tuple). Non-pinnable → `Any`.
function _f3_operand_type(a, sst, @nospecialize(T), spectypes, nir::Vector{NirStmt})
    _f3_is_box_read(a, nir) && return T
    if a isa NirSSA
        return _f3_ssa_type(sst, a.id)
    elseif a isa NirArgument
        return (spectypes !== nothing && 1 <= a.n <= length(spectypes)) ?
               _F3_CC.widenconst(spectypes[a.n]) : Any
    elseif a isa NirLiteral
        return _f3_literal_type(a.value)
    else
        return Any
    end
end

# Result type of a contents-write value `rhs` in `nir`, given box-contents type estimate `T`
# and the enclosing method's `spectypes`. Calls compute via `return_type` with box-reads typed `T`.
function _f3_write_result_type(nir::Vector{NirStmt}, sst, spectypes, rhs, @nospecialize(T))
    if rhs isa NirSSA && 1 <= rhs.id <= length(nir)
        local node = nir[rhs.id].node
        if node isa NirCall
            f = _nir_callee_object(node.callee)
            f === nothing && return Any
            local operands = node.args
            argtypes = Any[_f3_operand_type(a, sst, T, spectypes, nir) for a in operands]
            return infer_return_type(f, Tuple(argtypes))
        end
        return _f3_ssa_type(sst, rhs.id)
    end
    return _f3_operand_type(rhs, sst, T, nothing, nir)
end

# Every `getfield(#self#, fld)` read in `nir` for `fld` ∈ `fields` — the pattern by which a
# closure body reaches one of its OWN Core.Box-typed captured fields (dart2wasm `Capture.type`'s
# context-field read, closures.dart:1436). Returns ssa_id → the field read. Shared by
# `f3_closure_box_seeds` (seed the box's known contents type into the closure body) and
# `_f3_collect_capturing_bodies!` (find where a further-nested closure re-captures the SAME box).
function _f3_self_field_reads(nir::Vector{NirStmt}, fields::Set{Symbol})::Dict{Int,Symbol}
    out = Dict{Int,Symbol}()
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirCall || continue
        node.callee === getfield || continue
        local operands = node.args
        length(operands) >= 2 || continue
        (operands[1] isa NirArgument && operands[1].n == 1) || continue   # #self#
        local fld = operands[2]
        fld isa NirLiteral || continue
        fld.value in fields && (out[i] = fld.value)
    end
    return out
end

# Which field (by :new argument position) of each closure type created in `nir` captures the box
# at SSA index `box_id` — (closure type, field name) pairs, matched the same way `_f3_box_captors`
# always has (`%new(clo, …, box, …)` via `_f3_refers_to_box`). The field name is what lets discovery
# recurse: a captor closure's OWN body reaches the SAME box one hop further in as
# `getfield(#self#, thatfield)`, not another literal `%new(Core.Box)`.
function _f3_box_captor_fields(nir::Vector{NirStmt}, box_id::Int)::Vector{Tuple{Type,Symbol}}
    out = Tuple{Type,Symbol}[]
    for s in nir
        local node = s.node
        node isa NirNew || continue
        local ty = node.T
        ty !== Core.Box || continue
        local operands = node.args
        for j in eachindex(operands)
            _f3_refers_to_box(operands[j], box_id, nir) || continue
            (isstructtype(ty) && 1 <= j <= fieldcount(ty)) || continue
            push!(out, (ty, fieldname(ty, j)))
        end
    end
    return out
end

# The set of closure types that capture the box at SSA index `box_id` (from `%new(clo, …, box, …)`).
_f3_box_captors(nir::Vector{NirStmt}, box_id::Int)::Set{Type} =
    Set{Type}(ty for (ty, _) in _f3_box_captor_fields(nir, box_id))

# Retrieve the NIR + specTypes of EVERY closure body that captures `box_id` — directly, via a
# literal `%new(clo, …, box, …)` in `nir`, OR TRANSITIVELY through any chain of further-nested
# closure creation. The box writes this join must fold in live in these bodies. Recursion: a
# discovered closure's own body reaches the SAME box one hop deeper as `getfield(#self#, boxfield)`
# (boxfield = the field `_f3_box_captor_fields` matched for it); `_f3_box_captor_fields` and
# `_f3_refers_to_box` already treat "the box" as any SSA value regardless of how it arrived, so the
# same one-hop matching recurses unchanged on that SSA id, any depth. `visited` (keyed by specTypes)
# guards a recursive closure that captures itself. Returns Vector{(nir, spectypes)}.
function _f3_capturing_closure_bodies(nir::Vector{NirStmt}, box_id::Int)
    out = Tuple{Vector{NirStmt}, Any}[]
    _f3_collect_capturing_bodies!(out, Set{Any}(), nir, box_id)
    return out
end

function _f3_collect_capturing_bodies!(out::Vector{Tuple{Vector{NirStmt}, Any}}, visited::Set{Any},
                                       nir::Vector{NirStmt}, box_id::Int)::Vector{Tuple{Vector{NirStmt}, Any}}
    field_captors = _f3_box_captor_fields(nir, box_id)
    isempty(field_captors) && return out
    captor_types = Set{Type}(ty for (ty, _) in field_captors)
    # find the invokes of those closures → their MethodInstance.specTypes → typed IR
    for s in nir
        local node = s.node
        node isa NirInvoke || continue
        mi = node.mi
        mi isa Core.MethodInstance || continue
        st = mi.specTypes
        st isa DataType && st <: Tuple && length(st.parameters) >= 1 || continue
        clo_T = st.parameters[1]
        (clo_T in captor_types) || continue
        st in visited && continue
        push!(visited, st)
        irs = try get_typed_ir(st) catch; nothing end
        irs === nothing && continue
        boxfields = Set{Symbol}(f for (ty, f) in field_captors if ty === clo_T)
        for pair in irs
            body_nir = build_nir(pair.first)
            push!(out, (body_nir, collect(st.parameters)))
            # A further-nested closure reaches the SAME box as `getfield(#self#, boxfield)` — find
            # that read's SSA id in this body and recurse discovery one hop deeper from it.
            for i in keys(_f3_self_field_reads(body_nir, boxfields))
                _f3_collect_capturing_bodies!(out, visited, body_nir, i)
            end
        end
    end
    return out
end

"""
    box_contents_type(nir, ssa_types, box_id) -> Type | Nothing

PURE contents type for the `Core.Box` created at SSA index `box_id`: the JOIN of the enclosing init
write and EVERY closure write's computed result type (closure bodies retrieved via the `invoke`
CodeInstance; write types via `return_type` past the `Any`-erasure). Returns the concrete type if
the join unifies to one concrete `DataType`, else `nothing` (`Union`/abstract/`Any` ⇒ the box is
genuinely dynamic ⇒ anyref-boxed, dart2wasm's top-type field). Mirrors dart2wasm typing a context
field by the variable's own type — reconstructing what Julia erased. F3 L0; not yet wired
(byte-identical). See dev/HISTORY.md#closures-and-dynamic-dispatch.
"""
# formal(dev/formal/BoxJoin.tla): the join below is SOUND (a concrete type is chosen only
# when every write the box can ever receive, any nesting depth, agrees on it), order-
# independent, and never lets an invisible write narrow the cell. Closure-write discovery
# (_f3_capturing_closure_bodies) is TRANSITIVE — it recurses into a discovered closure's own
# body to find a further-nested captor, any depth — matching MCBoxJoin.cfg's TransitiveDiscovery
# = TRUE, the shape this model requires for the four claims to hold.
function box_contents_type(nir::Vector{NirStmt}, ssa_types, box_id::Int)::Union{Type,Nothing}
    # 1) enclosing init write(s)
    init = nothing
    for s in nir
        w = _f3_contents_write(s.node)
        w === nothing && continue
        _f3_refers_to_box(w[1], box_id, nir) || continue
        vt = _f3_operand_type(w[2], ssa_types, Any, nothing, nir)
        vt === Any && return nothing
        init = init === nothing ? vt : Union{init, vt}
    end
    init === nothing && return nothing
    # 2) every closure write, computed with contents = init (divergence ⇒ Union ⇒ dynamic)
    types = Any[init]
    for (body_nir, cspec) in _f3_capturing_closure_bodies(nir, box_id)
        for s in body_nir
            w = _f3_contents_write(s.node)
            w === nothing && continue
            push!(types, _f3_write_result_type(body_nir, body_nir, cspec, w[2], init))
        end
    end
    joined = reduce((a, b) -> Union{a, b}, types)
    return (joined isa DataType && isconcretetype(joined)) ? joined : nothing
end

# Find the SSA index of `%new(Core.Box)` statements in a body's NIR (helper for callers/tests).
function find_box_news(nir::Vector{NirStmt})::Vector{Int}
    out = Int[]
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirNew && node.T === Core.Box && push!(out, i)
    end
    return out
end

# Result type of one call node with box-derived operands typed by `out` (propagated) — the engine
# of f3_box_value_types. A `getfield(box,:contents)` read → the box's contents type; any other call
# → `return_type` with each SSA operand typed by `out[id]` if propagated, else its inferred type.
function _f3_call_result_type(node::NirCall, nir::Vector{NirStmt}, out::Dict{Int,Type},
                              boxT::Dict{Int,Type}, ssa_types, spectypes)
    local operands = node.args
    if node.callee === getfield && length(operands) >= 2 && _f3_is_contents(operands[2])
        boxref = operands[1]
        for (bid, T) in boxT
            _f3_refers_to_box(boxref, bid, nir) && return T
        end
        return nothing
    end
    f = _nir_callee_object(node.callee)
    f === nothing && return nothing
    argtypes = Any[]
    uses_box = false   # only propagate through ops that actually CONSUME a box-derived value
    for a in operands
        if a isa NirSSA && haskey(out, a.id)
            push!(argtypes, out[a.id]); uses_box = true
        elseif a isa NirSSA
            push!(argtypes, _f3_ssa_type(ssa_types, a.id))
        elseif a isa NirArgument
            # resolve closure/fn arguments (e.g. the closure's `i`) via slottypes/specTypes
            push!(argtypes, (spectypes !== nothing && 1 <= a.n <= length(spectypes)) ?
                  _F3_CC.widenconst(spectypes[a.n]) : Any)
        elseif a isa NirLiteral
            push!(argtypes, _f3_literal_type(a.value))
        else
            push!(argtypes, Any)
        end
    end
    uses_box || return nothing
    return infer_return_type(f, Tuple(argtypes))
end

"""
    f3_box_value_types(nir, ssa_types = nir) -> Dict{Int,Type}

F3 L2b — the VALUE-TYPE PROPAGATION past Julia's `Box{Any}` erasure (the F3 L2 unblocker the L2
attempt surfaced; dart2wasm `node.accept1 → ValueType`). Forward fixed-point: each `%new(Core.Box)`
with CONCRETE contents T seeds box-reads of it → T; any op over already-propagated SSAs → its
computed result type (`return_type` with propagated operand types). Returns ssa_id → concrete Julia
type for box-DERIVED values (the getfield result, the `s+i` arithmetic) — these are inferred `Any`
by Julia (the dynamic `+`) but compute at a concrete width, so without this they get anyref locals
the i64 value can't fill ("expected anyref, found i64"). PURE analysis (the typed-box wiring consumes
it to type the chain). Does NOT type the box itself (that is the box-local typing). See dev/HISTORY.md#closures-and-dynamic-dispatch.
"""
function f3_box_value_types(nir::Vector{NirStmt}, ssa_types = nir;
                            extra_box_seeds::Dict{Int,Type}=Dict{Int,Type}(),
                            spectypes=nothing)::Dict{Int,Type}
    out = Dict{Int,Type}()
    boxT = Dict{Int,Type}(extra_box_seeds)
    for bid in find_box_news(nir)
        t = box_contents_type(nir, ssa_types, bid)
        t !== nothing && (boxT[bid] = t)
    end
    isempty(boxT) && return out
    changed = true
    while changed
        changed = false
        for (i, s) in enumerate(nir)
            haskey(out, i) && continue
            local node = s.node
            # Propagate through PiNode narrowings + φ nodes (the isa-split that narrows a box read
            # to its concrete type) so an op CONSUMING the narrowed value still sees a box-derived
            # operand — else the `s+=i` add over the read keeps its anyref-from-erasure.
            if node isa NirPi && node.value isa NirSSA && haskey(out, node.value.id)
                out[i] = out[node.value.id]; changed = true; continue
            end
            if node isa NirPhi
                vts = Type[]; nssa = 0
                for v in node.values
                    v isa NirSSA || continue
                    nssa += 1
                    haskey(out, v.id) && push!(vts, out[v.id])
                end
                if !isempty(vts) && length(vts) == nssa
                    j = reduce((a, b) -> Union{a, b}, vts)
                    if j isa DataType && isconcretetype(j)
                        out[i] = j; changed = true; continue
                    end
                end
            end
            node isa NirCall || continue
            ft = _f3_call_result_type(node, nir, out, boxT, ssa_types, spectypes)
            if ft isa DataType && isconcretetype(ft) && ft !== Core.Box
                out[i] = ft
                changed = true
            end
        end
    end
    return out
end

# Is `T` one of WT's concrete numeric wasm-representable scalar types?
_f3_is_numeric_jl(T) = T isa DataType && isconcretetype(T) &&
    (T <: Integer || T <: AbstractFloat) && T !== Bool && sizeof(T) <= 8 && !(T <: BigInt)

"""
    propagate_numeric_value_types(nir, ssa_types = nir) -> Dict{Int,Type}

Loop C value channel (dart2wasm `node.accept1 → ValueType` — the type is a byproduct of emission).
Julia erases a mutated capture to `Any` even after the WT interpreter inlines + scalar-replaces the
`Core.Box` away, leaving an `Any`-typed numeric phi-accumulator computing concrete values (e.g.
`%acc = φ(0::Int64, %add)::Any; %add = %acc + i::Any`). Those `Any` SSAs get anyref locals the i64
value can't fill. This recovers the concrete type: anchor on already-concrete-numeric SSAs, then a
fixed point that types an `Any` numeric op / phi by its operands (OPTIMISTICALLY seeding a phi from
its resolved concrete operand to break the acc↔add cycle), then a VERIFY pass that drops any phi
whose operands don't ALL resolve numeric (so `φ(0,"x")` stays Any). Returns ssa_id → concrete numeric
Julia type for the `Any`-but-really-numeric SSAs only. Pure analysis.
"""
function propagate_numeric_value_types(nir::Vector{NirStmt}, ssa_types = nir;
                                        argtypes=nothing, self_shift::Int=1)::Dict{Int,Type}
    out = Dict{Int,Type}()
    _opT(a) = a isa NirSSA ? (haskey(out, a.id) ? out[a.id] : _f3_ssa_type(ssa_types, a.id)) :
              a isa NirLiteral ? _f3_literal_type(a.value) :
              a isa NirArgument ? ((argtypes !== nothing && 1 <= a.n - self_shift <= length(argtypes) &&
                                    argtypes[a.n - self_shift] isa Type) ?
                                   argtypes[a.n - self_shift] : Any) :
              Any
    # only consider SSAs Julia left as Any (don't override a known concrete type)
    pend = Int[i for i in eachindex(nir) if _f3_ssa_type(ssa_types, i) === Any]
    changed = true
    while changed
        changed = false
        for i in pend
            haskey(out, i) && continue
            local node = nir[i].node
            if node isa NirPhi
                ts = Type[]; have_concrete = false
                for v in node.values
                    t = _opT(v)
                    _f3_is_numeric_jl(t) && (push!(ts, t); have_concrete = true)
                end
                # optimistic: a phi with ≥1 resolved-numeric operand seeds to their join (cycle break)
                if have_concrete
                    j = reduce((a, b) -> Union{a, b}, ts)
                    if _f3_is_numeric_jl(j)
                        out[i] = j; changed = true
                    end
                end
            elseif node isa NirCall || node isa NirInvoke
                # Both call nodes name the callee and the runtime operands the same way — the
                # `:invoke` preamble (its MethodInstance) never reaches `args`.
                f = _nir_callee_object(node.callee)
                f === nothing && continue
                ats = Any[_opT(a) for a in node.args]
                all(_f3_is_numeric_jl, ats) || continue   # every operand must be (resolved) numeric
                rt = infer_return_type(f, Tuple(ats))
                if _f3_is_numeric_jl(rt)
                    out[i] = rt; changed = true
                end
            end
        end
    end
    # VERIFY: drop any phi we optimistically typed whose operands don't ALL resolve numeric.
    verifying = true
    while verifying
        verifying = false
        for (i, _) in collect(out)
            local node = nir[i].node
            node isa NirPhi || continue
            ok = all(v -> _f3_is_numeric_jl(_opT(v)), node.values)
            if !ok
                delete!(out, i); verifying = true
            end
        end
    end
    return out
end


"""
    f3_self_box_joins(nir, ssa_types, selfT; argtypes=nothing, self_shift=1) -> Dict{Int,Type}

parity(closures.dart:1436 Capture.type) — the CLOSURE-LOCAL typed capture:
when the parent scalar-replaced the `Core.Box` (no `%new` to record) the closure body must
solve its captured contents type ALONE. Optimistic-verify: (1) find the `getfield(#self#,
boxfield)` box reads; (2) CANDIDATE contents type = the join of resolved-numeric OTHER
operands in arithmetic that consumes the box's `:contents` reads (e.g. `contents + i::Int64`
⇒ Int64); (3) seed `f3_box_value_types` with box-read → candidate; (4) VERIFY every
`setfield!(box, :contents, v)` value resolves to a numeric ⊆ candidate — else return empty
(anyref fallback, no unsoundness).
"""
function f3_self_box_joins(nir::Vector{NirStmt}, ssa_types, selfT;
                           argtypes=nothing, self_shift::Int=1)::Dict{Int,Type}
    out = Dict{Int,Type}()

    boxfields = (selfT isa DataType && isconcretetype(selfT) && isstructtype(selfT)) ?
        Set{Symbol}(fieldname(selfT, i) for i in 1:fieldcount(selfT)
                    if fieldtype(selfT, i) === Core.Box) : Set{Symbol}()
    _ssat(i) = _f3_ssa_type(ssa_types, i)
    _opT(a) = a isa NirSSA ? _ssat(a.id) :
              a isa NirLiteral ? _f3_literal_type(a.value) :
              a isa NirArgument ? ((argtypes !== nothing && 1 <= a.n - self_shift <= length(argtypes) &&
                                    argtypes[a.n - self_shift] isa Type) ?
                                   argtypes[a.n - self_shift] : Any) :
              Any
    # A box read is `getfield(carrier, boxfield)` where the carrier is #self# (the
    # closure compiling its own body) OR any local value whose type has Core.Box
    # fields (parity M10b: a closure RETURNED by a callee and used here — the box
    # was born in the callee; the inlined body reads it through the closure value).
    _has_box_fields(T) = T isa DataType && isconcretetype(T) && isstructtype(T) &&
        any(i -> fieldtype(T, i) === Core.Box, 1:fieldcount(T))
    _box_field_names(T) = Set{Symbol}(fieldname(T, j) for j in 1:fieldcount(T)
                                      if fieldtype(T, j) === Core.Box)
    _saw_ssa_carrier = false
    _saw_write = false
    box_reads = Set{Int}()
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirCall || continue
        node.callee === getfield || continue
        local operands = node.args
        length(operands) >= 2 || continue
        base = operands[1]
        carrier_ok = (base isa NirArgument && base.n == 1 && !isempty(boxfields)) ||
                     (base isa NirSSA && _has_box_fields(_ssat(base.id)))
        carrier_ok || continue
        base isa NirSSA && (_saw_ssa_carrier = true)
        local fld = operands[2]
        fld isa NirLiteral || continue
        _bf = base isa NirArgument ? boxfields : _box_field_names(_ssat(base.id))
        fld.value in _bf && push!(box_reads, i)
    end
    isempty(box_reads) && return out
    contents_reads = Set{Int}()
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirCall || continue
        node.callee === getfield || continue
        local operands = node.args
        length(operands) >= 2 || continue
        (operands[1] isa NirSSA && operands[1].id in box_reads) || continue
        _f3_is_contents(operands[2]) && push!(contents_reads, i)
    end
    isempty(contents_reads) && return out
    # A concrete write to the captured box is the strongest dart-style capture
    # type evidence. This covers non-numeric captures (for example a Vector built
    # and assigned before its first read) without guessing from consumers.
    direct_types = Type[]
    for s in nir
        w = _f3_contents_write(s.node)
        w === nothing && continue
        (w[1] isa NirSSA && w[1].id in box_reads) || continue
        vt = _opT(w[2])
        vt isa Type && vt !== Any && vt !== Union{} && push!(direct_types, vt)
    end
    cand = isempty(direct_types) ? nothing : foldl(typejoin, direct_types)
    (cand isa DataType && isconcretetype(cand)) || (cand = nothing)
    # When no definite concrete write exists, retain the proven numeric consumer
    # inference used for accumulator captures.
    for s in nir
        cand === nothing || break
        local node = s.node
        (node isa NirCall || node isa NirInvoke) || continue
        local operands = node.args
        any(a -> a isa NirSSA && a.id in contents_reads, operands) || continue
        for a in operands
            (a isa NirSSA && a.id in contents_reads) && continue
            t = _opT(a)
            if _f3_is_numeric_jl(t)
                cand = cand === nothing ? t : Union{cand, t}
            end
        end
    end
    (cand isa Type && cand !== Any && cand !== Union{}) || return out
    seeds = Dict{Int,Type}(b => cand for b in box_reads)
    _spec = argtypes === nothing ? nothing :
            (self_shift == 1 ? Any[selfT; argtypes...] : Any[argtypes...])
    joins = f3_box_value_types(nir, ssa_types; extra_box_seeds=seeds, spectypes=_spec)
    for c in contents_reads
        joins[c] = cand
    end
    for s in nir
        w = _f3_contents_write(s.node)
        w === nothing && continue
        (w[1] isa NirSSA && w[1].id in box_reads) || continue
        _saw_write = true
        local v = w[2]
        vt = v isa NirSSA ? get(joins, v.id, _ssat(v.id)) : _opT(v)
        (vt isa Type && vt <: cand) || return Dict{Int,Type}()
    end
    # The BOX-READ ids are Core.Box VALUES, never numerics — they must not appear in
    # the join output (they'd re-type the box itself and break every consumer).
    for b in box_reads
        delete!(joins, b)
    end
    # VACUOUS-VERIFY guard: if NO setfield! write was visible in this body, the
    # optimistic candidate was never actually tested. For the #self# carrier that is
    # fine (the closure only reads; the parent wrote) — but for generalized SSA
    # carriers (a closure value from a callee) an unverified candidate poisons
    # string-carrying accumulators (print_to_string). Bail without joins then.
    if !_saw_write && _saw_ssa_carrier
        return Dict{Int,Type}()
    end
    return joins
end

# F3 L2b CLOSURE-BODY seed (dart2wasm `Capture.type = context.struct.fields[i].type`): in a closure
# BODY there is no %new(Core.Box) to seed from — the box arrives as `getfield(#self#, boxfield)` where
# `boxfield` is a Core.Box field of the closure type `selfT`. Map each such read → the box's contents
# type (`contents_T`, recovered from the enclosing fn's L2a side-table), so the body's box-derived
# arithmetic types past Box{Any} erasure exactly like dart reads its typed context field directly.
function f3_closure_box_seeds(nir::Vector{NirStmt}, selfT, contents_T)::Dict{Int,Type}
    out = Dict{Int,Type}()
    (selfT isa DataType && isstructtype(selfT) && contents_T isa Type) || return out
    boxfields = Set{Symbol}(fieldname(selfT, i) for i in 1:fieldcount(selfT) if fieldtype(selfT, i) === Core.Box)
    isempty(boxfields) && return out
    for i in keys(_f3_self_field_reads(nir, boxfields))
        out[i] = contents_T
    end
    return out
end

"""
    populate_box_field_types!(mod, registry, nir, ssa_types)

F3 L2 cross-function glue (pre-pass over an enclosing fn's NIR). For each `%new(Core.Box)`
whose contents type is CONCRETE (`box_contents_type`), map every closure type that captures it →
the box's contents WASM type, into `registry.box_contents_types`. `register_closure_type!` then
types the captured-box field as a typed `Box{contents}` instead of anyref. Dynamic-contents boxes
(`box_contents_type` ⇒ `nothing`) get NO entry → anyref fallback (current behavior, no regression).

The context value-channel proof invokes this before local typing, and closure registration reads
the side table when choosing its captured-cell field type. See dev/HISTORY.md#closures-and-dynamic-dispatch.
"""
function populate_box_field_types!(mod, registry, nir::Vector{NirStmt}, ssa_types)
    registry.box_contents_types === nothing && return registry.box_contents_types
    for box_id in find_box_news(nir)
        bt = box_contents_type(nir, ssa_types, box_id)
        bt === nothing && continue                       # dynamic contents → anyref fallback
        contents_wasm = get_concrete_wasm_type(bt, mod, registry)
        for clo_T in _f3_box_captors(nir, box_id)
            registry.box_contents_types[clo_T] = contents_wasm
        end
    end
    return registry.box_contents_types
end
