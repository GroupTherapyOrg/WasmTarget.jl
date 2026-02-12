# Stack Validator — catches type mismatches during codegen (like dart2wasm's InstructionsBuilder)
#
# dart2wasm tracks _stackTypes (List<ValueType>) and validates push/pop during
# bytecode emission. We mirror that approach: collect errors instead of throwing,
# so one validation run catches multiple issues.

export WasmStackValidator, validate_push!, validate_pop!, validate_pop_any!,
       stack_height, has_errors, reset_validator!, validate_instruction!

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

# ============================================================================
# Opcode Sets for Instruction Validation
# ============================================================================

# i32 unary ops: pop i32, push i32
const I32_UNARY_OPS = Set{UInt8}([
    Opcode.I32_EQZ, Opcode.I32_CLZ, Opcode.I32_CTZ, Opcode.I32_POPCNT,
])

# i64 unary ops: pop i64, push i64 (except i64.eqz which returns i32)
const I64_UNARY_OPS = Set{UInt8}([
    Opcode.I64_CLZ, Opcode.I64_CTZ, Opcode.I64_POPCNT,
])

# i32 binary arithmetic: pop 2 i32, push i32
const I32_BINARY_OPS = Set{UInt8}([
    Opcode.I32_ADD, Opcode.I32_SUB, Opcode.I32_MUL,
    Opcode.I32_DIV_S, Opcode.I32_DIV_U, Opcode.I32_REM_S, Opcode.I32_REM_U,
    Opcode.I32_AND, Opcode.I32_OR, Opcode.I32_XOR,
    Opcode.I32_SHL, Opcode.I32_SHR_S, Opcode.I32_SHR_U,
    Opcode.I32_ROTL, Opcode.I32_ROTR,
])

# i64 binary arithmetic: pop 2 i64, push i64
const I64_BINARY_OPS = Set{UInt8}([
    Opcode.I64_ADD, Opcode.I64_SUB, Opcode.I64_MUL,
    Opcode.I64_DIV_S, Opcode.I64_DIV_U, Opcode.I64_REM_S, Opcode.I64_REM_U,
    Opcode.I64_AND, Opcode.I64_OR, Opcode.I64_XOR,
    Opcode.I64_SHL, Opcode.I64_SHR_S, Opcode.I64_SHR_U,
    Opcode.I64_ROTL, Opcode.I64_ROTR,
])

# f32 binary arithmetic: pop 2 f32, push f32
const F32_BINARY_OPS = Set{UInt8}([
    Opcode.F32_ADD, Opcode.F32_SUB, Opcode.F32_MUL, Opcode.F32_DIV,
    Opcode.F32_MIN, Opcode.F32_MAX, Opcode.F32_COPYSIGN,
])

# f64 binary arithmetic: pop 2 f64, push f64
const F64_BINARY_OPS = Set{UInt8}([
    Opcode.F64_ADD, Opcode.F64_SUB, Opcode.F64_MUL, Opcode.F64_DIV,
    Opcode.F64_MIN, Opcode.F64_MAX, Opcode.F64_COPYSIGN,
])

# f32 unary ops: pop f32, push f32
const F32_UNARY_OPS = Set{UInt8}([
    Opcode.F32_ABS, Opcode.F32_NEG, Opcode.F32_CEIL, Opcode.F32_FLOOR,
    Opcode.F32_TRUNC, Opcode.F32_NEAREST, Opcode.F32_SQRT,
])

# f64 unary ops: pop f64, push f64
const F64_UNARY_OPS = Set{UInt8}([
    Opcode.F64_ABS, Opcode.F64_NEG, Opcode.F64_CEIL, Opcode.F64_FLOOR,
    Opcode.F64_TRUNC, Opcode.F64_NEAREST, Opcode.F64_SQRT,
])

# i32 comparisons: pop 2 i32, push i32
const I32_CMP_OPS = Set{UInt8}([
    Opcode.I32_EQ, Opcode.I32_NE,
    Opcode.I32_LT_S, Opcode.I32_LT_U, Opcode.I32_GT_S, Opcode.I32_GT_U,
    Opcode.I32_LE_S, Opcode.I32_LE_U, Opcode.I32_GE_S, Opcode.I32_GE_U,
])

