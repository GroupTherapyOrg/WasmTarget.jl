# ============================================================================
# Code Generation
# ============================================================================

"""
    validate_emitted_bytes!(ctx, bytes, stmt_idx)

PURE-414: Scan emitted bytecode and validate stack effects for recognized opcodes.
This is a MINIMAL first pass — validates constants, locals, drops, and GC ops.
Runs in parallel with bytecode emission (doesn't modify bytes, just tracks stack state).

Skips unknown multi-byte sequences silently — later passes will add more coverage.
"""
function validate_emitted_bytes!(ctx::CompilationContext, bytes::Vector{UInt8}, stmt_idx::Int)
    ctx.validator.enabled || return
    v = ctx.validator
    # Reset stack for each statement in the minimal first pass.
    # We don't track all opcodes yet, so inter-statement stack state
    # would produce false positives. Each statement is validated independently.
    empty!(v.stack)
    has_unknown = false  # Track if we hit opcodes we don't validate
    i = 1
    while i <= length(bytes)
        op = bytes[i]
        if op == Opcode.I32_CONST
            validate_instruction!(v, op)
            i += 1
            # Skip LEB128 immediate
            while i <= length(bytes) && (bytes[i] & 0x80) != 0; i += 1; end
            i <= length(bytes) && (i += 1)  # skip final byte of LEB128
        elseif op == Opcode.I64_CONST
            validate_instruction!(v, op)
            i += 1
            while i <= length(bytes) && (bytes[i] & 0x80) != 0; i += 1; end
            i <= length(bytes) && (i += 1)
        elseif op == Opcode.F32_CONST
            validate_instruction!(v, op)
            i += 1 + 4  # 4 bytes for f32
        elseif op == Opcode.F64_CONST
            validate_instruction!(v, op)
            i += 1 + 8  # 8 bytes for f64
        elseif op == Opcode.LOCAL_GET
            # local.get pushes a value — determine type from ctx.locals
            i += 1
            local_idx_start = i
            while i <= length(bytes) && (bytes[i] & 0x80) != 0; i += 1; end
            if i <= length(bytes)
                # Decode LEB128 local index
                local_idx = 0
                shift = 0
                for j in local_idx_start:i
                    local_idx |= (Int(bytes[j] & 0x7f) << shift)
                    shift += 7
                end
                i += 1
                # Determine type: params first, then locals
                local_type = _get_local_type(ctx, local_idx)
                if local_type !== nothing
                    validate_push!(v, local_type)
                end
            end
        elseif op == Opcode.LOCAL_SET
            # local.set pops a value
            i += 1
            local_idx_start = i
            while i <= length(bytes) && (bytes[i] & 0x80) != 0; i += 1; end
            if i <= length(bytes)
                local_idx = 0
                shift = 0
                for j in local_idx_start:i
                    local_idx |= (Int(bytes[j] & 0x7f) << shift)
                    shift += 7
                end
                i += 1
                local_type = _get_local_type(ctx, local_idx)
                if local_type !== nothing
                    validate_pop!(v, local_type)
                end
            end
        elseif op == Opcode.LOCAL_TEE
            # local.tee pops then pushes (net effect: type stays, but validates)
            i += 1
            while i <= length(bytes) && (bytes[i] & 0x80) != 0; i += 1; end
            i <= length(bytes) && (i += 1)
        elseif op == Opcode.DROP
            validate_instruction!(v, op)
            i += 1
        elseif op == Opcode.RETURN
            # Return clears the stack — reset validator stack for this scope
            empty!(v.stack)
            i += 1
        elseif op == Opcode.UNREACHABLE
            empty!(v.stack)
            v.reachable = false
            i += 1
        else
            # Unknown/multi-byte opcode — skip without validating
            # This includes control flow (block/loop/if/end/br), calls, GC prefix, etc.
            # These will be added in future passes
            has_unknown = true
            i += 1
        end
    end
    # If we hit unrecognized opcodes, filter out underflow errors (false positives)
    # since we can't fully track stack state without complete opcode coverage
    if has_unknown
        filter!(e -> !contains(e, "stack underflow"), v.errors)
    end
end

"""
    _get_local_type(ctx, local_idx) -> Union{WasmValType, Nothing}

Get the Wasm type of a local variable by its index. Parameters come first,
then additional locals from ctx.locals.
"""
function _get_local_type(ctx::CompilationContext, local_idx::Int)::Union{WasmValType, Nothing}
    if local_idx < ctx.n_params
        # It's a parameter — get type from arg_types (skip WasmGlobal args)
        param_count = 0
        for (i, T) in enumerate(ctx.arg_types)
            if i in ctx.global_args
                continue
            end
            if param_count == local_idx
                return get_concrete_wasm_type(T, ctx.mod, ctx.type_registry)
            end
            param_count += 1
        end
        return nothing
    else
        # It's an additional local
        local_offset = local_idx - ctx.n_params
        if local_offset >= 0 && local_offset < length(ctx.locals)
            return ctx.locals[local_offset + 1]  # 1-indexed
        end
        return nothing
    end
end

