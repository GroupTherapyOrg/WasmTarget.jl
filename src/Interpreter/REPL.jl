# Julia Interpreter REPL Integration - Written in WasmTarget-compatible Julia
# This module provides the main entry point for the interpreter.
#
# Design:
# - Single function interpret(code::String) -> String
# - Wires up: Tokenize -> Parse -> Eval pipeline
# - All errors returned as strings (no exceptions)
# - Designed to compile with WasmTarget.jl to WasmGC
#
# Usage in WASM:
#   1. WasmTarget.jl compiles this interpreter to interpreter.wasm
#   2. Browser loads interpreter.wasm
#   3. User types Julia code in editor
#   4. Browser calls interpret(code) via WASM
#   5. Result string displayed to user

export interpret, interpret_with_ast

# ============================================================================
# Error Message Construction
# ============================================================================

"""
Build an error message string for parse errors.
"""
@noinline function make_parse_error(source::String, parser_had_error::Int32, parser_pos::Int32)::String
    if parser_had_error == Int32(1)
        # Try to provide location info
        return "Parse error at position " * int_to_string(parser_pos)
    end
    return ""
end

"""
Build an error message for an empty input.
"""
@noinline function make_empty_error()::String
    return ""  # Empty input returns empty output (not an error)
end

# ============================================================================
# Main Interpret Function
# ============================================================================

"""
    interpret(code::String)::String

Interpret Julia code and return the result as a string.

This is the main entry point for the interpreter. It:
1. Tokenizes the input code
2. Parses tokens into an AST
3. Evaluates the AST
4. Returns the output (or error message) as a string

All processing happens within this function - no exceptions are thrown.
Errors are returned as descriptive strings.

# Example
```julia
result = interpret("x = 5; y = 3; println(x + y)")
# Returns: "8\\n"

result = interpret("function fib(n) if n <= 1 return n end return fib(n-1) + fib(n-2) end println(fib(10))")
# Returns: "55\\n"
```

# WASM Compilation
This function is designed to compile to WasmGC using WasmTarget.jl:
```julia
using WasmTarget
wasm_bytes = compile(interpret, (String,))
```

The resulting interpreter.wasm can be loaded in a browser to provide
a fully client-side Julia REPL.
"""
@noinline function interpret(code::String)::String
    # Handle empty input
    code_len = str_len(code)
    if code_len == Int32(0)
        return ""
    end

    # Parse the code
    # Max tokens: estimate based on code length (roughly 1 token per 2 chars + buffer)
    max_tokens = code_len + Int32(100)
    if max_tokens > Int32(10000)
        max_tokens = Int32(10000)  # Cap at 10000 tokens
    end

    parser = parser_new(code, max_tokens)

    # Parse into AST
    program = parse_program(parser)

    # Check for parse errors
    if parser.had_error == Int32(1)
        return "Error: Parse error at position " * int_to_string(parser.pos)
    end

    # Check for AST errors
    if program.kind == AST_ERROR
        return "Error: Failed to parse program"
    end

    # Evaluate the program
    output = eval_program(program, code)

    return output
end

# ============================================================================
# Debug/Testing Entry Point
# ============================================================================

"""
    interpret_with_ast(code::String)::Tuple{String, ASTNode}

Interpret Julia code and return both the result and the AST.
This is useful for debugging and testing the parser.

Note: This function is for Julia-side testing only, not for WASM compilation.
"""
function interpret_with_ast(code::String)::Tuple{String, ASTNode}
    code_len = str_len(code)
    if code_len == Int32(0)
        return ("", ast_error())
    end

    max_tokens = code_len + Int32(100)
    if max_tokens > Int32(10000)
        max_tokens = Int32(10000)
    end

    parser = parser_new(code, max_tokens)
    program = parse_program(parser)

    if parser.had_error == Int32(1)
        return ("Error: Parse error at position " * int_to_string(parser.pos), program)
    end

    if program.kind == AST_ERROR
        return ("Error: Failed to parse program", program)
    end

    output = eval_program(program, code)

    return (output, program)
end

# ============================================================================
# WASM Export Helper
# ============================================================================

"""
Get the interpret function signature for WASM compilation.

The interpreter is compiled to WASM with:
- Input: String (pointer to WasmGC string array)
- Output: String (pointer to WasmGC string array)

```julia
using WasmTarget
wasm_bytes = compile(interpret, (String,))
# Save to file
write("interpreter.wasm", wasm_bytes)
```
"""
function interpreter_signature()
    return (interpret, (String,))
end
