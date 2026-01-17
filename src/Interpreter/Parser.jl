# Julia Interpreter Parser - Written in WasmTarget-compatible Julia
# This parser consumes tokens from Tokenizer.jl and builds an AST.
#
# Design:
# - Recursive descent parser
# - AST nodes as mutable structs (WasmGC compatible)
# - All nodes have a type tag for dynamic dispatch in evaluator
# - Uses Int32 for all indices and tag values (WASM friendly)
#
# Grammar (subset of Julia):
#   program     → statement* EOF
#   statement   → assignment | if_stmt | while_stmt | for_stmt | func_def | return_stmt | expr_stmt
#   assignment  → IDENT "=" expression
#   if_stmt     → "if" expression statement* ("elseif" expression statement*)* ("else" statement*)? "end"
#   while_stmt  → "while" expression statement* "end"
#   for_stmt    → "for" IDENT "in" expression statement* "end"
#   func_def    → "function" IDENT "(" params? ")" statement* "end"
#   return_stmt → "return" expression?
#   expr_stmt   → expression (SEMICOLON | NEWLINE)?
#   expression  → logic_or
#   logic_or    → logic_and ("||" logic_and)*
#   logic_and   → equality ("&&" equality)*
#   equality    → comparison (("==" | "!=") comparison)*
#   comparison  → term (("<" | "<=" | ">" | ">=") term)*
#   term        → factor (("+" | "-") factor)*
#   factor      → unary (("*" | "/" | "%") unary)*
#   unary       → ("-" | "!") unary | power
#   power       → call ("^" unary)?
#   call        → primary ("(" args? ")")?
#   primary     → INT | FLOAT | STRING | "true" | "false" | "nothing" | IDENT | "(" expression ")"

export ASTNode, ASTKind
export AST_ERROR, AST_INT_LIT, AST_FLOAT_LIT, AST_BOOL_LIT, AST_STRING_LIT, AST_NOTHING_LIT
export AST_IDENT, AST_BINARY, AST_UNARY, AST_CALL, AST_ASSIGN
export AST_IF, AST_WHILE, AST_FOR, AST_FUNC, AST_RETURN, AST_BLOCK, AST_PROGRAM
export Parser, parser_new, parse_program, parse_expression
export ast_int, ast_float, ast_bool, ast_nothing, ast_ident, ast_string
export ast_binary, ast_unary, ast_call, ast_assign
export ast_if, ast_while, ast_for, ast_func, ast_return, ast_block, ast_program

# ============================================================================
# AST Node Kind Constants
# ============================================================================
const AST_ERROR       = Int32(0)   # Parse error
const AST_INT_LIT     = Int32(1)   # Integer literal
const AST_FLOAT_LIT   = Int32(2)   # Float literal
const AST_BOOL_LIT    = Int32(3)   # Boolean literal (true/false)
const AST_STRING_LIT  = Int32(4)   # String literal
const AST_NOTHING_LIT = Int32(5)   # nothing literal
const AST_IDENT       = Int32(6)   # Identifier
const AST_BINARY      = Int32(7)   # Binary operation (left op right)
const AST_UNARY       = Int32(8)   # Unary operation (op operand)
const AST_CALL        = Int32(9)   # Function call
const AST_ASSIGN      = Int32(10)  # Assignment (ident = expr)
const AST_IF          = Int32(11)  # If statement
const AST_WHILE       = Int32(12)  # While loop
const AST_FOR         = Int32(13)  # For loop
const AST_FUNC        = Int32(14)  # Function definition
const AST_RETURN      = Int32(15)  # Return statement
const AST_BLOCK       = Int32(16)  # Block of statements
const AST_PROGRAM     = Int32(17)  # Program (top-level)

# ============================================================================
# Binary Operator Constants
# ============================================================================
const OP_ADD  = Int32(1)   # +
const OP_SUB  = Int32(2)   # -
const OP_MUL  = Int32(3)   # *
const OP_DIV  = Int32(4)   # /
const OP_MOD  = Int32(5)   # %
const OP_POW  = Int32(6)   # ^
const OP_EQ   = Int32(7)   # ==
const OP_NE   = Int32(8)   # !=
const OP_LT   = Int32(9)   # <
const OP_LE   = Int32(10)  # <=
const OP_GT   = Int32(11)  # >
const OP_GE   = Int32(12)  # >=
const OP_AND  = Int32(13)  # &&
const OP_OR   = Int32(14)  # ||

