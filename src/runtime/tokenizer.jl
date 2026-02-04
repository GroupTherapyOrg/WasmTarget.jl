# Tokenizer.jl - A WASM-compilable tokenizer for Julia source code
#
# This is a simplified ASCII-only tokenizer designed to be compiled to WASM.
# It produces RawTokens that identify token boundaries and kinds.
#
# Design:
# - Uses ByteBuffer for character I/O
# - Token kinds as Int32 constants (WASM-compatible enum)
# - RawToken struct stores kind and position range
# - All operations are WASM-compilable

export RawToken
export TK_EOF, TK_NUMBER, TK_IDENTIFIER, TK_OPERATOR, TK_WHITESPACE
export TK_LPAREN, TK_RPAREN, TK_LBRACKET, TK_RBRACKET, TK_LBRACE, TK_RBRACE
export TK_COMMA, TK_SEMICOLON, TK_NEWLINE, TK_STRING, TK_CHAR, TK_COMMENT
export TK_DOT, TK_COLON, TK_AT, TK_ERROR
export next_token
export scan_whitespace, scan_newline, scan_comment, scan_number
export scan_identifier, scan_string, scan_char, scan_operator
export is_whitespace_not_newline, is_exponent_char, is_sign_char, is_identifier_char_or_bang

# Token kinds as Int32 constants
# Using Int32 because WASM doesn't have enums, and this compiles directly to i32
const TK_EOF        = Int32(0)   # End of file
const TK_NUMBER     = Int32(1)   # Integer or float literal
const TK_IDENTIFIER = Int32(2)   # Variable/function name
const TK_OPERATOR   = Int32(3)   # Operators: + - * / etc.
const TK_WHITESPACE = Int32(4)   # Spaces, tabs
const TK_LPAREN     = Int32(5)   # (
const TK_RPAREN     = Int32(6)   # )
const TK_LBRACKET   = Int32(7)   # [
const TK_RBRACKET   = Int32(8)   # ]
const TK_LBRACE     = Int32(9)   # {
const TK_RBRACE     = Int32(10)  # }
const TK_COMMA      = Int32(11)  # ,
const TK_SEMICOLON  = Int32(12)  # ;
const TK_NEWLINE    = Int32(13)  # Line breaks
const TK_STRING     = Int32(14)  # "..." string literal
const TK_CHAR       = Int32(15)  # '...' character literal
const TK_COMMENT    = Int32(16)  # # comment
const TK_DOT        = Int32(17)  # .
const TK_COLON      = Int32(18)  # :
const TK_AT         = Int32(19)  # @
const TK_ERROR      = Int32(20)  # Unknown/error token

"""
    RawToken

A token from the lexer, storing the token kind and its position in the source.
Designed to be WASM-compilable (all fields are Int32).

Fields:
- kind: Token kind (one of the TK_* constants)
- start: Start position in source (1-indexed, inclusive)
- stop: End position in source (1-indexed, inclusive)
"""
struct RawToken
    kind::Int32
    start::Int32
    stop::Int32
end

# Helper for whitespace check without ||
@noinline function is_whitespace_not_newline(c::Int32)::Bool
    if c == Int32(32)  # space
        return true
    end
    if c == Int32(9)   # tab
        return true
    end
    return false
end

# Helper for exponent character check (e or E)
@noinline function is_exponent_char(c::Int32)::Bool
    if c == Int32(101)  # e
        return true
    end
    if c == Int32(69)   # E
        return true
    end
    return false
end

# Helper for sign character check (+ or -)
@noinline function is_sign_char(c::Int32)::Bool
    if c == Int32(43)   # +
        return true
    end
    if c == Int32(45)   # -
        return true
    end
    return false
end

# Helper for identifier char or !
@noinline function is_identifier_char_or_bang(c::Int32)::Bool
    if is_identifier_char(c)
        return true
    end
    if c == Int32(33)  # !
        return true
    end
    return false
end

"""
    next_token(buf::ByteBuffer)::RawToken

Read the next token from the buffer and return it.
Advances the buffer position past the token.
"""
@noinline function next_token(buf::ByteBuffer)::RawToken
    # Skip to first character
    if bb_eof(buf)
        pos = bb_position(buf)
        return RawToken(TK_EOF, pos, pos)
    end

    start_pos = bb_position(buf)
    c = bb_peek(buf)

    # Whitespace (not newline) - use helper to avoid ||
    if is_whitespace_not_newline(c)
        return scan_whitespace(buf, start_pos)
    end

    # Newline - use is_ascii_newline helper
    if is_ascii_newline(c)
        return scan_newline(buf, start_pos)
    end

    # Comment
    if c == Int32(35)  # #
        return scan_comment(buf, start_pos)
    end

    # Number
    if is_ascii_digit(c)
        return scan_number(buf, start_pos)
    end

    # Identifier
    if is_identifier_start(c)
        return scan_identifier(buf, start_pos)
    end

    # String
    if c == Int32(34)  # "
        return scan_string(buf, start_pos)
    end

    # Character
    if c == Int32(39)  # '
        return scan_char(buf, start_pos)
    end

    # Single-character tokens
    if c == Int32(40)  # (
        bb_read(buf)
        return RawToken(TK_LPAREN, start_pos, start_pos)
    end
    if c == Int32(41)  # )
        bb_read(buf)
        return RawToken(TK_RPAREN, start_pos, start_pos)
    end
    if c == Int32(91)  # [
        bb_read(buf)
        return RawToken(TK_LBRACKET, start_pos, start_pos)
    end
    if c == Int32(93)  # ]
        bb_read(buf)
        return RawToken(TK_RBRACKET, start_pos, start_pos)
    end
    if c == Int32(123)  # {
        bb_read(buf)
        return RawToken(TK_LBRACE, start_pos, start_pos)
    end
    if c == Int32(125)  # }
        bb_read(buf)
        return RawToken(TK_RBRACE, start_pos, start_pos)
    end
    if c == Int32(44)  # ,
        bb_read(buf)
        return RawToken(TK_COMMA, start_pos, start_pos)
    end
    if c == Int32(59)  # ;
        bb_read(buf)
        return RawToken(TK_SEMICOLON, start_pos, start_pos)
    end
    if c == Int32(46)  # .
        bb_read(buf)
        return RawToken(TK_DOT, start_pos, start_pos)
    end
    if c == Int32(58)  # :
        bb_read(buf)
        return RawToken(TK_COLON, start_pos, start_pos)
    end
    if c == Int32(64)  # @
        bb_read(buf)
        return RawToken(TK_AT, start_pos, start_pos)
    end

    # Operators (multi-character possible)
    if is_operator_char(c)
        return scan_operator(buf, start_pos)
    end

    # Unknown character - consume and report error
    bb_read(buf)
    return RawToken(TK_ERROR, start_pos, start_pos)
