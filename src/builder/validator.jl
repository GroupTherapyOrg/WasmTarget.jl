# Stack Validator — catches type mismatches during codegen (like dart2wasm's InstructionsBuilder)
#
# dart2wasm tracks _stackTypes (List<ValueType>) and validates push/pop during
# bytecode emission. We mirror that approach: collect errors instead of throwing,
# so one validation run catches multiple issues.

export WasmStackValidator, validate_push!, validate_pop!, validate_pop_any!,
       stack_height, has_errors, reset_validator!, validate_instruction!,
       ValidatorLabel, validate_block_start!, validate_block_end!,
       validate_br!, validate_br_if!, validate_if_start!, validate_else!,
       validate_gc_instruction!

"""
    ValidatorLabel

Label stack entry for control flow validation, mirroring dart2wasm's Label class.
Tracks block kind, stack height at entry, result types, and reachability.

Key insight from dart2wasm:
- Loop.targetTypes = inputs (br restarts loop with its input types)
- Block/If.targetTypes = outputs (br exits with block's result types)
"""
struct ValidatorLabel
    kind::Symbol                        # :block, :loop, :if
    stack_height_at_entry::Int          # Stack height when block was entered
    result_types::Vector{WasmValType}   # Block's result types (outputs)
    reachable_at_entry::Bool            # Was block entry reachable?
    has_else::Bool                      # For :if labels — has else branch been seen?
end

ValidatorLabel(kind::Symbol, stack_height::Int, result_types::Vector{WasmValType}, reachable::Bool) =
    ValidatorLabel(kind, stack_height, result_types, reachable, false)

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
    labels::Vector{ValidatorLabel}      # Label stack for control flow (PURE-412)
    reachable::Bool                     # Whether current code is reachable (PURE-412)
end

WasmStackValidator(; enabled=true, func_name="") =
    WasmStackValidator(WasmValType[], String[], enabled, func_name, ValidatorLabel[], true)

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
    empty!(v.labels)
    v.reachable = true
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
    elseif opcode == Opcode.REF_NULL
        # ref.null $t: push null ref of given type (type_info = the ref type)
        if type_info !== nothing
            validate_push!(v, type_info)
        end
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

# ============================================================================
# Control Flow Validation (PURE-412)
# Mirrors dart2wasm's _labelStack / Label hierarchy
# ============================================================================

"""
    validate_block_start!(v, kind, result_types)

Push a label onto the label stack for a block/loop. Records the current stack
height so we can validate that the block produces exactly `result_types` when
it ends. Mirrors dart2wasm's `_pushLabel(Block(...))` / `_pushLabel(Loop(...))`.

For loops, `br` targets the loop start (no values consumed/produced by br).
For blocks, `br` targets the block end (must have result_types on stack).
"""
function validate_block_start!(v::WasmStackValidator, kind::Symbol, result_types::Vector{WasmValType}=WasmValType[])
    v.enabled || return
    label = ValidatorLabel(kind, length(v.stack), result_types, v.reachable)
    push!(v.labels, label)
end

"""
    validate_block_end!(v)

End the current block: pop the top label, verify the stack contains exactly
the block's result types above the entry height, then reset the stack to
entry_height + result_types. Mirrors dart2wasm's `end()` + `_verifyEndOfBlock`.

Reachability is restored from the label's `reachable_at_entry` — if the block
entry was reachable, code after the block is reachable (even if the block body
ended with an unconditional br).
"""
function validate_block_end!(v::WasmStackValidator)
    v.enabled || return
    if isempty(v.labels)
        push!(v.errors, "$(v.func_name): end without matching block/loop/if")
        return
    end
    label = pop!(v.labels)

    # Validate stack height and types if code is reachable
    if v.reachable
        expected_height = label.stack_height_at_entry + length(label.result_types)
        actual_height = length(v.stack)
        if actual_height != expected_height
            push!(v.errors, "$(v.func_name): block end stack height mismatch — expected $(expected_height), got $(actual_height)")
        end
        # Check result types match
        for (i, expected) in enumerate(label.result_types)
            idx = label.stack_height_at_entry + i
            if idx <= length(v.stack)
                actual = v.stack[idx]
                if !wasm_types_assignable(actual, expected)
                    push!(v.errors, "$(v.func_name): block result type mismatch at position $i — expected $(expected), found $(actual)")
                end
            end
        end
    end

    # Reset stack to entry height + result types (dart2wasm: _stackTypes.length = baseStackHeight; addAll(outputs))
    resize!(v.stack, label.stack_height_at_entry)
    append!(v.stack, label.result_types)

    # Restore reachability: code after block is reachable if block entry was reachable
    v.reachable = label.reachable_at_entry
