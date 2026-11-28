# The helpers test/src/julia_parser_ops.jl and test/src/unicode.jl share (each file includes this into its own
# module): julia-parser.scm's defines read at the julia pin, as femtolisp reads and evaluates them, never the port's own
# copies; and C's operator? walked over a name where flisp's strip-op-suffix reads past its NUL, the expected value
# of each name whose C answer reads bytes C never wrote (dev/formal/StripWalk.tla).
using Test, WasmTarget

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
    local dir = WasmTarget._c_pin_checkout(:julia)
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

# C's operator? over a name as flisp's strip-op-suffix walks it (julia/src/flisp/julia_extensions.c:245) in the
# memory dev/formal/StripWalk.tla's Mem(name, ZeroGarbage) holds: the name's bytes, the NUL flisp's strcpy stores
# after them (julia/src/flisp/flisp.c:217 mk_symbol), then zeros where C reads bytes it leaves undefined. The walk
# is C's loop as written, `while (op[i])`, each character u8_nextchar's (julia/src/support/utf8.c:269: u8_seqlen's
# bytes by trailingBytesForUTF8, shifted in six bits at a time, offsetsFromUTF8 subtracted; the two tables the
# port's copies, which test/src/unicode.jl re-reads from the pinned utf8.c) and the suffix test libjulia's own
# jl_op_suffix_char; the name stripped as strncpy copies it (fl_julia_strip_op_suffix), then maybe-strip-op-suffix
# (julia-parser.scm:66) and membership in the pinned parser's operators. Also whether C's answer is defined: every
# character the walk decodes ends at or before the NUL. A character that reads past the NUL decodes bytes C leaves
# undefined (a three- to six-byte lead cut off by the name's end, "+\xe3" reading 0xe3, the NUL and one byte past
# it), and libjulia's answer there is what those bytes happen to be: malloc padding, or the next block. A walk
# that only steps past the NUL after a character ending at it reads op[n+1] but answers the name whatever it is
# (StripPastNulIsName), so its answer is defined
function c_operator_over_zeros(s::String, operators::Vector{String}, no_suffix::Vector{String})::Tuple{Bool,Bool}
    local n = ncodeunits(s)
    local mem = vcat(Vector{UInt8}(codeunits(s)), zeros(UInt8, 8))   # op[k] is mem[k + 1]; op[n] the NUL
    local i = 0
    local defined = true
    while mem[i+1] != 0x00
        local sz = Int(WasmTarget.U8_TRAILING_BYTES[Int(mem[i+1])+1]) + 1
        local ch = UInt32(0)
        for k in 0:sz-1
            ch = (ch << 6) + mem[i+k+1]
        end
        ch -= WasmTarget.U8_OFFSETS_FROM_UTF8[sz]
        i + sz - 1 > n && (defined = false)
        ccall(:jl_op_suffix_char, Cint, (UInt32,), ch) != 0 && break
        i += sz
    end
    local op_ = mem[i+1] == 0x00 || i == 0 ? s : String(mem[1:i])
    local op = op_ == s || op_ in no_suffix ? s : op_
    return op in operators, defined
end
