# TypeInference.jl - Pure-Julia type inference for IRStmt arrays
#
# This module provides abstract interpretation over lowered IR (IRStmt arrays
# from Lowering.jl) to determine the type of each SSA value. WasmTarget uses
# these types to emit correct native Wasm instructions (i64.add vs f64.add).
#
# Design:
# - Types are represented as Int32 tags (T_INT64, T_FLOAT64, T_BOOL, etc.)
# - Forward pass walks statements in order, inferring types from operations
# - Slot types track variable assignments (widened at merge points)
# - infer_types() is the main entry point, compiles to WasmGC
#
# This is equivalent to Core.Compiler.typeinf's abstract interpretation:
# - Determines return types for operations (Int64 + Int64 = Int64)
# - Propagates types through assignments and loads
# - Widens at control flow merge points
# - Does NOT include optimization passes (Binaryen handles that)

export T_UNKNOWN, T_INT64, T_FLOAT64, T_BOOL, T_ANY
export InferredTypes, infer_types, infer_expr

# Type tags
const T_UNKNOWN  = Int32(0)   # Not yet inferred
const T_INT64    = Int32(1)   # Int64
const T_FLOAT64  = Int32(2)   # Float64
const T_BOOL     = Int32(3)   # Bool (result of comparisons)
const T_ANY      = Int32(4)   # Union/widened type (multiple possible types)

"""
Result of type inference: types for each SSA statement and each variable slot.

Fields:
- stmt_types: Type tag for each SSA statement (indexed 1:N)
- slot_types: Type tag for each variable slot (indexed 1:num_slots)
- return_type: Inferred return type of the function/expression
"""
mutable struct InferredTypes
    stmt_types::Vector{Int32}
    slot_types::Vector{Int32}
    return_type::Int32
end

"""
    widen_types(a::Int32, b::Int32) -> Int32

Type widening: when two types meet at a merge point, compute the joined type.
- Same type → that type
- Different concrete types → T_ANY
- T_UNKNOWN + anything → the other type
"""
function widen_types(a::Int32, b::Int32)::Int32
    a == b && return a
    a == T_UNKNOWN && return b
    b == T_UNKNOWN && return a
    return T_ANY
end

"""
    infer_binop(op::Int32, left::Int32, right::Int32) -> Int32

Infer the result type of a binary operation given operand types.
- Int64 op Int64 → Int64 (except div → Float64)
- Float64 op anything → Float64
- Comparisons always → Bool
"""
function infer_binop(op::Int32, left::Int32, right::Int32)::Int32
    # Comparisons always return Bool
    if op == IR_LT || op == IR_GT || op == IR_EQ
        return T_BOOL
    end

    # Division always returns Float64
    if op == IR_DIV
        return T_FLOAT64
    end

    # Float64 dominates
    if left == T_FLOAT64 || right == T_FLOAT64
        return T_FLOAT64
    end

    # Int64 + Int64 = Int64
    if left == T_INT64 && right == T_INT64
        return T_INT64
    end

    # If either is unknown, result is unknown
    if left == T_UNKNOWN || right == T_UNKNOWN
        return T_UNKNOWN
    end

    # Mixed types → Any
    return T_ANY
end

"""
    infer_types(stmts::Vector{IRStmt}, num_slots::Int32) -> InferredTypes

Run abstract interpretation over the IR statement array to determine
the type of each SSA value and each variable slot.

This is the WasmGC-compilable type inference entry point, equivalent to
Core.Compiler.typeinf's abstract interpretation pass.
"""
function infer_types(stmts::Vector{IRStmt}, num_slots::Int32)::InferredTypes
    n = Int32(length(stmts))
    stmt_types = Vector{Int32}(undef, Int(n))
    slot_types = Vector{Int32}(undef, Int(num_slots))
    return_type = T_UNKNOWN

    # Initialize all types to unknown
    i = Int32(1)
    while i <= n
        stmt_types[i] = T_UNKNOWN
        i += Int32(1)
    end
    j = Int32(1)
    while j <= num_slots
        slot_types[j] = T_UNKNOWN
        j += Int32(1)
    end

    # Forward pass: infer types for each statement
    idx = Int32(1)
    while idx <= n
        stmt = stmts[idx]
        op = stmt.opcode

        if op == IR_CONST
            # Constants are Int64 (our IR uses Int64 values)
            stmt_types[idx] = T_INT64

        elseif op == IR_ADD || op == IR_SUB || op == IR_MUL || op == IR_DIV ||
               op == IR_LT || op == IR_GT || op == IR_EQ
            # Binary operations: infer from operand types
            left_type = T_UNKNOWN
            right_type = T_UNKNOWN
            if stmt.arg1 > Int32(0) && stmt.arg1 <= n
                left_type = stmt_types[stmt.arg1]
            end
            if stmt.arg2 > Int32(0) && stmt.arg2 <= n
                right_type = stmt_types[stmt.arg2]
            end
            stmt_types[idx] = infer_binop(op, left_type, right_type)

        elseif op == IR_STORE
            # Store to slot: propagate the RHS type to the slot
            rhs_type = T_UNKNOWN
            if stmt.arg1 > Int32(0) && stmt.arg1 <= n
                rhs_type = stmt_types[stmt.arg1]
            end
            slot_idx = Int32(stmt.value)
            if slot_idx > Int32(0) && slot_idx <= num_slots
                # Widen: if slot already has a different type, widen
                slot_types[slot_idx] = widen_types(slot_types[slot_idx], rhs_type)
            end
            stmt_types[idx] = rhs_type

        elseif op == IR_LOAD
            # Load from slot: type is whatever the slot holds
            slot_idx = Int32(stmt.value)
            if slot_idx > Int32(0) && slot_idx <= num_slots
                stmt_types[idx] = slot_types[slot_idx]
            else
                stmt_types[idx] = T_UNKNOWN
            end

        elseif op == IR_GOTO
            # Control flow: no value type
            stmt_types[idx] = T_UNKNOWN

        elseif op == IR_GOTOIFNOT
            # Control flow: no value type (condition is in arg1)
            stmt_types[idx] = T_UNKNOWN

        elseif op == IR_RETURN
            # Return: the return type is the type of the returned value
            if stmt.arg1 > Int32(0) && stmt.arg1 <= n
                return_type = widen_types(return_type, stmt_types[stmt.arg1])
            end
            stmt_types[idx] = T_UNKNOWN

        else
            stmt_types[idx] = T_UNKNOWN
        end

        idx += Int32(1)
    end

    return InferredTypes(stmt_types, slot_types, return_type)
end

"""
    infer_expr(expr) -> InferredTypes

Infer types for a Julia Expr by lowering it to IR and running abstract interpretation.
This is the user-facing API (host-side).
"""
function infer_expr(expr)
    stmts, _result_ssa, num_slots = lower_expr(expr)
    return infer_types(stmts, num_slots)
end
