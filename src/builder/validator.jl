# Stack Validator — catches type mismatches during codegen (like dart2wasm's InstructionsBuilder)
#
# dart2wasm tracks _stackTypes (List<ValueType>) and validates push/pop during
# bytecode emission. Individual stack-effect checks append precise diagnostics; the
# instruction builder throws them at that same emit before another instruction can run.

export WasmStackValidator, validate_push!, validate_pop!, validate_pop_any!,
       stack_height, has_errors, reset_validator!, validate_instruction!,
       ControlLabel, ValidatorLabel, validate_block_start!, validate_block_end!,
       validate_br!, validate_br_if!, validate_if_start!, validate_else!,
       validate_gc_instruction!

"""Symbolic structured-control target, matching dart2wasm's `Label` API. parity(pkg/wasm_builder/lib/src/builder/instructions.dart:31 Label)"""
mutable struct ControlLabel
    kind::Symbol
    input_types::Vector{WasmValType}
    output_types::Vector{WasmValType}
end

"""
    ValidatorLabel

Label stack entry for control flow validation, mirroring dart2wasm's Label class.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:31 Label)
Tracks block kind, stack height at entry, result types, and reachability.

Key insight from dart2wasm:
- Loop.targetTypes = inputs (br restarts loop with its input types)
- Block/If.targetTypes = outputs (br exits with block's result types)
"""
struct ValidatorLabel
    handle::ControlLabel                # identity-bearing branch target
    kind::Symbol                        # :block, :loop, :if
    stack_height_at_entry::Int          # Stack height when block was entered
    input_types::Vector{WasmValType}    # Loop branch target types
    result_types::Vector{WasmValType}   # Block's result types (outputs)
    reachable_at_entry::Bool            # Was block entry reachable?
    has_else::Bool                      # For :if labels — has else branch been seen?
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:31 Label)
function ValidatorLabel(kind::Symbol, stack_height::Int,
                        input_types::Vector{WasmValType}, result_types::Vector{WasmValType},
                        reachable::Bool; handle=ControlLabel(kind, input_types, result_types))::ValidatorLabel
    ValidatorLabel(handle, kind, stack_height, input_types, result_types, reachable, false)
end

"""
    WasmStackValidator

Tracks the Wasm value stack during bytecode emission and catches type mismatches
immediately, rather than requiring post-hoc `wasm-tools validate` + WAT analysis.

Modeled on dart2wasm's InstructionsBuilder._stackTypes / _checkStackTypes pattern.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:211 InstructionsBuilder._labelStack/_stackTypes/_reachable)
"""
mutable struct WasmStackValidator
    stack::Vector{WasmValType}          # Current value stack (types)
    errors::Vector{String}              # Pending diagnostics thrown by InstrBuilder._check!
    func_name::String                   # For error messages
    labels::Vector{ValidatorLabel}      # Label stack for control flow
    reachable::Bool                     # Whether current code is reachable
    # The WasmModule being built — `wasm_subtype` needs it to resolve a ConcreteRef's
    # declared supertype chain (struct-vs-array kind + nominal `<:`). `nothing` when
    # unavailable — e.g. the numeric-only int128 builders, where no ConcreteRef ever
    # reaches the heap-kind branch, so the degraded relation is never exercised (Loop A).
    mod::Union{Nothing, WasmModule}
    context_hint::String   # the emitting Julia statement (set via set_context!)
end

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:233 InstructionsBuilder)
WasmStackValidator(; func_name="", mod=nothing)::WasmStackValidator =
    WasmStackValidator(WasmValType[], String[], func_name, ValidatorLabel[], true, mod, "")

"""
    validate_push!(v, typ)

Push a type onto the validation stack. Mirrors dart2wasm's _stackTypes.addAll(outputs).
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:508 InstructionsBuilder._verifyTypesFun)
"""
function validate_push!(v::WasmStackValidator, typ::WasmValType)::Vector{WasmValType}
    push!(v.stack, typ)
end

# dart2wasm `_verifyTypes`: an instruction may not pop below the innermost block's
# baseStackHeight — that would consume values belonging to an enclosing block, which
# the wasm stack discipline forbids. `_base` returns that floor.
# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:462 InstructionsBuilder._topOfLabelStack)
@inline _base(v::WasmStackValidator)::Int64 = isempty(v.labels) ? 0 : v.labels[end].stack_height_at_entry

