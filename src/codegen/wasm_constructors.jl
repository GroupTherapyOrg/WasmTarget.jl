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