"""
Generate Wasm bytecode from Julia CodeInfo.
Uses a block-based translation for control flow.
"""
function generate_body(ctx::CompilationContext)::Vector{UInt8}
    code = ctx.code_info.code
    n = length(code)

    # Analyze control flow to find basic block structure
    blocks = analyze_blocks(code)

    # Generate code using structured control flow
    bytes = generate_structured(ctx, blocks)

    # PURE-036y: Post-process to fix broken SELECT instructions.
    # Pattern: [local.get N, struct.new M, select] without a condition is broken.
    # Fix by removing the struct.new and select, keeping only local.get.
    bytes = fix_broken_select_instructions(bytes)

    # PURE-6025: Post-process to fix numeric constants stored to ref-typed locals.
    # Pattern: [i32_const VALUE] [local_set IDX] where IDX is a ref-typed local.
    # This happens when Julia type inference returns a Union type (e.g., Union{ConcreteRef, UInt8})
    # whose wasm type maps to ConcreteRef, but the actual compiled value is a UInt8 literal
    # (e.g., ExternRef=0x6f=111). The type mismatch goes undetected because
    # get_phi_edge_wasm_type returns ConcreteRef (matching the phi local type), but
    # compile_phi_value emits i32_const 111. Replace with ref.null of the local's type.
    bytes = fix_numeric_to_ref_local_stores(bytes, ctx.locals, ctx.n_params)

    # PURE-6025: Fix dead returns at the very end of a function body.
    # This happens when all paths inside the block return, leaving a dead return
    # with empty stack. Two patterns:
    # Pattern 1: [end] [return] [unreachable] [end] — dead return before unreachable
    # Pattern 2: [return] [end] [return] [end] — both if/else branches return
    if length(bytes) >= 4 && bytes[end] == Opcode.END
        if bytes[end - 1] == 0x00 && bytes[end - 2] == Opcode.RETURN && bytes[end - 3] == Opcode.END
            bytes[end - 2] = 0x00  # Replace RETURN with UNREACHABLE
        elseif bytes[end - 1] == Opcode.RETURN && bytes[end - 2] == Opcode.END && bytes[end - 3] == Opcode.RETURN
            bytes[end - 1] = 0x00  # Replace dead RETURN with UNREACHABLE
        end
    end

    # PURE-6022: Fix consecutive local_set instructions (multi-target phi assignments).
    # When a value feeds into multiple phi nodes, the codegen emits local_set for each
    # target. But local_set consumes the stack value, leaving nothing for subsequent sets.
    # Fix: convert local_set to local_tee when the next instruction is also local_set.
    bytes = fix_consecutive_local_sets(bytes)

    # PURE-6022: Strip excess bytes after the function body's closing `end`.
    # The flow generator may emit dead code (unreachable, br, etc.) after all blocks
    # are closed, creating bytes outside the function body expression. The WASM spec
    # requires: func = locals* expr, where expr = instr* end. Any bytes after the
    # expression's closing `end` cause "operators remaining after end of function body."
    bytes = strip_excess_after_function_end(bytes)

    # PURE-6022: Fix local_get → local_set/tee with i32↔i64 type mismatch.
    # Runs LAST to process the final bytes (same as what wasm-tools validates).
    # SUITE-1101: Skip WasmGlobal args — they're accessed via global.get/set,
    # not as wasm function params. Including them shifts all local type indices,
    # causing fix_local_get_set_type_mismatch to insert spurious conversions.
    param_wasm_types = WasmValType[]
    for (i, T) in enumerate(ctx.arg_types)
        if !(i in ctx.global_args)
            push!(param_wasm_types, get_concrete_wasm_type(T, ctx.mod, ctx.type_registry))
        end
    end
    all_local_types = vcat(param_wasm_types, ctx.locals)
    bytes = fix_local_get_set_type_mismatch(bytes, all_local_types)

    # PURE-6022: Remove spurious i32_wrap_i64 after array_len.
    # Must run LAST — fix_local_get_set_type_mismatch can introduce i32_wrap_i64 patterns
    # that land after array_len. WasmGC array_len returns i32, but codegen treats length()
    # as i64 and inserts i32_wrap_i64 expecting i64 input, causing validation error.
    bytes = fix_array_len_wrap(bytes)

    # PURE-6027: Insert i32_wrap_i64 when i64 local feeds into i32 binary ops.
    # Pattern: local_get <i64_idx>, i32_const <val>, i32_sub/add/etc.
    # The codegen may emit i32 ops for values that are actually in i64 locals
    # (e.g., after dead code guard scoping exposes previously masked code paths).
    bytes = fix_i64_local_in_i32_ops(bytes, all_local_types)

    # PURE-6022: Remove spurious i32_wrap_i64 after comparison/i32 ops.
    # Comparisons (i32_eqz, i64_eq, etc.) return i32, but codegen may emit i32_wrap_i64
    # expecting i64 input from a value that is already i32.
    bytes = fix_i32_wrap_after_i32_ops(bytes)

    # PURE-414: Check validator for errors after function body generation
    if has_errors(ctx.validator)
        @warn "Stack validator found $(length(ctx.validator.errors)) issue(s) in $(ctx.validator.func_name)" errors=ctx.validator.errors
    end

    return bytes
end

"""
PURE-6022: Remove spurious i32_wrap_i64 after array_len.

WasmGC array_len (0xFB 0x0F) returns i32, but Julia's length() returns Int64.
The codegen emits i32_wrap_i64 (0xA7) expecting i64 input, which fails validation.
Also handles: array_len followed by i64_extend_i32_s (0xAC) is redundant but valid —
we leave those alone since they don't cause validation errors.
"""
function fix_array_len_wrap(bytes::Vector{UInt8})::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes))
    i = 1
    fixes = 0
    while i <= length(bytes)
        # Check for array_len (0xFB 0x0F) followed by i32_wrap_i64 (0xA7)
        if bytes[i] == 0xFB && i + 2 <= length(bytes) && bytes[i+1] == 0x0F && bytes[i+2] == 0xA7
            # Emit array_len but skip the i32_wrap_i64
            push!(result, bytes[i])    # 0xFB
            push!(result, bytes[i+1])  # 0x0F
            # Skip 0xA7 (i32_wrap_i64) — array_len already returns i32
            i += 3
            fixes += 1
            continue
        end
        push!(result, bytes[i])
        i += 1
    end
    if fixes > 0
        @warn "fix_array_len_wrap: removed $fixes spurious i32_wrap_i64 after array_len"
    end
    return result
end

"""
PURE-6022: Remove spurious i32_wrap_i64 after instructions that already produce i32.

Comparison ops (i32_eqz 0x45, i64_eq 0x51, etc.) all return i32. The codegen sometimes
emits i32_wrap_i64 (0xA7) after these, expecting i64 input — which fails validation.
This post-processor uses instruction-level parsing (tracking last_opcode with proper
LEB128 skipping) to avoid false positives from operand bytes that happen to match
i32-producing opcodes.
"""
function fix_i32_wrap_after_i32_ops(bytes::Vector{UInt8})::Vector{UInt8}
    # Track the opcode of the last fully-emitted instruction (not operand bytes).
    # Single-byte opcodes that produce i32:
    # 0x45-0x66 = all comparison ops (i32_eqz through f64_ge)
    # 0x67-0x78 = i32 unary/binary ops (i32_clz through i32_rotr)
    # 0xD1 = ref.is_null
    is_i32_producing = falses(256)
    for op in 0x45:0x78  # comparisons + i32 ops
        is_i32_producing[op + 1] = true
    end
    is_i32_producing[0xD1 + 1] = true  # ref.is_null

    result = UInt8[]
    sizehint!(result, length(bytes))
    i = 1
    fixes = 0
    last_opcode = 0x00  # Track last instruction's opcode
    while i <= length(bytes)
        op = bytes[i]
        # Check if this is i32_wrap_i64 and the preceding instruction produces i32
        if op == 0xA7 && is_i32_producing[last_opcode + 1]
            # Previous instruction already produces i32 — skip this i32_wrap_i64
            i += 1
            fixes += 1
            last_opcode = 0x00  # Reset since we skipped
            continue
        end
        push!(result, op)
        # Update last_opcode based on instruction parsing:
        # Skip operands for instructions that have them, so last_opcode
        # only tracks actual instruction opcodes.
        if op == 0xFB  # GC prefix — 2nd byte is the sub-opcode + optional LEB operands
            last_opcode = 0x00  # GC ops may or may not produce i32; conservatively skip
            i += 1
            # Skip the rest of the GC instruction (sub-opcode + LEB operands)
            if i <= length(bytes)
                push!(result, bytes[i])
                sub = bytes[i]
                i += 1
                # array_new_fixed has 2 LEB operands, most GC ops have 1
                n_lebs = (sub == 0x08 || sub == 0x09) ? 2 :  # array_new_fixed, array_new_data
                         (sub in (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F)) ? 1 :
                         (sub in (0x1B, 0x1A)) ? 0 : 0  # extern_convert_any, any_convert_extern have 0
                for _ in 1:n_lebs
                    while i <= length(bytes)
                        push!(result, bytes[i])
                        done = (bytes[i] & 0x80) == 0
                        i += 1
                        done && break
                    end
                end
            end
        elseif op in (0x20, 0x21, 0x22, 0x23, 0x24)  # local.get/set/tee, global.get/set
            last_opcode = op
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0x41  # i32_const
            last_opcode = 0x41
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0x42  # i64_const
            last_opcode = 0x42
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0x43  # f32_const — 4 bytes
            last_opcode = 0x43
            i += 1
            for _ in 1:4
                i <= length(bytes) && (push!(result, bytes[i]); i += 1)
            end
        elseif op == 0x44  # f64_const — 8 bytes
            last_opcode = 0x44
            i += 1
            for _ in 1:8
                i <= length(bytes) && (push!(result, bytes[i]); i += 1)
            end
        elseif op == 0x10 || op == 0x0C || op == 0x0D  # call, br, br_if — 1 LEB
            last_opcode = op
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0x11  # call_indirect — 2 LEBs
            last_opcode = op
            i += 1
            for _ in 1:2
                while i <= length(bytes)
                    push!(result, bytes[i])
                    done = (bytes[i] & 0x80) == 0
                    i += 1
                    done && break
                end
            end
        elseif op == 0x28 || op == 0x36  # memory.load/store — 2 LEBs (align + offset)
            last_opcode = op
            i += 1
            for _ in 1:2
                while i <= length(bytes)
                    push!(result, bytes[i])
                    done = (bytes[i] & 0x80) == 0
                    i += 1
                    done && break
                end
            end
        elseif op == 0xD2  # ref.func — 1 LEB
            last_opcode = op
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0xD0  # ref.null — 1 LEB (heap type)
            last_opcode = op
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                done = (bytes[i] & 0x80) == 0
                i += 1
                done && break
            end
        elseif op == 0x02 || op == 0x03 || op == 0x04  # block/loop/if — 1 byte blocktype
            last_opcode = op
            i += 1
            if i <= length(bytes)
                push!(result, bytes[i])
                i += 1
            end
        else
            # Single-byte instruction (no operands): comparisons, arithmetic, drops, etc.
            last_opcode = op
            i += 1
        end
    end
    if fixes > 0
        @warn "fix_i32_wrap_after_i32_ops: removed $fixes spurious i32_wrap_i64 after i32-producing ops"
    end
    return result
