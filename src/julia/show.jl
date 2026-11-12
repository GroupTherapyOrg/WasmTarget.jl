# Julia's text of a MethodInstance, a type and a module, the text a rejection's site and a compiled module's names
# (a function's, a class's, a run-time type's) carry, as Base prints it at the pin (base/show.jl and
# base/methodshow.jl, Julia v1.12.7), ported so that no question about the PROGRAM's bindings is asked of Julia's
# binding table. The compiler's code runs at the judge's world, before the program's definitions (test/smoke.jl's
# W_JUDGE); Base's printing asks bindings whether a function's type is its binding's (`_isself`,
# `is_global_function`), whether a name is visible from Main (`isvisible`) and which const is an alias of a type
# (`make_typealias`), and each such read of a program binding is a read "in a world prior to its definition world"
# (Julia 1.12 warns and says it will error; a unit's own `show` methods are never run instead, at the program's world).
# Here a program binding (one of Main or a module under it: the snapshot's, a unit's) is never read: each question
# is answered from the type's structure as Julia records it, giving the text the judge's world gives today. A
# question about Julia's own modules (Core, Base and the stdlib packages, whose bindings the program cannot write)
# is asked of Julia's builtins where every module Julia loaded is defined, as Base asks it.
#
# precedent(julia: base/show.jl, the printing ported, and src/gf.c:4347 jl_new_generic_function_with_supertype, the
# structure that names a generic function's type). dart has no counterpart: its Kernel names a member by its
# declaration and never asks a binding table; Julia differs in that a type's text depends on the bindings that hold it.

# the program's modules: Main and every module under it (the snapshot's, each unit's, the judge's own); Base and Core,
# whose parent is the Main that binds them, and each stdlib package (its own root) are Julia's own
@quarantine pin"precedent(julia: base/show.jl:1334 print_fullname)" "a module's place is its parentmodule chain, the walk print_fullname makes; Main roots the program's modules" Base.parentmodule function _jt_program(m::Module)::Bool
    return m === Main || (m !== Base && m !== Core && parentmodule(m) !== m && _jt_program(parentmodule(m)))
end

# a question about Julia's own module (a binding the program cannot write), asked of Julia's builtins where every
# module Julia loaded is defined, as Base's invokelatest_gr reads a binding there
@quarantine pin"precedent(julia: base/reflection.jl:1289 invokelatest_gr)" "Julia's own modules (a stdlib the snapshot loads after the judge's world among them) are read where they are defined" Base.invokelatest _jt_julia(f, args...) =
    Base.invokelatest(f, args...)

# a generic function's type: jl_new_generic_function_with_supertype names it `#name` and sets its singleton's name to
# `name`, where every other type's singletonname is its demangled name (src/datatype.c:79 jl_demangle_typename), a
# closure's `#3` of `#3#4`: so the type of a function a global definition binds is told by its two names alone
@quarantine pin"precedent(julia: src/gf.c:4347 jl_new_generic_function_with_supertype)" "a generic function's type is named `#name` with the singleton name `name`, the structure Julia gives it where it binds it" Base.string _jt_gf_typename(tn::Core.TypeName)::Bool =
    string(tn.name) == "#" * string(tn.singletonname)

# base/show.jl:33 _isself, the function type's binding holding its instance: a generic function's type (the binding
# Julia made with it)
@quarantine pin"precedent(julia: base/show.jl:33 _isself)" "a function type is its binding's when Julia made the binding with the type, read from the type's names" Core.DataType _jt_isself(ft::DataType)::Bool = _jt_gf_typename(ft.name)

# base/show.jl:1041 is_global_function: a generic function's type, named for its binding (no `#` or `@` in the name);
# a program's function is printed as the judge's world sees it, whose const Julia 1.12 backdates there
# (PARTITION_KIND_BACKDATED_CONST), which `isconst` does not count: its type's own name
@quarantine pin"precedent(julia: base/show.jl:1041 is_global_function)" "a function type prints as typeof(f) when its binding is a const holding it, answered from the type's names and its module" Core.TypeName function _jt_is_global_function(tn::Core.TypeName, globname::Union{Symbol,Nothing})::Bool
    globname === nothing && return false
    (isconcretetype(tn.wrapper) && tn !== DataType.name && isdefined(tn, :module)) || return false
    _jt_program(tn.module) && return false
    local s = string(globname)
    return '#' ∉ s && '@' ∉ s && tn.singletonname === globname && _jt_gf_typename(tn)
