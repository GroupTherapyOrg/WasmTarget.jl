# dart's mini JavaScript parser (pkg/js_ast/lib/src/builder.dart's MiniJsParser at the dart pin), the
# part that reads an object literal's property names, ported to read the import object the JS runtime
# hands a module (src/julia/runtime/rtutils.jl host_modules). dart2js and dart2wasm's own JS tooling
# read JS text with this parser; WasmTarget reads its runtime template's import object with it rather
# than with a pattern over the text. Kept: the tokenizer (getToken, getString, the character table) and
# the recursive descent from an object initializer through member expressions to primaries; dropped:
# the AST nodes (a property's value is parsed and discarded, only its name read), regexp literals,
# operators, calls and function literals, each of which rejects where it is met, located.

# dart's `_Category` enum, its index order kept: a category at or past `dot` is one character long
# (_singleCharCategory)
@quarantine "dart's mini JS parser names each character's category (pkg/js_ast/lib/src/builder.dart:394 _Category)" Core.Symbol const JS_CATEGORIES::Tuple{Vararg{Symbol}} = (
    :none, :alpha, :numeric, :string, :symbol, :assignment, :dot, :lparen, :rparen, :lbrace, :rbrace,
    :lsquare, :rsquare, :comma, :query, :colon, :semicolon, :arrow, :hash, :whitespace, :other)

# dart's `_Category._asciiTable`, one category per code unit below 128, as written
@quarantine "dart's mini JS parser's table of the ASCII code units' categories (pkg/js_ast/lib/src/builder.dart:417 _Category._asciiTable)" Core.Symbol const JS_ASCII_TABLE::Tuple{Vararg{Symbol}} = (
    :other, :other, :other, :other, :other, :other, :other, :other,        # 0-7
    :other, :whitespace, :whitespace, :other, :other, :whitespace,        # 8-13
    :other, :other, :other, :other, :other, :other, :other, :other,        # 14-21
    :other, :other, :other, :other, :other, :other, :other, :other,        # 22-29
    :other, :other, :whitespace,                                           # 30-32
    :symbol, :other, :hash, :alpha, :symbol, :symbol, :other,              # !"#$%&'
    :lparen, :rparen, :symbol, :symbol, :comma, :symbol, :dot, :symbol,    # ()*+,-./
    :numeric, :numeric, :numeric, :numeric, :numeric,                      # 01234
    :numeric, :numeric, :numeric, :numeric, :numeric,                      # 56789
    :colon, :semicolon, :symbol, :symbol, :symbol, :query, :other,         # :;<=>?@
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # ABCDEFGH
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # IJKLMNOP
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # QRSTUVWX
    :alpha, :alpha, :lsquare, :other, :rsquare, :symbol, :alpha, :other,   # YZ[\]^_`
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # abcdefgh
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # ijklmnop
    :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha, :alpha,        # qrstuvwx
    :alpha, :alpha, :lbrace, :symbol, :rbrace, :symbol,                    # yz{|}~
)

# dart's operator tables the tokenizer checks a symbol token against (BINARY_PRECEDENCE's keys, 17 an
# assignment, UNARY_OPERATORS, OPERATORS_THAT_LOOK_LIKE_IDENTIFIERS)
@quarantine "dart's mini JS parser's binary operators and their precedences (pkg/js_ast/lib/src/builder.dart:489 MiniJsParser.BINARY_PRECEDENCE)" Base.Dict const JS_BINARY_PRECEDENCE::Dict{String,Int} = Dict(
    "+=" => 17, "-=" => 17, "*=" => 17, "/=" => 17, "%=" => 17, "^=" => 17, "|=" => 17, "&=" => 17,
    "<<=" => 17, ">>=" => 17, ">>>=" => 17, "**=" => 17, "=" => 17, "||" => 14, "&&" => 13, "|" => 12,
    "^" => 11, "&" => 10, "!=" => 9, "==" => 9, "!==" => 9, "===" => 9, "<" => 8, "<=" => 8, ">=" => 8,
    ">" => 8, "in" => 8, "instanceof" => 8, "<<" => 7, ">>" => 7, ">>>" => 7, "+" => 6, "-" => 6,
    "*" => 5, "/" => 5, "%" => 5, "**" => 4)
@quarantine "dart's mini JS parser's unary operators (pkg/js_ast/lib/src/builder.dart:528 MiniJsParser.UNARY_OPERATORS)" Base.Set const JS_UNARY_OPERATORS::Set{String} = Set(
    ["++", "--", "+", "-", "~", "!", "typeof", "void", "delete", "await"])
