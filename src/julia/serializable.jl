# dart's Serializable interface, which a ported class implements beside its superclass where Julia's
# single supertype cannot also place it under WasmBuilder.Serializable (an ir.DefinedFunction extends
# BaseFunction; an element segment is a kind of a sealed sum). Serializer.write names those classes
# in its signature (serialize/serializer.jl); this check derives the implementors from the pinned
# dart and refuses the load when write does not take one (A42S5).

# whether the dart class at line `ln` of `lines` reaches `target` through extends, implements and
# with, reading each superclass in the files of the anchor's package (`find`)
@quarantine "dart's analyzer knows a class's interfaces; Julia reads the pinned class headers" Base.any function _dart_reaches(lines::Vector{String}, ln::Int, target::String, find::Function, depth::Int = 0)::Bool
    depth > 16 && return false
    return any(_dart_supers(lines, ln)) do sup
        sup == target && return true
        local w = find(sup)
        w !== nothing && _dart_reaches(w[1], w[2], target, find, depth + 1)
    end
end

"""
    check_serializable_writable(serialize, write, serializer, sdk) -> Int

The check of Serializer.write's signature: every ported struct with a method of `serialize` whose
dart class implements Serializable (read from `sdk`, the pinned checkout) is a type `write` takes
with `serializer` first. Throws a `ConstructionViolation` naming each struct write does not take.

precedent(dart: `void write(Serializable object)`, the analyzer refusing a call with any other
type; rust: a trait bound checked at each impl). Julia's differs: an implementor that cannot subtype
Serializable is named in write's signature by hand, so the load checks the names against dart.
"""
@quarantine "Julia has no interfaces; an implementor outside Serializable's subtypes is checked against dart when the package loads" Base.hasmethod function check_serializable_writable(serialize::Function, write::Function, serializer::DataType, sdk::String)::Int
    local out = String[]
    for m in methods(serialize)
        local ps = Base.unwrap_unionall(m.sig).parameters
        length(ps) == 3 || continue
        local T = ps[3]
        T isa DataType && isconcretetype(T) || continue
        hasmethod(write, Tuple{serializer, T}) && continue
        local e = findfirst(x -> x isa ParityEntry && x.declares && any(n -> isdefined(x.mod, n) && getglobal(x.mod, n) === T, x.names), REGISTRY)
        e === nothing && continue
        local a = something(parse_anchor(REGISTRY[e].anchor))
        a.pin === :dart || continue
        local pkgdir = a.unit[1:findfirst('/', a.unit)]
        local lines = get!(() -> readlines(joinpath(sdk, a.file)), _PIN_LINES, joinpath(sdk, a.file))
        local find(name) = begin
            for d in DART_FILES
                startswith(d, pkgdir) || continue
                local p = joinpath(sdk, "pkg", d)
                local ls = get!(() -> readlines(p), _PIN_LINES, p)
                local k = _class_line(ls, name)
                k == 0 || return (ls, k)
            end
            nothing
        end
        _dart_reaches(lines, a.line, "Serializable", find) &&
            push!(out, "$T implements Serializable in dart ($(REGISTRY[e].anchor)), but Serializer.write does not take it")
    end
    empty!(_PIN_LINES)
    isempty(out) || throw(ConstructionViolation("check_serializable_writable", join(out, "; ")))
    return 0
end

# checked when every definition exists and the pinned checkout is there (src/WasmTarget.jl)
@quarantine "Serializer.write's assertion, run when the package loads" Base.Val construction_check(::Val{:check_serializable_writable})::Int =
    check_serializable_writable(WasmBuilder.serialize, Base.write, WasmBuilder.Serializer, something(_pin_sdk()))
