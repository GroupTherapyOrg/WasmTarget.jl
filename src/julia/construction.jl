# The constructions' load-time checks (dev/CHARTER.md C0, L201): a construction makes the wrong
# choice inexpressible through WasmTarget's interfaces, and what Julia's compiler cannot check
# itself, its assertion, runs here when the package loads; the ratchet's ConstructionLock only calls
# it, so no lock of a construction reads text.
#
# parity(quarantine: dart's analyzer checks a sealed class's switches and a class's abstract members
# at compile time, and Rust's compiler an enum's matches; Julia checks neither, so each construction
# asserts its own at load, Rust's `const _: () = assert!(..)` beside the item)

"""
    construction_check(::Val{definition}) -> Int

The load-time check of the construction `definition` names, defined beside that definition; 0 when
it holds, and it throws, refusing the load, when it does not. `ConstructionLock(definition)` in
test/parity_ratchet.jl only calls it.
"""
function construction_check end

"""
    ConstructionViolation(definition, what)

A construction's load-time check failed: `definition` names the construction and `what` the fault.
"""
struct ConstructionViolation <: Exception
    definition::String
    what::String
end
Base.showerror(io::IO, e::ConstructionViolation) = print(io, "WasmTarget: construction ", e.definition, " broken: ", e.what)

"""
    check_closed_sum(sum, handler) -> Int

The check of a closed sum: `sum` a `Union` of concrete structs that subtype nothing (so no module
outside this line can add a kind), `handler` a function with a method for every kind and for no
other type. Throws a `ConstructionViolation` naming the first fault.
"""
function check_closed_sum(@nospecialize(sum), handler::Function)::Int
    local name = string(sum)
    sum isa Union || throw(ConstructionViolation(name, "not a Union of its kinds"))
    local kinds = Base.uniontypes(sum)
    for T in kinds
        isconcretetype(T) || throw(ConstructionViolation(name, "the kind $T is not concrete"))
        supertype(T) === Any || throw(ConstructionViolation(name, "the kind $T subtypes $(supertype(T)), an open hierarchy"))
        hasmethod(handler, Tuple{T}) || throw(ConstructionViolation(name, "the kind $T has no $(nameof(handler)) method"))
    end
    for m in methods(handler)
        local sig = Base.unwrap_unionall(m.sig)
        length(sig.parameters) == 2 && sig.parameters[2] in kinds ||
            throw(ConstructionViolation(name, "$(nameof(handler)) has a method for $(sig), no kind of the sum"))
    end
    return 0
end

# the text of a binding's docstrings in `mod`, "" when it has none
function _docstring_text(mod::Module, n::Symbol)::String
    local md = get(Base.Docs.meta(mod), Base.Docs.Binding(mod, n), nothing)
    md === nothing && return ""
    return join((join(string.(d.text)) for d in values(md.docs)), "\n")
end

"""
    check_no_open_abstract(mod) -> Int

No open hierarchy in WasmTarget passes for a closed one (dev/AUDIT.md A33S1): every abstract type
`mod` or a submodule of it defines is a registered construction (`construction_check(::Val{name})`
has a method) or mirrors a dart abstract class, its docstring carrying the
`parity(<file>.dart:<line> <Symbol>)` anchor. A closed sum is then a `Union` or an `@enum` by its
type, never by its comment. Throws a `ConstructionViolation` naming the first other abstract type.

precedent(dart: sealed class against abstract class; rust: enum against trait). Julia's differs:
its abstract types are open by language, so the refusal runs when the package loads.
"""
function check_no_open_abstract(mod::Module)::Int
    for n in names(mod; all = true)
        isdefined(mod, n) || continue
        local b = getglobal(mod, n)
        if b isa Module
            b !== mod && parentmodule(b) === mod && check_no_open_abstract(b)
        elseif b isa DataType && isabstracttype(b) && parentmodule(b) === mod && nameof(b) === n
            hasmethod(construction_check, Tuple{Val{n}}) && continue
            occursin(r"parity\([\w/]+\.dart:\d+ \w+\)", _docstring_text(mod, n)) && continue
            throw(ConstructionViolation("check_no_open_abstract",
                "$mod.$n is an abstract type that is neither a registered construction nor a dart abstract class's mirror with its parity(...) anchor"))
        end
    end
    return 0
end