end

# base/show.jl:1021 isvisible(sym, parent, Main): Main sees a name of its own, and of Julia's own modules a name Core
# or Base exports (the modules Main uses before any program runs); a program module under Main, and a stdlib the
# program loads, are not used by Main at the judge's world
@quarantine pin"precedent(julia: base/show.jl:1021 isvisible)" "a name is visible from Main when it is Main's own or one Core or Base exports, answered without a program binding" Base.isexported function _jt_visible(sym::Symbol, parent::Module)::Bool
    parent === Main && return true
    _jt_program(parent) && return false
    _jt_julia(Base.isdeprecated, parent, sym) && return false
    for m in (Base, Core)
        _jt_julia(Base.isexported, m, sym) && _jt_julia(isdefinedglobal, m, sym) &&
            _jt_julia(Base.binding_module, m, sym) === _jt_julia(Base.binding_module, parent, sym) && return true
    end
    return false
end

# base/runtime_internals.jl:146 isexported: the program exports nothing it prints; Julia's own module as Base asks
@quarantine pin"precedent(julia: base/runtime_internals.jl:146 isexported)" "a module's exports are Julia's own module's, read by the builtin; a program module's are never read" Base.isexported _jt_exported(m::Module, sym::Symbol)::Bool =
    !_jt_program(m) && _jt_julia(Base.isexported, m, sym)

# base/show.jl:1324 show(::IO, ::Module) and base/runtime_internals.jl:23 is_root_module
@quarantine pin"precedent(julia: base/show.jl:1324 show)" "a module prints by its name, or its full name below a root" Base.nameof function _jt_show_module(io::IO, m::Module)::Nothing
    if parentmodule(m) === m || m === Base.Compiler || m === Base
        Base.show_sym(io, nameof(m))
    else
        _jt_print_fullname(io, m)
    end
    return nothing
end
@quarantine pin"precedent(julia: base/show.jl:1334 print_fullname)" "a module's full name is its parentmodule chain's" Base.nameof function _jt_print_fullname(io::IO, m::Module)::Nothing
    local mp = parentmodule(m)
    if m === Main || m === Base || m === Core || mp === m
        Base.show_sym(io, nameof(m))
    else
        _jt_print_fullname(io, mp)
        print(io, '.')
        Base.show_sym(io, nameof(m))
    end
    return nothing
end

# what `show(io, x)` dispatches to for the values a type holds: a type, a type variable, a Vararg, a module; any other
# value (a type parameter's number, Symbol or tuple of them) is Base's own show of that value
@quarantine pin"precedent(julia: base/show.jl:968 show)" "a type's parts print by their kind's show, a type parameter's value by Base's" Core.TypeVar function _jt_show(io::IO, @nospecialize(x))::Nothing
    x isa Type && return _jt_show_type(io, x)
    x isa TypeVar && return _jt_show_typevar(io, x)
    x isa Core.TypeofVararg && return _jt_show_vararg(io, x)
    x isa Module && return _jt_show_module(io, x)
    show(io, x)
    return nothing
end

# base/show.jl:569 show(::IO, ::Core.TypeofBottom) and :969 _show_type
@quarantine pin"precedent(julia: base/show.jl:969 _show_type)" "a type prints as its alias, its datatype, its union or its UnionAll with its where clause" Core.UnionAll function _jt_show_type(io::IO, @nospecialize(x::Type))::Nothing
    x === Union{} && (print(io, "Union{}"); return nothing)
    if Base.print_without_params(x)
        _jt_show_type_name(io, (Base.unwrap_unionall(x)::DataType).name)
        return nothing
    elseif get(io, :compact, true)::Bool && _jt_show_typealias(io, x)
        return nothing
    elseif x isa DataType
        _jt_show_datatype(io, x)
        return nothing
    elseif x isa Union
        if get(io, :compact, true)::Bool && _jt_show_unionaliases(io, x)
            return nothing
        end
        print(io, "Union{")
        local first = true
        for t in Base.uniontypes(x)
            first || print(io, ", ")
            first = false
            _jt_show(io, t)
        end
        print(io, "}")
        return nothing
    end
    x = x::UnionAll
    local wheres = TypeVar[]
    let io = IOContext(io)
        while x isa UnionAll
            local var = x.var
            if var.name === :_ || Base.io_has_tvar_name(io, var.name, x)
                local counter = 1
                while true
                    local newname = Symbol(var.name, counter)
                    if !Base.io_has_tvar_name(io, newname, x)
                        var = TypeVar(newname, var.lb, var.ub)
                        x = x{var}
                        break
                    end
                    counter += 1
                end
            else
                x = x.body
            end
            push!(wheres, var)
            io = IOContext(io, :unionall_env => var)
        end
        if x isa DataType
            _jt_show_datatype(io, x, wheres)
        else
            _jt_show(io, x)
        end
    end
    _jt_show_wheres(io, wheres)
    return nothing
