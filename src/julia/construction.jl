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
@quarantine "the open-hierarchy refusal's assertion, run when the package loads" Base.Val construction_check(::Val{:check_no_open_abstract})::Int = check_no_open_abstract(@__MODULE__)

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

# the binding a lowered operand refers to: a GlobalRef's value, an SSAValue's defining statement read the
# same way, or `getproperty(M, :x)` / `getfield(M, :x)` of a module `M` read as `M.x`; `nothing` for
# anything else (A38: lowering spells `M.x` as a getproperty call and puts each callee or type in its
# own statement)
@quarantine "lowered code refers to bindings by GlobalRef, SSAValue and module property, Julia's lowered IR" Core.GlobalRef function _binding(code::Vector{Any}, x, depth::Int=0)::Any
    depth > 32 && return nothing
    x isa Core.SSAValue && return _binding(code, code[x.id], depth + 1)
    x isa GlobalRef && return isdefined(x.mod, x.name) ? getglobal(x.mod, x.name) : nothing
    x isa Module && return x
    if x isa Expr && x.head === :call && length(x.args) == 3 && x.args[3] isa QuoteNode && x.args[3].value isa Symbol
        local f = _binding(code, x.args[1], depth + 1)
        if f === getproperty || f === getfield || f === getglobal
            local m = _binding(code, x.args[2], depth + 1)
            m isa Module && isdefined(m, x.args[3].value) && return getglobal(m, x.args[3].value)
        end
    end
    return nothing
end

# whether lowered `code` makes a `T` or reaches `token`: a statement whose binding is `token` (by
# GlobalRef, `M.x` or getfield), a call whose callee's binding is `T`, a `:new` or `:splatnew` whose
# type's binding is `T` or `token`, or a foreigncall of Julia's runtime struct constructors
# (jl_new_struct, jl_new_structv, jl_new_structt) (A36S3, A37S1, A38); naming `T` as a type makes nothing
@quarantine "a lowered body's makers are its bindings, calls, :new, :splatnew and foreigncall forms, Julia's lowered IR" Core.Expr function _code_makes(code::Vector{Any}, T::DataType, token::DataType)::Bool
    local walk(x) = if x isa Expr
        if (x.head === :new || x.head === :splatnew) && !isempty(x.args)
            local t = _binding(code, x.args[1])
            (t === T || t === token) && return true
        elseif x.head === :call && !isempty(x.args)
            _binding(code, x.args[1]) === T && return true
        elseif x.head === :foreigncall && !isempty(x.args)
            _ccall_name(x.args[1]) in (:jl_new_struct, :jl_new_structv, :jl_new_structt) && return true
        end
        any(walk, x.args)
    else
        false
    end
    for st in code
        _binding(code, st) === token && return true
        walk(st) && return true
    end
    return false
end

# a foreigncall's function name in lowered code: a quoted symbol, or the first of a (name, library) tuple
@quarantine "a foreigncall names its C function as a quoted symbol or a tuple, Julia's lowered IR" Core.QuoteNode function _ccall_name(x)::Symbol
    x isa QuoteNode && x.value isa Symbol && return x.value
    x isa Symbol && return x
    x isa Expr && x.head === :tuple && !isempty(x.args) && return _ccall_name(x.args[1])
    x isa Expr && x.head === :call && length(x.args) >= 2 && return _ccall_name(x.args[2])
    return :none
end

# whether lowered `code` escapes what a read of it can see: any operand, callee or argument alike (a
# splat lowers to Core._apply_iterate, invokelatest takes eval as an argument), whose binding is a
# function named eval, include_string or include; or a getfield, getglobal or getproperty of a module
# with a name that is no literal symbol (A37S1, A38)
@quarantine "code made at run time or a binding found by a computed name is invisible to a read of lowered IR" Core.getglobal function _code_escapes(code::Vector{Any})::Bool
    local evalish(b) = b isa Function && nameof(b) in (:eval, :include_string, :include)
    local walk(x) = if x isa Expr
        if x.head === :call && length(x.args) >= 3
            local f = _binding(code, x.args[1])
            if (f === getfield || f === getglobal || f === getproperty) && _binding(code, x.args[2]) isa Module &&
               !(x.args[3] isa QuoteNode || x.args[3] isa Symbol)
                return true
            end
        end
        any(a -> evalish(_binding(code, a)) || walk(a), x.args)
    else
        evalish(_binding(code, x))
    end
    return any(walk, code)
end

"""
    check_sole_maker(root, T, token, makers, checks, reflection) -> Int

The other half of a typestate's check (dev/AUDIT.md A36S3): no code in `root`, WasmTarget, makes a
`T` but the methods `makers` names. Every method a module of `root` defines is read in its lowered
form, and one that names `token` (a call of its constructor) or constructs `T` or `token` with
`:new`, other than `T`'s and `token`'s own constructors and the `makers`, throws a
`ConstructionViolation` naming it. `makers` holds the methods allowed to make a `T` and `checks` the
methods that assert it (the construction's own check names the token), each a `Method` matched by
identity, so a second method added to a maker's function is no maker (A37S1). Code a lowered read
cannot see is refused outright outside `reflection`, the files of WasmTarget's own reflection
(parity.jl, construction.jl): an `@generated` method, a call of eval, include_string or include, and
a module lookup by a computed name (A37S1); package extensions lie outside `root` and are no part of
the claim.

precedent(rust: a private constructor, which no code outside its module can call). Julia's differs: it
has no module privacy, so the guarantee holds for WasmTarget's own code, read when the package
loads; a caller outside the package can still reach the token, a limit of the language, not a choice.
"""
@quarantine "Julia has no module privacy; WasmTarget's own lowered code is read when the package loads" Base.uncompressed_ast function check_sole_maker(root::Module, T::DataType, token::DataType, makers::Tuple, checks::Tuple, reflection::Tuple)::Int
    local name = string(nameof(T))
    local allowed = Set{Method}(vcat(collect(methods(T)), collect(methods(token)), collect(Method, makers), collect(Method, checks)))
    local found = String[]
    local escapes = String[]
    Base.visit(Core.methodtable) do m
        (m isa Method && _within(m.module, root)) || return
        local where_ = "$(m.name) at $(m.file):$(m.line)"
        local in_reflection = any(f -> normpath(string(m.file)) == normpath(f), reflection)
        Base.hasgenerator(m) && !in_reflection && (push!(escapes, "@generated " * where_); return)
        m in allowed && return
        isdefined(m, :source) || return   # no lowered source: a builtin's, naming nothing
        local code = Base.uncompressed_ast(m).code
        _code_makes(code, T, token) && push!(found, where_)
        !in_reflection && _code_escapes(code) && push!(escapes, where_)
    end
    isempty(found) || throw(ConstructionViolation(name, "made or its token named outside its makers: $(join(found, "; "))"))
    isempty(escapes) || throw(ConstructionViolation(name, "code a lowered read cannot see (@generated, eval, include, a module lookup by a computed name): $(join(escapes, "; "))"))
    return 0
end
