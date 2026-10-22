# The file map, the anchors and the quarantine (dev/CHARTER.md C2): every file of src/ outside
# src/julia loads through `include_dart` from the pin table, every definition in it carries
# `@parity "<file>.dart:<line> <Symbol>"`, the dart definition it copies, and every definition in
# src/julia carries `@quarantine "<necessity>" <Julia API>`, what Julia forces and dart lacks. Each
# macro checks its definition where it is written and records it in REGISTRY; when the package has
# loaded, the totality checks walk every method and binding WasmTarget defines and refuse the load
# for one no entry covers.

# The registry's own definitions carry @quarantine like every other src/julia definition, but the
# macro is one of them and cannot expand before it exists: this block evaluates each definition, then
# registers each through the function the macro's expansion calls, so no definition goes unmarked.
let defs = quote
    """
        construction_check(::Val{definition}) -> Int

    The load-time check of the construction `definition` names, defined beside that definition; 0
    when it holds, and it throws, refusing the load, when it does not. `ConstructionLock(definition)`
    in test/parity_ratchet.jl only calls it.
    """
    @quarantine "Julia checks no construction at compile time; each asserts itself at load" Base.invokelatest function construction_check end

    """
        ConstructionViolation(definition, what)

    A construction's load-time check failed: `definition` names the construction and `what` the fault.
    """
    @quarantine "a refused load needs an exception type; dart's analyzer reports instead" Core.Exception struct ConstructionViolation <: Exception
        definition::String
        what::String
    end
    @quarantine "the refusal's text, Julia's error display" Base.showerror Base.showerror(io::IO, e::ConstructionViolation) = print(io, "WasmTarget: construction ", e.definition, " broken: ", e.what)

    """
        ParityEntry(mod, anchor, ported, names, file, first, last)

    A definition `@parity` checked: `anchor` the dart definition it copies, `ported` false for an
    `@unported` stub, `names` the bindings it defines in `mod`, and `file` lines `first` to `last`
    the span its methods sit in.
    """
    @quarantine "dart's analyzer knows each declaration's source; Julia records a method's line only" Base.Method struct ParityEntry
        mod::Module
        anchor::String
        ported::Bool
        names::Vector{Symbol}
        file::Symbol
        first::Int
        last::Int
    end

    """
        QuarantineEntry(mod, necessity, api, names, file, first, last)

    A definition `@quarantine` checked: `necessity` what Julia forces, `api` the Julia API it relies
    on (resolved when it was checked), and the rest as `ParityEntry`.
    """
    @quarantine "the Julia-only definitions' record, Rust's unsafe blocks with their SAFETY comments" Base.Method struct QuarantineEntry
        mod::Module
        necessity::String
        api::String
        names::Vector{Symbol}
        file::Symbol
        first::Int
        last::Int
    end

    """
        RegistryEntry

    A checked definition: `ParityEntry` (it copies a dart definition) or `QuarantineEntry` (Julia
    forces it). A closed sum: a `Union` of two concrete structs that subtype nothing.

    precedent(rust: enum; dart: sealed class). Julia's differs: a `Union` of concrete types.
    """
    @quarantine "a closed sum is a Union in Julia, which has no sealed classes" Core.Union const RegistryEntry = Union{ParityEntry, QuarantineEntry}

    """
        REGISTRY

    Every checked definition of every module, in load order; the totality checks read it. Filled
    when the package loads (at precompile, and saved in the package image with the module).
    """
    @quarantine "Julia keeps no declaration table to reflect on; the macros build one at load" Base.Vector const REGISTRY = RegistryEntry[]

    # the src directory, which the location rules and the include set are relative to
    @quarantine "a Julia package's source files have a path, Julia's include unit" Base.dirname const SRC = dirname(@__DIR__)

    @quarantine "the registry grows as the package loads, Julia's top-level evaluation" Base.push! _register!(e::RegistryEntry)::Nothing = (push!(REGISTRY, e); nothing)

    # whether `file` lies in the directory `dir` (both absolute)
    @quarantine "a source file's place is its path" Base.startswith _inside(file::AbstractString, dir::AbstractString)::Bool = startswith(normpath(file), joinpath(normpath(dir), ""))

    @quarantine "the macros' refusals name the line they stand on, Julia's LineNumberNode" Core.LineNumberNode _at(source::LineNumberNode)::String = string(something(source.file, :none), ":", source.line)

    # the last line a definition's expression spans: its methods' lines lie from the macro's line to it
    @quarantine "Julia's parser records lines as LineNumberNodes inside the expression" Core.LineNumberNode function _last_line(ex, line::Int)::Int
        ex isa LineNumberNode && return max(line, ex.line)
        ex isa Expr || return line
        for a in ex.args
            line = _last_line(a, line)
        end
        return line
    end

    # a function definition's call, under its `where` and return annotation; nothing for no call
    @quarantine "Julia's method signatures nest where clauses and return annotations" Base.Meta.isexpr function _call(sig)
        while Meta.isexpr(sig, :where) || Meta.isexpr(sig, :(::), 2)
            sig = sig.args[1]
        end
        return Meta.isexpr(sig, :call) ? sig : nothing
    end

    # the bindings a definition creates in its module and the Julia name the anchor's rule judges, or
    # a refusal naming its line: function (long, short, `function f end`), macro, struct, abstract and
    # primitive type, const and @enum, under @inline or @noinline
    @quarantine "Julia's definition forms, read from the parsed expression" Base.Meta.isexpr function _defines(def, source::LineNumberNode)::Tuple{Vector{Symbol},Symbol}
        refuse() = throw(ConstructionViolation("the definition forms",
            "$(_at(source)): not a definition @parity or @quarantine reads (function, macro, struct, abstract or primitive type, const, @enum)"))
        typename(t) = t isa Symbol ? t : Meta.isexpr(t, :(<:)) || Meta.isexpr(t, :curly) ? typename(t.args[1]) : refuse()
        if Meta.isexpr(def, :macrocall) && def.args[1] in (Symbol("@inline"), Symbol("@noinline"))
            return _defines(def.args[end], source)
        elseif Meta.isexpr(def, :macrocall) && def.args[1] === Symbol("@enum")
            local head = def.args[3]
            local x = Meta.isexpr(head, :(::)) ? head.args[1] : head
            local members = Symbol[]
            for a in def.args[4:end]
                for m in (Meta.isexpr(a, :block) ? a.args : (a,))
                    m isa LineNumberNode && continue
                    push!(members, m isa Symbol ? m : Meta.isexpr(m, :(=)) ? m.args[1] : refuse())
                end
            end
            return (vcat(typename(x), members), typename(x))
        elseif Meta.isexpr(def, :struct)
            local t = typename(def.args[2])
            return ([t], t)
        elseif Meta.isexpr(def, :abstract) || Meta.isexpr(def, :primitive)
            local t = typename(def.args[1])
            return ([t], t)
        elseif Meta.isexpr(def, :const) && Meta.isexpr(def.args[1], :(=))
            local lhs = def.args[1].args[1]
            local n = Meta.isexpr(lhs, :(::)) ? lhs.args[1] : lhs
            n isa Symbol || refuse()
            return ([n], n)
        elseif Meta.isexpr(def, :function, 1) && def.args[1] isa Symbol
            return ([def.args[1]], def.args[1])
        elseif Meta.isexpr(def, :macro)
            local c = _call(def.args[1])
            c === nothing && refuse()
            local n = c.args[1]::Symbol
            return ([Symbol("@", n)], n)
        elseif Meta.isexpr(def, :function) || Meta.isexpr(def, :(=))
            local c = _call(def.args[1])
            c === nothing && refuse()
            local f = c.args[1]
            f isa Symbol && return ([f], f)
            # a method of a function another module owns (Base.show): no binding here
            Meta.isexpr(f, :.) && f.args[2] isa QuoteNode && return (Symbol[], f.args[2].value)
            # a callable type's method, (c::T)(...): the type's binding is its own definition's
            Meta.isexpr(f, :(::)) && return (Symbol[], typename(f.args[end]))
            Meta.isexpr(f, :curly) && return (Symbol[], typename(f))
            refuse()
        end
        refuse()
    end

    # the Julia API a quarantined definition relies on, resolved in `mod` from a dotted name: every
    # prefix a module, the last part defined in it; anything else refuses the definition
    @quarantine "a quarantined definition names the Julia API it rests on, which must exist" Base.isdefined function _resolve_api(mod::Module, api, source::LineNumberNode)
        refuse(why) = throw(ConstructionViolation("@quarantine", "$(_at(source)): the Julia API $(repr(api)) $why"))
        Meta.isexpr(api, :., 2) && api.args[2] isa QuoteNode || refuse("is not a qualified name (Module.name)")
        local owner = api.args[1] isa Symbol ? (isdefined(mod, api.args[1]) ? getglobal(mod, api.args[1]) : refuse("does not resolve")) :
            _resolve_api(mod, api.args[1], source)
        local n = api.args[2].value
        owner isa Module && n isa Symbol && isdefined(owner, n) || refuse("does not resolve")
        return getglobal(owner, n)
    end

    # the QuarantineEntry of one definition, or a refusal at its line: the necessity stated, the API
    # resolved, the file in src/julia (a file under src/ elsewhere carries @parity)
    @quarantine "the Julia-only definitions are checked where they are written, Rust's unsafe" Base.Meta.isexpr function _quarantine_entry(mod::Module, source::LineNumberNode, necessity, api, def)::QuarantineEntry
        necessity isa String && !isempty(strip(necessity)) ||
            throw(ConstructionViolation("@quarantine", "$(_at(source)): the necessity is not a non-empty string"))
        _resolve_api(mod, api, source)
        local file = string(something(source.file, :none))
        local julia = joinpath(SRC, "julia")
        (_inside(file, SRC) || mod === @__MODULE__) && !_inside(file, julia) &&
            throw(ConstructionViolation("@quarantine", "$(_at(source)): a definition outside src/julia carries @parity, the dart definition it copies"))
        local names, _ = _defines(def, source)
        return QuarantineEntry(mod, necessity, string(api), names, Symbol(file), source.line, _last_line(def, source.line))
    end

    """
        @quarantine "<necessity>" <Module.api> <definition>

    Marks a definition of src/julia: what Julia forces that dart lacks, and the Julia API it relies
    on, a qualified name resolved when the definition loads (one that does not resolve refuses the
    load). A definition outside src/julia carries `@parity` instead.

    precedent(rust: `unsafe` with clippy's undocumented_unsafe_blocks, each block saying why). Julia's
    differs: no keyword marks Julia-only code, so the macro checks and records it when it loads.
    """
    @quarantine "Julia has no unsafe blocks; a macro marks and records each Julia-only definition" Base.var"@macroexpand" macro quarantine(necessity, api, def)
        local e = _quarantine_entry(__module__, __source__, necessity, api, def)
        return esc(Expr(:block, Expr(:macrocall, GlobalRef(Core, Symbol("@__doc__")), __source__, def),
                        Expr(:call, GlobalRef(@__MODULE__, :_register!), e), nothing))
    end
