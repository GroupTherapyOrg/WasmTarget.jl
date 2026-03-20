# ============================================================================
# WASM Constructor Exports — GAMMA-002
# ============================================================================
# Julia functions that create WasmGC struct instances for CodeInfo IR types.
# Compiled into the codegen E2E module so JS can call them to build IR.
#
# IR types in WASM:
#   SSAValue, Argument, GotoNode → WasmGC structs (single i64 field)
#   GotoIfNot, ReturnNode, PhiNode, Expr, CodeInfo → WasmGC structs (multi-field)
#
# JS flow: parse JSON → call these constructors → build code Vector{Any} →
#          pass to compile_module_from_ir_frozen_no_dict

# --- Simple IR node constructors ---

"""Create a Core.SSAValue (references an SSA value by index)."""
function wasm_create_ssa_value(id::Int32)::Core.SSAValue
    return Core.SSAValue(Int(id))
end

"""Create a Core.Argument (references a function argument by position)."""
function wasm_create_argument(n::Int32)::Core.Argument
    return Core.Argument(Int(n))
end

"""Create a Core.GotoNode (unconditional jump to label)."""
function wasm_create_goto_node(label::Int32)::Core.GotoNode
    return Core.GotoNode(Int(label))
end

"""Create a Core.GotoIfNot with SSAValue condition."""
function wasm_create_goto_if_not(cond_ssa_id::Int32, dest::Int32)::Core.GotoIfNot
    return Core.GotoIfNot(Core.SSAValue(Int(cond_ssa_id)), Int(dest))
end

"""Create a Core.ReturnNode with SSAValue return value."""
function wasm_create_return_node(val_ssa_id::Int32)::Core.ReturnNode
    return Core.ReturnNode(Core.SSAValue(Int(val_ssa_id)))
end

"""Create a Core.ReturnNode with no return value (unreachable/void)."""
function wasm_create_return_node_nothing()::Core.ReturnNode
    return Core.ReturnNode()
end

"""Create a Core.PhiNode from edge list and value list."""
function wasm_create_phi_node(edges::Vector{Int32}, values::Vector{Any})::Core.PhiNode
    return Core.PhiNode(edges, values)
end

"""Create an Expr with given head symbol and args vector."""
function wasm_create_expr(head::Symbol, args::Vector{Any})::Expr
    e = Expr(head)
    e.args = args
    return e
end

# --- CodeInfo constructor ---
# Core.CodeInfo has no public constructor. We modify a template in-place.
# The template is baked at build time and passed from JS as a WASM global.

"""
Set the essential fields on a CodeInfo template for compilation.
Modifies the template in-place and returns it.
"""
function wasm_set_code_info!(template::Core.CodeInfo,
                             code::Vector{Any},
                             ssavaluetypes::Vector{Any},
                             nargs::Int32)::Core.CodeInfo
    template.code = code
    template.ssavaluetypes = ssavaluetypes
    template.nargs = UInt64(nargs)
    return template
end

# --- Vector{Any} builders ---
# WasmGC arrays are opaque to JS. These let JS build Vector{Any} element-by-element.

"""Create a Vector{Any} of size n, initialized to nothing."""
function wasm_create_any_vector(n::Int32)::Vector{Any}
    return Vector{Any}(nothing, n)
end

"""Set element i (1-based) of Vector{Any} to an SSAValue."""
function wasm_set_any_ssa!(v::Vector{Any}, i::Int32, ssa_id::Int32)::Nothing
    v[i] = Core.SSAValue(Int(ssa_id))
    return nothing
end

"""Set element i (1-based) of Vector{Any} to an Argument."""
function wasm_set_any_arg!(v::Vector{Any}, i::Int32, arg_n::Int32)::Nothing
    v[i] = Core.Argument(Int(arg_n))
    return nothing
end

"""Set element i (1-based) of Vector{Any} to an Int64 literal."""
function wasm_set_any_i64!(v::Vector{Any}, i::Int32, val::Int64)::Nothing
    v[i] = val
    return nothing
end

"""Set element i (1-based) of Vector{Any} to an Expr."""
function wasm_set_any_expr!(v::Vector{Any}, i::Int32, expr::Expr)::Nothing
    v[i] = expr
    return nothing
end

"""Set element i (1-based) of Vector{Any} to a ReturnNode."""
function wasm_set_any_return!(v::Vector{Any}, i::Int32, ret::Core.ReturnNode)::Nothing
    v[i] = ret
    return nothing
end

"""Set element i (1-based) of Vector{Any} to a GotoIfNot."""
function wasm_set_any_gotoifnot!(v::Vector{Any}, i::Int32, g::Core.GotoIfNot)::Nothing
    v[i] = g
    return nothing
end

"""Set element i (1-based) of Vector{Any} to a GotoNode."""
function wasm_set_any_goto!(v::Vector{Any}, i::Int32, g::Core.GotoNode)::Nothing
    v[i] = g
    return nothing
