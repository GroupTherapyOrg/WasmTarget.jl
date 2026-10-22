# The file map, the anchors and the quarantine (dev/CHARTER.md C2): every file of src/ outside
# src/julia loads through `include_dart` from the pin table, every definition in it carries
# `@parity "<file>.dart:<line> <Symbol>"`, the dart definition it copies, and every definition in
# src/julia carries `@quarantine "<necessity>" <Julia API>`, what Julia forces and dart lacks, the API
# one its code references. Each macro checks its definition where it is written and records it in
# REGISTRY with the world its evaluation spans; when the package has loaded, every method WasmTarget
# defines is matched to the definition whose evaluation made it, and every binding to the definition
# naming it, and the load refuses one no entry covers.

# The registry's own definitions carry @quarantine like every other src/julia definition, but the
# macro is one of them and cannot expand before it exists: this block evaluates each definition,
# noting the worlds it spans, then registers each through the functions the macro's expansion calls,
# so no definition goes unmarked.
let defs = quote
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
        ParityEntry(mod, anchor, ported, declares, names, file, first, last, worlds, pid, methods)

    A definition `@parity` checked: `anchor` the dart definition it copies, `ported` false for an
    `@unported` stub, `declares` true for a type declaration (a struct, an abstract or primitive
    type, an enum or a closed sum: the class itself, never one of its constructors or members),
    `names` the bindings it defines in `mod`, `file` lines `first` to `last` its
    text, `worlds` the world ages its evaluation spanned in the process `pid`, and `methods` the
    methods that evaluation made, matched when the package has loaded (`_attribute!`).
    """
    @quarantine "dart's analyzer knows each declaration's members; Julia knows a method's world" Base.Method struct ParityEntry
        mod::Module
        anchor::String
        ported::Bool
        declares::Bool
        names::Vector{Symbol}
        file::Symbol
        first::Int
        last::Int
        worlds::UnitRange{UInt}
        pid::Int32
        methods::Vector{Method}
    end

    """
        QuarantineEntry(mod, necessity, api, names, file, first, last, worlds, pid, methods)

    A definition `@quarantine` checked: `necessity` what Julia forces, `api` the Julia API it relies
    on (resolved, and referenced by the definition, where it was checked), and the rest as
    `ParityEntry`.
    """
    @quarantine "the Julia-only definitions' record, Rust's unsafe blocks with their SAFETY comments" Base.Method struct QuarantineEntry
        mod::Module
        necessity::String
        api::String
        names::Vector{Symbol}
        file::Symbol
        first::Int
        last::Int
        worlds::UnitRange{UInt}
        pid::Int32
        methods::Vector{Method}
    end

    @quarantine "the macros' refusals name the line they stand on, Julia's LineNumberNode" Core.LineNumberNode _at(source::LineNumberNode)::String = string(something(source.file, :none), ":", source.line)

    """
        CLOSED_SUMS

    Every `@closed` sum, by its module and name, in load order; `check_closed` reads it.
    """
    @quarantine "Julia keeps no list of the Unions a module means as closed; @closed builds it" Base.Vector const CLOSED_SUMS = Vector{Tuple{Module,Symbol}}()

    # the name of the sum `@closed` marks, or a refusal at its line: `const X = Union{K1, K2, ...}`,
    # two kinds or more, each a concrete type defined above it that subtypes nothing, so no other
    # module can add a kind
    @quarantine "a closed sum's kinds are checked where it is written; Julia checks no sealed hierarchy" Base.supertype function _closed_sum(mod::Module, def, source::LineNumberNode)::Symbol
        refuse(why) = throw(ConstructionViolation("@closed", "$(_at(source)): $why"))
        Meta.isexpr(def, :const) && Meta.isexpr(def.args[1], :(=)) && def.args[1].args[1] isa Symbol ||
            refuse("@closed marks a `const X = Union{...}`")
        local rhs = def.args[1].args[2]
        Meta.isexpr(rhs, :curly) && rhs.args[1] === :Union && length(rhs.args) >= 3 ||
            refuse("a closed sum is a Union of two kinds or more")
        for k in rhs.args[2:end]
            k isa Symbol && isdefined(mod, k) || refuse("the kind $k is not a type defined above the sum")
            # a sealed class's sealed subclass: a closed sum whose kinds are this sum's too
            (mod, k) in CLOSED_SUMS && continue
            local T = getglobal(mod, k)
            T isa DataType && isconcretetype(T) || refuse("the kind $k is not a concrete type")
            supertype(T) === Any || refuse("the kind $k subtypes $(supertype(T)), an open hierarchy")
        end
        return def.args[1].args[1]
    end

    """
        @closed(const X = Union{K1, K2, ...})

    Declares a closed sum: its kinds concrete structs that subtype nothing, so no module adds a kind
    without editing this line; every `Union` binding WasmTarget defines carries it, and a match over
    it is `@exhaustive`.

    precedent(rust: enum; dart: sealed class, its subclasses in its own library). Julia's differs: a
    `Union` of concrete types is closed by its type, but Julia marks no Union as a sum, so the macro
    checks the kinds where it is written and the load refuses a Union binding without it.
    """
    @quarantine "Julia has no sealed classes or enums of structs; a macro marks a Union as a closed sum" Base.esc macro closed(def)
        local n = _closed_sum(__module__, def, __source__)
        return esc(Expr(:block, Expr(:macrocall, GlobalRef(Core, Symbol("@__doc__")), __source__, def),
                        Expr(:call, GlobalRef(Base, :push!), GlobalRef(@__MODULE__, :CLOSED_SUMS), Expr(:tuple, __module__, QuoteNode(n))), nothing))
    end

    """
        RegistryEntry

    A checked definition: `ParityEntry` (it copies a dart definition) or `QuarantineEntry` (Julia
    forces it). A closed sum: a `Union` of two concrete structs that subtype nothing.

    precedent(rust: enum; dart: sealed class). Julia's differs: a `Union` of concrete types.
    """
    @quarantine "a closed sum is a Union in Julia, which has no sealed classes" Core.Union @closed const RegistryEntry = Union{ParityEntry, QuarantineEntry}

    """
        REGISTRY

    Every checked definition of every module, in load order; the totality checks read it. Filled
    when the package loads (at precompile, and saved in the package image with the module).
    """
    @quarantine "Julia keeps no declaration table to reflect on; the macros build one at load" Base.Vector const REGISTRY = Vector{RegistryEntry}()

    # the worlds at which the definitions being evaluated began, innermost last (a module's
    # definitions are evaluated inside its own)
    @quarantine "Julia numbers each new method by a world age, which brackets a definition's evaluation" Base.Vector const _WORLDS = Vector{UInt}()

    # the src directory, which the location rules and the include set are relative to
    @quarantine "a Julia package's source files have a path, Julia's include unit" Base.dirname const SRC = dirname(@__DIR__)

    # notes the world a definition's evaluation begins at
    @quarantine "a definition's evaluation begins at the world it reads" Base.get_world_counter _mark!()::Nothing = (push!(_WORLDS, Base.get_world_counter()); nothing)

    # records a checked definition with the worlds its evaluation spanned, after `w0` up to `w1`, in
    # this process
    @quarantine "the registry grows as the package loads, each entry stamped with its worlds" Base.getpid function _register_range!(e::RegistryEntry, w0::UInt, w1::UInt)::Nothing
        local T = typeof(e)
        local fields = Any[getfield(e, i) for i in 1:fieldcount(T)-3]
        push!(REGISTRY, T(fields..., (w0 + 1):w1, Int32(getpid()), Method[]))
        return nothing
    end

    # records a checked definition whose evaluation began at the last _mark! and ends now
    @quarantine "the registry grows as the package loads, Julia's top-level evaluation" Base.get_world_counter _register!(e::RegistryEntry)::Nothing = _register_range!(e, pop!(_WORLDS), Base.get_world_counter())

    # whether `file` lies in the directory `dir` (both absolute)
    @quarantine "a source file's place is its path" Base.startswith _inside(file::AbstractString, dir::AbstractString)::Bool = startswith(normpath(file), joinpath(normpath(dir), ""))

    # the module and its submodules
    @quarantine "a module's methods are found by their module, Julia's reflection" Base.parentmodule function _within(m::Module, root::Module)::Bool
        while true
            m === root && return true
            local p = parentmodule(m)
            p === m && return false
            m = p
        end
    end

    # the last line a definition's expression spans
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
    # primitive type, const, @enum and module, under @inline, @noinline or @closed
    @quarantine "Julia's definition forms, read from the parsed expression" Base.Meta.isexpr function _defines(def, source::LineNumberNode)::Tuple{Vector{Symbol},Symbol}
        refuse() = throw(ConstructionViolation("the definition forms",
            "$(_at(source)): not a definition @parity or @quarantine reads (function, macro, struct, abstract or primitive type, const, @enum, module)"))
        typename(t) = t isa Symbol ? t : Meta.isexpr(t, :(<:)) || Meta.isexpr(t, :curly) ? typename(t.args[1]) : refuse()
        if Meta.isexpr(def, :macrocall) && def.args[1] in (Symbol("@inline"), Symbol("@noinline"), Symbol("@closed"))
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
        elseif Meta.isexpr(def, :module)
            def.args[2] isa Symbol || refuse()
            return ([def.args[2]], def.args[2])
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

    # the value a dotted name resolves to in `mod`, every prefix a module, or nothing
    @quarantine "a qualified name resolves through modules, Julia's getglobal" Core.getglobal function _resolve_name(mod::Module, ex)
        ex isa Symbol && return isdefined(mod, ex) ? Some(getglobal(mod, ex)) : nothing
        ex isa GlobalRef && return isdefined(ex.mod, ex.name) ? Some(getglobal(ex.mod, ex.name)) : nothing
        Meta.isexpr(ex, :., 2) && ex.args[2] isa QuoteNode || return nothing
        local owner = _resolve_name(mod, ex.args[1])
        owner === nothing && return nothing
        local o, n = something(owner), ex.args[2].value
        return o isa Module && n isa Symbol && isdefined(o, n) ? Some(getglobal(o, n)) : nothing
    end

    # whether the definition's own text references `v`: a name, a qualified name or a GlobalRef in it
    # resolving to `v` in `mod`, or a form whose syntax stands for it (a module definition for
    # Core.Module, a type declaration for Core.DataType, an interpolated string for Base.string)
    @quarantine "the API a definition rests on is one its code references, read from its expression" Base.Meta.isexpr function _references(mod::Module, ex, @nospecialize(v))::Bool
        Meta.isexpr(ex, :module) && v === Core.Module && return true
        (Meta.isexpr(ex, :struct) || Meta.isexpr(ex, :abstract) || Meta.isexpr(ex, :primitive)) && v === Core.DataType && return true
        Meta.isexpr(ex, :string) && v === Base.string && return true
        local r = _resolve_name(mod, ex)
        r !== nothing && something(r) === v && return true
        ex isa Expr || return false
        Meta.isexpr(ex, :., 2) && return _references(mod, ex.args[1], v)
        return any(a -> _references(mod, a, v), ex.args)
    end

    # the QuarantineEntry of one definition, or a refusal at its line: the necessity stated, the API a
    # qualified name that resolves and that the definition references, the file in src/julia (a file
    # under src/ elsewhere carries @parity)
    @quarantine "the Julia-only definitions are checked where they are written, Rust's unsafe" Base.Meta.isexpr function _quarantine_entry(mod::Module, source::LineNumberNode, necessity, api, def)::QuarantineEntry
        refuse(why) = throw(ConstructionViolation("@quarantine", "$(_at(source)): $why"))
        necessity isa String && !isempty(strip(necessity)) || refuse("the necessity is not a non-empty string")
        Meta.isexpr(api, :., 2) && api.args[2] isa QuoteNode || refuse("the Julia API $(repr(api)) is not a qualified name (Module.name)")
        local v = _resolve_name(mod, api)
        v === nothing && refuse("the Julia API $(repr(api)) does not resolve")
        _references(mod, def, something(v)) || refuse("the definition does not reference its Julia API $api")
        local file = string(something(source.file, :none))
        local julia = joinpath(SRC, "julia")
        (_inside(file, SRC) || _within(mod, @__MODULE__)) && !_inside(file, julia) &&
            refuse("a definition outside src/julia carries @parity, the dart definition it copies")
        local names, _ = _defines(def, source)
        return QuarantineEntry(mod, necessity, string(api), names, Symbol(file), source.line, _last_line(def, source.line),
                               UInt(0):UInt(0), Int32(0), Method[])
    end

    # a checked definition's expansion: the evaluation bracketed by its worlds, then the entry; a
    # module, whose expression must stand at top level, in a top-level expression
    @quarantine "a definition's evaluation is bracketed by world reads, Julia's top-level evaluation" Base.Meta.isexpr function _expansion(source::LineNumberNode, def, e::RegistryEntry)::Expr
        local mark = Expr(:call, GlobalRef(@__MODULE__, :_mark!))
        local reg = Expr(:call, GlobalRef(@__MODULE__, :_register!), e)
        Meta.isexpr(def, :module) && return Expr(:toplevel, mark, def, reg, nothing)
        return Expr(:block, mark, Expr(:macrocall, GlobalRef(Core, Symbol("@__doc__")), source, def), reg, nothing)
    end

    """
        @quarantine "<necessity>" <Module.api> <definition>

    Marks a definition of src/julia: what Julia forces that dart lacks, and the Julia API it relies
    on, a qualified name that resolves and that the definition's own code references (one that does
    not refuses the load at this line). A definition outside src/julia carries `@parity` instead.

    precedent(rust: `unsafe` with clippy's undocumented_unsafe_blocks, each block saying why). Julia's
    differs: no keyword marks Julia-only code, so the macro checks and records it when it loads.
    """
    @quarantine "Julia has no unsafe blocks; a macro marks and records each Julia-only definition" Base.esc macro quarantine(necessity, api, def)
        return esc(_expansion(__source__, def, _quarantine_entry(__module__, __source__, necessity, api, def)))
    end
end
    local marked = Tuple{LineNumberNode,Any,Any,Any,UInt,UInt}[]
    for st in defs.args
        st isa LineNumberNode && continue
        local doc = nothing
        if Meta.isexpr(st, :macrocall) && st.args[1] == GlobalRef(Core, Symbol("@doc"))
            doc, st = st.args[3], st.args[4]
        end
        Meta.isexpr(st, :macrocall) && st.args[1] === Symbol("@quarantine") && length(st.args) == 5 ||
            error("parity.jl: the registry's block holds only @quarantine definitions")
        local source, necessity, api, def = st.args[2], st.args[3], st.args[4], st.args[5]
        local w0 = Base.get_world_counter()
        Core.eval(@__MODULE__, doc === nothing ? def : Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), source, doc, def))
        push!(marked, (source, necessity, api, def, w0, Base.get_world_counter()))
    end
    for (source, necessity, api, def, w0, w1) in marked
        Core.eval(@__MODULE__, Expr(:call, :_register_range!, Expr(:call, :_quarantine_entry, @__MODULE__, QuoteNode(source),
                                                                     necessity, QuoteNode(api), QuoteNode(def)), w0, w1))
    end
end

"""
    construction_check(::Val{definition}) -> Int

The load-time check of the construction `definition` names, defined beside that definition; 0 when
it holds, and it throws, refusing the load, when it does not. `ConstructionLock(definition)` in
test/parity_ratchet.jl only calls it. This method is the file map's (`check_include_dart`); every
directory of src/ is a dependency of the package image by its listing, so a file added anywhere
under src/ rebuilds the image and meets the check, rather than loading the image built before it.
"""
@quarantine "Julia rebuilds a package image only for its include dependencies" Base.include_dependency function construction_check(::Val{:include_dart})::Int
    for (dir, _, _) in walkdir(SRC)
        include_dependency(dir; track_content = true)
    end
    return check_include_dart(SRC, INCLUDED)
end

"""
    DART_FILES

The pin table: every dart file in scope at the pinned commit (dev/PARITY_MASTER.md), by its path
under the sdk's pkg/ exactly as it sits at the pin (`dart2wasm/lib/translator.dart`,
`wasm_builder/lib/src/ir/type.dart`); `include_dart` loads only these, each from its source file
(`_jl_path`), and an anchor names only these. The files left out are out of scope (dev/MARCH.md
1.A4's dev/skeleton_scope.toml gives each its reason).
"""
@quarantine "Julia's include takes any path; the pin table is the file map dart's part directives fix" Core.String const DART_FILES::Tuple{Vararg{String}} = (
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
@quarantine "Julia records no include set a module can reflect on; include_dart keeps it" Core.String const INCLUDED = String[]

"""
    DART_MODULES

The module each dart file loads into, by the first prefix of its key that matches: one module per
dart package (`Dart2Wasm` for dart2wasm/lib, `WasmBuilder` for wasm_builder), and inside it one per
library dart imports under a prefix at the pin (dart2wasm's `util.dart as util` and
`js/runtime_generator.dart as js`, wasm_builder's `ir/ir.dart as ir`, which exports every ir file);
dart2wasm's `package:wasm_builder/wasm_builder.dart as w` is the package module itself. A name dart
spells `p.X` is `P.X` in the module that binds P: the package modules and a package's library
modules are bound where src/julia/packages.jl declares them.

precedent(dart: an import prefix, the library's names under it; rust: a module per namespace).
Julia's differs: it has no per-file namespace, so a prefix is a module, and a file is loaded into it.
"""
@quarantine "Julia has no per-file namespace; a dart package or prefixed library is a module" Base.Pair const DART_MODULES = (
    "dart2wasm/lib/util.dart" => (:Dart2Wasm, :Util),
    "dart2wasm/lib/js/runtime_generator.dart" => (:Dart2Wasm, :JS),
    "dart2wasm/lib/" => (:Dart2Wasm,),
    "wasm_builder/lib/src/ir/" => (:WasmBuilder, :IR),
    "wasm_builder/lib/" => (:WasmBuilder,),
)

# the module a dart file of the pin table loads into
@quarantine "a dart file's namespace is its package's or prefixed library's module" Core.getglobal function _module_of(dart::String)::Module
    for (prefix, path) in DART_MODULES
        startswith(dart, prefix) || continue
        local m = @__MODULE__
        for n in path
            isdefined(m, n) || throw(ConstructionViolation("include_dart", "the module $(join(path, '.')) for $dart is not declared (src/julia/packages.jl)"))
            m = getglobal(m, n)
        end
        return m
    end
    throw(ConstructionViolation("include_dart", "$dart is in no module of DART_MODULES"))
end

# the definition a top-level statement of a port carries, its docstring and @parity peeled, or nothing
@quarantine "a port's top-level statements are Julia expressions, read by their parsed form" Base.Meta.isexpr function _marked_definition(st)
    Meta.isexpr(st, :macrocall) && length(st.args) == 4 && st.args[1] == GlobalRef(Core, Symbol("@doc")) && (st = st.args[4])
    Meta.isexpr(st, :macrocall) && length(st.args) == 4 && _is_macro(st, Symbol("@parity")) || return nothing
    local def = st.args[4]
    _is_macro(def, Symbol("@unported")) && (def = def.args[end])
    return def
end

# whether a top-level statement of a port declares a type: a struct, abstract or primitive type,
# @enum or @closed sum behind @parity, which the first pass evaluates
@quarantine "Julia needs a type to exist before a signature names it; a declaration is read by its head" Base.Meta.isexpr function _is_declaration(st)::Bool
    local def = _marked_definition(st)
    def === nothing && return false
    return Meta.isexpr(def, :struct) || Meta.isexpr(def, :abstract) || Meta.isexpr(def, :primitive) ||
           (Meta.isexpr(def, :macrocall) && def.args[1] in (Symbol("@enum"), Symbol("@closed")))
end

# the names a declaration's supertype and field types mention, each with the module path it is
# qualified by (empty for a bare name): the declarations it must follow
@quarantine "a type's supertype and field types are read from its parsed declaration" Base.Meta.isexpr function _declaration_needs(def)::Vector{Tuple{Vector{Symbol},Symbol}}
    local out = Tuple{Vector{Symbol},Symbol}[]
    local walk(ex) = if ex isa Symbol
        push!(out, (Symbol[], ex))
    elseif Meta.isexpr(ex, :., 2) && ex.args[2] isa QuoteNode
        local path = Symbol[]
        local a = ex.args[1]
        while Meta.isexpr(a, :., 2) && a.args[2] isa QuoteNode
            pushfirst!(path, a.args[2].value); a = a.args[1]
        end
        a isa Symbol && pushfirst!(path, a)
        push!(out, (path, ex.args[2].value))
    elseif ex isa Expr
        foreach(walk, ex.args)
    end
    if Meta.isexpr(def, :struct)
        Meta.isexpr(def.args[2], :(<:)) && walk(def.args[2].args[2])
        for f in def.args[3].args
            Meta.isexpr(f, :(::)) && length(f.args) == 2 && walk(f.args[2])
        end
    elseif Meta.isexpr(def, :abstract) || Meta.isexpr(def, :primitive)
        Meta.isexpr(def.args[1], :(<:)) && walk(def.args[1].args[2])
    elseif Meta.isexpr(def, :macrocall) && def.args[1] === Symbol("@closed")
        walk(def.args[end].args[1].args[2])   # the sum's kinds
    end
    return out
end

# the function a top-level statement of a port defines by a marked definition, or nothing: the module
# path it is qualified by (empty for a bare name; `WasmBuilder.f` from an ir file, a package's member
# function owned by the package module) and its name, the generic the loader declares before the
# second pass
@quarantine "Julia needs a function to exist before another module adds a method to it; dart resolves a library's names first" Base.Meta.isexpr function _generic_name(st)::Union{Tuple{Any,Symbol},Nothing}
    local def = _marked_definition(st)
    def === nothing && return nothing
    Meta.isexpr(def, :macrocall) && def.args[1] in (Symbol("@inline"), Symbol("@noinline")) && (def = def.args[end])
    (Meta.isexpr(def, :function) || Meta.isexpr(def, :(=))) || return nothing
    local c = _call(def.args[1])
    c === nothing && return nothing
    local f = c.args[1]
    f isa Symbol && return (nothing, f)
    Meta.isexpr(f, :., 2) && f.args[2] isa QuoteNode && f.args[2].value isa Symbol && return (f.args[1], f.args[2].value)
    return nothing
end

"""
    include_dart("<file>.dart", ...)

Loads the ports of those dart files, each its path under the sdk's pkg/ (`_jl_path`), each into its
module (`DART_MODULES`): the only way a file of src/ outside src/julia loads, called once with every
port. The paths must be in `DART_FILES`; when the package has loaded, the files it loaded are
exactly the directory's (`check_include_dart`). It loads in two passes: first every file's type
declarations (struct, abstract and primitive type, @enum and @closed sum behind @parity), each
after the declarations its supertype, field types or kinds name, then every function a marked
definition binds declared (no method), then every other definition, file by file in DART_FILES
order; two declarations that need each other refuse the load.

precedent(dart: `part`/`part of` naming each file, and a library's declarations resolved before
its bodies; rust: `mod`, and items independent of their order). Julia's differs: `include` takes any
path and a signature can name only a type that exists, so the file map is a table checked against
the directory and the loader orders the passes.
"""
@quarantine "Julia's include loads any path in its text's order; include_dart admits the pin table's files and records each it loads" Base.push! function include_dart(darts::String...)::Nothing
    isempty(INCLUDED) || throw(ConstructionViolation("include_dart", "include_dart is called once, with every port"))
    for d in darts
        d in DART_FILES || throw(ConstructionViolation("include_dart", "$d is no file of the pin table DART_FILES"))
        d in INCLUDED && throw(ConstructionViolation("include_dart", "$d is included twice"))
        push!(INCLUDED, d)
    end
    local order = String[d for d in DART_FILES if d in INCLUDED]
    _load_two_pass!(Tuple{Module,String}[(_module_of(d), _jl_path(d)) for d in order])
    return nothing
end

"""
    _load_two_pass!(units)

Loads each `(module, file)` of `units` in two passes: the type declarations of every file first,
ordered so each follows the declarations its supertype and field types name in the units (by
module and name; a dotted name by the module named last before it), then each file's other
statements in order. Two declarations that need each other refuse the load, naming both.
"""
@quarantine "Julia evaluates a file top to bottom; the type declarations of every file are evaluated first" Base.include function _load_two_pass!(units::Vector{Tuple{Module,String}})::Nothing
    local decls = Tuple{Module,String,Any,Symbol}[]
    local generics = Tuple{Module,Tuple{Any,Symbol}}[]
    for (m, path) in units
        include_dependency(path; track_content = true)
        local top = Meta.parseall(read(path, String); filename = path)
        local lnn = LineNumberNode(1, Symbol(path))
        for st in top.args
            st isa LineNumberNode && (lnn = st; continue)
            _is_declaration(st) && push!(decls, (m, path, Expr(:toplevel, lnn, st), last(_defines(_marked_definition(st), lnn))))
            local g = _generic_name(st)
            g === nothing || push!(generics, (m, g))
        end
    end
    local index = Dict{Tuple{Module,Symbol},Int}((d[1], d[4]) => i for (i, d) in enumerate(decls))
    local needs(i) = begin
        local m = decls[i][1]
        local out = Int[]
        for (path, n) in _declaration_needs(_marked_definition(decls[i][3].args[2]))
            local target = isempty(path) ? m : nothing
            if !isempty(path)
                for (mm, _, _, _) in decls
                    nameof(mm) === path[end] && (target = mm; break)
                end
            end
            target === nothing && continue
            local j = get(index, (target, n), 0)
            j != 0 && j != i && push!(out, j)
        end
        out
    end
    local state = zeros(Int, length(decls))   # 0 unvisited, 1 on the path, 2 evaluated
    local visit(i, from) = begin
        state[i] == 2 && return
        state[i] == 1 && throw(ConstructionViolation("include_dart",
            "the declarations $(decls[from][4]) and $(decls[i][4]) need each other ($(decls[i][2]))"))
        state[i] = 1
        foreach(j -> visit(j, i), needs(i))
        Core.eval(decls[i][1], decls[i][3])
        state[i] = 2
    end
    foreach(i -> visit(i, i), eachindex(decls))
    # every function a marked definition binds exists before any body names it: a method another
    # module's file adds (`WasmBuilder.serialize(s, x::IR.RefType)`, dart's interface method
    # implemented elsewhere) loads whatever the file order; `function f end` makes no method
    for (m, (q, g)) in generics
        # a qualified name declares in the module it names, a package module of this one's root, never
        # Base or Core (a method of their functions extends what exists)
        local owner = q === nothing ? m : something(_resolve_name(m, q), nothing)
        owner isa Module && owner !== Base && owner !== Core && _within(owner, Base.moduleroot(m)) || continue
        isdefined(owner, g) || Core.eval(owner, Expr(:function, g))
    end
    for (m, path) in units
        Base.include(st -> _is_declaration(st) ? nothing : st, m, path)
    end
    return nothing
end

# the source file of a dart file of the pin table, relative to src/: dart2wasm's lib/<f>.dart is
# <f>.jl, wasm_builder's lib/<f>.dart and lib/src/<f>.dart are wasm_builder/<f>.jl (dev/MARCH.md 1.A4)
@quarantine "a Julia package's files sit under one src/, where the sdk keeps two packages' lib/" Base.match function _jl_rel(dart::String)::String
    local m = match(r"^(?:dart2wasm/lib/|(wasm_builder/)lib/(?:src/)?)([\w/]+)\.dart$", dart)
    m === nothing && throw(ConstructionViolation("include_dart", "$dart is no path under dart2wasm/lib or wasm_builder/lib"))
    return something(m[1], "") * m[2] * ".jl"
end
@quarantine "a source file is included by its absolute path, Julia's include unit" Base.joinpath _jl_path(dart::String)::String = joinpath(SRC, _jl_rel(dart))

"""
    PIN

The dart-lang/sdk commit every anchor cites (dev/PARITY_MASTER.md states it; the ratchet's L213
holds the two equal). An anchor's file is its path under that checkout's pkg/.
"""
@quarantine "the oracle's commit, which the anchors' resolver reads the pinned sdk at" Core.String const PIN::String = "898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e"

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

# the dart members Julia spells as a Base function, the one name the rule admits for each: the
# operators dart declares on a class, and Object's toString and hashCode, which Julia's show and hash
# answer
@quarantine "dart's operators and Object members are Base functions in Julia" Base.Dict const DART_BASE = Dict{String,Symbol}(
    "toString" => :show, "hashCode" => :hash,
    "==" => :(==), "[]" => :getindex, "[]=" => :setindex!, "+" => :+, "-" => :-, "unary-" => :-,
    "*" => :*, "/" => :/, "~/" => :div, "%" => :mod, "<" => :<, ">" => :>, "<=" => :<=, ">=" => :>=,
    "&" => :&, "|" => :|, "^" => :xor, "~" => :~, "<<" => :<<, ">>" => :>>, ">>>" => :>>>)

# the Julia names the rule admits for an anchor's symbol: `X` its type or unnamed constructor X (a
# top-level function or variable `f`: snake(f)); `X.m` the Base function DART_BASE names for m alone,
# else snake(m) (a method, getter or field), X_snake(m) (a static or named constructor) or
# set_snake(m)! (a setter). A dart name that is a Julia keyword is written var"<name>", Julia's own
# spelling of any identifier, so the rule needs no case for it
@quarantine "dart and Julia name a definition by different conventions; one rule maps them" Base.Symbol function _admitted_names(symbol::AbstractString)::Vector{Symbol}
    local parts = split(symbol, '.'; limit = 2)
    length(parts) == 1 && return unique([Symbol(symbol), Symbol(snake(symbol))])
    local x, m = parts
    haskey(DART_BASE, m) && return Symbol[DART_BASE[m]]
    return Symbol[Symbol(snake(m)), Symbol(x, "_", snake(m)), Symbol("set_", snake(m), "!")]
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

# ---- the anchors resolve at the pin (L213) ----------------------------------------------------------
# An anchor names a dart line; the line must declare the anchor's symbol at PIN, read from a checkout
# of dart-lang/sdk at that commit in one place, ~/.cache/wasmtarget/dart-sdk (dev/fetch_dart_sdk.sh
# makes it). Where the checkout exists, @parity refuses an anchor that does not resolve at its line
# and the package's load checks every anchor; the ratchet's L213 requires the checkout.

# an anchor's three parts: the key of its dart file, its line and its symbol
@quarantine "an anchor is a string, which Julia reads with a regex where dart's analyzer has a name" Base.var"@r_str" const ANCHOR_RX = r"^([\w/]+\.dart):([1-9]\d*) ([A-Za-z_$][\w$]*(?:\.\S+)?)$"

# the commit a git checkout's HEAD names, or nothing (no checkout, or a HEAD it cannot resolve)
@quarantine "git records a checkout's commit in its HEAD file, which Julia reads without a git process" Base.read function _head_commit(dir::String)::Union{String,Nothing}
    local git = joinpath(dir, ".git")
    isdir(git) || return nothing
    local head = strip(read(joinpath(git, "HEAD"), String))
    startswith(head, "ref: ") || return String(head)
    local ref = head[length("ref: ")+1:end]
    isfile(joinpath(git, ref)) && return String(strip(read(joinpath(git, ref), String)))
    local packed = joinpath(git, "packed-refs")
    isfile(packed) || return nothing
    for l in eachline(packed)
        local f = split(l)
        length(f) == 2 && f[2] == ref && return String(f[1])
    end
    return nothing
end

# the checkout of dart-lang/sdk at PIN, or nothing when there is none at the one path
@quarantine "the oracle's checkout is the developer's, at one path under the home directory" Base.Filesystem.homedir function _pin_sdk()::Union{String,Nothing}
    local dir = joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk")
    return _head_commit(dir) == PIN ? dir : nothing
end

# the pinned files' lines, read once while the package loads and emptied before its image is saved
@quarantine "Julia reads a file per call; the resolver reads each pinned file once" Base.Dict const _PIN_LINES = Dict{String,Vector{String}}()

# a dart declaration that opens a body at column 0, and its name
@quarantine "dart's declaration keywords, read from its formatted source" Base.var"@r_str" const DART_DECL_RX = r"^(?:(?:abstract|sealed|base|final|interface|mixin)\s+)*(?:class|mixin|enum|typedef|extension(?:\s+type)?)\s+([A-Za-z_$][\w$]*)"

# the name of the declaration whose body holds line `i`: the nearest code line above it at column 0
# (dart's formatter puts every top-level declaration there and its members at column 2); "" for an
# unnamed `extension on T`, nothing for no declaration with a body
@quarantine "dart's formatter fixes the columns, so a declaration's body is read from indentation" Base.match function _enclosing(lines::Vector{String}, i::Int)::Union{String,Nothing}
    for j in i-1:-1:1
        local l = lines[j]
        (isempty(l) || l[1] in (' ', '}', '/', '@', '*', ')')) && continue
        occursin(r"^extension\s+on\b", l) && return ""
        local m = match(DART_DECL_RX, l)
        return m === nothing ? nothing : String(m[1])
    end
    return nothing
end

# why line `ln` does not declare `symbol`, or nothing when it does: `X` a top-level declaration at
# column 0 (a class, mixin, enum, typedef or extension named X, or a function or variable X), or X's
# unnamed constructor at column 2 of X's body; `X.m` a member at column 2 of X's body (a method,
# getter, setter, field, named constructor X.m or operator m); a bare `m` also a member of an unnamed
# extension, which has no name to anchor by
@quarantine "dart's analyzer resolves a name to its declaration; Julia reads the pinned line" Base.occursin function _declares(lines::Vector{String}, ln::Int, symbol::AbstractString)::Union{String,Nothing}
    ln <= length(lines) || return "line $ln is past the file's end ($(length(lines)) lines)"
    local l = lines[ln]
    local s = lstrip(l)
    local col = ncodeunits(l) - ncodeunits(s)
    (startswith(s, "//") || startswith(s, "/*") || startswith(s, "*")) && return "line $ln is a comment"
    local member(x, m) = occursin(Regex("(?<![\\w\$.])\\Q" * m * "\\E(?![\\w\$])\\s*(?:[(<=;,]|\$)"), s) ||
        occursin(Regex("\\b(?:get|set)\\s+\\Q" * m * "\\E(?![\\w\$])"), s) ||
        occursin(Regex("\\boperator\\s*\\Q" * m * "\\E\\s*\\("), s) ||
        (x !== nothing && occursin(Regex("(?<![\\w\$])\\Q" * x * "." * m * "\\E(?![\\w\$])"), s))
    local parts = split(symbol, '.'; limit = 2)
    if length(parts) == 1
        local x = parts[1]
        if col == 0
            local d = match(DART_DECL_RX, s)
            d !== nothing && return d[1] == x ? nothing : "line $ln declares $(d[1]), not $x"
            return occursin(Regex("(?<![\\w\$])\\Q" * x * "\\E(?![\\w\$])\\s*(?:[(<=;,]|\$)"), s) ? nothing : "line $ln does not declare $x"
        end
        col == 2 || return "line $ln is at column $col, no declaration's"
        local enc = _enclosing(lines, ln)
        enc == x && occursin(Regex("^(?:const\\s+|factory\\s+)?\\Q" * x * "\\E\\s*\\("), s) && return nothing
        enc == "" && member(nothing, x) && return nothing
        return "line $ln does not declare $x (a top-level declaration sits at column 0)"
    end
    local x, m = parts
    col == 2 || return "line $ln is at column $col, not a member's 2"
    local enc = _enclosing(lines, ln)
    enc == x || return "line $ln is in the body of $(enc === nothing ? "no declaration" : enc == "" ? "an unnamed extension" : enc), not $x"
    return member(x, m) ? nothing : "line $ln does not declare $x.$m"
end

# the dart class `name`'s declaration line in `lines`, or 0
@quarantine "a dart class is found by its declaration at column 0, dart's formatted source" Base.match function _class_line(lines::Vector{String}, name::AbstractString)::Int
    for (i, l) in enumerate(lines)
        local d = match(DART_DECL_RX, l)
        d !== nothing && d[1] == name && occursin(r"\bclass\b", l) && return i
    end
    return 0
end

# the classes a dart class declaration at line `ln` extends, implements or mixes in, read up to the
# body's `{`, type arguments dropped
@quarantine "dart's supertypes follow extends, implements and with in the class header" Base.eachmatch function _dart_supers(lines::Vector{String}, ln::Int)::Vector{String}
    local head = ""
    for j in ln:min(length(lines), ln + 8)
        head *= " " * lines[j]
        occursin('{', lines[j]) && break
    end
    head = replace(head, r"<[^<>]*>" => "", r"<[^<>]*>" => "")
    local m = match(r"\b(?:extends|implements|with)\b(.*?)(?:\{|$)", head)
    m === nothing && return String[]
    return String[x.match for x in eachmatch(r"[A-Za-z_$][\w$]*", m[1]) if !(x.match in ("extends", "implements", "with"))]
end

# whether the dart class at line `ln` is reachable from a sealed class through its supertypes: a kind
# of a sealed sum, its subclasses then the sum's too; `find(name)` gives a class declared in another
# file as `(lines, line)`, or nothing
@quarantine "WasmTarget compiles a closed world: the pinned sdk holds every subclass" Base.occursin function _sealed_ancestor(lines::Vector{String}, ln::Int, find::Function, depth::Int = 0)::Bool
    depth > 16 && return false
    for sup in _dart_supers(lines, ln)
        local i = _class_line(lines, sup)
        local where_ = i == 0 ? find(sup) : (lines, i)
        where_ === nothing && continue
        local ls, k = where_
        occursin(r"^(?:(?:abstract|base|final|interface|mixin)\s+)*sealed\s+class\b", ls[k]) && return true
        _sealed_ancestor(ls, k, find, depth + 1) && return true
    end
    return false
end

# why a mirror's form disagrees with the dart declaration at line `ln`, or nothing: a dart `sealed`
# class is a `@closed` sum of its subclasses (its kinds closed by the type), never an open abstract
# type or a struct; a `@closed` sum mirrors a sealed class, or an abstract class that is a kind of a
# sealed sum (reachable from one through its supertypes), whose subclasses the closed world holds
# (A34S4; the lead's ruling (a), 2026-10-22); `find` as _sealed_ancestor's
@quarantine "dart's sealed modifier closes a hierarchy, which Julia spells as a closed Union, not an abstract type" Base.occursin function _form_fault(lines::Vector{String}, ln::Int, def, find::Function = _ -> nothing)::Union{String,Nothing}
    ln <= length(lines) || return nothing
    local sealed = occursin(r"^(?:(?:abstract|base|final|interface|mixin)\s+)*sealed\s+class\b", lines[ln])
    local closed = _is_macro(def, Symbol("@closed"))
    local typedecl = Meta.isexpr(def, :struct) || Meta.isexpr(def, :abstract)
    sealed && typedecl && return "dart's line $ln declares a sealed class, whose mirror is a @closed sum of its subclasses, not an open type"
    if closed && !sealed
        local abstract_ = occursin(r"^(?:(?:base|interface|mixin)\s+)*abstract\s+(?:(?:base|interface|mixin)\s+)*class\b", lines[ln])
        abstract_ && _sealed_ancestor(lines, ln, find) && return nothing
        return "a @closed sum mirrors a dart sealed class or an abstract kind of one; line $ln declares neither"
    end
    return nothing
end

# why an anchor does not resolve in the checkout `sdk`, or nothing when it does
@quarantine "the pinned dart file is read where the anchor is checked" Base.readlines function _anchor_fault(sdk::String, anchor::String)::Union{String,Nothing}
    local a = match(ANCHOR_RX, anchor)
    a === nothing && return "$(repr(anchor)) is no anchor"
    local path = joinpath(sdk, "pkg", a[1])
    isfile(path) || return "the pin has no pkg/$(a[1])"
    local lines = get!(() -> readlines(path), _PIN_LINES, path)
    return _declares(lines, parse(Int, a[2]), a[3])
end

"""
    check_anchors_resolve(mod, sdk) -> Int

The oracle's check: the anchor of every `@parity` definition of `mod` names a line that declares
its symbol in `sdk`, a checkout of dart-lang/sdk at `PIN`; throws a `ConstructionViolation` listing
each anchor that does not, with the reason.

precedent(dart: the analyzer resolves every identifier to its declaration or the program does not
compile; rust: rustdoc denies broken intra-doc links). Julia's differs: nothing resolves a name in
another language's source, so the macro reads the pinned dart line where the anchor is written and
the load checks every anchor, both where the pinned checkout exists.
"""
@quarantine "Julia resolves no name in dart's source; the anchors are read against the pinned files" Base.empty! function check_anchors_resolve(mod::Module, sdk::String)::Int
    local out = String[]
    for e in REGISTRY
        e isa ParityEntry && _within(e.mod, mod) || continue
        local f = _anchor_fault(sdk, e.anchor)
        f === nothing || push!(out, "$(basename(string(e.file))):$(e.first) $(e.anchor): $f")
    end
    empty!(_PIN_LINES)
    isempty(out) || throw(ConstructionViolation("check_anchors_resolve", join(out, "; ")))
    return 0
end
# the oracle's assertion: run when the package loads where the pinned checkout exists
# (src/WasmTarget.jl), and required by the ratchet's L213, which a missing checkout fails
@quarantine "the oracle's assertion, run when the package loads" Base.Val function construction_check(::Val{:check_anchors_resolve})::Int
    local sdk = _pin_sdk()
    sdk === nothing && throw(ConstructionViolation("check_anchors_resolve",
        "no checkout of dart-lang/sdk at $PIN at ~/.cache/wasmtarget/dart-sdk: bash dev/fetch_dart_sdk.sh"))
    return check_anchors_resolve(@__MODULE__, sdk)
end

# how many inner constructors a struct's body defines: the function definitions in it named for the
# struct
@quarantine "Julia gives a struct with no inner constructor its default ones, which a port must not lean on" Base.Meta.isexpr function _inner_constructors(def::Expr, name::Symbol)::Int
    local n = 0
    for st in def.args[3].args
        Meta.isexpr(st, :macrocall) && st.args[1] == GlobalRef(Core, Symbol("@doc")) && (st = st.args[end])
        (Meta.isexpr(st, :function) || Meta.isexpr(st, :(=))) || continue
        local c = _call(st.args[1])
        c === nothing && continue
        local f = c.args[1]
        local g = Meta.isexpr(f, :curly) ? f.args[1] : f
        g === name && (n += 1)
    end
    return n
end

# the ParityEntry of one definition and the definition to evaluate (an @unported stub expanded), or
# a refusal at its line: the anchor's form and file, the file outside src/julia (and loaded by
# include_dart, in WasmTarget), the Julia name the rule admits, the anchor resolved at the pin
@quarantine "the dart anchors are checked where they are written, as dart's analyzer would" Base.match function _parity_entry(mod::Module, source::LineNumberNode, anchor, def)::Tuple{ParityEntry,Any}
    local refuse(why) = throw(ConstructionViolation("@parity", "$(_at(source)): $why"))
    anchor isa String || refuse("the anchor is not a string literal")
    local m = match(ANCHOR_RX, anchor)
    m === nothing && refuse("the anchor $(repr(anchor)) does not read \"<file>.dart:<line> <Symbol>\"")
    m[1] in DART_FILES || refuse("the anchor's file $(m[1]) is no file of the pin table DART_FILES")
    local file = string(something(source.file, :none))
    local own = _within(mod, @__MODULE__)
    _inside(file, joinpath(SRC, "julia")) && refuse("a definition in src/julia carries @quarantine, the Julia necessity that forces it")
    (_inside(file, SRC) || own) && !any(d -> _jl_path(d) == normpath(file), INCLUDED) &&
        refuse("$file is not a file include_dart loaded")
    local ported = !_is_macro(def, Symbol("@unported"))
    ported || (def = _unported(anchor, def.args[end], source))
    local names, name = _defines(def, source)
    if ported && Meta.isexpr(def, :struct)
        local n = _inner_constructors(def, name)
        n == 1 || refuse("a ported struct defines exactly one inner constructor, not $n: dart's constructors are its outer functions over it, and Julia's default constructors stand for none")
    end
    local admitted = _admitted_names(m[3])
    name in admitted || refuse("the Julia name $name is not the rule's for $(m[3]): $(join(admitted, ", "))")
    # WasmTarget's own anchors resolve at the pin where its checkout exists (L213), and a dart class's
    # mirror has its form: a sealed class a @closed sum, any other class a struct or abstract type
    local sdk = own ? _pin_sdk() : nothing
    local fault = sdk === nothing ? nothing : _anchor_fault(sdk, anchor)
    fault === nothing || refuse("the anchor does not resolve at the pin: $fault")
    if sdk !== nothing
        local lines = get!(() -> readlines(joinpath(sdk, "pkg", m[1])), _PIN_LINES, joinpath(sdk, "pkg", m[1]))
        local pkgdir = m[1][1:findfirst('/', m[1])]   # the package of the anchor's file, dart2wasm/ or wasm_builder/
        local find(name) = begin
            for d in DART_FILES
                startswith(d, pkgdir) || continue
                local p = joinpath(sdk, "pkg", d)
                local ls = get!(() -> readlines(p), _PIN_LINES, p)
                local i = _class_line(ls, name)
                i == 0 || return (ls, i)
            end
            nothing
        end
        local why = _form_fault(lines, parse(Int, m[2]), def, find)
        why === nothing || refuse(why)
    end
    local declares = Meta.isexpr(def, :struct) || Meta.isexpr(def, :abstract) || Meta.isexpr(def, :primitive) ||
        (Meta.isexpr(def, :macrocall) && def.args[1] in (Symbol("@enum"), Symbol("@closed")))
    return (ParityEntry(mod, anchor, ported, declares, names, Symbol(file), source.line, _last_line(def, source.line), UInt(0):UInt(0), Int32(0), Method[]), def)
end

"""
    @parity "<file>.dart:<line> <Symbol>" <definition>

Marks a definition outside src/julia with the dart definition it copies at the pinned commit:
the file a key of `DART_FILES`, the Julia name the one rule's for the symbol (`snake`), the file
loaded by `include_dart`, and, where the pinned checkout exists, the anchor's line declaring its
symbol at `PIN` (`check_anchors_resolve`); any other form refuses the load at this line.
`@parity "<anchor>" @unported <definition>` stands for a definition not yet ported: its body rejects
with the anchor.

precedent(rust: the deny missing_docs lint, every item documented or the crate does not build).
Julia's differs: nothing requires a definition to say where it comes from, so the macro checks it
where it is written and the totality check refuses any definition without it when the package loads.
"""
@quarantine "Julia has no lint that denies an unanchored item; a macro checks and records each" Base.esc macro parity(anchor, def)
    local e, def2 = _parity_entry(__module__, __source__, anchor, def)
    return esc(_expansion(__source__, def2, e))
end

"""
    anchor_of(f) -> String

The `@parity` anchor of the one definition that binds `f`, found by identity in REGISTRY (an entry
whose module binds one of its names to `f` itself), so a rejection can name the dart definition it
stands for without writing the anchor a second time. No entry, or more than one, refuses.
"""
@quarantine "a definition's dart anchor is read from the registry by the object it binds, Julia's identity" Core.getglobal function anchor_of(@nospecialize(f))::String
    local hits = ParityEntry[e for e in REGISTRY if e isa ParityEntry &&
                             any(n -> isdefined(e.mod, n) && getglobal(e.mod, n) === f, e.names)]
    length(hits) == 1 || throw(ConstructionViolation("anchor_of",
        "$f is bound by $(isempty(hits) ? "no @parity definition" : "$(length(hits)) @parity definitions"), not one"))
    return hits[1].anchor
end

"""
    @unported <definition>

Inside `@parity` only, which expands it: a definition not yet ported, its body
`reject!(Unported(<anchor>), <signature>)` with the enclosing `@parity`'s anchor.
"""
@quarantine "a stub's anchor is its @parity's, so the stub cannot name another" Base.throw macro unported(def)
    throw(ConstructionViolation("@unported", "$(_at(__source__)): @unported outside @parity, whose anchor is the stub's"))
end

# ---- totality: every method and binding a definition's (L211, L212) -------------------------------

# the modules under `mod`, itself first
@quarantine "a package's modules are bindings of their parents, found by Julia's reflection" Base.names function _modules(mod::Module)::Vector{Module}
    local out = Module[mod]
    for n in names(mod; all = true)
        isdefined(mod, n) || continue
        local b = getglobal(mod, n)
        b isa Module && b !== mod && parentmodule(b) === mod && append!(out, _modules(b))
    end
    return out
end

"""
    _attribute!(mod) -> Vector{Method}

Matches each method `mod` or a module under it defines to the definition whose evaluation made it,
by identity: a method a definition's entry already holds is its; any other goes to the entry,
registered in this process, whose evaluation's worlds hold the method's `primary_world`, and is
pushed to it. The matching runs while the package loads (where each definition's methods are new
worlds), so the package image keeps each entry's methods; a definition evaluated later in a session
(by Revise) is matched the same way. Returns the methods no definition made.
"""
@quarantine "a method records the world it was defined at, which identifies the definition that made it" Base.visit function _attribute!(mod::Module)::Vector{Method}
    local entries = RegistryEntry[e for e in REGISTRY if _within(e.mod, mod)]
    local held = IdSet{Method}(m for e in entries for m in e.methods)
    local here = RegistryEntry[e for e in entries if e.pid == getpid()]
    local orphans = Method[]
    Base.visit(Core.methodtable) do m
        (_within(m.module, mod) && !(m in held)) || return
        local i = findfirst(e -> m.primary_world in e.worlds, here)
        i === nothing ? push!(orphans, m) : push!(here[i].methods, m)
    end
    return orphans
end

# why a method a definition made does not lie in it, or nothing: in the definition's own file, a body
# Julia's lowering gives no location (a closure's or a generator's), or a method Julia's @enum writes
# for the enum the definition declares (in Base's Enums.jl, its signature naming that type)
@quarantine "Julia's @enum writes its methods in Base's Enums.jl; every other method lies in its definition" Base.unwrap_unionall function _misplaced(m::Method, e::RegistryEntry, src::String)::Union{String,Nothing}
    local mods = Module[getglobal(e.mod, n) for n in e.names if isdefined(e.mod, n) && getglobal(e.mod, n) isa Module]
    if !isempty(mods)
        m.name in (:eval, :include) && m.module in mods && return nothing
        return "$(m.module).$(m.name) at $(m.file):$(m.line) lies in a module's body with no mark of its own"
    end
    m.file === e.file && return nothing
    m.file === :none && startswith(string(m.name), '#') && return nothing
    if string(m.file) == "Enums.jl"
        local enums = Any[getglobal(e.mod, n) for n in e.names if isdefined(e.mod, n)]
        local mentions(t) = any(x -> x isa DataType && (t === x || (t isa DataType && t <: Type && t.parameters[1] === x)), enums)
        any(mentions, Base.unwrap_unionall(m.sig).parameters) && return nothing
    end
    return "$(m.module).$(m.name) at $(m.file):$(m.line) lies outside the definition that made it ($(relpath(string(e.file), src)):$(e.first))"
end

# the faults of `mod`'s definitions under one mark, in `src/julia` (`julia`, @quarantine) or
# elsewhere (@parity): each method made by no definition, or lying outside the one that made it, and
# each binding of `mod` or a module under it that no entry names
@quarantine "Julia's methods and bindings are reflected on, the only declaration list it keeps" Base.names function _unmarked(mod::Module, src::String, julia::Bool)::Vector{String}
    local mark = julia ? "@quarantine" : "@parity"
    local jdir = joinpath(src, "julia")
    local side(file) = _inside(string(file), jdir) == julia
    local out = String[]
    for m in _attribute!(mod)
        local f = string(m.file)
        (_inside(f, src) ? side(f) : !julia) &&
            push!(out, "$(m.module).$(m.name) at $(_inside(f, src) ? relpath(f, src) : f):$(m.line) was made by no definition carrying $mark")
    end
    local entries = RegistryEntry[e for e in REGISTRY if _within(e.mod, mod)]
    for e in entries
        side(e.file) || continue
        for m in e.methods
            local why = _misplaced(m, e, src)
            why === nothing || push!(out, why)
        end
    end
    for sub in _modules(mod)
        local named = Set{Symbol}(n for e in entries if e.mod === sub for n in e.names)
        for n in names(sub; all = true)
            (startswith(string(n), '#') || n in (:eval, :include) || n === nameof(sub) || !isdefined(sub, n)) && continue
            (which(sub, n) === sub && !(n in named)) || continue
            local b = getglobal(sub, n)
            # a package's member function, declared by the loader and defined from another of its
            # modules (`WasmBuilder.f(...)` in an ir file): made by the marked definitions of its methods
            b isa Function && any(m -> any(e -> m in e.methods, entries), methods(b)) && continue
            local files = b isa Function || b isa Type ? String[string(m.file) for m in methods(b) if m.module === sub] : String[]
            (isempty(files) || any(side, files)) && push!(out, "the binding $sub.$n carries neither @parity nor @quarantine")
        end
    end
    return out
end

"""
    check_parity(mod, src) -> Int

The anchors' check: every method `mod` or a module under it defines outside `src/julia` was made by
an `@parity` definition's evaluation and lies in it, and every binding it owns is a marked
definition's; throws a `ConstructionViolation` listing the rest.
"""
@quarantine "the anchors' totality, by reflection when the package loads" Core.throw function check_parity(mod::Module, src::String)::Int
    local out = _unmarked(mod, src, false)
    isempty(out) || throw(ConstructionViolation("parity", join(out, "; ")))
    return 0
end
@quarantine "the anchors' assertion, run when the package loads" Base.Val construction_check(::Val{:parity})::Int = check_parity(@__MODULE__, SRC)

"""
    check_quarantine(mod, src) -> Int

The quarantine's check: every method `mod` or a module under it defines in `src/julia` was made by a
`@quarantine` definition's evaluation and lies in it, and every binding it owns is a marked
definition's; throws a `ConstructionViolation` listing the rest. Each definition's Julia API was
checked where it was written: a qualified name that resolves and that the definition references.
"""
@quarantine "the quarantine's totality, by reflection when the package loads" Core.throw function check_quarantine(mod::Module, src::String)::Int
    local out = _unmarked(mod, src, true)
    isempty(out) || throw(ConstructionViolation("quarantine", join(out, "; ")))
    return 0
end
@quarantine "the quarantine's assertion, run when the package loads" Base.Val construction_check(::Val{:quarantine})::Int = check_quarantine(@__MODULE__, SRC)

# ---- typed signatures and fields (L214, L215) -----------------------------------------------------
# A ported dart definition is typed as dart types it: every parameter of its methods declared, no
# field holding Any, a field `nothing` may hold only where dart declares it `T?`. A quarantined
# definition is exempt: it carries a Julia API's own types (Julia's trim inference returns an untyped
# Vector{Any}), the named heterogeneous seam the charter allows (C4).

# whether a type mentions Any: itself, a member of a Union, a parameter of a parametric type
@quarantine "Julia's types nest Any in Unions, parameters and Varargs, found by reflection" Base.unwrap_unionall function _mentions_any(@nospecialize(T))::Bool
    T === Any && return true
    T isa Union && return any(_mentions_any, Base.uniontypes(T))
    T isa UnionAll && return _mentions_any(Base.unwrap_unionall(T))
    T isa Core.TypeofVararg && return !isdefined(T, :T) || _mentions_any(T.T)
    T isa DataType && return any(p -> (p isa Type || p isa Core.TypeofVararg) && _mentions_any(p), T.parameters)
    return false
end

"""
    check_typed_signatures(mod) -> Int

The typed signatures' check: every method of a ported `@parity` definition of `mod` (not an
`@unported` stub) declares each parameter, none untyped (`Any`), an unbounded type variable or a
bare `Vararg` (a ported struct's one inner constructor among them, @parity refusing Julia's default
constructors where it is written); throws a `ConstructionViolation` listing the rest.

precedent(typescript: noImplicitAny; dart: the always_specify_types lint). Julia's differs: an
untyped parameter is `Any`, which Julia accepts, so the load reads each method's signature.
"""
@quarantine "Julia accepts an untyped parameter as Any; the load reads every ported signature" Base.unwrap_unionall function check_typed_signatures(mod::Module)::Int
    local out = String[]
    _attribute!(mod)
    for e in REGISTRY
        e isa ParityEntry && _within(e.mod, mod) && e.ported || continue
        for m in e.methods
            (!startswith(string(m.name), '#') && m.name !== :kwcall) || continue
            local ps = Base.unwrap_unionall(m.sig).parameters
            for i in 2:length(ps)
                local p = ps[i]
                local why = p === Any ? "is untyped (Any)" :
                    p isa TypeVar && p.ub === Any ? "is an unbounded type variable" :
                    p isa Core.TypeofVararg && (!isdefined(p, :T) || p.T === Any) ? "is a bare Vararg" : nothing
                why === nothing || push!(out, "$(basename(string(m.file))):$(m.line) $(m.name)'s parameter $(i - 1) $why ($(e.anchor))")
            end
        end
    end
    isempty(out) || throw(ConstructionViolation("check_typed_signatures", join(out, "; ")))
    return 0
end
@quarantine "the typed signatures' assertion, run when the package loads" Base.Val construction_check(::Val{:check_typed_signatures})::Int = check_typed_signatures(@__MODULE__)

# why the dart class at `anchor` does not declare `field` (a Julia field name) nullable, or nothing
# when it does: a member at column 2 of the class's body declaring the field whose snake name it is,
# its type ending in `?`
@quarantine "dart's sound null safety marks a nullable field T?; Julia reads the pinned class body" Base.readlines function _dart_nullable(sdk::String, anchor::String, field::Symbol)::Union{String,Nothing}
    local a = match(ANCHOR_RX, anchor)
    local path = joinpath(sdk, "pkg", a[1])
    isfile(path) || return "the pin has no pkg/$(a[1])"
    local lines = get!(() -> readlines(path), _PIN_LINES, path)
    for j in parse(Int, a[2])+1:length(lines)
        local l = lines[j]
        startswith(l, "}") && break
        startswith(l, "  ") && !startswith(l, "   ") || continue
        for d in eachmatch(r"([^\s(]+)\s+([A-Za-z_$][\w$]*)\s*(?:;|=(?![=>]))", l)
            snake(d[2]) == string(field) || continue
            return endswith(d[1], "?") ? nothing : "dart declares $(d[2]) as $(d[1]), not nullable (line $j)"
        end
    end
    return "the dart class declares no field $(field)"
end

"""
    check_typed_fields(mod, sdk) -> Int

The typed fields' check: no field of a struct a `@parity` definition of `mod` declares holds `Any`,
anywhere in its type; a field that may hold `nothing` is one the dart class declares `T?`, read from
`sdk`, the pinned checkout, when there is one. Throws a `ConstructionViolation` listing the rest.

precedent(typescript: strictNullChecks; dart: sound null safety). Julia's differs: a field may hold
Any or nothing by its declared type alone, so the load reads each field type and the pinned class.
"""
@quarantine "Julia's field types may hold Any or nothing; the load reads every ported struct" Base.fieldtypes function check_typed_fields(mod::Module, sdk::Union{String,Nothing})::Int
    local out = String[]
    for e in REGISTRY
        e isa ParityEntry && e.declares && _within(e.mod, mod) || continue
        for n in e.names
            isdefined(e.mod, n) || continue
            local T = Base.unwrap_unionall(getglobal(e.mod, n))
            T isa DataType && isstructtype(T) && !isabstracttype(T) || continue
            for (f, F) in zip(fieldnames(T), fieldtypes(T))
                _mentions_any(F) && push!(out, "$n.$f holds Any ($F; $(e.anchor))")
                if F isa Union && Nothing <: F && sdk !== nothing
                    local why = _dart_nullable(sdk, e.anchor, f)
                    why === nothing || push!(out, "$n.$f may hold nothing, but $why ($(e.anchor))")
                end
            end
        end
    end
    empty!(_PIN_LINES)
    isempty(out) || throw(ConstructionViolation("check_typed_fields", join(out, "; ")))
    return 0
end
@quarantine "the typed fields' assertion, run when the package loads" Base.Val construction_check(::Val{:check_typed_fields})::Int = check_typed_fields(@__MODULE__, _pin_sdk())
