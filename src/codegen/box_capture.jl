# F3 — dart2wasm-aligned mutable closure capture (`Core.Box`). See dev/F3_LOOP.md.
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
# L0 (this file): the pure inference, a pure analysis over the typed IR. NOT yet wired into codegen
# (byte-identical); L1 registered the specialized `Box{contents}` struct, L2 threads it through
# %new / setfield! / getfield / the closure captured-box field. Unit-tested in test/f3_box_capture_l0.jl.

const _F3_CC = Core.Compiler

_f3_is_setfield(f) = f isa GlobalRef && f.name === :setfield! && (f.mod === Core || f.mod === Base)
_f3_is_contents(x) = (x isa QuoteNode && x.value === :contents) || x === :contents

# A `setfield!(_, :contents, v)` call statement (any box), returning the value operand or nothing.
function _f3_contents_write_value(stmt)
    if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 4 &&
       _f3_is_setfield(stmt.args[1]) && _f3_is_contents(stmt.args[3])
        return stmt.args[4]
    end
    return nothing
end

# Is `a` a `getfield(_, :contents)` read in `code` (the box's contents, whatever box)?
function _f3_is_box_read(a, code)::Bool
    a isa Core.SSAValue || return false
    1 <= a.id <= length(code) || return false
    s = code[a.id]
    return s isa Expr && s.head === :call && s.args[1] isa GlobalRef &&
           s.args[1].name === :getfield && length(s.args) >= 3 &&
           s.args[3] isa QuoteNode && s.args[3].value === :contents
end

# Does `arg` reference the box created at SSA index `box_id`? Direct `%box_id` or `PiNode(%box_id,…)`.
function _f3_refers_to_box(arg, box_id::Int, code)::Bool
    arg isa Core.SSAValue || return false
    arg.id == box_id && return true
    if 1 <= arg.id <= length(code)
        s = code[arg.id]
        if s isa Core.PiNode && s.val isa Core.SSAValue && s.val.id == box_id
            return true
        end
    end
    return false
end

# Concrete Julia type of an IR operand, with box-contents reads typed as `T` and `Core.Argument`s
# resolved through `spectypes` (the method's signature tuple). Non-pinnable → `Any`.
function _f3_operand_type(a, sst, T, spectypes, code)
    _f3_is_box_read(a, code) && return T
    if a isa Core.SSAValue
        return (1 <= a.id <= length(sst)) ? _F3_CC.widenconst(sst[a.id]) : Any
    elseif a isa Core.Argument
        return (spectypes !== nothing && 1 <= a.n <= length(spectypes)) ?
               _F3_CC.widenconst(spectypes[a.n]) : Any
    elseif a isa QuoteNode
        return typeof(a.value)
    elseif a isa GlobalRef
        return Any
    else
        return a isa Type ? Type : typeof(a)
    end
end

# Result type of a contents-write value `rhs` in IR `code`, given box-contents type estimate `T`
# and the enclosing method's `spectypes`. Calls compute via `return_type` with box-reads typed `T`.
function _f3_write_result_type(code, sst, spectypes, rhs, T)
    if rhs isa Core.SSAValue && 1 <= rhs.id <= length(code)
        s = code[rhs.id]
        if s isa Expr && s.head === :call
            op = s.args[1]
            f = op isa GlobalRef ? (isdefined(op.mod, op.name) ? getfield(op.mod, op.name) : nothing) :
                (op isa Function ? op : nothing)
            f === nothing && return Any
            argtypes = Any[_f3_operand_type(a, sst, T, spectypes, code) for a in s.args[2:end]]
            return try _F3_CC.return_type(f, Tuple{argtypes...}) catch; Any end
        end
        return (1 <= rhs.id <= length(sst)) ? _F3_CC.widenconst(sst[rhs.id]) : Any
    end
    return _f3_operand_type(rhs, sst, T, nothing, code)
end

# Retrieve the typed IR + specTypes of each closure invoked in `code` that captures `box_id`
# (via the `invoke`'s CodeInstance/MethodInstance — the robust, non-guessing way). The box writes
# live in these bodies. Returns Vector{(code, ssavaluetypes, spectypes)}.
# The set of closure types that capture the box at SSA index `box_id` (from `%new(clo, …, box, …)`).
function _f3_box_captors(code, box_id::Int)::Set{Type}
    captors = Set{Type}()
    for stmt in code
        stmt isa Expr && stmt.head === :new && length(stmt.args) >= 2 || continue
        any(j -> _f3_refers_to_box(stmt.args[j], box_id, code), 2:length(stmt.args)) || continue
        a1 = stmt.args[1]
        ty = a1 isa GlobalRef ? (isdefined(a1.mod, a1.name) ? getfield(a1.mod, a1.name) : nothing) :
             (a1 isa Type ? a1 : nothing)
        ty isa Type && ty !== Core.Box && push!(captors, ty)
    end
    return captors
end