end

"""Set element i (1-based) of Vector{Any} to a PhiNode."""
function wasm_set_any_phi!(v::Vector{Any}, i::Int32, phi::Core.PhiNode)::Nothing
    v[i] = phi
    return nothing
end

# --- Verification accessors (for Node.js testing) ---

"""Get the id field of an SSAValue as Int32."""
function wasm_get_ssa_id(v::Core.SSAValue)::Int32
    return Int32(v.id)
end

"""Get the dest field of a GotoIfNot as Int32."""
function wasm_get_gotoifnot_dest(g::Core.GotoIfNot)::Int32
    return Int32(g.dest)
end

"""Get the length of a Vector{Any} as Int32."""
function wasm_any_vector_length(v::Vector{Any})::Int32
    return Int32(length(v))
end

"""Get the length of a Vector{Int32} as Int32."""
function wasm_i32_vector_length(v::Vector{Int32})::Int32
    return Int32(length(v))
end

# --- Vector{Int32} builders (for PhiNode edges) ---

"""Create a Vector{Int32} of size n, initialized to zero."""
function wasm_create_i32_vector(n::Int32)::Vector{Int32}
    return zeros(Int32, n)
end

"""Set element i (1-based) of Vector{Int32}."""
function wasm_set_i32!(v::Vector{Int32}, i::Int32, val::Int32)::Nothing
    v[i] = val
    return nothing
end

# --- Type constructors for ssavaluetypes ---
# ssavaluetypes entries are Julia Type objects. For MVP, we only need a few.

"""Create a Vector{Any} containing n copies of Int64 type (for ssavaluetypes)."""
function wasm_create_ssatypes_all_i64(n::Int32)::Vector{Any}
    v = Vector{Any}(undef, n)
    for i in 1:n
        v[i] = Int64
    end
    return v
end

# --- Symbol constructors for common IR heads ---
# Symbol can't be constructed from JS strings directly. These return
# pre-built Symbol values for common Expr heads used in Julia IR.

"""Return the Symbol :call (used for function call Exprs)."""
function wasm_symbol_call()::Symbol
    return :call
end

"""Return the Symbol :invoke (used for typed invoke Exprs)."""
function wasm_symbol_invoke()::Symbol
    return :invoke
end

"""Return the Symbol :new (used for struct construction Exprs)."""
function wasm_symbol_new()::Symbol
    return :new
end

"""Return the Symbol :boundscheck."""
function wasm_symbol_boundscheck()::Symbol
    return :boundscheck
end

"""Return the Symbol :foreigncall."""
function wasm_symbol_foreigncall()::Symbol
    return :foreigncall
end

# ============================================================================
# Mini-compiler — GAMMA-003
# ============================================================================
# Self-contained compiler for simple i64 arithmetic functions.
# Does NOT depend on WasmModule, TypeRegistry, CompilationContext, or Dict.
# Produces a complete WASM binary from IR components.
#
# Intrinsic functions are represented as Int64 IDs in the Expr args[1] position
# (JS deserializer maps globalref/intrinsic names to these IDs).
#
# Intrinsic ID mapping:
#   1=mul_int, 2=add_int, 3=sub_int, 4=neg_int,
#   5=slt_int, 6=sle_int, 7=eq_int, 8=ne_int,
#   9=and_int, 10=or_int, 11=xor_int,
#   12=sdiv_int, 13=srem_int, 14=sgt_int, 15=sge_int

"""
Compile a simple i64→i64 function from IR components to WASM bytes.

code: Vector{Any} of IR statements
  - Expr(:call, [Int64(intrinsic_id), args...]) for intrinsic calls
  - ReturnNode(SSAValue(n)) for returns
ssavaluetypes: Vector{Any} of types (reserved for future use)
nargs: number of Julia args including #self#

Returns: Vector{UInt8} containing a valid WASM binary.
"""
function wasm_compile_i64_to_i64(code::Vector{Any}, ssavaluetypes::Vector{Any},
                                  nargs::Int32)::Vector{UInt8}
    n_params = Int(nargs) - 1  # Subtract #self#
    n_stmts = length(code)

    # Count SSA values that need locals (all non-return, non-goto statements)
    n_ssa = Int32(0)
    for i in 1:n_stmts
        stmt = code[i]
        if stmt isa Expr
            n_ssa += Int32(1)
        end
    end

    # Generate function body bytecode
    body = UInt8[]
    for i in 1:n_stmts
        stmt = code[i]
        if stmt isa Expr && stmt.head === :call
            # args[1] = intrinsic ID (Int64), args[2:] = values
            for j in 2:length(stmt.args)
                _mini_emit_value!(body, stmt.args[j], Int32(n_params))
            end
            intrinsic_id = stmt.args[1]
            if intrinsic_id isa Int64
                _mini_emit_intrinsic!(body, Int32(intrinsic_id))
            end
            # Store result in SSA local
            local_idx = UInt32(n_params + i - 1)
            push!(body, 0x21)  # local.set
            append!(body, encode_leb128_unsigned(local_idx))
        elseif stmt isa Core.ReturnNode
            if isdefined(stmt, :val)
                _mini_emit_value!(body, stmt.val, Int32(n_params))
            end
            # Value is on stack; function end returns it
        end
    end

    return _mini_build_wasm(body, Int32(n_params), n_ssa)