end

"""
    scan_whitespace(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan whitespace (spaces and tabs, not newlines).
"""
@noinline function scan_whitespace(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume first whitespace
    while !bb_eof(buf)
        c = bb_peek(buf)
        if !is_whitespace_not_newline(c)  # use helper instead of ||
            break
        end
        bb_read(buf)
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_WHITESPACE, start_pos, stop_pos)
end

"""
    scan_newline(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan newline (handles CR, LF, and CRLF).
"""
@noinline function scan_newline(buf::ByteBuffer, start_pos::Int32)::RawToken
    c = bb_read(buf)
    # Handle CRLF as single newline - use nested ifs to avoid &&
    if c == Int32(13)
        if !bb_eof(buf)
            if bb_peek(buf) == Int32(10)
                bb_read(buf)
            end
        end
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_NEWLINE, start_pos, stop_pos)
end

"""
    scan_comment(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan a line comment (# to end of line).
"""
@noinline function scan_comment(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume #
    while !bb_eof(buf)
        c = bb_peek(buf)
        if is_ascii_newline(c)  # use helper instead of ||
            break
        end
        bb_read(buf)
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_COMMENT, start_pos, stop_pos)
end

"""
    scan_number(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan a numeric literal (integer or float).
"""
@noinline function scan_number(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume first digit
    while !bb_eof(buf)
        c = bb_peek(buf)
        if is_ascii_digit(c)
            bb_read(buf)
        elseif c == Int32(46)  # . for floats
            bb_read(buf)
            # Continue reading digits after decimal - use nested ifs
            while !bb_eof(buf)
                if !is_ascii_digit(bb_peek(buf))
                    break
                end
                bb_read(buf)
            end
            break
        elseif is_exponent_char(c)  # e or E for exponent - use helper
            bb_read(buf)
            # Optional sign - use nested ifs and helper
            if !bb_eof(buf)
                if is_sign_char(bb_peek(buf))
                    bb_read(buf)
                end
            end
            # Exponent digits - use nested ifs
            while !bb_eof(buf)
                if !is_ascii_digit(bb_peek(buf))
                    break
                end
                bb_read(buf)
            end
            break
        else
            break
        end
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_NUMBER, start_pos, stop_pos)
end

"""
    scan_identifier(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan an identifier.
"""
@noinline function scan_identifier(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume first character
    while !bb_eof(buf)
        c = bb_peek(buf)
        if !is_identifier_char_or_bang(c)  # use helper instead of ||
            break
        end
        bb_read(buf)
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_IDENTIFIER, start_pos, stop_pos)
end

"""
    scan_string(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan a double-quoted string literal.
"""
@noinline function scan_string(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume opening "
    while !bb_eof(buf)
        c = bb_read(buf)
        if c == Int32(34)  # closing "
            break
        elseif c == Int32(92)  # backslash escape
            if !bb_eof(buf)
                bb_read(buf)  # consume escaped character
            end
        end
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_STRING, start_pos, stop_pos)
end

"""
    scan_char(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan a character literal.
"""
@noinline function scan_char(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume opening '
    while !bb_eof(buf)
        c = bb_read(buf)
        if c == Int32(39)  # closing '
            break
        elseif c == Int32(92)  # backslash escape
            if !bb_eof(buf)
                bb_read(buf)  # consume escaped character
            end
        end
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_CHAR, start_pos, stop_pos)
end

"""
    scan_operator(buf::ByteBuffer, start_pos::Int32)::RawToken

Scan an operator (possibly multi-character).
"""
@noinline function scan_operator(buf::ByteBuffer, start_pos::Int32)::RawToken
    bb_read(buf)  # consume first operator char
    # Continue reading operator characters (handles ==, !=, <=, etc.)
    while !bb_eof(buf)
        c = bb_peek(buf)
        if is_operator_char(c)
            bb_read(buf)
        else
            break
        end
    end
    stop_pos = bb_position(buf) - Int32(1)
    return RawToken(TK_OPERATOR, start_pos, stop_pos)
end