function _f3_capturing_closure_bodies(code, box_id::Int)
    out = Tuple{Vector{Any}, Vector{Any}, Any}[]
    captors = _f3_box_captors(code, box_id)
    isempty(captors) && return out
    # find the invokes of those closures → their MethodInstance.specTypes → typed IR
    for stmt in code
        stmt isa Expr && stmt.head === :invoke || continue
        a1 = stmt.args[1]
        mi = a1 isa Core.MethodInstance ? a1 :
             (a1 isa Core.CodeInstance && isdefined(a1, :def) ? a1.def : nothing)
        mi isa Core.MethodInstance || continue
        st = mi.specTypes
        st isa DataType && st <: Tuple && length(st.parameters) >= 1 || continue
        (st.parameters[1] in captors) || continue
        irs = try Base.code_typed_by_type(st; optimize=true) catch; nothing end
        irs === nothing && continue
        for pair in irs
            b = pair.first
            push!(out, (b.code, b.ssavaluetypes, collect(st.parameters)))
        end
    end
    return out
end

"""
    box_contents_type(code, ssa_types, box_id) -> Type | Nothing

PURE contents type for the `Core.Box` created at SSA index `box_id`: the JOIN of the enclosing init
write and EVERY closure write's computed result type (closure bodies retrieved via the `invoke`
CodeInstance; write types via `return_type` past the `Any`-erasure). Returns the concrete type if
the join unifies to one concrete `DataType`, else `nothing` (`Union`/abstract/`Any` ⇒ the box is
genuinely dynamic ⇒ anyref-boxed, dart2wasm's top-type field). Mirrors dart2wasm typing a context
field by the variable's own type — reconstructing what Julia erased. F3 L0; not yet wired
(byte-identical). See dev/F3_LOOP.md.
"""
function box_contents_type(code, ssa_types, box_id::Int)::Union{Type,Nothing}
    # 1) enclosing init write(s)
    init = nothing
    for stmt in code
        v = _f3_contents_write_value(stmt)
        v === nothing && continue
        _f3_refers_to_box(stmt.args[2], box_id, code) || continue
        vt = _f3_operand_type(v, ssa_types, Any, nothing, code)
        vt === Any && return nothing
        init = init === nothing ? vt : Union{init, vt}
    end
    init === nothing && return nothing
    # 2) every closure write, computed with contents = init (divergence ⇒ Union ⇒ dynamic)
    types = Any[init]
    for (ccode, csst, cspec) in _f3_capturing_closure_bodies(code, box_id)
        for stmt in ccode
            v = _f3_contents_write_value(stmt)
            v === nothing && continue
            push!(types, _f3_write_result_type(ccode, csst, cspec, v, init))
        end
    end
    joined = reduce((a, b) -> Union{a, b}, types)
    return (joined isa DataType && isconcretetype(joined)) ? joined : nothing
end

# Find the SSA index of `%new(Core.Box)` statements in a typed IR (helper for callers/tests).
function find_box_news(code)::Vector{Int}
    out = Int[]
    for (i, s) in enumerate(code)
        if s isa Expr && s.head === :new && !isempty(s.args)
            a1 = s.args[1]
            ty = a1 isa GlobalRef ? (isdefined(a1.mod, a1.name) ? getfield(a1.mod, a1.name) : nothing) :
                 a1 isa Type ? a1 : nothing
            ty === Core.Box && push!(out, i)
        end
    end
    return out
end

# Result type of one call stmt with box-derived operands typed by `out` (propagated) — the engine
# of f3_box_value_types. A `getfield(box,:contents)` read → the box's contents type; any other call
# → `return_type` with each SSA operand typed by `out[id]` if propagated, else its inferred type.
function _f3_call_result_type(stmt, code, out::Dict{Int,Type}, boxT::Dict{Int,Type}, ssa_types, spectypes)
    op = stmt.args[1]
    if op isa GlobalRef && op.name === :getfield && length(stmt.args) >= 3 &&
       stmt.args[3] isa QuoteNode && stmt.args[3].value === :contents
        boxref = stmt.args[2]
        for (bid, T) in boxT
            _f3_refers_to_box(boxref, bid, code) && return T
        end
        return nothing
    end
    f = op isa GlobalRef ? (isdefined(op.mod, op.name) ? getfield(op.mod, op.name) : nothing) :
        (op isa Function ? op : nothing)
    f === nothing && return nothing
    argtypes = Any[]
    uses_box = false   # only propagate through ops that actually CONSUME a box-derived value
    for a in stmt.args[2:end]
        if a isa Core.SSAValue && haskey(out, a.id)
            push!(argtypes, out[a.id]); uses_box = true
        elseif a isa Core.SSAValue && 1 <= a.id <= length(ssa_types)
            push!(argtypes, _F3_CC.widenconst(ssa_types[a.id]))
        elseif a isa Core.Argument
            # resolve closure/fn arguments (e.g. the closure's `i`) via slottypes/specTypes
            push!(argtypes, (spectypes !== nothing && 1 <= a.n <= length(spectypes)) ?
                  _F3_CC.widenconst(spectypes[a.n]) : Any)
        elseif a isa QuoteNode
            push!(argtypes, typeof(a.value))
        else
            push!(argtypes, a isa Type ? Type : typeof(a))
        end
    end
    uses_box || return nothing
    return try _F3_CC.return_type(f, Tuple{argtypes...}) catch; nothing end