# ============================================================================
# Unary Operator Constants
# ============================================================================
const OP_NEG  = Int32(1)   # - (negation)
const OP_NOT  = Int32(2)   # ! or not (logical not)

# ============================================================================
# AST Node Structure
# ============================================================================

"""
ASTNode - A node in the abstract syntax tree.

All nodes have a kind field that identifies the node type.
Other fields are used depending on the node kind:

- INT_LIT: int_value
- FLOAT_LIT: float_value
- BOOL_LIT: int_value (0=false, 1=true)
- NOTHING_LIT: (no extra fields)
- STRING_LIT: str_start, str_length (reference into source)
- IDENT: str_start, str_length (reference into source)
- BINARY: op, left, right
- UNARY: op, left
- CALL: left (callee), children (arguments)
- ASSIGN: left (ident), right (value)
- IF: left (condition), children (then body), right (else body or nothing)
- WHILE: left (condition), children (body)
- FOR: left (iterator var), right (iterable), children (body)
- FUNC: str_start/str_length (name), children (params + body)
- RETURN: left (expression or nothing)
- BLOCK: children (statements)
- PROGRAM: children (statements)
"""
mutable struct ASTNode
    kind::Int32           # Node type (AST_* constant)
    op::Int32             # Operator for BINARY/UNARY
    int_value::Int32      # Integer value or bool (0/1)
    float_value::Float32  # Float value
    str_start::Int32      # Start position in source (for IDENT/STRING)
    str_length::Int32     # Length in source (for IDENT/STRING)
    left::Union{ASTNode, Nothing}    # Left child
    right::Union{ASTNode, Nothing}   # Right child
    children::Vector{ASTNode}        # Children (for BLOCK, CALL args, etc.)
    num_children::Int32              # Number of children used
end

# ============================================================================
# AST Node Constructors
# ============================================================================