end

"""Emit WASM opcodes for an IR value onto the stack."""
function _mini_emit_value!(bytes::Vector{UInt8}, val, n_params::Int32)::Nothing
    if val isa Core.Argument
        # Argument(2) = first real param = local 0
        local_idx = UInt32(val.n - 2)
        push!(bytes, 0x20)  # local.get
        append!(bytes, encode_leb128_unsigned(local_idx))
    elseif val isa Core.SSAValue
        # SSAValue(k) = local (n_params + k - 1)
        local_idx = UInt32(Int(n_params) + val.id - 1)
        push!(bytes, 0x20)  # local.get
        append!(bytes, encode_leb128_unsigned(local_idx))
    elseif val isa Int64
        push!(bytes, 0x42)  # i64.const
        append!(bytes, encode_leb128_signed(val))
    end
    return nothing
end

"""Emit WASM opcode for an i64 intrinsic by ID."""
function _mini_emit_intrinsic!(bytes::Vector{UInt8}, id::Int32)::Nothing
    if id == Int32(1)       # mul_int
        push!(bytes, 0x7e)
    elseif id == Int32(2)   # add_int
        push!(bytes, 0x7c)
    elseif id == Int32(3)   # sub_int
        push!(bytes, 0x7d)
    elseif id == Int32(5)   # slt_int
        push!(bytes, 0x53)
    elseif id == Int32(6)   # sle_int
        push!(bytes, 0x57)
    elseif id == Int32(7)   # eq_int
        push!(bytes, 0x51)
    elseif id == Int32(8)   # ne_int
        push!(bytes, 0x52)
    elseif id == Int32(9)   # and_int
        push!(bytes, 0x83)
    elseif id == Int32(10)  # or_int
        push!(bytes, 0x84)
    elseif id == Int32(11)  # xor_int
        push!(bytes, 0x85)
    elseif id == Int32(12)  # sdiv_int
        push!(bytes, 0x7f)
    elseif id == Int32(13)  # srem_int
        push!(bytes, 0x81)
    elseif id == Int32(14)  # sgt_int
        push!(bytes, 0x55)
    elseif id == Int32(15)  # sge_int
        push!(bytes, 0x59)
    end
    return nothing
end

"""Build a minimal WASM binary for an i64 function."""
function _mini_build_wasm(body::Vector{UInt8}, n_params::Int32, n_locals::Int32)::Vector{UInt8}
    result = UInt8[]

    # WASM magic + version
    append!(result, UInt8[0x00, 0x61, 0x73, 0x6d])
    append!(result, UInt8[0x01, 0x00, 0x00, 0x00])

    # === Type section (id=1): func type (n_params × i64) → (i64) ===
    type_content = UInt8[]
    push!(type_content, 0x01)  # 1 type
    push!(type_content, 0x60)  # func type
    append!(type_content, encode_leb128_unsigned(UInt32(n_params)))
    for _ in 1:n_params
        push!(type_content, 0x7e)  # i64
    end
    push!(type_content, 0x01)  # 1 result
    push!(type_content, 0x7e)  # i64
    _mini_emit_section!(result, UInt8(0x01), type_content)

    # === Function section (id=3): 1 function, type 0 ===
    _mini_emit_section!(result, UInt8(0x03), UInt8[0x01, 0x00])

    # === Export section (id=7): "f" → function 0 ===
    export_content = UInt8[]
    push!(export_content, 0x01)       # 1 export
    push!(export_content, 0x01)       # name length = 1
    push!(export_content, UInt8('f')) # name = "f"
    push!(export_content, 0x00)       # export kind = function
    push!(export_content, 0x00)       # function index = 0
    _mini_emit_section!(result, UInt8(0x07), export_content)

    # === Code section (id=10): 1 function body ===
    func_body = UInt8[]
    if n_locals > Int32(0)
        push!(func_body, 0x01)  # 1 local type entry
        append!(func_body, encode_leb128_unsigned(UInt32(n_locals)))
        push!(func_body, 0x7e)  # i64
    else
        push!(func_body, 0x00)  # no locals
    end
    append!(func_body, body)
    push!(func_body, 0x0b)  # end

    # Body with length prefix
    body_with_len = UInt8[]
    append!(body_with_len, encode_leb128_unsigned(UInt32(length(func_body))))
    append!(body_with_len, func_body)

    code_content = UInt8[]
    push!(code_content, 0x01)  # 1 function body
    append!(code_content, body_with_len)
    _mini_emit_section!(result, UInt8(0x0a), code_content)

    return result