end

"""
PURE-6027: Insert i32_wrap_i64 when an i64-typed local feeds into i32 binary operations.

Pattern: local_get <idx> (where local is i64), followed by i32_const, then i32 binary op
(i32_add 0x6a through i32_rotr 0x78). This happens when the codegen determines is_32bit=true
from Julia type inference but the actual SSA local was allocated as i64 (e.g., phi nodes that
merge values from branches with different type contexts, or code exposed by dead code guard
scoping). Fix: insert i32_wrap_i64 (0xa7) after the local_get.
"""
function fix_i64_local_in_i32_ops(bytes::Vector{UInt8}, all_local_types::Vector{WasmValType})::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes) + 64)
    i = 1
    fixes = 0
    while i <= length(bytes)
        op = bytes[i]
        if op == 0x20  # local_get
            # Read LEB128 local index
            push!(result, op)
            i += 1
            local_idx = 0
            shift = 0
            leb_start = length(result) + 1
            while i <= length(bytes)
                b = bytes[i]
                push!(result, b)
                local_idx |= (Int(b) & 0x7f) << shift
                shift += 7
                i += 1
                (b & 0x80) == 0 && break
            end
            # Check if this local is i64-typed
            if local_idx + 1 <= length(all_local_types) && all_local_types[local_idx + 1] === I64
                # Look ahead: is next instruction i32_const followed by i32 binary op?
                j = i
                if j <= length(bytes) && bytes[j] == 0x41  # i32_const
                    # Skip i32_const LEB128 operand
                    k = j + 1
                    while k <= length(bytes)
                        (bytes[k] & 0x80) == 0 && break
                        k += 1
                    end
                    k += 1  # past last LEB byte
                    # Check if next byte is an i32 binary op (0x6a-0x78)
                    if k <= length(bytes) && bytes[k] >= 0x6a && bytes[k] <= 0x78
                        push!(result, 0xa7)  # i32_wrap_i64
                        fixes += 1
                    end
                end
            end
        else
            push!(result, op)
            i += 1
        end
    end
    if fixes > 0
        @warn "fix_i64_local_in_i32_ops: inserted $fixes i32_wrap_i64 for i64 locals used in i32 ops"
    end
    return result
end

"""
PURE-6022: Fix consecutive local_set instructions (multi-target phi assignments).

When a value feeds into multiple phi nodes, the codegen emits local_set for each
target. But local_set (0x21) consumes the stack value, leaving nothing for the next
local_set. Fix: convert local_set to local_tee (0x22) when the next instruction is
also local_set. local_tee stores to the local but KEEPS the value on the stack.

Handles chains of any length: tee tee tee ... set.
"""
function fix_consecutive_local_sets(bytes::Vector{UInt8})::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes))
    i = 1
    fixes = 0
    while i <= length(bytes)
        op = bytes[i]
        if op == 0x21  # local_set
            # Peek past the LEB128 local index to find where next instruction starts
            j = i + 1
            while j <= length(bytes) && (bytes[j] & 0x80) != 0
                j += 1
            end
            if j <= length(bytes)
                j += 1  # Past the terminal LEB128 byte — j now points to next instruction
                if j <= length(bytes) && bytes[j] == 0x21  # next is also local_set
                    # Replace local_set with local_tee (keeps value on stack)
                    push!(result, 0x22)  # local_tee opcode
                    # Copy the LEB128 index bytes
                    for k in (i+1):(j-1)
                        push!(result, bytes[k])
                    end
                    i = j  # Skip to the next local_set instruction
                    fixes += 1
                    continue
                end
            end
            # No fix needed — copy the ENTIRE local_set instruction (opcode + LEB128 index)
            for k in i:(j-1)
                push!(result, bytes[k])
            end
            i = j
            continue
        end
        # Skip ALL instructions with LEB128 operands to prevent index bytes
        # from being misinterpreted as opcodes (e.g., index 33 = 0x21 = local_set)
        n_leb = _skip_leb_count(op)
        if n_leb > 0
            push!(result, bytes[i])
            i += 1
            for _ in 1:n_leb
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            continue
        end
        # Handle GC prefix instructions
        if op == 0xFB && i + 1 <= length(bytes)
            push!(result, bytes[i])
            i += 1
            sub_op = bytes[i]
            push!(result, bytes[i])
            i += 1
            n_gc_leb = _skip_gc_leb_count(sub_op)
            for _ in 1:n_gc_leb
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            continue
        end
        # Handle f32.const (4 raw bytes) and f64.const (8 raw bytes)
        if op == 0x43 && i + 4 <= length(bytes)  # f32.const
            for _ in 1:5; push!(result, bytes[i]); i += 1; end
            continue
        end
        if op == 0x44 && i + 8 <= length(bytes)  # f64.const
            for _ in 1:9; push!(result, bytes[i]); i += 1; end
            continue
        end
        push!(result, bytes[i])
        i += 1
    end
    return result
end