# i64 comparisons: pop 2 i64, push i32
const I64_CMP_OPS = Set{UInt8}([
    Opcode.I64_EQ, Opcode.I64_NE,
    Opcode.I64_LT_S, Opcode.I64_LT_U, Opcode.I64_GT_S, Opcode.I64_GT_U,
    Opcode.I64_LE_S, Opcode.I64_LE_U, Opcode.I64_GE_S, Opcode.I64_GE_U,
])

# f32 comparisons: pop 2 f32, push i32
const F32_CMP_OPS = Set{UInt8}([
    Opcode.F32_EQ, Opcode.F32_NE,
    Opcode.F32_LT, Opcode.F32_GT, Opcode.F32_LE, Opcode.F32_GE,
])

# f64 comparisons: pop 2 f64, push i32
const F64_CMP_OPS = Set{UInt8}([
    Opcode.F64_EQ, Opcode.F64_NE,
    Opcode.F64_LT, Opcode.F64_GT, Opcode.F64_LE, Opcode.F64_GE,
])

# ============================================================================
# Instruction Validation — numeric, parametric, and conversion ops
# ============================================================================

"""
    validate_instruction!(v, opcode, type_info=nothing)

Validate a single instruction's stack effect. Pops expected operands and pushes
results according to the Wasm spec. Mirrors dart2wasm's InstructionsBuilder
assertion checks for numeric/parametric/conversion instructions.

For GC-prefixed instructions (0xFB), use validate_gc_instruction! (PURE-413).
"""
function validate_instruction!(v::WasmStackValidator, opcode::UInt8, type_info=nothing)
    v.enabled || return

    # --- Numeric unary: pop T, push T (same type) ---
    if opcode in I32_UNARY_OPS
        validate_pop!(v, I32); validate_push!(v, I32)
    elseif opcode in I64_UNARY_OPS
        validate_pop!(v, I64); validate_push!(v, I64)
    elseif opcode == Opcode.I64_EQZ
        # i64.eqz: pop i64, push i32 (comparison result)
        validate_pop!(v, I64); validate_push!(v, I32)
    elseif opcode in F32_UNARY_OPS
        validate_pop!(v, F32); validate_push!(v, F32)
    elseif opcode in F64_UNARY_OPS
        validate_pop!(v, F64); validate_push!(v, F64)

    # --- Numeric binary: pop 2 T, push T ---
    elseif opcode in I32_BINARY_OPS
        validate_pop!(v, I32); validate_pop!(v, I32); validate_push!(v, I32)
    elseif opcode in I64_BINARY_OPS
        validate_pop!(v, I64); validate_pop!(v, I64); validate_push!(v, I64)
    elseif opcode in F32_BINARY_OPS
        validate_pop!(v, F32); validate_pop!(v, F32); validate_push!(v, F32)
    elseif opcode in F64_BINARY_OPS
        validate_pop!(v, F64); validate_pop!(v, F64); validate_push!(v, F64)

    # --- Comparisons: pop 2 T, push i32 ---
    elseif opcode in I32_CMP_OPS
        validate_pop!(v, I32); validate_pop!(v, I32); validate_push!(v, I32)
    elseif opcode in I64_CMP_OPS
        validate_pop!(v, I64); validate_pop!(v, I64); validate_push!(v, I32)
    elseif opcode in F32_CMP_OPS
        validate_pop!(v, F32); validate_pop!(v, F32); validate_push!(v, I32)
    elseif opcode in F64_CMP_OPS
        validate_pop!(v, F64); validate_pop!(v, F64); validate_push!(v, I32)

    # --- Constants: push T ---
    elseif opcode == Opcode.I32_CONST
        validate_push!(v, I32)
    elseif opcode == Opcode.I64_CONST
        validate_push!(v, I64)
    elseif opcode == Opcode.F32_CONST
        validate_push!(v, F32)
    elseif opcode == Opcode.F64_CONST
        validate_push!(v, F64)

    # --- Parametric ---
    elseif opcode == Opcode.DROP
        validate_pop_any!(v)
    elseif opcode == Opcode.SELECT
        # select: pop i32 condition, pop T, pop T, push T
        validate_pop!(v, I32)  # condition
        val2 = validate_pop_any!(v)
        validate_pop_any!(v)
        # Push back the type of one of the values (both should be same type)
        if val2 !== nothing
            validate_push!(v, val2)
        end

    # --- Integer conversions ---
    elseif opcode == Opcode.I32_WRAP_I64
        validate_pop!(v, I64); validate_push!(v, I32)
    elseif opcode == Opcode.I64_EXTEND_I32_S || opcode == Opcode.I64_EXTEND_I32_U
        validate_pop!(v, I32); validate_push!(v, I64)

    # --- Float-to-int truncation ---
    elseif opcode == Opcode.I32_TRUNC_F32_S || opcode == Opcode.I32_TRUNC_F32_U
        validate_pop!(v, F32); validate_push!(v, I32)
    elseif opcode == Opcode.I32_TRUNC_F64_S || opcode == Opcode.I32_TRUNC_F64_U
        validate_pop!(v, F64); validate_push!(v, I32)
    elseif opcode == Opcode.I64_TRUNC_F32_S || opcode == Opcode.I64_TRUNC_F32_U
        validate_pop!(v, F32); validate_push!(v, I64)
    elseif opcode == Opcode.I64_TRUNC_F64_S || opcode == Opcode.I64_TRUNC_F64_U
        validate_pop!(v, F64); validate_push!(v, I64)

    # --- Int-to-float conversion ---
    elseif opcode == Opcode.F32_CONVERT_I32_S || opcode == Opcode.F32_CONVERT_I32_U
        validate_pop!(v, I32); validate_push!(v, F32)
    elseif opcode == Opcode.F32_CONVERT_I64_S || opcode == Opcode.F32_CONVERT_I64_U
        validate_pop!(v, I64); validate_push!(v, F32)
    elseif opcode == Opcode.F64_CONVERT_I32_S || opcode == Opcode.F64_CONVERT_I32_U
        validate_pop!(v, I32); validate_push!(v, F64)
    elseif opcode == Opcode.F64_CONVERT_I64_S || opcode == Opcode.F64_CONVERT_I64_U
        validate_pop!(v, I64); validate_push!(v, F64)

    # --- Reinterpret (same-size bitcast) ---
    elseif opcode == Opcode.I32_REINTERPRET_F32
        validate_pop!(v, F32); validate_push!(v, I32)
    elseif opcode == Opcode.I64_REINTERPRET_F64
        validate_pop!(v, F64); validate_push!(v, I64)
    elseif opcode == Opcode.F32_REINTERPRET_I32
        validate_pop!(v, I32); validate_push!(v, F32)
    elseif opcode == Opcode.F64_REINTERPRET_I64
        validate_pop!(v, I64); validate_push!(v, F64)

    # --- Reference instructions (non-GC-prefix) ---
    elseif opcode == Opcode.REF_IS_NULL
        validate_pop_any!(v); validate_push!(v, I32)
    elseif opcode == Opcode.REF_EQ
        validate_pop_any!(v); validate_pop_any!(v); validate_push!(v, I32)

    # --- Memory instructions ---
    elseif opcode == Opcode.I32_LOAD
        validate_pop!(v, I32); validate_push!(v, I32)
    elseif opcode == Opcode.I64_LOAD
        validate_pop!(v, I32); validate_push!(v, I64)
    elseif opcode == Opcode.F32_LOAD
        validate_pop!(v, I32); validate_push!(v, F32)
    elseif opcode == Opcode.F64_LOAD
        validate_pop!(v, I32); validate_push!(v, F64)
    elseif opcode == Opcode.I32_STORE
        validate_pop!(v, I32); validate_pop!(v, I32)  # value, addr
    elseif opcode == Opcode.I64_STORE
        validate_pop!(v, I64); validate_pop!(v, I32)
    elseif opcode == Opcode.F32_STORE
        validate_pop!(v, F32); validate_pop!(v, I32)
    elseif opcode == Opcode.F64_STORE
        validate_pop!(v, F64); validate_pop!(v, I32)
    elseif opcode == Opcode.MEMORY_SIZE
        validate_push!(v, I32)
    elseif opcode == Opcode.MEMORY_GROW
        validate_pop!(v, I32); validate_push!(v, I32)

    # Unknown opcode — skip silently (GC prefix instructions handled by validate_gc_instruction!)
    end
end