end

"""Emit a WASM section with id and content."""
function _mini_emit_section!(result::Vector{UInt8}, id::UInt8, content::Vector{UInt8})::Nothing
    push!(result, id)
    append!(result, encode_leb128_unsigned(UInt32(length(content))))
    append!(result, content)
    return nothing
end

# ============================================================================
# Flat mini-compiler — ARCHB G-005
# ============================================================================
# WASM-compilation-friendly mini-compiler that uses ONLY Int32/UInt8 arrays.
# No Vector{Any}, no type dispatch, no Expr/Symbol handling.
# Uses @noinline helpers to prevent IR explosion from inlining.
#
# Instruction encoding in flat Int32 vector:
#   Call:   [0, wasm_opcode, n_operands, kind1, val1, kind2, val2, ...]
#   Return: [1, kind, val]
#   Operand kinds: 0=param(local_idx), 1=ssa(ssa_idx_0based), 2=i64_const(value)

# --- @noinline helpers to prevent IR explosion ---
@noinline function _fb!(v::Vector{UInt8}, b::UInt8)::Vector{UInt8}
    push!(v, b)
    return v
end
@noinline function _fa!(v::Vector{UInt8}, b::Vector{UInt8})::Vector{UInt8}
    return append!(v, b)
end
@noinline function _flu(n::UInt32)::Vector{UInt8}
    return encode_leb128_unsigned(n)
end
@noinline function _fls(n::Int64)::Vector{UInt8}
    return encode_leb128_signed(n)