# Helper: number of LEB128 operands to skip for a given opcode
function _skip_leb_count(op::UInt8)::Int
    # local.get/set/tee, global.get/set
    (op == 0x20 || op == 0x21 || op == 0x22 || op == 0x23 || op == 0x24) && return 1
    # br, br_if
    (op == 0x0C || op == 0x0D) && return 1
    # call
    op == 0x10 && return 1
    # call_indirect (type_idx, table_idx)
    op == 0x11 && return 2
    # ref.null (heap type)
    op == 0xD0 && return 1
    # ref.func
    op == 0xD2 && return 1
    # block/loop/if (blocktype)
    (op == 0x02 || op == 0x03 || op == 0x04) && return 1
    # i32.const, i64.const (signed LEB128 value)
    (op == 0x41 || op == 0x42) && return 1
    # memory load/store instructions (align + offset)
    (op >= 0x28 && op <= 0x3E) && return 2
    # memory.size, memory.grow
    (op == 0x3F || op == 0x40) && return 1
    return 0
end

# Helper: number of LEB128 operands to skip for a GC prefix sub-opcode
function _skip_gc_leb_count(sub_op::UInt8)::Int
    sub_op == 0x00 && return 1  # struct.new
    sub_op == 0x01 && return 1  # struct.new_default
    (sub_op >= 0x02 && sub_op <= 0x05) && return 2  # struct.get/get_s/get_u/set
    (sub_op == 0x06 || sub_op == 0x07) && return 1  # array.new/new_default
    sub_op == 0x08 && return 2  # array.new_fixed
    (sub_op >= 0x0b && sub_op <= 0x0e) && return 1  # array.get/get_s/get_u/set
    sub_op == 0x0f && return 0  # array.len
    (sub_op >= 0x14 && sub_op <= 0x17) && return 1  # ref.test/cast
    (sub_op == 0x1a || sub_op == 0x1b) && return 0  # extern/any convert
    (sub_op >= 0x1c && sub_op <= 0x1e) && return 0  # i31 ops
    return 0
end

"""
PURE-6022: Fix local_get → local_set/tee with i32↔i64 type mismatch.

When a phi node merges values from branches with different numeric types (e.g., one
branch produces i64, phi local is i32), the codegen emits local_get X → local_set Y
where X has type i64 and Y has type i32 (or vice versa). Insert the appropriate
conversion instruction between them.
"""
function fix_local_get_set_type_mismatch(bytes::Vector{UInt8}, all_types::Vector{WasmValType})::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes) + 64)
    i = 1
    fixes = 0
    while i <= length(bytes)
        op = bytes[i]
        if op == 0x20  # local_get
            # Decode source local index
            j = i + 1
            src_idx = 0; shift = 0
            while j <= length(bytes)
                b = bytes[j]
                src_idx |= (Int(b & 0x7f) << shift)
                shift += 7; j += 1
                (b & 0x80) == 0 && break
            end
            # j is now past the local_get's LEB128 index (start of next instruction)
            # Check if next instruction is local_set (0x21) or local_tee (0x22)
            if j <= length(bytes) && (bytes[j] == 0x21 || bytes[j] == 0x22)
                # Decode destination local index
                k = j + 1
                dst_idx = 0; shift = 0
                while k <= length(bytes)
                    b = bytes[k]
                    dst_idx |= (Int(b & 0x7f) << shift)
                    shift += 7; k += 1
                    (b & 0x80) == 0 && break
                end
                # Look up types (0-indexed local index → 1-indexed array)
                src_arr = src_idx + 1
                dst_arr = dst_idx + 1
                if src_arr >= 1 && src_arr <= length(all_types) && dst_arr >= 1 && dst_arr <= length(all_types)
                    src_type = all_types[src_arr]
                    dst_type = all_types[dst_arr]
                    if src_type === I64 && dst_type === I32
                        # Copy local_get, insert i32_wrap_i64, then copy local_set/tee
                        for bi in i:j-1; push!(result, bytes[bi]); end
                        push!(result, 0xA7)  # i32_wrap_i64
                        for bi in j:k-1; push!(result, bytes[bi]); end
                        fixes += 1; i = k; continue
                    elseif src_type === I32 && dst_type === I64
                        # Copy local_get, insert i64_extend_i32_s, then copy local_set/tee
                        for bi in i:j-1; push!(result, bytes[bi]); end
                        push!(result, 0xAC)  # i64_extend_i32_s
                        for bi in j:k-1; push!(result, bytes[bi]); end
                        fixes += 1; i = k; continue
                    end
                end
            end
            # No fix applied — copy the full local_get instruction (opcode + LEB128 index)
            for bi in i:(j-1)
                push!(result, bytes[bi])
            end
            i = j
            continue
        end
        # Skip ALL instructions with LEB128 operands to prevent index bytes
        # from being misinterpreted as opcodes
        n_leb = _skip_leb_count(op)
        if n_leb > 0
            push!(result, bytes[i])
            i += 1
            for _ in 1:n_leb
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            continue
        end
        # Handle GC prefix instructions
        if op == 0xFB && i + 1 <= length(bytes)
            push!(result, bytes[i])
            i += 1
            sub_op = bytes[i]
            push!(result, bytes[i])
            i += 1
            n_gc_leb = _skip_gc_leb_count(sub_op)
            for _ in 1:n_gc_leb
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            continue
        end
        # Handle f32.const (4 raw bytes) and f64.const (8 raw bytes)
        if op == 0x43 && i + 4 <= length(bytes)
            for _ in 1:5; push!(result, bytes[i]); i += 1; end
            continue
        end
        if op == 0x44 && i + 8 <= length(bytes)
            for _ in 1:9; push!(result, bytes[i]); i += 1; end
            continue
        end
        push!(result, bytes[i])
        i += 1
    end
    return result
end

