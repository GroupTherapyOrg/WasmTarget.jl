# Stack Validator — catches type mismatches during codegen (like dart2wasm's InstructionsBuilder)
#
# dart2wasm tracks _stackTypes (List<ValueType>) and validates push/pop during
# bytecode emission. We mirror that approach: collect errors instead of throwing,
# so one validation run catches multiple issues.

export WasmStackValidator, validate_push!, validate_pop!, validate_pop_any!,
       stack_height, has_errors, reset_validator!

"""
    WasmStackValidator

Tracks the Wasm value stack during bytecode emission and catches type mismatches
immediately, rather than requiring post-hoc `wasm-tools validate` + WAT analysis.

Modeled on dart2wasm's InstructionsBuilder._stackTypes / _checkStackTypes pattern.
"""
mutable struct WasmStackValidator
    stack::Vector{WasmValType}          # Current value stack (types)
    errors::Vector{String}              # Collected errors (don't throw, collect)
    enabled::Bool                       # Can disable for debugging
    func_name::String                   # For error messages
end

WasmStackValidator(; enabled=true, func_name="") =
    WasmStackValidator(WasmValType[], String[], enabled, func_name)

"""
    validate_push!(v, typ)

Push a type onto the validation stack. Mirrors dart2wasm's _stackTypes.addAll(outputs).
"""
function validate_push!(v::WasmStackValidator, typ::WasmValType)
    v.enabled || return
    push!(v.stack, typ)
end

"""
    validate_pop!(v, expected) -> WasmValType

Pop a value from the validation stack, checking that the actual type is assignable
to `expected`. Returns the actual type found (or `expected` on underflow).

Mirrors dart2wasm's _checkStackTypes + _stackTypes.length -= inputs.length.
"""
function validate_pop!(v::WasmStackValidator, expected::WasmValType)::WasmValType
    v.enabled || return expected
    if isempty(v.stack)
        push!(v.errors, "$(v.func_name): stack underflow — expected $(expected), stack empty")
        return expected
    end
    actual = pop!(v.stack)
    if !wasm_types_assignable(actual, expected)
        push!(v.errors, "$(v.func_name): type mismatch — expected $(expected), found $(actual)")
    end
    return actual
end

"""
    validate_pop_any!(v) -> Union{WasmValType, Nothing}

Pop any type from the validation stack without type checking.
Returns `nothing` on underflow.
"""
function validate_pop_any!(v::WasmStackValidator)::Union{WasmValType, Nothing}
    v.enabled || return nothing
    if isempty(v.stack)
        push!(v.errors, "$(v.func_name): stack underflow on pop_any")
        return nothing
    end
    return pop!(v.stack)
end

"""
    stack_height(v) -> Int

Current number of values on the validation stack.
"""
stack_height(v::WasmStackValidator) = length(v.stack)

"""
    has_errors(v) -> Bool

Whether any validation errors have been collected.
"""
has_errors(v::WasmStackValidator) = !isempty(v.errors)

"""
    reset_validator!(v)

Clear the stack and errors for reuse (e.g., between functions).
"""
function reset_validator!(v::WasmStackValidator)
    empty!(v.stack)
    empty!(v.errors)
end

# ============================================================================
# Type Assignability
# ============================================================================

"""
    wasm_types_assignable(actual, expected) -> Bool

Check if `actual` type is usable where `expected` type is needed.
Mirrors Wasm's type hierarchy for validation purposes.

Rules:
- Exact match always works
- Any ref type is assignable to any other ref type (permissive for now)
  This will be tightened in PURE-413 when we add WasmGC-specific validation.
- Numeric types must match exactly (i32 ≠ i64 ≠ f32 ≠ f64)
"""
function wasm_types_assignable(actual::WasmValType, expected::WasmValType)::Bool
    actual == expected && return true
    # Permissive ref-to-ref: externref → anyref, ConcreteRef → ExternRef, etc.
    # dart2wasm uses isSubtypeOf() for full hierarchy; we start permissive
    # and tighten in PURE-413 (WasmGC operations).
    _is_ref_type(actual) && _is_ref_type(expected) && return true
    return false
end

# Internal helpers — underscore-prefixed to avoid polluting the namespace
_is_ref_type(::NumType) = false
_is_ref_type(::RefType) = true
_is_ref_type(::ConcreteRef) = true
_is_ref_type(::UInt8) = false  # Packed types (i8=0x78, i16=0x77) are not ref types
