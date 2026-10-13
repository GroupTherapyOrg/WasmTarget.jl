# ============================================================================
# parity_ratchet.jl — the machine checks of dev/CHARTER.md, the definition of done: every
# lock and ratchet, and the per-clause status the run prints last.
#
# Makes "clean up as you go" MECHANICAL: every structural-disease metric from the
# 2026-07-01 census is counted here with a precise pattern and compared against the
# committed baseline (dev/parity_baseline.toml).
#
#   RATCHET metrics may only go DOWN.  count > baseline  ⇒  FAIL.
#   LOCKS pass only at 0.               count != 0       ⇒  FAIL (A3P9).
#   The baseline holds exactly the ratchets: a ratchet with no baseline line, or a
#   baseline key that names no ratchet                   ⇒  FAIL (A12P5).
#
# When a commit legitimately lowers a count, tighten the baseline IN THE SAME COMMIT:
#     WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl
# (update mode still FAILS on any increase — a ratchet never loosens; a ratchet at 0 becomes a
# lock by moving its definition from METRICS to LOCKS, and the baseline records ratchets only:
# update mode rewrites it with every ratchet's count, recording a new one and dropping a key
# that names none, a reviewable diff).
#
# Run standalone (seconds, exit 0/1):   julia --project=. test/parity_ratchet.jl
# Also included by runtests.jl as a @testset, on the shard its _wt_qa dealing gives it.
# ============================================================================
module ParityRatchet

# NO deps (not even stdlib TOML — the test env doesn't declare it; a `using TOML` here
# LoadError'd shard 0 inside Pkg.test). The baseline is a flat TOML-shaped file of
# `[section]` + `key = int` lines; the two 10-line helpers below read/write exactly that.

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SRC = joinpath(ROOT, "src")
const CODEGEN = joinpath(SRC, "codegen")
const BASELINE_PATH = joinpath(ROOT, "dev", "parity_baseline.toml")

_iscomment(line::AbstractString) = startswith(lstrip(line), "#")

# Minimal reader for the baseline's `[section]` / `key = int` shape (TOML-compatible subset).
function _read_baseline(path::String)::Dict{String,Dict{String,Int}}
    out = Dict{String,Dict{String,Int}}()
    isfile(path) || return out
    section = ""
    for line in eachline(path)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        if (m = match(r"^\[(\w+)\]$", s)) !== nothing
            section = m.captures[1]
            out[section] = get(out, section, Dict{String,Int}())
        # Accept TOML inline comments.  Without this, an annotated baseline entry is
        # omitted and its ratchet reported MISSING. A key before any `[section]` is kept
        # under "" so that run() reports it as naming no ratchet (A12P5).
        elseif (m = match(r"^(\w+)\s*=\s*(\d+)(?:\s+#.*)?$", s)) !== nothing
            local d = get!(out, section, Dict{String,Int}())
            # a key twice would keep its last line, so a second, larger line would loosen its
            # ratchet silently (TOML forbids it): refused, as the run refuses a STRAY key (A13P18)
            haskey(d, m.captures[1]) && error("$(path): [$(section)] $(m.captures[1]) appears twice; delete one line")
            d[m.captures[1]] = parse(Int, m.captures[2])
        end
    end
    return out
end

# the ratchets' values only: a lock's value is 0 by definition (A3P9), so none is recorded
function _write_baseline(path::String, metrics::Dict{String,Int})
    open(path, "w") do io
        println(io, "# dev/parity_baseline.toml — enforced by test/parity_ratchet.jl.")
        println(io, "# RATCHETS only: counts may only DECREASE. A lock passes only at 0 and is not recorded.")
        println(io, "# Tighten via: WT_RATCHET_UPDATE=1 julia --project=. test/parity_ratchet.jl")
        for (name, d) in (("metrics", metrics),)
            println(io, "\n[", name, "]")
            for k in sort!(collect(keys(d)))
                println(io, k, " = ", d[k])
            end
        end
    end
end

"""
Count non-comment lines in `.jl` files under `roots` matching `rx`, skipping files whose
path ends with an entry of `exclude_files` and lines matching `exclude_line` (e.g. defs).
Multiple matches on one line count once (call-SITE counting, stable + cheap).
"""
function count_sites(rx::Regex; roots=[SRC], exclude_files=String[],
                     exclude_line::Union{Regex,Nothing}=nothing)
    n = 0
    for root in roots
        for (dir, _, files) in walkdir(root), f in files
            endswith(f, ".jl") || continue
            path = joinpath(dir, f)
            # Windows: normalize separators so "codegen/values.jl" excludes match D:\...\codegen\values.jl
            _npath = replace(path, '\\' => '/')
            any(x -> endswith(_npath, x), exclude_files) && continue
            for line in eachline(path)
                _iscomment(line) && continue
                occursin(rx, line) || continue
                exclude_line !== nothing && occursin(exclude_line, line) && continue
                n += 1
            end
        end
    end
    return n
end

"""
Count every line in `.jl` files under `roots` matching `rx`, including comment lines.
Used for metrics that must count sediment like marches and narration tags.
"""
function count_lines_all(rx::Regex; roots=[SRC])
    n = 0
    for root in roots
        for (dir, _, files) in walkdir(root), f in files
            endswith(f, ".jl") || continue
            for line in eachline(joinpath(dir, f))
                occursin(rx, line) && (n += 1)
            end
        end
    end
    return n
end

"""
Return the line span of the top-level definition whose first line starts with `header`,
using Julia's own parser (keyword-counting cannot see `@inbounds for`, trailing `do`, or
one-line `if … end`). 0 if no such definition exists.
"""
function function_body_lines(path::String, header::AbstractString)::Int
    lines = readlines(path)
    start = findfirst(l -> startswith(l, header), lines)
    start === nothing && return 0
    ex = Meta.parseall(read(path, String); filename=path)
    linenos(e, acc) = (e isa LineNumberNode ? push!(acc, e.line) :
                       e isa Expr ? foreach(a -> linenos(a, acc), e.args) : nothing; acc)
    for top in ex.args
        top isa Expr || continue
        ls = linenos(top, Int[])
        isempty(ls) && continue
        # a docstring makes the top-level expression begin before the header line
        minimum(ls) <= start <= maximum(ls) && return maximum(ls) - start + 1
    end
    return 0
end

# ---- R30/R31 (Phase 12.I): parser-based, not regex-based ---------------------
# Both walk Meta.parseall's AST rather than grep patterns: a return-type
# annotation or a field's declared type can span lines, hide behind a `where`
# clause, or sit inside a macrocall — none of which a line-oriented regex sees
# reliably. Shared by R30 and R31 below.

"""`where T` clauses wrap the real call/`::` signature; strip them to get at it."""
function _strip_where(sig)
    while sig isa Expr && sig.head === :where
        sig = sig.args[1]
    end
    return sig
end

"""The name expr in call position of a (`where`-stripped) signature, or `nothing`
if `sig` isn't a `::`-annotated or bare call signature at all (e.g. an anonymous
`function (x) … end`, whose sig is a bare tuple/arg list)."""
function _sig_call_name(sig)
    core = _strip_where(sig)
    if core isa Expr && core.head === :(::) && length(core.args) == 2
        core = core.args[1]
    end
    (core isa Expr && core.head === :call) || return nothing
    return core.args[1]
end

"""A named call signature: `f(...)`, `Mod.f(...)`, or `Foo{T}(...)` — as opposed
to a functor/anonymous signature (`(c::Closure)(x)`, `function (x) … end`)."""
function _is_named_call_sig(sig)::Bool
    name = _sig_call_name(sig)
    return name isa Symbol || (name isa Expr && (name.head === :(.) || name.head === :curly))
end

"""Does the (`where`-stripped) signature carry a `::T` return-type annotation?"""
_has_return_annotation(sig) = sig isa Expr && sig.head === :(::) && length(sig.args) == 2

"""
The definitions whose `::Any` return is a named heterogeneous seam (dev/CHARTER.md C4: no
`Any` outside named seams), by function name, each with why its value is open by
construction. Any other `::Any` return counts in R30 as untyped.
"""
const R30_ANY_SEAMS = Dict{Symbol,String}(
    :_resolve_nircall_callee => "a call's callee resolved to its object: a function, a type or any callable value",
    :_nir_callee_object => "a callee operand's object: a function, a type or any callable value",
    :resolve_call_callee => "a :call's callee resolved to its object, or the operand of a dynamic callee",
    :nir_callee => "a callee operand resolved to its one representation: a constant's object, an unbound GlobalRef or a runtime value's node",
    :nir_operand_callee => "a callee operand resolved by the one rule over its static type: a constant's object, an unbound GlobalRef, a singleton's instance or a runtime value's node",
    :nir_const => "a literal operand's value, any Julia value",
    :_nir_const_operand => "a constant operand's value, any Julia value",
    :_nir_field_name => "a getfield operand's literal, whatever the IR wrote there",
    :_runtime_composition_apply => "a runtime composition returns whatever its last function returns",
)

"""
Count `function f(...)`/`f(...) = ...` definitions under `roots` with no `::T`
return-type annotation. Walks Meta.parseall's AST rather than lines, so a
signature split across lines or wrapped in `where`/a macrocall (`@inline`) is
still seen correctly. Excluded, structurally (not by name-list):
  - a definition nested inside another counted definition's body — a closure,
    whose return type isn't part of any public signature;
  - an anonymous/functor signature (`function (x) … end`, `(c::Closure)(x)`)
    — there is no name to attach an annotation to;
  - a qualified extension of another module's method (`Base.show`, dart's
    `CC.abstract_apply`, …) — the return type is the interface's contract,
    not WasmTarget's to annotate (still recursed into, to exclude any
    closures defined inside it).
"""
function count_untyped_returns(roots::Vector{String})::Int
    n = 0
    for root in roots
        isdir(root) || continue
        for (dir, _, files) in walkdir(root), f in files
            endswith(f, ".jl") || continue
            path = joinpath(dir, f)
            local ex
            try
                ex = Meta.parseall(read(path, String); filename=path)
            catch
                continue
            end
            n += _count_untyped_returns_in(ex, false)
        end
    end
    return n
end

function _count_untyped_returns_in(ex, in_fn::Bool)::Int
    ex isa Expr || return 0
    is_def = ex.head === :function ||
             (ex.head === :(=) && length(ex.args) == 2 && ex.args[1] isa Expr &&
              (ex.args[1].head === :call || ex.args[1].head === :where ||
               (ex.args[1].head === :(::) && ex.args[1].args[1] isa Expr &&
                (ex.args[1].args[1].head === :call || ex.args[1].args[1].head === :where))))
    if is_def
        in_fn && return 0   # nested definition = closure — excluded, don't recurse further
        sig = ex.args[1]
        _is_named_call_sig(sig) || return 0   # anonymous/functor — excluded
        body = length(ex.args) >= 2 ? ex.args[2] : nothing
        name = _sig_call_name(sig)
        if name isa Expr && name.head === :(.)   # qualified extension — interface's contract
            return body === nothing ? 0 : _count_untyped_returns_in(body, true)
        end
        below = body === nothing ? 0 : _count_untyped_returns_in(body, true)
        local core = _strip_where(sig)
        typed = _has_return_annotation(core) &&
                (core.args[2] !== :Any || (name isa Symbol && haskey(R30_ANY_SEAMS, name)))
        return (typed ? 0 : 1) + below
    end
    return sum(a -> _count_untyped_returns_in(a, in_fn), ex.args; init=0)
end

"""Does the field-type expr `t` contain the symbol `Any` — as itself, or nested
inside a parametric type (`Dict{Any,V}`, `Vector{Any}`, `Union{Nothing,Any}`)?
A `Dict{Any,V}` seam is exactly as open as a literal `::Any` field: there is no
fixed key type either way."""
function _type_mentions_any(t)::Bool
    t === :Any && return true
    t isa Expr || return false
    t.head === :curly && return any(_type_mentions_any, t.args)
    t.head === :where && return _type_mentions_any(t.args[1])
    return false
end

"""Extract `(fieldname::Symbol, type_expr_or_nothing)` from one element of a
struct body, or `nothing` if `el` isn't a field decl at all (an inner
constructor, a macro call, a docstring). `nothing` for the type means bare
`field` — untyped, implicitly `Any`. Unwraps `Base.@kwdef`'s `field::T =
default` down to `field::T`."""
function _field_decl(el)
    el isa Symbol && return (el, nothing)
    el isa Expr || return nothing
    if el.head === :(::) && length(el.args) == 2 && el.args[1] isa Symbol
        return (el.args[1], el.args[2])
    end
    el.head === :(=) && length(el.args) == 2 && return _field_decl(el.args[1])
    return nothing
end

# R31's allowlist: named heterogeneous seams where the field genuinely cannot
# carry a fixed type, each with a one-line reason. (struct, field) => skip.
const R31_ALLOWLIST = Set{Tuple{Symbol,Symbol}}([
    (:WasmDiagnostic, :detail),         # the raw Expr/MethodInstance/Type a diagnostic points at — open by construction
    (:WasmInternalError, :cause),       # the value a codegen bug threw — Julia can throw any value
    (:NirGlobalRef, :value),            # a bound global's value — as open as a literal's
    (:NirUnsupported, :raw),            # the raw IR node the boundary could not classify — open by construction
    (:CompilationContext, :func_ref),   # the function being compiled — anything callable, as FunctionInfo.func_ref
    (:CompilationContext, :captured_constant_fields),  # a closure's captured constants, by field — open values
    (:RootBindings, :captured_constants),              # an entry closure's captured constants, by name — open values
    (:RootBindings, :bound_leaves),     # (callable, argument types) of a bound leaf — the callable is open
    (:TypeRegistry, :constant_globals),                # constants.dart's constant map: a constant is any value
    (:TypeRegistry, :mutable_constant_globals),        # the same, for a mutable constant (by identity)
    (:NirLiteral, :value),              # a Julia literal's runtime value — literals are open
    (:NirCall, :callee),                # the callee object (Function/Type/Builtin) — callees are open
    (:NirInvoke, :callee),              # ditto: an :invoke's own callee operand, which is a
                                        # NirNode when a closure VALUE is invoked
    (:FunctionInfo, :func_ref),         # the registries' Function values — holds a Function, Type, or Builtin (anything callable)
    (:FunctionRegistry, :by_ref),       # keyed by the same open func_ref
    (:DispatchTable, :func_ref),        # DispatchTableRegistry's func_ref keys — same "anything callable" seam
    (:DispatchTableRegistry, :tables),
    (:DispatchTableRegistry, :selector_axis),
    (:DispatchTableRegistry, :selector_offset),
    (:DispatchTableRegistry, :selector_positions),
    (:DispatchTableRegistry, :selector_cascades),
    (:WasmInterpreter, :layout_reads),  # the host-layout memo, keyed by a specialization's specTypes or its CodeInstance (ir_reads_host_layout's key) — open by construction
    (:Translator, :constants_in_progress),  # the constant objects being emitted (cycle and depth guard) — any constant value
    (:WasmInterpreter, :cache_token),   # Core.Compiler's AbstractInterpreter cache-owner token — the @nospecialize'd interface leaves its type open
    (:ClosedWorld, :codeinfos),         # Core.Compiler.compile!'s output as it hands it: CodeInstance, CodeInfo alternating in a Vector{Any}
    (:ClosedWorldPlan, :functions),     # (callable, argument types, name, MethodInstance) — the callable is open, as FunctionInfo.func_ref
    (:ClosedWorldPlan, :external_leaves),  # (callable, argument types, MethodInstance) of each declared import — the callable is open, as FunctionInfo.func_ref
])

"""
Count `struct`/`mutable struct` fields anywhere in `src` that are `::Any`,
untyped, or `Any`-parametric (`Dict{Any,V}`), minus R31_ALLOWLIST's named
seams. Parser-based (Meta.parseall): a field's type can span lines or sit
behind `Base.@kwdef`'s `= default`, which a regex would misread as a value
assignment rather than a field declaration.
"""
function count_any_typed_fields()::Int
    n = 0
    for (dir, _, files) in walkdir(SRC), f in files
        endswith(f, ".jl") || continue
        path = joinpath(dir, f)
        local ex
        try
            ex = Meta.parseall(read(path, String); filename=path)
        catch
            continue
        end
        n += _count_any_fields_in(ex)
    end
    return n
end

function _count_any_fields_in(ex)::Int
    ex isa Expr || return 0
    n = 0
    if ex.head === :struct
        name_expr = ex.args[2]
        sname = Symbol(name_expr isa Expr ? name_expr.args[1] : name_expr)
        block = ex.args[3]
        if block isa Expr && block.head === :block
            for el in block.args
                decl = _field_decl(el)
                decl === nothing && continue
                fname, ftype = decl
                (ftype === nothing || _type_mentions_any(ftype)) || continue
                (sname, fname) in R31_ALLOWLIST && continue
                n += 1
            end
        end
    end
    for a in ex.args
        n += _count_any_fields_in(a)
    end
    return n
end

# Prose files are read line-ending-agnostic: a Windows checkout may carry CRLF, and a check
# that silently parses nothing there is a check that silently passes or fails by platform.
_text(path::String)::String = replace(read(path, String), "\r\n" => "\n")
_lines(path::String)::Vector{String} = String.(split(chomp(_text(path)), '\n'))

# ---- dev/CHARTER.md support --------------------------------------------------
const CHARTER_PATH = joinpath(ROOT, "dev", "CHARTER.md")

# ---- R32: every definition carries its dart anchor or quarantine (dev/CHARTER.md C2) ----
# Counted on the PARSED syntax tree, one entry per definition — every method separately, so an
# anchored dart-shaped method never hides an invented method of the same name. A definition is
# anchored when its docstring (read from the tree, not by scanning lines) or the contiguous
# comment block directly above it contains `parity(`, or it lies inside a
# `# parity-region(...)` … `# end parity-region` block.

const _DEF_WRAPPERS = (Symbol("@inline"), Symbol("@noinline"), Symbol("@generated"),
                       Symbol("@nospecialize"), Symbol("@assume_effects"), Symbol("@propagate_inbounds"))

_macroname(x) = x isa Symbol ? x : x isa GlobalRef ? x.name :
                (x isa Expr && x.head === :. ? _macroname(x.args[end]) : x isa QuoteNode ? x.value : nothing)

"""The name a top-level definition defines, or `nothing` when `ex` is not a definition."""
function _def_name(ex)::Union{Nothing,String}
    ex isa Expr || return nothing
    h = ex.head
    callname(c) = c isa Expr && c.head === :where ? callname(c.args[1]) :
                  c isa Expr && c.head === :(::) && length(c.args) == 2 ? callname(c.args[1]) :
                  c isa Expr && c.head === :call ? string(c.args[1]) : nothing
    typename(t) = t isa Symbol ? string(t) : t isa Expr && t.head in (:<:, :curly) ? typename(t.args[1]) : string(t)
    h === :function && return length(ex.args) >= 1 ? something(callname(ex.args[1]), string(ex.args[1])) : nothing
    h === :(=) && return callname(ex.args[1])
    h === :struct && return typename(ex.args[2])
    h in (:abstract, :primitive) && return typename(ex.args[1])
    h === :macro && return "@" * something(callname(ex.args[1]), "?")
    h === :const && ex.args[1] isa Expr && ex.args[1].head === :(=) &&
        return string(ex.args[1].args[1] isa Expr ? ex.args[1].args[1].args[1] : ex.args[1].args[1])
    return nothing
end

"""
Every top-level definition in one source file as `(name, line, anchored)`. Descends through
`module`, `begin`/`toplevel` blocks and `if` bodies (a conditionally defined method is still a
definition), and through docstring and annotation macros (`@inline`, …) to the definition.
"""
function toplevel_definitions(path::String)::Vector{Tuple{String,Int,Bool}}
    src = _text(path)
    lines = split(src, '\n')
    regions = falses(length(lines) + 1)
    inreg = false
    for (i, l) in enumerate(lines)
        startswith(l, "# parity-region(") && (inreg = true)
        startswith(l, "# end parity-region") && (inreg = false)
        regions[i] = inreg
    end
    comment_anchor(line) = begin   # contiguous comment block directly above `line`
        j = line - 1; found = false
        while j >= 1 && startswith(lstrip(lines[j]), "#")
            occursin("parity(", lines[j]) && (found = true); j -= 1
        end
        found
    end
    out = Tuple{String,Int,Bool}[]
    function visit(ex, line::Int)
        ex isa Expr || return
        if ex.head in (:toplevel, :block, :module)
            body = ex.head === :module ? ex.args[3].args : ex.args
            l = line
            for a in body
                a isa LineNumberNode ? (l = a.line) : visit(a, l)
            end
            return
        end
        if ex.head === :if || ex.head === :elseif
            foreach(a -> visit(a, line), ex.args[2:end])
            return
        end
        doc = ""
        d = ex
        while d isa Expr && d.head === :macrocall
            m = _macroname(d.args[1])
            if m === Symbol("@doc")
                doc *= string(d.args[3]); d = d.args[4]
            elseif m in _DEF_WRAPPERS
                d = d.args[end]
            else
                break
            end
        end
        name = _def_name(d)
        name === nothing && return
        anchored = occursin("parity(", doc) || comment_anchor(line) || regions[line]
        push!(out, (name, line, anchored))
    end
    visit(Meta.parseall(src; filename=path), 1)
    return out
end

"""
Bare string literals among the top-level statements of `src` — each is a docstring cut off from
its definition (a comment line between a docstring and its definition detaches it) or prose
with no definition under it. Either way the documentation is attached to nothing: stale by
construction (dev/CHARTER.md C9). Counted on the parsed syntax tree.
"""
function count_detached_docstrings(root::String=SRC)::Int
    n = 0
    function visit(ex)
        ex isa Expr || return
        if ex.head in (:toplevel, :module, :block)
            body = ex.head === :module ? ex.args[3].args : ex.args
            for a in body
                a isa String ? (n += 1) : visit(a)
            end
        end
    end
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") && visit(Meta.parseall(_text(joinpath(dir, f)); filename=f))
    end
    return n
end

"""The top-level definitions in `src/` with no `parity(` anchor — dev/CHARTER.md C2."""
function count_unanchored_definitions(root::String=SRC)::Int
    n = 0
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        n += count(d -> !d[3], toplevel_definitions(joinpath(dir, f)))
    end
    return n
end

"""
Catch clauses in `src` whose handler swallows the failure — it neither rethrows, throws,
errors, nor records a located diagnostic (record_unsupported!/emit_unsupported_stub!/
WasmInternalError/WasmCompileError). dev/CHARTER.md C6: a failure is correct or loud, never a
silent default. Counted on the parsed AST (Expr(:try, body, var, handler)), not by regex.
"""
function count_silent_catches(root::String=SRC)::Int
    loud = r"\brethrow\b|\bthrow\(|\berror\(|record_unsupported!|emit_unsupported_stub!|WasmInternalError|WasmCompileError"
    n = 0
    walk(x) = x isa Expr ? (x.head === :try && length(x.args) >= 3 && x.args[3] !== false &&
                            !occursin(loud, string(x.args[3])) && (n += 1);
                            foreach(walk, x.args)) : nothing
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        walk(Meta.parseall(read(joinpath(dir, f), String); filename=f))
    end
    return n
end

"""
The `emit_value!` calls under `root` that name no expected type (three positional
arguments), as `(file, line, source line)`. dart2wasm has exactly one such emission: the
visitor call inside `translateExpression` (code_generator.dart:676 `node.accept1(this,
expectedType)`), which is `emit_value!(b, val, ctx)` in the body of the 4-argument
`emit_value!`; that one call is not listed. Walks Meta.parseall's AST, so a call with nested
parentheses, keywords or several lines is found like any other (R17, L35).
"""
function untyped_value_emissions(root::String=CODEGEN)::Vector{Tuple{String,Int,String}}
    out = Tuple{String,Int,String}[]
    positional(ex) = [a for a in ex.args[2:end] if !(a isa Expr && a.head in (:parameters, :kw))]
    for (dir, _, files) in walkdir(root), f in sort(files)
        endswith(f, ".jl") || continue
        path = joinpath(dir, f)
        lines = readlines(path)
        claimed = Set{Int}()
        line = Ref(0)
        function visit(ex, in_funnel::Bool)
            if ex isa LineNumberNode
                line[] = ex.line
            elseif ex isa Expr
                if ex.head === :call && ex.args[1] === :emit_value!
                    pos = positional(ex)
                    if length(pos) == 3 && !(in_funnel && pos == Any[:b, :val, :ctx])
                        needle = "emit_value!(" * string(pos[1])
                        at = findfirst(k -> k >= line[] && !(k in claimed) &&
                                            occursin(needle, lines[k]), eachindex(lines))
                        at === nothing && (at = line[])
                        push!(claimed, at)
                        push!(out, (f, at, strip(lines[at])))
                    end
                end
                if ex.head === :function || (ex.head === :(=) && ex.args[1] isa Expr &&
                                             ex.args[1].head in (:call, :where))
                    sig = _strip_where(ex.args[1])
                    sig isa Expr && sig.head === :(::) && (sig = sig.args[1])
                    funnel = sig isa Expr && sig.head === :call && sig.args[1] === :emit_value! &&
                             length(positional(sig)) == 4
                    for a in ex.args[2:end]
                        visit(a, funnel)
                    end
                    return
                end
                foreach(a -> visit(a, in_funnel), ex.args)
            end
        end
        visit(Meta.parseall(read(path, String); filename=path), false)
    end
    return out
end


# ── R40: process-global compile state (dev/MARCH.md 13.7) ──
# module-level mutable state in src/: a Ref, RefValue or TaskLocalRef, or a container
# constructed empty and filled at run time. Each allowed one is named here exactly, with why it
# is not one compilation's state; an entry that no longer names a definition counts too.
const R40_ALLOWED_PROCESS_STATE = Dict{String,String}(
    "codegen/builtins.jl BUILTIN_LOWERINGS" =>
        "the lowering registry: filled at load by each @builtin_lowering, read-only after (dart's intrinsic tables, intrinsics.dart, are static)",
    "bridge.jl _DESC_CACHE" => "the host bridge's memo of descriptor(T), a pure function of T",
    "bridge.jl _FN_CACHE" => "the host bridge's memo of each type's generated accessor functions",
    "bridge.jl _ARG_CACHE" => "the host bridge's memo of each argument type's converter")

function process_global_state_sites()::Vector{String}
    local rx = r"^const (\w+)(?:::[^=]+)? = (?:(?:Base\.)?(?:Ref|RefValue|TaskLocalRef)\b|(?:Vector|Dict|IdDict|Set|WeakKeyDict)\{.*\}\(\)\s*$)"
    local found = String[]
    for (dir, _, files) in walkdir(SRC), f in files
        endswith(f, ".jl") || continue
        local path = joinpath(dir, f)
        local rel = replace(relpath(path, SRC), '\\' => '/')
        for l in eachline(path)
            local m = match(rx, l)
            m === nothing || push!(found, rel * " " * m.captures[1])
        end
    end
    local bad = String[s for s in found if !haskey(R40_ALLOWED_PROCESS_STATE, s)]
    for k in keys(R40_ALLOWED_PROCESS_STATE)
        k in found || push!(bad, "stale allowlist entry: " * k)
    end
    return sort!(bad)
end

"""
The smoke xfails that compile and then fail when they run: the entries of test/smoke.jl's
XFAIL_RUNTIME (a wrong value, a trap, or a result the harness cannot read back). The table
is static; smoke's xfail lane measures every case and fails when the table disagrees.
"""
function smoke_runtime_xfails()::Int
    src = _text(joinpath(ROOT, "test", "smoke.jl"))
    m = match(r"const XFAIL_RUNTIME = Dict\{String,Symbol\}\((.*?)\n\)"s, src)
    m === nothing && error("R39: test/smoke.jl has no XFAIL_RUNTIME table")
    return count(l -> occursin(r"^\s*\"[^\"]+/[^\"]+\" => :(wrong|trap|unreadable),", l),
                 split(m.captures[1], '\n'))
end

"""
    overlays_without_reason() -> Vector{String}

Every `@overlay …WASM_METHOD_TABLE` definition in src and ext whose line, the comment lines
directly above it, or the docstring directly above it carries no `parity(` anchor
(dev/CHARTER.md C3): an overlay replaces Julia's own body, so it either goes (Julia's body
compiles) or states why Julia's body cannot.
"""
function overlays_without_reason()::Vector{String}
    bad = String[]
    paths = [joinpath(d, f) for root in (SRC, joinpath(ROOT, "ext")) for (d, _, fs) in walkdir(root)
             for f in fs if endswith(f, ".jl")]
    for path in paths
        L = _lines(path)
        for (i, l) in enumerate(L)
            # any macro prefix (`@noinline @overlay …`) and any spelling of the table (the
            # WMT alias) is still an overlay
            occursin(r"^\s*(?:@\w+\s+)*@overlay\s+\S+\s", l) || continue
            ok = occursin("parity(", l)
            j = i - 1
            while !ok && j >= 1 && startswith(strip(L[j]), "#")
                ok = occursin("parity(", L[j]); j -= 1
            end
            if !ok && j >= 1 && endswith(strip(L[j]), "\"\"\"")
                k = j - 1
                while k >= 1 && !occursin("\"\"\"", L[k])
                    ok = ok || occursin("parity(", L[k]); k -= 1
                end
                ok = ok || (k >= 1 && occursin("parity(", L[k]))
            end
            ok || push!(bad, "$(relpath(path, ROOT)):$i")
        end
    end
    return bad
end

"""
    unresolved_dart_anchors() -> Vector{String}

Every `parity(<file>.dart:<line> <Symbol>)` anchor in src against dart-lang/sdk at the commit
pinned in dev/PARITY_MASTER.md (dev/CHARTER.md C2): the file exists (a path is relative to
pkg/dart2wasm/lib unless it names its package or sdk/lib), the line exists, and it names the
cited symbol (its last dotted component). The sources are read from `WT_DART_SDK`, else
~/.cache/wasmtarget/dart-sdk (`bash dev/fetch_dart_sdk.sh` fetches exactly the cited files);
no checkout at the pinned commit is one violation — the check never skips.
"""
function unresolved_dart_anchors()::Vector{String}
    pin = match(r"[0-9a-f]{40}", _text(joinpath(ROOT, "dev", "PARITY_MASTER.md"))).match
    sdk = get(ENV, "WT_DART_SDK", joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk"))
    head = isdir(sdk) ? readchomp(ignorestatus(`git -C $sdk rev-parse HEAD`)) : ""
    head == pin || return ["no dart-lang/sdk checkout at $pin in $sdk: run `bash dev/fetch_dart_sdk.sh`"]
    rx = r"parity(?:-region)?\(([A-Za-z0-9_/.\-]+\.dart):(\d+)(?:-\d+)?\s+([A-Za-z_$][A-Za-z0-9_$.]*)"
    lines = Dict{String,Vector{String}}()
    bad = String[]
    for (d, _, fs) in walkdir(SRC), f in fs
        endswith(f, ".jl") || continue
        path = joinpath(d, f)
        for (ln, l) in enumerate(_lines(path)), m in eachmatch(rx, l)
            cited, line, sym = m.captures[1], parse(Int, m.captures[2]), m.captures[3]
            rel = startswith(cited, "pkg/") || startswith(cited, "sdk/") ? cited : "pkg/dart2wasm/lib/" * cited
            src = joinpath(sdk, rel)
            where = "$(relpath(path, ROOT)):$ln $(m.match)"
            isfile(src) || (push!(bad, "no file: $where"); continue)
            text = get!(() -> _lines(src), lines, src)
            line <= length(text) || (push!(bad, "no line: $where"); continue)
            occursin(split(sym, '.')[end], text[line]) || push!(bad, "line does not name the symbol: $where")
        end
    end
    return bad
end

"""
    unconsumed_files_outside_src() -> Vector{String}

Tracked files outside `src/` that nothing consumes (dev/CHARTER.md C9): a file is consumed
when a tracked file that is not prose names it (a `.md` only by its full path; the plan,
the history and the changelog name files without consuming them), when a loader walks its
directory, or when it is a repository convention file or a directory's README. A fuzz-ledger
gap marked `status: fixed` records finished work and counts too.
"""
function unconsumed_files_outside_src()::Vector{String}
    convention = Set(["Project.toml", "LICENSE.md", "CHANGELOG.md", "AGENTS.md",
        ".gitignore", ".gitattributes", "release-please-config.json",
        ".release-please-manifest.json", "docs/Project.toml", "docs/input.css"])
    # directories a loader walks, each with the files that loader consumes: run_tlc.sh (the
    # models and their instances), the docs site's file routing, the fuzz ledger and corpus,
    # Pkg's [extensions], GitHub Actions. Anything else in them is consumed by nothing.
    walked = ("dev/formal/" => r"\.(tla|cfg)$", "docs/src/" => r"", "test/fuzz/failures/" => r"",
              "test/fuzz/corpus/" => r"", "ext/" => r"\.jl$", ".github/workflows/" => r"\.ya?ml$")
    not_consumers = Set(["dev/MARCH.md", "dev/HISTORY.md", "CHANGELOG.md"])
    files = String.(split(readchomp(Cmd(`git ls-files`; dir=ROOT)), '\n'))
    texts = Dict(f => _text(joinpath(ROOT, f)) for f in files
                 if !(f in not_consumers) && isfile(joinpath(ROOT, f)))
    bad = String[]
    for f in files
        startswith(f, "src/") && continue
        (f in convention || basename(f) == "README.md" ||
         any(((d, rx),) -> startswith(f, d) && occursin(rx, f), walked)) && continue
        needle = endswith(f, ".md") ? f : basename(f)
        any(((g, t),) -> g != f && !endswith(g, ".md") && occursin(needle, t), texts) || push!(bad, f)
    end
    for f in files
        startswith(f, "test/fuzz/failures/") && isfile(joinpath(ROOT, f)) &&
            occursin(r"^status: fixed"m, _text(joinpath(ROOT, f))) && push!(bad, f)
    end
    return bad
end

"""
    components_without_model() -> Vector{String}

dev/formal/README.md's Components table against src (dev/CHARTER.md C8): a modeled row whose
model file is missing or whose model no file it names anchors (`formal(dev/formal/<M>.tla)`),
an unmodeled row with no reason, a `formal(` anchor in src whose model has no row, and a
function holding a worklist or fixpoint loop (`while changed|verifying|true|!isempty`) that
no row names.
"""
function components_without_model()::Vector{String}
    readme = _text(joinpath(ROOT, "dev", "formal", "README.md"))
    rows = [strip.(split(strip(l), '|')[2:end-1]) for l in split(readme, '\n')
            if startswith(l, "| ") && !startswith(l, "| Component") && count('|', l) == 4]
    srcfiles = [joinpath(d, f) for (d, _, fs) in walkdir(SRC) for f in fs if endswith(f, ".jl")]
    text = Dict(f => _text(f) for f in srcfiles)
    bad = String[]
    listed = Set{String}()
    tablemodels = Set{String}()
    for (comp, fns, model) in rows
        union!(listed, [m.captures[1] for m in eachmatch(r"`([A-Za-z_!0-9]+)`", fns)])
        if startswith(model, "—")
            # an algorithmic component with no model yet counts: C8 says every one carries a
            # model. Only a row stating that there is no algorithmic claim to check (an
            # encoding, a one-statement rule, a predicate list) stands on its reason.
            occursin(r"—\s*\S", model) || push!(bad, "row without a reason: $comp")
            occursin(r"^—\s*none yet", model) && push!(bad, "no model yet: $comp")
            continue
        end
        push!(tablemodels, model)
        isfile(joinpath(ROOT, "dev", "formal", model * ".tla")) || push!(bad, "no model file: $model")
        files = [m.captures[1] for m in eachmatch(r"\(([a-z_]+\.jl)\)", fns)]
        isempty(files) || any(f -> any(p -> basename(p) == f &&
                                        occursin("formal(dev/formal/$model.tla)", text[p]), srcfiles), files) ||
            push!(bad, "no formal( anchor for $model in $(join(files, ", "))")
    end
    for (p, t) in text, m in eachmatch(r"formal\(dev/formal/([A-Za-z0-9_]+)\.tla\)", t)
        m.captures[1] in tablemodels || push!(bad, "anchor with no row: $(m.captures[1]) in $(relpath(p, ROOT))")
    end
    for (p, t) in text
        cur = nothing
        for l in split(t, '\n')
            # a definition under macros counts too: `@inline function`, `@noinline @overlay T function`
            mm = match(r"^(?:    )?(?:@[\w.]+\s+(?:[A-Z][\w.]*\s+)?)*function ([A-Za-z_!0-9.]+)\(", l)
            mm === nothing || (cur = mm.captures[1])
            if cur !== nothing && occursin(r"\bwhile (changed|verifying|true\b|!isempty)", l) && !(cur in listed)
                push!(bad, "fixpoint with no row: $cur ($(basename(p)))"); cur = nothing
            end
        end
    end
    return unique(bad)
end

"""
Why AGENTS.md is not current and lean — dev/CHARTER.md C0. It is the one agent-instructions
file (a CLAUDE.md beside it is a second, drifting copy); it holds only timeless rules and
pointers, so it is short, everything it names exists, and it carries no status vocabulary
(dates, phase names, "currently"/"as of"/"remaining" — status lives in dev/MARCH.md and in
this harness's output, where it is measured instead of remembered).
"""
function agents_md_violations()::Vector{String}
    v = String[]
    isfile(joinpath(ROOT, "CLAUDE.md")) && push!(v, "CLAUDE.md exists — AGENTS.md is the one instructions file")
    path = joinpath(ROOT, "AGENTS.md")
    isfile(path) || return push!(v, "AGENTS.md is missing")
    lines = _lines(path)
    length(lines) <= 90 || push!(v, "AGENTS.md has $(length(lines)) lines (cap 90)")
    for (i, l) in enumerate(lines)
        length(l) <= 100 || push!(v, "AGENTS.md:$i is $(length(l)) chars (cap 100)")
        for m in eachmatch(r"\b20\d\d-\d\d\b|\bPhase \d+|\b(?:currently|as of|remaining|so far|recently|TODO|FIXME)\b"i, l)
            push!(v, "AGENTS.md:$i status vocabulary: \"$(m.match)\"")
        end
    end
    txt = _text(path)
    for m in eachmatch(r"(?<![\w/.])((?:src|test|dev|ext|docs|\.github)/[\w./*-]*[\w/])", txt)
        p = m.captures[1]
        occursin('*', p) && continue
        (isfile(joinpath(ROOT, p)) || isdir(joinpath(ROOT, p))) || push!(v, "AGENTS.md names $p, which does not exist")
    end
    ids = Set(_short_id(first(q)) for q in vcat(METRICS, LOCKS))
    for m in eachmatch(r"\b([LR]\d+[a-z]?)\b", txt)
        m.captures[1] in ids || push!(v, "AGENTS.md cites $(m.captures[1]), which is no check")
    end
    corpus = join((read(joinpath(d, f), String) for root in (SRC, joinpath(ROOT, "test"), joinpath(ROOT, "dev"))
                   for (d, _, fs) in walkdir(root) for f in fs if endswith(f, ".jl") || endswith(f, ".sh")), "\n")
    for m in eachmatch(r"\b(WT_[A-Z_]+)\b", txt)
        occursin(m.captures[1], corpus) || push!(v, "AGENTS.md names $(m.captures[1]), which nothing reads")
    end
    pm = match(r"\b([0-9a-f]{40})\b", _text(joinpath(ROOT, "dev", "PARITY_MASTER.md")))
    for m in eachmatch(r"\b([0-9a-f]{40})\b", txt)
        (pm !== nothing && m.captures[1] == pm.captures[1]) || push!(v, "AGENTS.md pins $(m.captures[1][1:8]), dev/PARITY_MASTER.md does not")
    end
    return v
end

"""The clauses of dev/CHARTER.md: clause id => (text, cited short check ids like "L110"/"R29a")."""
function charter_clauses()::Vector{Pair{String,Tuple{String,Vector{String}}}}
    out = Pair{String,Tuple{String,Vector{String}}}[]
    isfile(CHARTER_PATH) || return out
    txt = _text(CHARTER_PATH)
    sec = match(r"## The clauses\n(.*?)\n## "s, txt)
    sec === nothing && return out
    for m in eachmatch(r"^- \*\*(C\d+) ·(.*?)(?=^- \*\*C\d+ ·|\z)"ms, sec.captures[1])
        body = m.captures[2]
        push!(out, m.captures[1] => (body, [c.captures[1] for c in eachmatch(r"`([LR]\d+[a-z]?)`", body)]))
    end
    return out
end

_short_id(id::AbstractString) = (m = match(r"^([LR]\d+[a-z]?)_", id); m === nothing ? String(id) : String(m.captures[1]))

# The one function in src/codegen/ir.jl that may read a raw CodeInfo / CodeInstance source:
# the NIR boundary's input (the typed-IR JSON transport is deleted).
const IR_RAW_READERS = Set([
    "get_typed_ir",
])

"""Matches of `pattern` in src/codegen/ir.jl outside the bodies of the IR_RAW_READERS
functions, docstrings and `#` comments excluded: a raw IR reader ir.jl gains that is not on
the list is counted."""
function _ir_raw_reads_outside_allowlist(pattern::Regex)::Int
    n = 0
    current = nothing          # the top-level function whose body we are in
    in_doc = false
    for line in eachline(joinpath(CODEGEN, "ir.jl"))
        if in_doc
            occursin("\"\"\"", line) && (in_doc = false)
            continue
        end
        if startswith(lstrip(line), "\"\"\"")
            count("\"\"\"", line) >= 2 || (in_doc = true)
            continue
        end
        startswith(lstrip(line), "#") && continue
        if !isempty(line) && !isspace(line[1])      # a top-level line opens or closes a scope
            m = match(r"^function ([\w!]+)\(", line)
            m === nothing && (m = match(r"^([\w!]+)\(.*\)(::\S+)?\s*=", line))
            current = m === nothing ? (line == "end" ? current : nothing) : m.captures[1]
        end
        (current !== nothing && current in IR_RAW_READERS) ||
            (n += length(collect(eachmatch(pattern, line))))
        line == "end" && (current = nothing)
    end
    return n
end

# ---- METRIC DEFINITIONS (baselines live in dev/parity_baseline.toml) --------
# Each entry: id => (description, thunk). Patterns deliberately exclude the
# definition line (`function name`) so they count CALLERS.
const METRICS = [
    "R5_julia_type_reguess" => ("get_concrete_wasm_type( callers — each site either declares a storage type (dart translateType, translator.dart:1044) or re-derives the type of a value already emitted. Terminal state 0: declaring sites move to an exact per-site allowlist with their dart anchor (dev/CHARTER.md C9, rule 2)",
        () -> count_sites(r"get_concrete_wasm_type\("; exclude_line=r"function get_concrete_wasm_type\(")),
    "R7_raw_coercion_ops" => ("numeric-coercion opcodes outside values.jl's convert_type! funnel (dart convertType, translator.dart:1597). Terminal state 0 (dev/CHARTER.md C1/C9)",
        () -> count_sites(r"I32_WRAP_I64|I64_EXTEND_I32_S|I64_EXTEND_I32_U|I64_TRUNC_F|I32_TRUNC_F|F64_CONVERT_I|F32_CONVERT_I|F32_DEMOTE_F64|F64_PROMOTE_F32";
                          roots=[CODEGEN], exclude_files=["values.jl", "intrinsics_table.jl", "julia_numeric_tier.jl"])),
    # ── marches 6-9 progress ratchets (mapped 2026-07-05, discovery-grounded;
    # historical campaign rationale is summarized in dev/HISTORY.md) ───────────
    "R14_fresh_constant_structs" => ("struct_new!(b in values.jl — heap constants built outside the ONE constant funnel (dart ensureConstant, constants.dart). Terminal state 0: per-object-identity kinds move to an exact per-site allowlist with their reason (dev/CHARTER.md C9, rule 2)",
        () -> count_sites(r"struct_new!\(b"; roots=[joinpath(SRC, "codegen")], exclude_files=setdiff(readdir(joinpath(SRC, "codegen")), ["values.jl"]))),
    "R27_coercion_bypass" => ("raw coercion ops (I32_WRAP_I64 etc) outside values.jl/int128.jl/types.jl",
        () -> count_sites(r"I32_WRAP_I64|I64_EXTEND_I32_[SU]|F64_PROMOTE_F32|F32_DEMOTE_F64";
                          roots=[CODEGEN], exclude_files=["values.jl", "int128.jl", "types.jl", "intrinsics_table.jl", "julia_numeric_tier.jl"])),
    # ── Phase 10.1a: the normalized frontend boundary (frontend/nir.jl; PARITY_MASTER item
    # 4 / DESIGN.md §10.1) — dart: AstCodeGenerator reads every node's type through ONE
    # StaticTypeContext (code_generator.dart:77 typeContext, :135 getStaticType), never
    # re-derived per visitor. R29 tracks per-file migration off raw CodeInfo reads onto the
    # NIR boundary; ir.jl is exempt (it's the boundary's OWN input side, `get_typed_ir`) and
    # frontend/nir.jl itself is outside roots=[CODEGEN] entirely (it's the construction
    # site — the boundary consuming CodeInfo is expected there, exactly like ir.jl).
    # ── Phase 12.I: strictness ratchets (dev/MARCH.md item I) — "strict in every
    # regard" made machine-checked for API types, not just codegen structure.
    "R33_unexercised_registry_entries" => ("lowering-registry entries no fast-lane case exercises — the entries of test/registry_coverage.jl's ALLOWLIST, which that lane keeps exact (a covered entry left in the list fails it; a new entry without a case fails it). dev/CHARTER.md C5. Terminal state 0",
        () -> count(l -> occursin(r"^\s*\(:[A-Z_]+, ", l), readlines(joinpath(ROOT, "test", "registry_coverage.jl")))),
]

# The builder alone: src/builder/*.jl, from builder/types.jl to builder/instr_builder.jl, loaded
# in the order src/WasmTarget.jl includes them into a module of their own (named WasmTarget, as
# InstrIR's `using ..WasmTarget` asks), without codegen/options.jl: the builder reads no OPTIONS
# (L149), so a builder function that read it fails here. The builder's behavioral locks (L151, L164-L168, L172) run its
# checks here in seconds, without loading the package.
const _BUILDER_SANDBOX = Ref{Union{Nothing,Module}}(nothing)
function builder_sandbox()::Module
    _BUILDER_SANDBOX[] === nothing || return _BUILDER_SANDBOX[]
    local files = String[]
    local started = false
    for m in eachmatch(r"^include\(\"([^\"]+)\"\)"m, read(joinpath(SRC, "WasmTarget.jl"), String))
        m[1] == "builder/types.jl" && (started = true)
        started && push!(files, m[1])
        m[1] == "builder/instr_builder.jl" && break
    end
    local W = Module(:WasmTarget)
    Core.eval(W, :(include(p) = Base.include($W, p)))
    for f in files
        Base.include(W, joinpath(SRC, f))
    end
    return _BUILDER_SANDBOX[] = W
end
include(joinpath(ROOT, "test", "builder_cases.jl"))
# run `f(W)` on the sandbox in the newest world (the sandbox's methods are defined after the locks)
in_builder_sandbox(f::Function) = (local W = builder_sandbox(); Base.invokelatest(f, W))
# how many of test/builder_cases.jl's rows (all, or those named) do not hold over the sandbox
builder_rows_failing(rows=nothing)::Int = in_builder_sandbox() do W
    count(c -> (rows === nothing || c.row in rows) && !builder_case_holds(W, c), builder_cases(W))
end
# how many of test/builder_cases.jl's body_cases rows (all, or those named) do not hold over the sandbox
body_rows_failing(rows=nothing)::Int = in_builder_sandbox() do W
    count(c -> (rows === nothing || c.row in rows) && !builder_case_holds(W, c), body_cases(W))
end
# how many of test/builder_cases.jl's dead_cases rows do not hold over the sandbox
dead_rows_failing()::Int = in_builder_sandbox() do W
    count(c -> !builder_case_holds(W, c), dead_cases(W))
end

# ---- LOCKS (completed dimensions; exact match required) ---------------------
const LOCKS = [
    "R40_process_global_state" => ("module-level mutable state one compilation reads or writes — a Ref, RefValue or TaskLocalRef, or a container constructed empty and filled at run time — outside R40_ALLOWED_PROCESS_STATE's exact entries (load-time tables and the host bridge's memos of pure functions, each with its reason; a stale entry counts). dart keeps one compilation's state on its Translator (translator.dart:96), which WT's Translator (context.jl) ports; a process-wide side channel leaks between compilations and tasks (dev/MARCH.md 13.7). Reached 0 on 2026-10-12 (batch 116e-1: the options, the diagnostics ledger and the constants in progress on the Translator, the perf_now import and the RNG globals on the module's registry, the layout-read memo on the interpreter, the selector table's base index read from the registry) and locked; test/diagnostics_sink.jl's 'a compile inside another's hook, and after another's options, shares no state (R40)' (a compile inside another's link_roots hook leaves the outer module's RNG globals and perf_now import and its ledger alone; compile_module after a logging compile does not log) (dev/CHARTER.md C2)",
        () -> length(process_global_state_sites())),
    # ratchets that reached 0 and were converted to locks (dev/CHARTER.md: a clause closes when
    # each ratchet it cites "has reached 0 and been converted to a lock"), 2026-09-30
    "R3_infer_value_type" => ("infer_value_type( callers — a value's Julia type computed at the use site instead of read once from its NIR node (dart reads node types through ONE StaticTypeContext, code_generator.dart:77). Reached 0 on 2026-10-11, when infer_value_type, get_ssa_type and _value_julia_type became the one reader, value_type (L174); stays 0 (dev/CHARTER.md C9, rule 2)",
        () -> count_sites(r"infer_value_type\("; exclude_line=r"function infer_value_type\(")),
    "R41_raw_local_declarations" => ("codegen sites that declare a local by pushing onto a function's locals list themselves (a push!/append!/pushfirst!/insert! onto any list named `locals`, bare or as a field, in src or ext), each computing its own index, beside the one declaration path, declare_local! (allocate_local!, builder_add_local!), which checks the local's type against the module (dart declares a local only through addLocal, instructions.dart:382). Reached 0 on 2026-10-11, when the last 165 sites moved to allocate_local! and builder_add_local!; stays 0 (dev/AUDIT.md A15B2; dev/CHARTER.md C7)",
        () -> begin
            # any push!/append!/pushfirst!/insert! onto a list named `locals` (bare or as a field), in src
            # and ext, beside declare_local!'s own one push
            local raw = r"(?:push|append|pushfirst|insert)!\(\s*(?:[A-Za-z_][A-Za-z0-9_.]*\.)?locals\s*,"
            local n = count_sites(raw; roots=[SRC, joinpath(ROOT, "ext")])
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            local m = match(r"function declare_local!\(.*?\nend"s, ib)
            n - (m === nothing ? 0 : count(raw, m.match))
        end),
    "R38_overlays_without_reason" => ("`@overlay …WASM_METHOD_TABLE` definitions in src and ext (behind any macro prefix, `@noinline @overlay`, and through any alias of the table, `@overlay WMT`: both went uncounted until 2026-09-29) with no parity anchor on the line, in the comments directly above, or in the docstring directly above: each replaces Julia's own body without stating why Julia's body cannot compile (dev/CHARTER.md C3: Julia's own bodies compile instead of bespoke re-implementations). Terminal state 0: each overlay is deleted once Julia's body compiles, or carries its dart anchor or quarantine reason",
        () -> length(overlays_without_reason())),
    "R39_smoke_runtime_xfails" => ("smoke xfails that compile and then fail when they run — a wrong value, a trap, or a result the harness cannot read back — the entries of test/smoke.jl's XFAIL_RUNTIME, which the xfail lane keeps exact against what each case measures (dev/CHARTER.md C6: correct or loud, never a module that runs and answers wrong). Terminal state 0: each becomes a passing case or a compile-time reject",
        () -> smoke_runtime_xfails()),
    "L131_every_algorithm_has_its_model" => ("dev/formal/README.md's Components table maps every algorithmic component of src to its TLA+ model or states why it has none; each modeled row's model exists and is anchored `formal(dev/formal/<M>.tla)` in a file the row names; every anchor has a row; every function holding a worklist or fixpoint loop has a row; a component with no model yet counts. Terminal state 0; returns to the locks at 0 (dev/CHARTER.md C8)",
        () -> length(components_without_model())),
    "R37_name_keyed_callee_arms" => ("codegen sites that select a callee by its NAME rather than its identity, in any spelling: `is_func(func, :x)`, a bare `name === :x` / `name in (:x, …)`, `.def.name`, a Method's or callee's `.name`, a regex (`occursin`/`match`) or prefix (`startswith`/`endswith`) over `string(…)`, `nameof(f) ===`/`in`, and a comparison `v === :x` / `v in (:x, …)` through ANY variable `v` bound from a `nameof(…)` or a `.name` read (counted once per such variable; a TypeName's `.name.name` is a type's name, not a callee's) (dart keys on the resolved member, intrinsics.dart:401 KernelNodes._lookup). The one exemption is a `nameof` guarded by `isa Core.IntrinsicFunction` in the same expression: Core.Intrinsics binds one const object per name, so there the name is the identity. Terminal state 0. The last site, invoke.jl's `#_growend!/_growbeg!/_growat!` arm, waits on the structural item that gives WT's Vector {data, size} its MemoryRef offset: without it Julia's own growth closure body (`a.ref = memoryref(newmem, offset)`, array.jl:1156) cannot be represented (dev/CHARTER.md C1)",
        () -> begin
            n = count_sites(r"is_func\(func, :"; roots=[CODEGEN])
            spellings = [r"(?<![.\w])name\s*(?:===|in)\s*\(?:",
                         r"\.def\.name\s*(?:===|in\b)",
                         r"\b(?:meth|method|m|_\w*_m|callee|func|f|g)\.name\s*(?:===|in)\s",
                         r"(?:occursin|match)\(r\"[^\"]*\",\s*string\(",
                         r"(?:startswith|endswith)\(string\(",
                         r"nameof\([\w.]+\)\s*(?:===|in\b)"]
            for (dir, _, files) in walkdir(CODEGEN), file in files
                endswith(file, ".jl") || continue
                src = read(joinpath(dir, file), String)
                for re in spellings, m in eachmatch(re, src)
                    line_start = something(findprev('\n', src, m.offset), 0) + 1
                    startswith(lstrip(src[line_start:m.offset]), "#") && continue
                    guard = src[thisind(src, max(1, m.offset - 200)):m.offset]
                    (startswith(re.pattern, "nameof") && occursin("isa Core.IntrinsicFunction", guard)) && continue
                    n += 1
                end
                # a name carried through a variable: `nm = callee.name` / `nameof(f)`, then
                # `nm === :getfield` — one site per such variable that is compared
                lines = split(src, '\n')
                for line in lines
                    startswith(lstrip(line), "#") && continue
                    b = match(r"(?:^|\blocal\s+|\s)(\w+)\s*=(?!=)\s*(.*)", line)
                    b === nothing && continue
                    v, rhs = b.captures[1], b.captures[2]
                    v == "name" && continue                       # the bare spelling above
                    occursin(r"\bnameof\(|\.name\b(?!\.name)", rhs) || continue
                    occursin(r"\.name\.name\b", rhs) && !occursin(r"\bnameof\(", rhs) && continue
                    occursin("isa Core.IntrinsicFunction", rhs) && continue
                    cmp = Regex("(?<![.\\w])" * v * "\\s*(?:===|in\\b)\\s*\\(?:")
                    any(l -> !startswith(lstrip(l), "#") && occursin(cmp, l), lines) && (n += 1)
                end
            end
            n
        end),
    "R15_constant_data_segments" => ("add_passive_data_segment! outside the builder and the string/type creators — the long-string and Symbol paths that bypass the one constant funnel. Terminal state 0 (dev/CHARTER.md C9)",
        () -> count_sites(r"add_passive_data_segment!"; exclude_files=["builder/instructions.jl", "codegen/strings.jl", "codegen/compile.jl", "codegen/interpreter.jl", "codegen/types.jl"])),   # types.jl = the lazy creator's ONE legit segment site
    "R17_unwrapped_value_emissions" => ("emit_value! calls with no expectedType, on the parse tree (untyped_value_emissions) — dart's only one is translateExpression's own accept1 call (code_generator.dart:676), which is not counted. Terminal state 0 (dev/CHARTER.md C4)",
        () -> length(untyped_value_emissions())),
    "R20_invoke_name_arms" => ("(?<![.\\w])name === :\\w+ arms in invoke.jl only (phase 5: 54 to migrate to registry)",
        () -> count_sites(r"(?<![.\w])name === :\w+"; roots=[CODEGEN],
                          exclude_files=setdiff(readdir(CODEGEN), ["invoke.jl"]))),
    "R21_foreigncall_arms" => ("(_fc_sym|fname|cfn) === :\\w+, or an `if`/`elseif`-headed `name === :\\w+`/`name in (:` arm, anywhere in statements.jl compile_foreigncall! dispatch (want 0: every foreigncall symbol dispatches through FOREIGN_LOWERINGS only)",
        () -> begin
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            count(line -> !_iscomment(line) &&
                          (occursin(r"(_fc_sym|fname|cfn) === :\w+", line) ||
                           (occursin(r"^\s*(if|elseif)\b", line) &&
                            occursin(r"(?<![.\w])name\s+(===\s*:\w+|in\s*\(:)", line))),
                  split(stmt_src, '\n'))
        end),
    "R30_untyped_returns" => ("function definitions in codegen/frontend/builder with no `::T` return-type annotation, or with `::Any` outside R30_ANY_SEAMS's named seams (long `function f(...)` and short `f(...) = ...`; excludes closures, anonymous/functor signatures, and qualified Base./interface extensions — see count_untyped_returns' docstring)",
        () -> count_untyped_returns([CODEGEN, joinpath(SRC, "frontend"), joinpath(SRC, "builder")])),
    "R31_any_typed_fields" => ("`Any`-typed or untyped struct/mutable struct fields anywhere in src, minus R31_ALLOWLIST's named heterogeneous seams (WasmDiagnostic.detail, NirLiteral.value/NirCall.callee/NirInvoke.callee, the registries' Function values, DispatchTableRegistry's func_ref keys, the interpreter's cache-owner token)",
        () -> count_any_typed_fields()),
    # ── dev/CHARTER.md (2026-09-22) ─────────────────────────────────────────────
    "R32_unanchored_definitions" => ("top-level definitions in src — every method separately, read from the parsed syntax tree — with no parity(<dart file:line>) or parity(quarantine: …) anchor in their docstring or directly above them — dev/CHARTER.md C2: every structure copies a named dart2wasm structure or names the Julia necessity that forces it. Terminal state 0",
        () -> count_unanchored_definitions()),
    "R35_detached_docstrings" => ("bare string literals among top-level statements in src: docstrings a comment line cut off from their definition (Julia then attaches them to nothing — a `# formal(…)` line between docstring and function did this repeatedly) or prose with no definition under it (dev/CHARTER.md C9). Terminal state 0: a docstring sits directly on its definition, with any anchor inside it",
        () -> count_detached_docstrings()),
    "R36_hidden_test_failures" => ("@test_skip / @test_broken in test/ — a known failure no gate reports, where a regression can hide (dev/CHARTER.md C5: wrong choices cannot land silently). Terminal state 0: each becomes a passing test, a located rejection asserted with @test_throws, or a tracked open item with its reproducer",
        () -> count_sites(r"@test_skip\b|@test_broken\b"; roots=[joinpath(ROOT, "test")],
                          exclude_files=["parity_ratchet.jl"])),
    "R34_silent_catches" => ("catch clauses in src that swallow a failure — no rethrow/throw/error and no located diagnostic (dev/CHARTER.md C6: correct or loud, never a silent default). Terminal state 0: a handler that must not throw (the diagnostic path itself) moves to an exact per-site allowlist with its reason",
        () -> count_silent_catches()),
    "L65_no_codegen_byte_shells" => ("codegen helpers expose only builder-native emission; dead byte-vector adapter APIs are deleted. One site is allowed, exactly: `function host_runtime_js(bytes::Vector{UInt8})::String`, no emission but the host runtime generated from the module a host instantiates, its imports read by the builder's module_function_imports (dart generates its runtime from the module it translated, runtime_generator.dart:128)",
        () -> count_sites(r"bytes shell|[(,]\s*(?:target_)?bytes::Vector\{UInt8\}";
                          roots=[CODEGEN], exclude_line=r"^function host_runtime_js\(bytes::Vector\{UInt8\}\)::String$")),
    "L66_no_fabricated_string_results" => ("string concatenation is Base's own compiled body, or the one N-way builder reached only when every operand is proven String or Symbol (builtins.jl `*`); the Method-keyed string builders are deleted and cannot return; mixed arguments can never become an empty string",
        () -> begin
            codegen_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")))
            strings_src = read(joinpath(CODEGEN, "strings.jl"), String)
            builtins_src = read(joinpath(CODEGEN, "builtins.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["Fall back to empty string", "array_new_fixed!(bms, str_type_idx, 0, I32)",
                         "For now, just do first two", "Multi-string concat: concat pairwise",
                         "_invoke_string_concat_or_reject_b", "_invoke_star_concat_b"]
            required = ["function compile_string_concat_many_b", "for loc in str_locals"]
            # both operands of `*`, read from their nodes, proven String or Symbol
            builtins_required = ["callee === (*) && length(vals) == 2 && all(t -> t === String || t === Symbol, ts)"]
            test_required = ["compare_julia_wasm(_wt_many_string_length).pass"]
            count(p -> occursin(p, codegen_src), forbidden) +
                count(p -> !occursin(p, strings_src), required) +
                count(p -> !occursin(p, builtins_src), builtins_required) +
                count(p -> !occursin(p, test_src), test_required)
        end),
    "L67_one_exception_and_block_owner" => ("the stackifier alone owns block and try-region structure; no dead block-emission adapter or statement-level EnterNode implementation may coexist",
        () -> begin
            api_src = read(joinpath(SRC, "WasmTarget.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            forbidden = ["codegen/conditionals.jl", "generate_block_code!",
                         "For now, we just skip this - full implementation requires try_table"]
            required = ["THE stackifier owns the", "every CFG shape, including a single block",
                        "try_open_at", "try_legacy!(b"]
            all_src = api_src * stmt_src * flow_src * stack_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L68_one_runtime_type_representation" => ("type constants, TypeNames, population, and lookup tables use only the canonical JlType hierarchy; the raw Julia DataType fallback is extinct",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            forbidden = ["_populate_legacy_types!", "Legacy path: Populate Julia DataType",
                         "else fall back to Julia DataType", "else Julia DataType struct",
                         "Fallback: return i32 typeId", "Type not in globals — return null ref",
                         "Fallback: i32 typeId"]
            required = ["type constants require the canonical JlType hierarchy",
                        "TypeName constants require the canonical JlType hierarchy",
                        "type constant population requires the canonical JlType hierarchy",
                        "type lookup table requires the canonical JlType hierarchy"]
            all_src = types_src * calls_src * context_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L69_one_vector_mutation_path" => ("Vector mutation compiles Julia's own bodies — push!, pop!, resize!, pushfirst!, popfirst!, insert!, deleteat!, append!, prepend!, empty! and _deleteend!, growing through _growend!/_growbeg!/_growat! and the reallocating closures the collector enrolls as statically invoked closures — with no WASM_METHOD_TABLE overlay of them and no name-routed mutation emitter or grow stand-in (restated 2026-09-27: it pinned the reallocating push!/resize! overlays, which put a Vector's MemoryRef back at offset 1, dev/CHARTER.md C3)",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["is_func(func, :push!)", "is_func(func, :pop!)",
                         "is_func(func, :resize!)", "assume capacity is sufficient",
                         "function _resize!", "function Base.pop!(v::Vector{T})",
                         "function Base.push!(v::Vector{T}, x)",
                         "function Base.resize!(v::Vector{T}, n::Integer)",
                         "function Base.pushfirst!(v::Vector{T}, x)",
                         "function Base.popfirst!(v::Vector{T})",
                         "function Base.insert!(v::Vector{T}", "function Base.deleteat!(v::Vector{T}",
                         "function Base.append!(v::Vector{T}", "function Base.prepend!(v::Vector{T}",
                         "function Base.empty!(v::Vector{T})", "function Base._deleteend!(a::Vector{T}",
                         "function Base._growend_internal!", "^#_growend!", "^#_(?:growend"]
            required = ["_wt_vector_mutation_semantics", "ftyp in invoked_closures"]
            all_src = calls_src * interp_src * invoke_src * trim_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L70_no_host_power_fallback" => ("power compiles through the collected Julia body; unresolved invokes cannot switch to a Math.pow host import or approximation",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["pow_import_idx", "requires 'pow' import", "approximation using exp",
                         "add_import!(mod, \"Math\", \"pow\"", "assume `Math.pow` sits at import index 0"]
            required = ["_wt_pure_power_semantics"]
            count(p -> occursin(p, invoke_src * compile_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L71_no_silent_io_argument_skip" => ("show of any argument compiles Julia's own show body or rejects at its statement; no show builder exists that could silently omit an argument and report success",
        () -> begin
            codegen_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")))
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String) *
                       read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            # no show builder exists: show(x) compiles Julia's own body, whose console
            # write rejects at its statement
            forbidden = ["show: unsupported argument type \$arg_type, skipping", "_invoke_show_b"]
            required = ["@test_throws WasmTarget.WasmCompileError WasmTarget.compile(_wt_unsupported_show, ())",
                        "receiver-free print/println/show reject loudly at their statement",
                        "(DiagAttrib.shows, (Float64,))"]
            count(p -> occursin(p, codegen_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L72_no_fabricated_string_encoder" => ("the JS string boundary exposes only implemented imports; no unused encoder API may alias the decoder as a placeholder",
        () -> begin
            strings_src = read(joinpath(CODEGEN, "strings.jl"), String)
            forbidden = ["encode_idx", "add_string_io_imports!", "old approach as a stub"]
            count(p -> occursin(p, strings_src), forbidden)
        end),
    "L73_capture_analysis_never_silently_disables" => ("capture/value-channel proof failures propagate; no catch-all may erase all inferred joins and continue compilation — the joins are computed once, by numeric_local_joins, whose body holds no catch (restated 2026-09-28: the captured-variable record replaced the closure-local guess)",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            capture_src = read(joinpath(CODEGEN, "box_capture.jl"), String)
            capture_test = read(joinpath(ROOT, "test", "f3_box_capture_l2b_propagate.jl"), String)
            forbidden = ["catch\n        Dict{Int,Type}()", "capture analysis fallback"]
            # the joins are computed once, by numeric_local_joins, whose body holds no catch:
            # a failure inside any capture/value-channel proof propagates
            required = ["_numeric_joins = numeric_local_joins(ctx)",
                        "propagate_numeric_value_types",
                        "plan_joins(ctx.translator.plan, ctx.mi)", "function record_capture_contents(",
                        "no fixpoint within the bound: every captured variable stays erased",
                        "Tuple{Vararg{Int64}}"]
            body = match(r"(?s)\nnumeric_local_joins\(ctx::AbstractCompilationContext\).*?\n\n", context_src)
            all_src = context_src * capture_src * capture_test
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required) +
                (body === nothing ? 1 : count("catch", body.match)) +
                max(count("= numeric_local_joins(ctx)", context_src) - 1, 0)
        end),
    "L74_builder_owns_statement_arity" => ("post-emission drop decisions use the builder's actual stack delta; no Julia-type/registry heuristic may re-guess whether a call produced a value",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            forbidden = ["function statement_produces_wasm_value", "assume no value produced"]
            required = ["_stmt_stack0 = length(bb.v.stack)",
                        "_stmt_pushed_value = length(bb.v.stack) > _stmt_stack0",
                        "_stmt_emitted && _stmt_pushed_value"]
            all_src = context_src * stack_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L75_globalref_absence_is_explicit" => ("core typing, dispatch, and cross-call resolution test binding existence explicitly; broad catches cannot disguise internal resolution failures as a missing GlobalRef",
        () -> begin
            files = ["flow.jl", "stackified.jl", "dispatch.jl", "invoke.jl", "calls.jl"]
            src = join((read(joinpath(CODEGEN, f), String) for f in files), "\n")
            forbidden = ["actual_val = getfield(val.mod, val.name)\n            return get_phi_edge_wasm_type(actual_val",
                         "called_func = try\n            getfield(func.mod, func.name)",
                         "ft_early = try\n            infer_value_type"]
            # dispatch.jl's own binding test moved to the NIR boundary in Phase 12D
            # (resolve_call_callee resolves a GlobalRef ONCE, leaving it a GlobalRef when
            # unbound), so what find_dispatch_call must still state explicitly is that an
            # unresolved callee is SKIPPED — not swallowed into a table lookup.
            required = ["val.bound || return nothing",
                        "callee_func isa NirNode || callee_func isa GlobalRef",
                        "\n        called_func = func isa GlobalRef ? nothing : func"]
            # an :invoke's callee is resolved at the boundary too (nir_callee, one rule for
            # every call kind), so an unbound global reaches codegen as its GlobalRef
            local nirs = read(joinpath(SRC, "frontend", "nir.jl"), String)
            count(p -> occursin(p, src), forbidden) + count(p -> !occursin(p, src), required) +
                (occursin("x isa NirGlobalRef && return x.bound ? x.value : GlobalRef(x.mod, x.name)", nirs) ? 0 : 1)
        end),
    "L76_no_silent_invoke_or_io_substitution" => ("invoke resolution uses explicit singleton/binding predicates; receiver-free print/println/show compile Julia's own bodies and reject loudly at their statement — no console builder exists that could disappear or fabricate question-mark output",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            codegen_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")))
            diag_src = read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            forbidden = ["func_type.instance\n                    catch", "try infer_value_type",
                         "No IO imports — stub as no-op", "unsupported argument type \$arg_type, skipping",
                         "Unsupported element type — just write \"?\"", "Create a synthetic GlobalRef for lookup",
                         "_compile_invoke_print", "_invoke_print_b", "_invoke_println_b"]
            # the singleton predicate is the boundary's one callee rule (nir_operand_callee), which
            # an :invoke's callee is resolved by too
            local nir_src = read(joinpath(SRC, "frontend", "nir.jl"), String)
            required = String[]
            # receiver-free print/println/show compile Julia's own bodies, whose console
            # write rejects loudly at its statement — pinned behaviorally
            diag_required = ["(DiagAttrib.hostprint, (Int64,)), (DiagAttrib.hostprintln, (Int64,))",
                             "@test_throws WasmTarget.WasmCompileError WasmTarget.compile(f, argtypes)",
                             "e.diag.stmt_idx > 0 && !isempty(e.diag.stmt)"]
            count(p -> occursin(p, codegen_src), forbidden) +
                count(p -> !occursin(p, invoke_src), required) +
                (occursin("(static_type isa DataType && Base.issingletontype(static_type) && static_type <: Function)", nir_src) ? 0 : 1) +
                count(p -> !occursin(p, diag_src), diag_required)
        end),
    "L77_call_reflection_is_structural" => ("call lowering tests binding, singleton, tuple, and field structure explicitly; reflection failures cannot silently select another lowering",
        () -> begin
            # The field-access lowerings are BUILTIN_LOWERINGS entries in
            # builtins.jl since Phase 12F; the structural tests they carry are
            # the same text, read from both halves of `compile_call!`'s chain.
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                        read(joinpath(CODEGEN, "builtins.jl"), String)
            forbidden = ["try getfield(func.mod, func.name) catch", "try infer_value_type",
                         "try fieldtypes(obj_type) catch", "return try Base.padding",
                         "try getfield(target_type_ref.mod", "try getfield(args[1].value"]
            required = ["\n        called_func = func isa GlobalRef ? nothing : func",
                        "obj_type isa DataType && isconcretetype(obj_type)",
                        "sext_int target is not a defined Julia type",
                        "zext_int target is not a defined Julia type",
                        "trunc_int target is not a defined Julia type"]
            count(p -> occursin(p, calls_src), forbidden) +
                count(p -> !occursin(p, calls_src), required)
        end),
    "L78_closed_world_reaches_a_real_fixpoint" => ("dynamic and edge discovery share one unconditional fixpoint with no environment opt-out, round ceiling, method-count cliff, or swallowed specialization failure: the loop only adds, so no collected body is ever dropped (the superseded trim, `unreachable=true` with its `prune_roots`, `pruned_superseded` and `intrinsic_body_roots`, was deleted in batch 111 and may not return), and every compile! output, the first and each later round's, is cut by the declared imports before it merges (an import's native body never enters the plan); every edge of the closed world — an :invoke, a call a builtin hides (invoke_in_world, a runtime-Vararg splat) and each edge Julia's collectinvokes! follows besides :invoke (a finalizer, a :cfunction, 1.13's :new of a Function, an :invoke_modify) — is ONE edge relation, _closed_world_edge, that the collector enrolls its target by, the external-leaf cut keeps it by and the collector's walk records its reason by (the plan reads the world and writes none of it), resolved in the overlay table (never the native `which`); every root's reason is the one its enrollment recorded, the fma roots' included: collect_new_pairs! takes no reason (no default) and raises a WasmInternalError for a root with none; plan_closed_world reads the world and writes none of it, which test/diagnostic_attribution.jl's \"planning writes nothing into the collected world\" pins over a program with a closure, a dynamic call and an edge (dev/AUDIT.md A2C4, A2C5). Until 2026-09-29 the pruner knew only the splat edge, so an invoke_in_world callee the collector enrolled was pruned back out (\"unresolved dynamic call Base.sqrt (Float64,)\"), and an argument operand went untyped (smoke invoke_in_world)",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            tests_src = read(joinpath(ROOT, "test", "runtests.jl"), String) *
                        read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            forbidden = ["WT_DYNDISPATCH", "for _round in 1:8", "length(ms) <= 64",
                         "try CC.specialize_method", "try collect(methods", "which(f, ats)",
                         "unreachable=true", "unreachable::Bool", "pruned_superseded",
                         "superseded_invokes", "prune_roots", "intrinsic_body_roots",
                         "_builtin_call_edge_mi",
                         # every reason is recorded by the collection (no default), the plan writes none
                         "why::String=", "get(enrolled_by, root_mi, why)", "enrolled_as[edge[2]] =",
                         "_closed_world_edge(n, src, slot_types, arg_type, edge_interp)"]
            required = ["while true",
                        "local edge = _closed_world_edge(node, src, src_slot_types, arg_type, interp)",
                        "local edge = _closed_world_edge(s.node, pair[2], pair_slot_types, arg_type, interp)",
                        "function collect_new_pairs!(mis)\n",
                        # the plan reads the world, its behavior pinned (diagnostic_attribution.jl)
                        "return plan_closed_world(world, entry_keys, entry_values, external_leaves)",
                        "@testset \"planning writes nothing into the collected world\" begin",
                        "@test world.enrolled_as == reasons",
                        "local why = get(enrolled_by, root_mi, nothing)\n            why === nothing && throw(WasmInternalError(",
                        "CC.findall(sig, CC.method_table(get_wasm_interpreter()); limit)",
                        "if (mi = _apply_iterate_vararg_target_mi(node, arg_type)) !== nothing",
                        "elseif (mi = _invoke_in_world_target_mi(node, arg_type)) !== nothing",
                        "kind = :finalizer", "kind = :cfunction", "kind = :new_function", "kind = :invoke_modify",
                        "local matches = wt_method_matches(Tuple{Core.Typeof(f), arg_types...})",
                        "Explicit invokes and dynamic-dispatch candidates form ONE reachability",
                        "collect_new_pairs!",
                        "# the loop only adds: no collected body is ever dropped",
                        "codeinfos = _prune_external_leaf_subgraphs(codeinfos, entries, external_leaves; numeric_joins, capture)",
                        "fresh_ci = _prune_external_leaf_subgraphs(fresh_ci, Any[first.(batch)...], external_leaves; numeric_joins, capture)",
                        "dynamic dispatch: discover every target admitted by the closed",
                        "has no environment opt-out or arbitrary round/method ceiling"]
            all_src = trim_src * tests_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required) +
                # no code writes a reason into the plan's record (the world's), anywhere in src
                count_sites(r"enrolled_as\[[^\]]*\]\s*=[^=]"; roots=[SRC])
        end),
    "L79_partial_new_requires_definite_initialization" => ("Wasm physical defaults for missing primitive fields are emitted only when a closed-world CFG must-analysis proves every field is written before read or escape",
        () -> begin
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["struct_type === Random.Xoshiro", "nameof(struct_type)",
                         "primitive_init_proven = true", "allow_uninitialized"]
            required = ["function _definitely_initializes_in_nir", "intersect(incoming[dest], assigned)",
                        "_partial_new_is_definitely_initialized", "primitive_init_proven",
                        "_wt_make_undefined_field", "_wt_use_definitely_initialized_fields"]
            all_src = stmts_src * test_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L80_dynamic_callable_enrollment_is_function_scoped" => ("dynamic callable bodies are paired only with signatures observed in the same collected function; no component-wide arity Cartesian product may enroll unrelated functions",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            forbidden = ["    dyn_sigs = Set", "    callable_types = Set", "for _T in callable_types",
                         "for ds in dyn_sigs"]
            required = ["callable_invocations = Set{Tuple{DataType,Tuple}}()",
                        "function flush_callable_invocations!",
                        "for T in _fn_callables, sig in _fn_dyn_sigs",
                        "Never form a component-wide Cartesian product"]
            count(p -> occursin(p, trim_src), forbidden) +
                count(p -> !occursin(p, trim_src), required)
        end),
    "L81_kwerr_throws_exact_methoderror" => ("reachable invalid-keyword paths compile Base.kwerr's own body, which throws a real MethodError with Core.kwcall, the exact argument tuple, and the module's one world age (WASM_WORLD_AGE — never the host counter) instead of a generic trap",
        () -> begin
            # Base.kwerr's own body builds the MethodError; its tls_world_age() is the
            # jl_get_tls_world_age foreigncall, which lowers to the module's one age
            codegen_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")))
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["_invoke_kwerr_b"]
            stmts_required = ["function _fc_jl_get_tls_world_age!(b::InstrBuilder, node::NirForeignCall, idx::Int, ctx::AbstractCompilationContext)::InstrBuilder\n    i64_const!(b, Int64(WASM_WORLD_AGE))"]
            test_required = ["err.args isa Tuple{NamedTuple{(:unsupported_keyword,), Tuple{Bool}}, typeof(identity)}",
                             "compare_julia_wasm(_wt_exact_kwerr_exception).pass"]
            count(p -> occursin(p, codegen_src), forbidden) +
                count(p -> !occursin(p, stmts_src), stmts_required) +
                count(p -> !occursin(p, test_src), test_required)
        end),
    "L82_inexact_helper_throws_exact_payload" => ("Core.throw_inexacterror compiles its own body, which constructs the real InexactError func and argument tuple and throws it through the Julia exception tag",
        () -> begin
            # Core.throw_inexacterror's own body builds InexactError(func, (T, val))
            codegen_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")))
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["_invoke_throw_inexacterror_b"]
            required = ["err isa InexactError && err.func === :convert && err.args isa Tuple{DataType, UInt64}",
                        "compare_julia_wasm(_wt_exact_inexact_exception).pass"]
            count(p -> occursin(p, codegen_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L83_fieldwise_constructors_are_structural" => ("concrete exact-field constructors route through the sole %new implementation before dynamic dispatch, even when inference erased a field expression",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            linalg_src = read(joinpath(ROOT, "test", "fuzz", "linalg_diff.jl"), String)
            forbidden = ["called_func === DimensionMismatch", "nameof(called_func)",
                         "constructor_allowlist"]
            required = ["A concrete field-wise constructor is structural, not dynamic",
                        "called_func === _ctor_result && length(args) == fieldcount(_ctor_result)",
                        "return compile_new!(b, nir_new(_ctor_result, args)",
                        "_la_solve", "_la_lusolve"]
            count(p -> occursin(p, calls_src), forbidden) +
                count(p -> !occursin(p, calls_src * linalg_src), required)
        end),
    "L84_boxing_requires_exact_julia_class" => ("the sole numeric boxer always stamps a proven concrete Julia classId; width-default class substitution and typeless boxing calls are extinct",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            all_codegen = join((read(joinpath(dir, f), String)
                                for (dir, _, files) in walkdir(CODEGEN)
                                for f in files if endswith(f, ".jl")), "\n")
            forbidden = ["wasm-rep-id fallback", "width-default type",
                         "wasm_type === I32 ? Int32", "emit_classid_box!(b, ctx, src_type, nothing)",
                         "emit_classid_box!(_xcb, ctx, ret_wasm, nothing)"]
            required = ["julia_type::Type", "isconcretetype(julia_type)",
                        "emit_type_id!(b, registry, julia_type)",
                        "There is no width-based fallback"]
            count(p -> occursin(p, all_codegen), forbidden) +
            count(p -> !occursin(p, values_src), required)
        end),
    "L85_constructors_never_drop_real_values" => ("constructor lowering represents every supplied value exactly or rejects loudly; vector and Union fields may never be repaired with null",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            forbidden = ["Non-Array AbstractVector (UnitRange, StepRange) — use ref.null",
                         "keep the type-correct null so the module validates",
                         "ref_null!(b, Int64(size_info_inner.wasm_type_idx)"]
            required = ["vector construction requires a concrete backing array; refusing to substitute null",
                        "emit_struct_prefix!(b, ctx.type_registry, size_tuple_type_inner, size_info_inner)",
                        "coerce_stack_top!(b, I64, ctx;",
                        "registered union field \$i has no physical Wasm type",
                        "emit_value!(b, val, ctx, _cn_expected;"]
            count(p -> occursin(p, statements_src), forbidden) +
            count(p -> !occursin(p, statements_src), required)
        end),
    "L86_phi_null_is_semantic_not_numeric" => ("phi lowering recognizes exact SSA/Pi aliases of Julia nothing before numeric conversion, so null can never become a fabricated classId box",
        () -> begin
            unions_src = read(joinpath(CODEGEN, "unions.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            required = ["def isa NirGlobalRef && def.name === :nothing",
                        "def.typ === Nothing && return true",
                        "return is_nothing_value(def.value, ctx)",
                        "if is_nothing_value(val, ctx)",
                        "before compiling SSA aliases"]
            count(p -> !occursin(p, unions_src * stack_src), required)
        end),
    "L87_symbolic_control_labels" => ("builder and codegen branch only to identity-bearing labels; numeric depths exist solely in the private serialization boundary, matching dart2wasm _labelIndex",
        () -> begin
            builder_src = read(joinpath(ROOT, "src", "builder", "instr_builder.jl"), String)
            validator_src = read(joinpath(ROOT, "src", "builder", "validator.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            all_codegen = join((read(joinpath(dir, f), String)
                                for (dir, _, files) in walkdir(CODEGEN)
                                for f in files if endswith(f, ".jl")), "\n")
            forbidden = [r"br!\([^,]+,\s*(?:UInt32\()?\d",
                         r"br_if!\([^,]+,\s*(?:UInt32\()?\d",
                         r"br_on_(?:non_)?null!\([^,]+,\s*\d",
                         r"function\s+get_(?:forward|loop)_label_depth",
                         r"br!\(b::InstrBuilder,\s*depth::Integer"]
            required = ["mutable struct ControlLabel", "handle::ControlLabel",
                        "function _label_depth(b::InstrBuilder, target::ControlLabel)",
                        "br!(b::InstrBuilder, target::ControlLabel)",
                        "branch target is not an open label",
                        "label_stack = Tuple{Symbol,Int,ControlLabel}[]",
                        "get_forward_label(target_block::Int)::ControlLabel"]
            sum(rx -> length(collect(eachmatch(rx, all_codegen * builder_src))), forbidden) +
            count(p -> !occursin(p, validator_src * builder_src * stack_src), required)
        end),
    "L88_constant_fields_keep_exact_classes" => ("constant materialization uses each known field value's concrete runtime Julia type, never an abstract declaration that would erase its classId",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            forbidden = ["from_julia=fieldtype(T, fi)", "from_julia=fieldtype(T, i)",
                         "has_undefined\n            ref_null!"]
            required = ["A materialized constant supplies stronger evidence than its declared",
                        "emit_value!(b, NirLiteral(field_val), ctx, expected; from_julia=typeof(field_val))",
                        "closure constant of type \$T has undefined captures; WT never fabricates capture values"]
            count(p -> occursin(p, values_src), forbidden) +
                count(p -> !occursin(p, values_src), required)
        end),
    "L89_erased_boundschecks_preserve_cfg_edges" => ("an always-taken @inbounds boundscheck branch is FOLDED (its fall-through edge dropped) and dead code is whatever the folded CFG cannot reach from the entry — never the statements between the jump and its target (that span carving dropped the live loop of reduce(max, 1:n) on 1.13); reachability runs before dominator and loop ownership analysis (re-pinned 2026-09-02)",
        () -> begin
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            reach = findfirst("Dead code = unreachable from the entry over the folded CFG", stack_src)
            cfg = findfirst("# The folded CFG: every block's edges as Julia's CFG has them (nir_cfg)", stack_src)
            dominators = findfirst("# Compute block dominators from the real CFG", stack_src)
            ordering_fail = reach === nothing || cfg === nothing || dominators === nothing ||
                            first(cfg) > first(reach) || first(reach) > first(dominators)
            forbidden = ["for j in (i + 2):(target - 1)", "resolve_through_dead_boundscheck"]
            Int(ordering_fail) + count(p -> occursin(p, stack_src), forbidden)
        end),
    "L90_crossing_regions_are_normalized_or_rejected" => ("shared terminal CFG tails are duplicated through the canonical visitor and every physical label closure is LIFO-checked",
        () -> begin
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            required = ["duplicated_terminal_targets = Set{Int}()",
                        "terminal && phi_free && !prev_can_fallthrough",
                        "compile_statement!(tb, i, ctx)",
                        "crossing control regions at block",
                        "_lb == length(label_stack)",
                        "_lp == length(label_stack)"]
            count(p -> !occursin(p, stack_src), required)
        end),
    "L91_framework_roots_are_declarative" => ("framework closure globals, exact constants, and root-to-root calls are declarative inputs to the one closed-world compilation route",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                        read(joinpath(CODEGEN, "builtins.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "module_builder_validation.jl"), String)
            required = ["captured_constants::Dict{Symbol,Any}",
                        "invoke_roots::Dict{Int,String}",
                        "invoke_arguments::Dict{Int,Vector{Int}}",
                        "bound_leaves::Vector{Tuple{Any,Tuple}}",
                        "entry_calls::Vector{UInt32}",
                        "link_roots::Union{Nothing,Function}",
                        "root \$name binds closure fields twice",
                        "invokes unknown compilation roots",
                        "selects arguments for unbound invoke sites",
                        "static_wasm_type(NirLiteral(_captured_value), ctx)",
                        "Declaratively bound invoke", "params = _function_type(ctx.mod, target_idx).params",
                        "emit_value!(bii, arg, ctx, expected",
                        "root entry call \$target_idx must have signature () -> ()",
                        "add_root_global_initializer!",
                        "registry.module_init_functions",
                        "add_string_global!",
                        # the linker cannot add an import: add_import! refuses one after a definition
                        "@test_throws MBV.ModuleValidationError MBV.compile_multi(",
                        "constant_root", "root-link fixture", "unknown_link", "bad_entry",
                        "linked_indices", "bindings.bound_leaves"]
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            count(p -> !occursin(p, compile_src * calls_src * invoke_src * stack_src * test_src), required)
        end),
    "L93_recovered_capture_calls_are_exact_closed_world_edges" => ("verified Core.Box capture types enroll one exact overlay MethodInstance and devirtualize only an all-concrete exact candidate signature without exposing candidates to fuzzy lookup (restated 2026-09-28: the types come from record_capture_contents over the collected world)",
        () -> begin
            box_src = read(joinpath(CODEGEN, "box_capture.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            test_src = read(joinpath(ROOT, "test", "f3_box_capture_l2b_propagate.jl"), String)
            required = ["capture.record = record_capture_contents(",
                        "capture.joins[mi] = capture_read_types(nirs[src], nirs[src], capture.record,",
                        "_body_joins(numeric_joins, capture, host_mi, src, nir, st)", "if isempty(absp)", "_closed_world_exact_type",
                        "_canonical_type_object_arg", "canonical_matches[1].method === match.method",
                        "root_mi in dynamic_roots && push!(dynamic_roots, resolved_mi)",
                        "function get_exact_candidate", "all(_closed_world_exact_type, arg_types)",
                        "info.is_candidate && info.arg_types == arg_types",
                        "infos = FunctionInfo[i for i in infos if !i.is_candidate && !i.invoke_only]",
                        "_target = get_exact_candidate", "target_info = get_exact_candidate",
                        "boxed_vector_capture", "vmod isa Vector{UInt8}"]
            count(p -> !occursin(p, box_src * trim_src * types_src * calls_src * test_src), required)
        end),
    "L94_codegen_errors_keep_structured_ledgers" => ("the closed-world planner propagates WasmCompileError and validation errors without catch-all conversion to ErrorException, preserving caller-facing diagnostic ledgers",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            test_src = read(joinpath(ROOT, "test", "diagnostics_sink.jl"), String)
            forbidden = ["code generation failed for", "sprint(showerror, err)"]
            required = ["b = generate_body(_ctx_function_builder(ctx, func_idx), ctx)",
                        "err isa WasmTarget.WasmCompileError", "err.diag in err.all",
                        "@test isempty(outer_sink)"]
            count(p -> occursin(p, compile_src), forbidden) +
            count(p -> !occursin(p, compile_src * test_src), required)
        end),
    "L95_type_object_specializations_match_runtime_representation" => ("transitive Type{T} specializations collapse to an already-collected representation-class specialization only under identical method identity, while singleton precision remains available when dispatch requires it",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["_canonical_type_object_arg", "collected_method_specs",
                        "!haskey(entry_keys, mi)", "canonical_args != arg_types",
                        "(mi.def, canonical_sig) in collected_method_specs"]
            count(p -> !occursin(p, trim_src), required)
        end),
    "L96_explicit_io_never_becomes_host_console" => ("print(io, ...) and show(io, ...) remain ordinary compiled Julia formatting calls — a module compiling print(::IOBuffer, ...) declares no import but the runtime's `wasmtarget.stack_trace`, which every module declares before its definitions (L145) — so host IO imports cannot shift framework-owned function indices: no host-console import exists anywhere in src, and receiver-free println/print/show reject loudly at their statement (no IO bridge exists to configure)",
        () -> begin
            docs_ci = read(joinpath(ROOT, ".github", "workflows", "docs.yml"), String)
            mbv_src = read(joinpath(ROOT, "test", "module_builder_validation.jl"), String)
            src_all = String[]
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") && push!(src_all, read(joinpath(dir, f), String))
            end
            src_all = join(src_all)
            # no host-console import exists anywhere in src (it would shift the
            # framework's function indices); no IO classifier exists — print(io, ...)
            # is an ordinary call and compiles to a module with no imports
            forbidden = ["add_io_imports!(", "_invoke_has_explicit_io", "\"io\", \"write_", "fromCharCodeArray"]
            required = ["explicit IO formatting does not activate host-console imports",
                        "compile_module(Any[(_mbv_io_receiver_print, (IOBuffer, Char), \"p\")])",
                        "@test [(i.module_name, i.field_name) for i in compiled.imports] == [(\"wasmtarget\", \"stack_trace\")]"]
            # the receiver-free rejection, pinned where it is exercised (the reject is
            # Julia's own console write, located at its statement)
            diag_src = read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            diag_required = ["receiver-free print/println/show reject loudly at their statement",
                             "e.diag.stmt_idx > 0 && !isempty(e.diag.stmt)"]
            docs_required = ["Verify interactive docs islands compiled",
                             "window.TherapyHydrate[\"examplelorenz\"]"]
            count(p -> occursin(p, src_all), forbidden) +
                count(p -> !occursin(p, mbv_src), required) +
                count(p -> !occursin(p, diag_src), diag_required) +
                count(p -> !occursin(p, docs_ci), docs_required)
        end),
    "L92_runtime_predicates_and_bottom_edges_are_exact" => ("`UnionAll(v, t)` is the jl_type_unionall foreigncall, which constructs a type (boot.jl): its lowering is jltypes.c's jl_type_unionall over the runtime jl_has_typevar (get_has_typevar_function!), and nothing retypes its result (it was read as an `isa UnionAll` predicate, answered by a ref.test of v and typed Bool; restated 2026-09-27); bottom phi producers preserve their real terminator without inventing a runtime type, and a phi source without a local that is a phi or `nothing` is a codegen bug (restated 2026-09-28)",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            forbidden = ["jl_type_unionall` (no lowering)",
                         "get_concrete_wasm_type(Union{}",
                         "node isa NirForeignCall && node.c_symbol === :jl_type_unionall",
                         "ref_test!(b, Int64(unionall_idx), false)",
                         "UnionAll(v, t) builds a type at run time (jl_type_unionall)"]
            required = [":jl_type_unionall => _fc_jl_type_unionall!",
                        "call!(b, get_has_typevar_function!(ctx.mod, reg)",
                        "A bottom producer has no runtime value to classify or coerce",
                        "is a phi or `nothing` without a local"]
            all_src = context_src * stmts_src * stack_src
            count(p -> occursin(p, all_src), forbidden) +
                count(p -> !occursin(p, all_src), required)
        end),
    "L64_no_unknown_numeric_type_guess" => ("unknown values and unresolved globals retain Any instead of being guessed as Int64",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            forbidden = ["If we can't evaluate, default to Int64",
                         "phi_julia_type = Int64", "phic_julia_type = Int64",
                         "phi_wasm_type = I64  # Default for Any/Union"]
            nir_src = read(joinpath(SRC, "frontend", "nir.jl"), String)
            # an unbound global's type is Any (the boundary's julia_type), and a node that is no
            # operand has no type to guess: value_type raises
            required = ["T = constant ? Core.Typeof(val) : bound ? Core.get_binding_type(x.mod, x.name) : Any",
                        "Preserve missing type evidence as Any",
                        "    error(\"value_type of \$(node), which is not an operand\")\nend"]
            count(p -> occursin(p, context_src), forbidden) +
                count(p -> !occursin(p, context_src * nir_src), required)
        end),
    "L63_no_control_or_allocation_defaults" => ("dynamic dispatch and Bool conditions never synthesize values; partial %new uses null only as Julia's explicit undefined-reference sentinel and rejects missing physical values",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            stmts_src = read(joinpath(CODEGEN, "statements.jl"), String)
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            forbidden = ["push_default! =", "drop!(b); i32_const!(b, 0)",
                         "emit default values for the missing fields"]
            required = ["value-producing dynamic dispatch selected a void target",
                        "Bool condition has a non-boolean reference representation",
                        "struct construction leaves a non-reference Julia field undefined",
                        "_wt_make_undefined_field"]
            count(p -> occursin(p, calls_src) || occursin(p, values_src) || occursin(p, stmts_src), forbidden) +
                count(p -> !(occursin(p, calls_src) || occursin(p, values_src) ||
                             occursin(p, stmts_src) || occursin(p, test_src)), required)
        end),
    "L62_exact_primitive_reinterpret_layout" => ("primitive ReinterpretArray construction folds exact bits/padding predicates, preserves runtime dimension errors, and bottom helpers never acquire a result representation",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            stack_src = read(joinpath(CODEGEN, "stackified.jl"), String)
            test_src = read(joinpath(ROOT, "test", "reinterpret_array_semantics.jl"), String)
            required = ["Base.isbitstype(", "{S<:_WT_PRIMITIVE_BITS,T<:_WT_PRIMITIVE_BITS} = true",
                        "ctx.return_type === Union{}", "ctx.return_type !== Union{}",
                        "_reinterpret_invalid_dimension"]
            count(p -> !(occursin(p, interp_src) || occursin(p, context_src) ||
                         occursin(p, stack_src) || occursin(p, test_src)), required)
        end),
    "L61_one_pure_interpolation_path" => ("Base.print_to_string is one pure-Julia overlay route and no invoke arm may truncate Int64 interpolation through Int32",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["elseif name === :print_to_string", "string interpolation requires int_to_string"]
            required = ["function Base.print_to_string(xs...)", "typemax(Int64)", "typemin(Int64)"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !(occursin(p, interp_src) || occursin(p, test_src)), required)
        end),
    "L60_no_fabricated_exception_payloads" => ("exception lowering either initializes every Julia field exactly or rejects it; no null/zero/default exception fabrication remains",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            forbidden = ["struct_new_default!(_thrb", "Default: push null ref for ref fields",
                         "ref_null!(berr, ArrayRef)", "name === :throw || name === :throw_boundserror",
                         "PURE-9032: Error constructors"]
            test_src = read(joinpath(ROOT, "test", "no_fabricated_values.jl"), String)
            # error(...), throw payloads and tuple errors compile Julia's own bodies;
            # the builders that re-implemented them are deleted
            forbidden_builders = ["_invoke_error_b", "_invoke_throw_payload_b", "_invoke_tuple_error_b"]
            required = ["constant exception contains undefined fields"]
            test_required = ["err isa ErrorException && err.msg == \"bad n\"",
                             "compare_julia_wasm(_wt_exact_error_exception, Int64(1)).pass"]
            count(p -> occursin(p, calls_src) || occursin(p, invoke_src), forbidden) +
                count(p -> occursin(p, calls_src) || occursin(p, invoke_src), forbidden_builders) +
                count(p -> !(occursin(p, calls_src) || occursin(p, invoke_src)), required) +
                count(p -> !occursin(p, test_src), test_required)
        end),
    "L59_real_base_exception_helpers" => ("Bounds/Inexact/Domain/Overflow helper bodies construct and throw their real Julia exceptions; no name-routed null-payload helper family remains",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["Stash a ref.null any as exception", "no specific value for these",
                         "no specific value)"]
            required = ["_wt_bounds_helper_catch", "_wt_inexact_helper_catch",
                        "_wt_domain_helper_catch", "_wt_overflow_helper_catch"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L58_no_bottom_invoke_stub" => ("Bottom-returning invokes compile their collected target and preserve native catch flow; no generic null exception may replace an unresolved invoke",
        () -> begin
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["get(ctx.ssa_types, idx, Any) === Union{}",
                         "an :invoke with inferred rettype Union{}"]
            required = ["_wt_bottom_invoke_catch", "typemax(Int64)"]
            count(p -> occursin(p, invoke_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L57_exact_typeassert_exception" => ("proven typeassert failure throws a classed TypeError preserving func (:typeassert, the emitter's default; the UnionAll constructor passes :UnionAll, as jl_type_unionall's jl_type_error does), context, expected type, and the concretely boxed got value",
        () -> begin
            # The typeassert LOWERING is `_lower_typeassert!` (builtins.jl, an
            # identity-keyed BUILTIN_LOWERINGS entry since Phase 12F); the
            # `_emit_typeerror_throw!` helper it calls still lives in calls.jl.
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                        read(joinpath(CODEGEN, "builtins.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            required = ["function _emit_typeerror_throw!", "func::Symbol=:typeassert",
                        "for (i, v) in enumerate((func, \"\", target))",
                        "push_got!(b, field(4))",
                        "_emit_typeerror_throw!(fb, ctx, _ta_target, (bb, w) -> emit_value!(bb, args[1], ctx, w))",
                        "err.expected === String", "err.got isa Int64"]
            forbidden = ["null-payload throw", "union_bottom_throw_stub shape"]
            count(p -> !occursin(p, calls_src * test_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L56_real_bottom_exception_bodies" => ("Union{} functions compile their actual Julia body and preserve catchable exception identity; no null-payload whole-body stub may replace them",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            test_src = read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String)
            forbidden = ["union_bottom_throw_stub", "Auto-stub functions that always throw",
                         "if return_type === Union{}"]
            required = ["_wt_bottom_throw", "err isa ArgumentError"]
            count(p -> occursin(p, compile_src), forbidden) +
                count(p -> !occursin(p, test_src), required)
        end),
    "L55_static_type_rendering_excludes_compiler_metadata" => ("Type{T} stays specialized through string/print/show so generated-function Method metadata never enters the runtime constant graph",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            required = ["Base.string(::Type{T})", "Base.print(io::IO, ::Type{T})",
                        "Base.show(io::IO, ::Type{T})", "_wt_type_name_str(T)",
                        "f === _wt_type_name_str"]
            count(p -> !occursin(p, interp_src), required)
        end),
    "L54_statistics_compiles_from_its_source" => ("Statistics compiles from its own source: no extension and no overlay of a Statistics method anywhere in ext/ or src/. Until 2026-09-29 six overlays replaced cor, corm, _quantilesort!, mean! and (on 1.13) the median and quantile wrappers; deleted, Julia's bodies matched native in every case of the Statistics lane on 1.12 and 1.13 (dev/CHARTER.md C3)",
        () -> begin
            project = read(joinpath(ROOT, "Project.toml"), String)
            isfile(joinpath(ROOT, "ext", "WasmTargetStatisticsExt.jl")) +
                occursin("WasmTargetStatisticsExt", project) +
                count_sites(r"@overlay\s+\S+\s+(?:function\s+)?Statistics\."; roots=[SRC, joinpath(ROOT, "ext")])
        end),
    "L53_pure_dense_linalg_kernels" => ("dense float norm/opnorm and mutating vector kernels stay in pure Julia with homogeneous signatures and one explicitly validated index domain (rotate!/reflect! compile Julia's own bodies since 2026-09-29, so they are no longer overlays)",
        () -> begin
            linalg_src = read(joinpath(ROOT, "ext", "WasmTargetLinearAlgebraExt.jl"), String)
            required = ["LinearAlgebra.norm(x::Array{T,N})",
                        "LinearAlgebra.opnorm(", "_wt_osj_svdvals(A)",
                        "a::T, x::Vector{T}, y::Vector{T}",
                        "a::T, x::Vector{T}, b::T, y::Vector{T}",
                        "length(x) == length(y)", "for i in eachindex(x)"]
            forbidden = ["for i in eachindex(x, y)",
                         "LinearAlgebra.norm(x::Vector{T})"]
            count(p -> !occursin(p, linalg_src), required) +
                count(p -> occursin(p, linalg_src), forbidden)
        end),
    "L52_dynamic_storage_owner_and_generic_norm" => ("pointer consumers retain runtime Memory/MemoryRef ownership across allocation phis, memmove returns its exact destination, and float norm uses LinearAlgebra's pure generic reference path instead of BLAS FFI",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            linalg_src = read(joinpath(ROOT, "ext", "WasmTargetLinearAlgebraExt.jl"), String)
            required = ["owner_is_memory ? owner_arg",
                        "Canonicalize repeated `.mem` projections",
                        "emit_value!(b, dest_ptr_arg, ctx, I64)",
                        "LinearAlgebra.generic_norm2(x)",
                        "LinearAlgebra.generic_normp(x, p)"]
            forbidden = ["memmove returns dest ptr — push i64.const 0"]
            all_src = statements_src * linalg_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L51_no_escaping_or_ambiguous_storage_pointers" => ("jl_value_ptr is an exact storage-relative offset only under whole-use-graph proof; escaping values and phis over different backing objects reject",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["_storage_relative_pointer_is_closed(ctx, idx)",
                        "jl_value_ptr escapes storage-relative WasmGC operations",
                        "phi-multiple-storage",
                        "soundness_fatal=true"]
            forbidden = ["fake-pointer", "fake pointer"]
            all_src = statements_src * calls_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L50_julia_call_result_and_reinterpret_bits" => ("a call's result type is Julia's own answer — the statement's type, or, where Julia stopped at its max_methods cutoff and typed a call to a known function `Any`, the call is the dynamic dispatch Julia's IR asks for, its result the dispatched method's, read at run time (codegen re-infers nothing: closed_world_call_result, which lifted the cutoff, was deleted 2026-10-11, L152) — never its first argument's type, a field's type, or a join over the registry's specializations; the typeId dispatch converts each target's result to that statement type; an unused `:invoke` reads the return type of the function its MethodInstance compiles to (get_function_by_mi: a planned body's rettype in the plan, a declared import's declared one), never another registry entry's — proven numeric phis are globally typed, and primitive ReinterpretArray operations use structural value bits rather than host layout queries",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["result_julia = get(ctx.ssa_types, idx, Any)",
                        "local target = get_function_by_mi(ctx.func_registry, rec.node.mi)",
                        "ctx.ssa_types[_jk] = _jv",
                        "foreach(observe_type!, T.parameters)",
                        # a `%new`'s class, as every concretely typed statement's (the one class set's statement rule)
                        "(made isa DataType && isconcretetype(made)) && observe_type!(made)",
                        "entry.specTypes",
                        "target_type <: atypes[p]",
                        "ssig = Tuple{Core.Typeof(g), spec...}",
                        "local selected = wt_method_which(ssig)",
                        "Base.array_subpadding",
                        "Core.bitcast(T, bits)",
                        "% TargetBits",
                        "% SourceBits"]
            forbidden = ["getfield(a, :parent)", "closed_world_call_result",
                         "infer_call_type", "foldl(typejoin, returns)", "infos[1].return_type",
                         "candidate <: actual", "info.arg_types...} == spec"]
            all_src = context_src * interp_src * trim_src * calls_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L49_monomorphic_invokes_and_typed_args" => ("explicit invokes specialize from concrete SSA types and every argument converts at emission; positional post-push repairs and runtime-generic _compute_sparams lowering are forbidden. _closed_world_edge types each operand as the edge's consumer reads it: a finalizer's and a `:cfunction`'s by Julia's argextype (value_type over the slot types and the boundary's SSA types, no join), as Julia's queue does (typeinfer.jl:1353, :1361 on 1.12.7; :1502, :1510 on 1.13.1); the `:new_function` edge specializes `Tuple{node.T, Vararg}`, typing no operand (:1523 on 1.13.1); an :invoke re-specialization, a splat and an invoke_in_world by the call-site type codegen's call reads (_edge_arg_type: value_type over the body's joins, _body_joins: its numeric joins and its captured-box reads, plan.joins' union), so the MethodInstance collected is the one called (dev/AUDIT.md A13P8)",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            invoke_src = read(joinpath(CODEGEN, "invoke.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            required = ["arg_types = Any[arg_type(a) for a in node.operands]",
                        "local body = _body_joins(joins, capture, mi, src, nir, slot_types)\n    return a -> value_type(a, slot_types, body)",
                        "local _call_type = let st = nir_slot_types(src), j = _body_joins(numeric_joins, capture, host_mi, src, nir, st)",
                        "local argextype(a) = value_type(a, slot_types, nothing)   # Julia's queue's operand type",
                        "Tuple{argextype(node.operands[1]), argextype(node.operands[2])}",
                        "mi = CC.compileable_specialization_for_call(interp, Tuple{argextype(ops[2]),",
                        "matches = wt_method_matches(ftype)",
                        "f isa Function || f isa Type",
                        "target.arg_types[(takes_closure ? 2 : 1):end]",
                        "Push arguments through the resolved target signature",
                        "Base.ReinterpretArray{T,N,S,A,false}"]
            forbidden = ["only handle the case where the LAST arg",
                         "Also handle middle args if needed",
                         "extern_convert_emitted_args", "compile_compute_sparams"]
            all_src = trim_src * invoke_src * calls_src * interp_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L48_exact_mutable_global_initialization" => ("mutable GlobalRefs use identity-keyed exact initializer functions behind the one module start; fabricated default objects and silent partial emission are forbidden",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            all_src = compile_src * context_src * types_src * values_src
            required = ["mutable_constant_globals", "module_init_functions",
                        "finalize_module_initializers!", "function_wasm_signature",
                        "is not defined in its source module"]
            forbidden = ["module_globals", "patched at runtime, so exact field values don't matter",
                         "If we can't evaluate, might be a type reference"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L47_single_memmove_lowering" => ("memmove/memcpy has one array-copy lowering and its one pointer walk recognizes Vector, Memory, String, and Symbol backing identities",
        () -> begin
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["st.c_symbol in (:jl_string_ptr, :jl_symbol_name)",
                        "backing_type === String || backing_type === Symbol",
                        ":memmove => _fc_memmove!", ":memcpy => _fc_memmove!"]
            count(p -> !occursin(p, stmt_src), required) +
                abs(length(collect(eachmatch(r"function _fc_memmove!\(", stmt_src))) - 1)
        end),
    "L46_symbol_syntax_value_metadata" => ("operator and syntactic-operator classification of ANY name, literal or built at run time, is Julia's parser answer: Base._isoperator / Base.is_syntactic_operator are overlaid by the port of julia-parser.scm `operator?` / `syntactic-op?` over tables read from jl_is_operator / jl_is_syntactic_operator at build time; no classed string carries a baked flag and no foreigncall lowering answers from one (a Symbol built from bytes once trapped there)",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            all_src = join((read(joinpath(CODEGEN, f), String) for f in readdir(CODEGEN) if endswith(f, ".jl")), "\n")
            required = ["@overlay WASM_METHOD_TABLE Base._isoperator(s::Symbol) = _wt_parser_is_operator(String(s))",
                        "@overlay WASM_METHOD_TABLE function Base._isoperator(s::AbstractString)",
                        "@overlay WASM_METHOD_TABLE Base.is_syntactic_operator(s::Symbol) =",
                        "function _wt_parser_is_operator(s::String)::Bool",
                        "function _wt_op_suffix_start(s::String)::Int",
                        "const _WT_NO_SUFFIX_OPERATORS"]
            forbidden = ["syntax_flags", ":jl_is_operator =>", ":jl_is_syntactic_operator =>",
                         "lacks operator metadata", ":name_is_operator", ":singleton_is_operator",
                         "ASCII-only operator", "name === :jl_is_operator"]
            count(p -> !occursin(p, interp_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L45_one_source_slot_and_vararg_abi" => ("semantic Core.Argument source types have one slot authority while the one physical vararg projection path maps fixed-prefix packs by their ABI offset",
        () -> begin
            context_src = read(joinpath(CODEGEN, "context.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            helpers_src = read(joinpath(CODEGEN, "helpers.jl"), String)
            required = ["T = value_type(ctx, NirArgument(source_slot))", "    value_type(node, ctx.slot_types, ctx.ssa_types)",
                        "function packed_vararg_source_type",
                        "packed_type = packed_vararg_source_type(ctx, val.n, arg_idx)",
                        "Reconstruct the one source-level vararg tuple",
                        "local _gft_fixed = args[1].n - 2",
                        "physical_offset + i - 1", "_gft_result_T isa Union ? AnyRef",
                        "function is_builtin_func"]
            forbidden = ["ctx.code_info.slottypes[args[1].n]",
                         "ctx.code_info.slottypes[val.id]",
                         "func.name in (:isdefined, :getfield, :setfield!) && func.mod in"]
            all_src = context_src * calls_src * values_src * flow_src * helpers_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L44_interned_module_metadata" => ("Module is one interned identity object with exact name/parent and collected binding visibility metadata; no empty shell or TypeName module-name string surrogate remains",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            all_src = types_src * values_src * calls_src * stmt_src
            required = ["get_module_constant_global!", "_closed_world_isvisible",
                        "emit_closed_world_isvisible!", "name_visible_main",
                        ":jl_module_parent => _fc_jl_module_parent!", ":jl_module_name => _fc_jl_module_name!"]
            forbidden = ["Module constant — empty struct", "module_name (mut string ref)",
                         "module_name → string"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L43_typename_world_bounds_metadata" => ("mutable Julia BindingPartition history is reduced once to exact immutable TypeName world-bound metadata; no partial Binding object or fake partition chain exists",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            all_src = types_src * calls_src * interp_src * trim_src
            required = ["world_bounded", "Base.check_world_bounded(tn)",
                        "emit_closed_world_type_bounds!",
                        "_closed_world_type_bounds", "f === _closed_world_type_bounds"]
            forbidden = ["registry.structs[Core.Binding]",
                         "registry.structs[Core.BindingPartition]",
                         "jl_bpart_get_restriction_value"]
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L42_exact_unicode_property_table" => ("utf8proc category/width and Julia identifier predicates share one exact version-matched packed table and one pre-indexed helper, and Base's Char case mapping/predicates read utf8proc's own case records through the same two-stage lookup; target Wasm never substitutes ASCII-only answers",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["const _UTF8PROC_PROPERTY_DATA",
                        "get_or_create_unicode_property_func!",
                        "needs_unicode_properties && get_or_create_unicode_property_func!",
                        ":utf8proc_category => _fc_utf8proc_category!",
                        ":utf8proc_charwidth => _fc_utf8proc_charwidth!",
                        ":jl_id_start_char => _fc_jl_id_start_char!", ":jl_id_char => _fc_jl_id_char!",
                        "const _UTF8PROC_CASE_DATA",
                        "needs_unicode_case && get_or_create_unicode_case_func!",
                        ":utf8proc_toupper => _fc_utf8proc_toupper!", ":utf8proc_tolower => _fc_utf8proc_tolower!",
                        ":utf8proc_totitle => _fc_utf8proc_totitle!", ":utf8proc_isupper => _fc_utf8proc_isupper!",
                        ":utf8proc_islower => _fc_utf8proc_islower!"]
            forbidden = ["assume valid, conservative", "true = always a grapheme break"]
            all_src = types_src * compile_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L41_cross_calls_share_builder_stack" => ("cross-function argument pushes, call pops, and result coercion execute on the same authoritative builder stack",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["local _xcb = fb", "Arguments already live on `fb`"]
            forbidden = ["local _xcb = _ctx_builder(ctx, \"compile_call\")\n                call!(_xcb, target_info.wasm_idx"]
            count(p -> !occursin(p, calls_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L40_explicit_invokes_in_closed_world" => ("every explicit invoke MethodInstance is enrolled in the joint reachability fixpoint, an invoke whose concrete call-site types select another MethodInstance retargeted in place (nir_retarget_invoke!) so its edge agrees with the overlay dispatch, recomputed every round from Julia's own MethodInstance (invoke_originals), so a round's retarget made under a capture typing a later round widens is restored, never kept (dev/AUDIT.md A16C1: smoke capture_typed_invoke trapped, native 19; dev/formal/ClosedWorld.tla RetargetsSound); an unspecialized Vararg signature becomes a physical Wasm entry ONLY as the one packed runtime-Vararg-tuple parameter — the {Object, data, size} struct the splat call site already holds (Phase 12 H) — and every other open-ended signature is still skipped",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["function _missing_explicit_invoke_mis",
                        "changed = collect_new_pairs!(_missing_explicit_invoke_mis(",
                        "if kind === :invoke",
                        "nir_retarget_invoke!(src, nir, k, mi)",
                        "original_mi = originals === nothing ? mi : get(originals, k, mi)",
                        "if mi isa Core.MethodInstance && mi !== current_mi",
                        "if any(T -> T isa Core.TypeofVararg, arg_types)",
                        "is_runtime_vararg_tuple_type(packed_vararg) || continue",
                        "arg_types = (packed_vararg,)"]
            count(p -> !occursin(p, trim_src), required) +
                (occursin("_g(\"capture_typed_invoke\"", read(joinpath(ROOT, "test", "smoke.jl"), String)) ? 0 : 1)
        end),
    "L39_only_proven_dead_traps" => ("unsupported lowering rejects unless its Julia CFG block is proven unreachable; non-dominance is never treated as deadness",
        () -> begin
            diag_src = read(joinpath(CODEGEN, "diagnostics.jl"), String)
            gen_src = read(joinpath(CODEGEN, "generate.jl"), String)
            # (the byte-vector emit_unsupported_stub! method, which carried `!_dead`, is deleted:
            # every stub goes through the builder method)
            required = ["function stmt_is_proven_unreachable",
                        "!stmt_is_proven_unreachable",
                        "soundness_fatal=(soundness_fatal && !_dead2)"]
            forbidden = ["soundness_fatal && _me", "soundness_fatal && _me2",
                         "sound *silent* trap", "A non-must-execute"]
            count(p -> !occursin(p, diag_src * gen_src), required) +
                count(p -> occursin(p, diag_src), forbidden)
        end),
    "L38_no_known_value_substitutions" => ("known Memory, ifelse, allocation, grapheme and isa gaps reject instead of substituting null, zero, one, or an arbitrary arm; an isa of an unboxed numeric answers Julia's own subtype test of its exact type",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            # The ifelse LOWERING is `_lower_ifelse!` (builtins.jl, an
            # identity-keyed BUILTIN_LOWERINGS entry since Phase 12F).
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                        read(joinpath(CODEGEN, "builtins.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["Memory constant of type \$T has an undefined slot",
                        "array.new_fixed 0",
                        "ifelse condition did not lower to i32",
                        "ifelse operand emitted no runtime value",
                        # an unlowered foreigncall (utf8proc's grapheme state machine
                        # among them) rejects at its statement, never a constant
                        "record_unsupported!(ctx, :unsupported_method, \"foreigncall `\$(name)` (no lowering)\"; idx=idx, detail=node)",
                        "jl_alloc_string without its required length operand",
                        "_isa_reject!(bld, ctx, \"isa(x, T) with a runtime type T\")",
                        "i32_const!(bld, isa2_julia <: check_type ? 1 : 0)",
                        "i32_const!(bld, isa3_julia <: check_type ? 1 : 0)"]
            forbidden = ["Memory constant too large to materialize (\$n_mem elements) — emitting null",
                         "Fall back to emitting just the true value",
                         # isa: a constant in place of a test (calls.jl _compile_call_isa)
                         "Unknown concrete type — can't test, return false",
                         "Unknown type - drop value and return false",
                         "can never be Nothing, so isa(x, T) is true",
                         "I64=>Int64, I32=>Int32, F64=>Float64, F32=>Float32",
                         "true = always a grapheme break", "_fc_utf8proc_grapheme_break_stateful!"]
            all_src = values_src * calls_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L37_no_fabricated_constant_fields" => ("constant fallbacks emit the registered Object prefix and every real field through its physical expected type; undefined fields are rejected",
        () -> begin
            values_src = read(joinpath(CODEGEN, "values.jl"), String)
            required = ["WT never fabricates field values",
                        "emit_struct_prefix!(b, ctx.type_registry, T, info)",
                        "emit_value!(b, NirLiteral(field_val), ctx, expected; from_julia=typeof(field_val))"]
            forbidden = ["emit ref.null for the field's expected type",
                         "type-correct defaults",
                         "mismatched concrete struct ref"]
            count(p -> !occursin(p, values_src), required) +
                count(p -> occursin(p, values_src), forbidden)
        end),
    "L36_no_hash_dispatch_residue" => ("the live selector registry contains no FNV-era hash/table/global fields and never fabricates a numeric value for a void target",
        () -> begin
            dispatch_src = read(joinpath(CODEGEN, "dispatch.jl"), String)
            forbidden = ["hash::UInt32", "table_size::Int32", "mask::Int32",
                         "keys_global_idx::", "values_global_idx::", "typeids_global_idx::",
                         "func_table_idx::", "i32_array_type_idx::",
                         "VALUE-typed dispatch signature over a", "MIRROR hole"]
            required = ["all_no_return ? nothing"]
            count(p -> occursin(p, dispatch_src), forbidden) +
                count(p -> !occursin(p, dispatch_src), required)
        end),
    "L34_single_pointer_lowering" => ("add_ptr/sub_ptr/pointerref/pointerset each have one compile_call lowering route",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            sum(max(count(line -> occursin("func.name === :$(name)", line), split(calls_src, '\n')) - 1, 0)
                for name in (:add_ptr, :sub_ptr, :pointerref, :pointerset))
        end),
    "L35_unwrapped_emissions_classified" => ("every intentional no-expectedType emission is explicitly classified by why its actual type is the consumer contract",
        () -> count(site -> !occursin("R17-floor:", site[3]), untyped_value_emissions())),
    "L32_empty_tuple_egal" => ("Tuple{} is an immutable zero-field singleton, so two of them are egal without heap identity: the static egal arm answers one singleton type with 1, and the runtime egal function answers 1 for any singleton class once the two classIds match (dev/CHARTER.md C3)",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["if concrete && Base.issingletontype(T)\n        i32_const!(b, 1)",
                        "local single = Base.issingletontype(C) && !(C <: Type)",
                        "    if single\n        i32_const!(b, 1)"]
            count(p -> !occursin(p, calls_src), required)
        end),
    "L31_multi_container_apply" => ("homogeneous multi-Vector _apply_iterate reductions traverse every container through one loop generator and never return an identity for Julia's invalid all-empty +()/*() call",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            required = ["container_args = args[3:end]",
                        "for (container_arg, container_type) in zip(container_args, container_types)",
                        "emit_method_error!(bld, ctx.mod, ctx.type_registry, Tuple{},",
                        "MethodError(f, (), world)",
                        "Int64(WASM_WORLD_AGE)",
                        "reduce_op = operator_intrinsic(target_value, elem_type)",
                        "reduce_op in (:sub_int, :sub_float) && (reduce_op = nothing)",
                        "local_set!(bld, has_value)"]
            forbidden = ["_get_binary_reduce_opcode(func_name"]
            count(p -> !occursin(p, calls_src), required) +
                count(p -> occursin(p, calls_src), forbidden)
        end),
    "L30_runtime_vararg_tuple" => ("Core._apply_iterate uses a real Object/data/size representation for runtime Vararg tuples, and isa of one against a tuple type (Tuple{} included) tests its runtime arity against the lengths that type admits; it never fabricates an empty tuple (restated 2026-10-06 when the Tuple{} test became every length's, A5E3, and every tuple type's, A6E1)",
        () -> begin
            calls_src = read(joinpath(CODEGEN, "calls.jl"), String)
            structs_src = read(joinpath(CODEGEN, "structs.jl"), String)
            required = ["_iterable_proven_empty(container_arg, ctx)",
                        "register_vararg_tuple_type!",
                        "is_runtime_vararg_tuple_type",
                        "unsupported Vararg tuple layout",
                        "result_type=result_type",
                        "so it is a T exactly for the lengths T admits"]
            forbidden = ["produces a Tuple{Vararg{Symbol}} which is checked",
                         "must emit a struct.new of the actual Tuple{} type"]
            all_src = calls_src * structs_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden)
        end),
    "L29_recursive_type_groups" => ("the type section's recursion groups are its strongly connected components, computed when it is written and never declared: each a contiguous run of indices, every reference out of a group backward, and a type refers only to types defined before it or in its group; a struct, tuple, Vector wrapper, array or MemoryRef box whose fields reach it again registers pending and is added with its component (finish_pending!, dev/formal/RecGroup.tla), never erased to an abstract ref, patched after a placeholder, or tracked in process-global or task-local registration state (restated 2026-09-28 from the declared, placeholder-and-patch groups)",
        () -> begin
            builder_src = read(joinpath(SRC, "builder", "instructions.jl"), String)
            codegen_src = read(joinpath(CODEGEN, "structs.jl"), String) * read(joinpath(CODEGEN, "types.jl"), String)
            required = [
                "function recursion_groups(mod::WasmModule)::Vector{UnitRange{Int}}",
                "is not a contiguous run of indices",
                "refers forward to type",
                "function add_type_group!(mod::WasmModule, types::Vector{CompositeType})::UInt32",
                "_check_refs_defined(mod, ct, length(mod.types))",
                "local groups = recursion_groups(mod)",
                "function finish_pending!(mod::WasmModule, registry::TypeRegistry, id::UInt32, ct::CompositeType)::UInt32",
                "local id = begin_pending!(registry, :arrays, elem_type)",
                "local id = begin_pending!(registry, :memoryref_box_idxs, T)",
            ]
            forbidden = ["add_rec_group!", "rec_groups", "_registering_types", "is_self_referential_type",
                         "mod.types[reserved_idx", "_struct_reg_stack", "TaskLocalDict",
                         "ensure_nominal_struct_types!", "const _STRUCT_REG_STACK"]
            all_src = builder_src * codegen_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), forbidden) +
                abs(count("begin_pending!(registry, :structs, T)", codegen_src) - 3)
        end),
    "L28_ordinary_object_prefix" => ("ordinary structs, tuples, and Array wrappers inherit Object's classId/identityHash prefix through one representation-aware allocation funnel (each registrar records field offset 2 when it records its type pending, finish_pending!; restated 2026-09-28)",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            structs_src = read(joinpath(CODEGEN, "structs.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = [
                "object_prefix_fields()",
                "emit_object_prefix!",
                "emit_struct_prefix!",
                "fields = value_branch ? FieldType[FieldType(I32, false)] : object_prefix_fields()",
                "T <: Number ? registry.base_struct_idx : get_object_struct_type!",
                "wasm_fields = object_prefix_fields()",
                "if T === Core.Box",
                "StructInfo(T, idx, [:contents], Type[Any], UInt32(1))",
                "Type[fieldtype(T, i) for i in 1:fieldcount(T)], UInt32(2))",
                "Type[ft isa DataType ? ft : Any for (_, ft) in fixed], UInt32(2))",
                "Type[Array{elem_type, 1}, size_tuple_type], UInt32(2))",
                "emit_struct_prefix!(b, ctx.type_registry, struct_type, info)",
                "ctx.type_registry.structs[object_type].field_offset == 2",
            ]
            all_src = types_src * structs_src * stmt_src
            count(p -> !occursin(p, all_src), required) +
                count(p -> occursin(p, all_src), ["set_struct_supertypes!"])
        end),
    "L27_no_postbuilder_byte_truncation" => ("the finalized typed instruction IR is authoritative; no raw-byte scanner may truncate or repair function bodies afterward",
        () -> begin
            gen_src = read(joinpath(CODEGEN, "generate.jl"), String)
            flow_src = read(joinpath(CODEGEN, "flow.jl"), String)
            builder_src = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            missing = count(p -> !occursin(p, gen_src * flow_src * builder_src),
                            ["finish_function!(b)", "structured IR has"])
            forbidden = count(p -> occursin(p, gen_src),
                              ["strip_excess_after_function_end", "Truncate everything after this byte",
                               "_last_instr_starts", "_instr_next", "_skip_leb_count",
                               "bytes[_tail", "dead returns at the very end"])
            missing + forbidden
        end),
    "L26_dispatch_roots_only" => ("dynamic selector candidates are only discovery roots; their transitive helper dependencies remain ordinary cross-call-visible functions",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["dynamic_roots::Set{Core.MethodInstance}", "union!(dynamic_roots, extra)",
                        "mi in world.dynamic_roots"]
            forbidden = ["pair_no > base_pairs", "_TRIM_BASE_PAIRS"]
            count(p -> !occursin(p, trim_src), required) + count(p -> occursin(p, trim_src), forbidden)
        end),
    "L25_flat_runtime_composition" => ("runtime-length composition is typed before optimization as a valid-Julia flat callable and allocated through normal struct codegen",
        () -> begin
            interp_src = read(joinpath(CODEGEN, "interpreter.jl"), String)
            call_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                       read(joinpath(CODEGEN, "builtins.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["struct _RuntimeComposition", "function CC.abstract_apply(interp::WasmInterpreter",
                        "_RuntimeComposition{container}", "_runtime_composition_apply",
                        "_emit_runtime_composition_context!", "register_closure_type!",
                        "T <: _RuntimeComposition"]
            forbidden = ["compose_and_call", "composition_callsite", "fake_composition"]
            all_src = interp_src * call_src * compile_src * trim_src
            count(p -> !occursin(p, all_src), required) + count(p -> occursin(p, all_src), forbidden)
        end),
    "L24_unified_static_tearoffs" => ("named-function tear-offs enroll in the closed world and use the same closure Object/context/vtable/RTI representation as capturing closures",
        () -> begin
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            required = ["callable_types::Set{DataType}", "isdefined(T, :instance)",
                        "typeof(f) in plan.callable_types", "takes_context ? 1 : 0",
                        "get_nothing_global!(ctx.mod, ctx.type_registry)"]
            forbidden = ["static_tearoff_struct", "tearoff_base_idx", "tearoff_callsite"]
            all_src = trim_src * compile_src * closure_src
            count(p -> !occursin(p, all_src), required) +
            count(p -> occursin(p, all_src), forbidden)
        end),
    "L23_closure_rti" => ("closure objects copy Dart's Object/context/vtable/functionType layout and use a real closed-world Julia type object",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            trim_src = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["FieldType(ConcreteRef(get_datatype_type_idx(registry), false), false)",
                        "haskey(type_globals, closure_type)",
                        "global_get!(b, type_global",
                        # the SSA-typed callable observation, now read off the boundary (Phase 12D)
                        "observe_callable!(s.julia_type)"]
            forbidden = ["functionType=ref.null", "dummy functionType", "placeholder functionType"]
            count(p -> !occursin(p, types_src * closure_src * trim_src), required) +
            count(p -> occursin(p, types_src * closure_src), forbidden)
        end),
    "L22_artifact_binaryen" => ("optimization uses Binaryen_jll's artifact executable and cannot silently depend on or skip for a system wasm-opt",
        () -> begin
            api_src = read(joinpath(SRC, "WasmTarget.jl"), String)
            tests_src = read(joinpath(ROOT, "test", "runtests.jl"), String)
            project_src = read(joinpath(ROOT, "Project.toml"), String)
            missing = count(p -> !occursin(p, api_src * project_src),
                            ["using Binaryen_jll: wasmopt", "Binaryen_jll =", "\$(wasmopt())",
                             "_binaryen_worker_count", "BINARYEN_CORES"])
            forbidden = count(p -> occursin(p, api_src * tests_src),
                              ["Sys.which(\"wasm-opt\")", "wasm-opt not found", "skipping optimization tests"])
            missing + forbidden
        end),
    "L21_packed_integer_arrays" => ("Int8/UInt8 and Int16/UInt16 arrays use packed Wasm GC storage and generic loads derive signedness from the Julia element type",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            load_src = read(joinpath(CODEGEN, "calls.jl"), String) *
                       read(joinpath(CODEGEN, "invoke.jl"), String)
            required = ["T === Int8 || T === UInt8 ? I8",
                        "T === Int16 || T === UInt16 ? I16",
                        "packed_array_signedness(elem_type)"]
            count(p -> !occursin(p, types_src * load_src), required) +
            count(_ -> true, eachmatch(r"signed=\(elem_type === UInt8", load_src))
        end),
    "L20_object_identity_layout" => ("Top owns classId; Object adds mutable identityHash; objectid reads/writes that slot and never fabricates a constant/content hash",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            closure_src = read(joinpath(CODEGEN, "closures.jl"), String)
            required = [
                "object_struct_idx::Union{Nothing, UInt32}",
                "StructType(fields, top)",
                "FieldType(I32, true)",
                "get_identity_counter_global!",
                "struct_get!(b, object_idx, UInt32(1))",
                "struct_set!(b, object_idx, UInt32(1))",
                "StructType(fields, object)",
                "struct_get!(tb, base_idx, UInt32(2))",
                "struct_get!(b, base_idx, UInt32(3))",
                "emit_classid_box!(tb, mod, registry, scratch, body.results[1], body.return_type)",
            ]
            all_src = types_src * stmt_src * closure_src
            missing = count(p -> !occursin(p, all_src), required)
            forbidden = count(p -> occursin(p, all_src),
                              ["constant 42", "array.len for strings", "fake identity", "fabricated identity"])
            missing + forbidden
        end),
    "L19_no_fabricated_invoke_results" => ("invoke/call lowering may not substitute dummy exceptions, empty strings, constant hashes, or null SimpleVectors",
        () -> count_sites(r"dummy anyref|emit empty string|fallback to constant hash|exception placeholder|benign null placeholder|union_bottom_throw_stub|Core\.svec \(SimpleVector construction\)")),
    "L18_no_value_repair_defaults" => ("PiNode, GlobalRef, returns, SSA stores, and struct fields preserve and coerce the emitted value; no zero/null repair helper or duplicate return ladder may remain",
        () -> begin
            statements_src = read(joinpath(CODEGEN, "statements.jl"), String)
            forbidden_count = count_sites(
                r"needs_type_safe_default|_emit_default!|_append_default!|_gv_replaced|ssa_type_mismatch|Push a type-correct default|compile_value produced empty bytes")
            forbidden_count +
                (occursin("emit_return_coerced!(b, node.value, ctx)", statements_src) ? 0 : 1)
        end),
    "L17_one_compilation_path" => ("public compilation always enters the closed-world planner; legacy discovery, recursive mode switching, byte shells, and legacy body compilers are extinct",
        () -> count_sites(r"_TRIM_ACTIVE|discovery=:legacy|discover_dependencies|AUTODISCOVER|FrozenCompilationState|InplaceCompilationContext|compile_from_ir_(?:inplace|prebaked)|compile_module_from_ir_frozen|compile_handler|compile_closure_body|compile_function_into!|compile_const_value|overlay_entries|_autodiscover_closure_deps!|run_selfhost|run_direct|to_bytes_mvp|FakeGlobalRef|wasm_compile_(?:flat|source)|function _compile_function_legacy|function compile_(?:value|statement|call|invoke|new|foreigncall|condition_to_i32)\([^!]")),
    "L16_no_codegen_lax_mode" => ("codegen correctness is unconditional: no strict keyword/field, paranoid environment toggle, or entry-vs-dependency downgrade state",
        () -> count_sites(r"strict::Bool|ctx\.strict|WT_PARANOID_STUBS|TRIM_ENTRY_NAMES";
                          exclude_files=["codegen/interpreter.jl"])),
    "L15_no_fabricated_ssa_store" => ("an emitted SSA value is coerced from its builder-tracked actual type; the drop-and-default store repair path is extinct",
        () -> count_sites(r"SSA-store type mismatch|value dropped, type-safe default|_cs4_func_ref")),
    "L14_no_posthoc_module_repair" => ("no codegen-crash or external-validator failure may be converted into an unreachable function body after the fact",
        () -> count_sites(r"_stub_invalid_isolated_funcs|dispatch-isolation|stubbing isolated|stub_names")),
    "L1_box_typeid_external" => ("emit_box_type_id! callers outside its home files (ONE box producer; locked 2026-06-30)",
        () -> count_sites(r"emit_box_type_id!\(";
                          exclude_files=["codegen/values.jl", "codegen/types.jl"],
                          exclude_line=r"function emit_box_type_id!")),
    "L2_ref_i31_callers" => ("no i31 value representation: the ref_i31!/i31_get_s!/i31_get_u! emitters and their RefI31/I31GetS/I31GetU nodes are deleted (the i31 box family went 2026-06-30; the emitters, left without a caller, went 2026-09-29) — a value is boxed through its class",
        () -> count_sites(r"ref_i31!|i31_get_[su]!|\bRefI31\b|\bI31Get[SU]\b")),
    "L9_no_unjustified_untyped_emission" => ("every untyped compile_value splice carries the god-fn-seam annotation; unjustified untyped emission is DEAD (M4; locked 2026-07-02)",
        () -> count_sites(r"compile_value\("; exclude_line=r"function compile_value\(|god-fn seam")),
    "L8_no_silent_traps" => ("every unreachable! is record_unsupported!-routed OR an annotated structural trap — NO silent stubs (M5; locked 2026-07-01)",
        () -> begin
            n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                endswith(f, ".jl") || continue
                recent = String[]
                for line in eachline(joinpath(dir, f))
                    if occursin(r"unreachable!\(", line) && !occursin("function unreachable!", line) &&
                       !startswith(lstrip(line), "#") &&
                       !occursin("structural trap", line) &&
                       !any(prev -> occursin("record_unsupported!", prev), recent)
                        n += 1
                    end
                    push!(recent, line)
                    length(recent) > 5 && popfirst!(recent)
                end
            end
            n
        end),
    "L7_wasmtools_demoted" => ("no always-on external-validate default may return — validity is the strict builder's job; wasm-tools is opt-in (validate=true / WT_VALIDATE=1) (M4; locked 2026-07-01)",
        () -> count_sites(r"validate::Bool\s*=\s*true")),
    "L6_all_builders_strict" => ("instruction validation is unconditional: no strict/enabled field, environment switch, setter, constructor keyword, production opt-out, or silently unmodeled opcode may exist.",
        () -> begin
            builder_root = joinpath(SRC, "builder")
            validator_src = read(joinpath(builder_root, "validator.jl"), String)
            required = ["unmodeled Wasm opcode", "unmodeled Wasm GC opcode"]
            forbidden_count = count_sites(
                r"InstrBuilder\([^)]*strict\s*=|_wt_builder_strict|set_strict!|strict::Bool|enabled::Bool|enabled\s*=|skip silently";
                roots=[builder_root])
            forbidden_count + count(p -> !occursin(p, validator_src), required)
        end),
    "L5_no_tagged_union" => ("the tagged-union wrapper family is DELETED — needs_tagged_union/emit_(un)wrap_union_value must never reappear (M3; locked 2026-07-01)",
        () -> count_sites(r"needs_tagged_union\(|emit_wrap_union_value\(|emit_unwrap_union_value\(")),
    "L4_no_postemit_reguess" => ("infer_value_wasm_type is GONE — renamed to static_wasm_type (pre-emit-ONLY contract); the post-emission re-guess anti-pattern is dead (M2; locked 2026-07-01)",
        () -> count_sites(r"infer_value_wasm_type\(")),
    "L13_no_byte_bridges" => ("no bytes enter a module body unvalidated: function bodies and global initializers are typed builders the module made. The builder has no raw-bytes path: every emission is a typed method or a tracked merge (append_builder!), and emit_raw! and its RawBytes instruction node are deleted (2026-09-29); a function's body bytes are written only by fill_function!, from its builder, and a global's initializer only by fill_global!, from its constant expression, so src/builder constructs a WasmFunction exactly twice (define_function!'s unfilled one and fill_function!'s) and a WasmGlobalDef exactly twice (define_global!'s and fill_global!'s), and nothing else does (L167; dev/CHARTER.md C7)",
        () -> count_sites(r"emit_raw!|RawBytes") +
              abs(count_sites(r"\bWasmFunction\(\w"; roots=[joinpath(SRC, "builder")], exclude_line=r"function WasmFunction\(|ArgumentError") - 2) +
              abs(count_sites(r"\bWasmGlobalDef\("; roots=[joinpath(SRC, "builder")], exclude_line=r"^\s*WasmGlobalDef$") - 2) +
              count_sites(r"\bWasmFunction\(|\bWasmGlobalDef\("; roots=[CODEGEN, joinpath(SRC, "frontend"), joinpath(ROOT, "ext")])),
    "L12_god_fn_seams_only" => ("every emit_raw! splice is an ANNOTATED god-fn seam or front — the byte-bridge class is closed to new members; R2 falls only by killing seams (march3; locked 2026-07-04)",
        () -> count_sites(r"emit_raw!\(";
                          exclude_line=r"function emit_raw!|god-fn seam|THE front seam|`emit_raw!")),
    "L11_driver_fronts" => ("driver-level byte splices flow ONLY through the declared fronts (compile_statement!/generate_stackified_flow!/_compile_catch_region! builder methods) — no raw driver splices at call sites (M11.3; locked 2026-07-03)",
        () -> count_sites(r"emit_raw!\(\w+, (?:generate_stackified_flow|compile_statement|generate_branch_split_try)\(";
                          exclude_line=r"THE front seam|pops=1|declared push|god-fn seam")),
    "L10_no_fnv_dispatch" => ("the FNV-1a hash-dispatch apparatus is DELETED — dispatch is dart's ONE selector table, classId + offset + call_indirect (M8.4; locked 2026-07-03)",
        () -> count_sites(r"fnv1a_hash\(|FNV_OFFSET_BASIS\b|FNV_PRIME\b|_emit_table_probe_body|OverlayRegistry\b";
                          exclude_files=["codegen/types.jl"])),
    "L3_legacy_flow_family" => ("ALL legacy lowering strategies — nested_conditionals/if_then_else/nested_if_else/void_flow/linear_flow/loop_code/branched_loops/complex_flow router (M1 COMPLETE: ONE lowering = the stackifier; DELETED + locked 2026-07-01)",
        () -> count_sites(r"generate_nested_conditionals\(|generate_if_then_else\(|compile_nested_if_else\(|generate_void_flow\(|generate_linear_flow\(|generate_loop_code\(|generate_branched_loops\(|generate_complex_flow\(";
                          exclude_line=r"function (generate_nested_conditionals|generate_if_then_else|compile_nested_if_else|generate_void_flow|generate_linear_flow|generate_loop_code|generate_branched_loops|generate_complex_flow)\(")),
    "L99_emit_raw_bridges_extinct" => ("emit_raw!( byte-bridges into the typed builder — EXTINCT since march4; the typed branch/try/catch generators emit structurally (locked 2026-09-01)",
        () -> count_sites(r"emit_raw!\("; exclude_line=r"function emit_raw!|`emit_raw!")),
    "L100_try_drivers_unified" => ("shape-specialized try/catch drivers — THE ONE stackifier owns all CFG shape generation (march 6 → locked 2026-09-01)",
        () -> count_sites(r"^function (generate_(try_catch|branch_split_try|catch_arm|catch_try_chain|sequential_try_catch|nested_try_catch)|_compile_(catch_region|try_body))";
                          exclude_line=nothing)),
    "L101_catch_all_clauses_extinct" => ("a Julia region catches only the typed exception tag: every catch_legacy! in codegen names the exception tag by its handle, exc_tag(ctx.type_registry) (the tag ensure_provenance_imports! defines, held by recover_module_handles!, as the one throw site's throw_!(b, exc_tag(registry))), and there is no catch_all in src, neither a constructor nor an opcode nor an IR instruction, and codegen builds no InstrIR.CatchLegacy past the builder. No wasm catch observes stack exhaustion or a trap (legacy catch_all, a catch of the imported JSTag and catch_all_ref alike, measured on Node 22.23.3), so the export boundary is the host's glue (host_glue_js) and an export entry has no handler; dart's builder has no catch_all_legacy (instructions.dart:799 catch_legacy only). A catch of any other tag, a literal or computed, counts (dev/CHARTER.md C6)",
        () -> count_sites(r"\bcatch_legacy!\((?![^,()]+,\s*exc_tag\(ctx\.type_registry\)\s*\))"; roots=[CODEGEN]) +
              count_sites(r"catch_all|CatchAll|CATCH_ALL") +
              count_sites(r"InstrIR\.CatchLegacy\("; roots=[CODEGEN])),
    "L102_convert_ladders_unified" => ("convert_type! callers outside values.jl — all external calls folded into the 4-arg wrap (march 8 → locked 2026-09-01)",
        () -> count_sites(r"convert_type!\("; exclude_files=["codegen/values.jl"], exclude_line=r"function convert_type!")),
    "L103_anyref_dispatch_extinct" => ("fill(AnyRef dispatch signatures — EXTINCT; dart's per-param LUB is the selector mechanism (march 9 → locked 2026-09-01)",
        () -> count_sites(r"fill\(AnyRef"; exclude_line=nothing)),
    "L108_no_campaign_narration" => ("no march<N>/P2-batch<N> campaign-narration tags anywhere in src, comment lines included; constraint-bearing content stays as untagged comments, parity( anchors cite dart source (locked 2026-09-02)",
        () -> count_lines_all(r"march\d+|P2-batch"; roots=[SRC])),
    "L110_parity_anchors_cite_dart" => ("every parity( anchor in src cites a dart file:line at the pinned oracle commit or is an explicit quarantine — phase labels are narration, not anchors (locked 2026-09-02)",
        () -> count_lines_all(r"parity(?:-region)?\((?![A-Za-z0-9_/]+\.dart:\d+|quarantine:)"; roots=[SRC])),
    "L104_table_ops_have_no_ladder_arm" => ("per-symbol exclusivity: every op key in any INTRINSIC_* table has ZERO name-keyed is_func ladder arms anywhere in codegen — a table entry and an arm can never coexist, so a half-wired table cannot stall again (the M11 lesson; locked 2026-09-02)",
        () -> begin
            table_src = read(joinpath(CODEGEN, "intrinsics_table.jl"), String)
            keys_set = Set{Symbol}()
            # Extract keys from all INTRINSIC_* dict definitions — both 2-tuple and 3-tuple keys
            for m in eachmatch(r"\(\s*[A-Z0-9]+\s*,\s*[A-Z0-9]+\s*,\s*:([a-z_0-9]+)\s*\)\s*=>", table_src)
                push!(keys_set, Symbol(m.captures[1]))
            end
            for m in eachmatch(r"\(\s*[A-Z0-9]+\s*,\s*:([a-z_0-9]+)\s*\)\s*=>", table_src)
                push!(keys_set, Symbol(m.captures[1]))
            end
            n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                (endswith(f, ".jl") && f != "intrinsics_table.jl") || continue
                for line in eachline(joinpath(dir, f))
                    _iscomment(line) && continue
                    any(key -> occursin("is_func(func, :$(key))", line), keys_set) || continue
                    occursin("table residue", line) || (n += 1)
                end
            end
            n
        end),
    "L109_no_patch_marker_tags" => ("no PURE-/WBUILD-/CG-/TRUE-PARSE-/E2E- patch-tag tokens anywhere in src, comment lines included — constraint-bearing sentences stay as untagged comments (locked 2026-09-02)",
        () -> count_lines_all(r"(PURE|WBUILD|CG|TRUE-PARSE|E2E)-\d"; roots=[SRC])),
    "L106_dead_codegen_defs_extinct" => ("the dead codegen definitions the march census found stay deleted (locked 2026-09-02). JL_TYPE_KIND_UNION and JL_TYPE_KIND_UNIONALL left the list on 2026-09-27: every type constant was a \$JlDataType then, and they are live again as the \$kind that tells a Union from a UnionAll, which share one wasm struct",
        () -> begin
            dead_names = ["has_loop", "has_branch_past_first_loop", "has_short_circuit_patterns",
                          "emit_string_data!",
                          "JL_TYPE_KIND_TYPEVAR", "get_return_type", "get_param_types",
                          "is_supported_intrinsic", "_WASM_LN2", "_IB", "SimpleCodeInfo",
                          "has_dispatch_table", "get_string_ref_array_type!"]
            all_src = join((read(joinpath(dir, f), String)
                            for (dir, _, files) in walkdir(SRC)
                            for f in files if endswith(f, ".jl")), "\n")
            count(dead_names) do name
                q = replace(name, "!" => "\\!")
                # multiline anchors: a definition at the start of any LINE
                occursin(Regex("^function\\s+$(q)\\s*\\(", "m"), all_src) ||
                occursin(Regex("^$(q)\\s*\\(.*\\)\\s*=(?!=)", "m"), all_src) ||
                occursin(Regex("^const\\s+$(q)\\s*=", "m"), all_src) ||
                occursin(Regex("^(?:mutable\\s+)?struct\\s+$(q)\\b", "m"), all_src)
            end
        end),
    "L111_formal_models_paired_and_anchored" => ("every TLA+ model dev/formal/<Name>.tla has its MC<Name>.tla + MC<Name>.cfg instance AND an MC<Name>Broken.cfg instance TLC must reject (a model with no counterexample-producing variant is vacuous), and is anchored by a formal(dev/formal/<Name>.tla) line in src or test; every formal( anchor names a model that exists (locked 2026-09-02)",
        () -> begin
            formal = joinpath(ROOT, "dev", "formal")
            isdir(formal) || return 0
            models = [f[1:end-4] for f in readdir(formal)
                      if endswith(f, ".tla") && !startswith(f, "MC")]
            anchors = Set{String}()
            for root in (SRC, joinpath(ROOT, "test")), (dir, _, files) in walkdir(root), f in files
                endswith(f, ".jl") || continue
                for m in eachmatch(r"formal\(dev/formal/([A-Za-z0-9_]+)\.tla\)", read(joinpath(dir, f), String))
                    push!(anchors, m.captures[1])
                end
            end
            n = 0
            for name in models
                for inst in ("MC$(name).tla", "MC$(name).cfg")
                    isfile(joinpath(formal, inst)) || (n += 1)
                end
                # at least one counterexample-producing variant (MC<Name>[Variant]Broken.cfg)
                any(f -> startswith(f, "MC$(name)") && endswith(f, "Broken.cfg"), readdir(formal)) || (n += 1)
                name in anchors || (n += 1)
            end
            n + count(a -> !(a in models), anchors)
        end),
    "L112_struct_registry_iterated_in_one_order" => ("the struct registry Dict is walked ONLY through registered_structs (sorted by wasm index then name) — a raw `for … in registry.structs` / keys/values/pairs walk picks a hash-order-dependent first match or id and emits process-varying bytes (the Dict-constant nondeterminism finding; dart numbers classes once, class_info.dart:831; locked 2026-09-02)",
        () -> begin
            walk = r"\b(?:in|keys|values|pairs)\(?\s*[\w.]*\.structs\b|collect\([^)]*\.structs\b"
            # the helper's own collect is the one sanctioned walk; if it ever
            # disappears the subtraction must not mask a rogue walk elsewhere
            in_types = count_sites(walk; roots=[CODEGEN], exclude_files=String[]) -
                       count_sites(walk; roots=[CODEGEN], exclude_files=["types.jl"])
            in_types >= 1 || return 1000
            count_sites(walk; roots=[SRC]) - 1
        end),
    "L113_builtin_registry_consulted_once_and_first" => ("compile_call! consults the identity-keyed builtin registry EXACTLY ONCE, right after its ONE SSAValue→GlobalRef callee resolution, and no lowering arm precedes that consult — dev/formal/ConsultChain.tla showed the retired egal/getglobal arms' predicates overlapped the registry's (a late `is_func(func, :(===))` also matched the string/typeof/nothing shapes the registry owns), so their correctness was a program-ORDER invariant; with Phase 12F those arms ARE registry entries and the invariant is now that the consult is single and first (relocked 2026-09-08)",
        () -> begin
            lines = readlines(joinpath(CODEGEN, "calls.jl"))
            start = findfirst(l -> startswith(l, "function compile_call!("), lines)
            start === nothing && return 1000
            stop = findnext(l -> startswith(l, "end"), lines, start + 1)
            stop = stop === nothing ? length(lines) : stop
            body = view(lines, start:stop)
            live = l -> !_iscomment(l)
            consults = count(l -> occursin("_try_builtin_lowering!(", l) && live(l), body)
            first_builtin = findfirst(l -> occursin("_try_builtin_lowering!(", l) && live(l), body)
            first_arm = findfirst(l -> occursin(r"is_func\(func, :", l) && live(l), body)
            (consults == 1 ? 0 : 1) +
                (first_arm !== nothing && first_builtin !== nothing && first_arm < first_builtin ? 1 : 0)
        end),
    "L114_foreigncalls_dispatch_through_registry_only" => ("compile_foreigncall! has exactly one consult point — FOREIGN_LOWERINGS — and its body carries no name-keyed arm; parity(intrinsics.dart:607) the FFI call codegen's helper-table dispatch (also :685 the arg-count table, :1018 the direct-call funnel) never hand-writes a name ladder either, locked here (2026-09-02)",
        () -> begin
            stmt_src = read(joinpath(CODEGEN, "statements.jl"), String)
            count(line -> !_iscomment(line) &&
                          (occursin(r"(_fc_sym|fname|cfn) === :\w+", line) ||
                           (occursin(r"^\s*(if|elseif)\b", line) &&
                            occursin(r"(?<![.\w])name\s+(===\s*:\w+|in\s*\(:)", line))),
                  split(stmt_src, '\n'))
        end),
    "L124_no_name_keyed_call_arms" => ("Phase 12F (dev/MARCH.md item F, formal(dev/formal/ConsultChain.tla)): ZERO `is_func(func, :sym)` arms anywhere in codegen — every Core/Base builtin call lowers through THE identity-keyed BUILTIN_LOWERINGS entry for its resolved callee OBJECT (dart keys on the resolved member, intrinsics.dart:401 KernelNodes._lookup, never on a bare name that any module's same-named function also answers to). Retires ratchet R19_call_is_func_arms and lock L116_call_arms_are_the_allowlist, whose fifteen-site allowlist this reduces to zero (locked 2026-09-08)",
        () -> count_sites(r"is_func\(func, :"; roots=[CODEGEN])),
    "L117_identity_keyed_registries_walk_in_program_order" => ("every identity-keyed registry dictionary (type_ids, type_ranges, type_constant_globals, typename_constant_globals, constant_globals, arrays, numeric_boxes, dispatch tables/positions/cascades) is walked ONLY through ordered_pairs — a raw walk orders by address-based hashes, which differ per process AND per architecture (the whole probe corpus differed x64 vs aarch64 until this lock); reads by key are fine (locked 2026-09-02)",
        () -> begin
            regs = "type_ids|type_ranges|type_constant_globals|typename_constant_globals|constant_globals|arrays|numeric_boxes|tables|selector_positions|selector_cascades"
            walk = Regex("\\bfor\\s+\\(?[^\\n]*?\\bin\\s+(?:keys|values|pairs)?\\(?\\s*[\\w.]*\\.(?:" * regs * ")\\b(?!\\[)")
            # order-insensitive folds (a max over ids, a Set collect that is sorted before use)
            benign = ["for (_, id) in registry.type_ids", "for id in values(registry.type_ids)",
                      "for (_, (_, high)) in registry.type_ranges",
                      "for T in keys(registry.type_ids)", "for T in keys(registry.type_ranges)"]
            n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                endswith(f, ".jl") || continue
                for line in eachline(joinpath(dir, f))
                    _iscomment(line) && continue
                    occursin(walk, line) || continue
                    any(b -> occursin(b, line), benign) && continue
                    n += 1
                end
            end
            n
        end),
    "L118_every_codegen_rejection_is_attributed" => ("a rejection raised while a statement is being compiled goes through record_unsupported!/emit_unsupported_stub! — which attribute it to the statement (ctx.current_stmt_idx) and its inline chain — never through a bare throw(WasmCompileError(WasmDiagnostic(…))); the registrar (structs.jl) and the import-stub check (compile.jl) run before any statement exists and are the only exceptions, with one exact site, pinned by its needle with its reason: the collection's rejection (trimcollect.jl _collection_rejection), made while collecting and located at a statement with its source line and inline chain, for the walk of the constants past its bound at the statement holding the constant (audit #13 A13C7) and for a dynamic call's candidate tuples past _CANDIDATE_BOUND at the first statement making it (A9C2). The export entry's rejection of a result that is not defaultable is gone with the entry's locals (a prologue, emit_export_entry!; A13B1) (locked 2026-09-02); and the plan's rejection of a signature a `show` outside Base and Core would print (trimcollect.jl _julia_signature_text, naming the method and its line), made while naming the planned functions, before any statement (116e-2)",
        () -> begin
            local allowed = [("trimcollect.jl", "    return WasmCompileError(WasmDiagnostic(kind, _collection_host_text(ci), why,") =>
                                 "the collection runs before codegen; its rejection is located at a statement (the constant's, or the dynamic call's)",
                             ("trimcollect.jl", "        throw(WasmCompileError(WasmDiagnostic(:unsupported_method, string(m.name),") =>
                                 "naming a planned function runs before codegen, with no statement: a signature a show outside Base and Core would print is rejected at the plan, naming the method and its source line (_julia_signature_text)"]
            local n = count_sites(r"WasmCompileError\(WasmDiagnostic\("; roots=[CODEGEN],
                                  exclude_files=["structs.jl", "compile.jl", "diagnostics.jl"])
            abs(n - length(allowed)) +
                count((((f, needle), _),) -> length(findall(needle, read(joinpath(CODEGEN, f), String))) != 1, allowed)
        end),
    "L119_one_located_statement_entry" => ("compile_statement! is the ONE per-statement entry and locates every failure raised below it — diagnostics through the funnel, anything else wrapped as WasmInternalError with the statement, its inline chain, and the compiler frames it was raised through (its catch_backtrace(), dart's CFECrashError.stackTrace), whose innermost WT frame heads the message; _compile_statement_located! has no other caller (locked 2026-09-02; the raising frames since 2026-09-29, when finding a codegen bug still meant patching a stack print into the compiler)",
        () -> begin
            src = read(joinpath(CODEGEN, "statements.jl"), String)
            required = ["ctx.current_stmt_idx = idx", "return _compile_statement_located!(b, idx, ctx)",
                        "(err isa WasmCompileError || err isa WasmInternalError) && rethrow()",
                        "throw(located_internal_error(ctx, idx, err, catch_backtrace()))"]
            callers = count_sites(r"_compile_statement_located!\("; roots=[SRC], exclude_line=r"^function _compile_statement_located!")
            count(p -> !occursin(p, src), required) + abs(callers - 1)
        end),
    "L121_retired_names_absent_from_src" => ("a symbol this campaign deleted must not appear ANYWHERE in src — comments and docstrings included. A reference to a function that no longer exists sends the next reader (human or agent) looking for it; the cloud review of 2026-09-04 spent a finding on exactly that (a docstring naming julia_to_wasm_type_concrete, folded into get_concrete_wasm_type in Phase 4.1). Historical records in dev/ and test/ ledgers are exempt — they document what WAS (locked 2026-09-04)",
        () -> begin
            retired = ["julia_to_wasm_type_concrete", "get_or_create_string_hash_func",
                       "builder_diagnose",   # the builder's post-mortem printer, with no caller
                       # 116a: an :invoke's callee is its MethodInstance's function, the plan the one consult
                       "_invoke_registered_signatures", "mi_target", "target_info_early",
                       "_build_standalone_intrinsic_bodies!", "_standalone_intrinsic_body",
                       "method_error_args", "_emit_apply_method_error!", "_is_direct_struct_constructor",
                       # 115b: bodies and initializers are builders the module made, globals held by handle
                       "global_named", "add_global_ref!", "builder_set_local_type!", "locals_fn",
                       "_seed_builder_locals!", "exc_cell_type!", "ensure_exception_top_global!",
                       "ensure_import_tops_global!", "_const_init_bytes!", "_fill_egal_body!",
                       "_string_constant_initializer!",
                       "string_hash_func_idx", "_wasm_string_fnv1a",
                       "resolve_through_dead_boundscheck",
                       "_is_typelevel_foldable",   # Phase 12 C: the fold enumeration
                       # the two `===` ladders `emit_egal!` replaced
                       "_compile_call_egaleq", "_lower_egal_early", "_emit_egal_box_vs_num",
                       "_egal_num_eqop", "_is_typeof_ssa", "_resolve_type_const",
                       # C3 deletion wave: the Method-keyed invoke builders, all unreached
                       "INVOKE_INTRINSICS", "InvokeIntrinsicEntry", "_register_invoke_intrinsic!",
                       "_build_invoke_intrinsics!", "_invoke_receiver_free_method",
                       "_invoke_box_arith_result!", "_emit_str_arg!", "_skip_cross_call",
                       # C3 deletion wave: the host-console IO bridge, left with no caller
                       "IOImports", "add_io_imports!", "_IO_IMPORTS", "get_io_imports",
                       "set_io_imports!", "clear_io_imports!", "create_utf8_to_js_helper!",
                       "emit_jl_string_to_js!", "_UTF8_TO_JS_FUNC_IDX", "clear_utf8_to_js_func!",
                       "get_char_array_type!", "_CHAR_ARRAY_TYPE_IDX", "clear_char_array_type!",
                       # the typed-IR JSON transport and its planner entry (2026-09-27)
                       "compile_from_codeinfo", "compile_module_from_ir", "_PrecomputedIRKey",
                       "preprocess_ir_entries", "serialize_ir_entries", "deserialize_ir_entries",
                       "collect_and_resolve_all_globalrefs", "substitute_globalrefs",
                       "wasm_bytes_length", "wasm_bytes_get",
                       # the compiled-bytes cache: its key hashed only the entry method's
                       # world, so a redefined callee was answered with stale bytes (2026-09-27)
                       "compile_cached", "compile_multi_cached", "enable_cache!",
                       "disable_cache!", "clear_cache!", "cache_stats", "CompileCache",
                       "compute_cache_key", "compute_multi_cache_key", "_GLOBAL_CACHE",
                       # the superseded trim and the builtin-only edge relation (batch 111):
                       # _closed_world_edge is the one relation, and the collection only adds
                       "_builtin_call_edge_mi", "pruned_superseded", "superseded_invokes",
                       "intrinsic_body_roots", "prune_roots",
                       # the export entry's handler and the wasm-side count (batch 112b-1): the
                       # boundary is the host's glue, host_glue_js
                       "catch_all_ref_clause", "throw_ref!", "ThrowRef", "THROW_REF",
                       # the try_table form (batch 112b-2): a region is dart's legacy try and catch
                       "try_table", "TryTable", "SymbolicTryCatch", "catch_clause", "InstrIR.TryCatch",
                       "TryCatch(", "_encode_catch!", "TRY_TABLE", "CATCH_REF", "CATCH_ALL",
                       "except H6, H7 and A13E1"]
            n = 0
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                src = read(joinpath(dir, f), String)
                n += count(name -> occursin(name, src), retired)
            end
            n
        end),
    "L123_wt_only_intrinsic_surface_extinct" => ("the WT-only str_*/arr_* runtime intrinsic surface (src/runtime/{stringops,arrayops,intrinsics}.jl, compile.jl's name-ladder is_intrinsic_function/generate_intrinsic_body, and their invoke.jl standalone builders) is DELETED — dart2wasm has no hand-written-wasm runtime library keyed by function NAME; users reach strings/arrays through Base, which lowers through Base's own overlays and compiled bodies (L115) (H(4); locked 2026-09-07)",
        () -> begin
            retired = ["is_intrinsic_function", "generate_intrinsic_body",
                       "str_char", "str_getchar", "str_charlen", "str_setchar!",
                       "str_new", "str_copy", "str_substr", "str_concat", "str_eq",
                       "str_hash", "str_find", "str_contains",
                       "arr_new", "arr_get", "arr_set!", "arr_len", "arr_fill!",
                       "INTRINSIC_MAPPING", "get_wasm_opcode"]
            n = 0
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                src = read(joinpath(dir, f), String)
                n += count(name -> occursin(name, src), retired)
            end
            n
        end),
    "L120_one_inference_path" => ("every typed IR and every inferred return type WasmTarget consumes comes from the WasmInterpreter through ir.jl (get_typed_ir / infer_return_type) — Base.code_typed, code_typed_by_type, Core.Compiler.return_type / _return_type and Base.infer_return_type are called only inside ir.jl, and get_typed_ir has no native-interpreter default (a standalone dump once differed from the closed-world plan's IR for the same function; box-capture joins once asked the native interpreter, which does not see the overlays; locked 2026-09-07)",
        () -> begin
            n = count_sites(r"Base\.code_typed\(\w|code_typed_by_type\(|(?<![\w.])_?return_type\(\s*[^)]|Base\.infer_return_type\(|Compiler\.return_type\(|CC\.return_type\(";
                            roots=[SRC], exclude_files=["codegen/ir.jl"])
            ir = read(joinpath(CODEGEN, "ir.jl"), String)
            occursin("interp::WasmInterpreter=get_wasm_interpreter()", ir) || (n += 1)
            occursin("interp=nothing", ir) && (n += 1)
            n
        end),
    "L107_one_debug_surface" => ("every WT_* debug switch is read in codegen/options.jl — dart TranslatorOptions shape; no scattered ENV reads (WT_VALIDATE is the documented gate and exempt; locked 2026-09-02)",
        () -> count_sites(r"\"WT_(?!VALIDATE\b)[A-Z_]+\""; roots=[SRC], exclude_files=["codegen/options.jl"])),
    "L97_planner_entries_are_closed" => ("every public compilation converges on the closed-world planner through exactly ONE entry — the trim collector (_compile_module_trim); the precomputed-IR installer and its JSON transport are deleted, and a second entry is a new discovery regime (locked 2026-09-01, one entry since 2026-09-27)",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            # the one sanctioned planner entry must exist verbatim, so a swap
            # (delete the legitimate caller, add a rogue one) cannot keep the
            # total and slip through
            required = ["return _compile_closed_world_plan(plan; kwargs...)"]
            extra = count_sites(r"_compile_closed_world_plan\(";
                                exclude_line=r"function _compile_closed_world_plan\(") - 1
            max(extra, 0) + count(p -> !occursin(p, compile_src), required)
        end),
    "L98_single_external_link_road" => ("external wasm-merge linking is a single road living only in compile_with_base; merged output bypasses the typed builder, so any new call site must be reviewed here (locked 2026-09-01)",
        () -> begin
            wt_src = read(joinpath(ROOT, "src", "WasmTarget.jl"), String)
            # zero merge references outside src/WasmTarget.jl, the sanctioned
            # count inside it (all within compile_with_base), and the road's
            # host function must still exist
            outside = count_sites(r"wasm-merge|wasm_merge"; exclude_files=["WasmTarget.jl"])
            total = count_sites(r"wasm-merge|wasm_merge")
            outside + max(total - 6, 0) +
                (occursin("function compile_with_base", wt_src) ? 0 : 1)
        end),
    "L115_invokes_dispatch_through_registry_only" => ("parity(code_generator.dart:1668-1686 visitStaticInvocation): an invoke of a member with a body is a direct `call` of that member's compiled function — compile_invoke! keeps no intrinsic table (INVOKE_INTRINSICS: 35 entries measured unreached 2026-09-22, deleted) and no bare-Symbol `name === :sym` ladder arm; neither can return to invoke.jl",
        () -> count_sites(r"(?<![.\w])name === :\w+|INVOKE_INTRINSICS|_register_invoke_intrinsic!|InvokeIntrinsicEntry"; roots=[CODEGEN],
                          exclude_files=setdiff(readdir(CODEGEN), ["invoke.jl"]))),
    "L122_closed_world_numbered_once" => ("Phase 12B (dev/MARCH.md, formal(dev/formal/ClassIdDispatch.tla)): assign_type_ids! numbers the WHOLE closed world in ONE DFS — _collect_reachable_ir_types (ir.jl) admits every concrete kind that can carry a classId (structs, closures, Core.Box, Memory/MemoryRef, primitives incl. Char/Int128/a user `primitive type`, a Tuple with a Type{X} element or a runtime-length Vararg tuple) before the DFS runs. A type reaching ensure_type_id! unnumbered is a loud collector bug, never a second, order-dependent id — `type_extra_ids` and its allocating branch are extinct (locked 2026-09-07)",
        () -> begin
            types_src = read(joinpath(CODEGEN, "types.jl"), String)
            required = ["existing > 0 && return existing", "reached codegen unnumbered"]
            forbidden_alloc = count_sites(r"for \(_, id\) in registry\.type_ids|registry\.type_ids\[T\] = new_id"; roots=[CODEGEN])
            count_sites(r"type_extra_ids") + forbidden_alloc +
                count(p -> !occursin(p, types_src), required)
        end),
    # ── dev/CHARTER.md (2026-09-22): the charter and the enforcement stack cite each other ──
    "L125_charter_is_the_definition_of_done" => ("dev/CHARTER.md exists; every check a clause cites exists here, and every lock and ratchet here is cited by exactly one clause (an uncited check is either obsolete or a clause is missing; a cited check that does not exist is a promise nobody keeps)",
        () -> begin
            clauses = charter_clauses()
            isempty(clauses) && return 1
            cited = String[]
            for (_, (_, ids)) in clauses; append!(cited, ids); end
            have = Set(_short_id(first(p)) for p in vcat(METRICS, LOCKS))
            missing_ = count(c -> c ∉ have, unique(cited))
            dup = length(cited) - length(unique(cited))
            uncited = count(h -> h ∉ Set(cited), have)
            missing_ + dup + uncited
        end),
    "L127_one_inference_path_keeps_source_lines" => ("dev/CHARTER.md C6: every inference call in ir.jl (the one inference path) asks for debuginfo=:source, so IR it returns carries its statements' locations and inline chains — code_typed's default dropped them, and every statement then read no location (behavioral twin: test/diagnostic_attribution.jl 'the one inference path keeps source lines')",
        () -> begin
            ir_lines = readlines(joinpath(CODEGEN, "ir.jl"))
            count(l -> !_iscomment(l) && occursin(r"Base\.code_typed(_by_type)?\(", l) &&
                       !occursin("debuginfo=:source", l), ir_lines)
        end),
    "L128_agents_md_current_and_lean" => ("AGENTS.md is the ONE agent-instructions file (no CLAUDE.md), at most 90 lines of at most 100 chars, names only paths, checks and WT_* switches that exist, pins the oracle commit dev/PARITY_MASTER.md pins, and carries no status vocabulary (dates, phase names, currently/as of/remaining) — status is measured here and planned in dev/MARCH.md, never remembered in the instructions (dev/CHARTER.md C0)",
        () -> (v = agents_md_violations(); foreach(x -> println("    ✗ ", x), v); length(v))),
    "L133_standalone_bodies_are_exact" => ("the functions that compile to a bespoke standalone body instead of Julia's own (STANDALONE_INTRINSIC_BODIES) are exactly the allowlist below, each for a stated reason, and each body carries its parity anchor; INVOKE_INTRINSICS is deleted (L121). Base.rethrow: its native body is a foreigncall to the C runtime's jl_rethrow (dev/CHARTER.md C3)",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            allowed = Set(["Base.rethrow"])   # native body: a foreigncall to jl_rethrow
            reg = match(r"(?s)\nconst STANDALONE_INTRINSIC_BODIES = IdDict\{Method,Function\}\((.*?)\)\n", compile_src)
            reg === nothing && return 1
            registered = Set(m.captures[1] for m in eachmatch(r"methods\(([A-Za-z_.]+)\)", reg.captures[1]))
            bodies = Set(m.captures[1] for m in eachmatch(r"m => ([A-Za-z_!]+)", reg.captures[1]))
            unanchored = count(bodies) do fn
                d = match(Regex("(?s)\"\"\"((?:(?!\"\"\").)*)\"\"\"\\nfunction " * fn * "\\("), compile_src)
                d === nothing || !occursin("parity(", d.captures[1])
            end
            length(symdiff(registered, allowed)) + unanchored
        end),
    "L132_dart_anchors_resolve" => ("every parity(<file>.dart:<line> <Symbol>) anchor in src resolves at the pinned dart-lang/sdk commit: the file and line exist and the line names the cited symbol; with no checkout at the pinned commit the check fails, never skips (dev/CHARTER.md C2)",
        () -> length(unresolved_dart_anchors())),
    "L130_every_file_outside_src_consumed" => ("every tracked file outside src/ is consumed: a tracked file that is not prose names it (a .md only by its path), a loader walks its directory, or it is a repository convention file or README; and no fuzz-ledger gap is `status: fixed` (dev/CHARTER.md C9)",
        () -> length(unconsumed_files_outside_src())),
    "L134_the_wasm_runtime_is_required" => ("no test branches on the wasm runtime's absence: test/wasm_runner.jl's one Node detection errors at load when Node ≥ 20 is missing, and no test skips, reports a pass, or answers `skipped` without it (runner_available, :nonode, :no_node, NODE_OK, a `skipped` result field) — every differential lane either runs its wasm or fails (dev/CHARTER.md C5)",
        () -> count_sites(r"runner_available|:nonode\b|:no_node\b|\bNODE_OK\b|NODE_CMD|NEEDS_(EXPERIMENTAL_)?FLAG|\bdetect_node\b|\.skipped\b|\bskipped\s*="; roots=[joinpath(ROOT, "test")], exclude_files=["parity_ratchet.jl"])),
    "L135_callee_by_exact_signature" => ("get_function binds a call to a compiled specialization only on its exact argument types (the return-compatibility gate aside): no subtype or reverse-subtype pass between argument types. An :invoke never asks it: its callee is its MethodInstance's function (L170); any other mismatch is dynamic dispatch, lowered as such or rejected. The reverse pass bound `RW(::Any)` holding a Symbol to `RW(::String)` and answered 1001 for 1100 (smoke xfail dynamic_constructor; dev/CHARTER.md C6)",
        () -> begin
            src = read(joinpath(CODEGEN, "types.jl"), String)
            m = match(r"(?s)\nfunction get_function\(registry::FunctionRegistry.*?\nend\n", src)
            m === nothing && return 1
            body = filter(l -> !_iscomment(l) && !occursin("_ret_ok(info) =", l) &&
                               !occursin(r"^\s*info\.return_type <: expected_return", l),
                          split(m.match, '\n'))
            count(l -> occursin("<:", l), body)
        end),
    "L144_statements_are_source_mapped" => ("every instruction a Julia statement emits maps to that statement's source, end to end, as dart2wasm's source maps do (pkg/wasm_builder/lib/source_map.dart): compile_statement! maps the statement (map_to_statement!, the one mapping entry) inside its located try and maps the code after it back to the function's definition (L159); the stackifier maps a block's terminator code to the terminator, each phi store on an edge to its phi, and an in-block return to itself; append_builder! carries a fragment's mappings shifted to where its instructions land, and the destination's own mapping resumes after them, so a fragment's last mapping does not run on into its destination; the serializer moves a body's mappings by the body's place in the code section and the section's place in the module; the differential runner compiles with the map (compare_julia_wasm) and names a trap's frames through it (located_frames); and the function-level approximation retired 2026-09-29 (collect_source_info, whose i-th mapping took the i-th defined function's size prefix) does not return (test/source_maps.jl; dev/CHARTER.md C10)",
        () -> begin
            src(f) = read(joinpath(CODEGEN, f), String)
            bsrc(f) = read(joinpath(SRC, "builder", f), String)
            tsrc(f) = read(joinpath(ROOT, "test", f), String)
            required = [
                (src("statements.jl"), "        map_to_statement!(b, ctx, idx)\n        return _compile_statement_located!(b, idx, ctx)"),
                (src("stackified.jl"), "        map_to_statement!(b, ctx, terminator_idx)\n"),
                (src("stackified.jl"), "map_to_statement!(b, ctx, i)   # this edge's store maps to its phi"),
                (src("stackified.jl"), "                map_to_statement!(bb, ctx, i)\n"),
                (bsrc("instr_builder.jl"), "_add_source_mapping!(dst, shift_by(m, shift))"),
                (bsrc("instr_builder.jl"), "_add_source_mapping!(dst, SourceMapping(shift + length(src.instrs), resume))"),
                (bsrc("instructions.jl"), "push!(code_mappings, shift_by(m, entry_start + body_start))"),
                (bsrc("instructions.jl"), "push!(module_mappings, shift_by(m, contents_start))"),
                (src("compile.jl"), "b = generate_body(_ctx_function_builder(ctx, func_idx), ctx)"),
                (tsrc("utils.jl"), "bytes, source_map = WasmTarget.compile_with_sourcemap(f, arg_types; optimize=optimize)"),
                (tsrc("wasm_runner.jl"), "located_frames(String(r[\"stack\"]), source_map, bytes)"),
            ]
            forbidden = ["collect_source_info", "update_function_offsets!"]
            all_src = join((read(joinpath(dir, f), String) for (dir, _, fs) in walkdir(SRC) for f in fs if endswith(f, ".jl")))
            count(((text, needle),) -> !occursin(needle, text), required) +
                count(p -> occursin(p, all_src), forbidden) +
                isfile(joinpath(CODEGEN, "sourcemap.jl"))
        end),
    "L145_a_throw_carries_its_stack" => ("every Julia throw carries the stack trace of its throw, and every rethrow the stack its throw captured, in the exception tag's stack slot, in every module (one module shape: a source map only maps the code): codegen has exactly one throw site, _emit_throw_top!, which throws the top entry of Julia's exception stack (its exception, its stack and the entry itself); no throw_ref is anywhere in src, and the export entry (emit_export_entry!) is a prologue that calls its inner last, so an escape passes it untouched, its payload (the exception and the stack its throw captured) exact (until batch 110 the entry's handler was a second throw site, and until batch 112b-1 it rethrew with throw_ref); emit_throw_value! pushes that entry with the JS stack it captures through the `wasmtarget.stack_trace` import every module has (dart: every throw captures StackTrace.current, code_generator.dart:2955 visitThrow, `errorThrowWithCurrentStackTrace`), and a rethrow throws the entry again, pushing nothing (dart's visitRethrow, code_generator.dart:2966, throws its catch's stackTraceLocal); the runner answers the import from the module's runtime and reads an escaped exception's stack from the exported tag, through the host's one escape helper (host_escape_js). _emit_throw_top!'s callers are exactly those two, emit_throw_value! and emit_rethrow!, read by the function each call sits in, so a third that throws the top without pushing fires it. test/source_maps.jl runs it: an escaped exception, rethrown, rethrown with `rethrow(e)` or not, names its first throw (dev/AUDIT.md H1; dev/CHARTER.md C10)",
        () -> begin
            local throws = count_sites(r"\bthrow_!\("; roots=[CODEGEN])   # _emit_throw_top!'s, alone
            local throw_refs = count_sites(r"throw_ref|ThrowRef|THROW_REF")
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local runner = read(joinpath(ROOT, "test", "wasm_runner.jl"), String)
            local required = [(gen, "call!(b, something(_stack_trace_func_idx(mod)))\n    struct_new!(b, cell)\n    global_set!(b, top)\n    _emit_throw_top!(b, mod, registry)"),
                              (gen, "add_import!(mod, \"wasmtarget\", \"stack_trace\", WasmValType[], WasmValType[ExternRef])"),
                              (read(joinpath(CODEGEN, "compile.jl"), String), "    ensure_provenance_imports!(mod)\n    trace === nothing || ensure_trace_imports!(mod)"),
                              (gen, "const st = e.getArg(tag, 1);"),
                              (runner, "catch (e) { return [(\$(WasmTarget.host_escape_js()))(instance.exports, e)]; }"),
                              (runner, "    \$(host_runtime_merge_js(bytes))"),
                              (gen, "    global_get!(b, top)\n    struct_get!(b, cell, 1)\n    global_get!(b, top)\n    throw_!(b, exc_tag(registry))"),
                              (gen, "    global_set!(b, top)\n    for i in 0:length(ft.params) - 1; local_get!(b, i); end\n    call!(b, inner_idx)\n    finish_function!(b)"),
                              (gen, "        struct_set!(b, cell, 0)\n    end\n    return _emit_throw_top!(b, mod, registry)\nend")]
            # _emit_throw_top!'s callers, exactly: the throw that pushes (emit_throw_value!) and
            # the rethrow that does not (emit_rethrow!); a call from any other function, one that
            # throws the top without pushing it, fires
            local callers = String[]
            for (dir, _, fs) in walkdir(SRC), f in fs
                endswith(f, ".jl") || continue
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = d.captures[1])
                    (_iscomment(line) || d !== nothing) && continue
                    occursin("_emit_throw_top!(", line) && push!(callers, enclosing)
                end
            end
            abs(throws - 1) + throw_refs + count(((text, needle),) -> !occursin(needle, text), required) +
                (sort(callers) == ["emit_rethrow!", "emit_throw_value!"] ? 0 : 1)
        end),
    "L146_a_collection_failure_is_located" => ("a closed-world collection failure names the method it was inferring and why it entered the closed world, as a compile-time rejection names its statement: every enrollment records its reason (_enrollment_text: for each kind of _closed_world_edge, the collector's one walk of the edges records each target's, collected already or not, and the plan reads it — its _EDGE_ENROLLMENT text: the call, the finalizer registered by, the function of, the body of the callable built by, the operator of the atomic modify; the dynamic call, the dispatch candidate for a runtime class, or the constructed closure's body — with the host, the statement and its source line); a failure planning the module outside any statement is a WasmInternalError at the module's entries, and one declaring a function's signature names the function and why it was enrolled; and collect_new_pairs! and the first collection throw a failure through throw_located_collection_failure (an interrupt or exhausted memory, the process's, passing through it and through the re-inference; test/diagnostic_attribution.jl plants a failure in the first collection and an ArgumentError in a re-inference), which re-infers the failed batch's roots alone (the failure path only; the success path keeps one batch, so every module's bytes are unchanged) and names the one that fails with its reason, its error and the frames it was raised through. Until 2026-09-29 a failure escaped as a raw MethodError from inside Core.Compiler after 738 s of collection, naming nothing (MARCH 13.10; test/diagnostic_attribution.jl; dev/CHARTER.md C6)",
        () -> begin
            trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            required = ["haskey(reasons, mi) || (reasons[mi] = _enrollment_text(_EDGE_ENROLLMENT[kind], host_ci, src, k, node))",
                        "const _EDGE_ENROLLMENT = (invoke = \"the call\", splat = \"the call\", invoke_in_world = \"the call\",",
                        "reasons[cmi] = _enrollment_text(\"the dynamic call\", ci, src, sidx, node)",
                        "reasons[cmi] = _enrollment_text(\"the dispatch candidate for runtime class",
                        "reasons[cmi] = \"the body of the closure",
                        "throw_located_collection_failure(batch, err, catch_backtrace(), _compile_root_alone)",
                        "throw_located_collection_failure(Tuple{Any,String}[(e, \"a compilation entry\") for e in entries],",
                        "(err isa WasmInternalError || err isa InterruptException || err isa OutOfMemoryError) && rethrow()\n        throw_located_collection_failure(Tuple{Any,String}[",
                        "(e isa InterruptException || e isa OutOfMemoryError) && rethrow()\n            throw(WasmInternalError(",
                        "_missing_explicit_invoke_mis(\n            codeinfos, invoke_seen; numeric_joins, capture, reasons=enrolled_by, invoked_closures,\n            invoke_originals))",
                        "_dynamic_dispatch_candidate_mis(codeinfos, seen_disp; reasons=enrolled_by, classes, nir_for,"]
            comp = read(joinpath(CODEGEN, "compile.jl"), String)
            # a failure outside any statement (planning the module, declaring a signature) is
            # located too: at the module's entries, or at the function and why it is there
            required_comp = ["String[\"while planning the module (no statement was being compiled)\"],",
                             "\"enrolled as \" * plan.enrolled_as[fd_mi]]"]
            diag = read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            required_diag = ["@testset \"diagnostics: a failure of the first collection names its entry\" begin",
                             "@testset \"diagnostics: a collection failure passes the process's errors and locates an ArgumentError\" begin"]
            count(p -> !occursin(p, trim), required) + count(p -> !occursin(p, comp), required_comp) +
                count(p -> !occursin(p, diag), required_diag)
        end),
    "L147_a_wrong_value_names_its_statement" => ("a wrong answer is located at the first statement whose value differs, as a trap and a rejection are: a traced compile (compile_with_statement_trace) traces every function compiled from Julia IR — each reports its entry (emit_trace_enter!) and, for each statement of a traced type (TRACED_STATEMENT_TYPES: exactly Julia's bits in its wasm local), its value after the store (emit_statement_trace!), through imports added before any definition, recording each function's probed statements; test/trace_localize.jl runs each traced function's CodeInfo natively as an OpaqueClosure with the same probes, every traced call routed to its callee's closure with the callee value it was invoked with, each closure taking its function's own `#self#` as an explicit first argument (Argument(n) becomes Argument(n + 1)), so the native run follows WT's IR all the way down into every traced function, closures included, each call reading its own instance's captures (until batch 114 a closure that read its own captures stayed native, `_reads_self`, and its events were dropped), compares the two event streams on what both report, and names the first divergent event — its function, text, inline chain, iteration and both values — or, when every event agrees and WT's IR run natively already answers differently from Julia, says the difference is in the IR, not codegen; smoke's WRONG lines and the statement-generator lane's wrong outcomes carry that report. A planted mul_int→sub miscompile is named at its statement, line and first iteration, in the entry, inside a separately compiled callee and inside a closure that reads its capture, and a closure built per iteration runs with each instance (test/wrong_value_locator.jl; dev/CHARTER.md C6)",
        () -> begin
            gen = read(joinpath(CODEGEN, "generate.jl"), String)
            stm = read(joinpath(CODEGEN, "statements.jl"), String)
            ctxs = read(joinpath(CODEGEN, "context.jl"), String)
            comp = read(joinpath(CODEGEN, "compile.jl"), String)
            loc = read(joinpath(ROOT, "test", "trace_localize.jl"), String)
            smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            lane = read(joinpath(ROOT, "test", "fuzz", "test_statements.jl"), String)
            required = [(stm, "local_set!(b, local_idx)\n                emit_statement_trace!(b, ctx, idx, local_idx, local_type)"),
                        (gen, "push!(ctx.translator.trace.probed[id], idx)"),
                        (read(joinpath(CODEGEN, "flow.jl"), String), "emit_trace_enter!(b, ctx)"),
                        (loc, "ir.stmts[i][:stmt] = Expr(:call, _run_traced, callee, st.args[2:end]...)"),
                        (loc, "v isa Core.Argument && (op[] = Core.Argument(v.n + 1))"),
                        (loc, "pushfirst!(ir.argtypes, Tuple{})"),
                        (loc, "(:ok, Base.invokelatest(_OCS[trace.entry], f, args...))"),
                        (ctxs, "haskey(TRACED_STATEMENT_TYPES, get(ctx.ssa_types, i, Any)) && push!(needs_local_set, i)"),
                        (comp, "trace === nothing || ensure_trace_imports!(mod)\n    local translator = Translator(plan, trace; options, diagnostics)"),
                        (loc, "filter!(keep, nevents)"),
                        (loc, "filter!(keep, wevents)"),
                        (smoke, "replace(_smoke_locate(f, args), "),
                        (lane, "replace(_locate(fn, Tuple(o.input)), ")]
            # one path: no function's calls stay native because it reads its own `#self#`
            count(((text, needle),) -> !occursin(needle, text), required) +
                length(collect(eachmatch(r"_reads_self|routable|haskey\(_OCS", loc)))
        end),
    "L149_the_builder_knows_no_julia_ir" => ("the builder layer (src/builder) holds and names no Julia compiler object — no CodeInfo, MethodInstance, CodeInstance or DebugInfo, no NIR node, no compilation context, and no compile option (no OPTIONS read, audit #2 A2B8): dart's wasm_builder knows nothing of kernel (module.dart:24 ModuleBuilder holds wasm parts only); what codegen needs to remember about Julia per compilation lives on its Translator (context.jl). The builder sandbox the builder's behavioral locks run in loads src/builder from builder/types.jl, without codegen/options.jl, so a builder function that reads OPTIONS fails there (dev/CHARTER.md C2)",
        () -> count_sites(r"Core\.(?:CodeInfo|MethodInstance|CodeInstance|DebugInfo)\b|\bNir[A-Z]\w*|\bCompilationContext\b|\bTranslator\b|\bStatementTrace\b|\bOPTIONS\b";
                          roots=[joinpath(SRC, "builder")]) +
              (occursin("        m[1] == \"builder/types.jl\" && (started = true)\n        started && push!(files, m[1])",
                        read(joinpath(ROOT, "test", "parity_ratchet.jl"), String)) ? 0 : 1)),
    "L150_every_host_import_has_its_runtime" => ("WT's own imports are one list, WT_IMPORTS (generate.jl), which every reader reads: every import WT's code generator creates, function or global (a literal `add_import!(mod, \"<module>\", \"<field>\"` or `add_global_import!(mod, \"<module>\", \"<field>\"` in src, and the traced compile's per-type probes, ensure_trace_imports!), is on it or is the glue's one import, `wasmtarget.host_imports_open` (host_glue_js hands it to the module), and it lists none that no code creates; host_runtime_js answers each of them a module declares, _is_host_declared_import calls every other function import the host's (by that list alone, no module-name rule), and the glue leaves exactly them unwrapped. The runtime is generated per module, as dart2wasm generates its runtime's JS methods from the module it translated (runtime_generator.dart:60 generateJsMethods, :128 RuntimeFinalizer.generate): host_runtime_js has one method, over the bytes a host instantiates (their imports read by the builder's module_function_imports), so no harness answers a module with a fixed list or another module's runtime (no `host_runtime_js()` call in src, test or docs). Behavior: test/host_imports.jl's 'the host runtime is the module's own imports' instantiates a module that reads the clock and one that draws random words, each with its own runtime, whose fields equal the module's declared function imports exactly, and with any one field taken out raises a LinkError (until 116e-2 every harness instantiated every module with all three fixed answers; dev/AUDIT.md A2C9, A2E4, A13E4; dev/CHARTER.md C1)",
        () -> begin
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local fbody(text, name) = (m = match(Regex("(?s)\\nfunction " * replace(name, "!" => "\\!") * "\\(.*?\\nend\\n"), text); m === nothing ? "" : m.match)
            local created = Set{Tuple{String,String}}()
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                for m in eachmatch(r"add_(?:global_)?import!\(mod, \"(\w+)\", \"(\w+)\"", read(joinpath(dir, f), String))
                    push!(created, (m.captures[1], m.captures[2]))
                end
            end
            for m in eachmatch(r"\(\"(trace_\w+)\", [IF](?:32|64)\)", fbody(gen, "ensure_trace_imports!"))
                push!(created, ("wasmtarget", m.captures[1]))
            end
            local list = match(r"(?s)\nconst WT_IMPORTS = Tuple\{String,String,Union\{Nothing,String\}\}\[\n.*?\n\]\n", gen)
            local listed = list === nothing ? Set{Tuple{String,String}}() :
                Set{Tuple{String,String}}((m.captures[1], m.captures[2]) for m in eachmatch(r"\(\"(\w+)\", \"(\w+)\", (?:\"|nothing)", list.match))
            # the glue answers its count, and reads the imports it leaves alone from WT_IMPORTS
            local glue = fbody(gen, "host_glue_js")
            local glue_ok = occursin("for (mm, f, _) in WT_IMPORTS if mm == m", glue) &&
                            occursin("once(glued.wasmtarget, 'wasmtarget', 'host_imports_open', open)", glue) &&
                            !occursin("m === 'wasmtarget'", glue)
            glue_ok && push!(listed, ("wasmtarget", "host_imports_open"))
            local required = [
                (gen, "_is_host_declared_import(imp::WasmImport)::Bool =\n    imp.kind == 0x00 && !any(((m, f, _),) -> m == imp.module_name && f == imp.field_name, WT_IMPORTS)\n"),
                (fbody(gen, "host_runtime_js"), "local imported = Set{Tuple{String,String}}(module_function_imports(bytes))\n    local answered = [(m, f, js) for (m, f, js) in WT_IMPORTS if js !== nothing && (m, f) in imported]"),
                (read(joinpath(ROOT, "test", "host_imports.jl"), String), "@test r[\"given\"] == r[\"declared\"] == sort([\"wasmtarget.stack_trace\", has])"),
                (read(joinpath(ROOT, "test", "host_imports.jl"), String), "@test r[\"missing\"] == [x * \" LinkError\" for x in r[\"given\"]]")]
            local v = length(symdiff(created, listed)) + (glue_ok ? 0 : 1) +
                      count(((text, needle),) -> !occursin(needle, text), required)
            # one method, over the module's bytes; no fixed runtime anywhere
            v += abs(count_sites(r"^function host_runtime_js\(|^host_runtime_js\(.*\)(?:::\w+)?\s*=") - 1)
            v += count_sites(r"^function host_runtime_js\((?!bytes::Vector\{UInt8\}\)::String$)")
            v += count_sites(r"host_runtime_js\(\)|HOST_RUNTIME\b"; roots=[SRC, joinpath(ROOT, "test"), joinpath(ROOT, "docs")],
                             exclude_files=["parity_ratchet.jl"])
            v
        end),
    "L151_every_builder_has_its_module" => ("every builder has its module, as every dart InstructionsBuilder has one (instructions.dart:233): InstrBuilder and WasmStackValidator have no method without a WasmModule (`mod` is a required keyword, never `Union{Nothing}`), so a module-less builder cannot be made and its fallbacks (a caller's global type, an unchecked global.set, a guessed struct for an unresolvable index, a call's claimed signature) are unreachable; no `=== nothing` test of a module in src/builder and no `mod=nothing` in src; every InstrBuilder codegen constructs names its module (`mod=`). Its behavior, over src/builder alone: `InstrBuilder(; func_name)` and `WasmStackValidator(; func_name)` throw (dev/AUDIT.md A2B7, A3B5, B5; dev/CHARTER.md C7)",
        () -> begin
            local n = 0
            for (dir, _, files) in walkdir(CODEGEN), f in files
                endswith(f, ".jl") || continue
                for m in eachmatch(r"InstrBuilder\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)", read(joinpath(dir, f), String))
                    occursin("mod=", m.match) || (n += 1)
                end
            end
            n += count_sites(r"\b(mod|_mod|v\.mod|b\.v\.mod)\s*[!=]==?\s*nothing\b"; roots=[joinpath(SRC, "builder")])
            n += count_sites(r"\bmod\s*=\s*nothing\b|mod::Union\{Nothing"; roots=[SRC])
            n += in_builder_sandbox() do W
                count((() -> W.InstrBuilder(; func_name="no module"), () -> W.WasmStackValidator(; func_name="no module"))) do make
                    try; make(); true; catch e; !(e isa UndefKeywordError); end
                end
            end
            n
        end),
    "L152_codegen_reads_the_plans_ir" => ("codegen reads each function's typed IR from the collected closed world, through the plan (plan_ir, ctx.translator.plan) or the collected pairs, and never asks Julia's inference again: no `get_typed_ir(` call in src outside its own definitions in ir.jl, and no process-global IR cache (TRIM_IR_CACHE, which a later read could find unset and fall back to a second inference, dev/AUDIT.md A2C3); codegen asks no inference at all: no `infer_return_type(` call, qualified (`Base.infer_return_type(`) or not, and no `typeinf(`, `typeinf_type(`, `typeinf_ext…(`, `typeinf_frame(`, `code_typed(`, `abstract_call…(`, `Base.return_types`, `return_type(` or `CC.findall(` call in src/codegen outside trimcollect.jl's collector and planner and ir.jl's inspection definitions, and no `closed_world_call_result` or `analyze_ssa_types!` anywhere in src (a callee's return type, an unused :invoke's and every join are the plan's: plan_ir, plan_joins, FunctionInfo.return_type); the box-capture analysis takes its closure bodies and its return-type question as required arguments (closure_bodies, rettype), so box_capture.jl names no inference, and collection passes them; its behavior: test/ir_one_inference_path.jl compiles a plan with the one inference entry counting its calls and the interpreter counting every query of its cache (CC.cache_owner, which any inference with a WasmInterpreter asks, cached or not, through any entry), and the compile asks each 0 times (dev/AUDIT.md A3C1; dev/CHARTER.md C1); and a statement's codegen asks no method table either (L171)",
        () -> begin
            local n = count_sites(r"\bget_typed_ir\("; roots=[SRC], exclude_files=["codegen/ir.jl"])
            n += count_sites(r"TRIM_IR_CACHE"; roots=[SRC])
            n += count_sites(r"(?<!\w)infer_return_type\(|\btypeinf\(|\btypeinf_type\(|\btypeinf_ext\w*\(|\btypeinf_frame\(|\bcode_typed\(|\babstract_call\w*\(|Base\.return_types|(?<![\w])return_type\(|CC\.findall\(";
                             roots=[CODEGEN], exclude_files=["trimcollect.jl", "ir.jl"])
            n += count_sites(r"closed_world_call_result|analyze_ssa_types!"; roots=[SRC])
            local box = read(joinpath(CODEGEN, "box_capture.jl"), String)
            n += occursin("closure_bodies::Function", box) && occursin("rettype::Function", box) &&
                 !occursin("closure_ir", box) ? 0 : 1
            local oip = read(joinpath(ROOT, "test", "ir_one_inference_path.jl"), String)
            n += occursin("@testset \"codegen asks no inference; an unused :invoke reads the plan's rettype\"", oip) &&
                 occursin("@test calls[] == 0", oip) && occursin("@test queries[] == 0", oip) ? 0 : 1
            n
        end),
    "L153_the_gate_runs_what_ci_runs" => ("the gate before a push runs every test family CI runs on Julia 1.12, validated (WT_VALIDATE=1, as CI's Unix shards), CI's fuzz pass (WT_FUZZ=1), and smoke on 1.13, so CI confirms rather than discovers (CI's 1.13 suite and its three platforms stay CI's, and so, for `dev/lanes.sh` without `--all`, do the deep TLC instances, which gate.yml runs): dev/lanes.sh's default run (not --fast; its comment lines not counted) stops at the first red lane (both smokes and TLC side by side first, batch 111's 1.13 failure having surfaced at minute 29 of a serial run) and has the whole Pkg.test suite as two concurrent shards (WT_SHARD=0,2 and 1,2), then the fuzz pass, and smoke on Julia 1.13, and AGENTS.md makes a push wait for its run on CI's runners, `bash dev/gate.sh` (the script reproduces it locally). No lane of that run is skipped green: it runs the probes and registry coverage only when the default `julia` is 1.12, the formal lane only when `java` runs, and smoke on 1.13 only without a JULIA= override and with `julia +1.13` installed, and each of those five skips prints FAIL and sets the gate red; and every lane runs on CI's wasm engine, the Node major ci.yml's node-version names (batch 108 passed the gate on Node 25 and trapped on CI's Node 22) (until A12P6 the first two and the missing java passed green). `dev/lanes.sh --lane <name> [--part i/N]` runs one lane of that same run, every other lane a no-op, its skips still red; .github/workflows/gate.yml (dev/gate.sh) is that run on CI's runners, one job per lane through it: every lane the default run has, each split lane with every part 0..N-1 of one N (registry coverage, when split, given its verdict by a job over every part's hits, `--lane coverage --merge`), `julia` 1.12 and `julia +1.13` from juliaup as the script calls them, Node from ci.yml's node-version, fail-fast (the first red job cancels the rest, as the script stops), every TLC instance (--all), none of the lanes' own variables (WT_*, TLC_*) set by the workflow, and triggered only by a gate/** push or workflow_dispatch, ci.yml and formal.yml never by a gate/** push (their push triggers are exactly `branches: [main, 'march/**']`, no branches-ignore) (Dale 2026-10-09: the gate off the local machine). Batch 101 passed ratchet, probes and smoke on both versions, then broke a runtests family on CI (runtime-length flat function composition), and the batch stacked on it was lost with it (2026-10-07; dev/CHARTER.md C10)",
        () -> begin
            _code(path) = join(filter(l -> !startswith(lstrip(l), "#"), split(read(path, String), '\n')), '\n')
            # the script's code, its comment lines dropped (a commented-out lane runs nothing)
            local lanes = _code(joinpath(ROOT, "dev", "lanes.sh"))
            local i = findfirst("if [ \$fast -eq 0 ]; then", lanes)
            i === nothing && return 3
            local gated = lanes[last(i):end]
            local agents = read(joinpath(ROOT, "AGENTS.md"), String)
            local wf = joinpath(ROOT, ".github", "workflows")
            local gate = isfile(joinpath(wf, "gate.yml")) ? _code(joinpath(wf, "gate.yml")) : ""
            # gate.yml's matrix (lane => its parts) against every lane the default run has: a
            # lane missing, a lane the script does not have, or a split lane missing a part
            local runs = Set(m[1] for m in eachmatch(r"(?:^|\s)lane ([a-z][a-z0-9.-]*)\s+(?:\$JULIA|julia|bash|suite|fuzz)\b"m, lanes))
            local jobs = Dict{String,Vector{String}}()
            for m in eachmatch(r"^\s*- \{ lane: ([a-z0-9.-]+), part: '([0-9/]*)' \}\s*$"m, gate)
                push!(get!(jobs, m[1], String[]), m[2])
            end
            local whole = parts -> parts == [""] || (all(p -> occursin(r"^[0-9]+/[1-9][0-9]*$", p), parts) &&
                length(unique(map(p -> split(p, '/')[2], parts))) == 1 &&
                sort(map(p -> parse(Int, split(p, '/')[1]), parts)) == collect(0:parse(Int, split(parts[1], '/')[2]) - 1))
            local matrix_ok = length(runs) == 8 && keys(jobs) == runs && all(whole, values(jobs))
            local pinned_push = map(("ci.yml", "formal.yml")) do f
                local c = _code(joinpath(wf, f))
                occursin("\non:\n  push:\n    branches: [main, 'march/**']\n", c) &&
                    count(r"^\s*push:"m, c) == 1 && !occursin("branches-ignore", c) &&
                    !occursin(r"^on:[ \t]*\S"m, c)
            end
            count(!, [occursin("lane suite suite", gated),
                      occursin(raw"shards=\"0,2 1,2\"; [ \"$only\" = suite ] && [ -n \"$part\" ] && shards=\"$pi,$pn\"", lanes),
                      occursin(raw"  for s in $shards; do" * "\n" * raw"    WT_VALIDATE=1 WT_SHARD=\"$s\" $JULIA --project=. -e 'using Pkg; Pkg.test()' > \"$d/shard$s.log\" 2>&1 &", lanes),
                      occursin("WT_VALIDATE=1 WT_FUZZ=1 \$JULIA --project=. -e 'using Pkg; Pkg.test()'", lanes),
                      occursin("lane smoke-1.13 julia +1.13 --project=. test/smoke.jl", gated),
                      occursin("A batch is pushed only after the full gate is green: `bash dev/gate.sh` (gate.yml, L153, L162).", replace(agents, r"\s+" => " ")),
                      # the first red lane ends the run (batch 111: a 1.13 failure surfaced at minute 29)
                      occursin(raw"stop() { [ $fail -eq 0 ] || { echo \"LANES red\"; exit 1; }; }", lanes),
                      occursin(join([raw"lane ratchet  $JULIA --project=. test/parity_ratchet.jl", "stop"], '\n'), lanes),
                      occursin(join([raw"join_bg \"$d/s113\" \"$d/formal\"; rm -rf dev/formal/states", "stop"], '\n'), lanes),
                      occursin(join([raw"  stop", raw"  lane suite suite", raw"  lane fuzz  fuzz"], '\n'), gated),
                      # --lane runs one lane of the same run: every other lane is a no-op
                      occursin(raw"want() { [ -z \"$only\" ] || [ \"$only\" = \"$1\" ]; }", lanes),
                      occursin(join([raw"  local name=$1; shift", raw"  want \"$name\" || return 0"], '\n'), lanes),
                      # each skip fails the gate (A12P6): a default julia that is not 1.12 ...
                      occursin(join([
                          raw"  if ! want probes && ! want coverage && ! want suite && ! want fuzz; then :",
                          raw"  elif $JULIA -e 'exit(VERSION.major == 1 && VERSION.minor == 12 ? 0 : 1)'; then",
                          raw"    bg \"$d/coverage\" lane coverage $JULIA --project=. test/registry_coverage.jl",
                          raw"    lane probes $JULIA --project=. test/probe_bytes.jl",
                          raw"    join_bg \"$d/coverage\"",
                          raw"  else",
                          raw"    printf '  FAIL probes         (the default julia is not 1.12: probes, coverage and the suite are 1.12 lanes; juliaup default 1.12)\n'; fail=1",
                          raw"  fi"], '\n'), gated),
                      # ... no working java ...
                      occursin(join([
                          raw"  if ! want formal; then :",
                          raw"  elif java -version >/dev/null 2>&1; then bg \"$d/formal\" lane formal bash dev/formal/run_tlc.sh",
                          raw"  else printf '  FAIL formal         (no working java: TLC needs one, brew install openjdk@17)\n'; fail=1; fi"], '\n'), gated),
                      # ... and a JULIA= override or no julia +1.13
                      occursin(join([
                          raw"  if ! want smoke-1.13; then :",
                          raw"  elif [ \"$JULIA\" != \"julia\" ]; then",
                          raw"    printf '  FAIL smoke-1.13     (the gate runs on the default julia, not %s)\n' \"$JULIA\"; fail=1",
                          raw"  elif julia +1.13 -e 'exit(0)' >/dev/null 2>&1; then",
                          raw"    bg \"$d/s113\" lane smoke-1.13 julia +1.13 --project=. test/smoke.jl",
                          raw"  else",
                          raw"    printf '  FAIL smoke-1.13     (julia +1.13 is not installed: juliaup add 1.13)\n'; fail=1",
                          raw"  fi"], '\n'), gated),
                      # the wasm engine is CI's: ci.yml's node-version, a Node of another major fails
                      occursin(join([
                          raw"NODE_MAJOR=$(sed -n \"s/^ *node-version: *'\{0,1\}\([0-9][0-9]*\).*/\1/p\" .github/workflows/ci.yml | head -1)",
                          raw"ci_node=\"$(brew --prefix \"node@$NODE_MAJOR\" 2>/dev/null)/bin\"",
                          raw"[ -x \"$ci_node/node\" ] && export PATH=\"$ci_node:$PATH\"",
                          raw"node_major=$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')",
                          raw"printf '  node %s (CI: %s)\n' \"$(node --version 2>/dev/null)\" \"$NODE_MAJOR\"",
                          raw"if [ -z \"$NODE_MAJOR\" ] || [ \"$node_major\" != \"$NODE_MAJOR\" ]; then",
                          raw"  printf '  FAIL node           (the wasm engine is not CI'\"'\"'s Node %s: brew install node@%s)\n' \"$NODE_MAJOR\" \"$NODE_MAJOR\"; fail=1",
                          raw"fi"], '\n'), lanes),
                      # gate.yml: the default run's lanes, each part of each split lane, one job each ...
                      matrix_ok,
                      occursin(raw"          bash dev/lanes.sh --lane ${{ matrix.lane }}${{ matrix.part != '' && format(' --part {0}', matrix.part) || '' }}${{ matrix.lane == 'formal' && ' --all' || '' }}", gate),
                      # ... the first red job cancels the rest ...
                      occursin("      fail-fast: true\n", gate) && !occursin("fail-fast: false", gate),
                      # ... `julia` 1.12 and `julia +1.13` as the script calls them ...
                      # (in every job that installs Julia)
                      count("      - name: Julia (juliaup)\n", gate) >= 1 &&
                          count(raw"          channel 1.12 && \"$J\" default 1.12" * "\n", gate) == count("      - name: Julia (juliaup)\n", gate),
                      occursin(raw"          if [ \"${{ matrix.lane }}\" = smoke-1.13 ]; then channel 1.13; fi", gate),
                      # ... CI's Node major, read from ci.yml's node-version ...
                      # (every job's: a job of its own Node passed while another kept the line)
                      let majors = count("      - name: CI's Node major\n", gate),
                          reads = count(raw"          echo \"node=$(sed -n \"s/^ *node-version: *'\{0,1\}\([0-9][0-9]*\).*/\1/p\" .github/workflows/ci.yml | head -1)\" >> \"$GITHUB_OUTPUT\"", gate),
                          versions = filter(l -> occursin(r"^\s*node-version:", l), split(gate, '\n'))
                          majors >= 1 && reads == majors && length(versions) == majors &&
                              all(==(raw"          node-version: ${{ steps.ci.outputs.node }}"), versions)
                      end,
                      # ... no lane variable set by the workflow (the script sets them) ...
                      !occursin(r"\b(WT|TLC)_[A-Z_]+", gate),
                      # ... and split coverage's verdict on the union of every part's hits
                      get(jobs, "coverage", [""]) == [""] ||
                          (occursin("  coverage-merge:\n    needs: lane\n", gate) &&
                           occursin("          bash dev/lanes.sh --lane coverage --merge\n", gate) &&
                           occursin(raw"  export WT_COVERAGE_MERGE=1 WT_COVERAGE_DIR=\"$PWD/coverage-parts\"", lanes) &&
                           occursin(raw"    coverage) export WT_COVERAGE_PART=\"$part\" WT_COVERAGE_DIR=\"$PWD/coverage-parts\" ;;", lanes)),
                      # ... and only on gate/**, where ci.yml and formal.yml never run
                      occursin("\non:\n  push:\n    branches: ['gate/**']\n  workflow_dispatch:\n\n", gate) &&
                          !occursin(r"^\s*(pull_request|schedule|workflow_run|workflow_call):"m, gate),
                      # ci.yml's and formal.yml's push triggers are exactly main and march/** (no
                      # branches-ignore, no unfiltered or inline push), so no gate/** push runs them
                      pinned_push...])
        end),
    "L155_exception_handling_is_dart_legacy" => ("Exception handling is dart's legacy form: no try_table, throw_ref, catch_all, catch_ref or delegate, as a constructor or opcode in src. Every region opens with try_legacy!, whose outputs are the tag's payload, and closes with catch_legacy! on the exception tag, held by handle. Every printed probe module holds no `try_table`, `throw_ref`, `delegate` or `catch_all`. dart2wasm emits only legacy exception handling (code_generator.dart:945 try_legacy, :999 catch_legacy; try_table exists only in wasm_builder), and its try runs with a concrete-reference result on CI's engine, V8 12.4 in Node 22, where a try_table with one traps (batch 108). The source half counts each such name outside a comment in src, a try_legacy! or catch_legacy! call in codegen beyond the region's one each, and the region's opener, its catch and the tag's payload as written (stackified.jl, generate.jl ensure_exception_tag!); the behavior half is test/probe_bytes.jl, which prints every probe's module with wasm-tools and fails on any of the four, required here as written (dev/MARCH.md 13.17 A13E7; dev/CHARTER.md C5)",
        () -> begin
            # no try_table, throw_ref, catch_all, catch_ref or delegate as a constructor or opcode
            local n = count_sites(r"try_table|TryTable|TRY_TABLE|throw_ref|ThrowRef|THROW_REF|catch_all|CatchAll|CATCH_ALL|catch_ref|CatchRef|CATCH_REF|\bdelegate[!_(]|Delegate\b|DELEGATE")
            # the region: one try whose outputs are the tag's payload, closed by one catch of tag 0
            local stack = read(joinpath(CODEGEN, "stackified.jl"), String)
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            n += occursin("local try_label = try_legacy!(b; results=WasmValType[AnyRef, ExternRef,\n" *
                          "                                                                    ConcreteRef(exc_cell_type(ctx.type_registry), true)])", stack) ? 0 : 1
            n += occursin("                    unreachable!(b)        # structural trap: no normal path reaches the try's end\n                    catch_legacy!(b, exc_tag(ctx.type_registry))", stack) ? 0 : 1
            n += occursin("tag_ft = FuncType(WasmValType[AnyRef, ExternRef, ConcreteRef(cell, true)], WasmValType[])", gen) ? 0 : 1
            n += abs(count_sites(r"\btry_legacy!\("; roots=[CODEGEN]) - 1) +
                 abs(count_sites(r"\bcatch_legacy!\("; roots=[CODEGEN]) - 1) +
                 count_sites(r"InstrIR\.(BeginTry|CatchLegacy)\("; roots=[CODEGEN])
            # the behavior: every probe module, printed, holds none of the four
            local probe = read(joinpath(ROOT, "test", "probe_bytes.jl"), String)
            for req in ("const _NON_DART_EH = r\"\\b(try_table|throw_ref|delegate|catch_all)\\b\"",
                        "        printed = read(pipeline(`wasm-tools print`; stdin=IOBuffer(bytes)), String)",
                        "_non_dart_eh(printed::String)::Bool = occursin(_NON_DART_EH, printed)",
                        "        _non_dart_eh(printed) && push!(non_dart_eh, name)",
                        "    if !isempty(non_dart_eh)")
                occursin(req, probe) || (n += 1)
            end
            n
        end),
    "L156_every_host_import_call_is_counted" => ("every call of a host-declared import is counted, by the host: the glue (host_glue_js) raises the imported count `wasmtarget.host_imports_open` around it and lowers it in a finally, and in wasm the call sits directly between the save of the top at its slot (`import_tops save`, index count of `\$import_tops`) and the restore of the top from that slot after a normal return (emit_direct_call!), the premise of the export boundary's claim (dev/formal/ExceptionStack.tla ImportCall and ImportReturn): an unsaved call leaves an export the host calls back from inside it a stale top, and an unrestored one leaves its caller the callee's (Julia's J2: native 1, 2). The boundary is the host's: no wasm code writes the count, and no export entry (a function named \"<name> (export)\") holds a try or a try_table or declares a local (a prologue that passes every escape untouched, emit_export_entry!). Both are checked on the code itself, not on its text: test/utils.jl's unsaved_host_import_calls and wasm_boundary_sites read a module as wasm-tools prints it, its name section stripped; the first counts each call of a host-declared import (by the compiler's own rule, _is_host_declared_import) not directly between the save and the restore, the second each `global.set` of the count and each try, try_table or local of an entry; test/real_bottom_exceptions.jl asserts both 0 on the export boundary's module, and every module the suite builds with import_stubs asserts the first: in each test file the `import_stubs=` compile sites, less its refusals (a compile in `try … nothing catch`, which builds no module), number exactly its `@test unsaved_host_import_calls(` assertions, so a module built and not asserted fires it (until 2026-10-11 the lock pinned a count of assertion texts per file, and five modules built with import_stubs, two in real_bottom_exceptions.jl and source_maps.jl's two host modules and its later-round one, went unasserted, audit #15 A15P1). This lock requires the assertions and the helpers' bodies as written (audit #13 A13P3: about 25 raw call! sites remain in codegen, and nothing stopped one from reaching a host import; dev/CHARTER.md C6)",
        () -> begin
            local t(f) = read(joinpath(ROOT, "test", f), String)
            local norm(x) = filter(!isempty, map(strip, split(x, '\n')))
            local helpers = [raw"""
function unsaved_host_import_calls(mod::WasmTarget.WasmModule)::Int
    local funcs = [imp for imp in mod.imports if imp.kind == 0x00]
    local host = Set(i - 1 for (i, imp) in enumerate(funcs) if WasmTarget._is_host_declared_import(imp))
    local count = _global_by_name(mod, "\$host_imports_open")
    local tops = _global_by_name(mod, "\$import_tops")
    local top = _global_by_name(mod, "\$exc_top")
    local save = findfirst(f -> f.name == "import_tops save", mod.functions)
    local lines = _printed_lines(mod)
    local n = 0
    for (k, l) in enumerate(lines)
        local c = match(r"^call (\d+)$", l)
        (c !== nothing && parse(Int, c.captures[1]) in host) || continue
        local saved = save !== nothing && k > 1 && lines[k-1] == "call $(length(funcs) + save - 1)"
        local restored = tops !== nothing && count !== nothing && top !== nothing && k + 4 <= length(lines) &&
            lines[k+1:k+4] == ["global.get $tops", "global.get $count",
                               "array.get $(mod.globals[tops + 1].valtype.type_idx)", "global.set $top"]
        (saved && restored) || (n += 1)
    end
    return n
end
""", raw"""
function wasm_boundary_sites(mod::WasmTarget.WasmModule)::Int
    local count = _global_by_name(mod, "\$host_imports_open")
    local entries = Set(WasmTarget.num_imported_funcs(mod) + i - 1 for (i, f) in enumerate(mod.functions)
                        if endswith(f.name, " (export)"))
    local n = 0
    local in_entry = false
    for l in _printed_lines(mod)
        local f = match(r"^\(func \(;(\d+);\)", l)
        if f !== nothing
            in_entry = parse(Int, f.captures[1]) in entries
        elseif startswith(l, "(") && !startswith(l, "(local")
            in_entry = false
        end
        count !== nothing && l == "global.set $count" && (n += 1)
        in_entry && (startswith(l, "(local") || occursin(r"^try(_table)?\b", l)) && (n += 1)
    end
    return n
end
"""]
            local printed = raw"""
_printed_lines(mod::WasmTarget.WasmModule)::Vector{String} =
    String[strip(l) for l in split(read(pipeline(pipeline(`wasm-tools strip --all`;
        stdin=IOBuffer(WasmTarget.to_bytes(mod))), `wasm-tools print`), String), '\n')]
"""
            local u = t("utils.jl")
            local missing_ = count(h -> begin
                    local name = match(r"function (\w+)\(", h).captures[1]
                    local m = match(Regex("(?s)\\nfunction " * name * "\\(.*?\\nend\\n"), u)
                    m === nothing || norm(m.match) != norm(h)
                end, helpers)
            missing_ += occursin(strip(printed), u) ? 0 : 1
            missing_ += length(findall("@test wasm_boundary_sites(m) == 0", t("real_bottom_exceptions.jl"))) == 1 ? 0 : 1
            # in every test file, each compile site with import_stubs that builds a module (not a
            # refusal: a compile in `try … nothing catch`) has its assertion
            local unasserted = 0
            for (dir, _, fs) in walkdir(joinpath(ROOT, "test")), f in fs
                (endswith(f, ".jl") && f != "parity_ratchet.jl") || continue
                local lines = readlines(joinpath(dir, f))
                local sites = 0
                for (k, l) in enumerate(lines)
                    (_iscomment(l) || !occursin(r"\bimport_stubs=", l)) && continue
                    local after = lines[k + 1:min(k + 4, length(lines))]
                    local j = findfirst(x -> occursin(r"^\s*nothing\s*$", x), after)
                    (j !== nothing && j < length(after) && occursin(r"^\s*catch\b", after[j + 1])) && continue
                    sites += 1
                end
                unasserted += abs(sites - count(l -> occursin("@test unsaved_host_import_calls(", l), lines))
            end
            missing_ + unasserted
        end),
    "L157_every_function_named" => ("every function codegen defines is named where it is defined, so the name section names every frame of a trap: define_function!'s and add_function!'s `name` is a required keyword (no default), and every `define_function!(` and `add_function!(` call in src and ext passes `name=` (read to its closing paren across lines; the definitions, comment lines and a docstring's signature line are not calls). A function compiled from Julia IR takes its Julia name; one the compiler generates takes its construct's, from generated_function_name's one vocabulary (GENERATED_CONSTRUCTS, diagnostics.jl): dart's text where dart has the construct (\"\$name trampoline\", \"\${selector.name} (polymorphic dispatcher)\", \"\$name (lazy initializer)\", \"\$memberName field initializer\", \"#init\"), what it ports where it is Julia's alone (jl_egal, jl_has_typevar, __udivmodti4, Random.__init__). Julia raises UndefKeywordError only when a call runs, so this lock carries the requirement to the edit site; a function's body is filled into it under the name it was defined with (fill_function!); an empty name, which the name section cannot carry, is refused with an ArgumentError naming the call by define_function! (which add_function! calls) and by WasmFunction's inner constructor, and the name-section writer writes every function's name, skipping none. 18 sites once defined an unnamed function, and a trap there printed \"no statement (the function's entry, or code the compiler generated)\" (test/generated_names.jl; dev/CHARTER.md C10)",
        () -> begin
            local n = 0
            for root in (SRC, joinpath(ROOT, "ext")), (dir, _, fs) in walkdir(root), f in fs
                endswith(f, ".jl") || continue
                local s = read(joinpath(dir, f), String)
                for m in findall(r"\b(?:add|define)_function!\(", s)
                    local ls = something(findprev('\n', s, first(m)), 0) + 1
                    local nl = findnext('\n', s, first(m))
                    local line = s[ls:(nl === nothing ? lastindex(s) : prevind(s, nl))]
                    _iscomment(line) && continue
                    occursin(r"\bfunction\s+(?:add|define)_function!\(", line) && continue
                    occursin(r"^\s*(?:add|define)_function!\(.*\)\s*->", line) && continue   # a docstring's signature
                    local j = last(m); local k = j; local depth = 0
                    while k <= lastindex(s)
                        s[k] == '(' && (depth += 1)
                        s[k] == ')' && (depth -= 1; depth == 0 && break)
                        k = nextind(s, k)
                    end
                    occursin(r"\bname\s*=", s[j:min(k, lastindex(s))]) || (n += 1)
                end
            end
            # the keyword itself carries no default, and an empty name is refused at both definitions
            local def = read(joinpath(SRC, "builder", "instructions.jl"), String)
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            n + !occursin("results::Vector{<:WasmValType};\n                          name::String)::UInt32", def) +
                !occursin("function add_function!(mod::WasmModule, b::InstrBuilder; name::String)::UInt32", ib) +
                !occursin("    isempty(name) && throw(ArgumentError(\"define_function!(…; name=\\\"\\\"): ", def) +
                !occursin("        isempty(name) && throw(ArgumentError(\"WasmFunction(type \$type_idx; name=\\\"\\\"): ", def) +
                occursin("isempty(f.name) || push!(func_names", def)
        end),
    "L158_one_compile_entry" => ("one compile entry, as dart2wasm's compile(options, ioManager, handleDiagnosticMessage) is (compile.dart:216): _compile (src/WasmTarget.jl) takes every public entry's keywords, typed, with source maps (`source_map_url`) and the statement trace (`trace`) options of it, and returns one CompileResult (compile.dart:88 CodegenResult); it alone reads the options (options_from_env) and hands them with the caller's ledger to the compile, whose Translator holds them (no OPTIONS, no DIAGNOSTICS_SINK in src: R40); among src/WasmTarget.jl's code it alone calls compile_module and _emit_module; each exported entry — compile, compile_multi, compile_with_sourcemap, compile_multi_with_sourcemap, compile_with_statement_trace — is one call of it, so the source-map and trace entries take diagnostics_sink and the source-map entries the framework keywords (existing_module, import_stubs, root_bindings, link_roots) compile_multi takes; and compile_function, a second road to compile_module, is gone from src and test. compile_module stays exported, the internal step below the entry that tests call to inspect a module: called directly it reads the environment's options itself and routes no ledger, which its docstring says. test/source_maps.jl runs both: a rejection through the source-map and trace entries fills the caller's sink, and compile_multi_with_sourcemap into a host's module answers compile_multi's bytes plus the URL section (dev/CHARTER.md C10)",
        () -> begin
            local api = read(joinpath(SRC, "WasmTarget.jl"), String)
            local body(name) = (m = match(Regex("(?s)\\nfunction " * name * "\\(.*?\\nend\\n"), api); m === nothing ? "" : m.match)
            local entry = body("_compile")
            local v = isempty(entry) ? 1 : 0
            # every keyword of the one entry is typed: `name::T=default`
            local sig = match(r"(?s)\nfunction _compile\(functions::Vector;(.*?)\)::CompileResult\n", api)
            if sig === nothing
                v += 1
            else
                local parts = String[]; local depth = 0; local cur = IOBuffer()
                for c in sig.captures[1]   # the keywords, split at top-level commas
                    c in "({[" && (depth += 1); c in ")}]" && (depth -= 1)
                    c == ',' && depth == 0 ? push!(parts, String(take!(cur))) : write(cur, c)
                end
                push!(parts, String(take!(cur)))
                v += count(k -> !occursin(r"^\s*\w+::", k), parts)
            end
            # the one entry reads the options once and hands them and the caller's ledger to the
            # compile (its Translator holds them, R40): no process-wide options or ledger exists
            v += occursin("options=options_from_env(), diagnostics=diagnostics_sink", entry) ? 0 : 1
            v += count_sites(r"\bOPTIONS\b|\bDIAGNOSTICS_SINK\b"; roots=[SRC])
            # compile_module( and _emit_module( called in src/WasmTarget.jl only inside the one entry
            local outside = replace(api, entry => "")
            for l in split(outside, '\n')
                _iscomment(l) && continue
                occursin(r"^function\s", l) && continue
                occursin(r"^\s*_emit_module\(.*\)\s*->", l) && continue   # a docstring's signature
                v += length(collect(eachmatch(r"\b(compile_module|_emit_module)\(", l)))
            end
            # each exported entry is one call of the one entry
            for name in ("compile", "compile_multi", "compile_with_sourcemap",
                         "compile_multi_with_sourcemap", "compile_with_statement_trace")
                local b = body(name)
                v += (!isempty(b) && length(collect(eachmatch(r"\b_compile\(", b))) == 1) ? 0 : 1
            end
            # compile_function is gone from src and test
            v + count_sites(r"\bcompile_function\b"; roots=[SRC, joinpath(ROOT, "test")], exclude_files=["parity_ratchet.jl"])
        end),
    "L159_every_julia_offset_mapped" => ("every byte of a function compiled from Julia IR maps to its statement or to its definition, and only a statement Julia gives no location of its own is unmapped, as dart2wasm maps a member: map_to_definition! (statement 0: the method's definition, derived once per function from the plan's MethodInstance by definition_source_info in the compile loop, which the whole-body arms use too) maps the entry before any instruction (generate_body; code_generator.dart:3625), compile_statement!'s `finally` and the stackifier's return and block ends map the code after a statement back to it (translateStatement's `finally` restores the member's offset, :721), and a body that replaces a whole compiled function — a selector caller or a standalone intrinsic body — is mapped whole to its definition (`start_source_mapping!(b, definition)` before the body builder's first instruction, the one arm of the compile loop both take; :3627-3634); stop_source_mapping! is called in codegen exactly once, map_to_statement!'s arm for a statement with no location of its own (code_generator.dart:196 noOffset); _stmt_line_nodes takes no earlier statement's location (no backward walk), so the source map, stmt_frames and julia_loc share one decoding that names the definition for such a statement; and every recorded body's mappings end at its end through one builder-layer rule, body_end_mapping (instructions.dart:78): builder_code_mapped appends it to every serialized builder's, which fill_function! reads a body's mappings from (a generated function's too, as dart's serializer ends every body), and the code-section writer only shifts mappings, so no function borrows another's segment. test/source_maps.jl measures it over straight-line code, a loop with phis, a try/catch, a closure, a selector caller and a standalone rethrow body: no byte borrowed across functions, and unmapped bytes only in a function with a statement Julia gives no location, the exact per-function counts pinned on Julia 1.12 (dev/CHARTER.md C10)",
        () -> begin
            local stm = read(joinpath(CODEGEN, "statements.jl"), String)
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local comp = read(joinpath(CODEGEN, "compile.jl"), String)
            local stk = read(joinpath(CODEGEN, "stackified.jl"), String)
            local diag = read(joinpath(CODEGEN, "diagnostics.jl"), String)
            local ins = read(joinpath(SRC, "builder", "instructions.jl"), String)
            local fbody(text, name) = (m = match(Regex("(?s)\\nfunction " * name * "\\(.*?\\nend\\n"), text); m === nothing ? "" : m.match)
            # exactly one stop in codegen, in map_to_statement!'s no-location arm
            local v = abs(count_sites(r"\bstop_source_mapping!\("; roots=[CODEGEN]) - 1) +
                      (occursin("return info === nothing ? stop_source_mapping!(b) : start_source_mapping!(b, info)",
                                fbody(stm, "map_to_statement!")) ? 0 : 1)
            local required = [(stm, "map_to_definition!(b::InstrBuilder, ctx::AbstractCompilationContext)::InstrBuilder = map_to_statement!(b, ctx, 0)"),
                              (stm, "local info = idx == 0 ? ctx.stmt_sources[0] : get!(() -> stmt_source_info(ctx, idx), ctx.stmt_sources, idx)"),
                              (comp, "            ctx.stmt_sources[0] = definition\n            b = generate_body(_ctx_function_builder(ctx, func_idx), ctx)"),
                              (stm, "    finally\n        # the code after the statement maps to the function's definition again, as dart's\n        # `finally` restores the enclosing member's offset (code_generator.dart:721)\n        map_to_definition!(b, ctx)\n    end"),
                              (fbody(gen, "generate_body"), "::InstrBuilder\n    # the function's entry, before any instruction, maps to its definition, as dart sets the\n    # member's offset before it generates the body (code_generator.dart:3625)\n    map_to_definition!(b, ctx)\n"),
                              (stk, "map_to_definition!(bb, ctx)   # the code after the return is the function's again"),
                              (stk, "        map_to_definition!(b, ctx)\n"),
                              (read(joinpath(SRC, "builder", "instr_builder.jl"), String), "records_source_maps(b) && push!(mapped, body_end_mapping(code))")]
            v += count(((text, needle),) -> !occursin(needle, text), required)
            # both whole-body arms map to the definition at the body builder's first instruction, in
            # the one arm they share, and end through the builder's rule (fill_function! reads it)
            v += abs(length(collect(eachmatch(r"\n            b = function_builder\(mod, func_idx\)\n            definition === nothing \|\| start_source_mapping!\(b, definition\)\n", comp))) - 1)
            v += occursin("    local code, mappings = builder_code_mapped(b)\n    mod.functions[slot] = WasmFunction(fn.type_idx, copy(b.locals), code, mappings, fn.name)",
                          read(joinpath(SRC, "builder", "instr_builder.jl"), String)) ? 0 : 1
            # one writer of a body's end: the code-section writer appends no mapping of its own
            v += length(collect(eachmatch(r"push!\(code_mappings, SourceMapping\(", ins)))
            # no backward walk in the one decoding
            local nodes = fbody(diag, "_stmt_line_nodes")
            v + (isempty(nodes) || occursin(r"-=\s*1|\bwhile\b|\bfor\b", nodes) ? 1 : 0)
        end),
    "L160_an_escape_names_its_type" => ("an escaped Julia exception names its type, as dart's minified build names a class through its source map: every module compile_module builds defines one exported reader, `wasmtarget.class_id: (anyref) -> i32` (ensure_class_id_reader!, generate.jl), at the end of compile_module over the final numbering, its body the class of the value's typeof: a type object's class its kind's (emit_type_object_kind!, the kind rule typeof reads), then emit_class_id!'s rule over `Any` (code_generator.dart:6076 loadClassId), so null is Nothing, a bare array one class has answers its class, and a value with no header traps at the cast, never a guessed class; the host's one escape helper (host_escape_js) reads the class from the payload's exception (`getArg(tag, 0)`, after any rethrow(e) replaced it; invoke_main_patch.dart:43-52) and answers `minified:Class<id>` (type.dart:344), or a trap saying the class could not be read; _compile hands compile_module's class names (`string(T)` per classId, compile.dart:617) to _emit_module, which has every mapped build's source map name them after serialization and before the map is encoded (source_map_json's add_minified_class_names!, source_map_utils.dart:15; compile.dart:633-639), and _run_wasm_opt reads them from the input map and adds them to the decoded output map (minified_class_names, source_map_utils.dart:63; io_util.dart:162-171, :206-211); in test/, `getArg(tag, 0)` appears nowhere (the helper is the one reader), every fuzz runner, run_wasm_single and the locator catch through the helper, and the runner alone writes \"uncaught Julia exception <type>\", resolved through the map (escaped_class_name). test/source_maps.jl runs it: ArgumentError, DomainError, a user exception, `nothing` and a type object (DataType) escape named, with and without wasm-opt, a rethrow(e) names its replacement while its stack names the first throw, a shared bare array reports its class unreadable in the reader's frame, and a class numbered in a later collection round of a host-import module is named (dev/CHARTER.md C10)",
        () -> begin
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local comp = read(joinpath(CODEGEN, "compile.jl"), String)
            local api = read(joinpath(SRC, "WasmTarget.jl"), String)
            local smap = read(joinpath(SRC, "builder", "source_map.jl"), String)
            local runner = read(joinpath(ROOT, "test", "wasm_runner.jl"), String)
            local fbody(text, name) = (m = match(Regex("(?s)\\nfunction " * name * "\\(.*?\\nend\\n"), text); m === nothing ? "" : m.match)
            local reader = fbody(gen, "ensure_class_id_reader!")
            local helper = fbody(gen, "host_escape_js")
            local required = [(reader, "add_export!(mod, generated_export_name!(namer, \"wasmtarget.class_id\"), 0,"),
                              (reader, "emit_type_object_kind!(b, registry, 0, allocate_local!(ctx, I32), done, id!)"),
                              (reader, "local_get!(b, 0)\n    emit_class_id!(b, ctx, Any)\n    end_block!(b)\n    finish_function!(b)"),
                              (comp, "    ensure_class_id_reader!(mod, type_registry, translator, namer)\n"),
                              (helper, "exports['wasmtarget.class_id'](e.getArg(tag, 0))"),
                              (helper, "return { throw: 'minified:Class' + id, stack }"),
                              (fbody(api, "_compile"), "_emit_module(result[1]; optimize, validate, class_names=_class_names(result[2]))"),
                              (fbody(api, "_emit_module"), "to_bytes_with_source_map(mod; class_names)"),
                              (smap, "    class_names === nothing || add_minified_class_names!(sm, class_names)\n    return _json_write(sm)"),
                              (fbody(api, "_run_wasm_opt"), "minified_class_names(source_map_json)"),
                              (fbody(api, "_run_wasm_opt"), "_json_write(add_minified_class_names!(_json_read(out_map)::Vector{Pair{String,Any}}, class_names))"),
                              (smap, "const _SOURCE_MAP_EXTENSION_NAME = \"x_org_dartlang_dart2js\""),
                              (smap, "\"minified_names\" => "),
                              (smap, "\"Class\$("),
                              (runner, "\"uncaught Julia exception \" * escaped_class_name(String(r[\"throw\"]), source_map)")]
            local v = count(((text, needle),) -> !occursin(needle, text), required)
            # one reader of the payload's exception: getArg(tag, 0) once in src, in the helper,
            # and nowhere in test/ (this file aside); no JS catch in test/ writes the escape's text
            v += abs(count_sites(r"\.getArg\(tag, 0\)") - 1)
            v += count_sites(r"\.getArg\(tag, 0\)|'uncaught Julia exception"; roots=[joinpath(ROOT, "test")],
                             exclude_files=["parity_ratchet.jl"])
            # every runner catch that reports an outcome goes through the helper
            for (f, n) in (("wasm_runner.jl", 1), (joinpath("fuzz", "harness.jl"), 2), (joinpath("fuzz", "bridge.jl"), 1),
                           (joinpath("fuzz", "bridge_args.jl"), 1), ("trace_localize.jl", 1))
                local t = read(joinpath(ROOT, "test", f), String)
                v += abs(length(collect(eachmatch(r"host_escape_js\(\)", t))) - n) +
                     length(collect(eachmatch(r"catch\s*\((?:e|err)\)\s*\{\s*return \{ trap: String\(", t)))
            end
            v
        end),
    "L161_the_lane_is_strict_on_throws" => ("the differential lanes the fuzz property drives (the statement-generator lane, test/fuzz/test_statements.jl, and the bounded fuzz) count a native throw as matched only by a Julia exception of native's type in wasm: Julia is the ground truth, and a Julia `catch` catches an exception of a type, never a wasm trap. FuzzProperty.classify is the one rule: the wasm side is `(:ok, v)`, `(:throw, type)` (an escaped Julia exception, named through the source map, L160) or `(:trap, msg)`; native returns and wasm throws or traps is :runtime_trap; native throws and wasm returns, traps or throws another type is :divergent_throw; it has no `both error` match, and _differential_args calls it for every sample (its own both-failed fall-through, a second copy of the loose rule, is gone), as the reproducer of a recorded gap reads the same rule (test/fuzz/run.jl). The lane prints a divergent throw with its full program, input, native exception and wasm outcome, and fails. test/fuzz/test_statements.jl runs it on synthetic outcomes and two planted miscompiles of `÷`'s guard (no guard: native DivideError, wasm trap \"divide by zero\"; a guard throwing StackOverflowError), each :divergent_throw (until batch 114 any wasm failure matched a native throw, and both plants passed; dev/CHARTER.md C10)",
        () -> begin
            local prop = read(joinpath(ROOT, "test", "fuzz", "property.jl"), String)
            local lane = read(joinpath(ROOT, "test", "fuzz", "test_statements.jl"), String)
            local run = read(joinpath(ROOT, "test", "fuzz", "run.jl"), String)
            local fbody(text, name) = (m = match(Regex("(?s)\\nfunction " * name * "\\(.*?\\nend\\n"), text); m === nothing ? "" : m.match)
            local required = [(fbody(prop, "classify"), "wstat === :throw && wv[2] == string(typeof(nv[2])) && return :match\n    return :divergent_throw"),
                              (fbody(prop, "_differential_args"), "cat = classify(nv, (w[1], w[2]), cmp)"),
                              (run, "_ok = _nat[1] === :throw ? (_res[1] === :throw && _res[2] == string(typeof(_nat[2]))) :"),
                              (lane, "@testset \"the statement lane is strict on throws\" begin"),
                              (lane, "_WT.INTRINSIC_BINOPS[k] = _WT.BinOpEmit((b, ctx, jw) -> _WT.num!(b, _WT.Opcode.I64_DIV_S), _WT.I64)"),
                              (lane, "_WT._emit_throw_error_struct!(bld, ctx, StackOverflowError)"),
                              (lane, "@test o.native[2] isa DivideError && o.wasm == (:throw, \"StackOverflowError\")")]
            count(((text, needle),) -> !occursin(needle, text), required) +
                length(collect(eachmatch(r"both error|nstat === :throw && wstat === :ok|wstat === :trap", prop)))
        end),
    "L162_the_gate_has_a_budget" => ("the gate gives its verdict in minutes: every lane of `bash dev/lanes.sh`'s default run on CI's runners (gate.yml, one job each, L153) within a budget of 20 minutes per lane job, the lane job's `timeout-minutes: 20` exactly, so a slow lane and a hung one are both cut at the budget, red, and fail-fast cancels the rest; coverage-merge's timeout is at most 10 minutes and gate.yml holds no other timeout; dev/gate.sh reads the budget from gate.yml's lane job (one source), prints the slowest lane job against it and marks a job past it; AGENTS.md's gate sentence names `bash dev/gate.sh`. The budget is admitted by five consecutive green runs on the final matrix, cold-cache runs (a new gate branch) among them, each with every lane job <= 0.95 B = 1140 s; the commit that set B names them; run 37930172953 (fuzz 1/4 1148 s) forced the fuzz parts' re-dealing and run 37943322602 (cold caches, cut at the budget) the 6 suite shards and 5 fuzz parts; it is lowered only, never raised: a lane past it is rebalanced or split first (Dale 2026-10-09, the gate \"~15-20 min\"; until batch 114 a lane job could run 45 minutes and the serial local run took 56; dev/CHARTER.md C10)",
        () -> begin
            local gate = read(joinpath(ROOT, ".github", "workflows", "gate.yml"), String)
            local sh = read(joinpath(ROOT, "dev", "gate.sh"), String)
            local agents = replace(read(joinpath(ROOT, "AGENTS.md"), String), r"\s+" => " ")
            local job(name) = (m = match(Regex("(?s)\\n  " * name * ":\\n(.*?)(?=\\n  [a-z][a-z-]*:\\n|\\z)"), gate); m === nothing ? "" : m.captures[1])
            local lane_t = [parse(Int, m[1]) for m in eachmatch(r"^    timeout-minutes: (\d+)\b"m, job("lane"))]
            local merge_t = [parse(Int, m[1]) for m in eachmatch(r"^    timeout-minutes: (\d+)\b"m, job("coverage-merge"))]
            count(!, [lane_t == [20],
                      length(merge_t) == 1 && merge_t[1] <= 10,
                      length(collect(eachmatch(r"timeout-minutes:", gate))) == 2,
                      occursin("A batch is pushed only after the full gate is green: `bash dev/gate.sh`", agents),
                      occursin(raw"budget=$(awk '/^  lane:$/ { inlane = 1; next } /^  [a-z][a-z-]*:$/ { inlane = 0 }", sh) &&
                          occursin(raw"inlane && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate.yml)", sh) &&
                          occursin(raw"-v B=\"$budget\"", sh) && occursin("PAST THE %d-MINUTE BUDGET", sh)])
        end),
    "L163_the_fast_lane" => ("the inner loop on CI's runners: `bash dev/gate.sh --fast` pushes a commit to gate-fast/<name>, never to gate/, where .github/workflows/gate-fast.yml runs the ratchet and smoke on Julia 1.12 and 1.13 through `dev/lanes.sh --lane <ratchet|smoke|smoke-1.13> [--part i/N]` and prints `FAST green` or `FAST red`; it runs no Julia on this machine, and the full gate (gate.yml, L153, L162) stays the push gate. gate-fast.yml's triggers are exactly a `gate-fast/**` push and workflow_dispatch; its matrix is exactly the ratchet, smoke parts 0..N-1 of one N and smoke-1.13 parts 0..M-1 of one M, with N and M the values its header states as measured, and 1 + N + M <= 20 (the account's concurrent runners); fail-fast; the lane job's timeout-minutes is the fast budget B_fast, which dev/gate.sh --fast reads from there (one source) and gate-fast.yml holds no other timeout; no WT_* or TLC_* variable is set by the workflow; ci.yml, formal.yml and gate.yml are not triggered by a gate-fast/** push; AGENTS.md's enforcement table has its row, `bash dev/gate.sh --fast` as ratchet + both smokes on CI's runners, the inner loop, not the push gate (dev/CHARTER.md C10)",
        () -> begin
            _code(path) = join(filter(l -> !startswith(lstrip(l), "#"), split(read(path, String), '\n')), '\n')
            local wf = joinpath(ROOT, ".github", "workflows")
            isfile(joinpath(wf, "gate-fast.yml")) || return 1
            local fast_raw = read(joinpath(wf, "gate-fast.yml"), String)
            local fast = _code(joinpath(wf, "gate-fast.yml"))
            local sh = read(joinpath(ROOT, "dev", "gate.sh"), String)
            local agents = replace(read(joinpath(ROOT, "AGENTS.md"), String), r"\s+" => " ")
            local v = 0
            # the triggers, exactly
            v += occursin("\non:\n  push:\n    branches: ['gate-fast/**']\n  workflow_dispatch:\n", fast) &&
                 count(r"^\s*push:"m, fast) == 1 && !occursin("branches-ignore", fast) ? 0 : 1
            # the matrix: the ratchet, smoke 0..N-1, smoke-1.13 0..M-1, with the N and M the header states
            local jobs = Dict{String,Vector{String}}()
            for m in eachmatch(r"^\s*- \{ lane: ([a-z0-9.-]+), part: '([0-9/]*)' \}\s*$"m, fast)
                push!(get!(jobs, m[1], String[]), m[2])
            end
            local stated = match(r"N = (\d+) and M = (\d+)", fast_raw)
            local N = stated === nothing ? -1 : parse(Int, stated[1])
            local M = stated === nothing ? -1 : parse(Int, stated[2])
            local parts(n) = String["$i/$n" for i in 0:n-1]
            v += (sort(collect(keys(jobs))) == ["ratchet", "smoke", "smoke-1.13"] && jobs["ratchet"] == [""] &&
                  sort(jobs["smoke"]) == sort(parts(N)) && sort(jobs["smoke-1.13"]) == sort(parts(M))) ? 0 : 1
            v += 1 + N + M <= 20 ? 0 : 1
            v += occursin("      fail-fast: true\n", fast) && !occursin("fail-fast: false", fast) ? 0 : 1
            # the budget: the lane job's timeout, the one gate.sh --fast reads, and no other timeout
            local lane_t = [parse(Int, m[1]) for m in eachmatch(r"^    timeout-minutes: (\d+)\b"m, fast)]
            v += length(lane_t) == 1 && length(collect(eachmatch(r"timeout-minutes:", fast))) == 1 ? 0 : 1
            v += occursin(raw"inlane && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate-fast.yml)", sh) ? 0 : 1
            v += occursin("bash dev/lanes.sh --lane \${{ matrix.lane }}\${{ matrix.part != '' && format(' --part {0}', matrix.part) || '' }}\n", fast) ? 0 : 1
            # no lane variable set by the workflow
            v += occursin(r"\b(WT|TLC)_[A-Z_]+", fast) ? 1 : 0
            # ci.yml, formal.yml and gate.yml never run on a gate-fast/** push
            for f in ("ci.yml", "formal.yml", "gate.yml")
                local c = _code(joinpath(wf, f))
                v += occursin("gate-fast", c) || occursin("'**'", c) || occursin("branches-ignore", c) ? 1 : 0
            end
            # gate.sh --fast pushes to gate-fast/ and never to gate/
            v += occursin("[ \$fast -eq 0 ] || { prefix=gate-fast; workflow=\"Gate fast\"; verdict=FAST; }", sh) &&
                 occursin("name=\$prefix/\${name//\\//-}", sh) ? 0 : 1
            v += occursin("| the inner loop, not the push gate: ratchet + both smokes on CI | `bash dev/gate.sh --fast` L163 |", agents) ? 0 : 1
            v
        end),
    "L164_one_subtype_relation" => ("one subtype relation, in the builder, as dart's isSubtypeOf lives beside its types (type.dart:236 RefType.isSubtypeOf, :733 DefType.isSubtypeOf): wasm_subtype, the heap-kind resolver, the same-top predicate and the non-null map are each defined once, in src/builder/types.jl; src/codegen defines none of the lattice names and no `_non_null` exists. Its behavior, run over src/builder alone: a defined function type is a subtype of itself, of func and of its nullable form, never of another function type, of an abstract type outside func or of a struct; a struct reaches its declared supertype; a non-null exn reference is a subtype of exnref; and test/builder_cases.jl's rows a-c (funcref is no (ref null \$sig), two function types are unrelated, an undefined type index is invalid, never a guessed struct) reject at their call (dev/AUDIT.md A3B3; dev/CHARTER.md C7)",
        () -> begin
            local names = ["wasm_subtype", "_wt_is_ref", "_wt_ref_nullable", "_wt_drop_nullable", "_wt_heap_kind",
                           "_wt_heap_kind_of_byte", "_wt_hierarchy_top", "_wt_same_hierarchy", "_wt_top_ref",
                           "_wt_defined_type", "_wt_concrete_supertype_idx", "_wt_concrete_chain_reaches", "_non_null"]
            local def_rx = Regex("^\\s*(?:@inline\\s+)?(?:function\\s+)?(" * join(names, "|") * ")\\(")
            local v = 0
            local homes = Dict{String,Set{String}}()
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                local rel = relpath(joinpath(dir, f), SRC)
                for line in eachline(joinpath(dir, f))
                    local m = match(def_rx, line)
                    m === nothing && continue
                    # a definition: `function name(` or a short form `name(…)::T =`
                    (startswith(lstrip(line), "function") || occursin(r"\)\s*(::\S+)?\s*=(?!=)", line)) || continue
                    push!(get!(homes, m[1], Set{String}()), replace(rel, '\\' => '/'))
                end
            end
            for n in names
                local h = get(homes, n, Set{String}())
                v += n == "_non_null" ? length(h) : (h == Set(["builder/types.jl"]) ? 0 : 1)
            end
            # the behavior, over the builder alone
            v += in_builder_sandbox() do W
            local m = W.WasmModule()
            local base = W.add_struct_type!(m, [W.FieldType(W.I32, false)])
            local mid = W.add_type!(m, W.StructType([W.FieldType(W.I32, false), W.FieldType(W.I64, false)], UInt32(base)))
            local f = W.add_type!(m, W.FuncType(W.WasmValType[], W.WasmValType[W.I32]))
            local g = W.add_type!(m, W.FuncType(W.WasmValType[], W.WasmValType[W.I64]))
            local cr(i, n=true) = W.ConcreteRef(UInt32(i), n)
            local T = m.types
            local holds = [W.wasm_subtype(cr(f, false), cr(f), T), W.wasm_subtype(cr(f), W.FuncRef, T),
                           W.wasm_subtype(cr(mid), cr(base), T), W.wasm_subtype(cr(mid, false), W.StructRef, T),
                           W.wasm_subtype(W.NonNullAbstractRef(UInt8(W.ExnRef)), W.ExnRef, T),
                           !W.wasm_subtype(cr(f), cr(g), T), !W.wasm_subtype(cr(g), cr(f), T),
                           !W.wasm_subtype(cr(f), W.AnyRef, T), !W.wasm_subtype(cr(f), W.StructRef, T),
                           !W.wasm_subtype(W.FuncRef, cr(f), T), !W.wasm_subtype(cr(base), cr(f), T),
                           !W.wasm_subtype(cr(base), cr(mid), T)]
            count(!, holds)
            end
            v += builder_rows_failing(("a", "b", "c"))
            v
        end),
    "L165_storage_types_are_darts" => ("dart's StorageType split (type.dart:11 StorageType, :39 ValueType, :1370 PackedType): WasmValType's union holds no UInt8 and no PackedType, so no local, parameter, result, label, global or select holds a raw byte or a packed type; PackedType (I8, I16) is a type of its own, which a field's type admits (StorageType, held by FieldType and ArrayType, read through `unpacked`, written by write_storage_type!), StorageType annotating exactly FieldType's field and constructor, ArrayType's constructor, _wt_is_ref, add_array_type! and _defaultable; no `isa UInt8` in src/builder; the packed bytes 0x78 and 0x77 are spelled in src only by PackedType's own definition (and the Opcode constants I32_ROTL and I32_ROTR), so the packed test is `isa PackedType` / `unpacked`, never `in (0x78, 0x77)`; the void block type is InstrIR's VOID_BLOCK, not the byte 0x40. Its behavior, over src/builder alone: test/builder_cases.jl's row d (no local is an i8) rejects and row g (struct.new of a packed field pops its unpacked i32) builds (dev/AUDIT.md A3B4, A12B6; dev/CHARTER.md C7 C1)",
        () -> begin
            local types_src = read(joinpath(SRC, "builder", "types.jl"), String)
            local u = match(r"const WasmValType = Union\{([^}]*)\}", types_src)
            local v = u === nothing ? 1 : (occursin("UInt8", u[1]) || occursin("PackedType", u[1]) ? 1 : 0)
            v += occursin("const StorageType = Union{WasmValType, PackedType}", types_src) ? 0 : 1
            # StorageType annotates exactly these definitions
            local allowed = Dict("builder/types.jl" => 4, "builder/instructions.jl" => 1, "builder/instr_builder.jl" => 1)
            local seen = Dict{String,Int}()
            for (dir, _, files) in walkdir(SRC), f in files
                endswith(f, ".jl") || continue
                local rel = replace(relpath(joinpath(dir, f), SRC), '\\' => '/')
                for line in eachline(joinpath(dir, f))
                    _iscomment(line) && continue
                    seen[rel] = get(seen, rel, 0) + length(collect(eachmatch(r"::StorageType\b", line)))
                end
            end
            filter!(p -> p.second > 0, seen)
            v += seen == allowed ? 0 : 1
            v += count_sites(r"\bisa\s+UInt8\b"; roots=[joinpath(SRC, "builder")])
            v += count_sites(r"0x7[78]\b"; exclude_line=r"const I32_ROT[LR] = 0x7[78]$|^\s*I(8|16) = 0x7[78]\s+#")
            v += count_sites(r"\b0x40\b"; roots=[joinpath(SRC, "builder")], exclude_line=r"push!\(c, 0x40\)|byte & 0x40")
            v += builder_rows_failing(("d", "g"))
            v
        end),
    "L166_operands_typed_by_the_module" => ("every instruction typed as dart types it, by the module's own types (instructions.dart: struct_get :1657, struct_set :1696, struct_new :1711, array_get :1735, array_set :1774, array_new_fixed :1802, array_fill :1875, call :947, call_indirect :960, call_ref :973, global_get :1063 each take the type or function object itself; ref_null :1570 its heap type; one _verifyCast :1927 for ref_test :1944 and ref_cast :1961; the conversions keep nullability :2028 :2040; ref_eq :1632): none of struct_get!, struct_set!, array_get!, array_set!, array_new_fixed!, array_fill!, call!, global_get!, call_ref!, call_indirect!, struct_new! and ref_null! takes a claimed type (each is defined exactly with dart's arguments); one resolver, _module_type, with one policy (an undefined index or another kind is invalid) and _true_call_sig, _true_field_type, _true_elem_type and _function_type_sig gone; ref_test! and ref_cast! both go through _verify_cast!; num! refuses a non-numeric opcode (validate_instruction! holds no constant, memory, parametric or reference arm) and ref_eq! emits ref.eq. Its behavior, over src/builder alone: every row of test/builder_cases.jl holds (each invalid program throws at its call, each valid one builds), which test/module_builder_validation.jl's testset '115a: every instruction typed as dart types it' also runs with wasm-tools; among them a function body takes no constant fragment, whose ref.func was checked as a global initializer's (row w) (dev/AUDIT.md A3B2, A3B6-A3B10, A3B14, A16B2; dev/CHARTER.md C7)",
        () -> begin
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            local val = read(joinpath(SRC, "builder", "validator.jl"), String)
            local expected = Dict(
                "struct_get!" => ["struct_get!(b::InstrBuilder, type_idx::Integer, field_idx::Integer)"],
                "struct_set!" => ["struct_set!(b::InstrBuilder, type_idx::Integer, field_idx::Integer)"],
                "array_get!" => ["array_get!(b::InstrBuilder, type_idx::Integer; signed::Union{Nothing,Bool}=nothing)"],
                "array_set!" => ["array_set!(b::InstrBuilder, type_idx::Integer)"],
                "array_new_fixed!" => ["array_new_fixed!(b::InstrBuilder, type_idx::Integer, n::Integer)"],
                "array_fill!" => ["array_fill!(b::InstrBuilder, type_idx::Integer)"],
                "call!" => ["call!(b::InstrBuilder, func_idx::Integer)"],
                "global_get!" => ["global_get!(b::InstrBuilder, idx::Integer)"],
                "call_ref!" => ["call_ref!(b::InstrBuilder, type_idx::Integer)"],
                "call_indirect!" => ["call_indirect!(b::InstrBuilder, type_idx::Integer, table_idx::Integer)"],
                "struct_new!" => ["struct_new!(b::InstrBuilder, type_idx::Integer)"],
                "ref_null!" => ["ref_null!(b::InstrBuilder, heaptype::Integer)", "ref_null!(b::InstrBuilder, rt::RefType)"])
            local v = 0
            for (name, sigs) in expected
                local defs = String[]
                for (dir, _, files) in walkdir(SRC), f in files
                    endswith(f, ".jl") || continue
                    for line in eachline(joinpath(dir, f))
                        local m = match(Regex("^(?:function\\s+)?(" * replace(name, "!" => "\\!") * "\\([^)]*\\))(?:::InstrBuilder)?\\s*(?:=|\$)"), line)
                        m === nothing || push!(defs, m[1])
                    end
                end
                v += sort(defs) == sort(sigs) ? 0 : 1
            end
            v += count_sites(r"\b(_true_call_sig|_true_field_type|_true_elem_type|_function_type_sig)\b")
            v += length(collect(eachmatch(r"^function _module_type\("m, ib))) == 1 ? 0 : 1
            v += count_sites(r"^function _module_type\(|^_module_type\(") == 1 ? 0 : 1
            # ref_test! (each form) and ref_cast! (each form) check through _verify_cast!
            for m in eachmatch(r"^function (ref_test!|ref_cast!)\(.*?^end"ms, ib)
                occursin("_verify_cast!(b, ", m.match) || (v += 1)
            end
            length(collect(eachmatch(r"^function (ref_test!|ref_cast!)\("m, ib))) == 4 || (v += 1)
            # num!'s validator: no arm for an instruction with an immediate, a memory access, a
            # parametric or a reference instruction
            local vi = match(r"function validate_instruction!\(.*?\nend\n"s, val)
            v += vi === nothing ? 1 :
                 length(collect(eachmatch(r"Opcode\.(I32_CONST|I64_CONST|F32_CONST|F64_CONST|DROP|SELECT|SELECT_T|REF_\w+|\w+_LOAD|\w+_STORE|MEMORY_\w+)\b", vi.match)))
            v += occursin("ref_eq!(b::InstrBuilder)::InstrBuilder =", ib) && occursin("InstrIR.RefEq()", ib) ? 0 : 1
            v += count_sites(r"num!\([^,]*,\s*Opcode\.REF_EQ\)")
            v += builder_rows_failing()
            v
        end),
    "L167_every_body_is_a_module_builder" => ("every body the module holds is a builder the module made, as dart's module holds only builders it made from a declared type (functions.dart:31 define, function.dart:19 FunctionBuilder, its body an InstructionsBuilder of the type's inputs and outputs; globals.dart:29 define, global.dart:13 GlobalBuilder, its initializer an InstructionsBuilder with outputs [type] and constantExpression): define_function! declares a function and function_builder gives its body; fill_function! fills it only from a function's builder (no fragment, no constant expression), complete, of the function's own parameters and results, once, reading the locals and the source mappings from the builder; add_function!(mod, b; name) is define then fill, and no add_function! takes body bytes; define_global! gives a global's initializer, a constant expression whose outputs are the global's type, which fill_global! fills; to_bytes refuses a module holding a function or a global never filled. In text: no assignment to a module's `.functions[…]`, no `push!` onto one, and no WasmFunction or WasmGlobalDef construction outside src/builder; no `add_function!` method takes a `Vector{UInt8}`; `add_global_ref!` does not exist; src/codegen builds no `UInt8[` vector holding an `Opcode.` or a raw byte; `locals_fn` and `builder_set_local_type!` do not exist (a function's builder and its fragments share one locals list, the function's). Its behavior, over src/builder alone: test/builder_cases.jl's body_cases rows f-j reject (a body with no results put in a function [] -> [i64], a function [] -> [i32] filled with a body [i64] -> [i64], an i32 initializing a (ref \$st) global, a call in an initializer, a global.get of a later global), and an unfilled function and an unfilled global each make to_bytes refuse (dev/AUDIT.md A3B16, A5B9, A3B1, A4B1, A11E6, B5; dev/CHARTER.md C7)",
        () -> begin
            local v = count_sites(r"\b(?:mod|m|_m|\w+_mod)\.functions\[[^\]]*\]\s*=(?!=)|push!\((?:\w+\.)*(?:mod|m|_m|\w+_mod)\.functions\b|\bWasmFunction\(|\bWasmGlobalDef\(";
                                  roots=[CODEGEN, joinpath(SRC, "frontend"), joinpath(ROOT, "ext")])
            v += count_sites(r"function add_function!\([^)]*Vector\{UInt8\}")
            v += count_sites(r"\badd_global_ref!"; roots=[SRC, joinpath(ROOT, "ext"), joinpath(ROOT, "test")], exclude_files=["parity_ratchet.jl"])
            v += count_sites(r"UInt8\[[^\]]*(?:Opcode\.|0x[0-9A-Fa-f]{2})"; roots=[CODEGEN])
            v += count_sites(r"\blocals_fn\b|\bbuilder_set_local_type!|_seed_builder_locals!")
            v += body_rows_failing(["f", "g", "h", "i", "j"])
            v += in_builder_sandbox() do W
                local refused(f) = try; f(); false; catch e; e isa W.ModuleValidationError; end
                local m = W.WasmModule(); W.define_function!(m, W.WasmValType[], W.WasmValType[]; name="f")
                local m2 = W.WasmModule(); W.define_global!(m2, W.I32, false)
                count(!, [refused(() -> W.to_bytes(m)), refused(() -> W.to_bytes(m2))])
            end
            v
        end),
    "L168_locals_initialized_before_use" => ("a local whose type has no default value (a non-null reference) is read only where it is set on every path, as dart's builder tracks it (instructions.dart:216-219 _localInitialized and _localInitializationStack; :375 a parameter is set; :382 addLocal sets a defaultable local; :393 local_set and local_tee set it; :1018-1030 local_get requires it, reachable or not; :701 _pushLabel records the stack's height and :566 _verifyEndOfBlock resets to it at end, else and catch_legacy): local_get! requires the local (_require_local!), local_set! and local_tee! set it (_initialize_local!), and _verify_end_of_block!, which validate_block_end!, validate_else! and validate_catch_legacy! each call, resets it (reset_local_initialization!), unconditionally. A fragment, which has not seen what its destination set, records each read of a local unset in it and each set at its outer level, and append_builder! replays the record in order through the destination's own rules: a function's builder rejects an unmet read there, a fragment destination records it in turn (dev/formal/LocalInit.tla, its four Broken instances in run_tlc.sh's list: NoResetAtEnd, MergeIgnoresRequires, MergeAppliesNestedSets, ReplayRejectsInFragment). Its behavior, over src/builder alone: test/builder_cases.jl's body_cases rows a-d reject (a read before any set, a set inside a block read after it, a set in the then arm read in the else, a fragment's unmet read appended where the local was never set) and row e builds (a fragment's outer set meets the next fragment's read) (dev/AUDIT.md A13B1 = A13B6; dev/CHARTER.md C7)",
        () -> begin
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            local val = read(joinpath(SRC, "builder", "validator.jl"), String)
            local fbody(text, name) = (m = match(Regex("(?s)\\nfunction " * replace(name, "!" => "\\!") * "\\(.*?\\nend\\n"), text); m === nothing ? "" : m.match)
            local v = 0
            v += occursin("    _require_local!(b, idx)\n    _emit!(b, InstrIR.LocalGet(UInt32(idx)))", fbody(ib, "local_get!")) ? 0 : 1
            v += occursin("    _initialize_local!(b, idx)\n    _emit!(b, InstrIR.LocalSet(UInt32(idx)))", fbody(ib, "local_set!")) ? 0 : 1
            v += occursin("    _initialize_local!(b, idx)\n    _emit!(b, InstrIR.LocalTee(UInt32(idx)))", fbody(ib, "local_tee!")) ? 0 : 1
            v += occursin("    # the frame's local initializations end with it, reachable or not\n    reset_local_initialization!(v, label)\n    v.reachable || return nothing",
                          fbody(val, "_verify_end_of_block!")) ? 0 : 1
            for f in ("validate_block_end!", "validate_else!", "validate_catch_legacy!")
                v += occursin("_verify_end_of_block!(v, label, ", fbody(val, f)) ? 0 : 1
            end
            v += occursin("    for (kind, x) in src.init_log\n        kind === :init ? _initialize_local!(dst, x) : _require_local!(dst, x, src.func_name)\n    end",
                          fbody(ib, "append_builder!")) ? 0 : 1
            v += occursin("(b.fragment && length(b.v.labels) == 1) && push!(b.init_log, (:init, Int(idx)))", fbody(ib, "_initialize_local!")) ? 0 : 1
            local formal = joinpath(ROOT, "dev", "formal")
            for c in ("NoResetAtEnd", "MergeIgnoresRequires", "MergeAppliesNestedSets", "ReplayRejectsInFragment")
                local cfg = joinpath(formal, "MCLocalInit" * c * "Broken.cfg")
                v += isfile(cfg) && startswith(read(cfg, String), "\\* expect: ") ? 0 : 1
            end
            v += all(f -> isfile(joinpath(formal, f)), ("LocalInit.tla", "MCLocalInit.tla", "MCLocalInit.cfg", "MCLocalInitNested.tla", "MCLocalInitNested.cfg")) ? 0 : 1
            v += occursin("cfgs=(MC*.cfg)", read(joinpath(formal, "run_tlc.sh"), String)) ? 0 : 1
            v + body_rows_failing(["a", "b", "c", "d", "e"])
        end),
    "L170_one_callee_per_method_instance" => ("an :invoke's callee is the function the plan compiles its MethodInstance to, as dart's static invocation calls its target's one function (code_generator.dart:1668, functions.dart:90): compile_invoke! names get_function_by_mi and nothing else, invoke.jl has no get_function( lookup by the callee's object and argument types, no _invoke_registered_signatures, no `<: ctx.arg_types` self rule and no self-call arm (a call of this function is the one call arm's, as dart's static invocation has no recursion case), and a MethodInstance with no function rejects at its statement; every per-function fact the plan holds is keyed by MethodInstance (ClosedWorldPlan's ir_cache, candidate_mis and bespoke), the IR read only through plan_ir / plan_ir_or_nothing (no other `.ir_cache` read in src), and the bespoke decision made once, in trim_compile_plan, from STANDALONE_INTRINSIC_BODIES (no other reader). Behavior: smoke one_consult's invoke_names_its_method (two methods share Int64; `invoke` names the less specific one: native 103004) fails under a signature-first lookup, and test/ir_one_inference_path.jl checks the plan's keys and that a closure body both invoked and called through an `Any` slot is a candidate by its MethodInstance. Until 2026-10-11 the signature lookup ran first and the MethodInstance answered only when it missed (dev/CHARTER.md C1)",
        () -> begin
            local inv = read(joinpath(CODEGEN, "invoke.jl"), String)
            local trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local oip = read(joinpath(ROOT, "test", "ir_one_inference_path.jl"), String)
            local n = 0
            n += occursin("local target = get_function_by_mi(ctx.func_registry, mi)", inv) ? 0 : 1
            n += occursin("# one call arm, self-recursion included", inv) ? 0 : 1
            n += occursin("ctx.func_idx", inv) ? 1 : 0   # no self-call arm: a self call is the call
            n += count(p -> occursin(p, inv), ["get_function(", "_invoke_registered_signatures", "<: ctx.arg_types"])
            n += count(p -> !occursin(p, trim), ["    ir_cache::IdDict{Core.MethodInstance,Tuple{Core.CodeInfo,Type}}\n",
                                                 "    candidate_mis::Set{Core.MethodInstance}\n",
                                                 "    bespoke::IdDict{Core.MethodInstance,Function}\n"])
            # the IR read only by plan_ir_or_nothing (plan_ir reads through it)
            n += abs(count_sites(r"\.ir_cache\b"; roots=[SRC]) - 1)
            n += occursin("    local hit = get(plan.ir_cache, mi, nothing)\n    return hit === nothing ? nothing : (hit[1], hit[2])", trim) ? 0 : 1
            # the bespoke table read once, by the planner
            n += abs(count_sites(r"get\(STANDALONE_INTRINSIC_BODIES\b"; roots=[SRC]) - 1)
            n += occursin("local gen = mi.def isa Method ? get(STANDALONE_INTRINSIC_BODIES, mi.def, nothing) : nothing", trim) ? 0 : 1
            n += count_sites(r"STANDALONE_INTRINSIC_BODIES\[|haskey\(STANDALONE_INTRINSIC_BODIES"; roots=[SRC])
            # the behavior pins
            n += occursin("(\"invoke_names_its_method\", (n::Int64) -> invoke(_sm_oc, Tuple{Integer}, n) * 1000 + _sm_oc(n), Int64(3))", smoke) ? 0 : 1
            n += occursin("@test keytype(plan.ir_cache) === Core.MethodInstance", oip) ? 0 : 1
            n += occursin("@test only(bodies) in plan.candidate_mis", oip) ? 0 : 1
            n
        end),
    "L171_one_method_consult" => ("one consult answers which methods Julia selects: Julia's matching in the WasmInterpreter's overlay table at its world (trimcollect.jl wt_method_matches = CC.findall, wt_method_which = CC.findsup, wt_methods_ambiguous), as dart consults one class hierarchy (translator.dart:108). No hasmethod(, which( (Sys.which aside), _which(, _methods_by_ftype( or isambiguous( outside that block, qualified or not (its ambiguity check is Julia's isambiguous algorithm, base/reflection.jl, run over the consult's matches with the ambiguous ones kept, merged across the overlay table as CC.findall merges it; it calls no Base.isambiguous and never raises), CC.findall( and CC.findsup( (or Core.Compiler.'s) only there, and get_world_counter() only at the interpreter's world (interpreter.jl) and the TypeName world-bound projection (types.jl `host_world`). A statement's codegen asks no table: calls.jl, dispatch.jl, selector_table.jl and invoke.jl name no consult; the vtable pre-pass's ambiguity search, which decides a rejection before any body compiles, asks the one consult (compile.jl wt_methods_ambiguous, closures.jl ambiguous_class_tuple's wt_method_which, its one consult in that file). No flat method_error_args exists; a dynamic call's and a closure entry's MethodError index the plan's per-callee record (no_method), which holds an entry, empty or not, for every callee whose dynamic call the collector enrolled and every planned callable with a vtable, so a missing one raises, and no `get(…no_method…)` default reads it; test/dispatch_method_error.jl reads the module: each no-row block builds one MethodError per tuple of its own callee's record (a flat read adds the other callee's arms, which no answer shows, the rows coming first). Exactly one emitter builds a MethodError (emit_method_error!). Until 2026-10-11 enrollment asked Base's table at the latest world while the plan read the overlay table, and codegen re-asked hasmethod and _methods_by_ftype per switch over one flat set of every callee's tuples (dev/CHARTER.md C1) One site asks the native table another question, exactly: which `show` Julia's own printer calls for a type or a type parameter of a planned function's signature (_user_shown_in_signature, trimcollect.jl), the printing running natively, so that no name is printed by code outside Base and Core (116e-2)",
        () -> begin
            local n = 0
            local consult_fns = Set(["wt_method_matches", "wt_method_which", "wt_dispatch_mi", "wt_methods_ambiguous", "_wt_matches_with_ambiguous"])
            local banned = r"(?<!\w)hasmethod\(|(?<![\w]|Sys\.)which\(|(?<!\w)_which\(|_methods_by_ftype\(|isambiguous\(|(?:CC|Core\.Compiler|Compiler)\.find(?:all|sup)\("
            for (dir, _, fs) in walkdir(SRC), f in fs
                endswith(f, ".jl") || continue
                local rel = replace(relpath(joinpath(dir, f), SRC), '\\' => '/')
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^(?:function\s+|)([A-Za-z_][A-Za-z0-9_!]*)\(.*\)(?:::[^=]+)?\s*=|^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = something(d.captures[1], d.captures[2]))
                    _iscomment(line) && continue
                    if occursin(banned, line)
                        (rel == "codegen/trimcollect.jl" && enclosing in consult_fns) ||
                            # exactly one site asks a question of the native table that is not dispatch of
                            # compiled code: which `show` Julia's own printer calls for a value of a planned
                            # function's signature, the printer running natively (_user_shown_in_signature)
                            (rel == "codegen/trimcollect.jl" && enclosing == "_user_shown_in_signature" &&
                             occursin("Base.moduleroot(parentmodule(which(show, Tuple{IO,Core.Typeof(x)}))) in (Base, Core)", line)) ||
                            (n += 1)
                    end
                    if occursin("get_world_counter()", line)
                        (rel == "codegen/interpreter.jl" ||
                         (rel == "codegen/types.jl" && occursin("host_world = Base.get_world_counter()", line))) || (n += 1)
                    end
                end
            end
            # who asks the consult, in src/codegen and src/frontend: the collector and planner
            # (trimcollect.jl) and the vtable pre-pass's ambiguity search (compile.jl's
            # _compile_closed_world_plan, closures.jl's ambiguous_class_tuple); a statement's
            # codegen asks none; every other site counts
            local consult_rx = r"\b(wt_method_matches|wt_method_which|wt_dispatch_mi|wt_methods_ambiguous|_wt_matches_with_ambiguous|entry_method_instance)\("
            local allowed_callers = Set([("codegen/compile.jl", "_compile_closed_world_plan"),
                                         ("codegen/closures.jl", "ambiguous_class_tuple")])
            for root in (CODEGEN, joinpath(SRC, "frontend")), (dir, _, fs) in walkdir(root), f in fs
                endswith(f, ".jl") || continue
                local rel = replace(relpath(joinpath(dir, f), SRC), '\\' => '/')
                rel == "codegen/trimcollect.jl" && continue
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = d.captures[1])
                    (_iscomment(line) || d !== nothing) && continue
                    occursin(consult_rx, line) && !((rel, enclosing) in allowed_callers) && (n += 1)
                end
            end
            n += count_sites(r"\bmethod_error_args\b|\berror_args_types\b"; roots=[SRC])
            local calls = read(joinpath(CODEGEN, "calls.jl"), String)
            # each reads its callee's record, which the plan holds for every callee it can reach (a
            # missing one raises), never a default
            n += occursin("local tuples = DataType[T for T in ctx.translator.plan.no_method[Core.Typeof(f)]", calls) ? 0 : 1
            n += occursin("no_method=plan.no_method[_T])", read(joinpath(CODEGEN, "compile.jl"), String)) ? 0 : 1
            n += count_sites(r"get\([^)]*no_method"; roots=[SRC])
            # the behavior pin: a callable's MethodError arms are its own record's, read from the module
            # (an answer cannot tell a flat record apart: the rows come first)
            n += occursin("@test count(l -> strip(l) == \"struct.new \$me\", split(body, '\\n')) == length(rf) + length(rg)",
                          read(joinpath(ROOT, "test", "dispatch_method_error.jl"), String)) ? 0 : 1
            # one MethodError builder
            n += abs(count_sites(r"emit_struct_prefix!\([^,]+,\s*[^,]+,\s*MethodError\b"; roots=[SRC]) - 1)
            n += abs(count_sites(r"^function emit_method_error!\("; roots=[SRC]) - 1)
            n
        end),
    "L169_held_by_handle" => ("the module objects codegen defines once it holds by handle, never finds again, as dart's code generator keeps each GlobalBuilder, FunctionBuilder and Tag it defines as an object (translator.dart:96 Translator): the exception tag and the stack entry type its payload carries, `\$exc_top`, `\$host_imports_open`, `\$import_tops`, its array type and the import_tops save helper are the TypeRegistry's ModuleHandles (codegen's own state; the builder holds none), each defined at its first use or, for what a host framework's setup made before the compile (ensure_provenance_imports!, ensure_host_imports_open!), recovered once at the compile's entry by recover_module_handles!, a quarantined host-framework boundary (dev/MARCH.md 13.16). In text: no `global_named` anywhere in src or test; no find of a function or a global by its `.name ==` (the entry's refusal of a module already holding a global named `\$exc_top` or `\$import_tops`, in check_existing_module, aside), and no `exc_cell_type!` (the entry type found by its content through add_type!'s deduplication) in src/codegen; the entry type's StructType is written once, where ensure_exception_tag! defines the tag; no throw_! or catch_legacy! in codegen names a tag by a literal index; exc_tag and exc_cell_type read the handles; recover_module_handles! is called once, at compile_module's entry, and _imported_global (the boundary's find of an imported global by its import name) only by recover_module_handles!, ensure_host_imports_open!, _refuse_late_host_imports_open (the entry's and the setup's one refusal of a host-declared import without its count) and _refuse_imported_global. Its behavior: the name section names every named global (subsection 7, dart's NameSection, serialize/sections.dart:844), and test/probe_bytes.jl requires every global the probe's module object names (compile_module, then each global's `name`, never names read back from the section it checks) printed by wasm-tools as `(global \$<name>`, required here as written (dev/AUDIT.md A3B15 = A2B6, A4B4, A2E7; dev/CHARTER.md C7)",
        () -> begin
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local v = count_sites(r"\bglobal_named\b"; roots=[SRC, joinpath(ROOT, "test"), joinpath(ROOT, "ext")], exclude_files=["parity_ratchet.jl"])
            v += count_sites(r"\bexc_cell_type!"; roots=[CODEGEN])
            # a find of a function or a global by its name, outside the one boundary that refuses a
            # module already holding the compile's own global names (check_existing_module, at the entry)
            for (dir, _, fs) in walkdir(CODEGEN), f in fs
                endswith(f, ".jl") || continue
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = d.captures[1])
                    _iscomment(line) && continue
                    occursin(r"\.name\s*==(?!=)[^\n]*\b(?:functions|globals)\b", line) &&
                        enclosing != "check_existing_module" && (v += 1)
                end
            end
            v += abs(count_sites(r"StructType\(\[FieldType\(AnyRef, true\), FieldType\(ExternRef, false\)\]\)"; roots=[CODEGEN]) - 1)
            v += count_sites(r"\b(?:throw_|catch_legacy)!\([^,()]+,\s*\d+\s*\)"; roots=[CODEGEN])
            v += occursin("exc_tag(registry::TypeRegistry)::UInt32 = something(registry.handles.exc_tag)", gen) &&
                 occursin("exc_cell_type(registry::TypeRegistry)::UInt32 = something(registry.handles.exc_cell)", gen) ? 0 : 1
            v += abs(count_sites(r"\brecover_module_handles!\(type_registry, mod\)"; roots=[CODEGEN]) - 1)
            local finders = String[]
            for (dir, _, fs) in walkdir(SRC), f in fs
                endswith(f, ".jl") || continue
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = d.captures[1])
                    (_iscomment(line) || d !== nothing) && continue
                    occursin(r"(?<![\w])_imported_global\(", line) && push!(finders, enclosing)
                end
            end
            v += sort(unique(finders)) == ["_refuse_imported_global", "_refuse_late_host_imports_open", "ensure_host_imports_open!", "recover_module_handles!"] ? 0 : 1
            local probe = read(joinpath(ROOT, "test", "probe_bytes.jl"), String)
            for req in ("    count(g -> g.name !== nothing && !occursin(\"(global \\\$\" * g.name * \" \", printed), m.globals)",
                        "        m = WasmTarget.compile_module([(f, argtypes, name)])\n        bytes = WasmTarget.to_bytes(m)",
                        "        _unnamed_globals(m, printed) == 0 || push!(unnamed, name)",
                        "    if !isempty(unnamed)")
                occursin(req, probe) || (v += 1)
            end
            v
        end),
    "L172_dead_code_is_not_recorded" => ("an instruction added while the code is unreachable is not recorded, as dart's `_add` returns when `!_reachable` (instructions.dart:363-368), so the builder holds no dead code, which it does not type, and wasm-tools never meets an instruction the builder did not check: `_emit!` returns (through _check!, so a validation error still throws) before it records anything while `b.v.reachable` is false; unreachable!, _br_depth!, return_! and throw_! record their instruction before they make the code unreachable (dart's unreachable :676, br :863, return_ :933 and throw_ :820 call `_add` first), and end_block!, else_! and catch_legacy! record theirs after their validator restores the frame's entry reachability (end :842, else_ :767, catch_legacy :799), so a frame entered in dead code is dropped whole; append_builder! records no instruction of a fragment appended where its function's code is unreachable; nothing in src/builder sets `.reachable = false` before an `_emit!` on one line. dev/formal/OperandStack.tla's Sound (the program the builder records for one it accepts is valid) has its Broken instance MCOperandStackDeadCodeBroken (every instruction recorded). Its behavior, over src/builder alone: every row of test/builder_cases.jl's dead_cases holds (each program's builder holds exactly the instructions it wants: `unreachable; f64.const 0; i32.eqz; drop` holds `unreachable` alone), which test/module_builder_validation.jl's testset 'dead code is not recorded' also runs with wasm-tools (dev/AUDIT.md A15B1; dev/CHARTER.md C7)",
        () -> begin
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            local fbody(name) = (m = match(Regex("(?s)\\nfunction " * replace(name, "!" => "\\!") * "\\(.*?\\nend\\n"), ib); m === nothing ? "" : m.match)
            local v = 0
            local em = match(r"(?s)\n@inline function _emit!\(.*?\nend\n", ib)
            v += em !== nothing && occursin("    b.v.reachable || return _check!(b)\n    push!(b.instrs, instr)", em.match) ? 0 : 1
            v += occursin("unreachable!(b::InstrBuilder)::InstrBuilder = (_emit!(b, InstrIR.Unreachable()); b.v.reachable = false; b)", ib) ? 0 : 1
            v += occursin("    _emit!(b, InstrIR.Br(UInt32(depth)))\n    b.v.reachable = false", fbody("_br_depth!")) ? 0 : 1
            v += occursin("    _emit!(b, InstrIR.Return())\n    b.v.reachable = false", fbody("return_!")) ? 0 : 1
            v += occursin("    _emit!(b, InstrIR.Throw(UInt32(tag)))\n    b.v.reachable = false", fbody("throw_!")) ? 0 : 1
            local ab = fbody("append_builder!")
            local k1, k2 = findfirst("    lands || return _check!(dst)", ab), findfirst("push!(dst.instrs, ins)", ab)
            v += (k1 !== nothing && k2 !== nothing && first(k1) < first(k2) && occursin("    local lands = dst.v.reachable\n", ab)) ? 0 : 1
            v += count_sites(r"\.reachable\s*=\s*false\s*;\s*_emit!"; roots=[joinpath(SRC, "builder")])
            v += occursin("function validate_br!(", read(joinpath(SRC, "builder", "validator.jl"), String)) ? 1 : 0
            local formal = joinpath(ROOT, "dev", "formal")
            local cfg = joinpath(formal, "MCOperandStackDeadCodeBroken.cfg")
            v += isfile(cfg) && startswith(read(cfg, String), "\\* expect: Sound\n") ? 0 : 1
            v += occursin("Sound == done \\in BOOLEAN /\\ (WtAccepts(prog) => SpecAccepts(Emitted(prog)))", read(joinpath(formal, "OperandStack.tla"), String)) ? 0 : 1
            v + dead_rows_failing()
        end),
    "L173_one_local_declaration" => ("a local is declared through one path, as dart declares one only through addLocal (instructions.dart:382): declare_local! (src/builder/instr_builder.jl) checks its type against the module and appends it to the function's one locals list, returning its index; builder_add_local! and allocate_local!(ctx, ::WasmValType) are each that call, allocate_local!(ctx, ::Type) translates its type and calls the other, and src/builder pushes onto a locals list nowhere else; no codegen site pushes one itself (R41), and none computes a local's index beside it: a trampoline's or a dispatch wrapper's scratch is read by the index its declaration returned, never `1 + arity`, `dt.arity` or a default 0, a parameter (dev/AUDIT.md A16B4). Its behavior, over src/builder alone: test/builder_cases.jl's row c (a local of a type index the module does not define) rejects at its declaration (dev/AUDIT.md A15B2; dev/CHARTER.md C7)",
        () -> begin
            local ib = read(joinpath(SRC, "builder", "instr_builder.jl"), String)
            local cx = read(joinpath(CODEGEN, "context.jl"), String)
            local v = abs(count_sites(r"push!\(\s*[\w.]*locals\s*,"; roots=[joinpath(SRC, "builder")]) - 1)
            v += occursin("    typ isa ConcreteRef && _module_type(mod, typ.type_idx, :add_local)   # a type the module defines\n    push!(locals, typ)\n    return Int(nparams) + length(locals) - 1", ib) ? 0 : 1
            v += occursin("builder_add_local!(b::InstrBuilder, typ::WasmValType)::Int = declare_local!(b.v.mod, b.locals, length(b.params), typ)", ib) ? 0 : 1
            v += occursin("allocate_local!(ctx::AbstractCompilationContext, wasm_type::WasmValType)::Int =\n    declare_local!(ctx.mod, ctx.locals, ctx.n_params, wasm_type)", cx) ? 0 : 1
            v += occursin("allocate_local!(ctx::AbstractCompilationContext, T::Type)::Int =\n    allocate_local!(ctx, get_concrete_wasm_type(T, ctx.mod, ctx.type_registry; for_local=true))", cx) ? 0 : 1
            # a local's index computed beside the declaration path (A16B4)
            v += count_sites(r"UInt32\(1 \+ arity\)|UInt32\(Int\(dt\.arity\)\)|entry\.return_type, dt\.arity\)|get\(scratch_of, [^)]*, UInt32\(0\)\)"; roots=[CODEGEN])
            v + builder_rows_failing(["c"])
        end),
    "L174_one_value_type_reader" => ("an operand's Julia type has one reader, value_type (context.jl), Julia's argextype widened (Compiler optimize.jl:423 on 1.12.7, :502 on 1.13.1): an SSA value's statement type (ctx.ssa_types, the boundary's type plus the plan's joins), a slot's type, a literal's Core.Typeof, a global's type the boundary read; collection and codegen both read it, as dart's dartTypeOf answers every node (code_generator.dart:129). Exactly its two methods (the rule over (slot types, SSA types) and the context's form) are defined; no other reader exists in src (get_ssa_type, infer_value_type, _value_julia_type, _call_site_arg_type, _collector_static_type, source_slot_type, the box analyses' _f3_ssa_type and _f3_literal_type), and no site reads `ssa_types` keyed by an operand node's `.id` or indexes a slot table outside value_type and the NIR boundary (a statement's own type, keyed by its statement index, is no operand read; a physical `ctx.arg_types` entry is the wasm signature's parameter, not an operand's Julia type); the joins codegen applies are the plan's (numeric_local_joins reads plan_joins), and the box analyses (propagate_numeric_value_types, capture_read_types, record_capture_contents, f3_box_value_types, box_contents_type) run nowhere outside box_capture.jl and trimcollect.jl's collector. Its behavior: test/ir_one_inference_path.jl compares value_type with Compiler's argextype for every call operand of every planned body of a program (dev/AUDIT.md A3C1, A3C4; dev/CHARTER.md C1)",
        () -> begin
            local cx = read(joinpath(CODEGEN, "context.jl"), String)
            local v = abs(count_sites(r"^function value_type\(|^value_type\(ctx::AbstractCompilationContext"; roots=[SRC]) - 2)
            v += occursin("function value_type(node::NirNode, slot_types::Union{Nothing,AbstractVector}, ssa_types)::Type", cx) ? 0 : 1
            v += occursin("value_type(ctx::AbstractCompilationContext, node::NirNode)::Type =\n    value_type(node, ctx.slot_types, ctx.ssa_types)", cx) ? 0 : 1
            v += count_sites(r"\b(get_ssa_type|infer_value_type|_value_julia_type|_call_site_arg_type|_collector_static_type|source_slot_type|_f3_ssa_type|_f3_literal_type)\b"; roots=[SRC])
            # an operand's type read past the reader: ssa_types keyed by an operand node's id (a
            # statement's own type, keyed by its index, is no operand read) or a slot table indexed,
            # outside value_type's own lines and the boundary (frontend/nir.jl)
            v += count_sites(r"ssa_types(\[|,\s*)[A-Za-z_][\w.]*(\[\d+\])?\.id\b|(?<!dt\.)\bslot_types\[";
                             roots=[SRC], exclude_files=["frontend/nir.jl"],
                             exclude_line=r"return ssa_types === nothing \? node\.julia_type|^\s*return slot_types\[n\]$")
            v += occursin("numeric_local_joins(ctx::AbstractCompilationContext)::Dict{Int,Type} =\n    ctx.mi === nothing ? Dict{Int,Type}() : plan_joins(ctx.translator.plan, ctx.mi)", cx) ? 0 : 1
            v += count_sites(r"(?<![\w.])(propagate_numeric_value_types|capture_read_types|record_capture_contents|f3_box_value_types|box_contents_type)\(";
                             roots=[SRC], exclude_files=["codegen/box_capture.jl", "codegen/trimcollect.jl"],
                             exclude_line=r"^\s*#|^\s{4}\w+\(.*\) ->")
            local oip = read(joinpath(ROOT, "test", "ir_one_inference_path.jl"), String)
            v += occursin("@testset \"value_type is Julia's argextype\"", oip) ? 0 : 1
            v
        end),
    "L175_globalref_resolved_once" => ("a global's binding is resolved once, at the NIR boundary (resolve_operand, frontend/nir.jl), as dart's StaticGet carries its resolved target (expressions.dart:1363, read by visitStaticGet, code_generator.dart:2183): NirGlobalRef carries `bound`, `value`, `constant` (isconst) and `julia_type` (abstract_eval_globalref_type's answer), resolve_call_callee and _resolve_type_operand read that one resolution, and no `isdefined(`, `isconst(`, `getglobal(`, `getfield(`, `eval(` (Core.eval), `get_binding_type(` or `isdefinedglobal(` over a `.mod, .name` pair appears outside frontend/nir.jl (isa's type operand reads the boundary's `value`, a global that is no constant rejecting at its statement). (The getglobal builtin's constant fold, builtins.jl, asks of a constant module and a literal name, the intrinsic's own operands, not of a NirGlobalRef.) Its behavior: value_type's argextype comparison covers every global operand (L174's test) (dev/AUDIT.md 13.4; dev/CHARTER.md C1)",
        () -> begin
            local nir = read(joinpath(SRC, "frontend", "nir.jl"), String)
            local v = count_sites(r"\b(isdefined|isconst|getglobal|getfield|eval|get_binding_type|isdefinedglobal)\(\s*[\w.\[\]]+\.mod\s*,\s*[\w.\[\]]+\.name\b";
                                  roots=[SRC], exclude_files=["frontend/nir.jl"])
            v += occursin("    bound::Bool\n    constant::Bool\n    julia_type::Type\nend", nir) ? 0 : 1
            v += count(r"resolve_operand\(x, (types|Type\[\])\)::NirGlobalRef", nir) == 1 ? 0 : 1   # _resolve_type_operand's
            v += occursin("resolve_call_callee(x, types)::Any = nir_callee(resolve_operand(x, types))", nir) ? 0 : 1
            v += count(r"isdefined\(x\.mod, x\.name\)", nir) == 1 ? 0 : 1
            v
        end),
    "L176_one_class_set" => ("the classes a value of the closed world may have are one set, computed by one function, closed_world_classes (trimcollect.jl), once per round of the collection's fixpoint over the world collected so far, the last round's carried by the ClosedWorld and the plan (`classes`), as dart's ClassInfoCollector numbers one class list whose allocated classes every selector's targets range over (class_info.dart:666, dispatch_table.dart:501): the enrollment (runtime_types and the candidates, class_candidates), the union-split MethodError tuples (_collect_reachable_ir_types over closed_world_class_list), the vtable pre-pass's ambiguity search (ambiguous_class_tuple over class_candidates, never the numbered classes) read it, and the numbering numbers every class of it (_collect_reachable_ir_types reg!s each); a constant's contents are walked once, by hold!, the class of every value reached observed whatever it is, its one bound a loud rejection past 10^6 own objects, and no second contents walk exists (contents!, whose silent stop at 4096 objects was A13C10, is gone); one statement rule observes the class of every statement whose inferred type is concrete (whatever makes it: a builtin, an intrinsic, a foreign call, an invoke of a declared import), one statement_operands rule says a callee is no evidence of a class (A4C4), and every value a statement carries is observed by the numbering's own rule of what a statement carries, _collected_operand_value (a literal, its value unresolved, a quoted GlobalRef the GlobalRef object, as Julia's jl_quotenode_value; a bound global's value, constant or not; a statement that is a value), everything it holds walked by hold!, and a vararg method's packed tuple, a value no statement makes, is observed from the body's slot (dev/formal/Enrollment.tla SlotsObserved). Its behavior: smoke's closure_ambiguity_numbered_unreached_class (a class a field's type numbers and no value has: asked about over the numbered classes it rejected a program Julia runs, native 3) and closure_union_nothing_erased (the constant `nothing` a statement passes, a value the candidate set missed: a trap where native answers 1) (dev/AUDIT.md A7C4, A3S3, A11C7; dev/formal/Enrollment.tla AskNumbered; dev/CHARTER.md C1)",
        () -> begin
            local trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            local comp = read(joinpath(CODEGEN, "compile.jl"), String)
            local clo = read(joinpath(CODEGEN, "closures.jl"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local v = 0
            # one function computes the set, called once (the fixpoint's round)
            v += abs(count_sites(r"\bclosed_world_classes\("; roots=[SRC], exclude_line=r"^function closed_world_classes\(|^\s*closed_world_classes\(codeinfos, entry_mis, nir_for\) ->") - 1)
            v += count("runtime_types = Set{DataType}()", trim) == 1 ? 0 : 1
            # its readers
            for (src, needle) in ((trim, "local runtime_types = classes.runtime"),
                                  (trim, "local observed_classes = class_candidates(classes)"),
                                  (trim, "for (p, S, rt) in error_args, C in closed_world_class_list(classes)"),
                                  (trim, "    for C in closed_world_class_list(classes)\n        C in LOWERING_INSTANTIATED_CLASSES || reg!(C)\n    end"),
                                  (trim, "            local made = CC.widenconst(s0.julia_type)\n            (made isa DataType && isconcretetype(made)) && observe_type!(made)\n"),
                                  (trim, "    holds_exceptions && foreach(observe_type!, LOWERING_INSTANTIATED_CLASSES)\n"),
                                  (comp, "    for _exn_T in LOWERING_INSTANTIATED_CLASSES\n"),
                                  (comp, "_reachable = _collect_reachable_ir_types(function_data, plan.bespoke, plan.classes)"),
                                  (comp, "local _amb = ambiguous_class_tuple(_T, _ov, plan.classes)"),
                                  (clo, "local candidates = class_candidates(classes)"),
                                  (trim, "        local has, v = _collected_operand_value(node)\n        (has && !(v isa Expr)) || return\n        hold!(v)"),
                                  (trim, "(node0 isa NirLiteral || node0 isa NirGlobalRef) && observe_runtime_operand!(node0)"),
                                  # a literal is its value, unresolved (A16C5); a packed vararg tuple observed from its slot (A16C2)
                                  (trim, "    operand isa NirLiteral && return (true, operand.value)\n"),
                                  (trim, "        if mi_j.def isa Method && mi_j.def.isva\n"),
                                  (trim, "(node isa NirCall || node isa NirInvoke || node isa NirNew || node isa NirForeignCall) &&\n            return node.operands"),
                                  (smoke, "(\"closure_ambiguity_numbered_unreached_class\""),
                                  (smoke, "(\"closure_union_nothing_erased\""),
                                  (read(joinpath(ROOT, "test", "dispatch_method_error.jl"), String),
                                   "@testset \"a constant's contents are classes of the one set\" begin"),
                                  (read(joinpath(ROOT, "test", "dispatch_method_error.jl"), String),
                                   "@testset \"the classes lowering instantiates are in the one class set\" begin"),
                                  (smoke, "(\"caught_methoderror_union_split\""),
                                  (read(joinpath(ROOT, "test", "host_imports.jl"), String),
                                   "@testset \"an import's result is a class of the one class set\" begin"),
                                  (trim, "            observe_type!(typeof(v))\n            (isbits(v) || v isa Module) && continue"))
                v += occursin(needle, src) ? 0 : 1
            end
            # no reader iterates another class source: not the numbered classes, not the numbering's own set
            v += occursin("registry.type_ids", clo) ? 1 : 0
            v += occursin("local classes = collect(out)", trim) ? 1 : 0
            # one walk of what a constant holds (hold!): no second contents walk for the numbering
            v += count_sites(r"\bcontents!\("; roots=[SRC])
            v += occursin("held::Set{DataType},", trim * clo * comp) ? 1 : 0   # a reader handed another set
            v += occursin("held::Set{DataType})", trim * clo * comp) ? 1 : 0
            v
        end),
    "L177_one_match_rule" => ("one definition decides whether a match of Julia's is one signature, the MethodInstance a call at its types runs, _match_is_one_signature (trimcollect.jl): its intersection is one DataType and every static parameter it leaves a TypeVar is mentioned only where the argument is one value's dispatch type (a concrete class that is not a kind, or a Type{X}): a TypeVar left there Julia leaves at run time too (`h(x::Union{T,Nothing}) where T` at Nothing), one left at an abstract argument or a kind it fixes per value. The static signature's match, each candidate tuple's and each per-class candidate's (the dynamic call of a function) call it, and no other test of a match's spec_types or sparams exists in src. Its behavior: smoke's closure_type_parameter_at_kind (a match at the kind DataType facing Type{S} built a body whose static parameter rejected, native 8) and closure_union_nothing_erased (dev/AUDIT.md A9C6; dev/formal/Enrollment.tla NoTypeVarCheck; dev/CHARTER.md C1)",
        () -> begin
            local trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local v = abs(count_sites(r"spec_types isa"; roots=[SRC]) - 1)
            v += abs(count_sites(r"sparams[^\n]*isa TypeVar|isa TypeVar[^\n]*sparams"; roots=[SRC]) - 1)
            v += count("function _match_is_one_signature(m::Core.MethodMatch)::Bool", trim) == 1 ? 0 : 1
            v += occursin("if _match_is_one_signature(mm)", trim) ? 0 : 1
            v += occursin("(cm.method === mm.method && _match_is_one_signature(cm)) || continue", trim) ? 0 : 1
            v += count("(ssig <: m.sig && _match_is_one_signature(selected)) || continue", trim) == 2 ? 0 : 1
            v += occursin("(\"closure_type_parameter_at_kind\"", smoke) ? 0 : 1
            v
        end),
    "L178_one_conversion" => ("a value meets a sink through one conversion, convert_type! (dart's convertType, translator.dart:1597), typed by the source value's own static type, never the sink's: the runtime-length tuple's widening check is the funnel's alone (no statement check beside it, no _erased_vararg_tuple_operand), and it and a closure context's erasure read the value's class through one rule, source_class (a concrete source type; an abstract one, as a sink's type a caller gave, names none and rejects); the heterogeneous tuple read converts each field through the funnel (no box, extern bridge or null of its own; a function's singleton, a classed object already, is held as it is, as before, A7S1's open representation), as does memoryrefset!'s element (no ladder of numeric boxes, closure wraps and extern bridges); no hand box: every numeric box is built or read by emit_classid_box!/emit_classid_unbox! (get_numeric_box_type! named only in values.jl's two, types.jl and compile.jl's pre-registration), and the numeric-to-anyref/externref helpers are gone; no caller passes a Memory's element type or a field's type as from_julia; `nothing` meeting any nullable reference of the any hierarchy (a nullable single representation, anyref, eqref, structref) is its null in the funnel, never boxed, a nothing held in a reference is never unboxed or cast (its placeholder, boxed for a non-null reference, NothingNeverCast; a closure entry's Nothing argument the same), and isa(x, Nothing) of a value of any class reads the one nothing test `===` reads (_emit_is_nothing!). Behavior: test/diagnostic_attribution.jl's 'the one widening check rejects a source type that names no class' testset (the representation into anyref with from_julia Any, a union, its own type or none: each a located rejection) and its 'nothing at every nullable reference of the any hierarchy is its null' testset (which fails with the funnel's nothing arm limited to a nullable concrete sink, as it was), smoke heterogeneous_tuple_read's nothing_isa (a nothing boxed at anyref and read by ref.is_null: native 1, wasm 2 at baae2757), and smoke runtime_length_tuple_class's into_any_field and erased_isa_ntuple reject loud (the second, through a Memory{Any} store, answered wrong with the statement check off before memoryrefset! converted through the funnel); the regression cases runtime_length_tuple's into_union_field and heterogeneous_tuple_read's other five fields answered as native before the funnel's fix too (dev/AUDIT.md A7E4, A6E4, A11E7, A16E2, A16P5; dev/formal/Coercion.tla NoUnclassedWidening, NothingIsNull; dev/CHARTER.md C1)",
        () -> begin
            local vals = read(joinpath(CODEGEN, "values.jl"), String)
            local blt = read(joinpath(CODEGEN, "builtins.jl"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local v = count_sites(r"_erased_vararg_tuple_operand")
            v += abs(count_sites(r"source_class\(from_julia\) === nothing") - 2)
            v += occursin("source_class(@nospecialize(from_julia))::Union{DataType, Nothing} =", vals) ? 0 : 1
            v += count_sites(r"emit_numeric_to_anyref!|emit_numeric_to_externref!")
            v += count("coerce_stack_top!(_hetb, union_wasm, ctx; from_julia=T)", blt) == 1 ? 0 : 1
            v += count_sites(r"emit_classid_box!\(_hetb|any_convert_extern!\(_hetb|ref_null!\(_hetb|maybe_wrap_closure!\(_msb|any_convert_extern!\(_msb|extern_convert_any!\(_msb")
            v += occursin("coerce_stack_top!(_msb, wasm_elem_type, ctx; from_julia=mset_val_T)", blt) ? 0 : 1
            v += count_sites(r"get_numeric_box_type!\("; exclude_files=["codegen/values.jl", "codegen/types.jl", "codegen/compile.jl"])
            v += abs(count(r"get_numeric_box_type!\(", vals) - 2)
            v += count_sites(r"from_julia=elem_type\b|from_julia=\(julia_field")
            v += occursin("if from_julia === Nothing && from != to && _wt_is_ref(to) && _wt_ref_nullable(to) &&\n       _wt_hierarchy_top(_wt_heap_kind(to, _mod.types)) === :any &&", vals) ? 0 : 1
            # isa(x, Nothing) of a value of any class reads the one nothing test `===` reads
            v += occursin("            _emit_is_nothing!(bld, ctx.type_registry, _isa_l)\n", read(joinpath(CODEGEN, "calls.jl"), String)) ? 0 : 1
            for c in ("(\"into_any_field\"", "(\"erased_isa_ntuple\"", "(\"into_union_field\"", "_g(\"heterogeneous_tuple_read\"", "(\"nothing_isa\"")
                v += occursin(c, smoke) ? 0 : 1
            end
            local diag = read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            v += occursin("the funnel: nothing at every nullable reference of the any hierarchy is its null", diag) ? 0 : 1
            v += occursin("    if from_julia === Nothing && _wt_is_ref(from) && from != to &&\n       (!_wt_is_ref(to) || (!_wt_ref_nullable(to) &&", vals) ? 0 : 1
            v += occursin("the one widening check rejects a source type that names no class", diag) &&
                 occursin("for src in (Any, Union{Nothing,Tuple{Vararg{Int64}}}, Tuple{Vararg{Int64}}, nothing)", diag) ? 0 : 1
            v
        end),
    "L179_one_type_test" => ("each type test has one lowering: one TypeError builder, _emit_typeerror_throw! (its three constant fields typed by their values, the value that failed pushed by its caller), which a typeassert's always-failing arm, its as-checker's body (as_checker!, L183) and the UnionAll constructor call, as dart's as-checker throws one TypeError (types.dart:763 generateAsChecker), and the only `register_struct_type!(…TypeError)` in codegen; one `Type{X}` element rule, type_element_kind (X's kind, as jl_f_tuple types the element), read by tuple_runtime_type, a tuple type's registration (_canonical_tuple_type), a MethodError's args tuple and a type-object argument's canonical signature (_canonical_type_object_arg); the type-object test partitions the bare arrays and the kinds over the value's static type, as every class read does (bare_array_partition), never over every class; and a phi edge's class test is the one class test, emit_isa_class_header! (it reads the header's classId, code_generator.dart:6076 loadClassId), the box-layout test beside it deleted. Behavior: test/dispatch_method_error.jl's 'one Type{X} element rule: the tuple Core.tuple builds is the tuple type registered' (a second rule in either reader, every type object a DataType, fails it for Vector, a Union and Union{}); the regression cases smoke tuple_type_element, kind_isa's kind_partition_static_type, union_nothing (the phi edges whose class flow.jl tests), typeassert_checks and test/real_bottom_exceptions.jl's TypeError fields (L57) answered as native before the lock's fixes too, which were restructurings (dev/AUDIT.md A4E5, A5E5, A5E8, A9E6, A16P5, A16P6; dev/CHARTER.md C1)",
        () -> begin
            local calls = read(joinpath(CODEGEN, "calls.jl"), String)
            local flow = read(joinpath(CODEGEN, "flow.jl"), String)
            local structs = read(joinpath(CODEGEN, "structs.jl"), String)
            local trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            local smoke = read(joinpath(ROOT, "test", "smoke.jl"), String)
            local v = abs(count_sites(r"register_struct_type!\([^)]*TypeError\)"; roots=[CODEGEN]) - 1)
            v += abs(count_sites(r"_emit_typeerror_throw!\(") - 5)   # its definition, docstring and three callers
            v += count("type_element_kind(@nospecialize(P))::Union{Nothing, Type} =", trim) == 1 ? 0 : 1
            v += occursin("Any[something(type_element_kind(P), P) for P in T.parameters]", structs) ? 0 : 1
            v += occursin("local K = type_element_kind(T)", trim) ? 0 : 1
            v += occursin("Any[something(type_element_kind(C), C) for C in cs]", trim) ? 0 : 1
            v += occursin("local runtime_class = type_element_kind(T)", trim) ? 0 : 1
            v += count_sites(r"Type\.body\.name\) \? (typeof\(|P\.parameters\[1\])")
            v += abs(count("check_type, val_jt)", calls) - 3)
            v += occursin("bare_array_partition(ctx.mod, reg, nothing)", calls) ? 1 : 0
            v += occursin("if K <: T && typeintersect(K, static_type) !== Union{}]", calls) ? 0 : 1
            v += count_sites(r"emit_isa_classid!")
            v += occursin("emit_isa_class_header!(b, ctx, phi_julia)", flow) ? 0 : 1
            for c in ("_g(\"tuple_type_element\"", "(\"kind_partition_static_type\"", "_g(\"union_nothing\"", "_g(\"typeassert_checks\"")
                v += occursin(c, smoke) ? 0 : 1
            end
            v += occursin("@testset \"one Type{X} element rule: the tuple Core.tuple builds is the tuple type registered\" begin",
                          read(joinpath(ROOT, "test", "dispatch_method_error.jl"), String)) ? 0 : 1
            v
        end),
    "L180_one_table_per_construct" => ("each lowering reads one table: one operator table, INTRINSIC_BINOPS (dart's `_binaryOperatorMap`, intrinsics.dart:437, its lookup :995), which the surface `+ - *` lowering and the `_apply_iterate` reduce reach through operator_intrinsic (the intrinsic Julia's own method runs, base/int.jl:86-88 and base/float.jl:495-497 on 1.12.7, :85-87 and :492-494 on 1.13.1; no `_OPERATOR_OPCODES`, no `_get_binary_reduce_opcode`), and one conversion table, INTRINSIC_CONVERSIONS, whose bitcast every reinterpretation reads (emit_bitcast!: no `*_REINTERPRET_*` opcode outside julia_numeric_tier.jl); one width rule, julia_to_wasm_type for a value's register (dart's translateType, translator.dart:1044; numeric_register, and exact_register for a register that holds exactly its value) and `_julia_int_width` for a BitInteger's bits, which every width decision in codegen reads (a 128-bit integer is `_julia_int_width(T, false) == 128`, a float register `numeric_register(T) in (F32, F64)`): no list of two or more numeric types (8- to 128-bit integers, Float16/32/64, Bool, Char) deciding a width, as an `||` chain, an `in (…)` tuple, an `isa Union{…}` or `<: Union{…}`, or a table of `=>` pairs, but the lines of one exact allowlist, each with its reason: the rule's own body, packed_array_storage (the packed storage rule), translate_external_type (the numbers the JS boundary carries unboxed), assign_type_ids!'s fixed primitive classes (which classes are numbered), `_struct_fields!` (13.4's one struct-field translation, 116f), the constant encoders (values.jl's, `_const_init!`'s: each constant's bits, as dart's constant visitors encode each class), the getfield constant fold's constant kinds (calls.jl), calls.jl's one-byte pointer-element tests (a byte layout) and the statement-value trace's own table (generate.jl); and one widening rule: a source narrower than 32 bits is normalised before it widens into a target of any register, signed for sext_int and sitofp, unsigned for zext_int and uitofp; every conversion's target is resolved once from its operand (a literal type, or a constant global's value), an unresolved one rejecting at its statement, never a default register; one operand table, `_nir_any_operand`, which count_ssa_uses! and the local allocation's second pass read (an upsilon's value is a use), and the use index (ssa_users) answers every whole-body use scan; and one loop-bounds definition, loop_bounds (a loop's header and its last back edge), which the local allocation and the branching-loop index read (no loop-header bitmap, no first-goto table). Behavior: test/m11_intrinsics_table.jl's 'operator_intrinsic is the intrinsic Julia's method runs' (for every admitted operator and type, the one intrinsic in Julia's typed body; an intrinsic callee only for its own kind, so smoke's xfail reduce_intrinsic_kind rejects where it added floats), test/nir_use_index.jl's 'the use count and the loop bounds read one table each' (count_ssa_uses! equals the one table's count on a body with an upsilon carrying an SSA value; a loop entered by a forward goto keeps its last back edge), smoke narrow_widening (a dirty Int8 widened to Int32 answered 200, native -56, and a UInt8 sign-extended answered 128, native -128, at baae2757), conversion_target (sitofp to a Float32 named by a GlobalRef rounded twice), int128_extends (a narrow source normalised before it widens into Int128: sext_int(Int128, 0x80) raised a StackImbalanceError and a dirty Int8 answered 200 on the base acc1ac87) and pointer_float_bytes (a StackImbalanceError on that base), each failing with its fix reverted; dispatch_slot_registers' int8_slot and enum_slot are regression cases that answered as native before the width rule too (a Float16 rejects at its statement, xfail dispatch_slot_float16) (dev/AUDIT.md the first audit's side notes, A16B1 = A16E1, A16E3, A16P1, A16P2, A16P5; 13.4; dev/CHARTER.md C1)",
        () -> begin
            local blt = read(joinpath(CODEGEN, "builtins.jl"), String)
            local calls = read(joinpath(CODEGEN, "calls.jl"), String)
            local ctxs = read(joinpath(CODEGEN, "context.jl"), String)
            local stm = read(joinpath(CODEGEN, "statements.jl"), String)
            local v = count_sites(r"_OPERATOR_OPCODES|_get_binary_reduce_opcode")
            v += count("function operator_intrinsic(", blt) == 1 ? 0 : 1
            # an intrinsic callee over its own kind only
            v += occursin("f === g && return int ? sym : nothing", blt) && occursin("f === g && return flt ? sym : nothing", blt) ? 0 : 1
            v += occursin("emit_intrinsic_binop!(fb, wt, wt, op, ctx, _julia_int_width(T, wt === I32))", blt) ? 0 : 1
            v += occursin("emit_intrinsic_binop!(bld, elem_wasm_type, elem_wasm_type, reduce_op, ctx,", calls) ? 0 : 1
            v += count_sites(r"REINTERPRET_"; roots=[CODEGEN], exclude_files=["codegen/julia_numeric_tier.jl"])
            # one widening rule, and every conversion target resolved once (no default register)
            local jnt = read(joinpath(CODEGEN, "julia_numeric_tier.jl"), String)
            # (each op normalises its source before any register's target, the I64 extension or none)
            for needle in ("        normalise_narrow!(b, ctx, julia_src, true)   # the one widening rule: its sign at its width\n        dst_reg === I64 && return table!(I32, I64, :sext_int)\n        return dst_reg",
                           "        normalise_narrow!(b, ctx, julia_src, false)   # the one widening rule: its bits\n        dst_reg === I64 && return table!(I32, I64, :zext_int)\n        return dst_reg",
                           "        normalise_narrow!(b, ctx, julia_src, true)    # the one widening rule: its sign at its width\n        return table!(src_reg, dst_reg, :sitofp)",
                           "        normalise_narrow!(b, ctx, julia_src, false)   # the one widening rule: its bits\n        return table!(src_reg, dst_reg, :uitofp)")
                v += occursin(needle, jnt) ? 0 : 1
            end
            v += occursin(r"reg\(T, default\)|_resolve_bitcast_target|something\(dst_reg, I32\)", jnt) ? 1 : 0
            v += occursin("    (op in (:sext_int, :zext_int, :trunc_int) && !dst_128 && !(dst_reg === I32 || dst_reg === I64)) &&\n        return reject!(\"its target is held in no integer register\")", jnt) ? 0 : 1
            v += occursin("(_cv_target_ref.bound && _cv_target_ref.constant ? _cv_target_ref.value : nothing) : _cv_target_ref", calls) ? 0 : 1
            # the width rule: a list of numeric types deciding a width (an `||` chain over 8- to
            # 128-bit integers or floats, an `in (…)` tuple, an `isa Union{…}` or `<: Union{…}`, a
            # table of `=>` pairs) is a line of the exact allowlist, each with its reason; any other
            # such line, or an entry no line uses, fires
            local num = raw"\b(U?Int(8|16|32|64|128)|Float(16|32|64)|Bool|Char)\b"
            local wrx = Regex(raw"=== U?Int(8|16|32|64|128)\b[^\n]*\|\||\|\|[^\n]*=== U?Int(8|16|32|64|128)\b|isa U?Int(8|16|32|64|128) \|\|" *
                              raw"|=== Float(16|32|64)\b[^\n]*(\?|\|\|)|\|\|[^\n]*=== Float(16|32|64)\b|isa Float(16|32|64) \|\|" *
                              raw"|\bin \((?:[^()]*?" * num * raw"){2}|(\bisa|<:) Union\{(?:[^{}]*?" * num * raw"){2}|" *
                              num * raw"\s*=>[^\n]*" * num * raw"\s*=>")
            local rule = "the width rule's own body, julia_to_wasm_type (translator.dart:1044 translateType)"
            local packed = "packed_array_storage, the packed storage rule (translator.dart:344 builtinTypes' WasmI8/WasmI16)"
            local external = "translate_external_type: the numbers the JS boundary carries unboxed (translator.dart:1113 translateExternalType)"
            local numbered = "assign_type_ids!'s fixed primitive classes, which classes are numbered (class_info.dart:864 ClassIdNumbering._number)"
            local fields = "_struct_fields!'s field translation, 13.4's one struct-field translation (116f)"
            local encode = "a constant encoder: each constant's bits by its class (constants.dart:622 visitIntConstant)"
            local fold = "the getfield constant fold's constant kinds, the values it folds (calls.jl)"
            local bytes = "a one-byte pointer-element test, a byte layout (pointer.jl's unsafe_load of a UInt8 or Int8)"
            local trace = "the statement-value trace's own table, the types a traced compile reports (parity(quarantine) on TRACED_STATEMENT_TYPES)"
            local allow = Tuple{String,String,String}[
                ("codegen/types.jl", "if T === Int32 || T === UInt32", rule),
                ("codegen/types.jl", "elseif T === Int64 || T === UInt64 || T === Int", rule),
                ("codegen/types.jl", "elseif T === UInt8 || T === Int8 || T === UInt16 || T === Int16", rule),
                ("codegen/types.jl", "elseif T === Int128 || T === UInt128", rule),
                ("codegen/types.jl", "elseif fv isa Int8 || fv isa Int16 || fv isa Int32", encode),
                ("codegen/types.jl", "elseif fv isa UInt8 || fv isa UInt16 || fv isa UInt32", encode),
                ("codegen/types.jl", "for T in (Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,", numbered),
                ("codegen/types.jl", "T === Int8 || T === UInt8 ? I8 :", packed),
                ("codegen/types.jl", "T === Int16 || T === UInt16 ? I16 : nothing", packed),
                ("codegen/types.jl", "T === Int8 || T === UInt8 || T === Int16 || T === UInt16 ||", external),
                ("codegen/types.jl", "T === Int32 || T === UInt32 || T === Int64 || T === UInt64 || T === Int ||", external),
                ("codegen/types.jl", "T === Float32 || T === Float64)", external),
                ("codegen/structs.jl", "elseif ft === Int32 || ft === UInt32 || ft === Bool || ft === Char ||", fields),
                ("codegen/structs.jl", "ft === Int8 || ft === UInt8 || ft === Int16 || ft === UInt16", fields),
                ("codegen/structs.jl", "elseif ft === Int64 || ft === UInt64 || ft === Int", fields),
                ("codegen/values.jl", "elseif lit isa Int128 || lit isa UInt128", encode),
                ("codegen/values.jl", "elseif val isa Int8 || val isa UInt8 || val isa Int16 || val isa UInt16", encode),
                ("codegen/values.jl", "elseif val isa Int64 || val isa Int", encode),
                ("codegen/values.jl", "elseif val isa Int128 || val isa UInt128", encode),
                ("codegen/calls.jl", "if _pr_vec !== nothing && (_pr_tp0 === UInt8 || _pr_tp0 === Int8 || _pr_tp0 === Nothing || _pr_tp0 === nothing)", bytes),
                ("codegen/calls.jl", "local _prb_vec = (ptr_arg !== nothing && (_prb_tp === UInt8 || _prb_tp === Int8)) ?", bytes),
                ("codegen/calls.jl", "if _ps_vec !== nothing && (_ps_vt === UInt8 || _ps_vt === Int8)", bytes),
                ("codegen/calls.jl", "if _psw_te === UInt8 || _psw_te === Int8", bytes),
                ("codegen/calls.jl", "if _gfc_val isa Union{Integer, Bool, Char, Float32, Float64, String, Symbol} &&", fold),
                ("codegen/calls.jl", "!(_gfc_val isa Union{Int128, UInt128, BigInt})", fold),
                ("codegen/generate.jl", "const TRACED_STATEMENT_TYPES = Dict{Type,WasmValType}(Int64 => I64, UInt64 => I64, Int32 => I32,", trace),
                ("codegen/generate.jl", "Bool => I32, Float32 => F32, Float64 => F64)", trace)]
            local unused = copy(allow)
            for (dir, _, files) in walkdir(CODEGEN), f in sort(files)
                endswith(f, ".jl") || continue
                local rel = "codegen/" * relpath(joinpath(dir, f), CODEGEN)
                for l in eachline(joinpath(dir, f))
                    (!_iscomment(l) && occursin(wrx, l)) || continue
                    local k = findfirst(e -> e[1] == rel && e[2] == strip(l), unused)
                    k === nothing ? (v += 1) : deleteat!(unused, k)
                end
            end
            v += length(unused)
            v += occursin("    _count(rec.node)\n    _nir_any_operand(_count, rec.node)", ctxs) ? 0 : 1
            v += occursin("_nir_any_operand(x -> (x isa NirSSA && push!(needs_local_set, x.id); false), node)", ctxs) ? 0 : 1
            v += count_sites(r"for use_rec in nir\b|any\(nir\) do|for \(phic_idx, phic_rec\) in enumerate")
            v += occursin(r"loop_headers|first_goto_to", ctxs) ? 1 : 0   # (the stackifier's own, block-level loops are 116d-3's one CFG)
            v += occursin("for phic_idx in ssa_users(ctx, idx)", stm) && occursin("for j in ssa_users(ctx, idx)   # the statements that use the new object", stm) ? 0 : 1
            v += count("function loop_bounds(cfg::NirCFG)", ctxs) == 1 ? 0 : 1
            local m11 = read(joinpath(ROOT, "test", "m11_intrinsics_table.jl"), String)
            v += occursin("operator_intrinsic is the intrinsic Julia's method runs", m11) ? 0 : 1
            local smk = read(joinpath(ROOT, "test", "smoke.jl"), String)
            for c in ("_g(\"int128_extends\"", "_g(\"pointer_float_bytes\"", "_g(\"dispatch_slot_registers\"", "_xf(\"reduce_intrinsic_kind\"", "_xf(\"dispatch_slot_float16\"",
                      "_g(\"narrow_widening\"", "_g(\"conversion_target\"")
                v += occursin(c, smk) ? 0 : 1
            end
            local nui = read(joinpath(ROOT, "test", "nir_use_index.jl"), String)
            v += occursin("the use count and the loop bounds read one table each", nui) &&
                 occursin("@test WasmTarget.loop_bounds(WasmTarget.nir_cfg(synth)) == [(3, 6)]", nui) ? 0 : 1
            v
        end),
    "L181_one_cfg" => ("a body's control-flow graph is one, Julia's own: nir_cfg (frontend/nir.jl), a port of Compiler's basic_blocks_starts and compute_basic_blocks (Compiler/src/ssair/ir.jl:46, :93; an Enter starts and ends a block, its catch destination a successor; a :leave ends one), built once per compiled body (the context's `cfg`) and read by generate_body, the stackifier (its blocks, successors and predecessors, the boundscheck fold the only edit; no region split, no handler edges of its own), the trampoline threading (nir_cfg of each round's rewritten statements), the proven-dead proof (the context's CFG; its reachability sees a handler through its catch edge, so a body with a try is no longer excluded), the definite-initialization proof (its statement successors), the statement visitor's stub reset (a block start), the loop bounds (a back edge is a successor block at or before its own, a backward goto-if-not too) and the stackifier's jump targets (its folded successors); one dominator computation, cfg_dominators (Julia's naive_idoms, Compiler/src/ssair/domtree.jl:681), read by the trampolines and the loop labels. No analyze_blocks, no _split_blocks_for_regions, no successor rule outside nir_cfg (no back-edge test on a jump's raw target; the emission reads a jump's target only to emit its branch), no second dominator loop. Behavior: test/nir_use_index.jl's 'nir_cfg is Julia's compute_basic_blocks' (its blocks and edges equal Compiler's over bodies with loops, phis and try/catch, and trailing `nothing` statements in no block, ir.jl:84) and 'the proven-dead proof sees a try body through the one CFG' (a handler's first statement is not proven dead; a statement after an `unreachable` inside a try body is), 'the use count and the loop bounds read one table each' (a loop whose only back edge is a goto-if-not), smoke loop_backward_branch (1.13 lays findfirst's String search loop with a goto-if-not back edge, which the raw-goto rule missed: green before and after), dev/formal/ProvenDead.tla (MCProvenDeadNoCatchEdgeBroken: an Enter's catch edge dropped proves a handler dead) and DefiniteInit.tla (MCDefiniteInitNoCatchEdgeBroken), and the probes byte-identical across the move (the first audit's side notes; 13.4's one CFG; dev/CHARTER.md C1)",
        () -> begin
            local nirs = read(joinpath(SRC, "frontend", "nir.jl"), String)
            local stk = read(joinpath(CODEGEN, "stackified.jl"), String)
            local gen = read(joinpath(CODEGEN, "generate.jl"), String)
            local stm = read(joinpath(CODEGEN, "statements.jl"), String)
            local v = count_sites(r"analyze_blocks|_split_blocks_for_regions")
            v += count("function nir_cfg(nir::Vector{NirStmt})::NirCFG", nirs) == 1 ? 0 : 1
            v += occursin("edge!(k, block_of[t.catch_target])", nirs) && occursin("push!(starts, idx); push!(starts, idx + 1)", nirs) ? 0 : 1
            v += count_sites(r"\bnir_cfg\("; roots=[CODEGEN]) == 3 ? 0 : 1   # the context, the trampolines, the definite-initialization proof over a callee's body
            local diag = read(joinpath(CODEGEN, "diagnostics.jl"), String)
            v += count("stmt_is_proven_unreachable(_ctx_cfg(ctx), idx)", diag) == 2 ? 0 : 1   # the proven-dead proof reads the context's CFG
            # no successor rule from a jump's raw target: no back-edge test on a target, the loop
            # bounds and the stackifier's jump targets read the CFG's successors
            v += count_sites(r"\.target\s*<"; roots=[CODEGEN])
            local ctxs = read(joinpath(CODEGEN, "context.jl"), String)
            local lb = match(r"function loop_bounds\(cfg::NirCFG\).*?\nend\n"s, ctxs)
            v += lb !== nothing && !occursin(".target", lb.match) && occursin("for k in eachindex(cfg.blocks), s in cfg.succs[k]", lb.match) ? 0 : 1
            local ntt = match(r"non_trivial_targets = Set\{Int\}\(\).*?\n\n"s, stk)
            v += ntt !== nothing && !occursin(".target", ntt.match) && occursin("for s in successors[block_idx]", ntt.match) ? 0 : 1
            v += occursin("return generate_structured(b, ctx, ctx.cfg)", gen) ? 0 : 1
            v += occursin("successors = Dict{Int, Vector{Int}}(k => copy(cfg.succs[k]) for k in eachindex(blocks))", stk) ? 0 : 1
            v += occursin("ctx.cfg.blocks[ctx.cfg.block_of[idx]].start_idx == idx", stm) ? 0 : 1
            v += occursin("Int[cfg.blocks[s].start_idx for s in cfg.succs[bk]]", stm) ? 0 : 1
            v += count_sites(r"push!\((succs|successors|preds|predecessors)\["; roots=[CODEGEN])
            v += count_sites(r"Set\{Int\}\(1:n\)|start2id|has_try_catch\(nir\) && return false"; roots=[CODEGEN])
            v += count("function cfg_dominators(", stk) == 1 ? 0 : 1
            v += count(r"while changed", stk) == 1 ? 0 : 1
            local nui = read(joinpath(ROOT, "test", "nir_use_index.jl"), String)
            v += occursin("nir_cfg is Julia's compute_basic_blocks", nui) ? 0 : 1
            v += occursin("the proven-dead proof sees a try body through the one CFG", nui) ? 0 : 1
            v += occursin("_g(\"loop_backward_branch\"", read(joinpath(ROOT, "test", "smoke.jl"), String)) ? 0 : 1
            for f in ("MCProvenDeadNoCatchEdgeBroken.cfg", "MCDefiniteInitNoCatchEdgeBroken.cfg")
                v += isfile(joinpath(ROOT, "dev", "formal", f)) ? 0 : 1
            end
            v
        end),
    "L182_one_callee_representation" => ("a call's constant callee has one representation, its object, resolved once at the NIR boundary by one rule for a :call, an :invoke and a call codegen builds (nir_callee over resolve_operand, and _resolve_nircall_callee's SSA, Core.Const and singleton-argument arms for both statement kinds), as Kernel's StaticInvocation carries its resolved target (expressions.dart:2820): an intrinsic the IR embeds as the object, a type object an :invoke embeds and a function a singleton-typed argument names are their objects; NirCall and NirInvoke refuse a NirLiteral callee at construction (_refuse_literal_callee); a callee passed as an operand (a call codegen builds, nir_call; invoke_in_world's `f`; `_apply_iterate`'s function) is read by the same rule over the operand's static type (nir_operand_callee: a runtime value of a singleton function type is its instance); a constant whose type does not determine it (Compiler's singleton_type over its Core.Typeof answers nothing: not a function singleton, not a type object, not a Builtin) carries its self operand in the node's own field `self` (nir_callee_self, FunctionInvocation.receiver, expressions.dart:2262), which an :invoke of a closure's function pushes first (nir_callee_value) and the operand walkers read; no callee is unwrapped or resolved in codegen (no nir_const of a callee, no `callee isa NirLiteral`, no manual global resolution of a callee operand, no _resolve_builtin_callee, _invoke_in_world_callee) and no :invoke callee is resolved again from its MethodInstance (no _invoke_named_callee, _invoke_callee_object). Behavior: test/nir_use_index.jl's 'a call's constant callee has one representation' (expm1's embedded have_fma, Dict's constructor, a singleton-typed argument's :invoke, a const closure's self; a NirLiteral callee refused) and smoke constant_callees (dev/AUDIT.md A4C5; dev/CHARTER.md C1)",
        () -> begin
            local nirs = read(joinpath(SRC, "frontend", "nir.jl"), String)
            local inv = read(joinpath(CODEGEN, "invoke.jl"), String)
            local v = count("        _refuse_literal_callee(callee)\n", nirs) == 2 ? 0 : 1
            v += count("function nir_callee(x::NirNode)::Any", nirs) == 1 ? 0 : 1
            v += occursin("callee = length(args) >= 2 ? _resolve_nircall_callee(args[2], code_info, types, slot_types) : nothing", nirs) ? 0 : 1
            v += occursin("NirCall(nir_operand_callee(callee, static_type), NirNode[operands...])", nirs) ? 0 : 1
            v += count("nir_callee_self(@nospecialize(callee))::Union{Nothing,NirLiteral} =", nirs) == 1 ? 0 : 1
            v += occursin("closure_self_to_push = something(nir_callee_value(node), NirLiteral(node.callee))", inv) ? 0 : 1
            v += count_sites(r"nir_const\((func|f|fref|target_func|[\w.]*callee[\w.]*)\)|\b(fref|target_func|target)\s+isa\s+NirGlobalRef|_resolve_builtin_callee|_invoke_named_callee|_invoke_callee_object|_invoke_in_world_callee|callee\.value\b|callee isa NirLiteral|isa NirLiteral \? [\w.]*callee";
                             exclude_files=["frontend/nir.jl"])
            # every callee passed as an operand is read by the one rule (nir_operand_callee): the
            # boundary's argument arm, nir_call, invoke_in_world's and _apply_iterate's
            v += count_sites(r"\bnir_operand_callee\("; roots=[SRC]) == 8 ? 0 : 1
            v += occursin("CC.singleton_type(Core.Typeof(callee)) !== nothing", nirs) ? 0 : 1
            local nui = read(joinpath(ROOT, "test", "nir_use_index.jl"), String)
            v += occursin("a call's constant callee has one representation", nui) ? 0 : 1
            v += occursin("_g(\"constant_callees\"", read(joinpath(ROOT, "test", "smoke.jl"), String)) ? 0 : 1
            v
        end),
    "L183_one_as_checker" => ("a typeassert's run-time check is one function per (target, static type), as dart's as-check calls one checker per tested type (types.dart:763 AsCheckers.generateAsChecker, cached in `_asCheckers`, :758): as_checker! builds it on its first use in a codegen context of its own (its one statement `typeassert(x, T)`), with dart's shape: from the top type (anyref, types.dart:784) to the register of S ∩ T (:783), its body narrowing the argument to the static type's register, the one isa lowering over that type (Julia's emit_isa tests S ∩ T, which is why the key holds the static type), the one TypeError throw and the argument converted to S ∩ T's register (:1172-1173); the calling statement converts its operand to the top type; the module's registry caches it (`as_checkers`, the function and its parameter, or the rejection its body raised) and names it as dart does, \"<obj> as T\" (types.dart:1039); _lower_typeassert!'s run-time arm calls it and lowers no isa and allocates no local of its own; a check WT cannot lower rejects at each calling statement with the body's rejection (the checker's own copy leaves the ledger). Behavior: test/diagnostic_attribution.jl's 'an as-checker's rejection is its caller's' (x::Type{<:AbstractVector} over Any: one diagnostic, at the caller's statement) and 'one as-checker per (target, static type)' (two statements and two functions, one function), smoke as_checkers and typeassert_checks (dev/AUDIT.md A4E5; dev/CHARTER.md C1)",
        () -> begin
            local bi = read(joinpath(CODEGEN, "builtins.jl"), String)
            local calls = read(joinpath(CODEGEN, "calls.jl"), String)
            local ta = match(r"function _lower_typeassert!.*?\nend\n"s, bi)
            local v = ta === nothing ? 1 : 0
            ta === nothing || (v += occursin("as_checker!(ctx, _ta_target, _ta_static)", ta.match) &&
                                    !occursin("_compile_call_isa", ta.match) && !occursin("allocate_local!", ta.match) ? 0 : 1)
            v += count_sites(r"\bas_checker!\(") == 3 ? 0 : 1   # its definition, docstring and the one caller
            v += occursin("ctx.type_registry.as_checkers[key] = result", calls) ? 0 : 1
            v += occursin("_compile_call_isa(check.operands, cb, cctx)", calls) ? 0 : 1
            # dart's shape: from the top type (types.dart:784) to S ∩ T's register (:783, :1172-1173)
            v += occursin("local cb = InstrBuilder(WasmValType[AnyRef], results;", calls) &&
                 occursin("coerce_stack_top!(cb, only(results), cctx; from_julia=(R === Nothing ? static_type : R))", calls) ? 0 : 1
            v += (ta !== nothing && occursin("coerce_stack_top!(fb, AnyRef, ctx; from_julia=_ta_static)", ta.match)) ? 0 : 1
            v += occursin("as_checker = GeneratedConstruct(\"as-checker\", \"<obj> as \", \"\", true)", read(joinpath(CODEGEN, "diagnostics.jl"), String)) ? 0 : 1
            local da = read(joinpath(ROOT, "test", "diagnostic_attribution.jl"), String)
            v += occursin("an as-checker's rejection is its caller's", da) && occursin("one as-checker per (target, static type)", da) ? 0 : 1
            local smk = read(joinpath(ROOT, "test", "smoke.jl"), String)
            v += occursin("_g(\"as_checkers\"", smk) && occursin("(\"empty_intersection_throws\"", smk) ? 0 : 1
            v
        end),
    "L184_one_export_namer" => ("a module's export names come from one export namer, as dart's translator holds one exportNamer (translator.dart:163; namer.dart:23 Namer): ExportNamer, made from the module's exports with the names of the exports WasmTarget generates reserved (namer.dart:32 reserveName); every add_export! in codegen takes its name from it, export_name! or generated_export_name! (the compile's functions and its link_roots hook's requests, decided before any body compiles, the exception tag, the class reader), and a name already held is refused naming its holder, never renamed with a counter (no `_d<k>`, `name_<k>` or `base_<n>`: a compiled function's name is its Julia identity, plan_function_names!, Base.StackTraces.show_spec_sig of its method and specTypes printed from a fixed empty module (JuliaNameContext), uncompacted and unlimited, so no `using` in Main renames a function, and refused where a `show` outside Base and Core would print part of it, where of two methods over one specialization the one Julia's `morespecific` orders first keeps it and the other adds its method's own signature, the choice never the plan's order; a name still held twice after that is a WasmInternalError naming both methods); a link_roots hook returns the exports it requests (`name => function index`) and adds none itself (run_link_roots refuses one), and no export is retargeted after codegen (no assignment into a module's `.exports`). Behavior: test/real_bottom_exceptions.jl's 'each export is made once' (a hook's request exported once through its entry; a hook's own add_export!, a hook's request for a name a compiled function holds, a requested reserved name and a host export of a function's signature each refused, naming the holder) and test/generated_names.jl's 'a compiled function is named by its signature' (names independent of the order, smoke's invoke_names_its_method and closure_invoke_only_body named by rule (a), two generic functions printing alike refused) and 'a compiled function's name does not depend on the session' (the same names before and after a `using` in Main; a value parameter a user `show` prints refused); a hook that retargets an export the module holds is refused too (dev/AUDIT.md A13C2, A12C5, P6; dev/MARCH.md 13.4; dev/CHARTER.md C1)",
        () -> begin
            local comp = read(joinpath(CODEGEN, "compile.jl"), String)
            local trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            local v = count_sites(r"^struct ExportNamer$") == 1 ? 0 : 1
            # every export codegen makes is named by the namer: each add_export! line names it
            # there, or is the compile's one loop over the names the namer took before codegen
            for root in (CODEGEN, joinpath(SRC, "frontend"), joinpath(ROOT, "ext")), (dir, _, files) in walkdir(root), f in files
                endswith(f, ".jl") || continue
                for line in eachline(joinpath(dir, f))
                    (_iscomment(line) || !occursin(r"\badd_(?:global_|table_|memory_)?export!\(", line)) && continue
                    (occursin(r"\badd_export!\(mod, (?:generated_)?export_name!\(", line) ||
                     strip(line) == "add_export!(mod, name, 0, target)") || (v += 1)
                end
            end
            local required = [(comp, "push!(compile_exports, (export_name!(namer, String(name), \"the compiled function \\\"\$(name)\\\"\"),"),
                              (comp, "push!(compile_exports, (export_name!(namer, name, \"the link_roots hook's request for function \$(idx)\"), idx))"),
                              (comp, "    for (name, idx) in compile_exports\n        local target = (exc_top === nothing || idx < num_imported_funcs(mod)) ? idx :\n                       emit_export_entry!(mod, type_registry, idx, name)\n        add_export!(mod, name, 0, target)\n    end"),
                              (comp, "    local before = copy(mod.exports)\n    local requested = link_roots(mod, root_indices, registry)\n    mod.exports == before || throw(ArgumentError("),
                              # a name held is refused where it is taken, never renamed
                              (comp, "    prior === nothing || throw(ArgumentError(\n        \"the export name \\\"\$name\\\" is taken (\$(prior)), the name \$(holder) is exported under: \" *"),
                              (comp, "    prior === nothing || throw(ArgumentError(\n        \"the export name \\\"\$name\\\" is taken (\$(prior)), the name of the export WasmTarget generates\"))"),
                              (trim, "all(o -> o === mi || Base.morespecific(mi.def::Method, o.def::Method), alike)) ? s :"),
                              (trim, "julia_function_name(mi::Core.MethodInstance)::String = _julia_signature_text(mi.def::Method, mi.specTypes)"),
                              (trim, "    local shown = _user_shown_in_signature(sig)\n    if shown !== nothing"),
                              (trim, "IOContext(io, :module => JuliaNameContext, :compact => false, :limit => false, :color => false), m, sig))"),
                              (trim, "string(s, \" [\", _julia_signature_text(mi.def::Method, (mi.def::Method).sig), \"]\")"),
                              (read(joinpath(ROOT, "test", "real_bottom_exceptions.jl"), String), "occursin(\"the link_roots hook's request\", err.msg)"),
                              (read(joinpath(ROOT, "test", "generated_names.jl"), String), "@test \"_sm_oc(x::Int64) [_sm_oc(x::Integer)]\" in names(mi)"),
                              (read(joinpath(ROOT, "test", "generated_names.jl"), String), "@test occursin(\"print alike\", msg)")]
            v += count(((text, needle),) -> !occursin(needle, text), required)
            # one place each export is made: the compile's loop runs once, after codegen, over names
            # decided before it; nothing retargets an export, and no counter renames one
            v += count_sites(r"\.exports\[[^\]]*\]\s*=(?!=)|codegen_export_names|used_names|export_name_counts|given_names|\"_d\"")
            v += count("local namer = ExportNamer(mod)", comp) == 1 ? 0 : 1
            v
        end),
    "L185_one_import_query" => ("the import at a function index is read by one builder query, imported_function(mod, idx), as wasm_builder's FunctionsBuilder holds its imported functions (functions.dart:13 _importedFunctions) and FunctionsBuilder.import (:43) hands its caller the imported function: codegen, the frontend and ext read no module's `.imports` (no filter over a module's imports at a call site, no index into them), every import query there being imported_function, with num_imported_funcs for the count; inside the builder the list is read only by the functions that keep it (add_import!, num_imported_funcs, imported_function) and the serializer (to_bytes_mapped). Behavior: test/host_imports.jl's 'one query for the import at a function index' (the k-th function import, nothing at a defined function's index, a host-declared import told apart by that answer alone, and the import section the bytes declare read back the same) (dev/AUDIT.md A13E4; dev/CHARTER.md C1)",
        () -> begin
            local v = count_sites(r"\.imports\b"; roots=[CODEGEN, joinpath(SRC, "frontend"), joinpath(ROOT, "ext")])
            v += count_sites(r"filter\([^\n]*\bimports\b")
            v += count_sites(r"^function imported_function\(") == 1 ? 0 : 1
            # the builder: the functions that read the list, exactly
            local readers = Set{String}()
            for (dir, _, fs) in walkdir(joinpath(SRC, "builder")), f in fs
                endswith(f, ".jl") || continue
                local enclosing = ""
                for line in eachline(joinpath(dir, f))
                    local d = match(r"^function\s+([^\s(]+)\(", line)
                    d === nothing || (enclosing = d.captures[1])
                    _iscomment(line) && continue
                    occursin(r"\bmod\.imports\b", line) && push!(readers, enclosing)
                end
            end
            v += length(symdiff(readers, Set(["add_import!", "num_imported_funcs", "imported_function", "to_bytes_mapped"])))
            local hi = read(joinpath(ROOT, "test", "host_imports.jl"), String)
            v += occursin("@testset \"one query for the import at a function index\" begin", hi) &&
                 occursin("@test WasmTarget.imported_function(mod, n) === nothing", hi) ? 0 : 1
            v
        end),
    "L154_planned_cites_rows" => ("a clause's Planned text cites dev/MARCH.md rows, never findings, and every finding sits on a row: no finding ID in any clause's Planned text; every row it cites exists; each row but 13.17 names in its Clause column exactly the clauses whose Planned cites it (a row that names none, as 13.16 post-merge and 13.11 the merge, is cited by none); and every finding ID on 13.17 sits under a group label `<name> (C<n> …):` whose clauses each cite 13.17, as every clause citing 13.17 has a label. Audits then lengthen MARCH rows, not the charter (82 to 105 Planned IDs on 2026-10-07; A3P4; dev/CHARTER.md C0)",
        () -> begin
            local rx = r"\b(A\d+[A-Z]\d+|[BEHMPS]\d+)\b"
            local charter = read(joinpath(ROOT, "dev", "CHARTER.md"), String)
            local plan = read(joinpath(ROOT, "dev", "MARCH.md"), String)
            local rows = Dict{String,Set{String}}()
            local row1317 = ""
            for l in split(plan, '\n')
                local m = match(r"^\| (13\.\d+) \| ([^|]*) \|", l)
                m === nothing && continue
                rows[m.captures[1]] = Set(String[x.match for x in eachmatch(r"C\d+", m.captures[2])])
                m.captures[1] == "13.17" && (row1317 = String(l))
            end
            local v = 0
            local cites = Dict{String,Set{String}}()
            for blk in split(charter, r"\n(?=- \*\*C\d+)")
                local h = match(r"^- \*\*(C\d+)", blk)
                h === nothing && continue
                local i = findfirst("Planned:", blk)
                i === nothing && continue
                local seg = blk[first(i):end]
                local j = findfirst("\n## ", seg)
                j === nothing || (seg = seg[1:first(j)])
                v += length(collect(eachmatch(rx, seg)))
                for r in eachmatch(r"13\.\d+", seg)
                    haskey(rows, r.match) || (v += 1)
                    push!(get!(cites, r.match, Set{String}()), h.captures[1])
                end
            end
            for (r, cs) in rows
                r == "13.17" && continue
                cs == get(cites, r, Set{String}()) || (v += 1)
            end
            # 13.17: each ID after a label, and labels' clauses == the clauses citing 13.17
            local labels = collect(eachmatch(r"[A-Za-z][^:;()]{1,60} \((C\d+(?: C\d+)*)[^()]*\):", row1317))
            local first_label = isempty(labels) ? lastindex(row1317) + 1 : labels[1].offset
            v += length(collect(m for m in eachmatch(rx, row1317) if m.offset < first_label))
            local label_clauses = Set(String[c.match for l in labels for c in eachmatch(r"C\d+", l.captures[1])])
            label_clauses == get(cites, "13.17", Set{String}()) || (v += 1)
            v
        end),
    "L148_changes_are_audited" => ("every change is audited against the charter before it lands (AGENTS.md, the anti-drift audit): every dev/AUDIT.md entry names the commit it audited through, an ancestor of HEAD, and each entry's range starts at the one before it (the entries chain, A2P5); the last is at most 5 commits behind HEAD, merges not counted; and every entry covers the four areas (builder; collection and planning; emission and diagnostics; enforcement and prose) with its findings and how each was resolved. With no git history the check fails, never skips (dev/CHARTER.md C0)",
        () -> begin
            local audit = joinpath(ROOT, "dev", "AUDIT.md")
            isfile(audit) || return 1
            local txt = read(audit, String)
            local entries = split(txt, r"\n(?=## )")[2:end]
            isempty(entries) && return 1
            local v = 0
            for e in entries
                for area in ("Area: builder", "Area: collection and planning",
                             "Area: emission and diagnostics", "Area: enforcement and prose")
                    occursin(area, e) || (v += 1)
                end
                occursin("Resolution:", e) || (v += 1)
            end
            # the entries chain: each one's range starts where the one before it was audited
            # through, and every audited-through commit is an ancestor of HEAD (a rewritten
            # history fails, never skips: A2P5)
            local prev = nothing
            local sha = nothing
            for e in entries
                local m = match(r"audited through ([0-9a-f]{8,40})", e)
                m === nothing && (v += 1; continue)
                sha = m.captures[1]
                success(`git -C $ROOT merge-base --is-ancestor $sha HEAD`) || (v += 1)
                if prev !== nothing
                    local r = match(r"\(([0-9a-f]{7,40})(?:~1)?\.\.", e)
                    (r !== nothing && (startswith(prev, r.captures[1]) || startswith(r.captures[1], prev))) || (v += 1)
                end
                prev = sha
            end
            sha === nothing && return v + 1
            success(`git -C $ROOT merge-base --is-ancestor $sha HEAD`) || return v   # counted above
            # the commits since the last audited one, merges not counted: a pull request's
            # merge checkout and a landed march branch count the same
            local behind = parse(Int, readchomp(`git -C $ROOT rev-list --count --no-merges $sha..HEAD`))
            return v + (behind > 5 ? 1 : 0)
        end),
    "L143_one_storage_pointer_rule" => ("a storage-relative pointer becomes an array index through one rule, _emit_storage_element_offset!: its value is the byte offset into the traced backing array, 1-based for a String or Symbol (jl_string_ptr answers 1), so the rule subtracts 1 for those and divides by the element size. No lowering converts a pointer to an index itself (no `from_julia=Ptr{UInt8}` coercion). Until 2026-09-29 jl_pchar_to_string used the pointer's value as the index: String(::SubString{String}) copied from one byte late and string(SubString(\"cde\", 1, 2)) answered \"de\" (smoke substring_to_string; dev/CHARTER.md C1)",
        () -> count_sites(r"from_julia\s*=\s*Ptr\{UInt8\}"; roots=[CODEGEN])),
    "L142_struct_layout_by_structure" => ("a concrete struct is laid out by its fields whatever it subtypes, and a type's layout does not depend on the route that meets it first: is_struct_type decides by structure (concrete, isstructtype, no dedicated representation) and names no type — no `name.name`, no `<: Number` or `<: AbstractArray` test, no extension-filled name set (_ARRAY_STRUCT_CARVEOUT is gone); every field translator (the struct, tuple and closure registrars) and register_reachable_type! register a concrete Array through register_array_wrapper!, the Vector layout for rank 1 and the Matrix layout otherwise; and a constructor :invoke is called as the function of its MethodInstance, never replaced by a bare struct.new (compile_invoke! emits none; the arm that did when the body was proven `%new(T, args...)` needed a body the plan holds only for a MethodInstance with a function, so it could not run, and is gone). Until 2026-09-29 AbstractArray and Number subtypes were excluded by name and a few re-admitted by name: a Diagonal took the Matrix layout `[:ref, :size]` (so `D.diag` was not lowerable), a Complex was an erased structref in locals (ifelse over two emitted invalid wasm), a struct's Matrix field registered the Matrix with the Vector layout, and six LinearAlgebra overlays stood in for Julia's bodies (dev/CHARTER.md C1)",
        () -> begin
            structs = read(joinpath(CODEGEN, "structs.jl"), String)
            inv = read(joinpath(CODEGEN, "invoke.jl"), String)
            m = match(r"(?s)\nfunction is_struct_type\(.*?\nend\n", structs)
            body = m === nothing ? "" : m.match
            n = m === nothing ? 1 : 0
            n += count(p -> occursin(p, body), ["name.name", "<: Number", "<: AbstractArray", "CARVEOUT"])
            n += count_sites(r"_ARRAY_STRUCT_CARVEOUT"; roots=[SRC, joinpath(ROOT, "ext")])
            # the four routes that register a field's or a signature's Array
            n += (count(r"register_array_wrapper!\(mod, registry, ft\)", structs) >= 3 ? 0 : 1)
            n += occursin("register_array_wrapper!(mod, registry, T)", structs) ? 0 : 1
            n += occursin("struct_new!", inv) ? 1 : 0   # an :invoke is called, never replaced by a struct.new
            n += occursin("fieldcount(_sc_tt) == length(args)", inv) ? 1 : 0
            n
        end),
    "L141_constants_intern_by_egal" => ("a constant is interned by `===`, Julia's egal and dart's Constant equality (a dart Constant equals only one of its own class with equal fields, constants.dart:154 constantInfo): every `*constant_globals` map of the TypeRegistry is an IdDict, or a Dict whose key type is one where isequal is `===` (String, Symbol, Core.TypeName). Until 2026-09-29 constant_globals was a Dict{Any} keyed by isequal: the constant `(0x01,)` read the `(1,)` global randperm had made, and Random's own hash_seed trapped on the cast for a negative seed; a same-layout pair such as `(true,)` and `(0x01,)` passed the cast carrying the wrong type (dev/formal/Constants.tla SharedOnlyIfEgal; dev/CHARTER.md C3)",
        () -> begin
            types = read(joinpath(CODEGEN, "types.jl"), String)
            maps = collect(eachmatch(r"^\s+(\w*constant_globals)::([^#\n]+?)\s*(?:#.*)?$"m, types))
            egal_keys = ("Dict{Union{String,Symbol},", "Dict{Core.TypeName,", "Dict{String,", "Dict{Symbol,")
            (length(maps) < 6 ? 1 : 0) +
                count(m -> !(startswith(m.captures[2], "IdDict{") ||
                             any(k -> startswith(m.captures[2], k), egal_keys)), maps)
        end),
    "L140_overlay_reasons_are_verified" => ("an overlay's quarantine reason that names a BLAS or LAPACK routine is checked, not believed: test/overlay_reasons.jl (one QA family of runtests.jl) finds, for each such overlay, that Julia's own method at the overlay's signature reaches that routine's foreigncall through its invokes, and every such reason in ext/ uses the one form it parses, `parity(quarantine: BLAS gemm: …)`. The first run found a reason naming BLAS trsv where Julia's ldiv! calls LAPACK trtrs (dev/CHARTER.md C3)",
        () -> begin
            n = isfile(joinpath(ROOT, "test", "overlay_reasons.jl")) ? 0 : 1
            n += occursin("include(\"overlay_reasons.jl\")", read(joinpath(ROOT, "test", "runtests.jl"), String)) ? 0 : 1
            for (d, _, fs) in walkdir(joinpath(ROOT, "ext")), f in fs
                endswith(f, ".jl") || continue
                for l in eachline(joinpath(d, f))
                    occursin(r"quarantine:\s*(BLAS|LAPACK)\b", l) || continue
                    occursin(r"^# parity\(quarantine: (BLAS|LAPACK) [a-z0-9]+: ", l) || (n += 1)
                end
            end
            n
        end),
    "L139_invoke_names_its_method" => ("an :invoke calls the method its MethodInstance names: the closed-world plan keeps one function per MethodInstance (never one per (f, arg_types): two methods share a specialization's argument types when Base calls a less specific one with `invoke(f, Tuple{Super}, x)`), marks the one dispatch does not select invoke-only, the collector's re-specialization keeps the invoked method (or its same-signature overlay) even where a more specific method fully covers it, and codegen decides self-recursion and the callee by the MethodInstance's function. Until 2026-09-28 the rebuild took dispatch's choice and the plan deduplicated by (f, arg_types): unique(::Vector{Float64}) compiled to a function that called itself forever (dev/CHARTER.md C6)",
        () -> begin
            trim = read(joinpath(CODEGEN, "trimcollect.jl"), String)
            inv = read(joinpath(CODEGEN, "invoke.jl"), String)
            types = read(joinpath(CODEGEN, "types.jl"), String)
            required = ["((mi.def, mi.specTypes) in seen_mis) && continue",
                        "push!(functions, (f, arg_types, name, mi))",
                        "if m.method.sig == mi.def.sig",
                        "if m.method.sig == root_mi.def.sig",
                        "CC.specialize_method(root_mi.def, root_mi.specTypes, root_mi.sparam_vals)",
                        "local target = get_function_by_mi(ctx.func_registry, mi)",
                        "# one call arm, self-recursion included",
                        "get_function_by_mi(registry::FunctionRegistry, mi::Core.MethodInstance)"]
            count(p -> !occursin(p, trim * inv * types), required) +
                count(p -> occursin(p, trim), ["seen_sigs", "(f, arg_types) in seen_sigs"])
        end),
    "L138_oracle_is_bit_exact" => ("the differential oracle is bit-exact: a float matches when its bits are Julia's (0.0 and -0.0 differ) or both are NaN — compare_julia_wasm and the vector bridges by isequal, the fuzz oracle's vals_match by isequal, Bridge._float_match by `===` — and the result transports carry -0.0 (JSON writes it as 0). The one tolerance (a relative 1e-9) applies only where tree_matches is told why the native value's last bits are not Julia's portable answer, and only four per-case allowlists say so: linalg_diff.jl's _LA_C_LIBRARY (each a BLAS or LAPACK routine), stats_diff.jl's _ST_NONPORTABLE and staticarrays_diff.jl's _SA_NONPORTABLE (each an @simd reduction, whose order and contraction Julia leaves to the target), and simplediffeq_diff.jl's _SDE_NONPORTABLE (each a muladd, which Julia leaves free to round once or twice — every case, since every solver's step is @muladd, and the lane checks that of each solver's step method, _sde_step_calls_muladd). Until 2026-09-28 every float compared within 1e-9 (the fuzz oracle, the bridge) or 1e-10 (the vector bridges), which passed a last-bit error in Julia's own math and a -0.0 read as 0.0 (dev/CHARTER.md C3)",
        () -> begin
            bridge = read(joinpath(SRC, "bridge.jl"), String)
            utils = read(joinpath(ROOT, "test", "utils.jl"), String)
            prop = read(joinpath(ROOT, "test", "fuzz", "property.jl"), String)
            n = count_sites(r"isapprox\(|≈|\brtol\b|\batol\b"; roots=[joinpath(ROOT, "test")],
                            exclude_files=["parity_ratchet.jl"])
            n += count_sites(r"isapprox\(|\brtol\b|\batol\b"; roots=[SRC],
                             exclude_line=r"return isapprox\(Float64\(a\), Float64\(b\); rtol = 1e-9, atol = 1e-12\)")
            n += count(p -> !occursin(p, bridge * utils * prop),
                       ["nonportable === nothing && return false", "a === b && return true",
                        "pass=isequal(expected, actual)", "return isequal(a, b)",
                        "if (Object.is(value, -0)) return \"__-0__\";", "out.push('__-0__')",
                        "result == \"__-0__\" && return -0.0"])
            # a SimpleDiffEq allowance is checked against the solver's own step, not believed
            n += occursin("calls = _sde_step_calls_muladd(S)",
                          read(joinpath(ROOT, "test", "fuzz", "simplediffeq_diff.jl"), String)) ? 0 : 1
            for (file, dict, rx) in (("linalg_diff.jl", "_LA_C_LIBRARY", r"^(BLAS|LAPACK) [a-z]"),
                                     ("stats_diff.jl", "_ST_NONPORTABLE", r"^@simd [A-Za-z]"),
                                     ("staticarrays_diff.jl", "_SA_NONPORTABLE", r"^@simd [A-Za-z]"),
                                     ("simplediffeq_diff.jl", "_SDE_NONPORTABLE", r"^muladd [A-Za-z]"))
                src = read(joinpath(ROOT, "test", "fuzz", file), String)
                m = match(Regex("(?s)const $(dict) = Dict\\{Function,String\\}\\((.*?)\\n?\\)\\n"), src)
                m === nothing && (n += 1; continue)
                n += count(v -> !occursin(rx, v), [x.captures[1] for x in eachmatch(r"=> \"([^\"]*)\"", m.captures[1])])
            end
            n
        end),
    "L137_any_is_anyref" => ("one representation of `Any`: the \$JlType hierarchy is created right after Top, before any type registers (compile_module; dart's ClassInfoCollector.collect creates Top and `_Type` first), so every `Any` field, local and signature is anyref — no code branches on the hierarchy's absence and no pass rewrites a finished type. Until 2026-09-28 the exception and signature types registered before the hierarchy took externref `Any` fields and a second, stale DataType struct, which patch_any_fields_for_jltype_hierarchy! rewrote afterwards (dev/CHARTER.md C1)",
        () -> begin
            compile_src = read(joinpath(CODEGEN, "compile.jl"), String)
            count_sites(r"jl_type_idx\s*(===|!==)\s*nothing"; exclude_line=r"# Already created") +
                count_sites(r"\bmod\.types\[[^\]]*\]\s*=[^=]") +
                count_sites(r"patch_any_fields_for_jltype_hierarchy!") +
                (occursin("get_base_struct_type!(mod, type_registry)\n    create_jl_type_hierarchy!(mod, type_registry)", compile_src) ? 0 : 1)
        end),
    "L136_constant_type_is_its_emission" => ("a constant's static type (static_wasm_type, dart's TypeOfConstantVisitor) is the type its emission pushes: the one visitor, emit_value!(b, val, ctx), checks it for every literal and bound GlobalRef it emits, as dart asserts it of every constant (constants.dart:811), and every reference constant is non-null (constants.dart:821). A long String constant pushed (ref null \$JlString) under a non-null static type until 2026-09-28 (dev/CHARTER.md C4)",
        () -> begin
            src = read(joinpath(CODEGEN, "values.jl"), String)
            m = match(r"(?s)\nfunction emit_value!\(b::InstrBuilder, val::NirNode, ctx::AbstractCompilationContext\)::.*?\nend\n", src)
            m === nothing && return 1
            count(r -> !occursin(r, m.match),
                  ["local st = static_wasm_type(val, ctx)", "st == ty || error("])
        end),
    "L129_plan_holds_only_open_work" => ("dev/MARCH.md lists open work only — at most 60 lines, no finished row (`| done |`) and no results section — and dev/HISTORY.md stays an archive of short entries (at most 160 lines, each `## ` entry at most 25). Finished work leaves the plan in the commit that closes it; results live in commit messages and this harness's output (dev/CHARTER.md C9)",
        () -> begin
            v = String[]
            plan = _lines(joinpath(ROOT, "dev", "MARCH.md"))
            length(plan) <= 60 || push!(v, "dev/MARCH.md has $(length(plan)) lines (cap 60)")
            for (i, l) in enumerate(plan)
                (occursin(r"\|\s*done\s*\|"i, l) || occursin(r"^#+ .*\bresults?\b"i, l)) &&
                    push!(v, "dev/MARCH.md:$i holds finished work: $(first(l, 60))")
            end
            hist = _lines(joinpath(ROOT, "dev", "HISTORY.md"))
            length(hist) <= 160 || push!(v, "dev/HISTORY.md has $(length(hist)) lines (cap 160)")
            starts = [i for (i, l) in enumerate(hist) if startswith(l, "## ")]
            for (k, i) in enumerate(starts)
                n = (k < length(starts) ? starts[k + 1] : length(hist) + 1) - i
                n <= 25 || push!(v, "dev/HISTORY.md entry at line $i is $n lines (cap 25)")
            end
            foreach(x -> println("    ✗ ", x), v)
            length(v)
        end),
    # ── the NIR boundary (frontend/nir.jl) is codegen's one reader of Julia's typed IR ──
    "R29a_raw_codeinfo_reads" => ("Expr.head/.args[ / ssavaluetypes raw reads in codegen/ — every codegen consumer reads ctx.nir nodes built once by frontend/nir.jl (dart reads every node through one typeContext, code_generator.dart:77). Inside ir.jl only an exact list of functions may read a raw CodeInfo: get_typed_ir (the boundary's input) and the typed-IR transport (IR_RAW_READERS); the host-layout query reads NIR; the closed-world type collector reads NIR (locked 2026-09-22; ir.jl narrowed 2026-09-23)",
        () -> count_sites(r"\.args\[|\.head ==|\.head ===|ssavaluetypes"; roots=[CODEGEN], exclude_files=["ir.jl"]) +
              _ir_raw_reads_outside_allowlist(r"\.args\[|\.head ==|\.head ===|ssavaluetypes")),
    "R29b_code_info_identifier" => ("the `code_info` identifier in codegen/ — CompilationContext is built from a NirBody and carries no CodeInfo; the planner hands typed IR to nir_body, and inside ir.jl only the IR_RAW_READERS functions name it (locked 2026-09-22; ir.jl narrowed 2026-09-23)",
        () -> count_sites(r"\bcode_info\b"; roots=[CODEGEN], exclude_files=["ir.jl"]) +
              _ir_raw_reads_outside_allowlist(r"\bcode_info\b")),
    "L126_ratchets_terminate_at_zero" => ("dev/CHARTER.md rule 2: a ratchet's only terminal state is 0. No ratchet description may declare a floor or its sites legitimate/reclassified — a site that belongs moves into an exact per-site allowlist with its anchor, a reviewable diff",
        () -> count(p -> occursin(r"floor|legitimate|reclassif"i, first(last(p))), METRICS)),
]


function run(; update::Bool=(get(ENV, "WT_RATCHET_UPDATE", "0") == "1"))
    baseline = _read_baseline(BASELINE_PATH)
    bm = get(baseline, "metrics", Dict{String,Int}())

    ok = true
    current_m = Dict{String,Int}()
    current_l = Dict{String,Int}()

    # function_body_lines must see the whole god function (4,583 lines at the march baseline);
    # a helper that exits early would make every span lock vacuous
    _fbl_check = function_body_lines(joinpath(CODEGEN, "calls.jl"), "function compile_call!(")
    _fbl_check > 1000 || (println("⚠ function_body_lines sanity check: got $_fbl_check (expected > 1000)"); ok = false)

    println("── parity ratchet (dev/CHARTER.md's locks and ratchets) ──")
    for (id, (desc, thunk)) in METRICS
        c = thunk()
        current_m[id] = c
        b = get(bm, id, nothing)
        # a ratchet with no baseline line bounds nothing: outside update mode it fails, and only
        # WT_RATCHET_UPDATE=1 records it, a reviewable diff of the baseline (A12P5)
        status = b === nothing ? (update ? "NEW(baseline): recorded by this update" :
                                  "❌ MISSING from dev/parity_baseline.toml (record it with WT_RATCHET_UPDATE=1)") :
                 c > b ? "❌ RATCHET BROKEN (+$(c - b))" :
                 c < b ? "▼ improved ($b→$c — tighten with WT_RATCHET_UPDATE=1)" : "= holding"
        b === nothing && !update && (ok = false)
        b !== nothing && c > b && (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", status, "   # ", desc)
    end
    for (id, (desc, thunk)) in LOCKS
        c = thunk()
        current_l[id] = c
        # a lock passes only at 0, whatever the baseline holds (A3P9)
        good = (c == 0)
        good || (ok = false)
        println(rpad(id, 28), lpad(string(c), 6), "  ", good ? "🔒 locked" : "❌ LOCK BROKEN (want 0)", "   # ", desc)
    end
    # a baseline key that names no METRICS ratchet fails outside update mode: a lock is not
    # recorded (A3P9), and a key left by a renamed or deleted ratchet bounds nothing (A12P5)
    metric_ids = Set{String}(first(p) for p in METRICS)
    for sec in sort!(collect(keys(baseline))), k in sort!(collect(keys(baseline[sec])))
        (sec == "metrics" && k in metric_ids) && continue
        if update
            println("baseline key [", sec, "] ", k, " names no METRICS ratchet: dropped by this update")
        else
            println("❌ STRAY baseline key [", sec, "] ", k, ": names no METRICS ratchet, FAIL (delete the line; a lock is not recorded, A3P9)")
            ok = false
        end
    end


    # dev/CHARTER.md: the per-clause verdict. A clause is CLOSED only when every check it
    # cites is a passing lock (a cited ratchet keeps it open, at 0 too, until it moves to
    # LOCKS) and it names no planned check.
    println("── charter (dev/CHARTER.md) ──")
    allc = merge(current_m, current_l)
    byshort = Dict(_short_id(k) => k for k in keys(allc))
    for (cid, (body, ids)) in charter_clauses()
        title = strip(first(split(body, "."; limit=2)))
        title = replace(title, "*" => "")
        open_ = String[]
        for i in ids
            k = get(byshort, i, nothing)
            k === nothing && (push!(open_, "$i?"); continue)
            # a cited ratchet keeps its clause open until it is a lock: "reached 0 and been
            # converted to a lock" (dev/CHARTER.md), not merely at 0
            haskey(current_m, k) && push!(open_, current_m[k] > 0 ? "$i=$(current_m[k])" : "$i (at 0, not yet a lock)")
            haskey(current_l, k) && current_l[k] != 0 && push!(open_, "$i BROKEN")
        end
        occursin("Planned:", body) && push!(open_, "planned check")
        println(rpad(cid, 4), rpad(first(title, 42), 44), isempty(open_) ? "CLOSED" : "OPEN  " * join(open_, " "))
    end
    if update
        if !ok
            println("refusing WT_RATCHET_UPDATE: a ratchet/lock is BROKEN (ratchets never loosen).")
        else
            _write_baseline(BASELINE_PATH, current_m)
            println("baseline tightened → ", BASELINE_PATH)
        end
    end
    return ok
end

end # module

# Standalone: exit 0/1. From runtests, include this file then assert
# `@test ParityRatchet.run()` inside a @testset (see runtests.jl's `_wt_qa("parity_ratchet.jl")` block).
if get(ENV, "WT_RATCHET_INCLUDED", "0") != "1"
    exit(ParityRatchet.run() ? 0 : 1)
end