"""
    validate_pop!(v, expected) -> WasmValType

Pop a value from the validation stack, checking that the actual type is assignable
to `expected`. Returns the actual type found (or `expected` on underflow).
Mirrors dart2wasm's _checkStackTypes + _stackTypes.length -= inputs.length.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:474 InstructionsBuilder._checkStackTypes)
"""
function validate_pop!(v::WasmStackValidator, expected::WasmValType)::WasmValType
    # wasm spec: post-unreachable code validates POLYMORPHICALLY — pops succeed
    # against the bottom type (the tag-run corpus tail's root: dead-path phi
    # stores popped an empty tracked stack that the spec says is bottomless).
    v.reachable || return expected
    if length(v.stack) <= _base(v)
        # Name the CURE — a fragment consuming the parent's stack must
        # DECLARE the input via seeding (append_builder! settles the contract).
        push!(v.errors, "UNDERFLOW $(v.func_name): stack underflow (past block base) — expected $(expected) " *
              "[ctx: $(v.context_hint)]. FIX: seed the fragment's input so the merge settles it.")
        return expected
    end
    actual = pop!(v.stack)
    if !wasm_subtype(actual, expected, v.mod)
        push!(v.errors, "$(v.func_name): type mismatch — expected $(expected), found $(actual)")
    end
    return actual
end

"""
    validate_pop_any!(v) -> Union{WasmValType, Nothing}

Pop any type from the validation stack without type checking.
Returns `nothing` on underflow.
parity(quarantine: a pop whose operand its caller checks itself — a reference operand, a
fragment seam; dart's _verifyTypes names every input's type.)
"""
function validate_pop_any!(v::WasmStackValidator)::Union{WasmValType, Nothing}
    v.reachable || return nothing   # spec: polymorphic post-unreachable
    if length(v.stack) <= _base(v)
        push!(v.errors, "UNDERFLOW $(v.func_name): stack underflow on pop_any (past block base) " *
              "[ctx: $(v.context_hint)]. FIX: seed the fragment's input.")
        return nothing
    end
    return pop!(v.stack)
end

"""
    validate_pop_ref!(v) -> Union{WasmValType, Nothing}

Pop a reference of any hierarchy (dart's `RefType.common(nullable: true)`, which ref.is_null,
ref.as_non_null and the casts take): a numeric operand is an error at the emitting line.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1582 InstructionsBuilder.ref_is_null)
"""
function validate_pop_ref!(v::WasmStackValidator)::Union{WasmValType, Nothing}
    local t = validate_pop_any!(v)
    t === nothing && return nothing
    (t isa RefType || t isa ConcreteRef || t isa NonNullAbstractRef) ||
        push!(v.errors, "$(v.func_name): expected a reference, found $(t) [ctx: $(v.context_hint)]")
    return t
end

"""
    stack_height(v) -> Int

Current number of values on the validation stack.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:472 InstructionsBuilder.stack)
"""
stack_height(v::WasmStackValidator)::Int64 = length(v.stack)

"""
    has_errors(v) -> Bool

Whether any validation errors have been collected.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:452 InstructionsBuilder._reportError)
"""
has_errors(v::WasmStackValidator)::Bool = !isempty(v.errors)

"""
    reset_validator!(v)

Clear the stack and errors for reuse (e.g., between functions).
parity(quarantine: WT reuses one validator across the functions and fragments of a module;
dart creates an InstructionsBuilder per function.)
"""
function reset_validator!(v::WasmStackValidator)::Bool
    empty!(v.stack)
    empty!(v.errors)
    empty!(v.labels)
    v.reachable = true
end

# ============================================================================
# Type Assignability
# ============================================================================

# Type assignability is now the precise dart2wasm-faithful `wasm_subtype` lattice
# (src/codegen/values.jl `isSubtypeOf`): nullability-aware, walks a ConcreteRef's
# declared supertype chain, and respects the abstract any/eq/struct/array/i31/func/
# extern/exn hierarchy. The old permissive `wasm_types_assignable` (any-ref ↔ any-ref ⇒
# true) + `_is_ref_type` shim were a deliberate "start permissive, tighten later"
# placeholder — DELETED here (Loop A): the validator calls `wasm_subtype`
# directly at every pop/branch/block-result check, with `v.mod` for the concrete chain.

# ============================================================================
# Opcode Sets for Instruction Validation
# ============================================================================

# parity-region(quarantine: the operand and result types of the no-immediate numeric,
# comparison and conversion instructions by opcode, which dart states in each emitter's
# _verifyTypes (i32_add … f64_promote_f32); num! emits them all.)
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

# end parity-region

# ============================================================================
# Instruction Validation — numeric, parametric, and conversion ops
# ============================================================================