"""
Create an empty/error AST node.
"""
@noinline function ast_error()::ASTNode
    return ASTNode(
        AST_ERROR, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create an integer literal node.
"""
@noinline function ast_int(value::Int32)::ASTNode
    return ASTNode(
        AST_INT_LIT, Int32(0), value, Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a float literal node.
"""
@noinline function ast_float(value::Float32)::ASTNode
    return ASTNode(
        AST_FLOAT_LIT, Int32(0), Int32(0), value,
        Int32(0), Int32(0), nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a boolean literal node.
"""
@noinline function ast_bool(value::Int32)::ASTNode
    return ASTNode(
        AST_BOOL_LIT, Int32(0), value, Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a nothing literal node.
"""
@noinline function ast_nothing()::ASTNode
    return ASTNode(
        AST_NOTHING_LIT, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a string literal node (stores position in source).
"""
@noinline function ast_string(start::Int32, length::Int32)::ASTNode
    return ASTNode(
        AST_STRING_LIT, Int32(0), Int32(0), Float32(0.0),
        start, length, nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create an identifier node (stores position in source).
"""
@noinline function ast_ident(start::Int32, length::Int32)::ASTNode
    return ASTNode(
        AST_IDENT, Int32(0), Int32(0), Float32(0.0),
        start, length, nothing, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a binary operation node.
"""
@noinline function ast_binary(op::Int32, left::ASTNode, right::ASTNode)::ASTNode
    return ASTNode(
        AST_BINARY, op, Int32(0), Float32(0.0),
        Int32(0), Int32(0), left, right,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a unary operation node.
"""
@noinline function ast_unary(op::Int32, operand::ASTNode)::ASTNode
    return ASTNode(
        AST_UNARY, op, Int32(0), Float32(0.0),
        Int32(0), Int32(0), operand, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a function call node.
"""
@noinline function ast_call(callee::ASTNode, args::Vector{ASTNode}, num_args::Int32)::ASTNode
    return ASTNode(
        AST_CALL, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), callee, nothing,
        args, num_args
    )
end

"""
Create an assignment node.
"""
@noinline function ast_assign(ident::ASTNode, value::ASTNode)::ASTNode
    return ASTNode(
        AST_ASSIGN, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), ident, value,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create an if statement node.
"""
@noinline function ast_if(condition::ASTNode, then_body::Vector{ASTNode}, num_then::Int32, else_body::Union{ASTNode, Nothing})::ASTNode
    return ASTNode(
        AST_IF, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), condition, else_body,
        then_body, num_then
    )
end

"""
Create a while statement node.
"""
@noinline function ast_while(condition::ASTNode, body::Vector{ASTNode}, num_stmts::Int32)::ASTNode
    return ASTNode(
        AST_WHILE, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), condition, nothing,
        body, num_stmts
    )
end

"""
Create a for statement node.
"""
@noinline function ast_for(var::ASTNode, iterable::ASTNode, body::Vector{ASTNode}, num_stmts::Int32)::ASTNode
    return ASTNode(
        AST_FOR, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), var, iterable,
        body, num_stmts
    )
end

"""
Create a function definition node.
"""
@noinline function ast_func(name_start::Int32, name_length::Int32, params::Vector{ASTNode}, body::Vector{ASTNode}, num_params::Int32, num_body::Int32)::ASTNode
    # Store params followed by body in children
    # num_children = num_params, and body starts after params
    all_children = Vector{ASTNode}(undef, num_params + num_body)
    i = Int32(1)
    while i <= num_params
        all_children[i] = params[i]
        i = i + Int32(1)
    end
    j = Int32(1)
    while j <= num_body
        all_children[num_params + j] = body[j]
        j = j + Int32(1)
    end
    return ASTNode(
        AST_FUNC, Int32(0), num_params, Float32(0.0),
        name_start, name_length, nothing, nothing,
        all_children, num_params + num_body
    )
end

"""
Create a return statement node.
"""
@noinline function ast_return(value::Union{ASTNode, Nothing})::ASTNode
    return ASTNode(
        AST_RETURN, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), value, nothing,
        Vector{ASTNode}(undef, 0), Int32(0)
    )
end

"""
Create a block node.
"""
@noinline function ast_block(statements::Vector{ASTNode}, num_stmts::Int32)::ASTNode
    return ASTNode(
        AST_BLOCK, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        statements, num_stmts
    )
end

"""
Create a program node.
"""
@noinline function ast_program(statements::Vector{ASTNode}, num_stmts::Int32)::ASTNode
    return ASTNode(
        AST_PROGRAM, Int32(0), Int32(0), Float32(0.0),
        Int32(0), Int32(0), nothing, nothing,
        statements, num_stmts
    )
end

# ============================================================================
# Parser Structure
# ============================================================================

"""
Parser - Holds the parser state.
"""
mutable struct Parser
    source::String        # Original source code
    tokens::TokenList     # Tokens from lexer
    pos::Int32            # Current token position
    had_error::Int32      # 1 if parsing error occurred
end

"""
Create a new parser from source code.
"""
@noinline function parser_new(source::String, max_tokens::Int32)::Parser
    tokens = tokenize(source, max_tokens)
    return Parser(source, tokens, Int32(1), Int32(0))
end

# ============================================================================
# Parser Helpers
# ============================================================================

"""
Get current token.
"""
@noinline function parser_current(p::Parser)::Token
    return token_list_get(p.tokens, p.pos)
end

"""
Get current token type.
"""
@noinline function parser_current_type(p::Parser)::Int32
    return token_list_get(p.tokens, p.pos).type
end

"""
Check if current token matches a type.
"""
@noinline function parser_check(p::Parser, type::Int32)::Int32
    if parser_current_type(p) == type
        return Int32(1)
    end
    return Int32(0)
end

"""
Advance to next token.
"""
@noinline function parser_advance!(p::Parser)::Token
    tok = parser_current(p)
    if tok.type != TOK_EOF
        p.pos = p.pos + Int32(1)
    end
    return tok
end

"""
Consume a token of the expected type or mark error.
"""
@noinline function parser_consume!(p::Parser, type::Int32)::Token
    if parser_check(p, type) == Int32(1)
        return parser_advance!(p)
    end
    p.had_error = Int32(1)
    return parser_current(p)
end

"""
Skip newlines and semicolons.
"""
@noinline function parser_skip_terminators!(p::Parser)::Nothing
    while true
        t = parser_current_type(p)
        if t == TOK_NEWLINE
            parser_advance!(p)
        elseif t == TOK_SEMICOLON
            parser_advance!(p)
        else
            break
        end
    end
    return nothing
end

"""
Check if at end of tokens.
"""
@noinline function parser_at_end(p::Parser)::Int32
    if parser_current_type(p) == TOK_EOF
        return Int32(1)
    end
    return Int32(0)
end

# ============================================================================
# Expression Parsing (Pratt-style precedence climbing)
# ============================================================================

"""
Parse a primary expression (literals, identifiers, parenthesized expressions).
"""
@noinline function parse_primary(p::Parser)::ASTNode
    tok = parser_current(p)
    t = tok.type

    # Integer literal
    if t == TOK_INT
        parser_advance!(p)
        return ast_int(tok.int_value)
    end

    # Float literal
    if t == TOK_FLOAT
        parser_advance!(p)
        return ast_float(tok.float_value)
    end

    # String literal
    if t == TOK_STRING
        parser_advance!(p)
        # Strip quotes: start+1, length-2
        return ast_string(tok.start + Int32(1), tok.length - Int32(2))
    end

    # true literal
    if t == TOK_KW_TRUE
        parser_advance!(p)
        return ast_bool(Int32(1))
    end

    # false literal
    if t == TOK_KW_FALSE
        parser_advance!(p)
        return ast_bool(Int32(0))
    end

    # nothing literal
    if t == TOK_KW_NOTHING
        parser_advance!(p)
        return ast_nothing()
    end

    # Identifier
    if t == TOK_IDENT
        parser_advance!(p)
        return ast_ident(tok.start, tok.length)
    end

    # Parenthesized expression
    if t == TOK_LPAREN
        parser_advance!(p)  # Skip '('
        expr = parse_expression(p)
        parser_consume!(p, TOK_RPAREN)  # Expect ')'
        return expr
    end

    # Error
    p.had_error = Int32(1)
    return ast_error()
end

"""
Parse a function call (after callee has been parsed).
"""
@noinline function parse_call_args(p::Parser, callee::ASTNode)::ASTNode
    # Max 16 arguments
    args = Vector{ASTNode}(undef, 16)
    num_args = Int32(0)

    # Parse arguments
    if parser_check(p, TOK_RPAREN) == Int32(0)
        # First argument
        args[1] = parse_expression(p)
        num_args = Int32(1)

        # More arguments
        while parser_check(p, TOK_COMMA) == Int32(1)
            parser_advance!(p)  # Skip comma
            if num_args < Int32(16)
                num_args = num_args + Int32(1)
                args[num_args] = parse_expression(p)
            end
        end
    end

    parser_consume!(p, TOK_RPAREN)  # Expect ')'
    return ast_call(callee, args, num_args)
end

"""
Parse call expression (function calls).
"""
@noinline function parse_call(p::Parser)::ASTNode
    expr = parse_primary(p)

    # Check for function call
    while parser_check(p, TOK_LPAREN) == Int32(1)
        parser_advance!(p)  # Skip '('
        expr = parse_call_args(p, expr)
    end

    return expr
end

"""
Parse power expression (right associative).
"""
@noinline function parse_power(p::Parser)::ASTNode
    left = parse_call(p)

    if parser_check(p, TOK_CARET) == Int32(1)
        parser_advance!(p)
        right = parse_unary(p)  # Right associative
        return ast_binary(OP_POW, left, right)
    end

    return left
end

"""
Parse unary expression.
"""
@noinline function parse_unary(p::Parser)::ASTNode
    t = parser_current_type(p)

    # Unary minus
    if t == TOK_MINUS
        parser_advance!(p)
        operand = parse_unary(p)
        return ast_unary(OP_NEG, operand)
    end

    # Unary not
    if t == TOK_KW_NOT
        parser_advance!(p)
        operand = parse_unary(p)
        return ast_unary(OP_NOT, operand)
    end

    return parse_power(p)
end

"""
Parse factor (*, /, %).
"""
@noinline function parse_factor(p::Parser)::ASTNode
    left = parse_unary(p)

    while true
        t = parser_current_type(p)
        if t == TOK_STAR
            parser_advance!(p)
            right = parse_unary(p)
            left = ast_binary(OP_MUL, left, right)
        elseif t == TOK_SLASH
            parser_advance!(p)
            right = parse_unary(p)
            left = ast_binary(OP_DIV, left, right)
        elseif t == TOK_PERCENT
            parser_advance!(p)
            right = parse_unary(p)
            left = ast_binary(OP_MOD, left, right)
        else
            break
        end
    end

    return left
end

"""
Parse term (+, -).
"""
@noinline function parse_term(p::Parser)::ASTNode
    left = parse_factor(p)

    while true
        t = parser_current_type(p)
        if t == TOK_PLUS
            parser_advance!(p)
            right = parse_factor(p)
            left = ast_binary(OP_ADD, left, right)
        elseif t == TOK_MINUS
            parser_advance!(p)
            right = parse_factor(p)
            left = ast_binary(OP_SUB, left, right)
        else
            break
        end
    end

    return left
end

"""
Parse comparison (<, <=, >, >=).
"""
@noinline function parse_comparison(p::Parser)::ASTNode
    left = parse_term(p)

    while true
        t = parser_current_type(p)
        if t == TOK_LT
            parser_advance!(p)
            right = parse_term(p)
            left = ast_binary(OP_LT, left, right)
        elseif t == TOK_LE
            parser_advance!(p)
            right = parse_term(p)
            left = ast_binary(OP_LE, left, right)
        elseif t == TOK_GT
            parser_advance!(p)
            right = parse_term(p)
            left = ast_binary(OP_GT, left, right)
        elseif t == TOK_GE
            parser_advance!(p)
            right = parse_term(p)
            left = ast_binary(OP_GE, left, right)
        else
            break
        end
    end

    return left
end

"""
Parse equality (==, !=).
"""
@noinline function parse_equality(p::Parser)::ASTNode
    left = parse_comparison(p)

    while true
        t = parser_current_type(p)
        if t == TOK_EQ_EQ
            parser_advance!(p)
            right = parse_comparison(p)
            left = ast_binary(OP_EQ, left, right)
        elseif t == TOK_NE
            parser_advance!(p)
            right = parse_comparison(p)
            left = ast_binary(OP_NE, left, right)
        else
            break
        end
    end

    return left
end

"""
Parse logical and (&&).
"""
@noinline function parse_logic_and(p::Parser)::ASTNode
    left = parse_equality(p)

    while parser_check(p, TOK_AMP_AMP) == Int32(1)
        parser_advance!(p)
        right = parse_equality(p)
        left = ast_binary(OP_AND, left, right)
    end

    return left
end

"""
Parse logical or (||).
"""
@noinline function parse_logic_or(p::Parser)::ASTNode
    left = parse_logic_and(p)

    while parser_check(p, TOK_PIPE_PIPE) == Int32(1)
        parser_advance!(p)
        right = parse_logic_and(p)
        left = ast_binary(OP_OR, left, right)
    end

    return left
end

"""
Parse an expression (top level expression parser).
"""
@noinline function parse_expression(p::Parser)::ASTNode
    return parse_logic_or(p)
end

# ============================================================================
# Statement Parsing
# ============================================================================

"""
Check if current token can start a statement.
"""
@noinline function is_statement_start(p::Parser)::Int32
    t = parser_current_type(p)

    if t == TOK_KW_IF
        return Int32(1)
    end
    if t == TOK_KW_WHILE
        return Int32(1)
    end
    if t == TOK_KW_FOR
        return Int32(1)
    end
    if t == TOK_KW_FUNCTION
        return Int32(1)
    end
    if t == TOK_KW_RETURN
        return Int32(1)
    end
    if t == TOK_KW_LET
        return Int32(1)
    end
    if t == TOK_IDENT
        return Int32(1)
    end
    if t == TOK_INT
        return Int32(1)
    end
    if t == TOK_FLOAT
        return Int32(1)
    end
    if t == TOK_STRING
        return Int32(1)
    end
    if t == TOK_LPAREN
        return Int32(1)
    end
    if t == TOK_MINUS
        return Int32(1)
    end
    if t == TOK_KW_TRUE
        return Int32(1)
    end
    if t == TOK_KW_FALSE
        return Int32(1)
    end
    if t == TOK_KW_NOTHING
        return Int32(1)
    end
    if t == TOK_KW_NOT
        return Int32(1)
    end

    return Int32(0)
end

"""
Parse a block of statements until 'end', 'else', 'elseif', or EOF.
"""
@noinline function parse_block_body(p::Parser, max_stmts::Int32)::Tuple{Vector{ASTNode}, Int32}
    stmts = Vector{ASTNode}(undef, max_stmts)
    num_stmts = Int32(0)

    parser_skip_terminators!(p)

    while true
        t = parser_current_type(p)
        # Stop at block terminators
        if t == TOK_KW_END
            break
        end
        if t == TOK_KW_ELSE
            break
        end
        if t == TOK_KW_ELSEIF
            break
        end
        if t == TOK_EOF
            break
        end

        if is_statement_start(p) == Int32(1)
            if num_stmts < max_stmts
                num_stmts = num_stmts + Int32(1)
                stmts[num_stmts] = parse_statement(p)
            else
                # Skip statement if full
                parse_statement(p)
            end
            parser_skip_terminators!(p)
        else
            # Unknown token - skip it
            parser_advance!(p)
        end
    end

    return (stmts, num_stmts)
end

"""
Parse if statement.
"""
@noinline function parse_if_statement(p::Parser)::ASTNode
    parser_advance!(p)  # Skip 'if'

    condition = parse_expression(p)
    (then_stmts, num_then) = parse_block_body(p, Int32(64))

    # Handle else/elseif
    else_node::Union{ASTNode, Nothing} = nothing

    if parser_check(p, TOK_KW_ELSEIF) == Int32(1)
        # elseif becomes nested if
        else_node = parse_if_statement(p)
    elseif parser_check(p, TOK_KW_ELSE) == Int32(1)
        parser_advance!(p)  # Skip 'else'
        (else_stmts, num_else) = parse_block_body(p, Int32(64))
        else_node = ast_block(else_stmts, num_else)
        parser_consume!(p, TOK_KW_END)  # Expect 'end'
    else
        parser_consume!(p, TOK_KW_END)  # Expect 'end'
    end

    return ast_if(condition, then_stmts, num_then, else_node)
end

"""
Parse while statement.
"""
@noinline function parse_while_statement(p::Parser)::ASTNode
    parser_advance!(p)  # Skip 'while'

    condition = parse_expression(p)
    (body_stmts, num_body) = parse_block_body(p, Int32(64))

    parser_consume!(p, TOK_KW_END)  # Expect 'end'

    return ast_while(condition, body_stmts, num_body)
end

"""
Parse for statement.
"""
@noinline function parse_for_statement(p::Parser)::ASTNode
    parser_advance!(p)  # Skip 'for'

    # Parse iterator variable
    var_tok = parser_consume!(p, TOK_IDENT)
    var_node = ast_ident(var_tok.start, var_tok.length)

    parser_consume!(p, TOK_KW_IN)  # Expect 'in'

    iterable = parse_expression(p)
    (body_stmts, num_body) = parse_block_body(p, Int32(64))

    parser_consume!(p, TOK_KW_END)  # Expect 'end'

    return ast_for(var_node, iterable, body_stmts, num_body)
end

"""
Parse function definition.
"""
@noinline function parse_function_definition(p::Parser)::ASTNode
    parser_advance!(p)  # Skip 'function'

    # Parse function name
    name_tok = parser_consume!(p, TOK_IDENT)

    # Parse parameters
    parser_consume!(p, TOK_LPAREN)

    params = Vector{ASTNode}(undef, 16)
    num_params = Int32(0)

    if parser_check(p, TOK_RPAREN) == Int32(0)
        # First parameter
        param_tok = parser_consume!(p, TOK_IDENT)
        params[1] = ast_ident(param_tok.start, param_tok.length)
        num_params = Int32(1)

        # More parameters
        while parser_check(p, TOK_COMMA) == Int32(1)
            parser_advance!(p)  # Skip comma
            param_tok = parser_consume!(p, TOK_IDENT)
            if num_params < Int32(16)
                num_params = num_params + Int32(1)
                params[num_params] = ast_ident(param_tok.start, param_tok.length)
            end
        end
    end

    parser_consume!(p, TOK_RPAREN)

    # Parse body
    (body_stmts, num_body) = parse_block_body(p, Int32(64))

    parser_consume!(p, TOK_KW_END)  # Expect 'end'

    return ast_func(name_tok.start, name_tok.length, params, body_stmts, num_params, num_body)
end

"""
Parse return statement.
"""
@noinline function parse_return_statement(p::Parser)::ASTNode
    parser_advance!(p)  # Skip 'return'

    # Check for expression
    t = parser_current_type(p)
    if t == TOK_NEWLINE || t == TOK_SEMICOLON || t == TOK_EOF || t == TOK_KW_END
        return ast_return(nothing)
    end

    expr = parse_expression(p)
    return ast_return(expr)
end

"""
Parse expression or assignment statement.
"""
@noinline function parse_expr_or_assign_statement(p::Parser)::ASTNode
    expr = parse_expression(p)

    # Check for assignment
    if parser_check(p, TOK_EQ) == Int32(1)
        if expr.kind == AST_IDENT
            parser_advance!(p)  # Skip '='
            value = parse_expression(p)
            return ast_assign(expr, value)
        else
            # Error: can only assign to identifier
            p.had_error = Int32(1)
            return ast_error()
        end
    end

    return expr
end

"""
Parse a single statement.
"""
@noinline function parse_statement(p::Parser)::ASTNode
    t = parser_current_type(p)

    if t == TOK_KW_IF
        return parse_if_statement(p)
    end

    if t == TOK_KW_WHILE
        return parse_while_statement(p)
    end

    if t == TOK_KW_FOR
        return parse_for_statement(p)
    end

    if t == TOK_KW_FUNCTION
        return parse_function_definition(p)
    end

    if t == TOK_KW_RETURN
        return parse_return_statement(p)
    end

    # Expression or assignment
    return parse_expr_or_assign_statement(p)
end

# ============================================================================
# Program Parsing
# ============================================================================

"""
Parse a complete program.
"""
@noinline function parse_program(p::Parser)::ASTNode
    stmts = Vector{ASTNode}(undef, 256)  # Max 256 statements
    num_stmts = Int32(0)

    parser_skip_terminators!(p)

    while parser_at_end(p) == Int32(0)
        if is_statement_start(p) == Int32(1)
            if num_stmts < Int32(256)
                num_stmts = num_stmts + Int32(1)
                stmts[num_stmts] = parse_statement(p)
            else
                parse_statement(p)  # Parse but don't store
            end
            parser_skip_terminators!(p)
        else
            # Unknown token - skip it
            parser_advance!(p)
        end
    end

    return ast_program(stmts, num_stmts)
end

# ============================================================================
# Debug/Utility Functions (Julia-only, not for WASM)
# ============================================================================

"""
Get human-readable name for an AST node kind.
"""
function ast_kind_name(kind::Int32)::String
    kind == AST_ERROR && return "ERROR"
    kind == AST_INT_LIT && return "INT"
    kind == AST_FLOAT_LIT && return "FLOAT"
    kind == AST_BOOL_LIT && return "BOOL"
    kind == AST_STRING_LIT && return "STRING"
    kind == AST_NOTHING_LIT && return "NOTHING"
    kind == AST_IDENT && return "IDENT"
    kind == AST_BINARY && return "BINARY"
    kind == AST_UNARY && return "UNARY"
    kind == AST_CALL && return "CALL"
    kind == AST_ASSIGN && return "ASSIGN"
    kind == AST_IF && return "IF"
    kind == AST_WHILE && return "WHILE"
    kind == AST_FOR && return "FOR"
    kind == AST_FUNC && return "FUNC"
    kind == AST_RETURN && return "RETURN"
    kind == AST_BLOCK && return "BLOCK"
    kind == AST_PROGRAM && return "PROGRAM"
    return "UNKNOWN"
end

"""
Get human-readable name for a binary operator.
"""
function op_name(op::Int32)::String
    op == OP_ADD && return "+"
    op == OP_SUB && return "-"
    op == OP_MUL && return "*"
    op == OP_DIV && return "/"
    op == OP_MOD && return "%"
    op == OP_POW && return "^"
    op == OP_EQ && return "=="
    op == OP_NE && return "!="
    op == OP_LT && return "<"
    op == OP_LE && return "<="
    op == OP_GT && return ">"
    op == OP_GE && return ">="
    op == OP_AND && return "&&"
    op == OP_OR && return "||"
    return "?"
end

"""
Print AST for debugging (Julia-side only).
"""
function print_ast(node::ASTNode, source::String, indent::Int=0)
    prefix = "  " ^ indent
    kind = ast_kind_name(node.kind)

    if node.kind == AST_INT_LIT
        println("$(prefix)$(kind): $(node.int_value)")
    elseif node.kind == AST_FLOAT_LIT
        println("$(prefix)$(kind): $(node.float_value)")
    elseif node.kind == AST_BOOL_LIT
        val = node.int_value == Int32(1) ? "true" : "false"
        println("$(prefix)$(kind): $(val)")
    elseif node.kind == AST_STRING_LIT || node.kind == AST_IDENT
        text = SubString(source, node.str_start, node.str_start + node.str_length - 1)
        println("$(prefix)$(kind): $(text)")
    elseif node.kind == AST_BINARY
        println("$(prefix)$(kind) $(op_name(node.op))")
        if node.left !== nothing
            print_ast(node.left, source, indent + 1)
        end
        if node.right !== nothing
            print_ast(node.right, source, indent + 1)
        end
    elseif node.kind == AST_UNARY
        op_str = node.op == OP_NEG ? "-" : "!"
        println("$(prefix)$(kind) $(op_str)")
        if node.left !== nothing
            print_ast(node.left, source, indent + 1)
        end
    elseif node.kind == AST_CALL
        println("$(prefix)$(kind)")
        println("$(prefix)  callee:")
        if node.left !== nothing
            print_ast(node.left, source, indent + 2)
        end
        println("$(prefix)  args:")
        for i in 1:node.num_children
            print_ast(node.children[i], source, indent + 2)
        end
    elseif node.kind == AST_ASSIGN
        println("$(prefix)$(kind)")
        if node.left !== nothing
            print_ast(node.left, source, indent + 1)
        end
        if node.right !== nothing
            print_ast(node.right, source, indent + 1)
        end
    elseif node.kind == AST_IF
        println("$(prefix)$(kind)")
        println("$(prefix)  condition:")
        if node.left !== nothing
            print_ast(node.left, source, indent + 2)
        end
        println("$(prefix)  then:")
        for i in 1:node.num_children
            print_ast(node.children[i], source, indent + 2)
        end
        if node.right !== nothing
            println("$(prefix)  else:")
            print_ast(node.right, source, indent + 2)
        end
    elseif node.kind == AST_WHILE
        println("$(prefix)$(kind)")
        println("$(prefix)  condition:")
        if node.left !== nothing
            print_ast(node.left, source, indent + 2)
        end
        println("$(prefix)  body:")
        for i in 1:node.num_children
            print_ast(node.children[i], source, indent + 2)
        end
    elseif node.kind == AST_FOR
        println("$(prefix)$(kind)")
        println("$(prefix)  var:")
        if node.left !== nothing
            print_ast(node.left, source, indent + 2)
        end
        println("$(prefix)  iterable:")
        if node.right !== nothing
            print_ast(node.right, source, indent + 2)
        end
        println("$(prefix)  body:")
        for i in 1:node.num_children
            print_ast(node.children[i], source, indent + 2)
        end
    elseif node.kind == AST_FUNC
        name = SubString(source, node.str_start, node.str_start + node.str_length - 1)
        num_params = node.int_value
        println("$(prefix)$(kind) $(name)")
        println("$(prefix)  params:")
        for i in 1:num_params
            print_ast(node.children[i], source, indent + 2)
        end
        println("$(prefix)  body:")
        for i in (num_params+1):node.num_children
            print_ast(node.children[i], source, indent + 2)
        end
    elseif node.kind == AST_RETURN
        println("$(prefix)$(kind)")
        if node.left !== nothing
            print_ast(node.left, source, indent + 1)
        end
    elseif node.kind == AST_BLOCK || node.kind == AST_PROGRAM
        println("$(prefix)$(kind)")
        for i in 1:node.num_children
            print_ast(node.children[i], source, indent + 1)
        end
    else
        println("$(prefix)$(kind)")
    end
end