end
    local marked = Tuple{LineNumberNode,Any,Any,Any}[]
    for st in defs.args
        st isa LineNumberNode && continue
        local doc = nothing
        if Meta.isexpr(st, :macrocall) && st.args[1] == GlobalRef(Core, Symbol("@doc"))
            doc, st = st.args[3], st.args[4]
        end
        Meta.isexpr(st, :macrocall) && st.args[1] === Symbol("@quarantine") && length(st.args) == 5 ||
            error("parity.jl: the registry's block holds only @quarantine definitions")
        local source, necessity, api, def = st.args[2], st.args[3], st.args[4], st.args[5]
        Core.eval(@__MODULE__, doc === nothing ? def : Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), source, doc, def))
        push!(marked, (source, necessity, api, def))
    end
    for (source, necessity, api, def) in marked
        Core.eval(@__MODULE__, Expr(:call, :_register!, Expr(:call, :_quarantine_entry, @__MODULE__, QuoteNode(source),
                                                              necessity, QuoteNode(api), QuoteNode(def))))
    end
end

"""
    DART_FILES

The pin table: every dart file in scope at the pinned commit (dev/PARITY_MASTER.md), by its path
under the sdk's pkg/ exactly as it sits at the pin (`dart2wasm/lib/translator.dart`,
`wasm_builder/lib/src/ir/type.dart`); `include_dart` loads only these, each from its source file
(`_jl_path`), and an anchor names only these. The files left out are out of scope (dev/MARCH.md
1.A4's dev/skeleton_scope.toml gives each its reason).
"""
@quarantine "Julia's include takes any path; the pin table is the file map dart's part directives fix" Base.include const DART_FILES = (
    "dart2wasm/lib/abi.dart", "dart2wasm/lib/class_info.dart", "dart2wasm/lib/closures.dart",
    "dart2wasm/lib/code_generator.dart", "dart2wasm/lib/compile.dart",
    "dart2wasm/lib/compiler_options.dart", "dart2wasm/lib/constant_evaluator.dart",
    "dart2wasm/lib/constants.dart", "dart2wasm/lib/constructor_info.dart",
    "dart2wasm/lib/dispatch_table.dart", "dart2wasm/lib/dynamic_dispatch_table.dart",
    "dart2wasm/lib/dynamic_dispatchers.dart", "dart2wasm/lib/functions.dart",
    "dart2wasm/lib/generate_wasm.dart", "dart2wasm/lib/globals.dart",
    "dart2wasm/lib/intrinsics.dart", "dart2wasm/lib/js/runtime_blob.dart",
    "dart2wasm/lib/js/runtime_generator.dart", "dart2wasm/lib/kernel_nodes.dart",
    "dart2wasm/lib/namer.dart", "dart2wasm/lib/param_info.dart",
    "dart2wasm/lib/record_class_generator.dart", "dart2wasm/lib/records.dart",
    "dart2wasm/lib/source_map_utils.dart", "dart2wasm/lib/static_dispatch_table.dart",
    "dart2wasm/lib/symbols.dart", "dart2wasm/lib/table_based_globals.dart",
    "dart2wasm/lib/tags.dart", "dart2wasm/lib/target.dart", "dart2wasm/lib/translator.dart",
    "dart2wasm/lib/types.dart", "dart2wasm/lib/util.dart", "dart2wasm/lib/wasm_annotations.dart",
    "wasm_builder/lib/wasm_builder.dart", "wasm_builder/lib/source_map.dart",
    "wasm_builder/lib/src/builder/builder.dart", "wasm_builder/lib/src/builder/data_segment.dart",
    "wasm_builder/lib/src/builder/data_segments.dart", "wasm_builder/lib/src/builder/elements.dart",
    "wasm_builder/lib/src/builder/exports.dart", "wasm_builder/lib/src/builder/function.dart",
    "wasm_builder/lib/src/builder/functions.dart", "wasm_builder/lib/src/builder/global.dart",
    "wasm_builder/lib/src/builder/globals.dart", "wasm_builder/lib/src/builder/instructions.dart",
    "wasm_builder/lib/src/builder/memories.dart", "wasm_builder/lib/src/builder/module.dart",
    "wasm_builder/lib/src/builder/table.dart", "wasm_builder/lib/src/builder/tables.dart",
    "wasm_builder/lib/src/builder/tags.dart", "wasm_builder/lib/src/builder/types.dart",
    "wasm_builder/lib/src/builder/util.dart", "wasm_builder/lib/src/ir/data_segment.dart",
    "wasm_builder/lib/src/ir/data_segments.dart", "wasm_builder/lib/src/ir/element.dart",
    "wasm_builder/lib/src/ir/elements.dart", "wasm_builder/lib/src/ir/exports.dart",
    "wasm_builder/lib/src/ir/finalizable.dart", "wasm_builder/lib/src/ir/function.dart",
    "wasm_builder/lib/src/ir/functions.dart", "wasm_builder/lib/src/ir/global.dart",
    "wasm_builder/lib/src/ir/globals.dart", "wasm_builder/lib/src/ir/imports.dart",
    "wasm_builder/lib/src/ir/indexable.dart", "wasm_builder/lib/src/ir/instruction.dart",
    "wasm_builder/lib/src/ir/instructions.dart", "wasm_builder/lib/src/ir/ir.dart",
    "wasm_builder/lib/src/ir/memories.dart", "wasm_builder/lib/src/ir/memory.dart",
    "wasm_builder/lib/src/ir/module.dart", "wasm_builder/lib/src/ir/table.dart",
    "wasm_builder/lib/src/ir/tables.dart", "wasm_builder/lib/src/ir/tags.dart",
    "wasm_builder/lib/src/ir/type.dart", "wasm_builder/lib/src/ir/types.dart",
    "wasm_builder/lib/src/serialize/sections.dart", "wasm_builder/lib/src/serialize/serialize.dart",
    "wasm_builder/lib/src/serialize/serializer.dart",
)