end

"""
    validate_br!(v, label_depth)

Validate an unconditional branch. Checks that:
1. The target label exists at the given depth
2. The stack has the correct types for the target (result_types for block/if, empty for loop)

After br, code is unreachable. Mirrors dart2wasm's `br(label)`.
"""
function validate_br!(v::WasmStackValidator, label_depth::Int)
    v.enabled || return
    if !v.reachable
        return  # Skip validation in unreachable code
    end
    if label_depth < 0 || label_depth >= length(v.labels)
        push!(v.errors, "$(v.func_name): br label depth $(label_depth) out of range ($(length(v.labels)) labels)")
        v.reachable = false
        return
    end
    # Label at depth 0 = top of stack, depth N = N from top
    label = v.labels[end - label_depth]

    # For loops, br targets the loop start (no values needed — loop consumes nothing on restart)
    # For blocks/if, br targets the end (need result_types on stack)
    target_types = label.kind === :loop ? WasmValType[] : label.result_types

    # Check stack has enough values above the label's base
    needed = length(target_types)
    available = length(v.stack) - label.stack_height_at_entry
    if available < needed
        push!(v.errors, "$(v.func_name): br to $(label.kind) needs $(needed) values, only $(available) available above block base")
    else
        # Check types of top-of-stack values
        for (i, expected) in enumerate(target_types)
            actual = v.stack[end - needed + i]
            if !wasm_types_assignable(actual, expected)
                push!(v.errors, "$(v.func_name): br type mismatch at position $i — expected $(expected), found $(actual)")
            end
        end
    end

    v.reachable = false
end

"""
    validate_br_if!(v, label_depth)

Validate a conditional branch: pop i32 condition, then verify the target
label like br. Unlike br, code after br_if remains reachable.
Mirrors dart2wasm's `br_if(label)`.
"""
function validate_br_if!(v::WasmStackValidator, label_depth::Int)
    v.enabled || return
    if !v.reachable
        return
    end
    # Pop i32 condition
    validate_pop!(v, I32)

    # Validate target label (same as br, but don't mark unreachable)
    if label_depth < 0 || label_depth >= length(v.labels)
        push!(v.errors, "$(v.func_name): br_if label depth $(label_depth) out of range ($(length(v.labels)) labels)")
        return
    end
    label = v.labels[end - label_depth]
    target_types = label.kind === :loop ? WasmValType[] : label.result_types

    needed = length(target_types)
    available = length(v.stack) - label.stack_height_at_entry
    if available < needed
        push!(v.errors, "$(v.func_name): br_if to $(label.kind) needs $(needed) values, only $(available) available above block base")
    else
        for (i, expected) in enumerate(target_types)
            actual = v.stack[end - needed + i]
            if !wasm_types_assignable(actual, expected)
                push!(v.errors, "$(v.func_name): br_if type mismatch at position $i — expected $(expected), found $(actual)")
            end
        end
    end
    # Reachability stays true — conditional branch
end