"""
    validate_instruction!(v, opcode, type_info=nothing)

Validate a single instruction's stack effect. Pops expected operands and pushes
results according to the Wasm spec. Mirrors dart2wasm's InstructionsBuilder
assertion checks for numeric/parametric/conversion instructions.
parity(quarantine: the per-opcode stack effects num! validates, which dart checks in each
emitter's _verifyTypes.)

For GC-prefixed instructions (0xFB), use validate_gc_instruction!.
"""
function validate_instruction!(v::WasmStackValidator, opcode::UInt8, type_info=nothing)::Union{Nothing, WasmValType, Vector{WasmValType}}

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
    elseif opcode == Opcode.SELECT || opcode == Opcode.SELECT_T
        # select t: [t, t, i32] → [t], its value type named by the caller (dart select(type),
        # instructions.dart:1004)
        type_info isa WasmValType ||
            throw(ArgumentError("select needs its value type (select!(b, t))"))
        validate_pop!(v, I32)  # condition
        validate_pop!(v, type_info)
        validate_pop!(v, type_info)
        validate_push!(v, type_info)

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

    # --- Sign-extension (i32; the i64 family was already tracked) ---
    elseif opcode == Opcode.I32_EXTEND8_S || opcode == Opcode.I32_EXTEND16_S
        validate_pop!(v, I32); validate_push!(v, I32)

    # --- Float precision conversion (were UNTRACKED — the fma32 class) ---
    elseif opcode == Opcode.F64_PROMOTE_F32
        validate_pop!(v, F32); validate_push!(v, F64)
    elseif opcode == Opcode.F32_DEMOTE_F64
        validate_pop!(v, F64); validate_push!(v, F32)

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
        # a nullable reference of any hierarchy (dart RefType.common(nullable: true))
        validate_pop_ref!(v); validate_push!(v, I32)
    elseif opcode == Opcode.REF_EQ
        validate_pop!(v, EqRef); validate_pop!(v, EqRef); validate_push!(v, I32)

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

    else
        throw(ArgumentError("unmodeled Wasm opcode 0x$(string(opcode, base=16, pad=2)) in strict instruction validator"))
    end
end

# ============================================================================
# Control Flow Validation
# Mirrors dart2wasm's _labelStack / Label hierarchy
# ============================================================================

"""
    validate_block_start!(v, kind, result_types)

Push a label onto the label stack for a block/loop. Records the current stack
height so we can validate that the block produces exactly `result_types` when
it ends. Mirrors dart2wasm's `_pushLabel(Block(...))` / `_pushLabel(Loop(...))`.

For loops, `br` targets the loop start (no values consumed/produced by br).
For blocks, `br` targets the block end (must have result_types on stack).
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:695 InstructionsBuilder._pushLabel)
"""
validate_block_start!(v::WasmStackValidator, kind::Symbol,
                      result_types::Vector{WasmValType}=WasmValType[])::ControlLabel =
    validate_block_start!(v, kind, WasmValType[], result_types)

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:695 InstructionsBuilder._pushLabel)
function validate_block_start!(v::WasmStackValidator, kind::Symbol,
                               input_types::Vector{WasmValType},
                               result_types::Vector{WasmValType})::ControlLabel
    for t in reverse(input_types); validate_pop!(v, t); end
    for t in input_types; validate_push!(v, t); end
    label = ValidatorLabel(kind, length(v.stack) - length(input_types),
                           input_types, result_types, v.reachable)
    push!(v.labels, label)
    return label.handle
end

"""
    validate_block_end!(v)

End the current block: pop the top label, verify the stack contains exactly
the block's result types above the entry height, then reset the stack to
entry_height + result_types. Mirrors dart2wasm's `end()` + `_verifyEndOfBlock`.

Reachability is restored from the label's `reachable_at_entry` — if the block
entry was reachable, code after the block is reachable (even if the block body
ended with an unconditional br).
formal(dev/formal/OperandStack.tla): the builder accepts every program the spec's validation
algorithm accepts, and rejects every invalid one whose instructions are all reachable.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:566 InstructionsBuilder._verifyEndOfBlock)
"""
function validate_block_end!(v::WasmStackValidator)::Union{Nothing, Bool}
    if isempty(v.labels)
        push!(v.errors, "$(v.func_name): end without matching block/loop/if")
        return
    end
    label = pop!(v.labels)
    # an if without else passes its inputs through its implicit empty else, so it is valid only
    # when that else is: as many inputs as results, each input a subtype of its result (the Wasm
    # spec; dart does not check it, the engine does). formal(dev/formal/OperandStack.tla):
    # ElseLessExact is the equality rule, which rejected a valid if
    (label.kind === :if && !label.has_else &&
     !(length(label.input_types) == length(label.result_types) &&
       all(wasm_subtype(i, r, v.mod) for (i, r) in zip(label.input_types, label.result_types)))) &&
        push!(v.errors, "$(v.func_name): an if with results $(label.result_types) needs an else " *
                        "(its inputs are $(label.input_types))")

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
                if !wasm_subtype(actual, expected, v.mod)
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
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:863 InstructionsBuilder.br)
"""
function validate_br!(v::WasmStackValidator, label_depth::Int)::Nothing
    validate_branch_types!(v, label_depth)
    v.reachable = false
    return nothing
end

"""
    validate_branch_types!(v, label_depth, popped = 0, pushed = WasmValType[])