"""
    INCLUDED

The dart files `include_dart` has loaded, in order; when the package has loaded they are exactly
the .jl files under src/ outside src/julia (`construction_check(::Val{:include_dart})`).
"""
@quarantine "Julia records no include set a module can reflect on; include_dart keeps it" Base.Vector const INCLUDED = String[]

# the source file of a dart file of the pin table, relative to src/: dart2wasm's lib/<f>.dart is
# <f>.jl, wasm_builder's lib/<f>.dart and lib/src/<f>.dart are wasm_builder/<f>.jl (dev/MARCH.md 1.A4)
@quarantine "a Julia package's files sit under one src/, where the sdk keeps two packages' lib/" Base.match function _jl_rel(dart::String)::String
    local m = match(r"^(?:dart2wasm/lib/|(wasm_builder/)lib/(?:src/)?)([\w/]+)\.dart$", dart)
    m === nothing && throw(ConstructionViolation("include_dart", "$dart is no path under dart2wasm/lib or wasm_builder/lib"))
    return something(m[1], "") * m[2] * ".jl"
end
@quarantine "a source file is included by its absolute path, Julia's include unit" Base.joinpath _jl_path(dart::String)::String = joinpath(SRC, _jl_rel(dart))

"""
    include_dart("<file>.dart")

Loads the port of that dart file, its path under the sdk's pkg/ (`_jl_path`): the only way a file of src/ outside src/julia
loads. The path must be in `DART_FILES` and loads once; when the package has loaded, the files it
loaded are exactly the directory's (`check_include_dart`).

precedent(dart: `part`/`part of`, a library naming each file it holds; rust: `mod`, a crate's
files reachable only through its declarations). Julia's differs: `include` takes any path, so the
file map is a table checked against the directory when the package loads.
"""
@quarantine "Julia's include loads any path; include_dart admits the pin table's files alone" Base.include function include_dart(dart::String)::Nothing
    dart in DART_FILES || throw(ConstructionViolation("include_dart", "$dart is no file of the pin table DART_FILES"))
    dart in INCLUDED && throw(ConstructionViolation("include_dart", "$dart is included twice"))
    push!(INCLUDED, dart)
    Base.include(@__MODULE__, _jl_path(dart))
    return nothing
