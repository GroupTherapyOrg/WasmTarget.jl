# The export directives of wasm_builder's barrel files (wasm_builder.dart, builder/builder.dart,
# ir/ir.dart, serialize/serialize.dart): which names a library makes visible to the libraries that
# import it. dart2wasm imports wasm_builder.dart under the prefix `w`, so `w.` reaches exactly the
# names wasm_builder.dart exports, composed through the directives it re-exports, less the names a
# `hide` removes. Each directive is ported where dart writes it as `@dart_export`, anchored at its
# dart line; the names it shows are Julia `public` there, and the load composes the rest and refuses
# any reference from Dart2Wasm to a WasmBuilder name `w.` cannot reach.

"""
    DART_EXPORTS

Every ported export directive, in load order: `(module, julia file, target, combinator, names)`,
the target as dart writes it (relative to the directive's file), the combinator `:show`, `:hide` or
`:all` (none), and the names it shows or hides.
"""
@quarantine "Julia keeps no record of a module's re-exports; @dart_export records each directive" Base.Vector const DART_EXPORTS = Vector{Tuple{Module,String,String,Symbol,Vector{Symbol}}}()

"""
    @dart_export "<target>.dart" [show|hide] Name...

An export directive of a dart barrel file, behind its `@parity "<file>.dart:<line> export"` anchor:
`show` makes exactly the names listed visible (each a Julia `public` of the module), `hide` all of
the target's visible names but those, and no combinator all of them. The load composes the sets and
checks the directive against the pinned dart (`check_dart_exports`).

precedent(dart: `export 'f.dart' show A, B;` and `hide`, a library re-exporting another's names;
rust: `pub use m::{A, B}`). Julia's differs: `public` marks a name but a qualified access ignores it
(`WasmBuilder.IR.Catch` resolves whether or not it is public), so the load reads Dart2Wasm's code and
refuses a reference the directives do not make visible.
"""
@quarantine "Julia's public cannot re-export or hide; a macro records dart's directive and declares what it shows" Base.esc macro dart_export(target, rest...)
    local refuse(why) = throw(ConstructionViolation("@dart_export", "$(_at(__source__)): $why"))
    target isa String && endswith(target, ".dart") || refuse("the target is a \"<file>.dart\" string")
    local comb = isempty(rest) ? :all : rest[1]
    comb in (:all, :show, :hide) || refuse("the combinator is show or hide, not $comb")
    local names = Symbol[n for n in rest[2:end]]
    all(n -> n isa Symbol, rest[2:end]) || refuse("the names are bare identifiers")
    (comb === :all) == isempty(names) || refuse("show and hide list names; a plain export lists none")
    local file = string(something(__source__.file, :none))
    local rec = Expr(:call, GlobalRef(Base, :push!), GlobalRef(@__MODULE__, :DART_EXPORTS),
                     Expr(:tuple, __module__, file, target, QuoteNode(comb), QuoteNode(names)))
    # a plain export of a file with no directives of its own shows every name it declares, public
    # here; read where the pinned checkout is, as the anchors are (a name's declaration line)
    local shown = comb === :show ? _shown_bindings(__module__, names) : comb === :all ? _declared_names(__module__, file, target) : Symbol[]
    return esc(isempty(shown) ? Expr(:block, rec, nothing) : Expr(:block, Expr(:public, shown...), rec, nothing))
end

# the Julia bindings of the names a `show` lists: each name, and its hierarchy's Abstract<X> where
# the class is one another extends (dev/skeleton.jl's pair; the types exist before any directive runs)
@quarantine "a dart class another extends is two Julia types, found by their bindings" Base.parentmodule function _shown_bindings(mod::Module, names::Vector{Symbol})::Vector{Symbol}
    local out = Symbol[]
    for n in names
        push!(out, n)
        local a = Symbol("Abstract", n)
        isdefined(mod, a) && getglobal(mod, a) isa Type && parentmodule(getglobal(mod, a)) === mod && push!(out, a)
    end
    return out
end