@quarantine "dart's mini JS parser's operators spelt as identifiers (pkg/js_ast/lib/src/builder.dart:541 MiniJsParser.OPERATORS_THAT_LOOK_LIKE_IDENTIFIERS)" Base.Set const JS_OPERATORS_LIKE_IDENTIFIERS::Set{String} = Set(
    ["typeof", "void", "delete", "in", "instanceof", "await"])

"""
    MiniJsParser(src)

dart's MiniJsParser over `src` (its text as code units), its state as dart keeps it: the last token,
its category and position, the position read to, and whether a newline was skipped; the constructor
reads the first token, as dart's does.
"""
@quarantine "dart's mini JS parser holds its source and its last token (pkg/js_ast/lib/src/builder.dart:462 MiniJsParser)" Core.String mutable struct MiniJsParser
    const src::Vector{UInt16}
    last_category::Symbol
    last_token::String
    last_position::Int
    position::Int
    skipped_newline::Bool
    MiniJsParser(src::String) = (local p = new(transcode(UInt16, src), :none, "", 0, 0, false); js_get_token!(p); p)
end

# a category at or past `dot` is a token of one character (`]]` is two symbols)
@quarantine "dart's mini JS parser reads a one-character category's token alone (pkg/js_ast/lib/src/builder.dart:481 MiniJsParser._singleCharCategory)" Base.findfirst js_single_char_category(cat::Symbol)::Bool =
    findfirst(==(cat), JS_CATEGORIES)::Int >= findfirst(==(:dot), JS_CATEGORIES)::Int

@quarantine "dart's mini JS parser reads a code unit's category from its table (pkg/js_ast/lib/src/builder.dart:550 MiniJsParser._category)" Core.UInt16 js_category(code::UInt16)::Symbol =
    code >= length(JS_ASCII_TABLE) ? :other : JS_ASCII_TABLE[Int(code) + 1]

# dart's error: a located rejection naming the parser's message and the position, as MiniJsParserError
# names them
@quarantine "dart's mini JS parser throws its error at the position it read to (pkg/js_ast/lib/src/builder.dart:762 MiniJsParser.error)" Core.String js_error(p::MiniJsParser, message::String)::Union{} =
    reject!(Internal("src/julia/js_parser.jl MiniJsParser: $message at code unit $(p.last_position) of the JS text"), "MiniJsParser")

@quarantine "dart's mini JS parser reads a string literal, its escapes as it reads them (pkg/js_ast/lib/src/builder.dart:580 MiniJsParser.getString)" Core.UInt16 function js_get_string!(p::MiniJsParser, start_position::Int, quote_::UInt16)::String
    p.position = start_position + 1
    local value = UInt16[]
    while true
        p.position >= length(p.src) && js_error(p, "Unterminated literal")
        local code = p.src[(p.position += 1)]
        code == quote_ && break
        code == UInt16('\n') && js_error(p, "Unterminated literal")
        if code == UInt16('\\')
            p.position >= length(p.src) && js_error(p, "Unterminated literal")
            code = p.src[(p.position += 1)]
            if code == UInt16('f')
                push!(value, 12)
            elseif code == UInt16('n')
                push!(value, 10)
            elseif code == UInt16('r')
                push!(value, 13)
            elseif code == UInt16('t')
                push!(value, 8)
            elseif code == UInt16('\\') || code == UInt16('\'') || code == UInt16('"')
                push!(value, code)
            elseif code == UInt16('x') || code == UInt16('X')
                js_error(p, "Hex escapes not supported in string literals")
            elseif code == UInt16('u') || code == UInt16('U')
                js_error(p, "Unicode escapes not supported in string literals")
            elseif UInt16('0') <= code <= UInt16('9')
                js_error(p, "Numeric escapes not supported in string literals")
            else
                js_error(p, "Unknown escape U+$(string(code; base = 16, pad = 4))")
            end
            continue
        end
        push!(value, code)
    end
    return transcode(String, value)
end