end

"""
    check_include_dart(src, included) -> Int

The file map's check: the .jl files under `src` outside `src/julia`, the module file
`src/WasmTarget.jl` aside, are exactly the source files of the dart files `included` names.
Throws a `ConstructionViolation` naming a file loaded otherwise or a dart file with no source.
"""
@quarantine "the directory listing is the file map's other side, Julia's filesystem API" Base.Filesystem.walkdir function check_include_dart(src::String, included::Vector{String})::Int
    local listed = String[]
    for (dir, _, files) in walkdir(src), f in files
        local path = joinpath(dir, f)
        (endswith(f, ".jl") && !_inside(path, joinpath(src, "julia")) && path != joinpath(src, "WasmTarget.jl")) || continue
        push!(listed, replace(relpath(path, src), '\\' => '/'))
    end
    local loaded = String[_jl_rel(d) for d in included]
    for f in listed
        f in loaded || throw(ConstructionViolation("include_dart", "src/$f is a file include_dart did not load from the pin table"))
    end
    for (d, f) in zip(included, loaded)
        f in listed || throw(ConstructionViolation("include_dart", "$d is included but src has no $f"))
    end
    return 0
end
# the file map's assertion, run when the package loads; every directory of src/ is a dependency of
# the package image by its listing, so a file added anywhere under src/ rebuilds the image and meets
# the check, rather than loading the image built before it
@quarantine "Julia rebuilds a package image only for its include dependencies" Base.include_dependency function construction_check(::Val{:include_dart})::Int
    for (dir, _, _) in walkdir(SRC)
        include_dependency(dir; track_content = true)
    end
    return check_include_dart(SRC, INCLUDED)