The values a branching instruction carries to the label at `label_depth`, once it pops
`popped` operands and pushes `pushed`: the top of that stack must match the label's target
types (a loop's inputs, a block's results), above the label's base. `br_on_null` carries what
lies under its operand; `br_on_non_null` carries that plus the operand made non-null.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:532 InstructionsBuilder._verifyBranchTypes)
"""
function validate_branch_types!(v::WasmStackValidator, label_depth::Int, popped::Int = 0,
                                pushed::Vector{WasmValType} = WasmValType[])::Nothing
    v.reachable || return nothing
    if label_depth < 0 || label_depth >= length(v.labels)
        push!(v.errors, "$(v.func_name): branch label depth $(label_depth) out of range ($(length(v.labels)) labels)")
        return nothing
    end
    label = v.labels[end - label_depth]
    inputs = label.kind === :loop ? label.input_types : label.result_types
    n = length(v.stack)
    if n - popped + length(pushed) - length(inputs) < label.stack_height_at_entry
        push!(v.errors, "$(v.func_name): branch underflows the base stack of its target $(label.kind) " *
              "[ctx: $(v.context_hint)]")
        return nothing
    end
    stack = length(inputs) <= length(pushed) ? pushed[end - length(inputs) + 1:end] :
            WasmValType[v.stack[n - popped + length(pushed) - length(inputs) + 1:n - popped]; pushed]
    for (i, expected) in enumerate(inputs)
        wasm_subtype(stack[i], expected, v.mod) ||
            push!(v.errors, "$(v.func_name): branch to $(label.kind) type mismatch at position $i — " *
                  "expected $(expected), found $(stack[i]) [ctx: $(v.context_hint)]")
    end
    return nothing
end

"""
    validate_br_if!(v, label_depth)

Validate a conditional branch: pop i32 condition, then verify the target
label like br. Unlike br, code after br_if remains reachable.
Mirrors dart2wasm's `br_if(label)`.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:878 InstructionsBuilder.br_if)
"""
function validate_br_if!(v::WasmStackValidator, label_depth::Int)::Nothing
    v.reachable || return nothing
    validate_pop!(v, I32)
    validate_branch_types!(v, label_depth)
    return nothing
end

"""
    validate_if_start!(v, result_types)

Validate an if instruction: pop i32 condition, push label for the then-branch.
Mirrors dart2wasm's `if_()` which calls `_verifyTypes([i32], [])` then `_pushLabel(If(...))`.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:753 InstructionsBuilder.if_)
"""
validate_if_start!(v::WasmStackValidator,
                   result_types::Vector{WasmValType}=WasmValType[])::ControlLabel =
    validate_if_start!(v, WasmValType[], result_types)

# parity(pkg/wasm_builder/lib/src/builder/instructions.dart:753 InstructionsBuilder.if_)
function validate_if_start!(v::WasmStackValidator,
                            input_types::Vector{WasmValType},
                            result_types::Vector{WasmValType})::ControlLabel
    validate_pop!(v, I32)  # condition
    for t in reverse(input_types); validate_pop!(v, t); end
    for t in input_types; validate_push!(v, t); end
    handle = ControlLabel(:if, input_types, result_types)
    label = ValidatorLabel(handle, :if, length(v.stack) - length(input_types),
                           input_types, result_types, v.reachable, false)
    push!(v.labels, label)
    return handle
end

"""
    validate_else!(v)

