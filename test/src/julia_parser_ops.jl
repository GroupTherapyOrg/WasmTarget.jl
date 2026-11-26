# Base's operator predicates by overlay (src/patch/unicode.jl): the femtolisp parser's operator? and syntactic-op?
# (julia/src/julia-parser.scm), which libjulia's jl_is_operator and jl_is_syntactic_operator answer (julia/src/ast.c:992,
# :1019), ported with the parser's tables. The names every comparison here asks come from julia-parser.scm read at the
# julia pin, each define read and evaluated as femtolisp would, never from the port's own copies: the port's lists equal
# those defines, define for define; each ported predicate answers as Julia's own ccall natively at every name of every
# define, dotted, suffixed (a suffix of julia_opsuffs.h, a combining mark) and with a suffix that is no suffix, at
# multi-codepoint names, at names cut off mid-sequence and at every character to U+FFFF; and both overlays answer in a
# module as native.
module JuliaParserOpsTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

native_op(s::String) = ccall(:jl_is_operator, Cint, (Cstring,), s)
native_syn(s::String) = ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s)

# femtolisp's reader (julia/src/flisp/read.c) over the parser's text from byte i: peek (:207) skips whitespace
# and a ; comment, a ( reads a list, a ' a quote, a " a string (read_string, :458, with no escape in the forms
# read here), and anything else a symbol by read_token (:165): a | toggles escaping, a \ takes the next byte as
# itself, and an unescaped byte that is no symchar (:14) ends it. A symbol is a Symbol, a string a String, a
# list a Vector{Any}, 'x the list (quote x)
function scm_read(s::Vector{UInt8}, i::Int)::Tuple{Any,Int}
    while true
        while s[i] in codeunits(" \t\n\v\f\r"); i += 1; end
        s[i] == UInt8(';') || break
        while s[i] != UInt8('\n'); i += 1; end
    end
    local c = Char(s[i])
    if c == '('
        local items = Any[]
        i += 1
        while true
            while s[i] in codeunits(" \t\n\v\f\r"); i += 1; end
            s[i] == UInt8(')') && return items, i + 1
            local (x, j) = scm_read(s, i)
            push!(items, x)
            i = j
        end
    elseif c == '\''
        local (x, j) = scm_read(s, i + 1)
        return Any[:quote, x], j
    elseif c == '"'
        local e = findnext(==(UInt8('"')), s, i + 1)
        return String(s[i+1:e-1]), e + 1
    end
    local buf = UInt8[]
    local escaped = false
    while i <= length(s)
        local b = s[i]
        if b == UInt8('|')
            escaped = !escaped
        elseif b == UInt8('\\')
            i += 1
            push!(buf, s[i])
        elseif !escaped && b in codeunits("()[]'\";`,\\| \f\n\r\t\v")
            break
        else
            push!(buf, b)
        end
        i += 1
    end
    return Symbol(String(buf)), i
end

