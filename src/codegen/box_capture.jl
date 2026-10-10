# F3 — dart2wasm-aligned mutable closure capture (`Core.Box`). See dev/HISTORY.md#closures-and-dynamic-dispatch.
#
# THE PURE PRINCIPLE (dart2wasm, closures.dart:1533 _buildContexts, the field typed at :1579
# translateTypeOfLocalVariable): a captured cell is typed by the
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

# parity(quarantine: the Core.Compiler alias of the capture-typing pass (dev/formal/CaptureType.tla).)
const _F3_CC = Core.Compiler

"""The caller's type answer for one SSA id, widened once. `sst` is whatever the caller holds:
the NIR itself (each node's own type — Julia inference's widened answer for that SSA), a raw
per-SSA lattice vector, or a context's REFINED map (`Dict`/`IntKeyMap`). All three read through
one get-safe accessor, so a refinement the context proved still wins over inference's answer.
parity(code_generator.dart:135 getStaticType): an operand's type is its defining node's, read once.
"""
_f3_ssa_type(sst::Vector{NirStmt}, id::Int)::Type = _nir_ssa_type(sst, id)
# parity(code_generator.dart:135 getStaticType): the same read from a lattice vector or a refined map.
function _f3_ssa_type(sst, id::Int)::Type
    t = get(sst, id, Any)   # Vector, IntKeyMap and Dict all answer an absent id with Any
    t isa Type && return t
    return _F3_CC.widenconst(t)
end

"""The Julia type a literal operand contributes as a call argument. A type literal argues as
`Type` (the call site passes the type OBJECT), everything else as its own concrete type.
parity(code_generator.dart:130 ConstantExpression): a constant's static type is its constant's type."""
_f3_literal_type(@nospecialize(v))::Type = v isa Type ? Type : typeof(v)

# parity(quarantine: `:contents` is the one field of Julia's `Core.Box`, the untyped cell Julia
# lowering creates for a reassigned captured variable; dart's captured variable is a typed field
# of its context struct, closures.dart:1576)
_f3_is_contents(x)::Bool = x isa NirLiteral && x.value === :contents

"""The `(box, value)` operands of a `setfield!(box, :contents, value)` call node (ANY box),
or `nothing` when the node is not one. Keyed on the resolved `setfield!` object the boundary
already produced — a same-named function in another module is a different callee.
parity(closures.dart:1579 translateTypeOfLocalVariable): a captured variable's cell type is the
join of the values written to it; these are the writes."""
function _f3_contents_write(node::NirNode)::Union{Nothing,Tuple{NirNode,NirNode}}
    node isa NirCall || return nothing
    node.callee === setfield! || return nothing
    local operands = node.operands
    (length(operands) >= 3 && _f3_is_contents(operands[2])) || return nothing
    return (operands[1], operands[3])
end

# Is `a` a `getfield(_, :contents)` read in `nir` (the box's contents, whatever box)?
# parity(quarantine: a `getfield(_, :contents)` read of a Julia `Core.Box` is inferred `Any`
# because the field is declared `Any`; these reads are where the erased variable type is restored)
function _f3_is_box_read(a, nir::Vector{NirStmt})::Bool
    a isa NirSSA || return false
    1 <= a.id <= length(nir) || return false
    local node = nir[a.id].node
    node isa NirCall || return false
    node.callee === getfield || return false
    local operands = node.operands
    return length(operands) >= 2 && _f3_is_contents(operands[2])
end