end

# base/show.jl:1071 show_type_name; check_world_bounded's `@world(...)` (a type whose binding was replaced) is a
# binding's history, which a program's type, defined once, does not have
@quarantine pin"precedent(julia: base/show.jl:1071 show_type_name)" "a type's name prints with its module unless Main sees it, a function's type as typeof(f)" Core.TypeName function _jt_show_type_name(io::IO, tn::Core.TypeName)::Nothing
    tn === UnionAll.name && (print(io, "UnionAll"); return nothing)
    local globname = tn.singletonname
    local globfunc = _jt_is_global_function(tn, globname)
    local sym = (globfunc ? globname : tn.name)::Symbol
    globfunc && print(io, "typeof(")
    local quo = false
    if !(get(io, :compact, false)::Bool)
        local from = get(io, :module, Main)
        if isdefined(tn, :module) && (from === nothing || !(from === Main && _jt_visible(sym, tn.module)))
            _jt_show_module(io, tn.module)
            print(io, ".")
            if globfunc && !Base.is_id_start_char(first(string(sym)))
                print(io, ':')
                if sym in Base.quoted_syms
                    print(io, '(')
                    quo = true
                end
            end
        end
    end
    Base.show_sym(io, sym)
    quo && print(io, ")")
    globfunc && print(io, ")")
    return nothing
end

# base/show.jl:1126 show_datatype (a keyword-argument NamedTuple prints as @Kwargs only in a backtrace, never here)
@quarantine pin"precedent(julia: base/show.jl:1126 show_datatype)" "a datatype prints as its tuple, NTuple or NamedTuple form, or its name and parameters" Core.DataType function _jt_show_datatype(io::IO, x::DataType, wheres::Vector{TypeVar} = TypeVar[])::Nothing
    local parameters = x.parameters::Core.SimpleVector
    local n = length(parameters)
    if x.name === Tuple.name
        n == 0 && (print(io, "Tuple{}"); return nothing)
        local max_n = 3
        local taillen = 1
        local pn = parameters[n]
        local fulln = n
        local vakind = :none
        local vaN = 0
        if pn isa Core.TypeofVararg
            if isdefined(pn, :N)
                vaN = pn.N
                if vaN isa Int
                    taillen = vaN
                    fulln += taillen - 1
                    vakind = :fixed
                else
                    vakind = :bound
                end
            else
                vakind = :unbound
            end
            pn = Base.unwrapva(pn)
        end
        if !(pn isa TypeVar || pn isa Type)
            taillen = 0
        elseif vakind === :none || vakind === :fixed
            for i in (n-1):-1:1
                if parameters[i] === pn
                    taillen += 1
                else
                    break
                end
            end
        end
        if (vakind == :bound && n == 1 == taillen) || (vakind === :fixed && taillen == fulln > max_n) ||
           (vakind === :none && taillen == fulln > max_n)
            print(io, "NTuple{")
            vakind === :bound ? _jt_show(io, vaN) : print(io, fulln)
            print(io, ", ")
            _jt_show(io, pn)
            print(io, "}")
        else
            print(io, "Tuple{")
            local headlen = (taillen > max_n ? fulln - taillen : fulln)
            for i = 1:headlen
                i > 1 && print(io, ", ")
                _jt_show(io, vakind === :fixed && i >= n ? pn : parameters[i])
            end
            if headlen < fulln
                headlen > 0 && print(io, ", ")
                print(io, "Vararg{")
                _jt_show(io, pn)
                print(io, ", ", fulln - headlen, "}")
            end
            print(io, "}")
        end
        return nothing
    elseif x.name === Base.typename(NamedTuple)
        local syms, types = parameters
        if syms isa Tuple && types isa DataType
            print(io, "@NamedTuple{")
            local first = true
            for i in eachindex(syms)
                first || print(io, ", ")
                Base.show_sym(io, syms[i])
                local typ = types.parameters[i]
                if typ !== Any
                    print(io, "::")
                    _jt_show(io, typ)
                end
                first = false
            end
            print(io, "}")
            return nothing
        end
    end
    _jt_show_type_name(io, x.name)
    _jt_show_typeparams(io, parameters, (Base.unwrap_unionall(x.name.wrapper)::DataType).parameters, wheres)
    return nothing