# a define of julia-parser.scm evaluated by the forms its operator lists use, a symbol's value its name: a
# quoted symbol or list, a name another define bound, add-dots (:4, each name and then each with a `.` before
# it), Set (:44) as the list it tests, append and append! (the lists in order), list, list* (the last argument
# the tail), (apply append L), (map eval L) (each name's value),
#delete-duplicates (julia/src/flisp/system.lsp:310, the first of
# each kept), filter by a one-argument lambda, not, is-word-operator? (:126, every character an
# identifier-start-char?, flisp's builtin of jl_id_start_char, which Base.is_id_start_char calls) and
# string->symbol; any other form fails, named
function scm_eval(x, env::Dict{Symbol,Any})
    x isa Symbol && return env[x]
    x isa String && return x
    local (f, args) = (x[1], x[2:end])
    f === :quote && return args[1] isa Symbol ? String(args[1]) : String[String(a) for a in args[1]]
    if f === :lambda
        local (param, body) = (only(args[1]), args[2])
        return v -> scm_eval(body, merge(env, Dict{Symbol,Any}(param => v)))
    end
    # apply and map take a builtin by its name: (apply append L), (map eval L)
    f === :apply && args[1] === :append && return String[vcat(scm_eval(args[2], env)...)...]
    f === :map && args[1] === :eval && return Any[env[Symbol(v)] for v in scm_eval(args[2], env)]
    local vals = Any[scm_eval(a, env) for a in args]
    f === Symbol("add-dots") && return vcat(vals[1], String["." * op for op in vals[1]])
    f === :Set && return vals[1]
    f in (:append, Symbol("append!")) && return String[vcat(vals...)...]
    f === :list && return String[vals...]
    f === Symbol("list*") && return String[vals[1:end-1]..., vals[end]...]
    f === Symbol("delete-duplicates") && return unique(vals[1])
    f === :filter && return filter(v -> vals[1](v), vals[2])
    f === :not && return !vals[1]
    f === Symbol("is-word-operator?") && return all(Base.is_id_start_char, vals[1])
    f === Symbol("string->symbol") && return vals[1]
    error("julia-parser.scm: no evaluator for ($f ...)")
end

# the value of the column-0 `(define <name> ...)` of the parser's text, each earlier define it names in env
function scm_define(text::String, name::String, env::Dict{Symbol,Any})
    local s = Vector{UInt8}(codeunits(text))
    local r = findfirst(Regex("^\\(define \\Q$name\\E[ \\n]", "m"), text)
    @test r !== nothing
    local (form, _) = scm_read(s, first(r))
    @test form[1] === :define && form[2] === Symbol(name)
    return scm_eval(form[3], env)
end

# the pinned julia-parser.scm's text, and each define the operator lists are built from, by its name, in the
# parser's order: prec-names (:35) names the precedence tables, each read from its own define; then unary-ops,
# syntactic-operators, the transposes, vararg-op, no-suffix? (:62) and operators (:129), the word operators out.
# nothing when the julia pin is not fetched (bash dev/fetch_julia.sh makes it), which each testset fails on
function pinned_parser()::Union{Nothing,Tuple{String,Dict{Symbol,Any}}}
    local dir = W._c_pin_checkout(:julia)
    dir === nothing && return nothing
    local text = read(joinpath(dir, "src", "julia-parser.scm"), String)
    local env = Dict{Symbol,Any}()
    env[Symbol("prec-names")] = scm_define(text, "prec-names", env)
    for name in env[Symbol("prec-names")]
        env[Symbol(name)] = scm_define(text, name, env)
    end
    for name in ("unary-ops", "syntactic-operators", "trans-op", "ctrans-op", "vararg-op", "no-suffix?", "operators")
        env[Symbol(name)] = scm_define(text, name, env)
    end
    return text, env
end

# every symbol the pinned defines name, each once, in the parser's order
pinned_names(env::Dict{Symbol,Any})::Vector{String} =
    unique(vcat(env[:operators], env[Symbol("no-suffix?")], env[Symbol("syntactic-operators")], env[Symbol("unary-ops")],
                (env[Symbol(n)] for n in env[Symbol("prec-names")])...))

module OpCases
# literal names, each a constant Symbol of the module: bit k set where the k-th name is an operator
const NAMES = (:+, :Int, :(=), Symbol("+′"), Symbol("=′"), Symbol(".+"), Symbol(".="), :in, :isa, Symbol("+₁"),
               Symbol("−"), Symbol("√"), Symbol("..."), Symbol("'"), Symbol(".'"), Symbol("->"), Symbol("<:"), :foo,
               Symbol(""), Symbol("+a"), Symbol("∈̂"), Symbol("⊕ˣ"), Symbol("&&"), Symbol(":="), Symbol("|>"))
