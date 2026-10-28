# dev/skeleton.jl — the rebuild's src skeleton, generated from dart2wasm and wasm_builder at the pinned
# commit (dev/MARCH.md 1.A4; dev/LEDGER.md D1, D26). It reads every in-scope dart file of the pin, with
# a lexer of dart's syntax cross-checked by a second, independent reader of dart-format's indentation,
# and emits src/<file>.jl: one Julia definition per dart definition, in dart's order, each with its
# `@parity "<file>.dart:<line> <Symbol>"` anchor and, until a lane ports it, an `@unported` body that
# rejects with that anchor. A filled definition is never touched: a re-run regenerates only
# `@unported` definitions and keeps every filled one verbatim.
#
#   julia dev/skeleton.jl count      the in-scope dart definitions, per file and in all
#   julia dev/skeleton.jl check      the two readers agree on every in-scope file (no output: agree)
#   julia dev/skeleton.jl write      write every in-scope file's skeleton, merged with what src holds
#   julia dev/skeleton.jl diff       the no-diff check: src holds exactly what `write` would write, no
#                                    Kernel row is stale, and every filled struct keeps its dart
#                                    class's instance fields or lists them to come
#   julia dev/skeleton.jl merge <tree> <dart file>...   take another tree's filled definitions of
#                                    those dart files, each in place of its stub
#
# The pin is dev/PARITY_MASTER.md's; the sdk checkout is $WT_DART_SDK, else
# ~/.cache/wasmtarget/dart-sdk (dev/fetch_dart_sdk.sh), and must be at the pin. The scope is
# dev/skeleton_scope.toml.
module Skeleton

const ROOT = normpath(joinpath(@__DIR__, ".."))

# ---- the pin and the sdk -------------------------------------------------------------------------
pin()::String = match(r"\b[0-9a-f]{40}\b", read(joinpath(ROOT, "dev", "PARITY_MASTER.md"), String)).match