function strip_excess_after_function_end(bytes::Vector{UInt8})::Vector{UInt8}
    depth = 0
    i = 1
    while i <= length(bytes)
        op = bytes[i]

        # Track block depth
        if op == 0x02 || op == 0x03 || op == 0x04  # block, loop, if
            depth += 1
            i += 1
            # Skip blocktype (void=0x40, or signed LEB128 type index/value type)
            if i <= length(bytes)
                if bytes[i] == 0x40  # void
                    i += 1
                else
                    # LEB128 blocktype
                    while i <= length(bytes)
                        b = bytes[i]
                        i += 1
                        (b & 0x80) == 0 && break
                    end
                end
            end
            continue
        end

        if op == 0x05  # else — doesn't change depth
            i += 1
            continue
        end

        if op == 0x0B  # end
            if depth == 0
                # This is the function body's closing `end`.
                # Truncate everything after this byte.
                if i < length(bytes)
                    return bytes[1:i]
                end
                return bytes
            end
            depth -= 1
            i += 1
            continue
        end

        # Skip GC prefix instructions with LEB128 params
        if op == 0xFB && i + 1 <= length(bytes)
            i += 1  # GC prefix
            sub_op = bytes[i]
            i += 1
            n_leb = if sub_op == 0x00; 1
                    elseif sub_op == 0x01; 1
                    elseif sub_op in (0x02, 0x03, 0x04, 0x05); 2
                    elseif sub_op in (0x06, 0x07); 1
                    elseif sub_op == 0x08; 2
                    elseif sub_op in (0x0b, 0x0c, 0x0d, 0x0e); 1
                    elseif sub_op == 0x0f; 0
                    elseif sub_op in (0x14, 0x15, 0x16, 0x17); 1
                    elseif sub_op in (0x1a, 0x1b); 0
                    elseif sub_op in (0x1c, 0x1d, 0x1e); 0
                    else 0
                    end
            for _ in 1:n_leb
                while i <= length(bytes)
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
            continue
        end

        # Skip f32.const (4 raw bytes) and f64.const (8 raw bytes)
        if op == 0x43 && i + 4 <= length(bytes)
            i += 5; continue
        end
        if op == 0x44 && i + 8 <= length(bytes)
            i += 9; continue
        end

        # Skip instructions with LEB128 operands
        n_skip = if op == 0x20 || op == 0x21 || op == 0x22; 1      # local.get/set/tee
                 elseif op == 0x23 || op == 0x24; 1                  # global.get/set
                 elseif op == 0x0C || op == 0x0D; 1                  # br, br_if
                 elseif op == 0x10; 1                                # call
                 elseif op == 0x11; 2                                # call_indirect
                 elseif op == 0xD0; 1                                # ref.null
                 elseif op == 0xD2; 1                                # ref.func
                 elseif op == 0x41 || op == 0x42; 1                  # i32.const, i64.const
                 elseif op >= 0x28 && op <= 0x3E; 2                  # memory load/store
                 elseif op == 0x3F || op == 0x40; 1                  # memory.size/grow
                 else 0
                 end
        if n_skip > 0
            i += 1  # Skip opcode
            for _ in 1:n_skip
                while i <= length(bytes)
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
            continue
        end

        # All other instructions: single byte (no operands)
        i += 1
    end
    return bytes  # No excess found
end

"""
PURE-036y: Scan bytecode for broken SELECT (0x1b) instructions that don't have
proper operands. The broken pattern is:
  [... local.get, struct.new, select ...] where there's no condition pushed.

For each broken SELECT found, remove the preceding struct.new and the SELECT,
leaving only the first value (which becomes the result).
"""
function fix_broken_select_instructions(bytes::Vector{UInt8})::Vector{UInt8}
    result = UInt8[]
    i = 1
    fixes = 0

    while i <= length(bytes)
        # Look for SELECT opcode (0x1b)
        if bytes[i] == 0x1b  # SELECT
            # Check if the preceding bytes match the broken pattern:
            # [...] local.get LEB128 struct.new LEB128 select
            #
            # We need to scan backwards to find:
            # 1. struct.new (0xfb 0x00 LEB128_type_idx) just before the select
            # 2. local.get (0x20 LEB128_local_idx) just before the struct.new
            #
            # If we find this pattern and nothing between them (no condition),
            # it's a broken SELECT.

            result_len = length(result)

            # Try to match struct.new pattern at end of result
            # struct.new encoding: 0xfb 0x00 LEB128_type_idx
            struct_new_pos = 0
            struct_new_len = 0

            # Scan backwards for GC_PREFIX (0xfb) followed by STRUCT_NEW (0x00)
            if result_len >= 3
                # Check for struct.new 3 specifically: [0xfb, 0x00, 0x03]
                if result[end-2] == 0xfb && result[end-1] == 0x00
                    # Found struct.new, calculate its length
                    # Type index is LEB128 starting at result[end]
                    # For small indices (< 128), it's just 1 byte
                    struct_new_pos = result_len - 2
                    # Calculate LEB128 length
                    leb_start = result_len
                    while leb_start <= result_len && (result[leb_start] & 0x80) != 0
                        leb_start += 1
                    end
                    struct_new_len = result_len - struct_new_pos + 1

                    # Now check for local.get before struct.new
                    local_get_end = struct_new_pos - 1
                    if local_get_end >= 2
                        # Find local.get (0x20) by scanning backwards
                        # local.get encoding: 0x20 LEB128_local_idx
                        # The LEB128 ends at local_get_end
                        local_get_start = 0

                        # Scan backwards to find 0x20
                        j = local_get_end
                        while j >= 1
                            if result[j] == 0x20
                                # Found potential local.get start
                                # Verify it's a valid LEB128 sequence
                                leb_len = local_get_end - j
                                valid = true
                                for k in (j+1):local_get_end-1
                                    if k <= length(result) && (result[k] & 0x80) == 0
                                        # This byte ends the LEB128 early
                                        valid = false
                                        break
                                    end
                                end
                                if valid && local_get_end <= length(result) && (result[local_get_end] & 0x80) == 0
                                    local_get_start = j
                                    break
                                end
                            end
                            j -= 1
                            if local_get_end - j > 10  # LEB128 can't be more than 10 bytes
                                break
                            end
                        end

                        if local_get_start > 0
                            # Found the pattern: local.get + struct.new + select
                            # This is a broken SELECT (no condition between struct.new and select)
                            # Fix: remove struct.new and select, keep local.get
                            resize!(result, local_get_end)
                            fixes += 1
                            i += 1  # Skip the select
                            continue
                        end
                    end
                end
            end
        end

        push!(result, bytes[i])
        i += 1
    end

    if fixes > 0
        @info "PURE-036y: Fixed $fixes broken SELECT instructions"
    end

    return result
end