ops(x::Int64)::Int64 = sum(Int64(Base._isoperator(NAMES[k])) << (k - 1) for k in 1:length(NAMES)) + x - x
syn(x::Int64)::Int64 = sum(Int64(Base.is_syntactic_operator(NAMES[k])) << (k - 1) for k in 1:length(NAMES)) + x - x
# a String built at run time, an operator or not by its bytes
str_op(x::Int64)::Int64 = Int64(Base._isoperator(string(Char(x), Char(x))))
# a String holding a NUL: Base's ArgumentError
function str_nul(x::Int64)::Int64
    try
        return Int64(Base._isoperator(string(Char(x), '\0')))
    catch e
        return e isa ArgumentError ? Int64(-1) : Int64(-2)
    end
end
end
const OC = OpCases

const PINNED = pinned_parser()

@testset "jl_is_operator's operator lists are julia-parser.scm's, define for define" begin
    @test PINNED !== nothing   # bash dev/fetch_julia.sh makes it
    if PINNED !== nothing
        local (text, env) = PINNED
        local names = env[Symbol("prec-names")]
        @test length(names) == 17 && length(W.PREC_NAMES) == 17
        for (k, name) in enumerate(names)
            @test env[Symbol(name)] == W.PREC_NAMES[k] || (@info "julia-parser.scm's $name differs from the port's" setdiff(env[Symbol(name)], W.PREC_NAMES[k]) setdiff(W.PREC_NAMES[k], env[Symbol(name)]); false)
        end
        for (name, ours) in (("unary-ops", W.UNARY_OPS), ("syntactic-operators", W.SYNTACTIC_OPERATORS),
                             ("trans-op", W.TRANS_OP), ("ctrans-op", W.CTRANS_OP), ("vararg-op", W.VARARG_OP),
                             ("no-suffix?", W.FL_NO_SUFFIX), ("operators", W.FL_OPERATORS))
            @test env[Symbol(name)] == ours
        end
        # a symbol dropped from a define is seen: prec-pipe> without |> differs from the port's
        @test scm_define(replace(text, " |\\|>|))" => "))"), "prec-pipe>", env) == [".|>"] != W.PREC_PIPE_GT
        # every symbol the defines name, asked of Base's _isoperator and of the port, alone and dotted: Base
        # answers each an operator but the word operators (in, isa and 🢲, an identifier-start character), which
        # operators leaves out
        local named = pinned_names(env)
        @test length(env[:operators]) > 600 && length(named) > length(env[:operators])
        @test isempty(filter(s -> (W.jl_is_operator(s) != 0) != Base._isoperator(s), vcat(named, "." .* named)))
        @test filter(s -> !Base._isoperator(s), named) == filter(s -> all(Base.is_id_start_char, s), named) == ["in", "isa", "🢲"]
    end
end

@testset "jl_is_operator's port answers as Base's _isoperator, natively" begin
    @test PINNED !== nothing   # bash dev/fetch_julia.sh makes it
    local ours(s) = W.jl_is_operator(s) != 0
    local operators = PINNED === nothing ? String[] : PINNED[2][:operators]
    local names = String[]
    for op in operators, s in (op, "." * op, op * "²", op * "′", op * "̂", op * "x", "²" * op)
        push!(names, s)
    end
    PINNED === nothing || append!(names, PINNED[2][Symbol("no-suffix?")])
    # names whose last sequence is cut off by their end, which C decodes with the NUL after the name and,
    # past it, bytes it leaves undefined, the port's zeros (dev/formal/StripWalk.tla): every lead byte
    # 0x80-0xff alone and with one continuation byte, after each prefix
    for p in ("", "+", "-", "=", ".+", "<", "x", "a", "→"), b in 0x80:0xff, t in (nothing, 0x80:0xbf...)
        push!(names, p * String(t === nothing ? UInt8[b] : UInt8[b, t]))
    end
    @test count(s -> !isvalid(s), names) > 50000
    for u in 1:0xffff
        0xd800 <= u <= 0xdfff && continue
        push!(names, string(Char(u)), string('+', Char(u)), string(Char(u), Char(u)))
    end
    @test length(operators) > 600
    @test isempty(filter(s -> ours(s) != Base._isoperator(s), names))
    @test all(op -> Base._isoperator(op), operators)