end

"""
    snake(symbol) -> String

The one naming rule: a dart symbol's Julia name, camelCase to snake_case, an acronym run kept
together (`toJSON` → `to_json`, `i32Const` → `i32_const`), a leading `_` kept.
"""
@quarantine "Julia names functions in snake_case where dart uses camelCase" Base.lowercase function snake(s::AbstractString)::String
    local m = match(r"^(_*)(.*)$"s, s)
    local body = replace(m[2], r"([A-Z]+)([A-Z][a-z])" => s"\1_\2")
    body = replace(body, r"([a-z0-9])([A-Z])" => s"\1_\2")
    return m[1] * lowercase(body)
end

# a dart operator's Julia function: the operators dart declares on a class and the Base function each
# extends
@quarantine "dart's operator declarations are Base methods in Julia" Base.getindex const DART_OPERATORS = Dict{String,Symbol}(
    "==" => :(==), "[]" => :getindex, "[]=" => :setindex!, "+" => :+, "-" => :-, "unary-" => :-,
    "*" => :*, "/" => :/, "~/" => :div, "%" => :mod, "<" => :<, ">" => :>, "<=" => :<=, ">=" => :>=,
    "&" => :&, "|" => :|, "^" => :xor, "~" => :~, "<<" => :<<, ">>" => :>>, ">>>" => :>>>)