Validate an else instruction: verify the then-branch stack, reset stack to
block entry height for the else-branch, restore reachability.
Mirrors dart2wasm's `else_()`.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:767 InstructionsBuilder.else_)
"""
function validate_else!(v::WasmStackValidator)::Union{Nothing, Bool}
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

    # Validate the then-branch's end as a block end: its height AND its value types against the
    # if's results (dart `_verifyEndOfBlock` → `_checkStackTypes(label.outputs)`); only the
    # height was checked, so an arm leaving a value of another type reached the module
    if v.reachable
        expected_height = label.stack_height_at_entry + length(label.result_types)
        if length(v.stack) != expected_height
            push!(v.errors, "$(v.func_name): if then-branch stack height mismatch — expected $(expected_height), got $(length(v.stack))")
        end
        for (i, expected) in enumerate(label.result_types)
            idx = label.stack_height_at_entry + i
            if idx <= length(v.stack) && !wasm_subtype(v.stack[idx], expected, v.mod)
                push!(v.errors, "$(v.func_name): if then-branch result type mismatch at position $i — expected $(expected), found $(v.stack[idx])")
            end
        end
    end

    # Replace label with has_else=true
    v.labels[end] = ValidatorLabel(label.handle, label.kind, label.stack_height_at_entry,
                                   label.input_types, label.result_types,
                                   label.reachable_at_entry, true)

    # Reset the stack to the if's base and give the else arm the if's inputs, as the then arm
    # had them (dart else_: `_stackTypes.length = baseStackHeight; addAll(label.inputs)`)
    resize!(v.stack, label.stack_height_at_entry)
    append!(v.stack, label.input_types)

    # Restore reachability from block entry
    v.reachable = label.reachable_at_entry
end

# ============================================================================
# WasmGC Instruction Validation
# Mirrors dart2wasm's InstructionsBuilder GC instruction assertions.
# These are the operations where specific bugs lived.
# ============================================================================

"""
    validate_gc_instruction!(v, gc_opcode, type_info)

Validate a GC-prefixed (0xFB) instruction's stack effect. `gc_opcode` is the
byte AFTER the GC prefix (e.g., Opcode.STRUCT_NEW = 0x00). `type_info` provides
type context needed for validation (type index, field types, element types).

Mirrors dart2wasm's InstructionsBuilder assertion checks for GC instructions.
parity(quarantine: the GC instructions' stack effects by opcode, which dart checks in each
emitter's _verifyTypes (struct_new … array_copy).)
"""
function validate_gc_instruction!(v::WasmStackValidator, gc_opcode::UInt8, type_info=nothing)::Union{WasmValType, Vector{WasmValType}}

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
        # array.len: pop an array reference, push i32 (dart array_len: RefType.array)
        validate_pop!(v, ArrayRef)
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
        actual = validate_pop_ref!(v)
        # P13: a ref.cast is only valid WITHIN one reference hierarchy — the operand and
        # the target must share a top (any / func / extern / exn). A cross-hierarchy cast
        # (e.g. externref → a GC struct) can never be expressed; codegen must emit an
        # extern.convert_any first. (Within-hierarchy always-trapping casts stay valid.)
        if actual !== nothing && !_wt_same_hierarchy(actual, target_type, v.mod)
            push!(v.errors, "$(v.func_name): ref.cast target $(target_type) is in a different hierarchy than the operand $(actual)")
        end
        validate_push!(v, target_type)

    elseif gc_opcode == Opcode.REF_CAST_NULL
        # ref.cast null (ref null $t): pop ref, push (ref null $t) nullable
        target_type = type_info
        actual = validate_pop_ref!(v)
        if actual !== nothing && !_wt_same_hierarchy(actual, target_type, v.mod)
            push!(v.errors, "$(v.func_name): ref.cast null target $(target_type) is in a different hierarchy than the operand $(actual)")
        end
        validate_push!(v, target_type)

    elseif gc_opcode == Opcode.ANY_CONVERT_EXTERN
        # any.convert_extern: pop externref, push anyref
        validate_pop!(v, ExternRef)
        validate_push!(v, AnyRef)

    elseif gc_opcode == Opcode.EXTERN_CONVERT_ANY
        # extern.convert_any: pop anyref, push externref (dart extern_convert_any)
        validate_pop!(v, AnyRef)
        validate_push!(v, ExternRef)

    elseif gc_opcode == Opcode.REF_TEST || gc_opcode == Opcode.REF_TEST_NULL
        # ref.test (ref $t): pop a reference in the target's hierarchy, push i32
        local actual = validate_pop_ref!(v)
        if actual !== nothing && type_info !== nothing && !_wt_same_hierarchy(actual, type_info, v.mod)
            push!(v.errors, "$(v.func_name): ref.test target $(type_info) is in a different hierarchy than the operand $(actual)")
        end
        validate_push!(v, I32)

    else
        throw(ArgumentError("unmodeled Wasm GC opcode 0x$(string(gc_opcode, base=16, pad=2)) in strict instruction validator"))
    end
end