# the Julia bindings of the names a dart file without export directives declares at top level, read
# from the registry (every definition of the target, loaded before its barrel) and the pinned line of
# each (an unnamed extension's member is anchored by its bare name but declared at column 2)
@quarantine "a file's declared names are its definitions' registry entries, read at the pin" Base.readlines function _declared_names(mod::Module, file::String, target::String)::Vector{Symbol}
    local sdk = _pin_sdk()
    sdk === nothing && return Symbol[]
    local key = findfirst(d -> normpath(_jl_path(d)) == normpath(file), collect(INCLUDED))
    key === nothing && return Symbol[]
    local tkey = _relative_key(INCLUDED[key], target)
    tkey in INCLUDED || return Symbol[]
    local lines = readlines(joinpath(sdk, "pkg", tkey))
    any(l -> startswith(l, "export '"), lines) && return Symbol[]
    local out = Symbol[]
    for e in REGISTRY
        e isa ParityEntry && e.mod === mod || continue
        local a = something(parse_anchor(e.anchor))
        a.pin === :dart || continue   # an LLVM unit's anchor names no dart file
        a.unit == tkey && !occursin('.', a.symbol) && !startswith(a.symbol, '_') && !startswith(lines[a.line], ' ') || continue
        append!(out, n for n in e.names if isdefined(mod, n))
    end
    return unique(out)
end

# the export directives of a pinned dart file: (line, target, combinator, names), each read from its
# `export` line to the `;` that closes it
@quarantine "dart's directives are read from the pinned source, which Julia does not parse" Base.match function _pin_exports(lines::Vector{String})::Vector{Tuple{Int,String,Symbol,Vector{Symbol}}}
    local out = Tuple{Int,String,Symbol,Vector{Symbol}}[]
    local i = 1
    while i <= length(lines)
        if startswith(lines[i], "export '")
            local j = i
            local text = lines[i]
            while !occursin(';', lines[j])
                j += 1
                text *= " " * lines[j]
            end
            local m = match(r"^export '([^']+)'\s*(?:(show|hide)\s+([^;]*))?;", text)
            m === nothing && throw(ConstructionViolation("check_dart_exports", "an export directive at line $i reads no target"))
            local names = m[3] === nothing ? Symbol[] : Symbol[Symbol(strip(x)) for x in split(m[3], ',') if !isempty(strip(x))]
            push!(out, (i, String(m[1]), m[2] === nothing ? :all : Symbol(m[2]), names))
            i = j
        end
        i += 1
    end
    return out
end

# a dart file key's path relative to another key's directory, normalized (`src/ir/ir.dart` from
# `wasm_builder/lib/wasm_builder.dart`)
@quarantine "a directive's target is a path relative to its file, resolved as a path" Base.Filesystem.normpath _relative_key(from::String, target::String)::String = replace(normpath(joinpath(dirname(from), target)), '\\' => '/')

"""
    check_dart_exports(sdk) -> Int

The barrel files' check: every export directive of an in-scope dart file at `sdk`'s pin whose target
is in scope is ported as `@dart_export` with its target, combinator and names, and no other
directive is; then every name a directive makes visible is Julia `public` in the module that binds
it; then no method of Dart2Wasm refers to a WasmBuilder name wasm_builder.dart does not export
(`check_wasm_builder_references`). Throws a `ConstructionViolation` naming each fault.
"""
@quarantine "a library's visible names are composed from dart's directives when the package loads" Base.ispublic function check_dart_exports(sdk::String)::Int
    local out = String[]
    local key_of = Dict{String,String}(normpath(_jl_path(d)) => d for d in INCLUDED)
    local recorded = Dict{Tuple{String,String},Tuple{Module,Symbol,Vector{Symbol}}}()
    for (m, file, target, comb, names) in DART_EXPORTS
        local key = get(key_of, normpath(file), nothing)
        key === nothing && (push!(out, "a directive in $file, no file of the pin table"); continue)
        recorded[(key, target)] = (m, comb, names)
    end
    local directives = export_directives(sdk)
    for (key, ds) in directives
        for (ln, target, comb, names) in ds
            local tkey = _relative_key(key, target)
            local r = get(recorded, (key, target), nothing)
            if !(tkey in INCLUDED)
                r === nothing || push!(out, "$key:$ln exports $target, out of scope, yet a @dart_export ports it")
            elseif r === nothing
                push!(out, "$key:$ln: `export '$target'` is not ported as @dart_export")
            elseif r[2] !== comb || sort(r[3]) != sort(names)
                push!(out, "$key:$ln: @dart_export \"$target\" reads $(r[2]) $(join(r[3], ", ")), dart's directive $comb $(join(names, ", "))")
            end
        end
    end
    for (key, target) in keys(recorded)
        any(d -> d[2] == target, get(directives, key, [])) || push!(out, "@dart_export \"$target\" in $key ports no directive of the pinned file")
    end
    isempty(out) || throw(ConstructionViolation("check_dart_exports", join(out, "; ")))
    local memo = Dict{String,Set{Tuple{String,Symbol}}}()
    local visible(key) = visible_names(sdk, key, directives, memo)
    # each visible name is public where it is bound: the bindings of its definitions
    local vis = Set{Tuple{String,Symbol}}()
    for key in keys(directives)
        union!(vis, visible(key))
    end
    for e in REGISTRY
        e isa ParityEntry || continue
        local a = something(parse_anchor(e.anchor))
        a.pin === :dart || continue   # an LLVM unit's anchor names no dart file
        (a.unit, Symbol(a.symbol)) in vis || continue
        for n in e.names
            isdefined(e.mod, n) && !Base.ispublic(e.mod, n) && push!(out, "$(join(fullname(e.mod), ".")).$n is visible by dart's directives ($(e.anchor)) but not public")
        end
    end
    isempty(out) || throw(ConstructionViolation("check_dart_exports", join(out, "; ")))
    return check_wasm_builder_references(_dart2wasm_methods(), wasm_builder_reach(visible("wasm_builder/lib/wasm_builder.dart")))