# dart's getToken: whitespace and comments skipped, then one token, its category and text. A regexp
# literal (a token after `/`) is not taken: a `/` is its symbol, as dart reads it before getRegExp
@quarantine "dart's mini JS parser reads the next token (pkg/js_ast/lib/src/builder.dart:620 MiniJsParser.getToken)" Base.transcode function js_get_token!(p::MiniJsParser)::Nothing
    local src = p.src
    local n = length(src)
    local at(i::Int) = src[i + 1]   # dart's codeUnitAt, from 0
    p.skipped_newline = false
    while true
        p.position >= n && break
        local code = at(p.position)
        # Skip '//' and '/*' style comments.
        if code == UInt16('/') && p.position + 1 < n
            if at(p.position + 1) == UInt16('/')
                local next_position = something(findnext(==(UInt16('\n')), src, p.position + 1), n + 1) - 1
                p.position = next_position
                continue
            elseif at(p.position + 1) == UInt16('*')
                local k = p.position + 2
                while k + 1 < n && !(at(k) == UInt16('*') && at(k + 1) == UInt16('/'))
                    k += 1
                end
                k + 1 < n || js_error(p, "Unterminated comment")
                p.position = k + 2
                continue
            end
        end
        js_category(code) === :whitespace || break
        code == UInt16('\n') && (p.skipped_newline = true)
        p.position += 1
    end
    if p.position == n
        p.last_category = :none
        p.last_token = ""
        p.last_position = p.position
        return nothing
    end
    local code = at(p.position)
    p.last_position = p.position
    if code == UInt16('\'') || code == UInt16('"')
        # String literal.
        p.last_category = :string
        p.last_token = js_get_string!(p, p.position, code)
    elseif code == UInt16('0') && p.position + 2 < n && at(p.position + 1) == UInt16('x')
        # Hex literal.
        p.position += 2
        while p.position < n
            local cat = js_category(at(p.position))
            cat === :numeric || cat === :alpha || break
            p.position += 1
        end
        p.last_category = :numeric
        p.last_token = transcode(String, src[p.last_position+1:p.position])
        tryparse(Int, p.last_token) === nothing && js_error(p, "Unparseable number")
    elseif code == UInt16('/')
        # Tokens that start with / are special due to regexp literals.
        p.last_category = :symbol
        p.position += 1
        p.position < n && at(p.position) == UInt16('=') && (p.position += 1)
        p.last_token = transcode(String, src[p.last_position+1:p.position])
    else
        # All other tokens handled here.
        local cat = js_category(at(p.position))
        local new_cat = :none
        while true
            p.position += 1
            p.position == n && break
            local c = at(p.position)
            # !, ~ and / never continue a token: !! and ~~ are two tokens, != is one
            new_cat = (c == UInt16('!') || c == UInt16('/') || c == UInt16('~')) ? :none : js_category(c)
            !js_single_char_category(cat) &&
                (cat === new_cat || (cat === :alpha && new_cat === :numeric) || (cat === :numeric && new_cat === :dot)) || break
        end
        p.last_category = cat
        p.last_token = transcode(String, src[p.last_position+1:p.position])
        if cat === :numeric
            tryparse(Float64, p.last_token) === nothing && js_error(p, "Unparseable number")
        elseif cat === :symbol
            if p.last_token == "=>"
                p.last_category = :arrow
            else
                local binary_precedence = get(JS_BINARY_PRECEDENCE, p.last_token, nothing)
                binary_precedence === nothing && !(p.last_token in JS_UNARY_OPERATORS) && js_error(p, "Unknown operator")
                binary_precedence == 17 && (p.last_category = :assignment)
            end
        elseif cat === :alpha
            p.last_token in JS_OPERATORS_LIKE_IDENTIFIERS && (p.last_category = :symbol)
        end
    end
    return nothing
end

@quarantine "dart's mini JS parser requires a token of a category (pkg/js_ast/lib/src/builder.dart:725 MiniJsParser._expectCategory)" Core.Symbol function js_expect_category!(p::MiniJsParser, cat::Symbol)::Nothing
    cat === p.last_category || js_error(p, "Expected $cat")
    js_get_token!(p)
    return nothing
end

@quarantine "dart's mini JS parser takes a token of a category when it is next (pkg/js_ast/lib/src/builder.dart:730 MiniJsParser._acceptCategory)" Core.Symbol function js_accept_category!(p::MiniJsParser, cat::Symbol)::Bool
    cat === p.last_category || return false
    js_get_token!(p)
    return true
end