# the Julia names the rule admits for an anchor's symbol: `X` its type or unnamed constructor X (a
# top-level function or variable `f`: snake(f)); `X.m` snake(m) (a method, getter or field),
# X_snake(m) (a static or named constructor), set_snake(m)! (a setter), or the operator's Base function
@quarantine "dart and Julia name a definition by different conventions; one rule maps them" Base.Symbol function _admitted_names(symbol::AbstractString)::Vector{Symbol}
    local parts = split(symbol, '.'; limit = 2)
    length(parts) == 1 && return unique([Symbol(symbol), Symbol(snake(symbol))])
    local x, m = parts
    local out = Symbol[Symbol(snake(m)), Symbol(x, "_", snake(m)), Symbol("set_", snake(m), "!")]
    haskey(DART_OPERATORS, m) && push!(out, DART_OPERATORS[m])
    return out
end

# the stub @unported stands for: a function whose body rejects with its anchor, or a struct with no
# fields whose only constructor does
@quarantine "an unported definition must stop the compile at itself, Rust's todo!()" Base.Meta.isexpr function _unported(anchor::String, def, source::LineNumberNode)
    local reject = GlobalRef(@__MODULE__, :reject!)
    local unported = GlobalRef(@__MODULE__, :Unported)
    local refuse(why) = throw(ConstructionViolation("@unported", "$(_at(source)): $why"))
    if Meta.isexpr(def, :function, 2) || Meta.isexpr(def, :(=), 2)
        local c = _call(def.args[1])
        c === nothing && refuse("not a function definition")
        all(a -> a isa LineNumberNode, Meta.isexpr(def.args[2], :block) ? def.args[2].args : (def.args[2],)) ||
            refuse("an unported definition has no body: its body is the rejection")
        return Expr(def.head, def.args[1], Expr(:block, source, Expr(:call, reject, Expr(:call, unported, anchor), string(c))))
    elseif Meta.isexpr(def, :struct)
        local t = def.args[2]
        local x = Meta.isexpr(t, :(<:)) ? t.args[1] : t
        x isa Symbol || refuse("an unported struct has no type parameters")
        all(a -> a isa LineNumberNode, def.args[3].args) || refuse("an unported struct has no fields: its only constructor is the rejection")
        local ctor = Expr(:(=), Expr(:call, x, Expr(:..., :args)), Expr(:block, source, Expr(:call, reject, Expr(:call, unported, anchor), "$x(...)")))
        return Expr(:struct, def.args[1], t, Expr(:block, source, ctor))
    end
    refuse("@unported stands for a function or a struct")