"""
    validate_if_start!(v, result_types)

Validate an if instruction: pop i32 condition, push label for the then-branch.
Mirrors dart2wasm's `if_()` which calls `_verifyTypes([i32], [])` then `_pushLabel(If(...))`.
"""
function validate_if_start!(v::WasmStackValidator, result_types::Vector{WasmValType}=WasmValType[])
    v.enabled || return
    validate_pop!(v, I32)  # condition
    label = ValidatorLabel(:if, length(v.stack), result_types, v.reachable, false)
    push!(v.labels, label)
end

"""
    validate_else!(v)

Validate an else instruction: verify the then-branch stack, reset stack to
block entry height for the else-branch, restore reachability.
Mirrors dart2wasm's `else_()`.
"""
function validate_else!(v::WasmStackValidator)
    v.enabled || return
    if isempty(v.labels)
        push!(v.errors, "$(v.func_name): else without matching if")
        return
    end
    label = v.labels[end]
    if label.kind !== :if
        push!(v.errors, "$(v.func_name): else in non-if block ($(label.kind))")
        return
    end
    if label.has_else
        push!(v.errors, "$(v.func_name): duplicate else in if block")
        return
    end

    # Validate then-branch stack: should have result_types above entry height
    if v.reachable
        expected_height = label.stack_height_at_entry + length(label.result_types)
        if length(v.stack) != expected_height
            push!(v.errors, "$(v.func_name): if then-branch stack height mismatch — expected $(expected_height), got $(length(v.stack))")
        end
    end

    # Replace label with has_else=true
    v.labels[end] = ValidatorLabel(label.kind, label.stack_height_at_entry,
                                   label.result_types, label.reachable_at_entry, true)

    # Reset stack to entry height for else-branch (dart2wasm: _stackTypes.length = baseStackHeight)
    resize!(v.stack, label.stack_height_at_entry)

    # Restore reachability from block entry
    v.reachable = label.reachable_at_entry
end

# ============================================================================
# WasmGC Instruction Validation (PURE-413)
# Mirrors dart2wasm's InstructionsBuilder GC instruction assertions.
# These are the operations where PURE-317 through PURE-323 bugs lived.
# ============================================================================