end

"""
    f3_box_value_types(code, ssa_types) -> Dict{Int,Type}

F3 L2b — the VALUE-TYPE PROPAGATION past Julia's `Box{Any}` erasure (the F3 L2 unblocker the L2
attempt surfaced; dart2wasm `node.accept1 → ValueType`). Forward fixed-point: each `%new(Core.Box)`
with CONCRETE contents T seeds box-reads of it → T; any op over already-propagated SSAs → its
computed result type (`return_type` with propagated operand types). Returns ssa_id → concrete Julia
type for box-DERIVED values (the getfield result, the `s+i` arithmetic) — these are inferred `Any`
by Julia (the dynamic `+`) but compute at a concrete width, so without this they get anyref locals
the i64 value can't fill ("expected anyref, found i64"). PURE analysis (the typed-box wiring consumes
it to type the chain). Does NOT type the box itself (that is the box-local typing). See dev/F3_LOOP.md.
"""
function f3_box_value_types(code, ssa_types; extra_box_seeds::Dict{Int,Type}=Dict{Int,Type}(), spectypes=nothing)::Dict{Int,Type}
    out = Dict{Int,Type}()
    boxT = Dict{Int,Type}(extra_box_seeds)
    for bid in find_box_news(code)
        t = box_contents_type(code, ssa_types, bid)
        t !== nothing && (boxT[bid] = t)
    end
    isempty(boxT) && return out
    changed = true
    while changed
        changed = false
        for (i, stmt) in enumerate(code)
            haskey(out, i) && continue
            # Propagate through PiNode narrowings + φ nodes (the isa-split that narrows a box read
            # to its concrete type) so an op CONSUMING the narrowed value still sees a box-derived
            # operand — else the `s+=i` add over the read keeps its anyref-from-erasure.
            if stmt isa Core.PiNode && stmt.val isa Core.SSAValue && haskey(out, stmt.val.id)
                out[i] = out[stmt.val.id]; changed = true; continue
            end
            if stmt isa Core.PhiNode
                vts = Type[]; nssa = 0
                for v in stmt.values
                    v isa Core.SSAValue || continue
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
            (stmt isa Expr && stmt.head === :call) || continue
            ft = _f3_call_result_type(stmt, code, out, boxT, ssa_types, spectypes)
            if ft isa DataType && isconcretetype(ft) && ft !== Core.Box
                out[i] = ft
                changed = true
            end
        end
    end
    return out
end

# F3 L2b CLOSURE-BODY seed (dart2wasm `Capture.type = context.struct.fields[i].type`): in a closure
# BODY there is no %new(Core.Box) to seed from — the box arrives as `getfield(#self#, boxfield)` where
# `boxfield` is a Core.Box field of the closure type `selfT`. Map each such read → the box's contents
# type (`contents_T`, recovered from the enclosing fn's L2a side-table), so the body's box-derived
# arithmetic types past Box{Any} erasure exactly like dart reads its typed context field directly.
function f3_closure_box_seeds(code, selfT, contents_T)::Dict{Int,Type}
    out = Dict{Int,Type}()
    (selfT isa DataType && isstructtype(selfT) && contents_T isa Type) || return out
    boxfields = Set{Symbol}(fieldname(selfT, i) for i in 1:fieldcount(selfT) if fieldtype(selfT, i) === Core.Box)
    isempty(boxfields) && return out
    for (i, stmt) in enumerate(code)
        (stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3) || continue
        op = stmt.args[1]
        (op isa GlobalRef && op.name === :getfield) || continue
        (stmt.args[2] isa Core.Argument && stmt.args[2].n == 1) || continue   # #self#
        fld = stmt.args[3]
        fldn = fld isa QuoteNode ? fld.value : fld
        fldn in boxfields && (out[i] = contents_T)
    end
    return out
end

"""
    populate_box_field_types!(mod, registry, code, ssa_types)

F3 L2 cross-function glue (pre-pass over an enclosing fn's typed IR). For each `%new(Core.Box)`
whose contents type is CONCRETE (`box_contents_type`), map every closure type that captures it →
the box's contents WASM type, into `registry.box_contents_types`. `register_closure_type!` then
types the captured-box field as a typed `Box{contents}` instead of anyref. Dynamic-contents boxes
(`box_contents_type` ⇒ `nothing`) get NO entry → anyref fallback (current behavior, no regression).

DORMANT until the L2 wiring consults the side-table + types box SSAs (context.jl SSA-type pass);
adding entries to a dict that nothing reads is byte-identical. See dev/F3_LOOP.md.
"""
function populate_box_field_types!(mod, registry, code, ssa_types)
    registry.box_contents_types === nothing && return registry.box_contents_types
    for box_id in find_box_news(code)
        bt = box_contents_type(code, ssa_types, box_id)
        bt === nothing && continue                       # dynamic contents → anyref fallback
        contents_wasm = get_concrete_wasm_type(bt, mod, registry)
        for clo_T in _f3_box_captors(code, box_id)
            registry.box_contents_types[clo_T] = contents_wasm
        end
    end
    return registry.box_contents_types
end