end

# whether an expression is a call of the macro named `name` (bare or qualified)
@quarantine "a macro call names its macro bare or qualified, Julia's syntax" Base.Meta.isexpr _is_macro(ex, name::Symbol)::Bool =
    Meta.isexpr(ex, :macrocall) && (ex.args[1] === name || (Meta.isexpr(ex.args[1], :.) && ex.args[1].args[end] == QuoteNode(name)) ||
                                     (ex.args[1] isa GlobalRef && ex.args[1].name === name))

# the ParityEntry of one definition and the definition to evaluate (an @unported stub expanded), or
# a refusal at its line: the anchor's form and file, the file outside src/julia (and loaded by
# include_dart, in WasmTarget), the Julia name the rule admits
@quarantine "the dart anchors are checked where they are written, as dart's analyzer would" Base.match function _parity_entry(mod::Module, source::LineNumberNode, anchor, def)::Tuple{ParityEntry,Any}
    local refuse(why) = throw(ConstructionViolation("@parity", "$(_at(source)): $why"))
    anchor isa String || refuse("the anchor is not a string literal")
    local m = match(r"^([\w/]+\.dart):([1-9]\d*) ([A-Za-z_$][\w$]*(?:\.\S+)?)$", anchor)
    m === nothing && refuse("the anchor $(repr(anchor)) does not read \"<file>.dart:<line> <Symbol>\"")
    m[1] in DART_FILES || refuse("the anchor's file $(m[1]) is no file of the pin table DART_FILES")
    local file = string(something(source.file, :none))
    _inside(file, joinpath(SRC, "julia")) && refuse("a definition in src/julia carries @quarantine, the Julia necessity that forces it")
    (_inside(file, SRC) || mod === (@__MODULE__)) && !any(d -> _jl_path(d) == normpath(file), INCLUDED) &&
        refuse("$file is not a file include_dart loaded")
    local ported = !_is_macro(def, Symbol("@unported"))
    ported || (def = _unported(anchor, def.args[end], source))
    local names, name = _defines(def, source)
    local admitted = _admitted_names(m[3])
    name in admitted || refuse("the Julia name $name is not the rule's for $(m[3]): $(join(admitted, ", "))")
    return (ParityEntry(mod, anchor, ported, names, Symbol(file), source.line, _last_line(def, source.line)), def)
end

"""
    @parity "<file>.dart:<line> <Symbol>" <definition>

Marks a definition outside src/julia with the dart definition it copies at the pinned commit:
the file a key of `DART_FILES`, the Julia name the one rule's for the symbol (`snake`), the file
loaded by `include_dart`; any other form refuses the load at this line. `@parity "<anchor>"
@unported <definition>` stands for a definition not yet ported: its body rejects with the anchor.

precedent(rust: the deny missing_docs lint, every item documented or the crate does not build).
Julia's differs: nothing requires a definition to say where it comes from, so the macro checks it
where it is written and the totality check refuses any definition without it when the package loads.
"""
@quarantine "Julia has no lint that denies an unanchored item; a macro checks and records each" Base.var"@macroexpand" macro parity(anchor, def)
    local e, def2 = _parity_entry(__module__, __source__, anchor, def)
    return esc(Expr(:block, Expr(:macrocall, GlobalRef(Core, Symbol("@__doc__")), __source__, def2),
                    Expr(:call, GlobalRef(@__MODULE__, :_register!), e), nothing))
end

"""
    @unported <definition>

Inside `@parity` only, which expands it: a definition not yet ported, its body
`reject!(Unported(<anchor>), <signature>)` with the enclosing `@parity`'s anchor.
"""
@quarantine "a stub's anchor is its @parity's, so the stub cannot name another" Base.var"@macroexpand" macro unported(def)
    throw(ConstructionViolation("@unported", "$(_at(__source__)): @unported outside @parity, whose anchor is the stub's"))