"""
PURE-6025: Scan bytecode for numeric constants (i32.const, i64.const) stored
directly to ref-typed locals via local.set. Replace with ref.null of the
appropriate type.

Pattern detected: [i32_const LEB128_value] [local_set LEB128_idx]
where local idx is ref-typed (ConcreteRef, StructRef, ArrayRef, AnyRef, ExternRef).

This catches cases where Julia type inference says a value is a ref type
(e.g., Union{ConcreteRef, UInt8} → ConcreteRef) but the actual compiled value
is a numeric constant (e.g., ExternRef=0x6f=111 compiled as i32_const 111).
"""
function fix_numeric_to_ref_local_stores(bytes::Vector{UInt8}, locals::Vector{WasmValType}, n_params::Int)::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes))
    fixes = 0
    i = 1

    # Track whether we're inside a GC prefix instruction's parameters
    # to avoid matching type index bytes (e.g., struct.get 65 0 = [0xFB,0x02,0x41,0x00]
    # where 0x41 is the type index, not i32.const).
    while i <= length(bytes)
        op = bytes[i]

        # Skip GC prefix instructions — their parameters contain LEB128 values
        # that can coincidentally match i32.const (0x41) or local_set (0x21).
        if op == Opcode.GC_PREFIX && i + 1 <= length(bytes)
            push!(result, bytes[i])
            i += 1
            sub_op = bytes[i]
            push!(result, bytes[i])
            i += 1
            # Skip LEB128 parameters based on sub-opcode
            # struct.new (0x00): 1 LEB128 (type_idx)
            # struct.get (0x02), struct.get_s (0x03), struct.get_u (0x04): 2 LEB128 (type_idx, field_idx)
            # struct.set (0x05): 2 LEB128 (type_idx, field_idx)
            # array.new (0x06), array.new_default (0x07): 1 LEB128 (type_idx)
            # array.get (0x0b), array.get_s (0x0c), array.get_u (0x0d): 1 LEB128 (type_idx)
            # array.set (0x0e): 1 LEB128 (type_idx)
            # array.len (0x0f): 0 LEB128
            # array.new_fixed (0x08): 2 LEB128 (type_idx, count)
            # ref.cast (0x17), ref.cast_nullable (0x17): 1 LEB128 (type_idx) — actually htf byte
            # ref.test (0x14/0x15): 1 htf byte
            # extern_convert_any (0x1b), any_convert_extern (0x1a): 0 params
            # i31.new/get (0x1c/0x1d/0x1e): 0 params
            n_leb = if sub_op == 0x00; 1       # struct.new
                    elseif sub_op == 0x01; 1   # struct.new_default
                    elseif sub_op in (0x02, 0x03, 0x04, 0x05); 2  # struct.get/set
                    elseif sub_op in (0x06, 0x07); 1  # array.new
                    elseif sub_op == 0x08; 2   # array.new_fixed
                    elseif sub_op in (0x0b, 0x0c, 0x0d, 0x0e); 1  # array.get/set
                    elseif sub_op == 0x0f; 0   # array.len
                    elseif sub_op in (0x14, 0x15, 0x16, 0x17); 1  # ref.test/cast
                    elseif sub_op in (0x1a, 0x1b); 0  # extern/any convert
                    elseif sub_op in (0x1c, 0x1d, 0x1e); 0  # i31 ops
                    else 0  # Unknown — don't skip, safer to not match
                    end
            for _ in 1:n_leb
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            # PURE-6025: After struct_new/array_new_fixed (which pushes a ref type),
            # check if next instruction is a numeric opcode (0x80-0xC4, e.g., i32_wrap_i64).
            # This is NEVER valid (ref type can't be treated as i64/i32) and happens in
            # dead code after unreachable where the compiler emits both struct construction
            # and a dead boxing path. Emit DROP + UNREACHABLE to consume the ref value and
            # make the stack polymorphic (all subsequent dead code instructions become valid).
            if (sub_op == 0x00 || sub_op == 0x08) && i <= length(bytes)
                next_byte = bytes[i]
                if next_byte >= 0x80 && next_byte <= 0xC4
                    push!(result, UInt8(0x1A))  # DROP — consume the struct ref
                    push!(result, UInt8(0x00))  # UNREACHABLE — polymorphic stack
                    i += 1  # Skip the numeric opcode
                    fixes += 1
                end
            end
            continue
        end

        # Skip f32.const (4 raw bytes) and f64.const (8 raw bytes)
        if op == Opcode.F32_CONST && i + 4 <= length(bytes)
            for _ in 1:5; push!(result, bytes[i]); i += 1; end
            continue
        end
        if op == Opcode.F64_CONST && i + 8 <= length(bytes)
            for _ in 1:9; push!(result, bytes[i]); i += 1; end
            continue
        end

        # PURE-6022: Skip operands for ALL instructions with LEB128 parameters.
        # Without this, operand bytes (e.g., local_set's index = 0x41) are treated
        # as opcodes in the next iteration, causing the parser to get out of sync
        # and corrupting constant array data (4096-element lookup tables).
        _n_leb_skip = if op == 0x20 || op == 0x21 || op == 0x22; 1  # local.get/set/tee
                      elseif op == 0x23 || op == 0x24; 1             # global.get/set
                      elseif op == 0x0C || op == 0x0D; 1             # br, br_if
                      elseif op == 0x10; 1                           # call
                      elseif op == 0x11; 2                           # call_indirect (type, table)
                      elseif op == 0xD0; 1                           # ref.null (heap type)
                      elseif op == 0xD2; 1                           # ref.func
                      elseif op == 0x02 || op == 0x03 || op == 0x04  # block/loop/if
                          1                                           # blocktype (1 byte or LEB128 type index)
                      elseif op >= 0x28 && op <= 0x3E; 2             # memory load/store (align, offset)
                      elseif op == 0x3F || op == 0x40; 1             # memory.size/grow
                      else 0
                      end
        if _n_leb_skip > 0
            push!(result, bytes[i])
            i += 1
            for _ in 1:_n_leb_skip
                while i <= length(bytes)
                    push!(result, bytes[i])
                    if (bytes[i] & 0x80) == 0
                        i += 1
                        break
                    end
                    i += 1
                end
            end
            continue
        end

        # Now check for i32.const / i64.const → local_set to ref-typed local
        if (op == Opcode.I32_CONST || op == Opcode.I64_CONST) && i + 1 <= length(bytes)
            # Decode the signed LEB128 value (skip over it to find the next instruction)
            j = i + 1
            while j <= length(bytes) && (bytes[j] & 0x80) != 0
                j += 1
            end
            matched = false
            if j <= length(bytes)
                j += 1  # Past the terminal LEB128 byte
                # Check if next instruction is local_set (0x21)
                if j <= length(bytes) && bytes[j] == Opcode.LOCAL_SET
                    # Decode the local index (unsigned LEB128)
                    k = j + 1
                    local_idx = 0
                    shift = 0
                    while k <= length(bytes)
                        b = bytes[k]
                        local_idx |= (Int(b & 0x7f) << shift)
                        shift += 7
                        k += 1
                        if (b & 0x80) == 0
                            break
                        end
                    end
                    # Check if this local is ref-typed
                    local_array_idx = local_idx - n_params + 1
                    if local_array_idx >= 1 && local_array_idx <= length(locals)
                        local_type = locals[local_array_idx]
                        if local_type isa ConcreteRef
                            # Replace i32_const VALUE with ref_null TYPE
                            push!(result, Opcode.REF_NULL)
                            append!(result, encode_leb128_signed(Int64(local_type.type_idx)))
                            # Keep the local_set instruction as-is
                            for bi in j:k-1
                                push!(result, bytes[bi])
                            end
                            fixes += 1
                            i = k
                            matched = true
                        elseif local_type === StructRef || local_type === ArrayRef || local_type === AnyRef || local_type === ExternRef
                            # Replace with ref_null of abstract type
                            push!(result, Opcode.REF_NULL)
                            push!(result, UInt8(local_type))
                            for bi in j:k-1
                                push!(result, bytes[bi])
                            end
                            fixes += 1
                            i = k
                            matched = true
                        end
                    end
                end
            end
            if matched
                continue
            end
            # PURE-6022: Pattern didn't match — still need to properly skip the LEB128
            # value operand. Without this, value bytes (e.g., 0x20=local.get, 0x21=local.set)
            # are misinterpreted as opcodes, causing the parser to get out of sync and
            # corrupting constant array data (4096-element lookup tables).
            push!(result, bytes[i])
            i += 1
            while i <= length(bytes)
                push!(result, bytes[i])
                if (bytes[i] & 0x80) == 0
                    i += 1
                    break
                end
                i += 1
            end
            continue
        end

        push!(result, bytes[i])
        i += 1
    end

    return result
end

"""
Represents a basic block in the IR.
"""
struct BasicBlock
    start_idx::Int
    end_idx::Int
    terminator::Any  # GotoIfNot, GotoNode, or ReturnNode