# Does `arg` reference the box created at SSA index `box_id`? Direct `%box_id` or `PiNode(%box_id,…)`.
# parity(quarantine: Julia's typed IR carries a `Core.Box` forward through PiNode narrowings, so
# "this box" is an SSA value or a PiNode of it; dart names a captured variable by its Capture)
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
# parity(quarantine: types the operands of a value written into a Julia `Core.Box`, whose
# `contents::Any` erases the variable's type — box reads as the join candidate, arguments through
# the MethodInstance's specTypes)
function _f3_operand_type(a, sst, @nospecialize(T), spectypes, nir::Vector{NirStmt})::Union{Type, Core.TypeofVararg}
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
# parity(quarantine: the inferred type of one value written into a Julia `Core.Box`, recomputed
# through the one inference path because `contents::Any` erased it; dart reads the variable's
# inferred type, translator.dart:2100 translateTypeOfLocalVariable)
function _f3_write_result_type(nir::Vector{NirStmt}, sst, spectypes, rhs, @nospecialize(T))::Union{Type, Core.TypeofVararg}
    if rhs isa NirSSA && 1 <= rhs.id <= length(nir)
        local node = nir[rhs.id].node
        if node isa NirCall
            f = _nir_callee_object(node.callee)
            f === nothing && return Any
            local operands = node.operands
            argtypes = Any[_f3_operand_type(a, sst, T, spectypes, nir) for a in operands]
            return infer_return_type(f, Tuple(argtypes))
        end
        return _f3_ssa_type(sst, rhs.id)
    end
    return _f3_operand_type(rhs, sst, T, nothing, nir)
end

# Every `getfield(#self#, fld)` read in `nir` for `fld` ∈ `fields` — the pattern by which a
# closure body reaches one of its OWN Core.Box-typed captured fields (dart2wasm `Capture.type`'s
# context-field read, closures.dart:1436). Returns ssa_id → the field read. Used by
# `_f3_collect_capturing_bodies!` (find where a further-nested closure re-captures the SAME box).
# parity(quarantine: a Julia closure body reaches its captured `Core.Box` only as
# `getfield(#self#, field)` on its own struct, found by scanning the IR; dart's Closures pass
# records every Capture's context field, closures.dart:1411 Capture)
function _f3_self_field_reads(nir::Vector{NirStmt}, fields::Set{Symbol})::Dict{Int,Symbol}
    out = Dict{Int,Symbol}()
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirCall || continue
        node.callee === getfield || continue
        local operands = node.operands
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
# parity(quarantine: a Julia closure is a struct built by `%new(closure_type, captures...)`, so the
# closures holding a given `Core.Box` are found in the IR; dart records them in its Closures pass,
# closures.dart:1411 Capture)
function _f3_box_captor_fields(nir::Vector{NirStmt}, box_id::Int)::Vector{Tuple{Type,Symbol}}
    out = Tuple{Type,Symbol}[]
    for s in nir
        local node = s.node
        node isa NirNew || continue
        # The raw code resolved this operand only from a GlobalRef or a type
        # literal, so a type NAMED by a Core.apply_type SSA was skipped.
        node.type_kind === :literal || continue
        local ty = node.T
        ty !== Core.Box || continue
        local operands = node.operands
        for j in eachindex(operands)
            _f3_refers_to_box(operands[j], box_id, nir) || continue
            (isstructtype(ty) && 1 <= j <= fieldcount(ty)) || continue
            push!(out, (ty, fieldname(ty, j)))
        end
    end
    return out
end

# The set of closure types that capture the box at SSA index `box_id` (from `%new(clo, …, box, …)`).
# parity(quarantine: the closure types holding a given Julia `Core.Box`, from `%new` in the IR;
# dart records captures in its Closures pass, closures.dart:1411 Capture)
_f3_box_captors(nir::Vector{NirStmt}, box_id::Int)::Set{Type} =
    Set{Type}(ty for (ty, _) in _f3_box_captor_fields(nir, box_id))

# Retrieve the NIR + specTypes of EVERY closure body that captures `box_id` — directly, via a
# literal `%new(clo, …, box, …)` in `nir`, OR TRANSITIVELY through any chain of further-nested
# closure creation. The box writes this join must fold in live in these bodies. Recursion: a
# discovered closure's own body reaches the SAME box one hop deeper as `getfield(#self#, boxfield)`
# (boxfield = the field `_f3_box_captor_fields` matched for it); `_f3_box_captor_fields` and
# `_f3_refers_to_box` already treat "the box" as any SSA value regardless of how it arrived, so the
# same one-hop matching recurses unchanged on that SSA id, any depth. `visited` (keyed by specTypes)
# guards a recursive closure that captures itself. Returns Vector{(nir, spectypes)}, or nothing
# when a captor's body is not in the lookup: its writes are then unknown, and the box stays erased.
# parity(quarantine: every closure body that can write a Julia `Core.Box`, reached through the
# MethodInstances its captors are invoked with; the join of their writes restores the type
# `contents::Any` erased, where dart reads the variable's inferred type,
# translator.dart:2100 translateTypeOfLocalVariable)
function _f3_capturing_closure_bodies(nir::Vector{NirStmt}, box_id::Int;
                                      closure_ir::Function)::Union{Nothing, Vector{Tuple{Vector{NirStmt}, Any}}}
    out = Tuple{Vector{NirStmt}, Any}[]
    _f3_collect_capturing_bodies!(out, Set{Any}(), nir, box_id; closure_ir) || return nothing
    return out