end

# base/show.jl:689 show_typeparams
@quarantine pin"precedent(julia: base/show.jl:689 show_typeparams)" "a type's parameters print in braces, a where-bound variable elided where Julia elides it" Core.SimpleVector function _jt_show_typeparams(io::IO, env::Core.SimpleVector, orig::Core.SimpleVector, wheres::Vector)::Nothing
    local n = length(env)
    local elide = length(wheres)
    local egal_var(p::TypeVar, @nospecialize o) = o isa TypeVar &&
        ccall(:jl_types_egal, Cint, (Any, Any), p.ub, o.ub) != 0 && ccall(:jl_types_egal, Cint, (Any, Any), p.lb, o.lb) != 0
    for i = n:-1:1
        local p = env[i]
        if p isa TypeVar
            if i == n && egal_var(p, orig[i]) && Base.show_can_elide(p, wheres, elide, env, i)
                n -= 1
                elide -= 1
            elseif p.lb === Union{} && Base.isgensym(p.name) && Base.show_can_elide(p, wheres, elide, env, i)
                elide -= 1
            elseif p.ub === Any && Base.isgensym(p.name) && Base.show_can_elide(p, wheres, elide, env, i)
                elide -= 1
            end
        end
    end
    if n > 0
        print(io, "{")
        for i = 1:n
            local p = env[i]
            if p isa TypeVar
                if p.lb === Union{} && something(findfirst(@nospecialize(w) -> w === p, wheres), 0) > elide
                    print(io, "<:")
                    _jt_show(io, p.ub)
                elseif p.ub === Any && something(findfirst(@nospecialize(w) -> w === p, wheres), 0) > elide
                    print(io, ">:")
                    _jt_show(io, p.lb)
                else
                    _jt_show(io, p)
                end
            else
                _jt_show(io, p)
            end
            i < n && print(io, ", ")
        end
        print(io, "}")
    end
    resize!(wheres, elide)
    return nothing
end

# base/show.jl:615 make_typealias over Julia's own modules: an alias is a const of a module the type names, a type
# the value is exactly; a program module's consts are never read (the judge's world holds none of them as const)
@quarantine pin"precedent(julia: base/show.jl:615 make_typealias)" "a type prints as the one alias of it a module it names holds, Julia's own modules read where defined" Base.unsorted_names function _jt_make_typealias(@nospecialize(x::Type))::Union{Nothing,Tuple{GlobalRef,Core.SimpleVector,Any}}
    Any === x && return nothing
    x <: Tuple && return nothing
    local mods = Base.modulesof!(Set{Module}(), x)
    replace!(mods, Core => Base)
    local aliases = Tuple{GlobalRef,Core.SimpleVector,Any}[]
    local xenv = UnionAll[]
    for p in Base.uniontypes(Base.unwrap_unionall(x))
        p isa UnionAll && push!(xenv, p)
    end
    x isa UnionAll && push!(xenv, x)
    for mod in mods
        _jt_program(mod) && continue
        for name in _jt_julia(Base.unsorted_names, mod)
            if _jt_julia(isdefined, mod, name) && !_jt_julia(Base.isdeprecated, mod, name) && _jt_julia(isconst, mod, name)
                local alias = _jt_julia(getfield, mod, name)
                if alias isa Type && !Base.has_free_typevars(alias) && !Base.print_without_params(alias) && x <: alias
                    local env
                    if alias isa UnionAll
                        local ti
                        (ti, env) = ccall(:jl_type_intersection_with_env, Any, (Any, Any), x, alias)::Core.SimpleVector
                        env = env::Core.SimpleVector
                        local applied = try
                                alias{env...}
                            catch ex
                                ex isa TypeError || rethrow()
                                continue
                            end
                        for p in xenv
                            applied = Base.rewrap_unionall(applied, p)
                        end
                        Base.has_free_typevars(applied) && continue
                        applied === x || continue
                    elseif alias === x
                        env = Core.svec()
                    else
                        continue
                    end
                    push!(aliases, (GlobalRef(mod, name), env, alias))
                end
            end
        end
    end
    length(aliases) == 1 && return aliases[1]
    return nothing
