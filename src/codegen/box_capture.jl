# F3 — dart2wasm-aligned mutable closure capture (`Core.Box`). See dev/F3_LOOP.md.
#
# Julia reifies every MUTATED closure capture as `Core.Box{contents::Any}`. dart2wasm instead
# types the captured cell CONCRETELY (a context-struct field typed by the variable's own type —
# `closures.dart:1102-1115`). To match that we must recover the concrete type a given `Core.Box`
# holds. This file is the F3 sub-loop's home.
#
# L0 (this commit): the contents-type INFERENCE — a pure analysis over the typed IR. It is NOT yet
# wired into codegen, so output is byte-identical; later loops register a specialized
# `Box{contents}` struct (L1) and thread it through %new / setfield! / getfield / the closure's
# captured-box field (L2+). Unit-tested in test/f3_box_capture_l0.jl.

_f3_is_setfield(f) = f isa GlobalRef && f.name === :setfield! && (f.mod === Core || f.mod === Base)
_f3_is_contents(x) = (x isa QuoteNode && x.value === :contents) || x === :contents

# Does `arg` reference the box created at SSA index `box_id`? Either a direct `%box_id` or a
# `PiNode(%box_id, Core.Box)` narrowing of it (Julia reads the box through such a PiNode).
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

# Concrete Julia type of a setfield! value operand, or `nothing` if not pinnable to a concrete
# DataType (SSAValue → ssa_types; literal → typeof; Argument/Slot/GlobalRef → nothing for L0).
function _f3_value_type(v, ssa_types)::Union{Type,Nothing}
    if v isa Core.SSAValue
        (1 <= v.id <= length(ssa_types)) || return nothing
        t = ssa_types[v.id]
        t = t isa Type ? t : Core.Compiler.widenconst(t)
        return (t isa DataType && isconcretetype(t)) ? t : nothing
    elseif v isa QuoteNode
        return _f3_value_type(v.value, ssa_types)
    elseif v isa Core.Argument || v isa Core.SlotNumber || v isa GlobalRef
        return nothing
    else
        return v isa Type ? nothing : (isconcretetype(typeof(v)) ? typeof(v) : nothing)
    end
end

"""
    box_contents_type(code, ssa_types, box_id) -> Type | Nothing

Infer the concrete Julia type held by the `Core.Box` created at SSA index `box_id`
(`%box_id = %new(Core.Box)`), by scanning the typed IR `code` for `setfield!(box, :contents, v)`
and taking the value type when it is consistent across all writes. Returns `nothing` when the box
is written with more than one distinct concrete type or any write is not pinnable (genuinely
dynamic → must stay anyref-boxed, the dart2wasm dynamic-capture path).

Pure analysis; mirrors dart2wasm typing a context field by `translateTypeOfLocalVariable`.
F3 L0 — not yet wired into codegen (byte-identical). See dev/F3_LOOP.md.
"""
function box_contents_type(code, ssa_types, box_id::Int)::Union{Type,Nothing}
    found = nothing
    for stmt in code
        if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 4 &&
           _f3_is_setfield(stmt.args[1]) && _f3_refers_to_box(stmt.args[2], box_id, code) &&
           _f3_is_contents(stmt.args[3])
            vt = _f3_value_type(stmt.args[4], ssa_types)
            vt === nothing && return nothing
            if found === nothing
                found = vt
            elseif found !== vt
                return nothing
            end
        end
    end
    return found
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