# the checkout, verified at the pin once per run (each library path asks for it)
const SDK = String[]
sdk()::String = isempty(SDK) ? (push!(SDK, _sdk()); SDK[1]) : SDK[1]
function _sdk()::String
    local dir = get(ENV, "WT_DART_SDK", joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk"))
    local head = try
        readchomp(`git -C $dir rev-parse HEAD`)
    catch
        error("skeleton: no dart-lang/sdk checkout at $dir (bash dev/fetch_dart_sdk.sh)")
    end
    head == pin() || error("skeleton: $dir is at $head, not the pin $(pin())")
    return dir
end

# a pin-table key (src/julia/parity.jl DART_FILES: the path under the sdk's pkg/ at the pin) and its source
dart_source(key::AbstractString)::String = joinpath(sdk(), "pkg", key)

# ---- the lexer -----------------------------------------------------------------------------------
struct Tok
    kind::Symbol      # :ident :number :string :punct
    text::String
    line::Int
    col::Int          # 0-based column of the token's first character
end

# the operator spellings dart's grammar names after `operator`, longest first
const OPS = [">>>=", "[]=", ">>>", "~/=", "==", "<=", ">=", "<<", ">>", "~/", "[]", "+", "-", "*", "/",
             "%", "<", ">", "&", "|", "^", "~"]

mutable struct Lexer
    s::Vector{Char}
    i::Int
    line::Int
    col::Int
    toks::Vector{Tok}
    file::String
end

peekc(L::Lexer, k::Int = 0)::Char = L.i + k <= length(L.s) ? L.s[L.i+k] : '\0'
function adv!(L::Lexer, n::Int = 1)
    for _ in 1:n
        if peekc(L) == '\n'
            L.line += 1; L.col = 0
        else
            L.col += 1
        end
        L.i += 1
    end
end
lexfail(L::Lexer, why) = error("skeleton: $(L.file):$(L.line): $why")

function skip_trivia!(L::Lexer)
    while L.i <= length(L.s)
        local c = peekc(L)
        if c == ' ' || c == '\t' || c == '\r' || c == '\n'
            adv!(L)
        elseif c == '/' && peekc(L, 1) == '/'
            while L.i <= length(L.s) && peekc(L) != '\n'
                adv!(L)
            end
        elseif c == '/' && peekc(L, 1) == '*'
            local depth = 0
            while true
                L.i > length(L.s) && lexfail(L, "an unterminated block comment")
                if peekc(L) == '/' && peekc(L, 1) == '*'
                    depth += 1; adv!(L, 2)
                elseif peekc(L) == '*' && peekc(L, 1) == '/'
                    depth -= 1; adv!(L, 2)
                    depth == 0 && break
                else
                    adv!(L)
                end
            end
        else
            break
        end
    end
end

# a string literal from the current quote (after any `r` prefix): its interpolations `${…}` lexed as
# code and discarded, so a brace inside one never counts for the declarations
function skip_string!(L::Lexer, raw::Bool)
    local q = peekc(L)
    local triple = peekc(L, 1) == q && peekc(L, 2) == q
    adv!(L, triple ? 3 : 1)
    while true
        L.i > length(L.s) && lexfail(L, "an unterminated string")
        local c = peekc(L)
        if triple && c == q && peekc(L, 1) == q && peekc(L, 2) == q
            adv!(L, 3); return
        elseif !triple && c == q
            adv!(L); return
        elseif !triple && c == '\n'
            lexfail(L, "a newline in a single-line string")
        elseif !raw && c == '\\'
            adv!(L, 2)
        elseif !raw && c == '$' && peekc(L, 1) == '{'
            adv!(L, 2)
            local saved = length(L.toks)
            lex_until_brace!(L)
            resize!(L.toks, saved)
        else
            adv!(L)
        end
    end
end

# lex tokens until the `}` that closes an interpolation (consumed)
function lex_until_brace!(L::Lexer)
    local depth = 0
    while true
        skip_trivia!(L)
        L.i > length(L.s) && lexfail(L, "an unterminated interpolation")
        if peekc(L) == '}' && depth == 0
            adv!(L); return
        end
        local t = next_tok!(L)
        t === nothing && continue
        t.text == "{" && (depth += 1)
        t.text == "}" && (depth -= 1)
    end
end

isidstart(c::Char)::Bool = isletter(c) || c == '_' || c == '$'
isidchar(c::Char)::Bool = isletter(c) || isdigit(c) || c == '_' || c == '$'

# the next token, pushed; a string's text is its source, quotes and any `r` prefix kept
function next_tok!(L::Lexer)
    local line, col, c = L.line, L.col, peekc(L)
    if (c == 'r' || c == 'R') && (peekc(L, 1) == '\'' || peekc(L, 1) == '"')
        local j = L.i
        adv!(L); skip_string!(L, true)
        push!(L.toks, Tok(:string, String(L.s[j:L.i-1]), line, col)); return L.toks[end]
    elseif c == '\'' || c == '"'
        local j = L.i
        skip_string!(L, false)
        push!(L.toks, Tok(:string, String(L.s[j:L.i-1]), line, col)); return L.toks[end]
    elseif isidstart(c)
        local j = L.i
        while L.i <= length(L.s) && isidchar(peekc(L))
            adv!(L)
        end
        push!(L.toks, Tok(:ident, String(L.s[j:L.i-1]), line, col)); return L.toks[end]
    elseif isdigit(c) || (c == '.' && isdigit(peekc(L, 1)))
        local j = L.i
        while L.i <= length(L.s) && (isidchar(peekc(L)) || peekc(L) == '.' && isdigit(peekc(L, 1)) ||
                                    (peekc(L) in ('+', '-') && peekc(L, -1) in ('e', 'E') && !startswith(String(L.s[j:min(j+1, end)]), "0x")))
            adv!(L)
        end
        push!(L.toks, Tok(:number, String(L.s[j:L.i-1]), line, col)); return L.toks[end]
    else
        # one punctuation character, `=>` and `...` kept whole; `>` alone so generic closers stay single
        local text = c == '=' && peekc(L, 1) == '>' ? "=>" :
                     c == '.' && peekc(L, 1) == '.' && peekc(L, 2) == '.' ? "..." :
                     c == '?' && peekc(L, 1) == '.' ? "?." : string(c)
        adv!(L, length(text))
        push!(L.toks, Tok(:punct, text, line, col)); return L.toks[end]
    end
end

function lex(src::AbstractString, file::AbstractString)::Vector{Tok}
    local L = Lexer(collect(src), 1, 1, 0, Tok[], String(file))
    while true
        skip_trivia!(L)
        L.i > length(L.s) && break
        next_tok!(L)
    end
    local depth = 0
    for t in L.toks
        t.text == "{" && (depth += 1)
        t.text == "}" && (depth -= 1)
        depth < 0 && error("skeleton: $file:$(t.line): a `}` closes nothing")
    end
    depth == 0 || error("skeleton: $file: brace depth $depth at the end of the file")
    return L.toks
end

# ---- the declarations ----------------------------------------------------------------------------
# One dart definition: its kind, its symbol (`X` for a type or a top-level definition, `X.m` for a
# member of X), the line of its name, and for a type its supertype and body's member list.
struct Decl
    kind::Symbol          # :class :abstract :mixin :enum :extension :typedef :function :getter :setter
                          # :variable :constructor :factory :method :operator :field :directive
    symbol::String
    line::Int
    modifiers::Vector{String}
    extends::String       # a class's `extends` target ("" none)
    params::Vector{Tok}   # the parameter list's tokens, without the outer parentheses
    rettype::Vector{Tok}  # the tokens before the name (return or field type); a typedef's aliased type
    implements::Vector{String}  # a class's `implements` targets, each with its prefix
    mixins::Vector{String}      # a class's `with` targets, each with its prefix
end
Decl(kind, symbol, line, modifiers, extends, params, rettype) = Decl(kind, symbol, line, modifiers, extends, params, rettype, String[], String[])
Decl(kind, symbol, line, modifiers, extends, params, rettype, impls) = Decl(kind, symbol, line, modifiers, extends, params, rettype, impls, String[])

const MODIFIERS = Set(["abstract", "sealed", "base", "final", "interface", "static", "external", "const",
                       "late", "var", "covariant", "factory", "augment"])

# the index after a balanced group opened at `i` (one of `( [ {`; `<` counts generic angles)
function close_of(toks::Vector{Tok}, i::Int, file)::Int
    local open = toks[i].text
    local closer = Dict("(" => ")", "[" => "]", "{" => "}", "<" => ">")[open]
    local depth = 0
    for j in i:length(toks)
        toks[j].text == open && (depth += 1)
        toks[j].text == closer && (depth -= 1)
        depth == 0 && return j + 1
    end
    error("skeleton: $file:$(toks[i].line): an unclosed `$open`")
end

# the end of a statement starting at `i` inside a body ending before `stop`: after its `;`, or after
# the block that is its body; `=>` and `=` make it end at the next `;` with every group balanced
function statement_end(toks::Vector{Tok}, i::Int, stop::Int, file)::Int
    local j = i
    local expr = false
    while j < stop
        local t = toks[j].text
        if t == "(" || t == "["
            j = close_of(toks, j, file); continue
        elseif t == "{"
            local k = close_of(toks, j, file)
            expr || return k
            j = k; continue
        elseif t == ";"
            return j + 1
        elseif t == "operator"
            # the operator's symbol (`==`, `[]=`, …) up to its parameter list
            while j < stop && toks[j].text != "("
                j += 1
            end
            continue
        elseif t == "=>" || t == "="
            expr = true
        elseif t == ":" && !expr
            # a constructor's initializer list: it ends at the body or `;`
            j += 1
            while j < stop && toks[j].text != ";"
                local tt = toks[j].text
                if tt == "{"
                    # the body, after a token that ends an expression; a map or set literal otherwise
                    local prev = toks[j-1]
                    (prev.kind in (:ident, :number, :string) || prev.text in (")", "]", "}", ">")) && break
                    j = close_of(toks, j, file); continue
                end
                (tt == "(" || tt == "[") ? (j = close_of(toks, j, file)) : (j += 1)
            end
            continue
        end
        j += 1
    end
    error("skeleton: $file:$(toks[i].line): a declaration that does not end")
end

# skip the metadata annotations at `i` (`@x`, `@x.y`, `@x(...)`)
function skip_metadata(toks::Vector{Tok}, i::Int, file)::Int
    while i <= length(toks) && toks[i].text == "@"
        i += 2
        while i + 1 <= length(toks) && toks[i].text == "." && toks[i+1].kind == :ident
            i += 2
        end
        i <= length(toks) && toks[i].text == "(" && (i = close_of(toks, i, file))
    end
    return i
end

# the first `(` at depth 0 in toks[a:b-1] that opens a parameter list (not a `Function(` type), or 0
function param_open(toks::Vector{Tok}, a::Int, b::Int, file)::Int
    local j = a
    while j < b
        local t = toks[j].text
        if t == "(" && j == a
            # a record type opening the declaration, `(A, B) name(…)`: a type, not the parameters
            j = close_of(toks, j, file); continue
        elseif t == "(" && !(toks[j-1].text == "Function")
            return j
        elseif t == "(" || t == "["
            j = close_of(toks, j, file); continue
        elseif t == "<"
            j = close_of(toks, j, file); continue
        elseif t == "=" || t == "=>" || t == "{" || t == ";"
            return 0
        end
        j += 1
    end
    return 0
end

# the declarations of a body toks[a:b-1]: at depth 0 of a file (container ""), or the members of type X
function declarations(toks::Vector{Tok}, a::Int, b::Int, container::String, file, out::Vector{Decl};
                      enum_body::Bool = false, on::String = "")
    local i = a
    if enum_body
        # the enum's values up to the `;` that ends them (or the body's end): data, no definitions
        while i < b && toks[i].text != ";"
            (toks[i].text == "(" || toks[i].text == "[" || toks[i].text == "{") ? (i = close_of(toks, i, file)) : (i += 1)
        end
        i += 1
    end
    while i < b
        i = skip_metadata(toks, i, file)
        i >= b && break
        local e = statement_end(toks, i, b, file)
        local n0 = length(out)
        classify!(toks, i, e, container, file, out)
        # an unnamed extension's members: their bare names (A3's anchors), the `on` type kept as owner
        if !isempty(on)
            for k in n0+1:length(out)
                local d = out[k]
                out[k] = Decl(d.kind, d.symbol, d.line, d.modifiers, on, d.params, d.rettype, d.implements, d.mixins)
            end
        end
        i = e
    end
end

function classify!(toks::Vector{Tok}, i::Int, e::Int, container::String, file, out::Vector{Decl})
    local mods = String[]
    local j = i
    local first = toks[i].text
    if container == "" && first in ("import", "export", "part", "library")
        return
    end
    while j < e && toks[j].kind == :ident && toks[j].text in MODIFIERS &&
          !(toks[j].text in ("final", "const", "var", "late") && j + 1 < e && toks[j+1].text in ("=", ";", ","))
        push!(mods, toks[j].text); j += 1
    end
    local kw = toks[j].text
    if container == "" && kw in ("class", "mixin", "enum", "extension", "typedef") ||
       container == "" && kw == "mixin" && toks[j+1].text == "class"
        kw == "mixin" && toks[j+1].text == "class" && (push!(mods, "mixin"); j += 1; kw = "class")
        local kind = kw == "class" ? (("abstract" in mods || "sealed" in mods) ? :abstract : :class) :
                     kw == "mixin" ? :mixin : kw == "enum" ? :enum : kw == "typedef" ? :typedef : :extension
        local k = j + 1
        kw == "extension" && toks[k].text == "type" && (k += 1)
        local ext = ""
        local adepth = 0   # inside a type-parameter list, `<T extends X>`, an `extends` bounds T
        for m in k:e-1
            local tt = toks[m].text
            tt == "<" ? (adepth += 1) : tt == ">" ? (adepth -= 1) : tt == ">>" ? (adepth -= 2) : nothing
            tt == "{" && break
            if adepth == 0 && (toks[m].text == "extends" || kind == :extension && toks[m].text == "on") && m + 1 < e
                ext = toks[m+1].text
                # a prefixed type, `w.X` / `ir.X` / `kernel.X`, kept with its prefix: the prefix says
                # which library declares it (resolve)
                if m + 3 < e && toks[m+2].text == "." && toks[m+3].kind == :ident
                    ext = ext * "." * toks[m+3].text
                end
                break
            end
        end
        # the `implements` and `with` targets: the identifiers (with a prefix) after the keyword and
        # before the body or the next clause, each at depth 0 of the type arguments
        local lb0 = findnext(t -> t.text == "{", toks, k)
        local targets(kw) = begin
            local out = String[]
            local ki = findnext(t -> t.text == kw, toks, k)
            if ki !== nothing && lb0 !== nothing && ki < lb0
                local depth, m = 0, ki + 1
                while m < lb0 && !(depth == 0 && toks[m].text in ("implements", "with", "on"))
                    local t = toks[m].text
                    t == "<" ? (depth += 1) : t == ">" ? (depth -= 1) : t == ">>" ? (depth -= 2) :
                    (depth == 0 && toks[m].kind == :ident && (m == ki + 1 || toks[m-1].text == ",")) &&
                        push!(out, (m + 2 < lb0 && toks[m+1].text == "." && toks[m+2].kind == :ident) ? t * "." * toks[m+2].text : t)
                    m += 1
                end
            end
            out
        end
        local impls = targets("implements")
        local mixins = kind == :enum ? String[] : targets("with")
        local unnamed = kind == :extension && !(toks[k].kind == :ident && toks[k].text != "on")
        local name = unnamed ? ext : toks[k].text
        # a typedef's aliased type: its tokens after the `=`, without the `;`
        local eq = kind == :typedef ? findnext(t -> t.text == "=", toks, k) : nothing
        local rhs = eq === nothing || eq >= e ? Tok[] : toks[eq+1:e-2]
        push!(out, Decl(kind, name, toks[k].line, mods, ext, Tok[], rhs, impls, mixins))
        if kind != :typedef
            local lb = findnext(t -> t.text == "{", toks, k)
            (lb === nothing || lb >= e) && error("skeleton: $file:$(toks[k].line): $kw $name has no body")
            local rb = close_of(toks, lb, file) - 1
            declarations(toks, lb + 1, rb, unnamed ? "" : name, file, out; enum_body = kind == :enum, on = unnamed ? ext : "")
        end
        return
    end
    local p = param_open(toks, j, e, file)
    # getter / setter / operator
    for m in j:(p == 0 ? e - 1 : p - 1)
        local t = toks[m]
        if t.kind == :ident && t.text == "operator" && m + 1 < e
            local op = ""
            local q = m + 1
            while q < e && toks[q].text != "("
                op *= toks[q].text; q += 1
            end
            local unary = op == "-" && q + 1 < e && toks[q+1].text == ")"
            push!(out, Decl(:operator, sym(container, unary ? "unary-" : op), t.line, mods, "",
                            params_of(toks, q, file), toks[j:m-1])); return
        elseif t.kind == :ident && t.text in ("get", "set") && m + 1 < e && toks[m+1].kind == :ident &&
               (m + 2 >= e || toks[m+2].text != "<" || t.text == "set") && toks[m+1].text != "("
            local kind = t.text == "get" ? :getter : :setter
            push!(out, Decl(kind, sym(container, toks[m+1].text), toks[m+1].line, mods, "",
                            kind == :setter && p != 0 ? params_of(toks, p, file) : Tok[], toks[j:m-1])); return
        end
    end
    if p != 0
        # the name before the parameter list, past any type parameters
        local q = p - 1
        toks[q].text == ">" && (q = matching_open_angle(toks, q, file) - 1)
        local nm = toks[q]
        nm.kind == :ident || error("skeleton: $file:$(nm.line): no name before a parameter list")
        if q - 2 >= j && toks[q-1].text == "." && toks[q-2].kind == :ident
            # a named constructor or factory `X.n(`
            local kind = "factory" in mods ? :factory : :constructor
            # `X.n(` inside X: the member `X.n`; at the top level (an extension's or a type's): `X.n`
            local s = isempty(container) || toks[q-2].text == container ? toks[q-2].text * "." * nm.text :
                      sym(container, toks[q-2].text * "." * nm.text)
            push!(out, Decl(kind, s, nm.line, mods, "", params_of(toks, p, file), Tok[])); return
        end
        if container != "" && nm.text == container
            local kind = "factory" in mods ? :factory : :constructor
            push!(out, Decl(kind, container, nm.line, mods, "", params_of(toks, p, file), Tok[])); return
        end
        local kind = container == "" ? :function : :method
        push!(out, Decl(kind, sym(container, nm.text), nm.line, mods, "", params_of(toks, p, file), toks[j:q-1])); return
    end
    # variables and fields: each name before `=`, `,` or `;` at depth 0
    local names = Tok[]
    local m = j
    while m < e
        local t = toks[m].text
        if t == "(" || t == "[" || t == "{" || t == "<"
            m = close_of(toks, m, file); continue
        elseif t == "=" || t == "," || t == ";"
            toks[m-1].kind == :ident && push!(names, toks[m-1])
            t == ";" && break
            if t == "="
                # skip the initializer to the next `,` or `;` at depth 0; neither names a variable
                m += 1
                while m < e && !(toks[m].text in (",", ";"))
                    (toks[m].text in ("(", "[", "{")) ? (m = close_of(toks, m, file)) : (m += 1)
                end
                (m >= e || toks[m].text == ";") && break
            end
        end
        m += 1
    end
    isempty(names) && error("skeleton: $file:$(toks[i].line): an unrecognised declaration `$(join((t.text for t in toks[i:min(e-1, i+6)]), ' '))`")
    local kind = container == "" ? :variable : :field
    for n in names
        push!(out, Decl(kind, sym(container, n.text), n.line, mods, "", Tok[], toks[j:findfirst(==(n), toks)-1]))
    end
end

sym(container::String, name::AbstractString)::String = isempty(container) ? String(name) : container * "." * name

function matching_open_angle(toks::Vector{Tok}, q::Int, file)::Int
    local depth = 0
    for m in q:-1:1
        toks[m].text == ">" && (depth += 1)
        toks[m].text == "<" && (depth -= 1)
        depth == 0 && return m
    end
    error("skeleton: $file:$(toks[q].line): an unopened `>`")
end

params_of(toks::Vector{Tok}, p::Int, file)::Vector{Tok} = toks[p+1:close_of(toks, p, file)-2]

# every declaration of a dart file, in its order
function read_dart(path::AbstractString)::Vector{Decl}
    local file = relpath(path, sdk())
    local toks = lex(read(path, String), file)
    local out = Decl[]
    declarations(toks, 1, length(toks) + 1, "", file, out)
    return out
end

# ---- the second reader: dart-format's indentation ------------------------------------------------
# The declaration lines a formatted file shows: every line at column 0 that starts a top-level
# declaration, and every line at column 2 that starts a member of a class, mixin, enum (past its
# values) or extension body; annotation and comment lines yield to the line they precede.
function indented_lines(path::AbstractString)::Vector{Int}
    local lines = split(read(path, String), '\n')
    local out = Int[]
    local body = ""          # "" top level, else the kind of the type whose body this is
    local enum_values = false
    local in_triple = false
    local wrapped = Set{Int}()
    local header_kind = ""
    for (n, l) in enumerate(lines)
        local s = rstrip(l)
        local quotes = length(collect(eachmatch(r"\"\"\"|'''", s)))
        if in_triple
            isodd(quotes) && (in_triple = false)
            continue
        end
        isodd(quotes) && (in_triple = true)
        isempty(strip(s)) && continue
        local ind = length(s) - length(lstrip(s))
        local t = lstrip(s)
        startswith(t, "//") && continue
        if body == "" && !isempty(header_kind)
            # a wrapped header's continuation lines, up to the one that opens the body
            endswith(s, "{") && (body = header_kind; enum_values = body == "enum"; header_kind = "")
            continue
        end
        if body == ""
            ind == 0 || continue
            (startswith(t, "@") || startswith(t, "}") || startswith(t, ")") || startswith(t, "]") || startswith(t, "/*")) && continue
            occursin(r"^(import|export|part|library)\b", t) && continue
            push!(out, n)
            local m = match(r"^(?:(?:abstract|sealed|base|final|interface|mixin)\s+)*(class|mixin|enum|extension)\b", t)
            if m !== nothing
                # the body opens on the header's line or on the last line of a wrapped header
                header_kind = m[1]
                endswith(s, "{") && (body = header_kind; enum_values = body == "enum"; header_kind = "")
                (endswith(s, ";") || endswith(s, "}")) && (header_kind = "")
            end
        else
            if ind == 0 && startswith(t, "}")
                body = ""; continue
            end
            ind == 2 || continue
            if enum_values
                endswith(s, ";") && (enum_values = false)
                continue
            end
            (startswith(t, "@") || startswith(t, "}") || startswith(t, ")") || startswith(t, "]") || startswith(t, "/*")) && continue
            n in wrapped && continue
            if occursin(r"(^|[^\w$])Function\($", s) || (startswith(t, "(") && !occursin(r"^\(.*\)\??\s+[\w$]+", t))
                # a function or record type wrapping the declaration: its name follows the closing `)`
                local k = n + 1
                while k <= length(lines) && !(indent_of(lines[k]) == 2 && occursin(r"^\s*\}?\)", lines[k]))
                    k += 1
                end
                k > length(lines) && error("skeleton: $path:$n: a wrapped type with no closing line")
                local close_line = rstrip(lines[k])
                local name_at = occursin(r"^\s*\}?\)\??\s*$", close_line) ? next_nonblank(lines, k) : k
                push!(out, name_at); push!(wrapped, name_at)
                continue
            end
            # a declaration whose name dart-format wrapped onto the next line at the same column: the
            # next line, which holds the name, is its line
            local nx = next_nonblank(lines, n)
            local code = code_part(s)
            if nx !== nothing && indent_of(lines[nx]) == 2 && !occursin(r"^\s*(@|//|/\*)", lines[nx]) &&
               !occursin(r"[;{},(\[=]$", code) && !endswith(code, "=>")
                push!(out, nx); push!(wrapped, nx)
            else
                push!(out, n)
            end
        end
    end
    return out
end

indent_of(l::AbstractString)::Int = length(l) - length(lstrip(l))
# a line without its trailing `//` comment (one outside a string: an even count of quotes before it)
function code_part(s::AbstractString)::String
    for m in eachmatch(r"//", s)
        local before = s[1:prevind(s, m.offset)]
        iseven(count(==('\''), before)) && iseven(count(==('"'), before)) && return rstrip(before)
    end
    return String(s)
end
function next_nonblank(lines, n::Int)
    for k in n+1:length(lines)
        isempty(strip(lines[k])) || return k
    end
    return nothing
end

# ---- the emission --------------------------------------------------------------------------------
# A3's one naming rule, src/julia/parity.jl's `snake` (its one source): its definition read from there
# and evaluated here when the generator loads, so the generator and the loader name every definition
# alike
let m = match(r"(?s)\bfunction snake(\(s::AbstractString\)::String\n.*?\nend)\n",
              read(joinpath(ROOT, "src", "julia", "parity.jl"), String))
    m === nothing && error("skeleton: src/julia/parity.jl holds no snake")
    Core.eval(@__MODULE__, Meta.parse("function snake" * m[1]))
end

# the one rule's table of dart operators and Object members that are Base functions, read from
# src/julia/parity.jl's DART_BASE (its one source)
const DART_BASE = Dict{String,String}()
function dart_base()::Dict{String,String}
    isempty(DART_BASE) || return DART_BASE
    local m = match(r"const DART_BASE = (Dict\{String,Symbol\}\((?s:.*?)\))\n", read(PARITY, String))
    m === nothing && error("skeleton: src/julia/parity.jl holds no DART_BASE")
    local ex = Meta.parse(m[1])
    Meta.isexpr(ex, :call) || error("skeleton: DART_BASE is no Dict literal")
    for p in ex.args[2:end]
        DART_BASE[p.args[2]] = string(p.args[3] isa QuoteNode ? p.args[3].value : p.args[3])
    end
    return DART_BASE
end

# ---- the modules: one per dart package, a submodule per library dart imports under a prefix ------
# read from src/julia/parity.jl's DART_MODULES (its one source; opus-a3's loader places each file by
# it): the module of a key is the first entry whose prefix the key starts with
const MODULES = Pair{String,String}[]
function dart_modules()::Vector{Pair{String,String}}
    isempty(MODULES) || return MODULES
    local m = match(r"(?s)const DART_MODULES = \((.*?)\n\)", read(PARITY, String))
    m === nothing && error("skeleton: src/julia/parity.jl holds no DART_MODULES")
    for e in eachmatch(r"\"([^\"]+)\" => \(([^)]*)\)", m[1])
        push!(MODULES, String(e[1]) => join(strip.(lstrip.(strip.(split(e[2], ',', keepempty = false)), ':')), '.'))
    end
    return MODULES
end
function module_of(key::AbstractString)::String
    for (prefix, mod) in dart_modules()
        startswith(key, prefix) && return mod
    end
    error("skeleton: $key is in no module of DART_MODULES")
end

# the scanned types: where each class, mixin and enum name is declared, and which declarations a
# scanned class extends ("<key>|<name>")
struct Scope
    where::Dict{String,Vector{String}}
    extended::Set{String}
    extension_on::Dict{String,String}
    decls::Dict{String,Vector{Decl}}
    sealed::Dict{String,Vector{Tuple{String,String}}}  # "<key>|<name>" of a sealed class => its kinds (key, name)
    excluded::Dict{String,String}  # the anchor of each declaration of an in-scope file out of scope => why
end

# a class's Julia supertype as dart spells it (with its prefix), or "": its `extends` target; with
# none, its first `implements` target declared in scope. Julia's types have one supertype, so an
# interface past the first is not one (the lead's ruling: an `implements` is modelled as the builder's
# ir.jl does, ValueType and PackedType under StorageType)
function dart_super(d::Decl, file::AbstractString)::String
    isempty(d.extends) || return d.extends
    for i in d.implements
        local p, n = split_prefix(i)
        declaring(n, p, file) === nothing || return i
    end
    return ""
end

# the module of the library whose class first declares member `m` among the dart supertypes of class
# `x` (its `extends` and `implements`, transitively; the furthest declarer is the interface), or
# nothing when no supertype declares it
function interface_module(S::Scope, file::AbstractString, x::AbstractString, m::AbstractString)::Union{Nothing,String}
    local found = nothing
    local seen = Set{String}()
    local todo = [(String(file), String(x))]
    while !isempty(todo)
        local f, c = popfirst!(todo)
        "$f|$c" in seen && continue
        push!(seen, "$f|$c")
        local d = findfirst(e -> e.symbol == c && e.kind in (:class, :abstract, :mixin), S.decls[f])
        d === nothing && continue
        local cd = S.decls[f][d]
        (c != x || f != file) && any(e -> e.symbol == "$c.$m" && !("static" in e.modifiers), S.decls[f]) && (found = module_of(f))
        for sup in vcat(isempty(cd.extends) ? String[] : [cd.extends], cd.implements)
            local p, n = split_prefix(sup)
            local k = declaring(n, p, f)
            k === nothing || push!(todo, (k, n))
        end
    end
    return found
end

# module `m`'s spelling inside module `from`: a submodule by its relative name, else its full path
spell_module(m::AbstractString, from::AbstractString)::String =
    startswith(m, from * ".") ? m[length(from)+2:end] : String(m)

# a concrete dart class another class extends: two Julia definitions, Abstract<X> and X (stub)
is_pair(S::Scope, file::AbstractString, d::Decl)::Bool = d.kind == :class && "$file|$(d.symbol)" in S.extended

# a dart sealed class: its mirror is a @closed sum of the classes that extend or implement it
is_sealed(d::Decl)::Bool = d.kind == :abstract && "sealed" in d.modifiers

# a possibly prefixed dart type name, `w.X`: its prefix ("" none) and name
function split_prefix(s::AbstractString)::Tuple{String,String}
    local i = findfirst('.', s)
    return i === nothing ? ("", String(s)) : (String(s[1:i-1]), String(s[i+1:end]))
end

# ---- the imports: a type name resolves as dart resolves it ----------------------------------------
# A library is named by its path under the sdk's pkg/ (a pin-table key, or `kernel/lib/ast.dart`) or,
# for a platform library, `dart:<name>`. Each file's directives are read from its source: an import
# brings a library's exported names into the file's scope under its prefix ("" none), filtered by its
# `show` and `hide`; an export re-exports a library's names; a part's declarations are its library's.
struct Directive
    kind::Symbol            # :import :export :part
    lib::String             # the library it names ("" for a package the checkout does not hold)
    prefix::String
    show::Vector{String}    # empty: every name
    hide::Vector{String}
end

# the library a directive's uri names, from library `from`
function lib_of_uri(uri::AbstractString, from::AbstractString)::String
    startswith(uri, "dart:") && return isfile(lib_path(uri)) ? String(uri) : ""
    local m = match(r"^package:([\w.]+)/(.+)$", uri)
    local id = m !== nothing ? "$(m[1])/lib/$(m[2])" :
               startswith(from, "dart:") ? normpath(joinpath(dirname(lib_path(from)), uri)) :
               normpath(joinpath(dirname(from), uri))
    startswith(from, "dart:") && m === nothing && (id = relpath(id, joinpath(sdk(), "sdk", "lib")))
    return isfile(lib_path(id)) ? replace(id, '\\' => '/') : ""
end

# a library's source file: a pkg/ path, a platform library's file as sdk/lib/libraries.json names it,
# or a platform part (`core/x.dart`)
lib_path(id::AbstractString)::String =
    startswith(id, "dart:") ? joinpath(sdk(), "sdk", "lib", platform_uri(id[6:end])) :
    isfile(joinpath(sdk(), "pkg", id)) ? joinpath(sdk(), "pkg", id) : joinpath(sdk(), "sdk", "lib", id)
const PLATFORM_URIS = Dict{String,String}()
platform_uri(name::AbstractString)::String = get!(() -> _platform_uri(name), PLATFORM_URIS, name)
function _platform_uri(name::AbstractString)::String
    local m = match(Regex("\"\\Q$(name)\\E\": \\{\\s*\"uri\": \"([^\"]+)\""), read(joinpath(sdk(), "sdk", "lib", "libraries.json"), String))
    return m === nothing ? "$name/$name.dart" : m[1]
end

const DIRECTIVES = Dict{String,Vector{Directive}}()
function directives(id::AbstractString)::Vector{Directive}
    haskey(DIRECTIVES, id) && return DIRECTIVES[id]
    local text = read(lib_path(id), String)
    local out = Directive[]
    for m in eachmatch(r"(?ms)^(import|export|part)\s+(['\"].*?);", text)
        local body = replace(m[2], r"//[^\n]*" => "")
        local uri = match(r"['\"]([^'\"]+)['\"]", body)
        uri === nothing && error("skeleton: $id: a directive with no uri `$(m.match)`")
        local rest = body[uri.offset+length(uri.match):end]
        # a conditional import's other uris (`if (dart.library.x) '...'`): the default is the first
        rest = replace(rest, r"if\s*\([^)]*\)\s*['\"][^'\"]+['\"]" => "")
        local pre = match(r"\bas\s+([A-Za-z_$][\w$]*)", rest)
        local names(kw) = (local k = match(Regex("\\b$kw\\s+([\\w\$,\\s]+?)(?:\\b(?:show|hide)\\b|\\z)"), rest);
                           k === nothing ? String[] : String.(strip.(split(k[1], ',', keepempty = false))))
        push!(out, Directive(Symbol(m[1]), lib_of_uri(uri[1], id), pre === nothing ? "" : pre[1], names("show"), names("hide")))
    end
    return DIRECTIVES[id] = out
end

# the type names a library's own source and parts declare at top level: classes, mixins, enums,
# typedefs and extension types (dart-format puts each at column 0)
const OWN_TYPES = Dict{String,Set{String}}()
function own_types(id::AbstractString)::Set{String}
    haskey(OWN_TYPES, id) && return OWN_TYPES[id]
    local out = Set{String}()
    local files = [lib_path(id)]
    for d in directives(id)
        d.kind == :part && !isempty(d.lib) && push!(files, lib_path(d.lib))
    end
    for f in files, l in eachline(f)
        local m = match(r"^(?:(?:abstract|sealed|base|final|interface|mixin|augment)\s+)*(?:class|mixin|enum|extension\s+type(?:\s+const)?)\s+([A-Za-z_$][\w$]*)", l)
        m === nothing && (m = match(r"^typedef\s+([A-Za-z_$][\w$]*)\s*(?:<[^=]*>)?\s*=", l))
        m === nothing && (m = match(r"^typedef\s+.*?([A-Za-z_$][\w$]*)\s*(?:<[^(]*>)?\s*\(", l))
        m === nothing || push!(out, m[1])
    end
    return OWN_TYPES[id] = out
end

# the type names a library exports: its own, then each export's (filtered), name => declaring library
const EXPORTED = Dict{String,Dict{String,String}}()
function exported(id::AbstractString)::Dict{String,String}
    haskey(EXPORTED, id) && return EXPORTED[id]
    local out = EXPORTED[id] = Dict{String,String}(n => String(id) for n in own_types(id))
    for d in directives(id)
        d.kind == :export && !isempty(d.lib) || continue
        for (n, k) in exported(d.lib)
            visible(d, n) && !haskey(out, n) && (out[n] = k)
        end
    end
    return out
end
visible(d::Directive, n::AbstractString)::Bool = (isempty(d.show) || n in d.show) && !(n in d.hide)

# the library declaring type `name` as library `from` spells it under dart prefix `prefix`, as dart
# resolves it: no prefix, `from`'s own declarations first; then every import under `prefix` that
# shows the name (dart:core implicitly, unprefixed). Two libraries refuse, as dart does, unless one is
# a platform library, which the other shadows. Nothing when no library read declares it.
function resolve(name::AbstractString, prefix::AbstractString, from::AbstractString)::Union{Nothing,String}
    prefix == "" && name in own_types(from) && return String(from)
    local found = String[]
    local imports = [d for d in directives(from) if d.kind == :import && d.prefix == prefix]
    prefix == "" && push!(imports, Directive(:import, "dart:core", "", String[], String[]))
    for d in imports
        (isempty(d.lib) || !visible(d, name)) && continue
        local k = get(exported(d.lib), name, nothing)
        k === nothing || k in found || push!(found, k)
    end
    length(found) > 1 && (found = filter(k -> !startswith(k, "dart:") && !startswith(k, "core/"), found))
    length(found) > 1 && error("skeleton: $from: `$(isempty(prefix) ? "" : prefix * ".")$name` names $(join(found, " and ")): dart refuses the ambiguity")
    return isempty(found) ? nothing : found[1]
end

# the in-scope key of the file declaring type `name` as file `from` spells it under `prefix`, or
# nothing: a type no in-scope file declares (Kernel's, the platform's, an out-of-scope file's)
function declaring(name::AbstractString, prefix::AbstractString, from::AbstractString)::Union{Nothing,String}
    local k = resolve(name, prefix, from)
    return k !== nothing && k in scope_set() ? k : nothing
end
const SCOPE_SET = Set{String}()
scope_set()::Set{String} = isempty(SCOPE_SET) ? union!(SCOPE_SET, scope()) : SCOPE_SET

# a type's Julia spelling in file `from`: bare in its own module, else qualified by its module (one
# rule, adjusted to the loader's module map when opus-a3 fixes how `w.`/`ir.` references read)
function spell(name::AbstractString, key::AbstractString, from::AbstractString)::String
    local m, f = module_of(key), module_of(from)
    return m == f ? String(name) : spell_module(m, f) * "." * name
end

# a possibly prefixed type name's Julia spelling in file `from`, or "" (external: unannotated). A
# typedef is its aliased type's, a function type's `Function`; a record typedef is its struct's
# A type no in-scope file declares is the Kernel table's (src/julia/kernel.jl) or, from a platform
# library, DART_TYPES'; one with neither refuses, as does a name that resolves nowhere and is no type
# parameter of its file, which stays unannotated (Julia's `where` is the port's)
function type_ref(S::Scope, s::AbstractString, from::AbstractString; at::AbstractString = from)::String
    isempty(s) && return ""
    local p, n = split_prefix(s)
    local r = resolve(n, p, from)
    if r === nothing
        p == "" && haskey(DART_TYPES, n) && return DART_TYPES[n]
        p == "" && n in type_params(from) && return ""
        error("skeleton: $from: the type `$s` resolves to no library dart2wasm imports, and is no type parameter")
    elseif startswith(r, "dart:")
        haskey(DART_TYPES, n) || error("skeleton: $from: the platform type $n ($r) has no row in DART_TYPES")
        return DART_TYPES[n]
    elseif !(r in scope_set())
        local row = get(kernel_types(), (r, n), nothing)
        row === nothing && error("skeleton: $from: the type $n ($r) has no row in KERNEL_TYPES (src/julia/kernel.jl)")
        push!(KERNEL_USED, (r, n))
        # a row whose types are planned (`planned: <row>`): the parameter stays unannotated until then
        return startswith(row, "planned: ") ? "" : row
    end
    local k = r
    local td = findfirst(d -> d.kind == :typedef && d.symbol == n, S.decls[k])
    if td !== nothing
        local tk = typedef_kind(S.decls[k][td])
        tk == :function && return "Function"
        tk == :alias && return julia_type(S.decls[k][td].rettype, S, k; at = at)
    end
    # dart's X, of a class another extends, is the hierarchy: Abstract<X>
    any(d -> d.symbol == n && is_pair(S, k, d), S.decls[k]) && return spell("Abstract" * n, k, at)
    return spell(n, k, at)
end

# a class's Julia supertype, its dart supertype's: none where the Kernel table says Julia has no
# counterpart (a Kernel visitor), or where it is a type Julia's hierarchy cannot extend
function super_ref(S::Scope, s::AbstractString, from::AbstractString)::String
    local r = type_ref(S, s, from)
    return r == "NoCounterpart" ? "" : r
end

# a typedef's kind: :function, a function type, which Julia spells `Function` (Julia has no arrow
# types: a callable's type is its own); :record, a record type used as data, a struct of its fields;
# :alias, another type's name, a `const` binding of its Julia type
function typedef_kind(d::Decl)::Symbol
    isempty(d.rettype) && error("skeleton: typedef $(d.symbol) at line $(d.line) aliases no type")
    d.rettype[1].text == "(" && return :record
    return is_function_type(String[t.text for t in d.rettype]) ? :function : :alias
end
# whether a dart type's tokens are a function type: `Function` outside every group
function is_function_type(ts::Vector{String})::Bool
    local depth = 0
    for t in ts
        t in ("(", "<", "[", "{") && (depth += 1)
        t in (")", ">", "]", "}") && (depth -= 1)
        depth == 0 && t == "Function" && return true
    end
    return false
end

function read_scope()::Scope
    local decls = Dict{String,Vector{Decl}}()
    local excluded = Dict{String,String}()
    for f in scope()
        local all = read_dart(dart_source(f))
        local ext_on = Dict(d.symbol => d.extends for d in all if d.kind == :extension)
        decls[f] = Decl[]
        for d in all
            local why = out_reason(f, d, ext_on)
            why === nothing ? push!(decls[f], d) : (excluded[anchor(f, d)] = why)
        end
    end
    local where, ext_on = Dict{String,Vector{String}}(), Dict{String,String}()
    for f in scope(), d in decls[f]
        d.kind in (:class, :abstract, :mixin, :enum) && push!(get!(where, d.symbol, String[]), f)
        d.kind == :extension && (ext_on[d.symbol] = d.extends)
    end
    local extended = Set{String}()
    for f in scope(), d in decls[f]
        local sup = d.kind in (:class, :abstract, :mixin) ? dart_super(d, f) : ""
        isempty(sup) && continue
        local p, n = split_prefix(sup)
        local k = declaring(n, p, f)
        k === nothing || push!(extended, "$k|$n")
    end
    # a sealed class's kinds: the in-scope classes that extend or implement it, in the pin table's order.
    # An abstract class that is a kind of a closed sum is one too, of its own subclasses: dart2wasm's
    # library declares every subclass, so WasmTarget's closed world holds them all
    local subs = Dict{String,Vector{Tuple{String,String}}}()
    for f in scope(), d in decls[f]
        d.kind in (:class, :abstract, :mixin) || continue
        for sup in vcat(isempty(d.extends) ? String[] : [d.extends], d.implements)
            local p, n = split_prefix(sup)
            local k = declaring(n, p, f)
            k === nothing || push!(get!(subs, "$k|$n", Tuple{String,String}[]), (f, d.symbol))
        end
    end
    local sealed = Dict{String,Vector{Tuple{String,String}}}()
    local todo = ["$f|$(d.symbol)" for f in scope() for d in decls[f] if is_sealed(d)]
    local kind_of = Dict((f, d.symbol) => d for f in scope() for d in decls[f] if d.kind in (:class, :abstract, :mixin))
    while !isempty(todo)
        local c = popfirst!(todo)
        haskey(sealed, c) && continue
        sealed[c] = get(subs, c, Tuple{String,String}[])
        for (f, n) in sealed[c]
            local d = kind_of[(f, n)]
            d.kind == :abstract && haskey(subs, "$f|$n") && push!(todo, "$f|$n")
        end
    end
    return Scope(where, extended, ext_on, decls, sealed, excluded)
end

# a dart type's tokens, as file `from` resolves them, as a Julia type spelled in file `at`, or ""
# (unannotated) where no row of the table covers it
# the platform's types (dart:core, dart:typed_data, dart:_internal) and the language's own (void,
# dynamic, Never), each with its Julia type; DART_GENERIC's take their arguments
const DART_TYPES = Dict("int" => "Int64", "double" => "Float64", "bool" => "Bool", "String" => "String",
                        "num" => "Real", "void" => "Nothing", "Object" => "Any", "dynamic" => "Any",
                        "Function" => "Function", "Null" => "Nothing", "Never" => "Union{}", "Type" => "Type",
                        "Uri" => "String", "StringSink" => "IO", "StringBuffer" => "IOBuffer",
                        "Uint8List" => "Vector{UInt8}", "BytesBuilder" => "IOBuffer",
                        "List" => "Vector", "Set" => "Set", "Map" => "Dict", "Iterable" => "AbstractVector")
const DART_GENERIC = Set(["List", "Set", "Map", "Iterable"])

# the Kernel table, src/julia/kernel.jl's KERNEL_TYPES: (library, name) => Julia type
const KERNEL = Dict{Tuple{String,String},String}()
const KERNEL_USED = Set{Tuple{String,String}}()
function kernel_types()::Dict{Tuple{String,String},String}
    isempty(KERNEL) || return KERNEL
    local m = match(r"(?s)const KERNEL_TYPES = (\(\n.*?\n\))", read(joinpath(ROOT, "src", "julia", "kernel.jl"), String))
    m === nothing && error("skeleton: src/julia/kernel.jl holds no KERNEL_TYPES")
    for p in Meta.parse(m[1]).args
        KERNEL[(p.args[2].args[1], p.args[2].args[2])] = p.args[3].args[1]
    end
    return KERNEL
end
# the rows no definition's stub names (each in-scope definition stubbed, filled or not): a row is a type
# an in-scope file names, so a row nothing names is stale
function unused_kernel_rows(S)::Vector{String}
    for f in scope(), d in S.decls[f]
        counted(d) && stub(f, d, S, Decl[])
    end
    return sort(["$(k[1]) $(k[2])" for k in keys(kernel_types()) if !(k in KERNEL_USED)])
end

# the names a dart file declares as type parameters (each identifier opening or continuing a `<...>`
# list): a type that resolves nowhere is one only if it is among them
const TPARAMS = Dict{String,Set{String}}()
function type_params(key::AbstractString)::Set{String}
    haskey(TPARAMS, key) && return TPARAMS[key]
    local toks = lex(read(dart_source(key), String), key)
    local out = Set{String}()
    for i in 2:length(toks)
        toks[i].kind == :ident && toks[i-1].text in ("<", ",") && i + 1 <= length(toks) &&
            toks[i+1].text in (",", ">", "extends") && push!(out, toks[i].text)
    end
    return TPARAMS[key] = out
end
function julia_type(toks::AbstractVector{Tok}, S::Scope, from::AbstractString; at::AbstractString = from, exact::Bool = false)::String
    isempty(toks) && return ""
    local ts = [t.text for t in toks if !(t.kind == :ident && t.text in ("final", "const", "covariant", "required", "late", "var"))]
    isempty(ts) && return ""
    local nullable = ts[end] == "?"
    nullable && (ts = ts[1:end-1])
    local j = julia_type_strs(ts, S, from, at, exact)
    isempty(j) && return ""
    return nullable ? "Union{Nothing,$j}" : j
end
# `exact` keeps an in-scope generic class's arguments (a typedef's alias names its instance); a
# parameter's annotation names the class, its arguments dropped, as a stub cannot be parametric
function julia_type_strs(ts::Vector{String}, S::Scope, from::AbstractString, at::AbstractString = from, exact::Bool = false)::String
    isempty(ts) && return ""
    if ts[end] == "?"
        local j = julia_type_strs(ts[1:end-1], S, from, at, exact)
        return isempty(j) ? "" : "Union{Nothing,$j}"
    end
    # a prefixed type, `w.X` / `ir.X` / `kernel.X`
    local prefix = ""
    if length(ts) >= 3 && ts[2] == "." && occursin(r"^[A-Za-z_$][\w$]*$", ts[1])
        prefix = ts[1]; ts = ts[3:end]
    end
    is_function_type(ts) && return "Function"
    ts[1] == "(" && ts[end] == ")" && return record_type(ts[2:end-1], S, from, at)
    local head = ts[1]
    if length(ts) == 1
        return type_ref(S, isempty(prefix) ? head : "$prefix.$head", from; at = at)
    end
    if ts[2] == "<" && ts[end] == ">"
        local args = split_args(ts[3:end-1])
        local jargs = [julia_type_strs(a, S, from, at) for a in args]
        local r = type_ref(S, isempty(prefix) ? head : "$prefix.$head", from; at = at)
        local lib = resolve(head, prefix, from)
        # a platform collection takes its arguments; one a type parameter leaves unannotated is the
        # collection of any element, its UnionAll
        if lib !== nothing && startswith(lib, "dart:") && head in DART_GENERIC
            return any(isempty, jargs) ? r : "$r{$(join(jargs, ','))}"
        end
        return exact && !isempty(r) && !any(isempty, jargs) ? "$r{$(join(jargs, ','))}" : r
    end
    error("skeleton: $from: the dart type `$(join(ts, ' '))` has no Julia translation")
end
# a dart record type's fields, as a Julia Tuple type (positional) or NamedTuple type (named); a field
# a type parameter leaves unannotated makes the record any Tuple or NamedTuple of its names
function record_type(ts::Vector{String}, S::Scope, from::AbstractString, at::AbstractString)::String
    local field(f) = (local nl = f[end] == "?"; local g = nl ? f[1:end-1] : f;
                      local j = julia_type_strs(g, S, from, at); isempty(j) ? "" : nl ? "Union{Nothing,$j}" : j)
    # a field's type, past its name: the last identifier, unless the field is the type alone
    local typeof_(f) = length(f) > 1 && occursin(r"^[A-Za-z_$][\w$]*$", f[end]) && !(f[end-1] in (".", "<", ",")) ? f[1:end-1] : f
    if !isempty(ts) && ts[1] == "{" && ts[end] == "}"
        local fs = filter(!isempty, split_args(ts[2:end-1]))
        local names = [jname(f[end]) for f in fs]
        local types = [field(f[1:end-1]) for f in fs]
        local tup = "(" * join((":" * n for n in names), ", ") * (length(names) == 1 ? ",)" : ")")
        return any(isempty, types) ? "NamedTuple{$tup}" : "NamedTuple{$tup, Tuple{$(join(types, ", "))}}"
    end
    "{" in ts && error("skeleton: $from: a record type with positional and named fields `($(join(ts, ' ')))` has no Julia type")
    local types = [field(typeof_(f)) for f in filter(!isempty, split_args(ts))]
    return any(isempty, types) ? "Tuple" : "Tuple{$(join(types, ", "))}"
end

function split_args(ts::Vector{String})::Vector{Vector{String}}
    local out, cur, depth = Vector{String}[], String[], 0
    for t in ts
        t in ("<", "(", "[", "{") && (depth += 1)
        t in (">", ")", "]", "}") && (depth -= 1)
        if t == "," && depth == 0
            push!(out, cur); cur = String[]
        else
            push!(cur, t)
        end
    end
    push!(out, cur)
    return out
end

# one dart parameter: its name, its Julia type and its section (:required, :optional, :named)
struct Param
    name::String
    jtype::String
    dart::String
    section::Symbol
    required::Bool
    default::Vector{Tok}   # the tokens after `=` (or the old `:`), none when dart gives no default
end

function params(ps::Vector{Tok}, S::Scope, from::AbstractString)::Vector{Param}
    local out = Param[]
    local section = :required
    local cur = Tok[]
    local flush!() = begin
        if !isempty(cur)
            local depth = 0
            local head = Tok[]
            # the name: the last identifier before `=` or `:` at depth 0 (a default follows)
            for t in cur
                (t.text in ("=", ":") && depth == 0) && break
                t.text in ("(", "<", "[") && (depth += 1)
                t.text in (")", ">", "]") && (depth -= 1)
                push!(head, t)
            end
            local idx = findlast(t -> t.kind == :ident, head)
            if idx !== nothing
                local nm = head[idx].text
                local tys = head[1:idx-1]
                local req = any(t -> t.text == "required", tys)
                local dflt = length(head) < length(cur) ? cur[length(head)+2:end] : Tok[]
                # a field or super initializer (`this.x`, `super.x`) takes its field's type: unannotated
                local jt = any(t -> t.text in ("this", "super"), tys) ? "" : julia_type(tys, S, from)
                push!(out, Param(nm, jt, join((t.text for t in cur), " "), section, req, dflt))
            end
        end
        empty!(cur)
    end
    local depth = 0
    for t in ps
        if depth == 0 && t.text in ("[", "{")
            flush!(); section = t.text == "[" ? :optional : :named; continue
        elseif depth == 0 && t.text in ("]", "}")
            flush!(); continue
        elseif depth == 0 && t.text == ","
            flush!(); continue
        end
        t.text in ("(", "<", "[", "{") && (depth += 1)
        t.text in (")", ">", "]", "}") && (depth -= 1)
        push!(cur, t)
    end
    flush!()
    return out
end

# a Julia identifier for a dart parameter name (`this.x` a field initializer: `x`)
jname(n::AbstractString)::String = (local s = snake(n); s in ("end", "function", "type", "global", "local", "begin", "module", "struct", "do", "try", "catch", "quote", "let", "const", "return", "for", "while", "if", "else", "elseif", "import", "using", "export", "macro", "abstract", "primitive", "mutable", "baremodule", "finally", "break", "continue", "outer") ? s * "_" : s)

# the Julia parameter list of a stub: `self` first for an instance member, the required parameters
# typed, the optional positional ones collected (`optional...`), the named ones as keywords
function signature(d::Decl, owner::AbstractString, S::Scope, from::AbstractString; self::Bool)::String
    local ps = params(d.params, S, from)
    local parts = String[]
    local ot = type_ref(S, owner, from)
    self && push!(parts, isempty(ot) ? "self" : "self::$ot")
    for p in ps
        p.section == :required || continue
        push!(parts, isempty(p.jtype) ? jname(p.name) : "$(jname(p.name))::$(p.jtype)")
    end
    any(p -> p.section == :optional, ps) && push!(parts, "optional...")
    local named = [p for p in ps if p.section == :named]
    local s = join(parts, ", ")
    if !isempty(named)
        s *= "; " * join((named_param(p) for p in named), ", ")
    end
    return s
end

# a named parameter as a Julia keyword: typed where dart's type translates, with dart's default where
# it translates (a literal, an empty collection of the parameter's type), `nothing` where dart's is
# its implicit null (a nullable or untyped parameter with none), and no default otherwise (required)
function named_param(p::Param)::String
    local n = isempty(p.jtype) ? jname(p.name) : "$(jname(p.name))::$(p.jtype)"
    p.required && return n
    local nullable = isempty(p.jtype) || startswith(p.jtype, "Union{Nothing,")
    isempty(p.default) && return nullable ? "$n = nothing" : n
    local v = julia_default(p.default, p.jtype)
    return v === nothing ? n : "$n = $v"
end

# a dart default value's Julia spelling, or nothing where it does not translate
function julia_default(ts::Vector{Tok}, jtype::AbstractString)::Union{Nothing,String}
    local xs = [t.text for t in ts if !(t.kind == :ident && t.text == "const")]
    length(xs) == 2 && xs[1] == "-" && ts[end].kind == :number && return "-" * xs[2]
    length(xs) == 1 || return (xs in (["[", "]"], ["{", "}"]) && occursin(r"^(Vector|Dict|Set)\{", jtype)) ? "$jtype()" : nothing
    local x, t = xs[1], ts[end]
    x in ("true", "false") && return x
    x == "null" && return "nothing"
    t.kind == :number && return occursin(r"^(0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][+-]?\d+)?)$", x) ? x : nothing
    if t.kind == :string
        # a plain single-line literal: no interpolation, no escape but a quote's
        local m = match(r"^(['\"])((?:[^'\"\\$]|\\['\"])*)\1$", x)
        m === nothing && return nothing
        local body = replace(m[2], "\\'" => "'", "\\\"" => "\"")
        return repr(body)
    end
    return nothing
end

# the Julia name of a dart symbol under A3's rule, and whether the member takes `self`
function julia_name(d::Decl)::Tuple{String,Bool}
    local parts = split(d.symbol, '.'; limit = 2)
    if length(parts) == 1
        d.kind in (:class, :abstract, :mixin, :enum, :typedef, :constructor, :factory) && return (d.symbol, false)
        # a member of an unnamed extension: its bare name, `self` its `on` type
        local member = d.kind in (:method, :getter, :setter, :operator) || (!isempty(d.extends) && d.kind in (:function, :variable))
        d.kind == :setter && return ("set_$(snake(d.symbol))!", true)
        return (snake(d.symbol), member && !isempty(d.extends) && !("static" in d.modifiers))
    end
    local x, m = parts
    local static = "static" in d.modifiers
    local base = dart_base()
    # an operator, toString or hashCode: the Base function DART_BASE names, the rule's one name
    haskey(base, m) && !static && return (base[m], true)
    d.kind in (:constructor, :factory) && return ("$(x)_$(snake(m))", false)
    d.kind == :setter && return ("set_$(snake(m))!", !static)
    static && return ("$(x)_$(snake(m))", false)
    return (snake(m), true)
end

const JULIA_KEYWORDS = Set(["end", "function", "global", "local", "begin", "module", "struct", "do", "try",
    "catch", "quote", "let", "const", "return", "for", "while", "if", "else", "elseif", "import", "using",
    "export", "macro", "abstract", "primitive", "mutable", "baremodule", "finally", "break", "continue",
    "outer", "public", "true", "false"])

# a Julia function name that Base exports is extended as Base.<name>, as A3's rule admits; a name that
# is a Julia keyword is written var"name", the name the rule wants
function qualified(name::String)::String
    name in JULIA_KEYWORDS && return "var\"$name\""
    local s = Symbol(rstrip(name, '!') == name ? name : name)
    (isdefined(Base, s) && Base.isexported(Base, s)) || return occursin(r"^[\w!]+$", name) ? name : "Base.:($name)"
    return occursin(r"^[\w!]+$", name) ? "Base.$name" : "Base.:($name)"
end

anchor(file::String, d::Decl)::String = "$file:$(d.line) $(d.symbol)"

# the stub of one declaration
function stub(file::String, d::Decl, S::Scope, fields::Vector{Decl})::String
    local a = anchor(file, d)
    if d.kind == :typedef
        typedef_kind(d) == :record && return "@parity \"$a\" @unported struct $(d.symbol) end"
        return "@parity \"$a\" const $(d.symbol) = $(julia_type(d.rettype, S, file; exact = true))"
    end
    if d.kind in (:class, :abstract, :mixin) && haskey(S.sealed, "$file|$(d.symbol)")
        local kinds = S.sealed["$file|$(d.symbol)"]
        return "@parity \"$a\" @closed const $(d.symbol) = Union{" * join((spell(n, k, file) for (k, n) in kinds), ", ") * "}"
    end
    if d.kind in (:class, :abstract, :mixin)
        local sup = dart_super(d, file)
        local sp = super_ref(S, sup, file)
        # a sealed class's kind subtypes nothing: the sum names it
        local p, n = split_prefix(sup)
        local sk = isempty(sup) ? nothing : declaring(n, p, file)
        sk !== nothing && haskey(S.sealed, "$sk|$n") && (sp = "")
        local super = isempty(sp) ? "" : " <: $sp"
        d.kind != :class && return "@parity \"$a\" abstract type $(d.symbol)$super end"
        local doc = isempty(fields) ? "" :
            "\"\"\"\n$(d.symbol)'s dart fields: " * join(("`$(f.symbol[length(d.symbol)+2:end])`" for f in fields), ", ") * ".\n\"\"\"\n"
        # a concrete class another extends: Julia's own shape (AbstractArray and Array), the hierarchy
        # abstract type Abstract<X> and X the struct of dart's own instances, both at X's line
        if is_pair(S, file, d)
            return "@parity \"$a\" abstract type Abstract$(d.symbol)$super end\n\n" *
                   doc * "@parity \"$a\" @unported struct $(d.symbol) <: Abstract$(d.symbol) end"
        end
        return doc * "@parity \"$a\" @unported struct $(d.symbol)$super end"
    elseif d.kind == :enum
        return "@parity \"$a\" @enum $(d.symbol) " * join(("$(d.symbol)_$(v)" for v in enum_values(file, d)), " ")
    end
    local name, self = julia_name(d)
    local owner = occursin('.', d.symbol) ? split(d.symbol, '.')[1] :
                  (d.kind in (:class, :abstract, :mixin, :enum) ? "" : d.extends)
    # a named extension's members take its `on` type
    haskey(S.extension_on, owner) && (owner = S.extension_on[owner])
    local ot = type_ref(S, owner, file)
    local sig = d.kind in (:getter, :field, :variable) ? (self ? (isempty(ot) ? "self" : "self::$ot") : "") :
                signature(d, owner, S, file; self = self)
    # toString and hashCode take Julia's own signatures, show(io, x) and hash(x, h), so a lane fills them
    local member = occursin('.', d.symbol) ? split(d.symbol, '.'; limit = 2)[2] : ""
    if !isempty(ot) && !("static" in d.modifiers)
        member == "toString" && (sig = "io::IO, self::$ot")
        member == "hashCode" && (sig = "self::$ot, h::UInt")
    end
    # Serializable.serialize and its implementations take the serializer first, as Julia's
    # write(io, x) and the builder lane's port do (its filled files win; the stubs agree with them)
    if member == "serialize" && self
        local m2 = match(r"^(self::[^,]+), (s::.+)$", sig)
        m2 === nothing || (sig = m2[2] * ", " * m2[1])
    end
    local fname = d.kind in (:constructor, :factory) ? name : qualified(name)
    # a member is its package's one generic function, dispatching on the receiver as dart's members do:
    # a member in a library module (IR, Util, JS) is a method of the package module's function, and
    # an interface member another package declares is that package's (the lead's ruling:
    # Serializable.serialize is WasmBuilder.serialize, its implementations its methods)
    if !startswith(fname, "Base.") && self && d.kind in (:method, :getter, :setter, :operator)
        local own = module_of(file)
        local pkg = String(first(split(own, '.')))
        local om = occursin('.', d.symbol) ? interface_module(S, file, String(split(d.symbol, '.')[1]), member) : nothing
        local target = (om === nothing || first(split(om, '.')) == pkg) ? pkg : om
        target == own || (fname = spell_module(target, own) * "." * fname)
    end
    if startswith(fname, "Base.") && occursin('.', d.symbol)
        # a Base builtin takes no methods, and a Base function's method with an untyped first argument
        # would overwrite Base's own: the rule's other name for `X.m`, `X_snake(m)`
        local s = Symbol(name)
        local typed = occursin(r"(^|, )self::", sig)
        if (isdefined(Base, s) && getglobal(Base, s) isa Core.Builtin) || !typed
            local x, m = split(d.symbol, '.'; limit = 2)
            fname = "$(x)_$(snake(m))"
        end
    end
    return "@parity \"$a\" @unported function $fname($sig) end"
end

# an enum's value names, in order: the first identifier of each item before the `;` or `}` closing them
enum_values(file::String, d::Decl)::Vector{String} = String[v for (v, _) in enum_value_lines(file, d)]

# a file's counted declarations in the order its skeleton holds them: the type declarations first (two
# passes load them before any signature names them), then every other definition, each in dart's order
is_type(d::Decl)::Bool = d.kind in (:class, :abstract, :mixin, :enum) || d.kind == :typedef && typedef_kind(d) == :record
ordered(ds::Vector{Decl})::Vector{Decl} = vcat(filter(d -> counted(d) && is_type(d), ds), filter(d -> counted(d) && !is_type(d), ds))

# the dart fields of class d, listed in its stub's docstring
fields_of(d::Decl, ds::Vector{Decl})::Vector{Decl} =
    d.kind == :class ? [f for f in ds if f.kind == :field && !("static" in f.modifiers) && startswith(f.symbol, d.symbol * ".")] : Decl[]

const HEADER = "# parity(%s): generated by dev/skeleton.jl from the pinned commit; a filled definition\n# replaces its stub in place, and the generator never touches it again."

# the Julia source a fresh dart file's skeleton is: its header, then every declaration's stub
function render(file::String, S::Scope)::String
    local ds = S.decls[file]
    local io = IOBuffer()
    print(io, replace(HEADER, "%s" => file))
    for d in ordered(ds)
        print(io, "\n\n", stub(file, d, S, fields_of(d, ds)))
    end
    println(io)
    return String(take!(io))
end

# ---- the merge: a re-run never touches a filled definition ---------------------------------------
# One top-level definition of an existing Julia file: its lines (its leading comment lines with it),
# its @parity anchor ("" when it carries none) and whether it is still @unported.
struct Segment
    first::Int
    last::Int
    anchor::String
    unported::Bool
    text::String
end

# the @parity anchor of a top-level expression and whether its definition is @unported
function parity_of(ex)::Tuple{String,Bool}
    Meta.isexpr(ex, :macrocall) || return ("", false)
    local name = ex.args[1]
    local nm = name isa Symbol ? name : name isa GlobalRef ? name.name : Meta.isexpr(name, :.) ? name.args[end].value : nothing
    if nm === Symbol("@doc")
        return parity_of(ex.args[end])
    elseif nm === Symbol("@parity")
        local def = ex.args[end]
        local unp = Meta.isexpr(def, :macrocall) && (def.args[1] === Symbol("@unported") ||
                                                    def.args[1] isa GlobalRef && def.args[1].name === Symbol("@unported"))
        return (ex.args[end-1] isa String ? ex.args[end-1] : "", unp)
    end
    return ("", false)
end

# whether a definition is the generator's to write: an @unported stub, or a declaration the generator
# writes complete, a mirror abstract type, a @closed sum or an @enum (a lane that replaces one writes another form,
# which is kept)
generated(s::Segment)::Bool = s.unported ||
    occursin(r"^@parity \"[^\"]+\" (abstract type \S+( <: \S+)? end|@enum [^\n]+|@closed const \S+ = Union\{[^\n]+\})$", s.text)

# a Julia file's preamble (the lines before its first definition) and its definitions
function segments(text::AbstractString, file::AbstractString)::Tuple{String,Vector{Segment}}
    local lines = split(text, '\n')
    local top = Meta.parseall(text; filename = String(file))
    local starts = Tuple{Int,Any}[]
    local pending = 0
    for a in top.args
        if a isa LineNumberNode
            pending = a.line
        elseif !(a isa Nothing)
            push!(starts, (pending, a))
        end
    end
    # a definition owns the comment lines directly above it
    local lead(n) = (local k = n; while k > 1 && startswith(lstrip(lines[k-1]), "#") && !isempty(strip(lines[k-1])); k -= 1; end; k)
    local firsts = [lead(s) for (s, _) in starts]
    local out = Segment[]
    for (i, (s, ex)) in enumerate(starts)
        local stop = i < length(starts) ? firsts[i+1] - 1 : length(lines)
        while stop > s && (isempty(strip(lines[stop])) || startswith(lstrip(lines[stop]), "#"))
            stop -= 1
        end
        local a, u = parity_of(ex)
        push!(out, Segment(firsts[i], stop, a, u, join(lines[firsts[i]:stop], '\n')))
    end
    local preamble = isempty(out) ? text : join(lines[1:out[1].first-1], '\n')
    return (rstrip(preamble), out)
end

# the Julia file of a pin-table key: src/julia/parity.jl's `_jl_rel`, its pattern read from there
function jl_file(key::String)::String
    local m = match(r"function _jl_rel\(dart::String\)::String\n(?s:.*?)\n\s*local m = match\(r\"(.+?)\", dart\)", read(PARITY, String))
    m === nothing && error("skeleton: src/julia/parity.jl holds no _jl_rel")
    local k = match(Regex(m[1]), key)
    k === nothing && error("skeleton: $key is no path _jl_rel maps")
    return joinpath(ROOT, "src", something(k[1], "") * k[2] * ".jl")
end

# an anchor in the pin-table form: a short form (opus-builder's `src/ir/type.dart:26 X`, a path under
# wasm_builder/lib; or a path under dart2wasm/lib) rewritten to its DART_FILES key; "" for no anchor
function canonical_anchor(a::AbstractString, keys::Set{String})::String
    isempty(a) && return ""
    local m = match(r"^([\w/]+\.dart):(\d+) (.+)$", a)
    m === nothing && return String(a)
    m[1] in keys && return String(a)
    for k in ("wasm_builder/lib/" * m[1], "wasm_builder/lib/src/" * m[1], "dart2wasm/lib/" * m[1])
        k in keys && return "$k:$(m[2]) $(m[3])"
    end
    return String(a)
end

# every anchor src defines outside src/julia, in the pin-table form: anchor => (Julia file, @unported)
function src_anchors()::Dict{String,Tuple{String,Bool}}
    local out = Dict{String,Tuple{String,Bool}}()
    local srcdir = joinpath(ROOT, "src")
    local keys = Set(scope())
    local abstract_seen = Set{String}()   # anchors whose abstract type a segment holds
    for (dir, _, files) in walkdir(srcdir), f in files
        endswith(f, ".jl") || continue
        local path = joinpath(dir, f)
        startswith(path, joinpath(srcdir, "julia")) && continue
        path == joinpath(srcdir, "WasmTarget.jl") && continue
        for s in last(segments(src_text(path), path))
            local a = canonical_anchor(s.anchor, keys)
            isempty(a) && continue
            local isabs = occursin(r"^@parity \"[^\"]+\" abstract type "m, s.text)
            local pair_seen = isabs != (a in abstract_seen) ? Set([a]) : Set{String}()
            isabs && push!(abstract_seen, a)
            if haskey(out, a)
                # one dart definition may take several filled Julia definitions (a struct and its
                # default constructor); a filled one wins over a stub, which goes; two stubs refuse
                # a pair's abstract type beside its struct stub is two parts of one definition
                (out[a][2] && generated(s) && !(a in pair_seen)) && error("skeleton: $a is stubbed twice: $(out[a][1]) and $path")
                generated(s) && continue
                out[a][2] || continue
            end
            out[a] = (path, generated(s))
        end
    end
    return out
end

# the Julia source a dart file's skeleton is, merged with the file src already holds. The file keeps
# its layout: a filled definition stays verbatim where it is (its short anchor rewritten to the key), an
# @unported one is regenerated in place, and a declaration src defines nowhere gets its stub after the
# nearest earlier declaration the file holds (at its head when none). An anchor naming no dart
# declaration at the pin, or a definition with no anchor, refuses.
function generate(file::String, S::Scope, anchors::Dict{String,Tuple{String,Bool}}, bykey::Dict{String,Tuple{String,Decl}})::String
    local path = jl_file(file)
    isfile(path) || return render(file, S)
    local preamble, segs = segments(src_text(path), path)
    local keys = Set(scope())
    local texts = String[]
    local held = String[]       # each output entry's anchor, in order
    local parts = Dict{String,Vector{Symbol}}()   # a pair's parts the output holds (:abstract, :struct)
    for s in segs
        local a = canonical_anchor(s.anchor, keys)
        isempty(a) && error("skeleton: $path:$(s.first): a definition with no @parity anchor")
        # a stub of a definition out of scope goes; a filled one refuses, its port out of scope
        if !haskey(bykey, a) && haskey(S.excluded, a)
            generated(s) && continue
            error("skeleton: $path:$(s.first): $(s.anchor) is filled, but it is out of scope: $(S.excluded[a])")
        end
        haskey(bykey, a) || error("skeleton: $path:$(s.first): $(s.anchor) names no declaration at the pin")
        local f, d = bykey[a]
        # a typedef's alias is the generator's to write: the `const` of its Julia type
        local gen = generated(s) || d.kind == :typedef && typedef_kind(d) == :alias
        # a stub whose definition another file fills goes
        (gen && haskey(anchors, a) && !anchors[a][2] && anchors[a][1] != path) && continue
        local text = gen ? stub(f, d, S, fields_of(d, S.decls[f])) :
                     a == s.anchor ? s.text : replace(s.text, "\"" * s.anchor * "\"" => "\"" * a * "\""; count = 1)
        if is_pair(S, f, d)
            # one of a pair's two parts: its abstract type, or its struct (a stub, or filled)
            local part = occursin(r"^@parity \"[^\"]+\" abstract type "m, s.text) ? :abstract : :struct
            local both = split(stub(f, d, S, fields_of(d, S.decls[f])), "\n\n"; limit = 2)
            gen && (text = part == :abstract ? both[1] : both[2])
            push!(get!(parts, a, Symbol[]), part)
        end
        push!(texts, text); push!(held, a)
    end
    # a pair holding one part gains the other beside it: the abstract type before the struct
    for (a, ps) in parts
        length(ps) == 1 || continue
        local f, d = bykey[a]
        local both = split(stub(f, d, S, fields_of(d, S.decls[f])), "\n\n"; limit = 2)
        local k = findfirst(==(a), held)
        ps[1] == :abstract ? (insert!(texts, k + 1, both[2]); insert!(held, k + 1, a)) :
                             (insert!(texts, k, both[1]); insert!(held, k, a))
    end
    local order = ordered(S.decls[file])
    for (i, d) in enumerate(order)
        local a = anchor(file, d)
        (a in held || haskey(anchors, a)) && continue
        # after the nearest earlier declaration of this file the output holds
        local at = 0
        for j in i-1:-1:1
            local k = findfirst(==(anchor(file, order[j])), held)
            k === nothing || (at = k; break)
        end
        insert!(texts, at + 1, stub(file, d, S, fields_of(d, S.decls[file])))
        insert!(held, at + 1, a)
    end
    local head = isempty(preamble) ? replace(HEADER, "%s" => file) : preamble
    return isempty(texts) ? head * "\n" : head * "\n\n" * join(texts, "\n\n") * "\n"
end

# every declaration at the pin by its anchor: anchor => (key, declaration). An instance field is one
# too: a filled accessor may anchor at it, though the generator stubs none (a field is its struct's);
# so is an enum's value, which a filled enum that is a struct (dart's enum with fields and a mixin,
# V128Instruction) defines as a constant anchored at its line
function by_anchor(S::Scope)::Dict{String,Tuple{String,Decl}}
    local out = Dict(anchor(f, d) => (f, d) for f in scope() for d in S.decls[f] if counted(d) || d.kind == :field)
    # an export directive declares no name; a port anchors it by the word `export` at its first line
    for f in scope(), (i, l) in enumerate(eachline(dart_source(f)))
        startswith(l, "export '") || continue
        local e = Decl(:directive, "export", i, String[], "", Tok[], Tok[])
        out[anchor(f, e)] = (f, e)
    end
    for f in scope(), d in S.decls[f]
        d.kind == :enum || continue
        for (v, line) in enum_value_lines(f, d)
            local e = Decl(:enumvalue, "$(d.symbol).$v", line, String[], "", Tok[], Tok[])
            out[anchor(f, e)] = (f, e)
        end
    end
    return out
end

# an enum's values, each with its line
function enum_value_lines(file::String, d::Decl)::Vector{Tuple{String,Int}}
    local toks = lex(read(dart_source(file), String), file)
    local k = findfirst(i -> toks[i].text == "enum" && i < length(toks) && toks[i+1].text == d.symbol && toks[i+1].line == d.line, eachindex(toks))
    k === nothing && error("skeleton: $file:$(d.line): enum $(d.symbol) not found")
    local i = findnext(t -> t.text == "{", toks, k) + 1
    local out, expect = Tuple{String,Int}[], true
    while i <= length(toks) && !(toks[i].text in (";", "}"))
        local t = toks[i].text
        if t in ("(", "[", "{", "<")
            i = close_of(toks, i, file); continue
        elseif t == "@"
            i = skip_metadata(toks, i, file); continue
        elseif t == ","
            expect = true
        elseif expect && toks[i].kind == :ident
            push!(out, (t, toks[i].line)); expect = false
        end
        i += 1
    end
    return out
end

# write every in-scope file's skeleton (only files that change are written)
function write_main()::Int
    local S = read_scope()
    local anchors = src_anchors()
    local bykey = by_anchor(S)
    local n = 0
    for f in scope()
        local text = generate(f, S, anchors, bykey)
        local path = jl_file(f)
        (isfile(path) && read(path, String) == text) && continue
        mkpath(dirname(path))
        write(path, text)
        n += 1
    end
    println("skeleton: $n file(s) written")
    local stale = unused_kernel_rows(S)
    isempty(stale) || error("skeleton: KERNEL_TYPES rows no in-scope file names: $(join(stale, ", "))")
    return 0
end

# the no-diff check: every in-scope file is exactly what the generator writes (a hand-edited stub, a
# missing stub or a filled definition out of dart's order differs)
# src's text of a file, read through SRC_READ, which the ratchet's plants replace (L210)
const SRC_READ = Ref{Function}(p -> read(p, String))
src_text(path::AbstractString)::String = SRC_READ[](path)

# whether in-scope file `f` is missing or differs from what the generator writes, or nothing
function file_fault(f::String, S::Scope, anchors, bykey)::Union{Nothing,String}
    local path = jl_file(f)
    isfile(path) || return "$(relpath(path, ROOT)) is missing"
    local text = generate(f, S, anchors, bykey)
    src_text(path) == text || return "$(relpath(path, ROOT)) differs from what dev/skeleton.jl writes"
    return nothing
end

# the no-diff check's faults: the scope's, each file that differs, each stale Kernel row and, with
# `fields`, each filled struct's field faults and each filled definition's Kernel-typed parameter that
# is not the table's type
function diff_faults(S::Scope = read_scope(); fields::Bool = true)::Vector{String}
    local anchors = src_anchors()
    local bykey = by_anchor(S)
    local out = scope_faults()
    for f in scope()
        local x = file_fault(f, S, anchors, bykey)
        x === nothing || push!(out, x)
    end
    append!(out, ("KERNEL_TYPES row $r: no in-scope file names it" for r in unused_kernel_rows(S)))
    fields && append!(out, field_faults(S))
    fields && append!(out, kernel_param_faults(S))
    return out
end

function diff_main()::Int
    local out = diff_faults()
    foreach(x -> println("✗ ", x), out)
    return length(out)
end

# ---- the fields: a ported struct keeps every dart instance field ------------------------------------
# A filled struct anchored at a dart class holds that class's instance fields, each by the one rule's
# name (snake, a Julia keyword with a trailing `_`): its own, its `extends` chain's and its mixins'
# (Julia has no inheritance, so a subclass's struct holds its superclass's fields), or src fills a
# definition anchored at the field's declaration (an accessor: a superclass's constant field each
# subclass answers, the builder's SingleByteInstruction.byte), but those its
# docstring lists after "Fields to come", each backticked by its dart name (wt3-translator's form:
# `Fields to come (N, ...): \`a\` :100, \`b\` :104.`, line tokens and the parenthetical ignored). A
# field missing, or listed to come while the struct holds it, is a fault.

# the dart instance fields of class `x` in file `key`, each its dart name and its declaration's anchor:
# its own, then its extends chain's and its mixins', each in scope
function dart_instance_fields(S::Scope, key::AbstractString, x::AbstractString, seen = Set{String}())::Vector{Tuple{String,String}}
    "$key|$x" in seen && return Tuple{String,String}[]
    push!(seen, "$key|$x")
    local ds = S.decls[key]
    local i = findfirst(d -> d.symbol == x && d.kind in (:class, :abstract, :mixin), ds)
    i === nothing && return Tuple{String,String}[]
    local d = ds[i]
    local out = [(f.symbol[length(x)+2:end], anchor(key, f)) for f in ds if f.kind == :field && !("static" in f.modifiers) && startswith(f.symbol, x * ".")]
    for sup in vcat(isempty(d.extends) ? String[] : [d.extends], d.mixins)
        local p, n = split_prefix(sup)
        local k = declaring(n, p, key)
        k === nothing || append!(out, dart_instance_fields(S, k, n, seen))
    end
    return out
end

# the dart names a docstring lists after "Fields to come", up to the period that ends the list
function fields_to_come(text::AbstractString)::Vector{String}
    local m = match(r"Fields to come[^:]*:((?:[^.`]|`[^`]*`)*)\."s, text)
    m === nothing && return String[]
    return String[x[1] for x in eachmatch(r"`([^`]+)`", m[1])]
end

# the field names of the struct a definition's parsed form declares, or nothing
function struct_fields(ex)::Union{Nothing,Vector{Symbol}}
    Meta.isexpr(ex, :macrocall) && return struct_fields(ex.args[end])
    Meta.isexpr(ex, :struct) || return nothing
    local out = Symbol[]
    for f in ex.args[3].args
        Meta.isexpr(f, :const) && (f = f.args[1])
        f isa Symbol ? push!(out, f) : Meta.isexpr(f, :(::)) && f.args[1] isa Symbol ? push!(out, f.args[1]) : nothing
    end
    return out
end

# every filled struct's field faults
function field_faults(S::Scope)::Vector{String}
    local out = String[]
    local keys = Set(scope())
    local bykey = by_anchor(S)
    local filled = Set(a for (a, (_, stub)) in src_anchors() if !stub)
    for f in scope()
        local path = jl_file(f)
        isfile(path) || continue
        for s in last(segments(src_text(path), path))
            generated(s) && continue
            local a = canonical_anchor(s.anchor, keys)
            haskey(bykey, a) || continue
            local key, d = bykey[a]
            d.kind in (:class, :abstract, :mixin) || continue
            local ex = try Meta.parse(s.text) catch; nothing end
            local have = struct_fields(ex)
            have === nothing && continue
            local want = unique(dart_instance_fields(S, key, d.symbol))
            local come = fields_to_come(s.text)
            local at = "$(relpath(path, ROOT)):$(s.first) $(d.symbol)"
            for (n, fa) in want
                # the rule's name, or jname's, which also suffixes Julia's contextual words (type, mutable)
                local held = Symbol(snake(n)) in have || Symbol(jname(n)) in have || fa in filled
                held != (n in come) || push!(out, held ? "$at holds `$n`, listed to come" : "$at lacks dart's field `$n` and does not list it to come")
            end
            for n in come
                any(w -> w[1] == n, want) || push!(out, "$at lists `$n` to come, which is no instance field of the dart class")
            end
        end
    end
    return out
end

# ---- the Kernel-typed parameters of filled definitions ------------------------------------------
# The Kernel table types every Kernel-typed parameter, filled or stubbed (the lead's ruling, A46S1): a
# filled definition's parameter whose dart type is a Kernel type is annotated with the table's row, as
# the stub was. Parameters are matched by position (the receiver aside) and keywords by name; a
# definition whose positional count differs from dart's is not matched (a port that reshaped it).

# whether a dart parameter's type names a Kernel table row (its head type, past `?` and arguments)
function kernel_typed(p::Param, S::Scope, from::AbstractString)::Bool
    local ts = filter(t -> !(t in ("final", "const", "covariant", "required", "late", "var")), split(p.dart))
    local i = findfirst(==(p.name), ts)
    i === nothing || i == 1 && return false
    local head = ts[1]
    local pre = i >= 4 && ts[2] == "." ? (ts[1], ts[3]) : ("", head)
    occursin(r"^[A-Z_]", pre[2]) || return false
    local r = try resolve(pre[2], pre[1], from) catch; nothing end
    return r !== nothing && !(r in scope_set()) && !startswith(r, "dart:") && haskey(kernel_types(), (r, pre[2]))
end

# a parsed definition's call: its positional arguments and keyword arguments, each name => annotation
function call_args(ex)
    while Meta.isexpr(ex, :macrocall); ex = ex.args[end]; end
    (Meta.isexpr(ex, :function) || Meta.isexpr(ex, :(=))) && length(ex.args) == 2 || return nothing
    local c = ex.args[1]
    while Meta.isexpr(c, :where) || Meta.isexpr(c, :(::)) && length(c.args) == 2 && Meta.isexpr(c.args[1], :call) || Meta.isexpr(c, :where)
        c = c.args[1]
    end
    Meta.isexpr(c, :call) || return nothing
    local ann(a) = Meta.isexpr(a, :kw) ? ann(a.args[1]) : Meta.isexpr(a, :(::)) ? (length(a.args) == 2 ? (string(a.args[1]), string(a.args[2])) : ("", string(a.args[1]))) : (string(a), "")
    local pos = Tuple{String,String}[]
    local kw = Dict{String,String}()
    for a in c.args[2:end]
        if Meta.isexpr(a, :parameters)
            foreach(k -> (local x = ann(k); kw[x[1]] = x[2]), a.args)
        else
            push!(pos, ann(a))
        end
    end
    return (pos, kw)
end

# two annotations name one type: equal text, a Union's members in any order
function same_type(a::AbstractString, b::AbstractString)::Bool
    local norm(x) = (local e = try Meta.parse(x) catch; x end;
                     Meta.isexpr(e, :curly) && e.args[1] === :Union ? Set(string.(e.args[2:end])) : replace(string(e), " " => ""))
    return norm(a) == norm(b)
end

function kernel_param_faults(S::Scope)::Vector{String}
    local out = String[]
    local keys = Set(scope())
    local bykey = by_anchor(S)
    for f in scope()
        local path = jl_file(f)
        isfile(path) || continue
        for s in last(segments(src_text(path), path))
            generated(s) && continue
            local a = canonical_anchor(s.anchor, keys)
            haskey(bykey, a) || continue
            local key, d = bykey[a]
            d.kind in (:function, :method, :constructor, :factory, :operator, :setter) || continue
            local ex = try Meta.parse(s.text) catch; nothing end
            local args = ex === nothing ? nothing : call_args(ex)
            args === nothing && continue
            local pos, kw = args
            local ps = params(d.params, S, key)
            local req = [p for p in ps if p.section == :required]
            local self = last(julia_name(d)) && !(occursin('.', d.symbol) && split(d.symbol, '.')[2] in ("toString", "hashCode"))
            local jpos = self ? pos[2:end] : pos
            local at = "$(relpath(path, ROOT)):$(s.first) $(d.symbol)"
            local check(p, got) = begin
                kernel_typed(p, S, key) || return
                isempty(p.jtype) && return   # a planned row: unannotated until its types exist
                same_type(got, p.jtype) ||
                    push!(out, "$at: `$(p.name)` is $(isempty(got) ? "unannotated" : got), the Kernel table's $(p.jtype)")
            end
            if length(jpos) == length(req) + any(p -> p.section == :optional, ps)
                for (p, (_, got)) in zip(req, jpos)
                    check(p, got)
                end
            end
            for p in ps
                p.section == :named && haskey(kw, jname(p.name)) && check(p, kw[jname(p.name)])
            end
        end
    end
    return out
end

# ---- merging another lane's port --------------------------------------------------------------
# A lane may port in one module (opus-builder's wasm_builder port is one namespace). `merge` adapts
# each filled definition to the loader's modules (DART_MODULES) and the generator's declarations:
# - a definition in a library module (IR, Util, JS) spells its package's members and the package
#   module's own names through the package module (`WasmBuilder.write_byte`): every member is its
#   package's one generic function (the lead's ruling, extended to every member by the default sent
#   with group (a)); a definition in the package module spells a library module's own names through
#   it (`IR.RefType`), dart's `ir.` prefix; locals, fields, keyword names and symbols are left alone;
# - a struct takes the generator's supertype (its `extends`, or first `implements` in scope; none
#   for a sealed sum's kind), unless the lane gave it a forward declaration src/julia defines;
# - a declaration the generator writes complete (an abstract type, a closed sum, an enum) is the
#   generator's: the lane's form of it is left, and so is a definition naming what is out of scope
#   (the deserializer, the printer, widen_return) or an anchor that names no declaration at the pin.

# the names a definition binds locally: its parameters, assignments, loop and comprehension
# variables, `local` names, type variables and struct fields
function locals_of(ex)::Set{Symbol}
    local out = Set{Symbol}()
    local lhs!(x) = x isa Symbol ? push!(out, x) :
        Meta.isexpr(x, :(::)) ? (length(x.args) == 2 ? lhs!(x.args[1]) : nothing) :
        Meta.isexpr(x, :tuple) || Meta.isexpr(x, :parameters) ? foreach(lhs!, x.args) :
        Meta.isexpr(x, :kw) || Meta.isexpr(x, :(=)) ? lhs!(x.args[1]) :
        Meta.isexpr(x, :...) ? lhs!(x.args[1]) : nothing
    local walk(x) = begin
        x isa Expr || return
        local is_sig(l) = Meta.isexpr(l, :call) || Meta.isexpr(l, :where) || (Meta.isexpr(l, :(::)) && length(l.args) == 2 && is_sig(l.args[1]))
        if x.head in (:function, :(=), :->) && length(x.args) == 2 && (x.head != :(=) || is_sig(x.args[1]))
            local sig = x.args[1]
            while Meta.isexpr(sig, :where)
                foreach(t -> lhs!(Meta.isexpr(t, :(<:)) ? t.args[1] : t), sig.args[2:end]); sig = sig.args[1]
            end
            Meta.isexpr(sig, :(::)) && length(sig.args) == 2 && Meta.isexpr(sig.args[1], :call) && (sig = sig.args[1])
            Meta.isexpr(sig, :call) ? foreach(lhs!, sig.args[2:end]) : lhs!(sig)
        elseif x.head in (:(=), :local, :global, :const) || x.head in (:+=, :-=, :*=, :|=, :&=)
            x.head in (:global, :const) || lhs!(x.args[1])
            x.head == :local && foreach(lhs!, x.args)
        elseif x.head == :for || x.head == :generator || x.head == :let
            for it in (x.head == :generator ? x.args[2:end] : [x.args[1]])
                for b in (Meta.isexpr(it, :block) ? it.args : [it])
                    (Meta.isexpr(b, :(=)) || Meta.isexpr(b, :in)) && lhs!(b.args[1])
                end
            end
        elseif x.head == :struct
            for f in x.args[3].args
                Meta.isexpr(f, :const) && (f = f.args[1])
                (f isa Symbol || Meta.isexpr(f, :(::))) && lhs!(f)
            end
        elseif x.head == :try && length(x.args) >= 2 && x.args[2] isa Symbol
            push!(out, x.args[2])
        end
        foreach(walk, x.args)
    end
    walk(ex)
    return out
end

# the names each module binds at top level and each package's members, read from the pin's
# declarations as the one rule names them: (top[module], members[package])
function binding_sets(S::Scope)::Tuple{Dict{String,Set{Symbol}},Dict{String,Set{Symbol}}}
    local top = Dict{String,Set{Symbol}}()
    local members = Dict{String,Set{Symbol}}()
    for f in scope(), d in S.decls[f]
        counted(d) || continue
        local m = module_of(f)
        local pkg = String(first(split(m, '.')))
        if d.kind in (:class, :abstract, :mixin)
            push!(get!(top, m, Set{Symbol}()), Symbol(d.symbol))
        elseif d.kind == :enum
            push!(get!(top, m, Set{Symbol}()), Symbol(d.symbol))
            foreach(v -> push!(top[m], Symbol(v)), ("$(d.symbol)_$v" for v in enum_values(f, d)))
        else
            local name, self = julia_name(d)
            self && name in values(dart_base()) && continue
            push!(get!(self ? members : top, self ? pkg : m, Set{Symbol}()), Symbol(name))
        end
    end
    return (top, members)
end

# a definition's text with its names spelled for module `mod` (see above)
function adapt(text::AbstractString, mod::AbstractString, top, members)::String
    local JS = Base.JuliaSyntax
    local ex = try Meta.parse(text) catch; nothing end
    local locs = ex === nothing ? Set{Symbol}() : locals_of(ex)
    local pkg = String(first(split(mod, '.')))
    local mine = get(top, mod, Set{Symbol}())
    local toks = JS.tokenize(text)
    local kinds = [string(JS.kind(t)) for t in toks]
    local out = IOBuffer()
    local prevsig(i) = (local j = i - 1; while j >= 1 && kinds[j] in ("Whitespace", "NewlineWs", "Comment"); j -= 1; end; j)
    local nextsig(i) = (local j = i + 1; while j <= length(toks) && kinds[j] in ("Whitespace", "NewlineWs"); j += 1; end; j)
    for (i, t) in enumerate(toks)
        local w = text[t.range]
        if kinds[i] != "Identifier"
            print(out, w); continue
        end
        local n = Symbol(w)
        local p, q = i - 1, nextsig(i)
        local after_dot = p >= 1 && kinds[p] == "."
        local symbol_ = p >= 1 && kinds[p] == ":" && (p == 1 || kinds[p-1] in ("Whitespace", "NewlineWs", "(", ",", "[", "=", "{"))
        local kwname = q <= length(toks) && kinds[q] == "=" && (local b = prevsig(i); b >= 1 && kinds[b] in ("(", ",", ";"))
        local qualifier = q <= length(toks) && kinds[q] == "." && i + 1 == q
        if after_dot || (w == "ir" && qualifier) || symbol_ || kwname || n in locs
            print(out, w); continue
        end
        if mod != pkg && (n in get(members, pkg, Set{Symbol}()) || (n in get(top, pkg, Set{Symbol}()) && !(n in mine)))
            print(out, pkg, ".", w)
        elseif mod == pkg && !(n in mine) && !(n in get(members, pkg, Set{Symbol}()))
            local lib = findfirst(m -> startswith(m, pkg * ".") && n in top[m], collect(keys(top)))
            lib === nothing ? print(out, w) : print(out, spell_module(collect(keys(top))[lib], mod), ".", w)
        else
            print(out, w)
        end
    end
    local r = String(take!(out))
    # the lane's own `ir.X` (the module of its catch clauses): the IR module's, or inside IR its own
    return replace(r, r"(?<![\w.])ir\." => (mod == "WasmBuilder.IR" ? "" : "IR."))
end

# a struct definition's header with the generator's supertype, unless the lane's is a forward
# declaration src/julia defines (it stands for a struct a cycle needs before its parts)
function fix_super(text::AbstractString, sp::AbstractString, forwards::Set{String})::String
    local m = match(r"((?:mutable )?struct )(\w+)(\{[^}]*\})?( <: ([\w.]+))?", text)
    m === nothing && return String(text)
    m[5] !== nothing && m[5] in forwards && return String(text)
    local head = m[1] * m[2] * something(m[3], "") * (isempty(sp) ? "" : " <: " * sp)
    return text[1:m.offset-1] * head * text[m.offset+length(m.match):end]
end

const OUT_OF_SCOPE_NAMES = r"\b(Deserializer|IndentPrinter|print_to|widen_return|ModulePrintSettings)\b"

# merge another tree's filled definitions of the dart files `darts` into src: each, adapted, takes
# the place of its anchor's definition in the file its anchor names (a stub, or an earlier fill),
# several for one anchor kept in their order. The other tree is only read. Prints what it leaves.
function merge_main(tree::AbstractString, darts::Vector{String}; forwards::Set{String} = Set(["AbstractModule"]))::Int
    local S = read_scope()
    local bykey = by_anchor(S)
    local allkeys = Set(scope())
    for k in darts
        k in allkeys || error("skeleton: merge: $k is no in-scope dart file")
    end
    local top, members = binding_sets(S)
    local incoming = Dict{String,Vector{String}}()
    local left = String[]
    local srcdir = joinpath(tree, "src")
    local take(s::Segment, path) = begin
        s.unported && return
        local a = canonical_anchor(s.anchor, allkeys)
        local m = match(r"^(.+?\.dart):\d+ ", a)
        (m === nothing || !(m[1] in darts)) && return
        local why = !haskey(bykey, a) ? "names no declaration at the pin" :
                    occursin(OUT_OF_SCOPE_NAMES, s.text) ? "names what is out of scope" :
                    occursin(r"^(\"\"\"(?s:.*?)\"\"\"\n)?@parity \"[^\"]+\" (abstract type|const \w+ = Union\{)"m, s.text) ? "a declaration the generator writes" :
                    (local fd = bykey[a][2]; fd.kind == :enum || haskey(S.sealed, "$(bykey[a][1])|$(fd.symbol)")) ? "a declaration the generator writes" : ""
        isempty(why) || (push!(left, "$a: $why"); return)
        local key, d = bykey[a]
        local text = a == s.anchor ? s.text : replace(s.text, "\"" * s.anchor * "\"" => "\"" * a * "\""; count = 1)
        text = adapt(text, module_of(key), top, members)
        if d.kind in (:class, :abstract, :mixin) && occursin(r"(?:mutable )?struct ", text)
            local sup = dart_super(d, key)
            local p, n = split_prefix(sup)
            local sk = isempty(sup) ? nothing : declaring(n, p, key)
            local sp = sk !== nothing && haskey(S.sealed, "$sk|$n") ? "" : super_ref(S, sup, key)
            text = fix_super(text, sp, forwards)
        end
        push!(get!(incoming, a, String[]), text)
    end
    for (dir, _, files) in walkdir(srcdir), f in sort(files)
        endswith(f, ".jl") || continue
        local path = joinpath(dir, f)
        (startswith(path, joinpath(srcdir, "julia")) || path == joinpath(srcdir, "WasmTarget.jl")) && continue
        for s in last(segments(read(path, String), path))
            # a module the lane declared inside a file (its `ir` of catch clauses): its definitions
            local mm = match(r"^@parity \"[^\"]+\" module \w+\n(?:using [^\n]*\n)?(?s:(.*))\nend\s*$", s.text)
            if mm !== nothing
                foreach(x -> take(x, path), last(segments(String(mm[1]), path)))
            else
                take(s, path)
            end
        end
    end
    local n = 0
    for k in darts
        local path = jl_file(k)
        local preamble, segs = segments(read(path, String), path)
        local out, done = String[], Set{String}()
        for s in segs
            local a = canonical_anchor(s.anchor, allkeys)
            if haskey(incoming, a)
                a in done || (append!(out, incoming[a]); push!(done, a); n += length(incoming[a]))
                continue
            end
            push!(out, s.text)
        end
        for a in keys(incoming)
            startswith(a, k * ":") && !(a in done) && error("skeleton: merge: $a has no definition in $(relpath(path, ROOT))")
        end
        write(path, rstrip(preamble) * "\n\n" * join(out, "\n\n") * "\n")
    end
    foreach(x -> println("left: ", x), sort(left))
    println("skeleton: $n definition(s) merged from $tree, $(length(left)) left")
    return 0
end

# the positional signature a stub defines (its function and positional parameter types, which Julia
# dispatches on; keywords do not take part), for the duplicate check
function dispatch_key(file::String, d::Decl, S::Scope)::Union{Nothing,String}
    d.kind in (:class, :abstract, :mixin, :enum) && return nothing
    local s = stub(file, d, S, Decl[])
    local m = match(r"function (.+?)\((.*)\) end$", s)
    m === nothing && return nothing
    local pos = split(first(split(m[2], ';')), ", "; keepempty = false)
    local types = [occursin("::", p) ? split(p, "::"; limit = 2)[2] : (endswith(p, "...") ? "Vararg" : "Any") for p in pos]
    return module_of(file) * "." * m[1] * "(" * join(types, ",") * ")"
end

# the stubs that would define one method twice: a duplicate signature overwrites a method, which Julia
# refuses while precompiling
function duplicate_stubs(S::Scope)::Vector{String}
    local seen = Dict{String,String}()
    local out = String[]
    for f in scope(), d in S.decls[f]
        counted(d) || continue
        local k = dispatch_key(f, d, S)
        k === nothing && continue
        haskey(seen, k) ? push!(out, "$k: $(seen[k]) and $(anchor(f, d))") : (seen[k] = anchor(f, d))
    end
    return out
end

# ---- the scope ----------------------------------------------------------------------------------
# The in-scope files are src/julia/parity.jl's DART_FILES, the one list (A3); dev/skeleton_scope.toml
# gives each other dart file of the two packages its reason, and together they are every dart file
const PARITY = joinpath(ROOT, "src", "julia", "parity.jl")

function scope()::Vector{String}
    local m = match(r"(?s)const DART_FILES(?:::[^=]*)? = \((.*?)\n\)", read(PARITY, String))
    m === nothing && error("skeleton: src/julia/parity.jl holds no DART_FILES")
    return String[x[1] for x in eachmatch(r"\"([^\"]+)\"", m[1])]
end

# a section of dev/skeleton_scope.toml: key => reason
function scope_section(name::AbstractString)::Dict{String,String}
    local text = read(joinpath(ROOT, "dev", "skeleton_scope.toml"), String)
    local sec = match(Regex("(?s)\\[\\Q$(name)\\E\\]\\n(.*?)(?:\\n\\[|\\z)"), text)
    sec === nothing && error("skeleton: dev/skeleton_scope.toml has no [$name] section")
    return Dict(String(m[1]) => String(m[2]) for m in eachmatch(r"^\"([^\"]+)\"\s*=\s*\"([^\"]*)\""m, sec[1]))
end

# the out-of-scope dart files and their reasons
out_of_scope()::Dict{String,String} = scope_section("out")

# why a declaration of in-scope file `file` is out of scope, or nothing: [out_definitions] names it
# or the class it is a member of (`<key> <Symbol>`); or its parameters or receiver name a type
# [out_types] lists (`<library> <Name>`), or a class [out_definitions] takes out
const OUT_DEFINITIONS = Dict{String,String}()
const OUT_TYPES = Dict{String,String}()
function out_reason(file::AbstractString, d::Decl, ext_on::Dict{String,String})::Union{Nothing,String}
    isempty(OUT_DEFINITIONS) && merge!(OUT_DEFINITIONS, scope_section("out_definitions"))
    isempty(OUT_TYPES) && merge!(OUT_TYPES, scope_section("out_types"), OUT_DEFINITIONS)
    local x = first(split(d.symbol, '.'))
    for k in ("$file $(d.symbol)", "$file $x")
        haskey(OUT_DEFINITIONS, k) && return OUT_DEFINITIONS[k]
    end
    # the receiver of an extension's member, unnamed (its `on` kept as d.extends) or named
    local on = d.kind in (:class, :abstract, :mixin, :enum, :extension) ? "" :
               haskey(ext_on, x) ? ext_on[x] : !occursin('.', d.symbol) ? d.extends : ""
    local names = Tuple{String,String}[]
    isempty(on) || push!(names, split_prefix(on))
    local ts = d.params
    for i in eachindex(ts)
        ts[i].kind == :ident || continue
        if !isuppercase(first(ts[i].text)) && i + 2 <= length(ts) && ts[i+1].text == "." && ts[i+2].kind == :ident
            push!(names, (ts[i].text, ts[i+2].text))   # a prefixed type, `ir.X`
        elseif isuppercase(first(ts[i].text)) && !(i >= 2 && ts[i-1].text == ".")
            push!(names, ("", ts[i].text))
        end
    end
    for (p, n) in names
        local lib = resolve(n, p, file)
        lib === nothing && continue
        local k = "$lib $n"
        haskey(OUT_TYPES, k) && return "it names $n, out of scope: $(OUT_TYPES[k])"
    end
    return nothing
end

# every dart file of the two packages at the pin is in scope or out with its reason, never both
function scope_faults()::Vector{String}
    local all = String[]
    for pkg in ("dart2wasm", "wasm_builder"), (dir, _, files) in walkdir(joinpath(sdk(), "pkg", pkg, "lib")), f in files
        endswith(f, ".dart") && push!(all, relpath(joinpath(dir, f), joinpath(sdk(), "pkg")))
    end
    local ins, outs = Set(scope()), out_of_scope()
    local out = String[]
    for f in all
        (f in ins) == haskey(outs, f) && push!(out, f in ins ? "$f is in DART_FILES and out of scope" : "$f is neither in DART_FILES nor given a reason")
    end
    for f in union(ins, keys(outs))
        f in all || push!(out, "$f is no dart file at the pin")
    end
    # each row says its kind (the scope file's header): a scope exclusion or the Julia step
    for sec in ("out", "out_definitions", "out_types"), (k, why) in scope_section(sec)
        occursin(r"^(scope|julia): \S", why) || push!(out, "dev/skeleton_scope.toml [$sec] \"$k\": its reason opens with no kind, `scope: ` or `julia: `")
    end
    return out
end

# ---- the commands --------------------------------------------------------------------------------
# the definitions a file holds, as the generator counts them: every declaration but an extension (its
# members are), a function typedef (a parameter's type, `Function`) and an instance field (a field is
# part of its struct; a static field is a stub function). A typedef that is data, a record or an alias,
# is a definition
counted(d::Decl)::Bool = d.kind != :extension && !(d.kind == :typedef && typedef_kind(d) == :function) &&
    !(d.kind == :field && !("static" in d.modifiers))

function count_main()
    local total = 0
    local S = read_scope()
    for f in scope()
        local n = count(counted, S.decls[f])
        println(rpad(f, 50), lpad(n, 6))
        total += n
    end
    println(rpad("in scope, in all", 50), lpad(total, 6))
end

# the two readers' disagreements, one per in-scope file whose declaration lines differ
function check_faults()::Vector{String}
    local out = String[]
    for f in scope()
        local path = dart_source(f)
        local lexed = sort(unique(Int[d.line for d in read_dart(path)]))
        local indented = sort(unique(indented_lines(path)))
        lexed == indented || push!(out, "$f: the lexer reads $(length(lexed)) declaration lines, the indentation " *
            "$(length(indented)); the lexer alone $(first(setdiff(lexed, indented), 12)), the indentation alone " *
            "$(first(setdiff(indented, lexed), 12))")
    end
    return out
end

function check_main()::Int
    local out = check_faults()
    foreach(x -> println("✗ ", x), out)
    return length(out)
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    local cmd = isempty(ARGS) ? "count" : ARGS[1]
    cmd == "count" ? Skeleton.count_main() :
    cmd == "check" ? exit(Skeleton.check_main() == 0 ? 0 : 1) :
    cmd == "write" ? exit(Skeleton.write_main()) :
    cmd == "diff" ? exit(Skeleton.diff_main() == 0 ? 0 : 1) :
    cmd == "merge" ? exit(Skeleton.merge_main(ARGS[2], String.(ARGS[3:end]))) :
    (println(stderr, "usage: julia dev/skeleton.jl count|check|write|diff|merge"); exit(2))
end