end

# base/show.jl:806 show_typealias(io, x)
@quarantine pin"precedent(julia: base/show.jl:806 show_typealias)" "a type with one alias prints as the alias, its parameters and its where clause" Base.makeproper function _jt_show_typealias(io::IO, @nospecialize(x::Type))::Bool
    local properx = Base.makeproper(io, x)
    local alias = _jt_make_typealias(properx)
    alias === nothing && return false
    local wheres = Base.make_wheres(io, alias[2], x)
    _jt_show_typealias(io, alias[1], x, alias[2], wheres, alias[3])
    _jt_show_wheres(io, wheres)
    return true
end
# base/show.jl:735 show_typealias(io, name, x, env, wheres): the alias's value is the one the scan read, never read again
@quarantine pin"precedent(julia: base/show.jl:735 show_typealias)" "an alias prints with its module unless Main sees it, then its parameters" Core.GlobalRef function _jt_show_typealias(io::IO, name::GlobalRef, @nospecialize(x::Type), env::Core.SimpleVector, wheres::Vector, @nospecialize(orig))::Nothing
    if !(get(io, :compact, false)::Bool)
        local from = get(io, :module, Main)
        if from === nothing || !(from === Main && _jt_visible(name.name, name.mod))
            _jt_show_module(io, name.mod)
            print(io, ".")
        end
    end
    print(io, name.name)
    isempty(env) && return nothing
    io = IOContext(io)
    for p in wheres
        io = IOContext(io, :unionall_env => p)
    end
    local vars = TypeVar[]
    while orig isa UnionAll
        push!(vars, orig.var)
        orig = orig.body
    end
    _jt_show_typeparams(io, env, Core.svec(vars...), wheres)
    return nothing
end

# base/show.jl:792 show_wheres
@quarantine pin"precedent(julia: base/show.jl:792 show_wheres)" "a type's free variables print as its where clause" Core.TypeVar function _jt_show_wheres(io::IO, wheres::Vector{TypeVar})::Nothing
    isempty(wheres) && return nothing
    io = IOContext(io)
    local n = length(wheres)
    for i = 1:n
        local p = wheres[i]
        print(io, n == 1 ? " where " : i == 1 ? " where {" : ", ")
        _jt_show(io, p)
        io = IOContext(io, :unionall_env => p)
    end
    n > 1 && print(io, "}")
    return nothing
end

# base/show.jl:816 make_typealiases over Julia's own modules alone (as _jt_make_typealias)
@quarantine pin"precedent(julia: base/show.jl:816 make_typealiases)" "a union prints by the aliases that cover its members, Julia's own modules read where defined" Base.unsorted_names function _jt_make_typealiases(@nospecialize(x::Type))::Tuple{Vector{Core.SimpleVector},Any}
    local aliases = Core.SimpleVector[]
    Any === x && return aliases, Union{}
    x <: Tuple && return aliases, Union{}
    local mods = Base.modulesof!(Set{Module}(), x)
    replace!(mods, Core => Base)
    local xenv = UnionAll[]
    local each = Any[]
    for p in Base.uniontypes(Base.unwrap_unionall(x))
        p isa UnionAll && push!(xenv, p)
        push!(each, Base.rewrap_unionall(p, x))
    end
    x isa UnionAll && push!(xenv, x)
    for mod in mods
        _jt_program(mod) && continue
        for name in _jt_julia(Base.unsorted_names, mod)
            if _jt_julia(isdefined, mod, name) && !_jt_julia(Base.isdeprecated, mod, name) && _jt_julia(isconst, mod, name)
                local alias = _jt_julia(getfield, mod, name)
                if alias isa Type && !Base.has_free_typevars(alias) && !Base.print_without_params(alias) && !(alias <: Tuple)
                    local (ti, env) = ccall(:jl_type_intersection_with_env, Any, (Any, Any), x, alias)::Core.SimpleVector
                    ti === Union{} && continue
                    local mod2 = Base.modulesof!(Set{Module}(), alias)
                    mod in mod2 || (mod === Base && Core in mod2) || continue
                    env = env::Core.SimpleVector
                    local applied = alias
                    if !isempty(env)
                        applied = try
                                alias{env...}
                            catch ex
                                ex isa TypeError || rethrow()
                                continue
                            end
                    end
                    local ul = Base.unionlen(applied)
                    for p in xenv
                        applied = Base.rewrap_unionall(applied, p)
                    end
                    Base.has_free_typevars(applied) && continue
                    applied <: x || continue
                    Base.print_without_params(x) && (env = Core.svec())
                    for typ in each
                        if typ <: applied
                            push!(aliases, Core.svec(GlobalRef(mod, name), env, applied, (ul, -length(env)), alias))
                            break
                        end
                    end
                end
            end
        end
    end
    isempty(aliases) && return aliases, Union{}
    sort!(aliases, by = x -> x[4]::Tuple{Int,Int}, rev = true)
    local applied = Union{}
    local applied1 = Union{}
    local keep = Core.SimpleVector[]
    local prev = (0, 0)
    for alias in aliases
        local alias4 = alias[4]::Tuple{Int,Int}
        if alias4[1] < 2
            if !(alias[3] <: applied)
                applied1 = Union{applied1, alias[3]}
                push!(keep, alias)
            end
        elseif alias4 == prev || !(alias[3] <: applied)
            applied = applied1 = Union{applied1, alias[3]}
            push!(keep, alias)
            prev = alias4
        end
    end
    return keep, applied1