end

# the export directives of every in-scope wasm_builder file at the pin, by file key
@quarantine "dart's directives are read from the pinned files, one table per load" Base.readlines function export_directives(sdk::String)::Dict{String,Vector{Tuple{Int,String,Symbol,Vector{Symbol}}}}
    local directives = Dict{String,Vector{Tuple{Int,String,Symbol,Vector{Symbol}}}}()
    for key in INCLUDED
        startswith(key, "wasm_builder/") || continue
        local ds = _pin_exports(readlines(joinpath(sdk, "pkg", key)))
        isempty(ds) || (directives[key] = ds)
    end
    return directives
end

"""
    visible_names(sdk, key, directives = export_directives(sdk), memo = Dict()) -> Set{Tuple{String,Symbol}}

The names the dart file `key` makes visible to a library that imports it, each `(declaring key, dart
name)`: through its export directives, each target's visible names filtered by `show` or `hide`; for
a file with none, the public names it declares at top level (its definitions' anchors, read at the
pin so an unnamed extension's member, declared at column 2, is left out).
"""
@quarantine "a library's visible names compose through its directives, as dart's namespace does" Base.get! function visible_names(sdk::String, key::String, directives::Dict{String,Vector{Tuple{Int,String,Symbol,Vector{Symbol}}}} = export_directives(sdk), memo::Dict{String,Set{Tuple{String,Symbol}}} = Dict{String,Set{Tuple{String,Symbol}}}())::Set{Tuple{String,Symbol}}
    return get!(memo, key) do
        local s = Set{Tuple{String,Symbol}}()
        if haskey(directives, key)
            for (_, target, comb, names) in directives[key]
                local tkey = _relative_key(key, target)
                tkey in INCLUDED || continue
                for v in visible_names(sdk, tkey, directives, memo)
                    (comb === :all || (comb === :show) == (v[2] in names)) && push!(s, v)
                end
            end
        else
            local lines = readlines(joinpath(sdk, "pkg", key))
            for e in REGISTRY
                e isa ParityEntry || continue
                local a = something(parse_anchor(e.anchor))
                a.pin === :dart || continue   # an LLVM unit's anchor names no dart file
                a.unit == key && !occursin('.', a.symbol) && !startswith(a.symbol, '_') || continue
                startswith(lines[a.line], ' ') && continue
                push!(s, (key, Symbol(a.symbol)))
            end
        end
        s
    end
end

