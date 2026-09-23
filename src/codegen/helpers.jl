# ============================================================================
# Helper Functions
# ============================================================================

"""True when a resolved callee IS the named Core/Base builtin binding.

parity(pkg/kernel/lib/src/ast/expressions.dart:2820 StaticInvocation): a call node carries its
resolved target, compared by identity."""
function is_builtin_func(func, name::Symbol)::Bool
    core_target = isdefined(Core, name) ? getglobal(Core, name) : nothing
    base_target = isdefined(Base, name) ? getglobal(Base, name) : nothing
    return func === core_target || func === base_target
end

"""
Check if a resolved callee is a comparison operation: a comparison intrinsic, `===`, or `!==`.
"""
function is_comparison(func)::Bool
    (func === (===) || func === (!==)) && return true
    return func isa Core.IntrinsicFunction &&
           nameof(func) in (:slt_int, :sle_int, :ult_int, :ule_int, :eq_int, :ne_int,
                            :lt_float, :le_float, :eq_float, :ne_float)
end

"""
Check if a value is known to be boolean (0 or 1).
This is true for comparison results, Bool literals, and phi nodes with Bool type.
"""
function is_boolean_value(val::NirNode, ctx::AbstractCompilationContext)::Bool
    if val isa NirSSA
        # Check if the SSA value is from a comparison
        # Guard against out-of-bounds SSAValue IDs
        (val.id < 1 || val.id > length(ctx.nir)) && return false
        rec = ctx.nir[val.id]
        if rec.slot == 0 && rec.node isa NirCall && is_comparison(rec.node.callee)
            return true
        end
        # Check if SSA has Bool inferred type (e.g., phi node results, getfield of Bool fields)
        if infer_value_type(val, ctx) === Bool
            return true
        end
    elseif val isa NirLiteral && val.value isa Bool
        return true
    elseif val isa NirArgument
        # Function parameters typed as Bool
        if infer_value_type(val, ctx) === Bool
            return true
        end
    end
    return false
end
# Julia IR nodes whose value is supplied at runtime rather than embedded as a
# literal/global constant. Keep this classification centralized so optimized
# (SSA/Pi/Argument) and unoptimized (SlotNumber) IR share call lowering.
# parity(quarantine: NirSSA/NirArgument/NirSlot reference Julia IR values by SSA id, argument
# or slot; Kernel operands are expression nodes, not references to other statements.)
is_runtime_ir_value(x)::Bool = x isa NirSSA || x isa NirArgument || x isa NirSlot