end

# the module and its submodules
@quarantine "a module's methods are found by their module, Julia's reflection" Base.parentmodule function _within(m::Module, root::Module)::Bool
    while true
        m === root && return true
        local p = parentmodule(m)
        p === m && return false
        m = p
    end
end

# the faults of a module's definitions under one mark: in `src/julia` (`julia`, @quarantine) or
# elsewhere under `src` (@parity), each method a registry entry of that mark must span in its file,
# and every binding the module owns an entry must name; a body Julia's lowering gives no location (a
# generator's) must belong to a named definition
@quarantine "Julia's methods and bindings are reflected on, the only declaration list it keeps" Base.visit function _unmarked(mod::Module, src::String, julia::Bool)::Vector{String}
    local want = julia ? QuarantineEntry : ParityEntry
    local mark = julia ? "@quarantine" : "@parity"
    local jdir = joinpath(src, "julia")
    local entries = RegistryEntry[e for e in REGISTRY if _within(e.mod, mod)]
    local named = Set{Symbol}(n for e in entries for n in e.names)
    local out = String[]
    Base.visit(Core.methodtable) do m
        _within(m.module, mod) || return
        local file = string(m.file)
        if m.file === :none
            julia && return
            local p = match(r"^#+([^#]+)#", string(m.name))
            p !== nothing && Symbol(p[1]) in named ||
                push!(out, "$(m.module).$(m.name), a body with no location, belongs to no marked definition")
            return
        end
        if !_inside(file, src)
            julia || push!(out, "$(m.module).$(m.name) is defined at $file:$(m.line), outside src")
            return
        end
        _inside(file, jdir) == julia || return
        any(e -> e isa want && e.file === m.file && e.first <= m.line <= e.last, entries) ||
            push!(out, "$(relpath(file, src)):$(m.line) $(m.name) carries no $mark")
    end
    # an unmarked binding is this mark's fault when its methods lie on this mark's side, and both
    # marks' when it has none (a const, an abstract type, a function with no method)
    for n in names(mod; all = true)
        (startswith(string(n), '#') || n in (:eval, :include) || n === nameof(mod) || !isdefined(mod, n)) && continue
        (which(mod, n) === mod && !(n in named)) || continue
        local b = getglobal(mod, n)
        local files = b isa Function || b isa Type ? String[string(m.file) for m in methods(b) if m.module === mod] : String[]
        (isempty(files) || any(f -> _inside(f, jdir) == julia, files)) &&
            push!(out, "the binding $mod.$n carries neither @parity nor @quarantine")
    end
    return out
end

"""
    check_parity(mod, src) -> Int

The anchors' check: every method `mod` defines under `src` outside `src/julia` lies in an
`@parity` definition's lines, and every binding it owns is a marked definition's; throws a
`ConstructionViolation` listing the rest.
"""
@quarantine "the anchors' totality, by reflection when the package loads" Base.visit function check_parity(mod::Module, src::String)::Int
    local out = _unmarked(mod, src, false)
    isempty(out) || throw(ConstructionViolation("parity", join(out, "; ")))
    return 0
end
@quarantine "the anchors' assertion, run when the package loads" Base.invokelatest construction_check(::Val{:parity})::Int = check_parity(@__MODULE__, SRC)

"""
    check_quarantine(mod, src) -> Int

The quarantine's check: every method `mod` defines in `src/julia` lies in a `@quarantine`
definition's lines, and every binding it owns is a marked definition's; throws a
`ConstructionViolation` listing the rest.
"""
@quarantine "the quarantine's totality, by reflection when the package loads" Base.visit function check_quarantine(mod::Module, src::String)::Int
    local out = _unmarked(mod, src, true)
    isempty(out) || throw(ConstructionViolation("quarantine", join(out, "; ")))
    return 0
end
@quarantine "the quarantine's assertion, run when the package loads" Base.invokelatest construction_check(::Val{:quarantine})::Int = check_quarantine(@__MODULE__, SRC)