"""
    wasm_builder_reach(visible) -> Set{Tuple{Module,Symbol}}

What dart2wasm's `w.` reaches, from the names wasm_builder.dart makes `visible` (each `(declaring
key, dart name)`): each name's Julia bindings in its module, and every binding and method of a
definition anchored at one of its members (a static or constructor `X_m`, a member function, a
package generic `WasmBuilder.m`); of any other class, its instance members' package generics; a
private member (`X._m`) never; and the module IR itself.

The lead's ruling (2026-10-28): dart's export governs names, not members, so an instance member of a
class `w.` cannot name stays reachable through a value of it; dart2wasm calls setFunctionAt on the
ActiveFunctionSegmentBuilder that `elements.activeFunctionSegmentBuilderFor` returns, a class
builder.dart does not export.
"""
@quarantine "a dart name's Julia bindings are its definitions' registry entries and their methods' functions" Base.parentmodule function wasm_builder_reach(visible::Set{Tuple{String,Symbol}})::Set{Tuple{Module,Symbol}}
    local reach = Set{Tuple{Module,Symbol}}([(WasmBuilder, :IR)])
    for e in REGISTRY
        e isa ParityEntry || continue
        local a = something(parse_anchor(e.anchor))
        a.pin === :dart || continue   # an LLVM unit's anchor names no dart file
        local parts = split(a.symbol, '.'; limit = 2)
        length(parts) == 2 && startswith(parts[2], '_') && continue
        if !((a.unit, Symbol(parts[1])) in visible)
            # an instance member of a class `w.` cannot name is still called on its instances (dart's
            # export governs names, not members): its package generic, never its statics
            length(parts) == 2 || continue
            local member = Symbol(snake(parts[2]))
            for m in e.methods
                local f = Base.unwrap_unionall(m.sig).parameters[1]
                f isa DataType && f <: Function && isdefined(f, :instance) && nameof(f.instance) === member &&
                    push!(reach, (parentmodule(f.instance), member))
            end
            continue
        end
        foreach(n -> push!(reach, (e.mod, n)), e.names)
        # each method's function where it is bound: a package generic (WasmBuilder.m) or a constructor
        for m in e.methods
            local f = Base.unwrap_unionall(m.sig).parameters[1]
            if f isa DataType && f <: Function && isdefined(f, :instance)
                push!(reach, (parentmodule(f.instance), nameof(f.instance)))
            elseif f isa DataType && f <: Type
                local t = Base.unwrap_unionall(f.parameters[1])
                t isa DataType && push!(reach, (parentmodule(t), nameof(t)))
            end
        end
    end
    return reach
end

# every method a definition of Dart2Wasm or its submodules made
@quarantine "Dart2Wasm's methods are its definitions' registry entries" Base.Method _dart2wasm_methods()::Vector{Method} =
    Method[m for e in REGISTRY if _within(e.mod, Dart2Wasm) for m in e.methods]

# the (module, name) a lowered operand names in WasmBuilder or IR: a GlobalRef, or `getproperty(M, :x)`
# of such a module, through SSA values; nothing for anything else
@quarantine "lowered code names a binding by GlobalRef or a module's property, Julia's lowered IR" Core.GlobalRef function _wasm_builder_name(code::Vector{Any}, x, depth::Int = 0)::Union{Tuple{Module,Symbol},Nothing}
    depth > 32 && return nothing
    x isa Core.SSAValue && return _wasm_builder_name(code, code[x.id], depth + 1)
    if x isa GlobalRef
        (x.mod === WasmBuilder || x.mod === WasmBuilder.IR) && return (x.mod, x.name)
        return nothing
    end
    if x isa Expr && x.head === :call && length(x.args) == 3 && x.args[3] isa QuoteNode && x.args[3].value isa Symbol
        local f = _binding(code, x.args[1])
        if f === getproperty || f === getfield || f === getglobal
            local m = _binding(code, x.args[2])
            (m === WasmBuilder || m === WasmBuilder.IR) && return (m, x.args[3].value)
        end
    end
    return nothing
end

"""
    check_wasm_builder_references(methods, reach) -> Int

The `w.` prefix's check: no lowered statement of `methods` names a binding of WasmBuilder or IR
outside `reach` (`wasm_builder_reach`), and no signature names such a type. Throws a
`ConstructionViolation` naming each reference and the method that makes it.
"""
@quarantine "a qualified name ignores public; the reach is checked in each method's lowered code" Base.uncompressed_ast function check_wasm_builder_references(methods::Vector{Method}, reach::Set{Tuple{Module,Symbol}})::Int
    local out = String[]
    local fault(m, mod, n) = push!(out, "$(basename(string(m.file))):$(m.line) $(m.name) refers to $(join(fullname(mod), ".")).$n, which wasm_builder.dart does not export")
    for m in methods
        for p in Base.unwrap_unionall(m.sig).parameters
            local t = Base.unwrap_unionall(p)
            t isa DataType || continue
            local mod = parentmodule(t)
            (mod === WasmBuilder || mod === WasmBuilder.IR) && !((mod, nameof(t)) in reach) && fault(m, mod, nameof(t))
        end
        local ci = try Base.uncompressed_ast(m) catch; nothing end
        ci === nothing && continue
        local walk(x) = begin
            local r = _wasm_builder_name(ci.code, x)
            r !== nothing && !(r in reach) && fault(m, r...)
            x isa Expr && foreach(walk, x.args)
        end
        foreach(walk, ci.code)
    end
    isempty(out) || throw(ConstructionViolation("check_wasm_builder_references", join(unique(out), "; ")))
    return 0
end

@quarantine "the barrel files' assertion, run when the package loads where the pinned checkout exists" Base.Val construction_check(::Val{:check_dart_exports})::Int = check_dart_exports(something(_pin_sdk()))
