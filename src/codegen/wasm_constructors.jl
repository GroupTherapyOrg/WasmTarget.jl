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