end

# base/show.jl:897 show_unionaliases
@quarantine pin"precedent(julia: base/show.jl:897 show_unionaliases)" "a union prints its members no alias covers, then the aliases" Base.uniontypes function _jt_show_unionaliases(io::IO, x::Union)::Bool
    local properx = Base.makeproper(io, x)
    local aliases, applied = _jt_make_typealiases(properx)
    isempty(aliases) && return false
    local first = true
    local tvar = false
    for typ in Base.uniontypes(x)
        if isa(typ, TypeVar)
            tvar = true
            continue
        elseif Base.rewrap_unionall(typ, properx) <: applied
            continue
        end
        print(io, first ? "Union{" : ", ")
        first = false
        _jt_show(io, typ)
    end
    if first && !tvar && length(aliases) == 1
        local alias = aliases[1]
        local env = alias[2]::Core.SimpleVector
        local wheres = Base.make_wheres(io, env, x)
        _jt_show_typealias(io, alias[1], x, env, wheres, alias[5])
        _jt_show_wheres(io, wheres)
    else
        for alias in aliases
            print(io, first ? "Union{" : ", ")
            first = false
            local env = alias[2]::Core.SimpleVector
            local wheres = Base.make_wheres(io, env, x)
            _jt_show_typealias(io, alias[1], x, env, wheres, alias[5])
            _jt_show_wheres(io, wheres)
        end
        if tvar
            for typ in Base.uniontypes(x)
                if isa(typ, TypeVar)
                    print(io, ", ")
                    _jt_show(io, typ)
                end
            end
        end
        print(io, "}")
    end
    return true
end

# base/show.jl:2798 show(::IO, ::TypeVar)
@quarantine pin"precedent(julia: base/show.jl:2798 show)" "a type variable prints with the bounds its context does not already print" Core.TypeVar function _jt_show_typevar(io::IO, tv::TypeVar)::Nothing
    local in_env = (:unionall_env => tv) in io
    local show_bound(io::IO, @nospecialize(b)) = begin
        local parens = isa(b, UnionAll) && !Base.print_without_params(b)
        parens && print(io, "(")
        _jt_show(io, b)
        parens && print(io, ")")
    end
    local lb, ub = tv.lb, tv.ub
    if !in_env && lb !== Union{}
        if ub === Any
            Base.show_sym(io, tv.name)
            print(io, ">:")
            show_bound(io, lb)
        else
            show_bound(io, lb)
            print(io, "<:")
            Base.show_sym(io, tv.name)
        end
    else
        Base.show_sym(io, tv.name)
    end
    if !in_env && ub !== Any
        print(io, "<:")
        show_bound(io, ub)
    end
    return nothing
end

# base/show.jl:2832 show(::IO, ::Core.TypeofVararg)
@quarantine pin"precedent(julia: base/show.jl:2832 show)" "a Vararg prints with its element type and count" Core.TypeofVararg function _jt_show_vararg(io::IO, vm::Core.TypeofVararg)::Nothing
    print(io, "Vararg")
    if isdefined(vm, :T)
        print(io, "{")
        _jt_show(io, vm.T)
        if isdefined(vm, :N)
            print(io, ", ")
            _jt_show(io, vm.N)
        end
        print(io, "}")
    end
    return nothing
