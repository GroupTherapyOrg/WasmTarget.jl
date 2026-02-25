# ============================================================================
# Helper Functions
# ============================================================================

"""
Check if func matches a given intrinsic name.
"""
function is_func(func, name::Symbol)::Bool
    if func isa GlobalRef
        return func.name === name
    elseif func isa Core.IntrinsicFunction
        # Compare intrinsic by string representation
        return Symbol(func) === name
    elseif typeof(func) <: Core.Builtin
        # Builtin functions like isa, typeof, etc.
        return nameof(func) === name
    elseif func isa Function
        # Generic functions
        return nameof(func) === name
    elseif func isa Core.MethodInstance
        # Specific method instance
        return func.def.name === name
    end
    return false
end

"""
Check if a function is a comparison operation.
"""
function is_comparison(func)::Bool
    if func isa GlobalRef
        name = func.name
        return name in (:slt_int, :sle_int, :ult_int, :ule_int, :eq_int, :ne_int,
                        :lt_float, :le_float, :eq_float, :ne_float,
                        :(===), :(!==))
    end
    return false
end

"""
Check if a value is known to be boolean (0 or 1).
This is true for comparison results, Bool literals, and phi nodes with Bool type.
"""
function is_boolean_value(val, ctx::CompilationContext)::Bool
    if val isa Core.SSAValue
        # Check if the SSA value is from a comparison
        # PURE-6021: Guard against out-of-bounds SSAValue IDs
        (val.id < 1 || val.id > length(ctx.code_info.code)) && return false
        stmt = ctx.code_info.code[val.id]
        if stmt isa Expr && stmt.head === :call && is_comparison(stmt.args[1])
            return true
        end
        # Check if SSA has Bool inferred type (e.g., phi node results, getfield of Bool fields)
        if infer_value_type(val, ctx) === Bool
            return true
        end
    elseif val isa Bool
        return true
    elseif val isa Core.Argument
        # Function parameters typed as Bool
        if infer_value_type(val, ctx) === Bool
            return true
        end
    end
    return false
end