end

"""
Represents a try/catch region in the IR.
"""
struct TryRegion
    enter_idx::Int      # SSA index of Core.EnterNode
    catch_dest::Int     # SSA index where catch block starts
    leave_idx::Int      # SSA index of :leave expression (end of try body)
end

"""
Find try/catch regions by scanning for Core.EnterNode statements.
Returns a list of TryRegion structs.
"""
function find_try_regions(code)::Vector{TryRegion}
    regions = TryRegion[]

    for (i, stmt) in enumerate(code)
        if stmt isa Core.EnterNode
            catch_dest = stmt.catch_dest
            # Find the corresponding :leave that references this EnterNode
            leave_idx = 0
            for (j, s) in enumerate(code)
                if s isa Expr && s.head === :leave
                    # :leave args contain references to EnterNode SSA values
                    for arg in s.args
                        if arg isa Core.SSAValue && arg.id == i
                            leave_idx = j
                            break
                        end
                    end
                    if leave_idx > 0
                        break
                    end
                end
            end

            if leave_idx > 0
                push!(regions, TryRegion(i, catch_dest, leave_idx))
            end
        end
    end

    return regions
end

"""
Check if code contains try/catch regions.
"""
function has_try_catch(code)::Bool
    for stmt in code
        if stmt isa Core.EnterNode
            return true
        end
    end
    return false
end

"""
Analyze the IR to find basic block boundaries.
A new block starts after each terminator AND at each jump target.
"""
function analyze_blocks(code)
    # First, collect all jump targets
    jump_targets = Set{Int}()
    for stmt in code
        if stmt isa Core.GotoNode
            push!(jump_targets, stmt.label)
        elseif stmt isa Core.GotoIfNot
            push!(jump_targets, stmt.dest)
        end
    end

    blocks = BasicBlock[]
    block_start = 1

    for i in 1:length(code)
        stmt = code[i]

        # Check if NEXT statement is a jump target (start new block after this one)
        is_terminator = stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.ReturnNode
        next_is_jump_target = (i + 1) in jump_targets

        if is_terminator
            push!(blocks, BasicBlock(block_start, i, stmt))
            block_start = i + 1
        elseif next_is_jump_target && i >= block_start
            # Current statement is NOT a terminator but next statement IS a jump target
            # Close current block with no terminator (fallthrough)
            push!(blocks, BasicBlock(block_start, i, nothing))
            block_start = i + 1
        end
    end

    # Handle trailing code without explicit terminator
    if block_start <= length(code)
        push!(blocks, BasicBlock(block_start, length(code), nothing))
    end

    return blocks
end

"""
Check if this code contains a loop (has backward jumps).
"""
function has_loop(ctx::CompilationContext)
    return !isempty(ctx.loop_headers)
end

"""
Check if there's a conditional BEFORE the first loop that jumps PAST the first loop.
This pattern requires special handling (generate_complex_flow instead of generate_loop_code).
Example: if/else where each branch has its own loop (like float_to_string).
"""
function has_branch_past_first_loop(ctx::CompilationContext, code)
    if isempty(ctx.loop_headers)
        return false
    end

    # Find first loop header and its back-edge
    first_header = minimum(ctx.loop_headers)
    back_edge_idx = nothing
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode && stmt.label == first_header
            back_edge_idx = i
            break
        end
    end
    if back_edge_idx === nothing
        return false
    end

    # Check for conditionals BEFORE the first loop that jump PAST its back-edge
    for i in 1:(first_header - 1)
        stmt = code[i]
        if stmt isa Core.GotoIfNot
            target = stmt.dest
            if target > back_edge_idx
                # This conditional jumps past the first loop - complex pattern
                return true
            end
        end
    end

    return false
end

"""
Find merge points - targets of multiple forward jumps.
These are blocks that need WASM block/br structure for proper control flow.
Returns a Dict mapping target index to list of source indices.
"""
function find_merge_points(code)
    # Track all forward jump targets
    forward_targets = Dict{Int, Vector{Int}}()

    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode
            target = stmt.label
            if target > i  # Forward jump
                if !haskey(forward_targets, target)
                    forward_targets[target] = Int[]
                end
                push!(forward_targets[target], i)
            end
        elseif stmt isa Core.GotoIfNot
            target = stmt.dest
            if target > i  # Forward jump (the false branch)
                if !haskey(forward_targets, target)
                    forward_targets[target] = Int[]
                end
                push!(forward_targets[target], i)
            end
        end
    end

    # Merge points are targets with multiple sources
    merge_points = Dict{Int, Vector{Int}}()
    for (target, sources) in forward_targets
        if length(sources) >= 2
            merge_points[target] = sources
        end
    end

    return merge_points
end

"""
Check if the control flow has || or && patterns (merge points from short-circuit evaluation).
"""
function has_short_circuit_patterns(code)
    merge_points = find_merge_points(code)
    return !isempty(merge_points)
end

"""
Generate code for try/catch blocks using WASM exception handling (try_table).

Following dart2wasm's approach:
- Use a single exception tag for all Julia exceptions
- try_table with catch_all to handle any exception
- Catch handler gets exception value (if any)

WASM structure:
  (block \$after_try          ; exit point for try success
    (block \$catch_handler    ; catch handler block
      (try_table (catch_all 0) ; branch to \$catch_handler on exception
        ;; try body code
        (br 1)                 ; normal exit (skip catch)
      )
    )
    ;; catch handler code
  )
  ;; code after try/catch
"""
# PURE-1102: Ensure module has exception tag 0 for Julia exceptions (idempotent)
function ensure_exception_tag!(mod::WasmModule)
    if isempty(mod.tags)
        void_ft = FuncType(WasmValType[], WasmValType[])
        void_type_idx = add_type!(mod, void_ft)
        add_tag!(mod, void_type_idx)
    end
end

"""
PURE-6024: Generate try/catch code using generate_stackified_flow for the try body.
Used when the try body has complex control flow (phi nodes, nested conditionals).
The simple linear approach in generate_try_catch can't handle phi locals or nested
GotoIfNot, causing null pointer dereferences from uninitialized phi locals.

Structure:
  block \$catch_landing (void)          ; catch_all jumps here
    try_table (catch_all 0) (void)     ; catch clause routes to label 0
      ; generate_stackified_flow for all blocks before catch handler
      ; (handles phi nodes, nested control flow, all returns)
    end
  end
  ; catch handler code (pop_exception skipped, returns -1 or similar)
"""
function generate_try_catch_stackified(ctx::CompilationContext, blocks::Vector{BasicBlock}, code, region::TryRegion)::Vector{UInt8}
    bytes = UInt8[]
    catch_dest = region.catch_dest

    # Catch landing block (void) — catch_all branches here
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)  # void

    # try_table with catch_all → label 0 (catch_landing block)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)  # void block type
    append!(bytes, encode_leb128_unsigned(1))    # 1 catch clause
    push!(bytes, Opcode.CATCH_ALL)               # catch_all type
    append!(bytes, encode_leb128_unsigned(0))    # label index 0

    # Extract blocks before catch handler — includes try body + normal return path
    try_body_blocks = [b for b in blocks if b.start_idx < catch_dest]

    # Use generate_stackified_flow for proper control flow:
    # - phi locals set at every edge (GotoNode, GotoIfNot, fall-through)
    # - nested GotoIfNot properly generates if/else or br_if
    # - returns use RETURN opcode (exits function from within try_table)
    append!(bytes, generate_stackified_flow(ctx, try_body_blocks, code))

    # End try_table
    push!(bytes, Opcode.END)

    # End catch_landing block
    push!(bytes, Opcode.END)

    # Catch handler (from catch_dest to end of code)
    for i in catch_dest:length(code)
        stmt = code[i]
        if stmt !== nothing
            # Skip pop_exception — it's a runtime marker, no WASM equivalent
            if stmt isa Expr && stmt.head === :pop_exception
                continue
            end
            append!(bytes, compile_statement(stmt, i, ctx))
        end
    end

    return bytes