end

# base/show.jl:2552 show_signature_function, qualified (show_mi's), no html or demangling
@quarantine pin"precedent(julia: base/show.jl:2552 show_signature_function)" "a call's function prints as its name, qualified when its module does not export it, a type as itself, any other as (::its type)" Base.isType function _jt_show_signature_function(io::IO, @nospecialize(ft))::Nothing
    local uw = Base.unwrap_unionall(ft)
    if ft <: Function && isa(uw, DataType) && isempty(uw.parameters) && _jt_isself(uw)
        local uwmod = parentmodule(uw)
        if !_jt_exported(uwmod, uw.name.singletonname) && uwmod !== Main
            _jt_show_module(io, uwmod)
            print(io, '.')
        end
        Base.show_sym(io, uw.name.singletonname)
    elseif Base.isType(ft) && (f = ft.parameters[1]; !isa(f, TypeVar))
        local uwf = Base.unwrap_unionall(f)
        local parens = isa(f, UnionAll) && !(isa(uwf, DataType) && f === uwf.name.wrapper)
        parens && print(io, "(")
        _jt_show(io, f)
        parens && print(io, ")")
    else
        print(io, "(::")
        _jt_show(io, ft)
        print(io, ")")
    end
    return nothing
end

# base/show.jl:2585 show_tuple_as_call (qualified; no argument names or keywords) and base/methodshow.jl:103
# show_method_params, the where clause of the signature's variables
@quarantine pin"precedent(julia: base/show.jl:2585 show_tuple_as_call)" "a signature prints as a call of its function on (::argument type, ...) with its where clause" Base.IOContext function _jt_show_tuple_as_call(out::IO, name::Symbol, @nospecialize(sig::Type))::Nothing
    sig === Tuple && (print(out, name, "(...)"); return nothing)
    local tv = Any[]
    local buf = IOBuffer()
    local io = IOContext(buf, out)
    local env_io = io
    while isa(sig, UnionAll)
        push!(tv, sig.var)
        env_io = IOContext(env_io, :unionall_env => sig.var)
        sig = sig.body
    end
    local ps = (sig::DataType).parameters
    _jt_show_signature_function(env_io, ps[1])
    print(io, "(")
    for i = 2:length(ps)
        i > 2 && print(io, ", ")
        print(io, "::")
        print(io, sprint(_jt_show, ps[i]; context = env_io))
    end
    print(io, ")")
    if !isempty(tv)
        print(io, " where ")
        if length(tv) == 1
            _jt_show(io, tv[1])
        else
            print(io, "{")
            for i = 1:length(tv)
                i > 1 && print(io, ", ")
                _jt_show(io, tv[i])
                io = IOContext(io, :unionall_env => tv[i])
            end
            print(io, "}")
        end
    end
    print(out, String(take!(buf)))
    return nothing
end

"""
    julia_text(x) -> String

`x`'s text as Julia prints it (`string(x)`) for a MethodInstance (base/show.jl:1380 show_mi: "MethodInstance for "
and its call), a type, a type variable, a Vararg or a module, built with no read of a program binding (this file's
header): the one text a rejection's site, a function's name, a class's struct name and a run-time type's name carry.
Any other value is Base's `string`, which reads no binding.
"""
@quarantine pin"precedent(julia: base/show.jl:1380 show_mi)" "a MethodInstance's text is \"MethodInstance for \" and its signature's call; a type's its show" Core.MethodInstance function julia_text(@nospecialize(x))::String
    if x isa Core.MethodInstance
        local def = x.def
        def isa Method || reject!(Internal("src/julia/show.jl julia_text: a MethodInstance of a $(typeof(def)), no method's"), "julia_text")
        isdefined(def, :generator) && x === def.generator &&
            reject!(Internal("src/julia/show.jl julia_text: a method's generator, which no closed world holds"), "julia_text")
        local io = IOBuffer()
        print(io, "MethodInstance for ")
        _jt_show_tuple_as_call(io, def.name, x.specTypes)
        return String(take!(io))
    end
    x isa Union{Type,TypeVar,Core.TypeofVararg,Module} && return sprint(_jt_show, x)
    return string(x)
end