end

# parity(quarantine: the transitive walk of _f3_capturing_closure_bodies — a further-nested Julia
# closure re-captures the same `Core.Box` as `getfield(#self#, field)`, found one hop per body)
function _f3_collect_capturing_bodies!(out::Vector{Tuple{Vector{NirStmt}, Any}}, visited::Set{Any},
                                       nir::Vector{NirStmt}, box_id::Int;
                                       closure_ir::Function)::Bool
    field_captors = _f3_box_captor_fields(nir, box_id)
    isempty(field_captors) && return true
    captor_types = Set{Type}(ty for (ty, _) in field_captors)
    # find the invokes of those closures → the collected IR of their MethodInstances (closure_ir:
    # the plan's in codegen, the collected pairs in collection). A captor whose body the lookup
    # does not hold has writes no one can see: the view is incomplete (false), and the box
    # stays erased rather than narrowed (BoxJoin.tla: an invisible write never narrows the cell)
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
        local hit = closure_ir(mi)
        hit === nothing && return false
        boxfields = Set{Symbol}(f for (ty, f) in field_captors if ty === clo_T)
        body_nir = build_nir(hit[1])
        push!(out, (body_nir, collect(st.parameters)))
        # A further-nested closure reaches the SAME box as `getfield(#self#, boxfield)` — find
        # that read's SSA id in this body and recurse discovery one hop deeper from it.
        for i in keys(_f3_self_field_reads(body_nir, boxfields))
            _f3_collect_capturing_bodies!(out, visited, body_nir, i; closure_ir) || return false
        end
    end
    return true
end

"""
    box_contents_type(nir, ssa_types, box_id; closure_ir) -> Type | Nothing

PURE contents type for the `Core.Box` created at SSA index `box_id`: the JOIN of the enclosing init
write and EVERY closure write's computed result type (closure bodies retrieved via the `invoke`
CodeInstance; write types via `return_type` past the `Any`-erasure). Returns the concrete type if
the join unifies to one concrete `DataType`, else `nothing` (`Union`/abstract/`Any` ⇒ the box is
genuinely dynamic ⇒ anyref-boxed, dart2wasm's top-type field). Mirrors dart2wasm typing a context
field by the variable's own type — reconstructing what Julia erased. F3 L0; not yet wired
(byte-identical). See dev/HISTORY.md#closures-and-dynamic-dispatch.
formal(dev/formal/BoxJoin.tla): the join below is SOUND (a concrete type is chosen only
when every write the box can ever receive, any nesting depth, agrees on it), order-
independent, and never lets an invisible write narrow the cell. Closure-write discovery
(_f3_capturing_closure_bodies) is TRANSITIVE — it recurses into a discovered closure's own
body to find a further-nested captor, any depth — matching MCBoxJoin.cfg's TransitiveDiscovery
= TRUE, the shape this model requires for the four claims to hold.
parity(quarantine: Julia lowers a reassigned captured variable to `Core.Box`, whose
`contents::Any` erases the variable's type; the join of every write restores it. dart types the
context field by the variable's inferred type, closures.dart:1579 translateTypeOfLocalVariable)
"""
function box_contents_type(nir::Vector{NirStmt}, ssa_types, box_id::Int;
                           spectypes=nothing, closure_ir::Function)::Union{Type,Nothing}
    # 1) enclosing init write(s); an argument written in is typed by the creator's signature
    init = nothing
    for s in nir
        w = _f3_contents_write(s.node)
        w === nothing && continue
        _f3_refers_to_box(w[1], box_id, nir) || continue
        vt = _f3_operand_type(w[2], ssa_types, Any, spectypes, nir)
        vt === Any && return nothing
        init = init === nothing ? vt : Union{init, vt}
    end
    bodies = _f3_capturing_closure_bodies(nir, box_id; closure_ir)
    bodies === nothing && return nothing     # a captor's writes are unknown: the box is dynamic
    # A box its creator declares but never writes starts undefined, and a read before any write
    # throws: its values are the closures' writes. Those that do not read the box (typed with the
    # contents unknown, Union{}) give the start; the others are then typed from it below.
    if init === nothing
        for (body_nir, cspec) in bodies, s in body_nir
            w = _f3_contents_write(s.node)
            w === nothing && continue
            local vt = _f3_write_result_type(body_nir, body_nir, cspec, w[2], Union{})
            vt === Union{} && continue
            init = init === nothing ? vt : Union{init, vt}
        end
    end
    init === nothing && return nothing
    # 2) every closure write, computed with contents = init (divergence ⇒ Union ⇒ dynamic)
    types = Any[init]
    for (body_nir, cspec) in bodies
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
# parity(quarantine: locates the `%new(Core.Box)` cells Julia lowering emits for reassigned
# captured variables; dart's captured variables live in context structs, closures.dart:1533)
function find_box_news(nir::Vector{NirStmt})::Vector{Int}
    out = Int[]
    for (i, s) in enumerate(nir)
        local node = s.node
        node isa NirNew && node.type_kind === :literal &&
            node.T === Core.Box && push!(out, i)
    end
    return out