end
@noinline function _flen(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

"""Emit a local.get instruction into the byte vector."""
@noinline function _emit_local_get!(v::Vector{UInt8}, idx::UInt32)::Nothing
    _fb!(v, 0x20)
    _fa!(v, _flu(idx))
    return nothing
end

"""Emit a local.set instruction into the byte vector."""
@noinline function _emit_local_set!(v::Vector{UInt8}, idx::UInt32)::Nothing
    _fb!(v, 0x21)
    _fa!(v, _flu(idx))
    return nothing
end

"""Emit an i64.const instruction into the byte vector."""
@noinline function _emit_i64_const!(v::Vector{UInt8}, val::Int64)::Nothing
    _fb!(v, 0x42)
    _fa!(v, _fls(val))
    return nothing
end

"""Emit a WASM section (id + leb128(len) + content) into result."""
@noinline function _emit_section!(result::Vector{UInt8}, id::UInt8, content::Vector{UInt8})::Nothing
    _fb!(result, id)
    _fa!(result, _flu(UInt32(_flen(content))))
    _fa!(result, content)
    return nothing
end

"""
Compile a simple i64→i64 function from a flat Int32 instruction buffer.
Returns a complete, valid WASM binary as Vector{UInt8}.
"""
function wasm_compile_flat(instrs::Vector{Int32}, n_params::Int32)::Vector{UInt8}
    # --- First pass: count SSA locals ---
    n_ssa = Int32(0)
    pos = Int32(1)
    n_instrs = Int32(length(instrs))
    while pos <= n_instrs
        stype = instrs[pos]
        if stype == Int32(0)  # call
            n_operands = instrs[pos + Int32(2)]
            n_ssa += Int32(1)
            pos += Int32(3) + n_operands * Int32(2)
        else  # return
            pos += Int32(3)
        end
    end

    # --- Second pass: emit function body bytecode ---
    body = UInt8[]
    pos = Int32(1)
    ssa_idx = Int32(0)
    while pos <= n_instrs
        stype = instrs[pos]
        if stype == Int32(0)  # call intrinsic
            opcode = instrs[pos + Int32(1)]
            n_operands = instrs[pos + Int32(2)]
            pos += Int32(3)
            for _ in Int32(1):n_operands
                kind = instrs[pos]
                val = instrs[pos + Int32(1)]
                pos += Int32(2)
                if kind == Int32(0)  # param → local.get
                    _emit_local_get!(body, UInt32(val))
                elseif kind == Int32(1)  # ssa → local.get(n_params + ssa_idx)
                    _emit_local_get!(body, UInt32(n_params + val))
                else  # i64 const
                    _emit_i64_const!(body, Int64(val))
                end
            end
            _fb!(body, UInt8(opcode & Int32(0xFF)))
            _emit_local_set!(body, UInt32(n_params + ssa_idx))
            ssa_idx += Int32(1)
        else  # return
            kind = instrs[pos + Int32(1)]
            val = instrs[pos + Int32(2)]
            pos += Int32(3)
            if kind == Int32(0)  # param
                _emit_local_get!(body, UInt32(val))
            elseif kind == Int32(1)  # ssa
                _emit_local_get!(body, UInt32(n_params + val))
            end
        end
    end

    # --- Build complete WASM module ---
    result = UInt8[]

    # Magic + version
    _fb!(result, 0x00); _fb!(result, 0x61); _fb!(result, 0x73); _fb!(result, 0x6d)
    _fb!(result, 0x01); _fb!(result, 0x00); _fb!(result, 0x00); _fb!(result, 0x00)

    # Type section (id=1): func (i64^n_params → i64)
    tp = UInt8[]
    _fb!(tp, 0x01); _fb!(tp, 0x60)  # 1 type, func
    _fa!(tp, _flu(UInt32(n_params)))
    for _ in Int32(1):n_params; _fb!(tp, 0x7e); end  # i64 params
    _fb!(tp, 0x01); _fb!(tp, 0x7e)  # 1 result, i64
    _emit_section!(result, 0x01, tp)

    # Function section (id=3): 1 func → type 0
    _fb!(result, 0x03); _fb!(result, 0x02); _fb!(result, 0x01); _fb!(result, 0x00)

    # Export section (id=7): "f" → func 0
    ep = UInt8[]
    _fb!(ep, 0x01); _fb!(ep, 0x01); _fb!(ep, UInt8('f'))  # 1 export, name "f"
    _fb!(ep, 0x00); _fb!(ep, 0x00)  # func kind, idx 0
    _emit_section!(result, 0x07, ep)

    # Code section (id=10): 1 function body
    fb = UInt8[]
    if n_ssa > Int32(0)
        _fb!(fb, 0x01)  # 1 local entry
        _fa!(fb, _flu(UInt32(n_ssa)))
        _fb!(fb, 0x7e)  # i64
    else
        _fb!(fb, 0x00)  # no locals
    end
    _fa!(fb, body)
    _fb!(fb, 0x0b)  # end

    cp = UInt8[]
    _fb!(cp, 0x01)  # 1 func body
    _fa!(cp, _flu(UInt32(_flen(fb))))
    _fa!(cp, fb)
    _emit_section!(result, 0x0a, cp)

    return result
end

# ============================================================================
# WasmGC String constructors — F-004
# ============================================================================
# Enable JS to build WasmGC Strings (i32 arrays) for passing to WASM functions.
#
# In WasmTarget.jl, String compiles to a WasmGC i32 array. These constructors
# use Vector{Int32} as the creation type (same WASM representation) so that
# array operations compile cleanly. Architecture B (F-007) will bridge the
# Vector{Int32} ↔ String gap when wiring compile_source.
#
# JS flow: create_wasm_string(len) → set chars → pass to WASM functions

"""Create a WasmGC string-compatible i32 array of given length, initialized to zeros."""
function create_wasm_string(len::Int32)::Vector{Int32}
    return zeros(Int32, len)
end

"""Set character at position i (1-based) to the given Unicode codepoint."""
function set_string_char!(s::Vector{Int32}, i::Int32, codepoint::Int32)::Nothing
    s[i] = codepoint
    return nothing
end

"""Get character codepoint at position i (1-based)."""
function get_string_char(s::Vector{Int32}, i::Int32)::Int32
    return s[i]
end

"""Get the length of a WasmGC string as Int32."""
function wasm_string_length(s::Vector{Int32})::Int32
    return Int32(length(s))
end

# ============================================================================
# WASM-native Mini-Parser — F-002 + F-003 + F-006
# ============================================================================
# Parses MVP Julia expressions and compiles to WASM in one pass.
# Input: source string as Vector{Int32} (Unicode codepoints)
# Output: complete WASM binary as Vector{UInt8}
#
# Supported syntax:
#   f(x::Int64) = x*x+1
#   g(x::Int64, y::Int64) = x+y*2
#   h(x::Int64) = (x+1)*(x-1)
#
# All parameters and return type are Int64.
# NO Dict, NO String, NO complex types — fully WASM-compilable.

# --- Token kinds ---
const _TK_IDENT  = Int32(1)
const _TK_INT    = Int32(2)
const _TK_PLUS   = Int32(3)
const _TK_MINUS  = Int32(4)
const _TK_STAR   = Int32(5)
const _TK_SLASH  = Int32(6)
const _TK_LPAREN = Int32(7)
const _TK_RPAREN = Int32(8)
const _TK_EQ     = Int32(9)
const _TK_DCOLON = Int32(10)
const _TK_COMMA  = Int32(11)
const _TK_EOF    = Int32(12)

# --- Value kinds (for expression results, matches wasm_compile_flat format) ---
const _VK_PARAM = Int32(0)
const _VK_SSA   = Int32(1)
const _VK_CONST = Int32(2)

# --- Operator opcodes (i64 WASM opcodes) ---
const _OP_ADD = Int32(0x7c)  # i64.add
const _OP_SUB = Int32(0x7d)  # i64.sub
const _OP_MUL = Int32(0x7e)  # i64.mul
const _OP_DIV = Int32(0x7f)  # i64.div_s

# ── Tokenizer ─────────────────────────────────────────────────────────────────

@noinline function _is_alpha(c::Int32)::Bool
    return (c >= Int32('a') && c <= Int32('z')) ||
           (c >= Int32('A') && c <= Int32('Z')) ||
           c == Int32('_')
end

@noinline function _is_digit(c::Int32)::Bool
    return c >= Int32('0') && c <= Int32('9')
end

@noinline function _is_alnum(c::Int32)::Bool
    return _is_alpha(c) || _is_digit(c)
end

@noinline function _is_space(c::Int32)::Bool
    return c == Int32(' ') || c == Int32('\t') || c == Int32('\n') || c == Int32('\r')
end

"""
Tokenize source into flat token array.
Each token = 4 Int32: [kind, start_pos, end_pos, int_value]
Returns (tokens::Vector{Int32}, n_tokens::Int32).
"""
@noinline function _mp_tokenize!(tokens::Vector{Int32}, src::Vector{Int32}, slen::Int32)::Int32
    pos = Int32(1)
    n_tok = Int32(0)

    while pos <= slen
        c = src[pos]

        # Skip whitespace
        if _is_space(c)
            pos += Int32(1)
            continue
        end

        # Identifier or keyword
        if _is_alpha(c)
            start = pos
            while pos <= slen && _is_alnum(src[pos])
                pos += Int32(1)
            end
            n_tok += Int32(1)
            idx = (n_tok - Int32(1)) * Int32(4)
            tokens[idx + Int32(1)] = _TK_IDENT
            tokens[idx + Int32(2)] = start
            tokens[idx + Int32(3)] = pos   # exclusive end
            tokens[idx + Int32(4)] = Int32(0)
            continue
        end

        # Integer literal
        if _is_digit(c)
            start = pos
            val = Int32(0)
            while pos <= slen && _is_digit(src[pos])
                val = val * Int32(10) + (src[pos] - Int32('0'))
                pos += Int32(1)
            end
            n_tok += Int32(1)
            idx = (n_tok - Int32(1)) * Int32(4)
            tokens[idx + Int32(1)] = _TK_INT
            tokens[idx + Int32(2)] = start
            tokens[idx + Int32(3)] = pos
            tokens[idx + Int32(4)] = val
            continue
        end

        # :: (two-char token)
        if c == Int32(':') && pos + Int32(1) <= slen && src[pos + Int32(1)] == Int32(':')
            n_tok += Int32(1)
            idx = (n_tok - Int32(1)) * Int32(4)
            tokens[idx + Int32(1)] = _TK_DCOLON
            tokens[idx + Int32(2)] = pos
            tokens[idx + Int32(3)] = pos + Int32(2)
            tokens[idx + Int32(4)] = Int32(0)
            pos += Int32(2)
            continue
        end

        # Single-char tokens
        kind = Int32(0)
        if c == Int32('+');     kind = _TK_PLUS
        elseif c == Int32('-'); kind = _TK_MINUS
        elseif c == Int32('*'); kind = _TK_STAR
        elseif c == Int32('/'); kind = _TK_SLASH
        elseif c == Int32('('); kind = _TK_LPAREN
        elseif c == Int32(')'); kind = _TK_RPAREN
        elseif c == Int32('='); kind = _TK_EQ
        elseif c == Int32(','); kind = _TK_COMMA
        end

        if kind != Int32(0)
            n_tok += Int32(1)
            idx = (n_tok - Int32(1)) * Int32(4)
            tokens[idx + Int32(1)] = kind
            tokens[idx + Int32(2)] = pos
            tokens[idx + Int32(3)] = pos + Int32(1)
            tokens[idx + Int32(4)] = Int32(0)
            pos += Int32(1)
            continue
        end

        # Unknown character — skip
        pos += Int32(1)
    end

    # EOF token
    n_tok += Int32(1)
    idx = (n_tok - Int32(1)) * Int32(4)
    tokens[idx + Int32(1)] = _TK_EOF
    tokens[idx + Int32(2)] = pos
    tokens[idx + Int32(3)] = pos
    tokens[idx + Int32(4)] = Int32(0)

    return n_tok
end

# ── Token access helpers ──────────────────────────────────────────────────────

@noinline function _tok_kind(tokens::Vector{Int32}, i::Int32)::Int32
    return tokens[(i - Int32(1)) * Int32(4) + Int32(1)]
end

@noinline function _tok_start(tokens::Vector{Int32}, i::Int32)::Int32
    return tokens[(i - Int32(1)) * Int32(4) + Int32(2)]
end

@noinline function _tok_end(tokens::Vector{Int32}, i::Int32)::Int32
    return tokens[(i - Int32(1)) * Int32(4) + Int32(3)]
end

@noinline function _tok_intval(tokens::Vector{Int32}, i::Int32)::Int32
    return tokens[(i - Int32(1)) * Int32(4) + Int32(4)]
end

"""Check if two identifier tokens in the source refer to the same name."""
@noinline function _ident_eq(src::Vector{Int32}, s1::Int32, e1::Int32,
                              s2::Int32, e2::Int32)::Bool
    len1 = e1 - s1
    len2 = e2 - s2
    if len1 != len2
        return false
    end
    for i in Int32(0):(len1 - Int32(1))
        if src[s1 + i] != src[s2 + i]
            return false
        end
    end
    return true
end

"""Find parameter index (0-based) for an identifier. Returns -1 if not found."""
@noinline function _find_param(src::Vector{Int32},
                                param_starts::Vector{Int32}, param_ends::Vector{Int32},
                                n_params::Int32,
                                ident_start::Int32, ident_end::Int32)::Int32
    for i in Int32(1):n_params
        if _ident_eq(src, param_starts[i], param_ends[i], ident_start, ident_end)
            return i - Int32(1)  # 0-based
        end
    end
    return Int32(-1)
end

# ── Expression parser (recursive descent with precedence) ─────────────────────
# Returns: (value_kind::Int32, value_val::Int32, new_tok_pos::Int32)
# Modifies instrs/n_instrs in-place.

"""Parse an atom: integer literal, identifier, or parenthesized expression."""
@noinline function _parse_atom(src::Vector{Int32}, tokens::Vector{Int32}, tpos::Int32,
                                instrs::Vector{Int32}, n_instrs_ref::Vector{Int32},
                                param_starts::Vector{Int32}, param_ends::Vector{Int32},
                                n_params::Int32, ssa_counter::Vector{Int32})::Tuple{Int32, Int32, Int32}
    kind = _tok_kind(tokens, tpos)

    if kind == _TK_INT
        val = _tok_intval(tokens, tpos)
        return (_VK_CONST, val, tpos + Int32(1))
    end

    if kind == _TK_IDENT
        s = _tok_start(tokens, tpos)
        e = _tok_end(tokens, tpos)
        pidx = _find_param(src, param_starts, param_ends, n_params, s, e)
        if pidx >= Int32(0)
            return (_VK_PARAM, pidx, tpos + Int32(1))
        end
        # Unknown identifier — treat as 0
        return (_VK_CONST, Int32(0), tpos + Int32(1))
    end

    if kind == _TK_LPAREN
        # Parenthesized expression
        vk, vv, next = _parse_additive(src, tokens, tpos + Int32(1), instrs,
                                         n_instrs_ref, param_starts, param_ends,
                                         n_params, ssa_counter)
        # Skip closing paren
        if _tok_kind(tokens, next) == _TK_RPAREN
            next += Int32(1)
        end
        return (vk, vv, next)
    end

    # Fallback
    return (_VK_CONST, Int32(0), tpos + Int32(1))
end

"""Emit a binary operation instruction, return the SSA index."""
@noinline function _emit_binop!(instrs::Vector{Int32}, n_instrs_ref::Vector{Int32},
                                 ssa_counter::Vector{Int32},
                                 opcode::Int32,
                                 lk::Int32, lv::Int32, rk::Int32, rv::Int32)::Int32
    ni = n_instrs_ref[Int32(1)]
    instrs[ni + Int32(1)] = Int32(0)    # stmt_type = call
    instrs[ni + Int32(2)] = opcode
    instrs[ni + Int32(3)] = Int32(2)    # n_operands
    instrs[ni + Int32(4)] = lk          # left kind
    instrs[ni + Int32(5)] = lv          # left value
    instrs[ni + Int32(6)] = rk          # right kind
    instrs[ni + Int32(7)] = rv          # right value
    n_instrs_ref[Int32(1)] = ni + Int32(7)
    ssa_idx = ssa_counter[Int32(1)]
    ssa_counter[Int32(1)] = ssa_idx + Int32(1)
    return ssa_idx
end

"""Parse multiplicative expression: atom (* or /) atom ..."""
@noinline function _parse_multiplicative(src::Vector{Int32}, tokens::Vector{Int32}, tpos::Int32,
                                          instrs::Vector{Int32}, n_instrs_ref::Vector{Int32},
                                          param_starts::Vector{Int32}, param_ends::Vector{Int32},
                                          n_params::Int32, ssa_counter::Vector{Int32})::Tuple{Int32, Int32, Int32}
    lk, lv, next = _parse_atom(src, tokens, tpos, instrs, n_instrs_ref,
                                param_starts, param_ends, n_params, ssa_counter)

    while true
        op = _tok_kind(tokens, next)
        if op == _TK_STAR
            opcode = _OP_MUL
        elseif op == _TK_SLASH
            opcode = _OP_DIV
        else
            break
        end
        rk, rv, next = _parse_atom(src, tokens, next + Int32(1), instrs, n_instrs_ref,
                                    param_starts, param_ends, n_params, ssa_counter)
        ssa_idx = _emit_binop!(instrs, n_instrs_ref, ssa_counter, opcode, lk, lv, rk, rv)
        lk = _VK_SSA
        lv = ssa_idx
    end

    return (lk, lv, next)
end

"""Parse additive expression: multiplicative (+ or -) multiplicative ..."""
@noinline function _parse_additive(src::Vector{Int32}, tokens::Vector{Int32}, tpos::Int32,
                                    instrs::Vector{Int32}, n_instrs_ref::Vector{Int32},
                                    param_starts::Vector{Int32}, param_ends::Vector{Int32},
                                    n_params::Int32, ssa_counter::Vector{Int32})::Tuple{Int32, Int32, Int32}
    lk, lv, next = _parse_multiplicative(src, tokens, tpos, instrs, n_instrs_ref,
                                          param_starts, param_ends, n_params, ssa_counter)

    while true
        op = _tok_kind(tokens, next)
        if op == _TK_PLUS
            opcode = _OP_ADD
        elseif op == _TK_MINUS
            opcode = _OP_SUB
        else
            break
        end
        rk, rv, next = _parse_multiplicative(src, tokens, next + Int32(1), instrs, n_instrs_ref,
                                              param_starts, param_ends, n_params, ssa_counter)
        ssa_idx = _emit_binop!(instrs, n_instrs_ref, ssa_counter, opcode, lk, lv, rk, rv)
        lk = _VK_SSA
        lv = ssa_idx
    end

    return (lk, lv, next)
end

# ── Main entry point ──────────────────────────────────────────────────────────

"""
Compile a Julia source string to WASM bytes. Zero server, all in WASM.

Input: source as Vector{Int32} (codepoints), slen
Output: complete WASM binary as Vector{UInt8}

Parses MVP Julia expressions (function definitions with arithmetic),
produces flat instruction buffer, calls wasm_compile_flat.
"""
function wasm_compile_source(src::Vector{Int32}, slen::Int32)::Vector{UInt8}
    # --- Tokenize ---
    max_tokens = slen + Int32(1)  # worst case: each char is a token
    tokens = zeros(Int32, max_tokens * Int32(4))
    n_tokens = _mp_tokenize!(tokens, src, slen)

    # --- Parse function signature: name(param1::Type1, ...) = body ---
    tpos = Int32(1)  # current token position

    # Skip function name
    if _tok_kind(tokens, tpos) == _TK_IDENT
        tpos += Int32(1)
    end

    # Parse parameter list
    param_starts = zeros(Int32, Int32(8))  # max 8 params
    param_ends = zeros(Int32, Int32(8))
    n_params = Int32(0)

    if _tok_kind(tokens, tpos) == _TK_LPAREN
        tpos += Int32(1)  # skip (

        while _tok_kind(tokens, tpos) != _TK_RPAREN && _tok_kind(tokens, tpos) != _TK_EOF
            # Expect identifier (parameter name)
            if _tok_kind(tokens, tpos) == _TK_IDENT
                n_params += Int32(1)
                param_starts[n_params] = _tok_start(tokens, tpos)
                param_ends[n_params] = _tok_end(tokens, tpos)
                tpos += Int32(1)

                # Skip optional ::Type
                if _tok_kind(tokens, tpos) == _TK_DCOLON
                    tpos += Int32(1)  # skip ::
                    if _tok_kind(tokens, tpos) == _TK_IDENT
                        tpos += Int32(1)  # skip type name
                    end
                end
            end

            # Skip comma
            if _tok_kind(tokens, tpos) == _TK_COMMA
                tpos += Int32(1)
            end
        end

        if _tok_kind(tokens, tpos) == _TK_RPAREN
            tpos += Int32(1)  # skip )
        end
    end

    # Skip '='
    if _tok_kind(tokens, tpos) == _TK_EQ
        tpos += Int32(1)
    end

    # --- Parse body expression ---
    max_instrs = slen * Int32(8)  # generous buffer
    instrs = zeros(Int32, max_instrs)
    n_instrs_ref = Int32[Int32(0)]  # mutable counter (write position in instrs)
    ssa_counter = Int32[Int32(0)]   # mutable SSA index counter

    vk, vv, next = _parse_additive(src, tokens, tpos, instrs, n_instrs_ref,
                                    param_starts, param_ends, n_params, ssa_counter)

    # Emit return statement
    ni = n_instrs_ref[Int32(1)]
    instrs[ni + Int32(1)] = Int32(1)  # stmt_type = return
    instrs[ni + Int32(2)] = vk
    instrs[ni + Int32(3)] = vv
    n_instrs_ref[Int32(1)] = ni + Int32(3)

    # --- Trim instruction buffer to actual size ---
    actual_len = n_instrs_ref[Int32(1)]
    trimmed = zeros(Int32, actual_len)
    for i in Int32(1):actual_len
        trimmed[i] = instrs[i]
    end

    # --- Compile to WASM via wasm_compile_flat ---
    return wasm_compile_flat(trimmed, n_params)
end
