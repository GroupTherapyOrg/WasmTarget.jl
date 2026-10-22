# The constructions' load-time checks (dev/CHARTER.md C0, L201): a construction makes the wrong
# choice inexpressible through WasmTarget's interfaces, and what Julia's compiler cannot check
# itself, its assertion, runs here when the package loads; the ratchet's ConstructionLock only calls
# it (`construction_check`, src/julia/parity.jl), so no lock of a construction reads text.

"""
    check_closed_sum(sum, handler) -> Int

The check of a closed sum: `sum` a `Union` of concrete structs that subtype nothing (so no module
outside this line can add a kind), `handler` a function with a method for every kind and for no
other type. Throws a `ConstructionViolation` naming the first fault.
"""
@quarantine "dart's analyzer checks a sealed class's switches and Rust's compiler an enum's matches; Julia checks neither" Base.uniontypes function check_closed_sum(@nospecialize(sum), handler::Function)::Int
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

"""
    check_no_open_abstract(mod) -> Int

No open hierarchy in WasmTarget passes for a closed one (dev/AUDIT.md A33S1): every abstract type
`mod` or a submodule of it defines is a registered construction (`construction_check(::Val{name})`
has a method) or mirrors a dart abstract class, its definition carrying `@parity` (an entry of
`REGISTRY` naming it). A closed sum is then a `Union` or an `@enum` by its type, never by its
comment. Throws a `ConstructionViolation` naming the first other abstract type.

precedent(dart: sealed class against abstract class; rust: enum against trait). Julia's differs:
its abstract types are open by language, so the refusal runs when the package loads.
"""
@quarantine "Julia's abstract types are open by language; dart's sealed classes and Rust's enums are not" Base.isabstracttype function check_no_open_abstract(mod::Module)::Int
    for n in names(mod; all = true)
        isdefined(mod, n) || continue
        local b = getglobal(mod, n)
        local u = b isa UnionAll ? Base.unwrap_unionall(b) : b   # `abstract type T{X} end` binds a UnionAll
        if b isa Module
            b !== mod && parentmodule(b) === mod && check_no_open_abstract(b)
        elseif u isa DataType && isabstracttype(u) && parentmodule(u) === mod && nameof(u) === n
            hasmethod(construction_check, Tuple{Val{n}}) && continue
            any(e -> e isa ParityEntry && e.mod === mod && n in e.names, REGISTRY) && continue
            throw(ConstructionViolation("check_no_open_abstract",
                "$mod.$n is an abstract type that is neither a registered construction nor a dart abstract class's mirror carrying @parity"))
        end
    end
    return 0
end
# checked last, when every definition exists (src/WasmTarget.jl calls it after every include)
@quarantine "the open-hierarchy refusal's assertion, run when the package loads" Base.isabstracttype construction_check(::Val{:check_no_open_abstract})::Int = check_no_open_abstract(@__MODULE__)

"""
    check_sole_constructor(T, token, file) -> Int

The check of a typestate: a value of `T` can be made in one place alone. `T` has exactly one
constructor method, defined in `file`, whose first argument is the singleton `token`; `token` has
exactly one constructor method, defined in `file` too, so only code in that file holds the token
and makes a `T`. Throws a `ConstructionViolation` naming the first fault.

precedent(rust: typestate with a private constructor, the value made by one function of its module).
Julia's differs: it has no private constructors, so the sole constructor and the token's are checked
by reflection over their method tables when the package loads.
"""
@quarantine "Julia has no private constructors; a typestate's sole constructor is checked by reflection" Base.methods function check_sole_constructor(T::DataType, token::DataType, file::AbstractString)::Int
    local name = string(nameof(T))
    local here(m) = normpath(string(m.file)) == normpath(file)
    local ms = collect(methods(T))
    length(ms) == 1 || throw(ConstructionViolation(name, "$(length(ms)) constructor methods, where its one is made in $(basename(file)) alone"))
    here(only(ms)) || throw(ConstructionViolation(name, "its constructor is defined at $(only(ms).file):$(only(ms).line), not in $(basename(file))"))
    local sig = Base.unwrap_unionall(only(ms).sig)
    length(sig.parameters) >= 2 && sig.parameters[2] === token ||
        throw(ConstructionViolation(name, "its constructor does not take the token $(nameof(token)) first"))
    local ts = collect(methods(token))
    length(ts) == 1 && here(only(ts)) ||
        throw(ConstructionViolation(name, "the token $(nameof(token)) has $(length(ts)) constructor methods, where its one is in $(basename(file)) alone"))
    return 0
end