end

# Result type of one call node with box-derived operands typed by `out` (propagated) — the engine
# of f3_box_value_types. A `getfield(box,:contents)` read → the box's contents type; any other call
# → `return_type` with each SSA operand typed by `out[id]` if propagated, else its inferred type.
# parity(quarantine: one step of f3_box_value_types — a call over values read from a Julia
# `Core.Box` is inferred `Any`; recompute it through the one inference path with the restored
# operand types)
function _f3_call_result_type(node::NirCall, nir::Vector{NirStmt}, out::Dict{Int,Type},
                              boxT::Dict{Int,Type}, ssa_types, spectypes)::Union{Nothing, Type}
    local operands = node.operands
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
    # an operand with no value (Union{}) means the call never runs
    any(t -> t === Union{}, argtypes) && return Union{}
    return infer_return_type(f, Tuple(argtypes))
end

"""
    f3_box_value_types(nir, ssa_types = nir; closure_ir) -> Dict{Int,Type}

F3 L2b — the VALUE-TYPE PROPAGATION past Julia's `Box{Any}` erasure (the F3 L2 unblocker the L2
attempt surfaced; dart2wasm `node.accept1 → ValueType`). Forward fixed-point: each `%new(Core.Box)`
with CONCRETE contents T seeds box-reads of it → T; any op over already-propagated SSAs → its
computed result type (`return_type` with propagated operand types). Returns ssa_id → concrete Julia
type for box-DERIVED values (the getfield result, the `s+i` arithmetic) — these are inferred `Any`
by Julia (the dynamic `+`) but compute at a concrete width, so without this they get anyref locals
the i64 value can't fill ("expected anyref, found i64"). PURE analysis (the typed-box wiring consumes
it to type the chain). Does NOT type the box itself (that is the box-local typing). See dev/HISTORY.md#closures-and-dynamic-dispatch.
parity(quarantine: values read from a Julia `Core.Box` are inferred `Any` because
`contents::Any` erased the captured variable's type; this carries the restored type through the
box-derived SSAs, where dart's visitor returns the ValueType it produced)
formal(dev/formal/BoxValueTypes.tla): every SSA it types holds exactly that type on every execution (a literal phi operand joins like an SSA's)
"""
function f3_box_value_types(nir::Vector{NirStmt}, ssa_types = nir;
                            extra_box_seeds::Dict{Int,Type}=Dict{Int,Type}(),
                            spectypes=nothing, record=nothing,
                            keep_nonconcrete::Bool=false, closure_ir::Function)::Dict{Int,Type}
    out = Dict{Int,Type}()
    boxT = Dict{Int,Type}(extra_box_seeds)
    for bid in find_box_news(nir)
        # a box a closure captures is typed by the whole program's writes into it (the record);
        # one no closure captures has all its writers here
        local fields = _f3_box_captor_fields(nir, bid)
        t = if record !== nothing && !isempty(fields)
            local ts = Type[get(record, tf, Any) for tf in fields]
            all(==(ts[1]), ts) && ts[1] isa DataType && isconcretetype(ts[1]) ? ts[1] : nothing
        else
            box_contents_type(nir, ssa_types, bid; spectypes, closure_ir)
        end
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
                # a phi is box-derived when an operand is: only then is it typed. Every operand
                # joins — a box-derived SSA by its propagated type, a literal by its own; any
                # other operand leaves the phi untyped
                any(v -> v isa NirSSA && haskey(out, v.id), node.values) || continue
                vts = Type[]
                for v in node.values
                    t = v isa NirSSA ? get(out, v.id, nothing) :
                        v isa NirLiteral ? _f3_literal_type(v.value) : nothing
                    t isa Type || (vts = nothing; break)
                    push!(vts, t)
                end
                if vts !== nothing && !isempty(vts)
                    j = reduce((a, b) -> Union{a, b}, vts)
                    if keep_nonconcrete || (j isa DataType && isconcretetype(j))
                        out[i] = j; changed = true; continue
                    end
                end
            end
            node isa NirCall || continue
            ft = _f3_call_result_type(node, nir, out, boxT, ssa_types, spectypes)
            # codegen keeps only a concrete type (a local's); record_capture_contents's fixpoint
            # keeps every computed one, Union{} (no value yet) and unions included
            if ft isa Type && ft !== Core.Box &&
               (keep_nonconcrete || (ft isa DataType && isconcretetype(ft)))
                out[i] = ft
                changed = true
            end
        end
    end
    return out