"""
    validate_gc_instruction!(v, gc_opcode, type_info)

Validate a GC-prefixed (0xFB) instruction's stack effect. `gc_opcode` is the
byte AFTER the GC prefix (e.g., Opcode.STRUCT_NEW = 0x00). `type_info` provides
type context needed for validation (type index, field types, element types).

Mirrors dart2wasm's InstructionsBuilder assertion checks for GC instructions.
"""
function validate_gc_instruction!(v::WasmStackValidator, gc_opcode::UInt8, type_info=nothing)
    v.enabled || return

    if gc_opcode == Opcode.STRUCT_NEW
        # struct.new $t: pop N field values (in reverse order), push (ref $t)
        type_idx, field_types = type_info
        for ft in reverse(field_types)
            validate_pop!(v, ft)
        end
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.STRUCT_NEW_DEFAULT
        # struct.new_default $t: no pops (all fields get defaults), push (ref $t)
        type_idx = type_info isa Tuple ? type_info[1] : type_info
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.STRUCT_GET || gc_opcode == Opcode.STRUCT_GET_S || gc_opcode == Opcode.STRUCT_GET_U
        # struct.get $t $i: pop (ref null $t), push field_type
        type_idx, field_type = type_info
        validate_pop!(v, ConcreteRef(UInt32(type_idx), true))
        validate_push!(v, field_type)

    elseif gc_opcode == Opcode.STRUCT_SET
        # struct.set $t $i: pop value, pop (ref null $t)
        type_idx, field_type = type_info
        validate_pop!(v, field_type)
        validate_pop!(v, ConcreteRef(UInt32(type_idx), true))

    elseif gc_opcode == Opcode.ARRAY_NEW
        # array.new $t: pop init_value, pop i32 length, push (ref $t)
        type_idx, elem_type = type_info
        validate_pop!(v, I32)       # length
        validate_pop!(v, elem_type) # init value
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.ARRAY_NEW_DEFAULT
        # array.new_default $t: pop i32 length, push (ref $t)
        type_idx = type_info isa Tuple ? type_info[1] : type_info
        validate_pop!(v, I32)  # length
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.ARRAY_NEW_FIXED
        # array.new_fixed $t $n: pop n elem values, push (ref $t)
        type_idx, elem_type, n = type_info
        for _ in 1:n
            validate_pop!(v, elem_type)
        end
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.ARRAY_NEW_DATA
        # array.new_data $t $d: pop i32 length, pop i32 offset, push (ref $t)
        type_idx = type_info isa Tuple ? type_info[1] : type_info
        validate_pop!(v, I32)  # length
        validate_pop!(v, I32)  # offset
        validate_push!(v, ConcreteRef(UInt32(type_idx), false))

    elseif gc_opcode == Opcode.ARRAY_GET || gc_opcode == Opcode.ARRAY_GET_S || gc_opcode == Opcode.ARRAY_GET_U
        # array.get $t: pop i32 index, pop (ref null $t), push elem_type
        type_idx, elem_type = type_info
        validate_pop!(v, I32)  # index
        validate_pop!(v, ConcreteRef(UInt32(type_idx), true))  # array ref
        validate_push!(v, elem_type)

    elseif gc_opcode == Opcode.ARRAY_SET
        # array.set $t: pop value, pop i32 index, pop (ref null $t)
        type_idx, elem_type = type_info
        validate_pop!(v, elem_type)  # value
        validate_pop!(v, I32)        # index
        validate_pop!(v, ConcreteRef(UInt32(type_idx), true))  # array ref

    elseif gc_opcode == Opcode.ARRAY_LEN
        # array.len: pop any array ref, push i32
        validate_pop_any!(v)
        validate_push!(v, I32)

    elseif gc_opcode == Opcode.ARRAY_FILL
        # array.fill $t: pop i32 size, pop value, pop i32 offset, pop (ref null $t)
        type_idx, elem_type = type_info
        validate_pop!(v, I32)        # size
        validate_pop!(v, elem_type)  # fill value
        validate_pop!(v, I32)        # offset
        validate_pop!(v, ConcreteRef(UInt32(type_idx), true))  # array ref

    elseif gc_opcode == Opcode.ARRAY_COPY
        # array.copy $t1 $t2: pop i32 len, pop i32 src_offset, pop (ref null $t2),
        #                      pop i32 dst_offset, pop (ref null $t1)
        dst_type_idx, src_type_idx = type_info
        validate_pop!(v, I32)  # length
        validate_pop!(v, I32)  # src offset
        validate_pop!(v, ConcreteRef(UInt32(src_type_idx), true))  # src array
        validate_pop!(v, I32)  # dst offset
        validate_pop!(v, ConcreteRef(UInt32(dst_type_idx), true))  # dst array

    elseif gc_opcode == Opcode.REF_CAST
        # ref.cast (ref $t): pop ref, push (ref $t) non-nullable
        target_type = type_info
        validate_pop_any!(v)
        validate_push!(v, target_type)

    elseif gc_opcode == Opcode.REF_CAST_NULL
        # ref.cast null (ref null $t): pop ref, push (ref null $t) nullable
        target_type = type_info
        validate_pop_any!(v)
        validate_push!(v, target_type)

    elseif gc_opcode == Opcode.ANY_CONVERT_EXTERN
        # any.convert_extern: pop externref, push anyref
        validate_pop!(v, ExternRef)
        validate_push!(v, AnyRef)

    elseif gc_opcode == Opcode.EXTERN_CONVERT_ANY
        # extern.convert_any: pop anyref, push externref
        validate_pop_any!(v)  # any anyref subtype
        validate_push!(v, ExternRef)

    # Unknown GC opcode — skip silently
    end
end