end

@testset "the parser's operator predicates, ported, against libjulia's" begin
    @test PINNED !== nothing   # bash dev/fetch_julia.sh makes it
    # every name of every define, its dotted and suffixed forms: a suffix of julia_opsuffs.h (′ ₁ ² ˣ), a combining mark
    # (category Mn, a suffix by its category), and characters that are no suffix (x, ä, a letter after a combining mark)
    local names = PINNED === nothing ? String[] : pinned_names(PINNED[2])
    local suffixes = ["", "′", "″", "₁", "²", "ˣ", "̂", "x", "ä", "̂x", "!", "1"]
    local words = ["", "in", "isa", "foo", "Int", "x′", "π", "∂", "∇x", "+a", "−x", "√x", ".", "..", "...", "'", ".'", "->",
                   "<:", ">:", "::", "\$", "\$=", "&", "∈̂", "a", "_", "⊕ˣ", "→̂", "🢲", "𝟎", "..=", "+=′", "=>′", "++′", "x=", ".x"]
    local cases = unique(vcat([n * s for n in names for s in suffixes], words, [s for s in suffixes]))
    @test length(cases) > 7000
    local bad_op = [c for c in cases if W.jl_is_operator(c) != native_op(c)]
    local bad_syn = [c for c in cases if W.jl_is_syntactic_operator(c) != native_syn(c)]
    @test isempty(bad_op) || (@info "operator? disagrees" bad_op[1:min(end, 20)]; false)
    @test isempty(bad_syn) || (@info "syntactic-op? disagrees" bad_syn[1:min(end, 20)]; false)
    # a Symbol's name, Base's answer for the Symbol natively: the ported predicates over the name
    @test all(c -> (Base._isoperator(Symbol(c)) == (W.jl_is_operator(String(Symbol(c))) != 0)), cases)
    @test all(c -> (Base.is_syntactic_operator(Symbol(c)) == (W.jl_is_syntactic_operator(String(Symbol(c))) != 0)), cases)
    @test_throws ArgumentError Base._isoperator("+\0")
    # the suffix test over every code point
    @test all(wc -> W.jl_op_suffix_char(wc) == (ccall(:jl_op_suffix_char, Cint, (UInt32,), wc) != 0), UInt32(0):UInt32(0x10ffff))
    # the parser's own lists: the dotted forms computed (add-dots), the word operators out of operators
    if PINNED !== nothing
        local env = PINNED[2]
        @test "in" in env[Symbol("prec-comparison")] && !("in" in env[:operators]) && ".+" in env[Symbol("prec-plus")] && ".+" in env[:operators]
    end
    # each overlay at Base's own signature: Base defines one method of each, which the overlay table's answers alone
    @test length(methods(Base._isoperator)) == 1 && only(methods(Base._isoperator)).sig == Tuple{typeof(Base._isoperator), Any}
    @test length(methods(Base.is_syntactic_operator)) == 1 && only(methods(Base.is_syntactic_operator)).sig == Tuple{typeof(Base.is_syntactic_operator), Symbol}
    local mt = Core.Compiler.OverlayMethodTable(Base.get_world_counter(), W.METHOD_TABLE)
    @test Base._which(Tuple{typeof(Base._isoperator), Symbol}; method_table = mt).method.module === W
    @test Base._which(Tuple{typeof(Base._isoperator), String}; method_table = mt).method.module === W
    @test Base._which(Tuple{typeof(Base.is_syntactic_operator), Symbol}; method_table = mt).method.module === W
end

@testset "the overlays in a module, against native" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((OC.ops, (1,)), (OC.syn, (1,)), (OC.str_op, (0x2b, 0x61, 0x3d)), (OC.str_nul, (0x2b,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("julia_parser_ops/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