# dart's parsePrimary, the forms an import object's value takes: a name, a string or number, an object
# or array literal; `true`, `false`, `null` and `this` are names here, their nodes not built. A
# parenthesized expression, a function, a regexp or a hole rejects, located
@quarantine "dart's mini JS parser reads a primary expression (pkg/js_ast/lib/src/builder.dart:784 MiniJsParser.parsePrimary)" Base.:(==) function js_parse_primary!(p::MiniJsParser)::Nothing
    local last = p.last_token
    if js_accept_category!(p, :alpha)
        last == "function" && js_error(p, "a function literal, which the import object's reader does not take")
    elseif js_accept_category!(p, :string) || js_accept_category!(p, :numeric)
    elseif js_accept_category!(p, :lbrace)
        js_parse_object_initializer!(p)
    elseif js_accept_category!(p, :lsquare)
        while true
            js_accept_category!(p, :comma) && continue
            js_accept_category!(p, :rsquare) && break
            js_parse_assignment!(p)
            js_accept_category!(p, :rsquare) && break
            js_expect_category!(p, :comma)
        end
    else
        js_error(p, "Expected primary expression")
    end
    return nothing
end

# dart's parseObjectInitializer: its properties until the closing brace, comma separated, a trailing
# comma taken; the property names, as dart's ObjectInitializer holds them, a hole's `nothing`
@quarantine "dart's mini JS parser reads an object initializer (pkg/js_ast/lib/src/builder.dart:888 MiniJsParser.parseObjectInitializer)" Core.String function js_parse_object_initializer!(p::MiniJsParser)::Vector{Union{String,Nothing}}
    local properties = Union{String,Nothing}[]
    while true
        js_accept_category!(p, :rbrace) && break
        push!(properties, js_parse_method_definition_or_property!(p))
        js_accept_category!(p, :rbrace) && break
        js_expect_category!(p, :comma)
    end
    return properties
end

# dart's parseMethodDefinitionOrProperty: a name (an identifier, a string, an operator spelt as one,
# or a hole, `#name`) and, after a colon, its value; a method definition rejects, located
@quarantine "dart's mini JS parser reads an object initializer's property (pkg/js_ast/lib/src/builder.dart:899 MiniJsParser.parseMethodDefinitionOrProperty)" Core.String function js_parse_method_definition_or_property!(p::MiniJsParser)::Union{String,Nothing}
    local identifier = p.last_token
    local property_name::Union{String,Nothing} = identifier
    if js_accept_category!(p, :alpha) || js_accept_category!(p, :string) || js_accept_category!(p, :symbol)
    elseif js_accept_category!(p, :hash)
        # parseHash: a named hole's name taken, the property's name the template's to fill
        js_accept_category!(p, :alpha)
        property_name = nothing
    else
        js_error(p, "Expected property name")
    end
    js_accept_category!(p, :colon) || js_error(p, "a method definition, which the import object's reader does not take")
    js_parse_assignment!(p)
    return property_name
end

# dart's parseMember: a primary, then its `.name` and `[expression]` accesses (getDotRhs)
@quarantine "dart's mini JS parser reads a member expression (pkg/js_ast/lib/src/builder.dart:929 MiniJsParser.parseMember)" Base.in function js_parse_member!(p::MiniJsParser)::Nothing
    js_parse_primary!(p)
    while true
        if js_accept_category!(p, :dot)
            # getDotRhs: an identifier, or an operator spelt as one
            local identifier = p.last_token
            if js_accept_category!(p, :symbol)
                identifier in JS_OPERATORS_LIKE_IDENTIFIERS || js_error(p, "Expected alphanumeric identifier")
            else
                js_expect_category!(p, :alpha)
            end
        elseif js_accept_category!(p, :lsquare)
            js_parse_assignment!(p)
            js_expect_category!(p, :rsquare)
        else
            break
        end
    end
    return nothing
end

# dart's parseAssignment reaches parseMember through its operators' levels; an import object's value
# is a member expression, and an operator, call or `new` after one rejects, located
@quarantine "dart's mini JS parser reads an assignment expression down to its member expression (pkg/js_ast/lib/src/builder.dart:929 MiniJsParser.parseMember)" Base.in function js_parse_assignment!(p::MiniJsParser)::Nothing
    p.last_category === :alpha && p.last_token == "new" && js_error(p, "a new expression, which the import object's reader does not take")
    js_parse_member!(p)
    p.last_category in (:comma, :rbrace, :rsquare, :none) ||
        js_error(p, "the operator or call $(repr(p.last_token)), which the import object's reader does not take")
    return nothing
end