end

# Is `T` one of WT's concrete numeric wasm-representable scalar types?
# parity(quarantine: the numeric join of a scalar-replaced Julia `Core.Box` accumulator
# (propagate_numeric_value_types); the Julia scalar types WT lowers to one wasm number)
_f3_is_numeric_jl(T)::Bool = T isa DataType && isconcretetype(T) &&
    (T <: Integer || T <: AbstractFloat) && T !== Bool && sizeof(T) <= 8 && !(T <: BigInt)

"""
    propagate_numeric_value_types(nir, ssa_types = nir) -> Dict{Int,Type}

Loop C value channel (dart2wasm `node.accept1 → ValueType` — the type is a byproduct of emission).
Julia erases a mutated capture to `Any` even after the WT interpreter inlines + scalar-replaces the
`Core.Box` away, leaving an `Any`-typed numeric phi-accumulator computing concrete values (e.g.
`%acc = φ(0::Int64, %add)::Any; %add = %acc + i::Any`). Those `Any` SSAs get anyref locals the i64
value can't fill. This recovers the concrete type: anchor on already-concrete-numeric SSAs, then a
fixed point that types an `Any` numeric op / phi by its operands (OPTIMISTICALLY seeding a phi from
its resolved concrete operand to break the acc↔add cycle), then a VERIFY pass: a phi keeps its
seed only if every operand resolves numeric and their join is the seeded type (so `φ(0,"x")` and
`φ(0, %acc + 0.5)` stay Any); a phi that fails is banned and the fixed point restarts, so nothing
typed through the failed seed survives. Returns ssa_id → concrete numeric
Julia type for the `Any`-but-really-numeric SSAs only. Pure analysis.
parity(quarantine: Julia leaves a scalar-replaced `Core.Box` capture's numeric accumulator typed
`Any`; dart types a captured variable by its declared type, closures.dart:1579
translateTypeOfLocalVariable.)
formal(dev/formal/NumericJoin.tla): every SSA it types holds exactly that type on every execution (VERIFY rechecks each phi's join, bans a failing phi and restarts)
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
    banned = Set{Int}()   # phis VERIFY rejected: never typed again
    while true
        changed = true
        while changed
            changed = false
            for i in pend
                (haskey(out, i) || i in banned) && continue
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
                    ats = Any[_opT(a) for a in node.operands]
                    all(_f3_is_numeric_jl, ats) || continue   # every operand must be (resolved) numeric
                    rt = infer_return_type(f, Tuple(ats))
                    if _f3_is_numeric_jl(rt)
                        out[i] = rt; changed = true
                    end
                end
            end
        end
        # VERIFY: a phi's optimistic seed stands only if EVERY operand resolves numeric and their
        # join is exactly the seeded type. A phi that fails is banned and propagation restarts
        # from nothing, so no type computed through the failed seed survives.
        failed = Int[i for (i, t) in out if nir[i].node isa NirPhi &&
                     !(all(v -> _f3_is_numeric_jl(_opT(v)), nir[i].node.values) &&
                       reduce((a, b) -> Union{a, b}, Type[_opT(v) for v in nir[i].node.values]) === t)]
        isempty(failed) && return out
        union!(banned, failed)
        empty!(out)
    end
end




"""
    record_capture_contents(bodies; closure_ir) -> Dict{Tuple{Type,Symbol},Type}