end

function generate_try_catch(ctx::CompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    bytes = UInt8[]
    regions = find_try_regions(code)

    if isempty(regions)
        # No try regions, fall back to normal generation
        return generate_complex_flow(ctx, blocks, code)
    end

    # Ensure module has an exception tag for Julia exceptions
    ensure_exception_tag!(ctx.mod)

    # For now, handle single try/catch region
    region = regions[1]
    enter_idx = region.enter_idx
    catch_dest = region.catch_dest
    leave_idx = region.leave_idx

    # PURE-6024: If try body has phi nodes (complex control flow with merge points),
    # delegate to generate_stackified_flow which properly handles phi locals,
    # nested GotoIfNot, and GotoNode. The simple linear approach below can only
    # handle one level of GotoIfNot and doesn't set phi locals at edges.
    has_phi = false
    for i in (enter_idx+1):(catch_dest-1)
        if i <= length(code) && code[i] isa Core.PhiNode
            has_phi = true
            break
        end
    end
    if has_phi
        return generate_try_catch_stackified(ctx, blocks, code, region)
    end

    # Determine result type for the function
    result_type_byte = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)

    # Structure:
    # (block $after_try [result_type]      ; outer block - exit for both paths
    #   (block $catch_block                 ; catch jumps here
    #     (try_table (catch_all 0)          ; try body, catch_all jumps to label 0 ($catch_block)
    #       ;; code before EnterNode
    #       ;; try body (enter_idx+1 to leave_idx-1)
    #       ;; normal path after :leave until catch_dest-1
    #       (br 1)                          ; skip catch, go to $after_try
    #     )
    #   )
    #   ;; catch handler (catch_dest to end of catch)
    # )

    # Outer block for the result value
    push!(bytes, Opcode.BLOCK)
    append!(bytes, encode_block_type(result_type_byte))

    # Inner void block for catch destination
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)  # void result type

    # try_table with catch_all clause
    # Format: try_table blocktype vec(catch) end
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)  # void block type (no result from try_table itself)

    # Catch clauses: catch_all 0 (branch to label 0 on any exception)
    append!(bytes, encode_leb128_unsigned(1))  # 1 catch clause
    push!(bytes, Opcode.CATCH_ALL)             # catch_all type
    append!(bytes, encode_leb128_unsigned(0))  # label index 0 (inner block)

    # Generate code BEFORE EnterNode
    for i in 1:(enter_idx-1)
        stmt = code[i]
        if stmt !== nothing && !(stmt isa Core.EnterNode)
            append!(bytes, compile_statement(stmt, i, ctx))
        end
    end

    # Generate try body (from EnterNode+1 to leave_idx-1)
    # Need to handle control flow (GotoIfNot) properly
    i = enter_idx + 1
    while i <= leave_idx - 1
        stmt = code[i]
        if stmt === nothing
            i += 1
            continue
        end

        # Handle GotoIfNot (if statement) inside try body
        if stmt isa Core.GotoIfNot
            # This is an if statement in the try body
            # The then-branch is from i+1 to dest-1
            # The else-branch starts at dest
            goto_if_not = stmt
            else_target = goto_if_not.dest

            # Compile the condition value
            append!(bytes, compile_condition_to_i32(goto_if_not.cond, ctx))

            # Check if then-branch has a return or throw (void if) vs needs else
            then_start = i + 1
            then_end = min(else_target - 1, leave_idx - 1)
            then_has_return = false
            then_has_throw = false

            for j in then_start:then_end
                if code[j] isa Core.ReturnNode
                    then_has_return = true
                    break
                elseif code[j] isa Expr && code[j].head === :call
                    func = code[j].args[1]
                    if func isa GlobalRef && func.name === :throw
                        then_has_throw = true
                        break
                    end
                end
            end

            if then_has_throw || then_has_return
                # Then branch ends with throw/return, no else branch needed
                # Use: (if (then ...))
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void result type

                # Generate then branch
                for j in then_start:then_end
                    if code[j] !== nothing
                        append!(bytes, compile_statement(code[j], j, ctx))
                    end
                end

                push!(bytes, Opcode.END)

                # Skip to else_target (which becomes the continuation)
                i = else_target
            else
                # Normal if-else pattern (rare in try body, but handle it)
                push!(bytes, Opcode.IF)
                push!(bytes, 0x40)  # void result type

                for j in then_start:then_end
                    if code[j] !== nothing
                        append!(bytes, compile_statement(code[j], j, ctx))
                    end
                end

                push!(bytes, Opcode.ELSE)

                # Else branch from else_target to leave_idx-1
                for j in else_target:(leave_idx-1)
                    if code[j] !== nothing
                        append!(bytes, compile_statement(code[j], j, ctx))
                    end
                end

                push!(bytes, Opcode.END)

                # We've processed everything up to leave_idx
                i = leave_idx
            end
        else
            append!(bytes, compile_statement(stmt, i, ctx))
            i += 1
        end
    end

    # Skip the :leave itself (it's a control flow marker)

    # Generate normal path code after :leave until catch_dest
    for i in (leave_idx+1):(catch_dest-1)
        stmt = code[i]
        if stmt !== nothing
            # Check if this is a return - if so, we need to handle it specially
            if stmt isa Core.ReturnNode
                append!(bytes, compile_statement(stmt, i, ctx))
                # After return in try, branch out
                push!(bytes, Opcode.BR)
                append!(bytes, encode_leb128_unsigned(1))  # branch to outer block
                break
            else
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end
    end

    # If no return in try body, branch past catch
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(1))  # branch to outer block (past catch)

    # End try_table
    push!(bytes, Opcode.END)

    # End inner (catch destination) block
    push!(bytes, Opcode.END)

    # Catch handler code (from catch_dest to end)
    for i in catch_dest:length(code)
        stmt = code[i]
        if stmt !== nothing
            # Skip :pop_exception - it's just a marker
            if stmt isa Expr && stmt.head === :pop_exception
                continue
            end
            append!(bytes, compile_statement(stmt, i, ctx))
        end
    end

    # End outer block - don't add END here, generate_structured will add it
    # Actually wait, we need to end the outer block but the END is added by generate_structured
    # Let me check... generate_structured adds one END at the end of the function

    # Actually we DO need to end the outer block here
    push!(bytes, Opcode.END)

    return bytes
end