The type of every captured variable of the closed world, keyed by (closure type, captured
field): the join of every write into the variable's `Core.Box` anywhere in `bodies` (each a
`(nir, spectypes, selfT)`) — its creator's writes into the box it makes (an argument typed by
the creator's signature), and every write through the field: in a body of the closure itself
(`#self#`) or through a closure value (a closure a callee returned, its body inlined). A write
that reads the variable (`c = c + 1`) is typed with the current record, so the join iterates
to a fixpoint. A field whose writes are not one concrete type records `Any`: its reads stay
erased. The record is complete for the closed world because every body that can run is in it,
which the creator alone is not (a returned closure's writes are invisible to its creator).
formal(dev/formal/CaptureType.tla): a captured box's read is typed by the join of every write
into the box, its creator's included.
parity(closures.dart:1436 Capture.type): a captured variable's type comes from its
declaration, the one type every read and write of it shares.
"""
function record_capture_contents(bodies::Vector; closure_ir::Function)::Dict{Tuple{Type,Symbol},Type}
    # The least fixpoint of the types each captured variable can hold: round k types every
    # write through a field with the field's contents as round k-1's set (a set still empty
    # holds no value yet: Union{}, and a write computed from it stores nothing), over the
    # base the creators' writes give. Each round recomputes from scratch, so a type only
    # stays if the writes still produce it.
    local held = Dict{Tuple{Type,Symbol},Set{Any}}()
    # the fields whose box some body creates: only those have their base in the closed world
    local created = Set{Tuple{Type,Symbol}}()
    for (nir, _, _) in bodies, box_id in find_box_news(nir)
        union!(created, _f3_box_captor_fields(nir, box_id))
    end
    for _round in 1:32
        local next = Dict{Tuple{Type,Symbol},Set{Any}}()
        add!(key, @nospecialize(t)) = (t === Union{} || push!(get!(() -> Set{Any}(), next, key), t))
        local seeds = Dict{Tuple{Type,Symbol},Type}(key => Union{ts...} for (key, ts) in held)
        for (nir, spec, selfT) in bodies
            for box_id in find_box_news(nir)
                local fields = _f3_box_captor_fields(nir, box_id)
                isempty(fields) && continue
                foreach(tf -> get!(() -> Set{Any}(), next, tf), fields)
                for s in nir
                    local w = _f3_contents_write(s.node)
                    (w === nothing || !_f3_refers_to_box(w[1], box_id, nir)) && continue
                    local t = _f3_operand_type(w[2], nir, Any, spec, nir)
                    foreach(tf -> add!(tf, t), fields)
                end
            end
            local joins = _capture_propagate(nir, seeds, selfT, spec; closure_ir)
            for s in nir
                local w = _f3_contents_write(s.node)
                w === nothing && continue
                local key = _captured_box_field(w[1], nir, selfT)
                key === nothing && continue
                local v = w[2]
                add!(key, v isa NirSSA ? get(joins, v.id, _f3_ssa_type(nir, v.id)) :
                          _f3_operand_type(v, nir, Any, spec, nir))
            end
        end
        if next == held
            local out = _capture_finalize(held)
            for key in keys(out)
                key in created || (out[key] = Any)   # its base is outside the closed world
            end
            return out
        end
        held = next
    end
    # no fixpoint within the bound: every captured variable stays erased (never a guess)
    return Dict{Tuple{Type,Symbol},Type}(key => Any for key in keys(held))
end

# The types of the values computed from captured-box reads in `nir`, the reads seeded with
# `seeds` (a union while record_capture_contents iterates; Union{} for a field with no value yet).
# parity(quarantine: one round of record_capture_contents's fixpoint over the reads of a Julia
# `Core.Box`, whose `contents::Any` erases the type the round's seed restores)
function _capture_propagate(nir::Vector{NirStmt}, seeds::Dict{Tuple{Type,Symbol},Type},
                            @nospecialize(selfT), spec; closure_ir::Function)::Dict{Int,Type}
    local reads = Dict{Int,Type}()
    for i in eachindex(nir)
        local key = _captured_box_field(NirSSA(i, Any), nir, selfT)
        key === nothing && continue
        reads[i] = get(seeds, key, Union{})   # a field with no value yet holds none
    end
    return f3_box_value_types(nir, nir; extra_box_seeds=reads, spectypes=spec, keep_nonconcrete=true, closure_ir)
end

# The record's answer per captured field: its one concrete type, else Any (erased).
# parity(quarantine: the finalization of record_capture_contents's join, a Julia Union of
# write types collapsing to the one concrete type dart's declaration names)
_capture_finalize(seen::Dict{Tuple{Type,Symbol},Set{Any}})::Dict{Tuple{Type,Symbol},Type} =
    Dict{Tuple{Type,Symbol},Type}(tf => ((length(ts) == 1 && first(ts) isa DataType &&
                                          isconcretetype(first(ts))) ? first(ts) : Any)
                                  for (tf, ts) in seen)

# The (closure type, field) a box operand reads — `getfield(carrier, f)` where the carrier is
# `#self#` (of type `selfT`) or a closure value and `f` is its captured `Core.Box` — or nothing.
# parity(quarantine: a Julia closure reaches its captured `Core.Box` through a field of its own
# struct; dart's captured variable is a field of the closure's context, closures.dart:1411 Capture)
function _captured_box_field(x, nir::Vector{NirStmt}, @nospecialize(selfT))::Union{Nothing,Tuple{Type,Symbol}}
    (x isa NirSSA && 1 <= x.id <= length(nir)) || return nothing
    local s = nir[x.id]
    local node = s.node
    (s.slot == 0 && node isa NirCall && node.callee === getfield && length(node.operands) >= 2) ||
        return nothing
    local base, fld = node.operands[1], node.operands[2]
    (fld isa NirLiteral && fld.value isa Symbol) || return nothing
    local T = (base isa NirArgument && base.n == 1) ? selfT : base isa NirSSA ? base.julia_type : nothing
    (T isa DataType && isstructtype(T) && hasfield(T, fld.value) &&
     fieldtype(T, fld.value) === Core.Box) || return nothing
    return (T, fld.value)
end

"""
    capture_read_types(nir, ssa_types, record, selfT; spectypes, closure_ir) -> Dict{Int,Type}

The types of the captured-box reads in `nir`, and of the values computed from them: a box read
`getfield(carrier, f)` whose carrier is the closure being compiled (`#self#`, of type
`selfT`) or a closure value (the M10b shape: a closure a callee returned) is seeded with the
type recorded for that captured field (record_capture_contents), a box this body creates and a
closure captures is typed by the record too, and
f3_box_value_types propagates it to the `:contents` reads and what they feed. The box reads
themselves are Core.Box values and are never retyped. A closure body never infers its
captured variable's type on its own: it cannot see its creator's writes.
parity(closures.dart:1436 Capture.type)
"""
function capture_read_types(nir::Vector{NirStmt}, ssa_types, record::Dict{Tuple{Type,Symbol},Type},
                            @nospecialize(selfT); spectypes=nothing, closure_ir::Function)::Dict{Int,Type}
    local seeds = Dict{Int,Type}()
    for i in eachindex(nir)
        local key = _captured_box_field(NirSSA(i, Any), nir, selfT)
        key === nothing && continue
        local ct = get(record, key, nothing)
        (ct isa DataType && isconcretetype(ct)) || continue
        seeds[i] = ct
    end
    local joins = f3_box_value_types(nir, ssa_types; extra_box_seeds=seeds, spectypes, record, closure_ir)
    for b in keys(seeds)
        delete!(joins, b)
    end
    return joins
end
