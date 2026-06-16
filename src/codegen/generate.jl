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
function validate_emitted_bytes!(ctx::AbstractCompilationContext, bytes::Vector{UInt8}, stmt_idx::Int)
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
function _get_local_type(ctx::AbstractCompilationContext, local_idx::Int)::Union{WasmValType, Nothing}
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
function generate_body(ctx::AbstractCompilationContext)::Vector{UInt8}
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
    # Forward-parse to find genuine instruction boundaries: raw backward byte checks
    # misfire when a LEB immediate collides with an opcode — e.g. `local.get 1418`
    # encodes as [0x20, 0x8a, 0x0b] and the trailing 0x0b reads as END, turning
    # [local.get N][return][unreachable][end] into a false Pattern-1 match that
    # rewrites a LIVE return to unreachable (gap 4c8236022172).
    if length(bytes) >= 4 && bytes[end] == Opcode.END
        _tail = _last_instr_starts(bytes, 4)
        if length(_tail) == 4
            _t1, _t2, _t3, _t4 = bytes[_tail[1]], bytes[_tail[2]], bytes[_tail[3]], bytes[_tail[4]]
            if _t1 == Opcode.END && _t2 == Opcode.RETURN && _t3 == Opcode.UNREACHABLE && _t4 == Opcode.END
                bytes[_tail[2]] = Opcode.UNREACHABLE  # Pattern 1: dead RETURN after END
            elseif _t1 == Opcode.RETURN && _t2 == Opcode.END && _t3 == Opcode.RETURN && _t4 == Opcode.END
                bytes[_tail[3]] = Opcode.UNREACHABLE  # Pattern 2: dead final RETURN
            end
        end
    end

    # WBUILD-1011: Disabled fix_consecutive_local_sets — it blindly converts adjacent
    # local.set X; local.set Y to local.tee X; local.set Y, assuming both receive the
    # same stack value. This is wrong when two DIFFERENT values are being popped (e.g.,
    # Int128 emitters popping two struct refs). Phi locals are now handled by
    # emit_phi_local_set! which independently pushes values before each LOCAL_SET.

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

    # PURE-414: Check validator for errors after function body generation.
    # Downgraded to @debug: the validator observes raw pre-fix emitted opcodes,
    # but the fix_* passes above (lines 213-230) repair the byte stream before
    # it leaves this function. wasm-tools validate / wasm-opt are the source of
    # truth; these collected errors are a developer diagnostic only.
    if has_errors(ctx.validator)
        @debug "Stack validator found $(length(ctx.validator.errors)) issue(s) in $(ctx.validator.func_name)" errors=ctx.validator.errors
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
    # Forward-parse INSTRUCTION boundaries (5th instance of the backward/raw
    # byte-scan class): the raw 3-byte match also fired when [0xFB 0x0F] was
    # the LEB immediate of another instruction — e.g. `local.get 2043` encodes
    # as [0x20 0xFB 0x0F] in bodies with >1947 locals — deleting a LIVE
    # i32.wrap_i64 after it and desyncing every later validation/decode
    # (the E-003 island's fn#107 `i64.mul[0] expected i64, found ref`).
    result = UInt8[]
    sizehint!(result, length(bytes))
    i = 1
    fixes = 0
    n = length(bytes)
    while i <= n
        j = _instr_next(bytes, i)
        j == 0 && (append!(result, @view bytes[i:n]); break)  # truncated tail: copy verbatim
        # a GENUINE array.len is exactly the two bytes [0xFB 0x0F]
        if j - i == 2 && bytes[i] == 0xFB && bytes[i + 1] == 0x0F &&
           j <= n && bytes[j] == 0xA7
            push!(result, 0xFB, 0x0F)
            i = j + 1   # skip the spurious i32.wrap_i64 — array.len returns i32
            fixes += 1
            continue
        end
        append!(result, @view bytes[i:(j - 1)])
        i = j
    end
    if fixes > 0
        @debug "fix_array_len_wrap: removed $fixes spurious i32_wrap_i64 after array_len"
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
                # P2-batch24 (gap 3bcded846d6e): the old table mis-counted several
                # GC immediates — array.len (0x0F) has NONE but was counted as 1,
                # so the parser ate the next instruction's bytes, desynced, and a
                # later byte landing in the 0x45-0x78 range made this pass strip a
                # LEGITIMATE i32_wrap_i64 (memorynew's size wrap → "expected i32,
                # found i64"). Immediate counts per the WasmGC spec:
                #   2 LEBs: struct.get/_s/_u/set (type+field), array.new_fixed/
                #           _data/_elem, array.copy, array.init_data/_elem
                #   1 LEB:  struct.new/_default, array.new/_default, array.get
                #           family, array.set, array.fill, ref.test/cast (±null)
                #   0:      array.len, any/extern convert, ref.i31, i31.get_s/u
                # (br_on_cast 0x18/0x19 would need flags+3 LEBs — never emitted.)
                n_lebs = (sub in (0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0A, 0x11, 0x12, 0x13)) ? 2 :
                         (sub in (0x00, 0x01, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x10, 0x14, 0x15, 0x16, 0x17)) ? 1 :
                         0  # 0x0F array.len, 0x1A/0x1B converts, 0x1C-0x1E i31 ops
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
        elseif op == 0x1C  # select_t: count:LEB then `count` valtypes (1 byte, or 0x63/0x64 + heaptype LEB)
            # Skip the whole instruction. Without this the scanner walks INTO the
            # type operands: a (ref null $T) operand is 0x63 + LEB, and that LEB's
            # first byte is 0xA7 for type index 167 (=i32.wrap_i64's opcode), which
            # this pass then strips as a "spurious wrap" — corrupting the select's
            # result type (ref null 167 → ref null 1, "type mismatch: expected
            # (ref null $A), found (ref null $B)" in reactive figure islands).
            last_opcode = 0x00
            i += 1
            cnt = 0; sh = 0
            while i <= length(bytes)
                b = bytes[i]; push!(result, b); i += 1
                cnt |= Int(b & 0x7f) << sh
                (b & 0x80) == 0 && break
                sh += 7
            end
            for _ in 1:cnt
                i <= length(bytes) || break
                vt = bytes[i]; push!(result, vt); i += 1
                if vt == 0x63 || vt == 0x64  # (ref null ht)/(ref ht): heaptype LEB follows
                    while i <= length(bytes)
                        push!(result, bytes[i])
                        done = (bytes[i] & 0x80) == 0
                        i += 1
                        done && break
                    end
                end
            end
        elseif op == 0x02 || op == 0x03 || op == 0x04  # block/loop/if — blocktype
            last_opcode = op
            i += 1
            if i <= length(bytes)
                bt = bytes[i]; push!(result, bt); i += 1
                # ref-typed blocktypes ((ref null ht)/(ref ht)) carry a heaptype LEB
                # beyond the first byte; skipping only 1 byte desyncs the scanner.
                if bt == 0x63 || bt == 0x64
                    while i <= length(bytes)
                        push!(result, bytes[i])
                        done = (bytes[i] & 0x80) == 0
                        i += 1
                        done && break
                    end
                end
            end
        else
            # Single-byte instruction (no operands): comparisons, arithmetic, drops, etc.
            last_opcode = op
            i += 1
        end
    end
    if fixes > 0
        @debug "fix_i32_wrap_after_i32_ops: removed $fixes spurious i32_wrap_i64 after i32-producing ops"
    end
    return result
end

"""
PURE-6027: Insert i32_wrap_i64 when an i64-typed value feeds into i32 binary operations.

Patterns handled:
1. local_get <idx> (i64 local), i32_const, i32_binary_op → wrap after local_get
2. local_get <idx> (i64 local), directly i32_binary_op → wrap after local_get
3. i64_const <value>, i32_binary_op → wrap after i64_const
4. local_get <idx> (i64 local), local_get <any>, i32_binary_op → wrap after first local_get

This happens when the codegen determines is_32bit=true from Julia type inference but the actual
value is i64 (e.g., phi nodes allocated as i64, or Int64 literal constants in invoke arithmetic
where is_32bit is determined from the first arg but the second arg is an Int64 literal).
Fix: insert i32_wrap_i64 (0xa7) after the i64 value.
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
                j = i
                if j <= length(bytes) && bytes[j] == 0x41  # i32_const
                    # Pattern 1: local_get(i64), i32_const, i32_op
                    # Skip i32_const LEB128 operand
                    k = j + 1
                    while k <= length(bytes)
                        (bytes[k] & 0x80) == 0 && break
                        k += 1
                    end
                    k += 1  # past last LEB byte
                    if k <= length(bytes) && bytes[k] >= 0x6a && bytes[k] <= 0x78
                        push!(result, 0xa7)  # i32_wrap_i64
                        fixes += 1
                    end
                elseif j <= length(bytes) && bytes[j] >= 0x6a && bytes[j] <= 0x78
                    # Pattern 2: local_get(i64) directly before i32 binary op
                    push!(result, 0xa7)  # i32_wrap_i64
                    fixes += 1
                elseif j <= length(bytes) && bytes[j] == 0x20  # another local_get
                    # Pattern 4: local_get(i64), local_get(?), i32_op
                    # Skip second local_get + its LEB128 operand
                    k = j + 1
                    while k <= length(bytes)
                        (bytes[k] & 0x80) == 0 && break
                        k += 1
                    end
                    k += 1  # past last LEB byte
                    if k <= length(bytes) && bytes[k] >= 0x6a && bytes[k] <= 0x78
                        push!(result, 0xa7)  # i32_wrap_i64
                        fixes += 1
                    end
                end
            end
        elseif op == 0x42  # i64_const
            # Pattern 3: i64_const <value>, i32_binary_op
            # Copy i64_const opcode and LEB128 value
            push!(result, op)
            i += 1
            while i <= length(bytes)
                b = bytes[i]
                push!(result, b)
                i += 1
                (b & 0x80) == 0 && break
            end
            # Check if next is i32 binary op (0x6a-0x78)
            if i <= length(bytes) && bytes[i] >= 0x6a && bytes[i] <= 0x78
                push!(result, 0xa7)  # i32_wrap_i64
                fixes += 1
            end
        elseif op == 0xfb  # GC prefix — skip sub-opcode + all LEB128 operands
            push!(result, op)
            i += 1
            if i <= length(bytes)
                sub_op = bytes[i]
                push!(result, sub_op)
                i += 1
                # Determine number of LEB128 operands for each GC sub-opcode
                n_leb = if sub_op in (0x00, 0x01, 0x06, 0x07, 0x0b, 0x0c, 0x0d, 0x0e,
                                      0x14, 0x15, 0x16, 0x17)
                    1  # type_idx only
                elseif sub_op in (0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0a)
                    2  # type_idx + field_idx/length/data_idx/elem_idx
                else
                    0  # array.len (0x0f), any.convert_extern (0x1a), extern.convert_any (0x1b), etc.
                end
                for _ in 1:n_leb
                    while i <= length(bytes)
                        b = bytes[i]
                        push!(result, b)
                        i += 1
                        (b & 0x80) == 0 && break
                    end
                end
            end
        elseif op == 0x44  # f64.const — 8 immediate bytes (IEEE 754)
            push!(result, op)
            i += 1
            for _ in 1:8
                if i <= length(bytes)
                    push!(result, bytes[i])
                    i += 1
                end
            end
        elseif op == 0x43  # f32.const — 4 immediate bytes (IEEE 754)
            push!(result, op)
            i += 1
            for _ in 1:4
                if i <= length(bytes)
                    push!(result, bytes[i])
                    i += 1
                end
            end
        elseif op in (0x41, 0x21, 0x22, 0x0c, 0x0d, 0x10, 0x23, 0x24)
            # Instructions with 1 LEB128 operand:
            # 0x41=i32.const, 0x21=local.set, 0x22=local.tee,
            # 0x0c=br, 0x0d=br_if, 0x10=call, 0x23=global.get, 0x24=global.set
            push!(result, op)
            i += 1
            while i <= length(bytes)
                b = bytes[i]
                push!(result, b)
                i += 1
                (b & 0x80) == 0 && break
            end
        else
            push!(result, op)
            i += 1
        end
    end
    if fixes > 0
        @debug "fix_i64_local_in_i32_ops: inserted $fixes i32_wrap_i64 for i64 locals used in i32 ops"
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
function fix_consecutive_local_sets(bytes::Vector{UInt8}; local_types::Union{Nothing, Vector}=nothing, n_params::Int=0)::Vector{UInt8}
    result = UInt8[]
    sizehint!(result, length(bytes))
    i = 1
    fixes = 0
    while i <= length(bytes)
        op = bytes[i]
        if op == 0x21  # local_set
            # Peek past the LEB128 local index to find where next instruction starts
            j = i + 1
            # Decode first local index
            first_idx = 0; shift = 0
            while j <= length(bytes) && (bytes[j] & 0x80) != 0
                first_idx |= (Int(bytes[j] & 0x7f) << shift)
                shift += 7
                j += 1
            end
            if j <= length(bytes)
                first_idx |= (Int(bytes[j] & 0x7f) << shift)
                j += 1  # Past the terminal LEB128 byte — j now points to next instruction
                if j <= length(bytes) && bytes[j] == 0x21  # next is also local_set
                    # Decode second local index to check type compatibility
                    second_idx = 0; shift2 = 0; k2 = j + 1
                    while k2 <= length(bytes) && (bytes[k2] & 0x80) != 0
                        second_idx |= (Int(bytes[k2] & 0x7f) << shift2)
                        shift2 += 7; k2 += 1
                    end
                    if k2 <= length(bytes)
                        second_idx |= (Int(bytes[k2] & 0x7f) << shift2)
                    end
                    # WBUILD-1010: Only convert SET→TEE when both locals have the same
                    # type. When they differ (e.g., i64 vs ref), the two local.set
                    # instructions pop DIFFERENT values from the stack (not the same value
                    # being saved to multiple phi locals).
                    types_match = true
                    if local_types !== nothing
                        arr1 = first_idx - n_params + 1
                        arr2 = second_idx - n_params + 1
                        if arr1 >= 1 && arr1 <= length(local_types) && arr2 >= 1 && arr2 <= length(local_types)
                            types_match = (local_types[arr1] == local_types[arr2])
                        elseif first_idx < n_params && arr2 >= 1 && arr2 <= length(local_types)
                            types_match = false  # comparing param to local — skip
                        elseif arr1 >= 1 && arr1 <= length(local_types) && second_idx < n_params
                            types_match = false
                        end
                    end
                    if types_match
                    # Replace local_set with local_tee (keeps value on stack)
                    push!(result, 0x22)  # local_tee opcode
                    # Copy the LEB128 index bytes
                    for k in (i+1):(j-1)
                        push!(result, bytes[k])
                    end
                    i = j  # Skip to the next local_set instruction
                    fixes += 1
                    continue
                    end  # types_match
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
    # throw (tag index)
    op == 0x08 && return 1
    # br_on_null / br_on_non_null (label)
    (op == 0xD5 || op == 0xD6) && return 1
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
    sub_op == 0x08 && return 2  # array.new_fixed (type, count)
    (sub_op == 0x09 || sub_op == 0x0a) && return 2  # array.new_data/new_elem (type, seg)
    (sub_op >= 0x0b && sub_op <= 0x0e) && return 1  # array.get/get_s/get_u/set
    sub_op == 0x0f && return 0  # array.len
    sub_op == 0x10 && return 1  # array.fill (type)
    (sub_op >= 0x11 && sub_op <= 0x13) && return 2  # array.copy/init_data/init_elem
    (sub_op >= 0x14 && sub_op <= 0x17) && return 1  # ref.test/cast
    (sub_op == 0x1a || sub_op == 0x1b) && return 0  # extern/any convert
    (sub_op >= 0x1c && sub_op <= 0x1e) && return 0  # i31 ops
    return 0
end

"""
Forward-parse an instruction byte buffer and return the start index of the LAST
instruction, or 0 if the buffer is empty / truncated mid-instruction. Backward
scans for "does this buffer end with local.get?" misfire when an immediate byte
collides with an opcode — e.g. `i32.const 32` encodes as [0x41, 0x20] and the
0x20 immediate reads as LOCAL_GET (the titlecase ±32 wrong-value family, where
ASCII case distance is exactly 32). A forward parse from a known instruction
boundary is unambiguous.
"""
function _last_instr_start(bytes::Vector{UInt8})::Int
    i = 1
    n = length(bytes)
    last_start = 0
    while i <= n
        last_start = i
        i = _instr_next(bytes, i)
        i == 0 && return 0
    end
    return last_start
end

"""
Advance past the single instruction starting at index `i`; return the index of
the next instruction, or 0 if the buffer ends mid-instruction.
"""
function _instr_next(bytes::Vector{UInt8}, i::Int)::Int
    n = length(bytes)
    op = bytes[i]
    if op == 0xFB  # GC prefix: sub-opcode + LEB operands
        i + 1 > n && return 0
        sub_op = bytes[i + 1]
        i += 2
        for _ in 1:_skip_gc_leb_count(sub_op)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    elseif op == 0x43  # f32.const: 4 raw payload bytes
        i + 4 > n && return 0
        i += 5
    elseif op == 0x44  # f64.const: 8 raw payload bytes
        i + 8 > n && return 0
        i += 9
    elseif op == 0xFC  # saturating-trunc / misc prefix: sub-opcode LEB
        i += 1
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            (b & 0x80) == 0 && break
        end
    elseif op == 0x0E  # br_table: count N, then N+1 label LEBs
        i += 1
        cnt = 0; shift = 0
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            cnt |= (Int(b & 0x7f) << shift); shift += 7
            (b & 0x80) == 0 && break
        end
        for _ in 1:(cnt + 1)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    elseif op == 0x1F  # try_table: blocktype, count N, then N catch clauses
        i += 1
        i > n && return 0
        # blocktype LEB (single byte for valtypes/void; signed LEB for type idx)
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            (b & 0x80) == 0 && break
        end
        cnt = 0; shift = 0
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            cnt |= (Int(b & 0x7f) << shift); shift += 7
            (b & 0x80) == 0 && break
        end
        for _ in 1:cnt
            i > n && return 0
            kind = bytes[i]; i += 1
            # catch (0x00) / catch_ref (0x01): tag LEB + label LEB;
            # catch_all (0x02) / catch_all_ref (0x03): label LEB only
            nlebs = kind <= 0x01 ? 2 : 1
            for _ in 1:nlebs
                while true
                    i > n && return 0
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
        end
    else
        i += 1
        for _ in 1:_skip_leb_count(op)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    end
    return i
end

"""
Forward-parse an instruction buffer and return the start indices of the last
`k` instructions (oldest first). Returns fewer than `k` entries if the buffer
holds fewer instructions, and an empty vector if it is truncated mid-instruction.
"""
function _last_instr_starts(bytes::Vector{UInt8}, k::Int)::Vector{Int}
    i = 1
    n = length(bytes)
    starts = Int[]
    while i <= n
        push!(starts, i)
        length(starts) > k && popfirst!(starts)
        i = _instr_next(bytes, i)
        i == 0 && return Int[]
    end
    return starts
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
            n_leb = if sub_op == 0x00; 1                          # struct.new
                    elseif sub_op == 0x01; 1                          # struct.new_default
                    elseif sub_op in (0x02, 0x03, 0x04, 0x05); 2     # struct.get/get_s/get_u/set
                    elseif sub_op in (0x06, 0x07); 1                  # array.new/new_default
                    elseif sub_op == 0x08; 2                          # array.new_fixed
                    elseif sub_op in (0x09, 0x0a); 2                  # array.new_data/new_elem
                    elseif sub_op in (0x0b, 0x0c, 0x0d, 0x0e); 1     # array.get/get_s/get_u/set
                    elseif sub_op == 0x0f; 0                          # array.len
                    elseif sub_op == 0x10; 1                          # array.fill
                    elseif sub_op == 0x11; 2                          # array.copy
                    elseif sub_op in (0x12, 0x13); 2                  # array.init_data/init_elem
                    elseif sub_op in (0x14, 0x15, 0x16, 0x17); 1     # ref.test/cast variants
                    elseif sub_op in (0x1a, 0x1b); 0                  # any_convert_extern/extern_convert_any
                    elseif sub_op in (0x1c, 0x1d, 0x1e); 0           # ref.i31/i31.get_s/i31.get_u
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

        # P2-batch12: opcodes with non-trivial immediates the decoder previously
        # treated as single-byte. Mis-skipping makes the scanner read an OPERAND
        # byte as an opcode — an operand byte of 0x0B then looks like the
        # function's closing `end` at depth 0 and TRUNCATES the real tail.
        # select_t's type-index operand was the trigger: type indices shift per
        # module, so the same function validated in one module and lost its last
        # 9 instructions in another (Ryu kernel, gaps 19d59e9a61b3/b72318c9598c).
        _skip_leb() = (while i <= length(bytes); b = bytes[i]; i += 1; (b & 0x80) == 0 && break; end)
        if op == 0x08  # throw: tag index LEB
            i += 1; _skip_leb(); continue
        end
        if op == 0x0E  # br_table: vec(label) + default label
            i += 1
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:(cnt + 1); _skip_leb(); end
            continue
        end
        if op == 0x1C  # select_t: vec(valtype); each valtype is 1 byte, or 0x63/0x64 + heaptype LEB
            i += 1
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:cnt
                i > length(bytes) && break
                vt = bytes[i]; i += 1
                (vt == 0x63 || vt == 0x64) && _skip_leb()  # ref null ht / ref ht
            end
            continue
        end
        if op == 0x1F  # try_table: blocktype + vec(catch clause); OPENS A FRAME
            depth += 1
            i += 1
            if i <= length(bytes)
                if bytes[i] == 0x40
                    i += 1
                else
                    _skip_leb()
                end
            end
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:cnt
                i > length(bytes) && break
                kind = bytes[i]; i += 1
                # 0x00 catch tag+label, 0x01 catch_ref tag+label: 2 LEBs;
                # 0x02 catch_all label, 0x03 catch_all_ref label: 1 LEB
                (kind == 0x00 || kind == 0x01) && _skip_leb()
                _skip_leb()
            end
            continue
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
            elseif catch_dest > i
                # P2-batch4: an always-throwing try body has NO :leave (Julia elides
                # it when the body can't exit normally — e.g. `try div(0,0) catch`).
                # Dropping the region here meant no try_table was emitted at all, so
                # the throw escaped uncaught. Synthesize leave_idx = catch_dest: the
                # try body becomes enter+1 .. catch_dest-1 and every consumer's
                # normal-exit range (leave_idx+1 .. catch_dest-1) is empty, which is
                # exactly right — there is no normal exit.
                push!(regions, TryRegion(i, catch_dest, catch_dest))
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
function has_loop(ctx::AbstractCompilationContext)
    return any(ctx.loop_headers)
end

"""
Check if there's a conditional BEFORE the first loop that jumps PAST the first loop.
This pattern requires special handling (generate_complex_flow instead of generate_loop_code).
Example: if/else where each branch has its own loop (like float_to_string).
"""
function has_branch_past_first_loop(ctx::AbstractCompilationContext, code)
    if !any(ctx.loop_headers)
        return false
    end

    # Find first loop header and its back-edge
    first_header = findfirst(ctx.loop_headers)
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
# PURE-9032: Also ensures the $current_exn global exists for exception value stashing.
function ensure_exception_tag!(mod::WasmModule)
    if isempty(mod.tags)
        void_ft = FuncType(WasmValType[], WasmValType[])
        void_type_idx = add_type!(mod, void_ft)
        add_tag!(mod, void_type_idx)
    end
end

"""
PURE-9032: Ensure module has the \$current_exn global for exception value stashing.
This is a (mut anyref) global initialized to ref.null any.
Returns the global index. Idempotent — scans existing globals to avoid duplicates.
"""
function ensure_exception_global!(mod::WasmModule)::UInt32
    # Check if we already have an anyref mutable global (our exception stash)
    for (i, g) in enumerate(mod.globals)
        if g.valtype === AnyRef && g.mutable_
            return UInt32(i - 1)
        end
    end
    # Create (global (mut anyref) (ref.null any))
    init = UInt8[0xD0, 0x6E, Opcode.END]  # ref.null any + end
    push!(mod.globals, WasmGlobalDef(AnyRef, true, init))
    return UInt32(length(mod.globals) - 1)
end

"""
PURE-9036: Ensure module has stack trace capture infrastructure.
Adds `capture_stack` import (env.capture_stack: () → externref) and
`\$current_stack_trace` global (mut externref). Returns (import_idx, global_idx).
Idempotent — scans existing imports to avoid duplicates.
"""
function ensure_stack_trace_support!(mod::WasmModule)
    # Check if capture_stack import already exists
    import_idx = nothing
    func_count = UInt32(0)
    for imp in mod.imports
        if imp.kind == 0x00  # function import
            if imp.module_name == "env" && imp.field_name == "capture_stack"
                import_idx = func_count
            end
            func_count += 1
        end
    end

    if import_idx === nothing
        import_idx = add_stack_trace_import!(mod)
    end

    global_idx = ensure_stack_trace_global!(mod)
    return (import_idx=import_idx, global_idx=global_idx)
end

"""
PURE-9036: Emit capture_stack() + global.set at a throw site.
Call this before emitting the `throw` instruction to capture the stack trace.
"""
function emit_capture_stack!(bytes::Vector{UInt8}, capture_import_idx::UInt32, trace_global_idx::UInt32)
    push!(bytes, Opcode.CALL)
    append!(bytes, encode_leb128_unsigned(capture_import_idx))
    push!(bytes, Opcode.GLOBAL_SET)
    append!(bytes, encode_leb128_unsigned(trace_global_idx))
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
# P2-batch17: compile a catch-handler region [from..to] honouring GotoIfNot
# (conditional catch arms / exception isa dispatch). The linear per-statement
# loops no-op'd GotoIfNot, so `catch; if x; a; else; b; end` always produced the
# then arm (gap f80bce91645e). Mirrors the PURE-9032 handling from the simple
# no-merge generator.
function _compile_catch_region!(bytes::Vector{UInt8}, ctx::AbstractCompilationContext, code, from::Int, to::Int)
    i = from
    while i <= to
        stmt = code[i]
        if stmt === nothing || (stmt isa Expr && stmt.head === :pop_exception)
            i += 1
            continue
        end
        if stmt isa Core.GotoIfNot
            else_target = stmt.dest
            append!(bytes, compile_condition_to_i32(stmt.cond, ctx))
            then_start = i + 1
            then_end = min(else_target - 1, to)
            then_has_return = any(code[j] isa Core.ReturnNode for j in then_start:then_end)
            push!(bytes, Opcode.IF)
            push!(bytes, 0x40)
            for j in then_start:then_end
                ts = code[j]
                if ts !== nothing && !(ts isa Expr && ts.head === :pop_exception)
                    append!(bytes, compile_statement(ts, j, ctx))
                end
            end
            if then_has_return
                # Then arm exits the function — no else arm needed; continue at dest
                push!(bytes, Opcode.END)
                ctx.last_stmt_was_stub = false
                i = else_target
            else
                push!(bytes, Opcode.ELSE)
                for j in else_target:to
                    es = code[j]
                    if es !== nothing && !(es isa Expr && es.head === :pop_exception)
                        append!(bytes, compile_statement(es, j, ctx))
                    end
                end
                push!(bytes, Opcode.END)
                ctx.last_stmt_was_stub = false
                i = to + 1
            end
        else
            append!(bytes, compile_statement(stmt, i, ctx))
            i += 1
        end
    end
    return bytes
end

function generate_try_catch_stackified(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock}, code, region::TryRegion)::Vector{UInt8}
    bytes = UInt8[]
    catch_dest = region.catch_dest

    # P2-batch16: merge-phi structure (port of PURE-9031 from the simple
    # generator). Without it, a try body that completes NORMALLY fell out of
    # the try_table straight THROUGH the catch handler, overwriting the merge
    # phi with the catch arm's value (`try gcd(Int32(0), x) catch Int32(0)`
    # returned 0 — gap 6d3a1788a329 family). Structure:
    #   block $merge (void)
    #     block $catch_landing (void)
    #       try_table (catch_all 0)  ;; body; normal completion brs to $merge
    #       end
    #     end
    #     ;; catch handler (sets merge phi), falls through to $merge end
    #   end
    #   ;; post-merge code (phi reads, conversions, return)
    # P2-batch19: a MERGE phi must have a try-side edge (< catch_dest). Phis
    # whose edges all originate inside the catch region are INTERNAL to the
    # catch arm (e.g. the inlined `mod(typemin, x)` diamond — gap 93a32c2c9d13)
    # and are handled by the stackified catch compilation below, not by the
    # merge structure.
    merge_start = length(code) + 1
    for i in catch_dest:length(code)
        st = code[i]
        if st isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
           any(Int(e) < catch_dest for e in st.edges)
            merge_start = i
            break
        end
    end
    has_merge = merge_start <= length(code)

    # P2-batch19: pre-try branch that EXITS over the whole try/catch
    # (`if cond; try ... catch ... end else X end`). The else target lies
    # outside the try-body block subset, so the stackifier silently dropped the
    # branch and the condition value corrupted the operand stack (gaps
    # efca694cdd4f / 6cf9be31dafc). Restructure as:
    #   <pre-branch stmts>
    #   block $else: cond eqz br_if; <try/catch structure> end
    #   <post code [dest..]>
    # Only for the return-style shape (no merge phis; the catch arm returns).
    exit_idx = 0
    exit_dest = 0
    if !has_merge
        catch_ret = 0
        for i in catch_dest:length(code)
            if code[i] isa Core.ReturnNode
                catch_ret = i
                break
            end
        end
        if catch_ret > 0
            for i in 1:(region.enter_idx - 1)
                st = code[i]
                if st isa Core.GotoIfNot && st.dest > catch_ret
                    exit_idx = i
                    exit_dest = st.dest
                    break
                end
            end
        end
    end
    has_exit_branch = exit_idx > 0

    if has_exit_branch
        # Pre-branch code via the stackifier — it can contain loops (Set/Vector
        # literal fills); a linear walk flattens them (6cf9be31dafc traped OOB).
        # The branch block itself is truncated before its GotoIfNot terminator,
        # which is emitted manually as the $else guard below.
        pre_blocks = BasicBlock[]
        for b in blocks
            b.start_idx > exit_idx && continue
            if b.end_idx < exit_idx
                push!(pre_blocks, b)
            else
                # block containing the exit branch: keep statements before it
                b.start_idx <= exit_idx - 1 &&
                    push!(pre_blocks, BasicBlock(b.start_idx, exit_idx - 1, nothing))
            end
        end
        append!(bytes, generate_stackified_flow(ctx, pre_blocks, code; trailing_unreachable = false))
        # P3 gap e1cc83db76ea: the pre subset can end with a catchable-throw
        # statement (boundscheck arm) that leaves last_stmt_was_stub=true —
        # compile_condition_to_i32 then dead-code-guards the CONDITION into a
        # bare `unreachable` and the whole if/try structure traps on entry.
        # The pre region falls through here alive; reset BEFORE the condition.
        ctx.last_stmt_was_stub = false
        push!(bytes, Opcode.BLOCK)   # $else
        push!(bytes, 0x40)
        append!(bytes, compile_condition_to_i32((code[exit_idx]::Core.GotoIfNot).cond, ctx))
        push!(bytes, Opcode.I32_EQZ)
        push!(bytes, Opcode.BR_IF)
        append!(bytes, encode_leb128_unsigned(0))
        ctx.last_stmt_was_stub = false
    end

    # P2-batch21 (gap 2c8a7b674388): pre-try code must NOT live inside the
    # try_table — a throwing pre-try statement (e.g. the catchable bounds throw
    # of a `getindex(v, 0)` before the try) would be caught by this try's
    # catch_all, whereas natively it propagates uncaught. Emit blocks before
    # the EnterNode OUTSIDE the try_table, splitting the block that spans the
    # enter (Enter does not terminate a basic block); the tail goes into the
    # try body so phi edges keyed on its last statement stay resolvable.
    pre_try_blocks = BasicBlock[]
    body_head = nothing
    for b in blocks
        (has_exit_branch && b.start_idx <= exit_idx) && continue
        b.start_idx < catch_dest || continue
        if b.end_idx < region.enter_idx
            push!(pre_try_blocks, b)
        elseif b.start_idx <= region.enter_idx <= b.end_idx
            b.start_idx < region.enter_idx &&
                push!(pre_try_blocks, BasicBlock(b.start_idx, region.enter_idx - 1, nothing))
            region.enter_idx < b.end_idx &&
                (body_head = BasicBlock(region.enter_idx + 1, b.end_idx, b.terminator))
        end
    end
    if !isempty(pre_try_blocks)
        append!(bytes, generate_stackified_flow(ctx, pre_try_blocks, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end

    if has_merge
        push!(bytes, Opcode.BLOCK)   # $merge
        push!(bytes, 0x40)
    end

    # Catch landing block (void) — catch_all branches here
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)  # void

    # try_table with catch_all → label 0 (catch_landing block)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)  # void block type
    append!(bytes, encode_leb128_unsigned(1))    # 1 catch clause
    push!(bytes, Opcode.CATCH_ALL)               # catch_all type
    append!(bytes, encode_leb128_unsigned(0))    # label index 0

    # Try-body blocks: strictly after the enter, before the catch handler.
    # Pre-try and pre-branch blocks are emitted above, outside the try_table.
    try_body_blocks = [b for b in blocks
                       if b.start_idx > region.enter_idx && b.start_idx < catch_dest]
    body_head !== nothing && pushfirst!(try_body_blocks, body_head)

    # Use generate_stackified_flow for proper control flow:
    # - phi locals set at every edge (GotoNode, GotoIfNot, fall-through)
    # - nested GotoIfNot properly generates if/else or br_if
    # - returns use RETURN opcode (exits function from within try_table)
    append!(bytes, generate_stackified_flow(ctx, try_body_blocks, code))

    if has_merge
        # Normal completion: the try-exit edge targets the merge block, which is
        # OUTSIDE try_body_blocks, so the stackified body never assigns the merge
        # phi locals — set them here from each phi's try-side edge value.
        for i in merge_start:length(code)
            st = code[i]
            st isa Core.PhiNode || break   # merge phis are contiguous
            haskey(ctx.phi_locals, i) || continue
            for (k, e) in enumerate(st.edges)
                if e < catch_dest && isassigned(st.values, k)
                    emit_phi_local_set!(bytes, st.values[k], i, ctx)
                    break
                end
            end
        end
        push!(bytes, Opcode.BR)
        append!(bytes, encode_leb128_unsigned(2))  # past catch_landing + catch → $merge end
    end

    # End try_table
    push!(bytes, Opcode.END)

    # End catch_landing block
    push!(bytes, Opcode.END)

    # PURE-9032-style: the catch handler is reachable via exception regardless
    # of any stub flags set while emitting the try body.
    ctx.last_stmt_was_stub = false

    # Catch handler: catch_dest up to the merge point (or end of code)
    if has_merge
        # P2-batch17: GotoIfNot-aware linear walk (conditional catch arms).
        # P3 gap 40da73b299fc: arms containing loops or phis need REAL control
        # flow — the linear walk drops back-edges (loops flatten to straight
        # line) and never emits phi-edge stores (phi locals read their zero
        # defaults: the [0,0,0] fill loop indexed array[-1] → OOB trap).
        # Route those through the stackifier like the no-merge case below.
        _arm_rng = catch_dest:(merge_start - 1)
        _arm_complex = any(i -> code[i] isa Core.PhiNode, _arm_rng) ||
                       any(i -> code[i] isa Core.GotoNode && (code[i]::Core.GotoNode).label <= i, _arm_rng) ||
                       count(i -> code[i] isa Core.GotoIfNot, _arm_rng) > 1
        if _arm_complex
            catch_blocks = [b for b in blocks
                            if b.start_idx >= catch_dest && b.start_idx < merge_start]
            append!(bytes, generate_stackified_flow(ctx, catch_blocks, code;
                                                    trailing_unreachable = false))
        else
            _compile_catch_region!(bytes, ctx, code, catch_dest, merge_start - 1)
        end
    else
        # P2-batch19: self-contained catch arm (ends in return) — compile via
        # the stackifier so internal phis/diamonds/loops work (inlined
        # mod/div in catch arms, loop-in-catch — gaps 93a32c2c9d13 family).
        catch_blocks = [b for b in blocks
                        if b.start_idx >= catch_dest &&
                           (!has_exit_branch || b.start_idx < exit_dest)]
        append!(bytes, generate_stackified_flow(ctx, catch_blocks, code))
    end

    if has_exit_branch
        push!(bytes, Opcode.END)   # $else
        ctx.last_stmt_was_stub = false
        # Post code: the else arm of the pre-try branch (returns). P2-batch21:
        # stackified — else arms can contain loops/begin blocks/nested ifs that
        # the linear walk flattened or rejected (gap 227929b3fbff family).
        post_blocks = [b for b in blocks if b.start_idx >= exit_dest]
        append!(bytes, generate_stackified_flow(ctx, post_blocks, code))
    end

    if has_merge
        # Catch-side merge phi values (edge source >= catch_dest)
        for i in merge_start:length(code)
            st = code[i]
            st isa Core.PhiNode || break
            haskey(ctx.phi_locals, i) || continue
            for (k, e) in enumerate(st.edges)
                if e >= catch_dest && isassigned(st.values, k)
                    emit_phi_local_set!(bytes, st.values[k], i, ctx)
                    break
                end
            end
        end
        push!(bytes, Opcode.END)   # $merge
        ctx.last_stmt_was_stub = false
        # Post-merge code: phi reads, conversions, return.
        # P3 gap 40da73b299fc: the linear walk DROPS control flow — a
        # `goto #N if not %cond` guarding a throw_inexacterror vanished, so
        # the throw executed unconditionally on the no-throw path (escaped
        # exception). Route control-flow-bearing post-merge regions through
        # the stackifier; keep the linear walk for the plain
        # phi-read/convert/return tail it was written for.
        _pm_rng = merge_start:length(code)
        _pm_complex = any(i -> code[i] isa Core.GotoIfNot || code[i] isa Core.GotoNode, _pm_rng)
        if _pm_complex
            pm_blocks = [b for b in blocks if b.start_idx >= merge_start]
            append!(bytes, generate_stackified_flow(ctx, pm_blocks, code;
                                                    trailing_unreachable = false))
        else
            for i in _pm_rng
                stmt = code[i]
                if stmt !== nothing
                    if stmt isa Expr && stmt.head === :pop_exception
                        continue
                    end
                    append!(bytes, compile_statement(stmt, i, ctx))
                end
            end
        end
    end

    return bytes
end

# P2-batch18: does the outer region's normal path (between :leave and the catch
# dest) return from the function? True for the return-style try/catch chain
# shapes; false for merging shapes (which goto a phi instead).
function _outer_normal_path_returns(code, outer::TryRegion)::Bool
    for i in (outer.leave_idx + 1):(outer.catch_dest - 1)
        code[i] isa Core.ReturnNode && return true
    end
    return false
end

# P2-batch22 (gap bac7c93c2871): `if cond; try A catch X end else try B catch Y
# end end` ALSO has two regions with inner.enter ≥ outer.catch_dest and
# returning arms — but it is an if/else SPLIT, not a catch-containing-try
# chain. The tell: pre-try control flow branches OVER the outer region
# (a GotoIfNot/GotoNode before outer.enter whose dest lands at/after
# outer.catch_dest). The chain layout would glue the else-arm try into the
# then-arm's catch handler, returning the wrong arm's value.
function _branches_over_outer(code, outer::TryRegion)::Bool
    for i in 1:(outer.enter_idx - 1)
        st = code[i]
        dest = st isa Core.GotoIfNot ? st.dest : st isa Core.GotoNode ? st.label : 0
        dest >= outer.catch_dest && return true
    end
    return false
end

# P2-batch22 (gap bac7c93c2871): `if cond; try A catch X end else try B catch
# Y end end` — two INDEPENDENT try/catches, one per branch arm, every arm
# returning. Neither the chain nor the sequential generator fits (chain glues
# the else arm into the then arm's catch; sequential leaves the branch
# condition stranded on the stack). Layout:
#   <pre-branch code>
#   block $else
#     cond eqz br_if 0                ;; !cond → else arm
#     <then arm: try_table A / catch X>   ;; all paths return
#   end
#   <else arm: try_table B / catch Y>     ;; all paths return
function generate_branch_split_try(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                   code, then_chain::Vector{TryRegion},
                                   else_chain::Vector{TryRegion},
                                   branch_idx::Int)::Vector{UInt8}
    bytes = UInt8[]
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)
    else_start = (code[branch_idx]::Core.GotoIfNot).dest

    function _emit_try_table!(body_blocks::Vector{BasicBlock})
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)
        push!(bytes, Opcode.TRY_TABLE)
        push!(bytes, 0x40)
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.CATCH_ALL)
        append!(bytes, encode_leb128_unsigned(0))
        append!(bytes, generate_stackified_flow(ctx, body_blocks, code))
        push!(bytes, Opcode.END)   # try_table
        push!(bytes, Opcode.END)   # catch landing block
        ctx.last_stmt_was_stub = false
    end

    # One arm = a (possibly empty) CHAIN of try regions plus its surrounding
    # code, all paths returning (guarded at dispatch). P2-batch25 (gap
    # 589873788e5c): an arm can hold try-in-catch chains, not just one try.
    function _emit_arm!(lo::Int, chain::Vector{TryRegion}, hi::Int)
        if isempty(chain)
            arm_blocks = [b for b in blocks if b.start_idx >= lo && b.start_idx <= hi]
            append!(bytes, generate_stackified_flow(ctx, arm_blocks, code))
            ctx.last_stmt_was_stub = false
        else
            _emit_chain_levels!(bytes, ctx, blocks, code, chain, lo, hi, _emit_try_table!)
        end
    end

    # Pre-branch code (may contain loops — stackified), truncated at the branch.
    pre = BasicBlock[]
    for b in blocks
        if b.end_idx < branch_idx
            push!(pre, b)
        elseif b.start_idx <= branch_idx <= b.end_idx && b.start_idx < branch_idx
            push!(pre, BasicBlock(b.start_idx, branch_idx - 1, nothing))
        end
    end
    if !isempty(pre)
        append!(bytes, generate_stackified_flow(ctx, pre, code; trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end

    push!(bytes, Opcode.BLOCK)   # $else
    push!(bytes, 0x40)
    append!(bytes, compile_condition_to_i32((code[branch_idx]::Core.GotoIfNot).cond, ctx))
    push!(bytes, Opcode.I32_EQZ)
    push!(bytes, Opcode.BR_IF)
    append!(bytes, encode_leb128_unsigned(0))
    _emit_arm!(branch_idx + 1, then_chain, else_start - 1)   # then arm — all paths return
    push!(bytes, Opcode.END)     # $else
    _emit_arm!(else_start, else_chain, length(code))          # else arm — all paths return
    return bytes
end

# P2-batch18 (generalised to N levels in P2-batch24, gap a38002fd0ef2):
# `try A catch; <prefix>; try B catch; … try Z catch W end … end end` — each
# catch handler IS (or wraps) the next try. Per level k:
#   <prefix stmts between level k-1's catch_dest and level k's enter>
#   block $ck / try_table(catch_all 0): body of level k / end / end
# and after the last try_table, the final catch region (GotoIfNot-aware).
# Only called for the return-style shape (guarded at the dispatch site).
# P3 gap 600287f76223: `try A catch; if cond; try B … else Z end end` — the
# OUTER catch arm is an if/else split whose arms hold (possibly empty) chains.
# The chain layout funnelled both paths into the inner try_table (the else arm
# became unreachable); the sequential layout treats the regions as disjoint.
# Emit the outer level exactly like one _emit_chain_levels! level, then
# delegate the whole catch arm to generate_branch_split_try restricted to the
# catch-subset blocks.
function generate_catch_arm_split(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                  code, outer::TryRegion, arm_regions::Vector{TryRegion},
                                  branch_idx::Int)::Vector{UInt8}
    bytes = UInt8[]
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)

    # Outer level: pre-try blocks OUTSIDE the try_table (EnterNode split —
    # natively-uncaught throws there must not reach our catch_all).
    r = outer
    pre = BasicBlock[]
    head = nothing
    for b in blocks
        b.start_idx < r.catch_dest || continue
        if b.end_idx < r.enter_idx
            push!(pre, b)
        elseif b.start_idx <= r.enter_idx <= b.end_idx
            b.start_idx < r.enter_idx &&
                push!(pre, BasicBlock(b.start_idx, r.enter_idx - 1, nothing))
            r.enter_idx < b.end_idx &&
                (head = BasicBlock(r.enter_idx + 1, b.end_idx, b.terminator))
        end
    end
    if !isempty(pre)
        append!(bytes, generate_stackified_flow(ctx, pre, code; trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    body = [b for b in blocks if b.start_idx > r.enter_idx && b.start_idx < r.catch_dest]
    head !== nothing && pushfirst!(body, head)
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))
    append!(bytes, generate_stackified_flow(ctx, body, code))
    push!(bytes, Opcode.END)   # try_table
    push!(bytes, Opcode.END)   # catch landing block
    ctx.last_stmt_was_stub = false

    # Catch arm: prefix + if/else split with per-arm chains, every path returns.
    bdest = (code[branch_idx]::Core.GotoIfNot).dest
    then_chain = [q for q in arm_regions if q.enter_idx < bdest]
    else_chain = [q for q in arm_regions if q.enter_idx >= bdest]
    arm_blocks = [b for b in blocks if b.start_idx >= r.catch_dest]
    append!(bytes, generate_branch_split_try(ctx, arm_blocks, code, then_chain,
                                             else_chain, branch_idx))
    return bytes
end

# P3 gap 10cc64efe535: catch-arm split with a GotoNode skip and MERGING arms.
# `try A catch; if cond X else try B catch Y end end end` where the arms meet
# at a merge phi instead of returning. Layout:
#   <pre> block $c1 { try_table { body A (returns) } }
#   block $armmerge (void)
#     <arm prefix [catch_dest .. gin-1]>           ; fill loops, cond computation
#     block $skiparm (void)
#       <cond> i32.eqz br_if 0                     ; !cond → inner-try arm
#       <merge-phi store for the skip edge>; br 1  ; cond → skip to $armmerge
#     end
#     block $c2 { try_table { body B } }           ; always-throw body, no result
#     <inner catch tail [B.catch_dest .. merge-1]>
#     <merge-phi store for the catch-tail edge>
#   end
#   <post-merge [merge ..]: phi reads, pop_exception, return>
function generate_catch_arm_skip_merge(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                       code, outer::TryRegion, inner::TryRegion,
                                       gin_idx::Int, skip_idx::Int, merge_idx::Int)::Vector{UInt8}
    bytes = UInt8[]
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)

    # Outer pre + body — identical structure to generate_catch_arm_split
    r = outer
    pre = BasicBlock[]
    head = nothing
    for b in blocks
        b.start_idx < r.catch_dest || continue
        if b.end_idx < r.enter_idx
            push!(pre, b)
        elseif b.start_idx <= r.enter_idx <= b.end_idx
            b.start_idx < r.enter_idx &&
                push!(pre, BasicBlock(b.start_idx, r.enter_idx - 1, nothing))
            r.enter_idx < b.end_idx &&
                (head = BasicBlock(r.enter_idx + 1, b.end_idx, b.terminator))
        end
    end
    if !isempty(pre)
        append!(bytes, generate_stackified_flow(ctx, pre, code; trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    body = [b for b in blocks if b.start_idx > r.enter_idx && b.start_idx < r.catch_dest]
    head !== nothing && pushfirst!(body, head)
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))
    append!(bytes, generate_stackified_flow(ctx, body, code))
    push!(bytes, Opcode.END)   # try_table
    push!(bytes, Opcode.END)   # catch landing block
    ctx.last_stmt_was_stub = false

    push!(bytes, Opcode.BLOCK)   # $armmerge
    push!(bytes, 0x40)
    # Arm prefix [outer.catch_dest .. gin_idx-1], truncating the block that
    # carries the GotoIfNot terminator (emitted manually below)
    arm_pre = BasicBlock[]
    for b in blocks
        b.start_idx >= r.catch_dest || continue
        b.start_idx <= gin_idx || continue
        if b.end_idx < gin_idx
            push!(arm_pre, b)
        elseif b.start_idx <= gin_idx - 1
            push!(arm_pre, BasicBlock(b.start_idx, gin_idx - 1, nothing))
        end
    end
    if !isempty(arm_pre)
        append!(bytes, generate_stackified_flow(ctx, arm_pre, code; trailing_unreachable=false))
    end
    # e1cc class: the prefix can end with a catchable-throw arm — reset before
    # compiling the live condition.
    ctx.last_stmt_was_stub = false
    push!(bytes, Opcode.BLOCK)   # $skiparm
    push!(bytes, 0x40)
    append!(bytes, compile_condition_to_i32((code[gin_idx]::Core.GotoIfNot).cond, ctx))
    push!(bytes, Opcode.I32_EQZ)
    push!(bytes, Opcode.BR_IF)
    append!(bytes, encode_leb128_unsigned(0))   # !cond → inner-try arm
    ctx.last_stmt_was_stub = false
    # cond TRUE → skip edge: store the merge phi's skip-edge value, br $armmerge
    local _ph = code[merge_idx]::Core.PhiNode
    for (j, e) in enumerate(_ph.edges)
        if Int(e) == skip_idx && isassigned(_ph.values, j)
            emit_phi_local_set!(bytes, _ph.values[j], merge_idx, ctx)
            break
        end
    end
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(1))   # past $skiparm → $armmerge end
    push!(bytes, Opcode.END)   # $skiparm
    ctx.last_stmt_was_stub = false

    # Inner region: prefix [gdest .. inner.enter-1] (ϒ etc.), then try_table
    in_pre = BasicBlock[]
    in_head = nothing
    for b in blocks
        b.start_idx > gin_idx || continue
        b.start_idx < inner.catch_dest || continue
        if b.end_idx < inner.enter_idx
            push!(in_pre, b)
        elseif b.start_idx <= inner.enter_idx <= b.end_idx
            b.start_idx < inner.enter_idx &&
                push!(in_pre, BasicBlock(b.start_idx, inner.enter_idx - 1, nothing))
            inner.enter_idx < b.end_idx &&
                (in_head = BasicBlock(inner.enter_idx + 1, b.end_idx, b.terminator))
        end
    end
    if !isempty(in_pre)
        append!(bytes, generate_stackified_flow(ctx, in_pre, code; trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    in_body = [b for b in blocks
               if b.start_idx > inner.enter_idx && b.start_idx < inner.catch_dest]
    in_head !== nothing && pushfirst!(in_body, in_head)
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))
    append!(bytes, generate_stackified_flow(ctx, in_body, code;
                                            trailing_unreachable=false))
    ctx.last_stmt_was_stub = false
    # If the inner body completes normally it merges too — store its phi
    # edge (an edge strictly inside the body range) and branch to $armmerge.
    local _had_body_edge = false
    for (j, e) in enumerate(_ph.edges)
        if inner.enter_idx < Int(e) && Int(e) < inner.catch_dest && isassigned(_ph.values, j)
            emit_phi_local_set!(bytes, _ph.values[j], merge_idx, ctx)
            _had_body_edge = true
            break
        end
    end
    if _had_body_edge
        push!(bytes, Opcode.BR)
        append!(bytes, encode_leb128_unsigned(2))   # try_table + $c2 → $armmerge
    end
    push!(bytes, Opcode.END)   # try_table
    push!(bytes, Opcode.END)   # $c2
    ctx.last_stmt_was_stub = false
    # Inner catch tail [inner.catch_dest .. merge-1], then the catch-edge store
    tail_blocks = [b for b in blocks
                   if b.start_idx >= inner.catch_dest && b.start_idx < merge_idx]
    if !isempty(tail_blocks)
        append!(bytes, generate_stackified_flow(ctx, tail_blocks, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    for (j, e) in enumerate(_ph.edges)
        if Int(e) >= inner.catch_dest && isassigned(_ph.values, j)
            emit_phi_local_set!(bytes, _ph.values[j], merge_idx, ctx)
            break
        end
    end
    push!(bytes, Opcode.END)   # $armmerge
    ctx.last_stmt_was_stub = false

    # Post-merge [merge_idx ..]: phi reads, conversions, return
    if any(i -> code[i] isa Core.GotoIfNot || code[i] isa Core.GotoNode, merge_idx:length(code))
        pm_blocks = [b for b in blocks if b.start_idx >= merge_idx]
        append!(bytes, generate_stackified_flow(ctx, pm_blocks, code;
                                                trailing_unreachable=false))
    else
        for i in merge_idx:length(code)
            stmt = code[i]
            if stmt !== nothing
                stmt isa Expr && stmt.head === :pop_exception && continue
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end
    end
    return bytes
end

function generate_catch_try_chain(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                  code, chain::Vector{TryRegion})::Vector{UInt8}
    bytes = UInt8[]
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)

    # Emit one `block $c / try_table(catch_all 0) ... end / end` whose body is
    # compiled by the STACKIFIER over the given block subset — try bodies here
    # can contain loops/phis (e.g. inlined vector-literal fill loops), which a
    # linear statement walk silently flattens. The normal path inside each body
    # RETURNS (guarded at the dispatch site), so the try_table needs no result.
    function _emit_try_table_region!(body_blocks::Vector{BasicBlock})
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)
        push!(bytes, Opcode.TRY_TABLE)
        push!(bytes, 0x40)
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.CATCH_ALL)
        append!(bytes, encode_leb128_unsigned(0))
        append!(bytes, generate_stackified_flow(ctx, body_blocks, code))
        push!(bytes, Opcode.END)   # try_table
        push!(bytes, Opcode.END)   # catch landing block
        ctx.last_stmt_was_stub = false
    end

    _emit_chain_levels!(bytes, ctx, blocks, code, chain, 1, length(code),
                        _emit_try_table_region!)
    return bytes
end

# Shared chain emission bounded to [lo, hi] (P2-batch25: arms of a branch-split
# can themselves be chains — gap 589873788e5c). Per level: prefix (pre-try code
# for level 1, the catch-handler prefix for deeper levels), then the level's
# try_table; after the last level, the stackified catch tail. P2-batch21/22
# lessons baked in: prefixes live OUTSIDE the try_table (a throwing prefix must
# propagate past this level's catch_all — gap 2075020442b9), and the EnterNode
# does NOT terminate a basic block, so the block spanning it is SPLIT — head to
# the prefix, tail into the try body, keeping fill-loop phi edges keyed on the
# tail's last statement resolvable (gap 90fa5e0f6382). The catch tail is
# stackified (gap fdc7171b283f: fill loops in catch arms).
function _emit_chain_levels!(bytes::Vector{UInt8}, ctx::AbstractCompilationContext,
                             blocks::Vector{BasicBlock}, code,
                             chain::Vector{TryRegion}, lo0::Int, hi::Int,
                             emit_try_table!::Function)
    for (k, r) in enumerate(chain)
        lo = k == 1 ? lo0 : chain[k-1].catch_dest
        pre = BasicBlock[]
        head = nothing
        for b in blocks
            b.start_idx >= lo || continue
            b.start_idx < r.catch_dest || continue
            if b.end_idx < r.enter_idx
                push!(pre, b)
            elseif b.start_idx <= r.enter_idx <= b.end_idx
                b.start_idx < r.enter_idx &&
                    push!(pre, BasicBlock(b.start_idx, r.enter_idx - 1, nothing))
                r.enter_idx < b.end_idx &&
                    (head = BasicBlock(r.enter_idx + 1, b.end_idx, b.terminator))
            end
        end
        if !isempty(pre)
            # Falls through into this level's try_table — no trailing unreachable.
            append!(bytes, generate_stackified_flow(ctx, pre, code;
                                                    trailing_unreachable=false))
            ctx.last_stmt_was_stub = false
        end
        body = [b for b in blocks
                if b.start_idx > r.enter_idx && b.start_idx < r.catch_dest]
        head !== nothing && pushfirst!(body, head)
        emit_try_table!(body)
    end

    tail_blocks = [b for b in blocks
                   if b.start_idx >= chain[end].catch_dest && b.start_idx <= hi]
    append!(bytes, generate_stackified_flow(ctx, tail_blocks, code))
    ctx.last_stmt_was_stub = false
    return bytes
end

# P3 gaps ff6dc9760825 / 73a575f2d651: merge-phi variant of the catch-try
# chain. Levels nest in catch arms and EACH level can have its OWN merge phi
# (`try div(x,x) catch; try div(0,0x..,x) catch 0x00 end end` — inner phi
# merges the inner try's normal/catch values, an outer phi merges the outer
# body with that result). A flat single-merge layout stored only the innermost
# phi's edges, leaving the outer phi local at its zero default (73a5 returned
# 0 for every non-throwing input). Recursive per-level layout:
#   <pre_k>
#   block $merge_k (void)               ; only when level k has a merge phi
#     block $ck { try_table(catch_all 0) { body_k; try-side phi stores; br 2 } }
#     <catch arm: recurse into level k+1, or stackified>
#     <catch-side phi stores>
#   end
#   <post-merge [merge_k .. hi]: phi reads / next-level code, falls through>
# A level whose normal path returns (no merge phi) emits the plain
# return-style block and recurses into its catch arm.
function generate_catch_try_chain_merge(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                        code, chain::Vector{TryRegion})::Vector{UInt8}
    bytes = UInt8[]
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)
    _emit_merge_chain_level!(bytes, ctx, blocks, code, chain, 1, 1, length(code))
    return bytes
end

function _emit_merge_chain_level!(bytes::Vector{UInt8}, ctx::AbstractCompilationContext,
                                  blocks::Vector{BasicBlock}, code,
                                  chain::Vector{TryRegion}, k::Int, lo::Int, hi::Int)
    r = chain[k]
    # This level's merge phi: first phi at/after the catch dest (within bounds)
    # with a try-side edge from THIS level's body.
    mk = 0
    for i in r.catch_dest:hi
        st = code[i]
        if st isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
           any(r.enter_idx < Int(e) < r.catch_dest for e in st.edges)
            mk = i
            break
        end
    end

    # Pre code [lo .. enter-1], splitting the block that spans the EnterNode
    pre = BasicBlock[]
    head = nothing
    for b in blocks
        b.start_idx >= lo || continue
        b.start_idx < r.catch_dest || continue
        if b.end_idx < r.enter_idx
            push!(pre, b)
        elseif b.start_idx <= r.enter_idx <= b.end_idx
            b.start_idx < r.enter_idx &&
                push!(pre, BasicBlock(b.start_idx, r.enter_idx - 1, nothing))
            r.enter_idx < b.end_idx &&
                (head = BasicBlock(r.enter_idx + 1, b.end_idx, b.terminator))
        end
    end
    if !isempty(pre)
        append!(bytes, generate_stackified_flow(ctx, pre, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    body = [b for b in blocks
            if b.start_idx > r.enter_idx && b.start_idx < r.catch_dest]
    head !== nothing && pushfirst!(body, head)

    arm_hi = mk == 0 ? hi : mk - 1
    _has_inner = k < length(chain) && chain[k+1].enter_idx >= r.catch_dest &&
                 chain[k+1].enter_idx <= arm_hi

    mk > 0 && (push!(bytes, Opcode.BLOCK); push!(bytes, 0x40))   # $merge_k
    push!(bytes, Opcode.BLOCK)   # $ck — catch landing
    push!(bytes, 0x40)
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))
    append!(bytes, generate_stackified_flow(ctx, body, code;
                                            trailing_unreachable=(mk == 0)))
    ctx.last_stmt_was_stub = false
    if mk > 0
        # Normal completion: the merge target is outside the body subset, so
        # the stackified body never assigns the merge phi locals — store this
        # level's try-side edge values, then branch past try_table + $ck.
        for i in mk:hi
            st = code[i]
            st isa Core.PhiNode || break   # merge phis are contiguous
            haskey(ctx.phi_locals, i) || continue
            for (j, e) in enumerate(st.edges)
                ei = Int(e)
                if r.enter_idx < ei && ei < r.catch_dest && isassigned(st.values, j)
                    emit_phi_local_set!(bytes, st.values[j], i, ctx)
                    break
                end
            end
        end
        push!(bytes, Opcode.BR)
        append!(bytes, encode_leb128_unsigned(2))
    end
    push!(bytes, Opcode.END)   # try_table
    push!(bytes, Opcode.END)   # $ck
    ctx.last_stmt_was_stub = false

    # Catch arm [catch_dest .. arm_hi]: the next level nests here, else plain
    if _has_inner
        _emit_merge_chain_level!(bytes, ctx, blocks, code, chain, k + 1,
                                 r.catch_dest, arm_hi)
    else
        arm_blocks = [b for b in blocks
                      if b.start_idx >= r.catch_dest && b.start_idx <= arm_hi]
        if !isempty(arm_blocks)
            # Never pad the arm with a trailing unreachable: when an ENCLOSING
            # level has a merge, the arm falls through into that level's
            # catch-side phi stores (a pad trapped the whole catch path of a
            # return-style inner level — ff6dc9760825 on 1.13). A returning
            # arm emits its own RETURN; the function-end pad covers the rest.
            append!(bytes, generate_stackified_flow(ctx, arm_blocks, code;
                                                    trailing_unreachable=false))
            ctx.last_stmt_was_stub = false
        end
    end

    if mk > 0
        # Catch-side merge phi values (edge source inside the catch arm)
        for i in mk:hi
            st = code[i]
            st isa Core.PhiNode || break
            haskey(ctx.phi_locals, i) || continue
            for (j, e) in enumerate(st.edges)
                if r.catch_dest <= Int(e) < mk && isassigned(st.values, j)
                    emit_phi_local_set!(bytes, st.values[j], i, ctx)
                    break
                end
            end
        end
        push!(bytes, Opcode.END)   # $merge_k
        ctx.last_stmt_was_stub = false
        # Post-merge [mk .. hi]: phi reads, conversions, return — or, for an
        # inner level, the code that flows on inside the ENCLOSING catch arm.
        if any(i -> code[i] isa Core.GotoIfNot || code[i] isa Core.GotoNode, mk:hi)
            pm_blocks = [b for b in blocks if b.start_idx >= mk && b.start_idx <= hi]
            append!(bytes, generate_stackified_flow(ctx, pm_blocks, code;
                                                    trailing_unreachable=false))
        else
            for i in mk:hi
                stmt = code[i]
                if stmt !== nothing
                    stmt isa Expr && stmt.head === :pop_exception && continue
                    append!(bytes, compile_statement(stmt, i, ctx))
                end
            end
        end
    end
    return bytes
end

function generate_try_catch(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    bytes = UInt8[]
    regions = find_try_regions(code)

    if isempty(regions)
        # No try regions, fall back to normal generation
        return generate_complex_flow(ctx, blocks, code)
    end

    # Ensure module has an exception tag for Julia exceptions
    ensure_exception_tag!(ctx.mod)

    # PURE-9033: Detect nested/sequential try/catch regions and dispatch accordingly.
    if length(regions) >= 2
        sort!(regions, by=r -> r.enter_idx)
        outer = regions[1]
        inner = regions[2]
        # P2-batch22 (gap bac7c93c2871; chains-per-arm P2-batch25, gap
        # 589873788e5c): if/else split — a pre-try GotoIfNot jumps OVER the
        # first region, each arm holds a (possibly empty) consecutive chain of
        # regions, every arm returns, and no merge phis cross the split.
        begin
            # P3 gap 464d3b1b41ec: take the FIRST (outermost) spanning branch,
            # not the last. With nested ifs both spanning the region (`if a;
            # if b; try … else x end else try … end`), the innermost pick
            # left the outer GotoIfNot stranded inside the stackified
            # pre-code, whose out-of-subset exit fell into the wrong arm.
            # Everything after the outermost split nests inside its arms.
            branch_idx = 0
            for i in 1:(outer.enter_idx - 1)
                st = code[i]
                if st isa Core.GotoIfNot && st.dest > outer.catch_dest
                    branch_idx = i
                    break
                end
            end
            if branch_idx > 0
                bdest = (code[branch_idx]::Core.GotoIfNot).dest
                then_chain = [r for r in regions if r.enter_idx < bdest]
                else_chain = [r for r in regions if r.enter_idx >= bdest]
                _chain_consecutive(ch) = all(
                    ch[k].enter_idx >= ch[k-1].catch_dest &&
                    (_outer_normal_path_returns(code, ch[k-1]) ||
                     ch[k-1].leave_idx == ch[k-1].catch_dest)
                    for k in 2:length(ch))
                arms_ok = !isempty(then_chain) &&
                          all(r.enter_idx > branch_idx for r in then_chain) &&
                          _chain_consecutive(then_chain) && _chain_consecutive(else_chain) &&
                          # then arm fully precedes the else arm
                          then_chain[end].catch_dest <= bdest
                if arms_ok
                    then_returns = any(code[i] isa Core.ReturnNode
                                       for i in then_chain[end].catch_dest:(bdest - 1))
                    else_lo = isempty(else_chain) ? bdest : else_chain[end].catch_dest
                    else_returns = any(code[i] isa Core.ReturnNode
                                       for i in else_lo:length(code))
                    # Arm-INTERNAL phis (vector-literal fill loops etc.) are fine —
                    # the stackified arm bodies handle them. Only a CROSS-ARM merge
                    # phi (an edge from before the else arm) breaks the layout.
                    no_cross_phi = !any(code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
                                        any(Int(e) < bdest for e in (code[i]::Core.PhiNode).edges)
                                        for i in bdest:length(code))
                    if then_returns && else_returns && no_cross_phi
                        return generate_branch_split_try(ctx, blocks, code, then_chain,
                                                         else_chain, branch_idx)
                    end
                end
            end
        end
        # Inner is nested if its enter is within the outer's try scope
        if inner.enter_idx > outer.enter_idx && inner.enter_idx < outer.catch_dest
            return generate_nested_try_catch_2(ctx, blocks, code, outer, inner)
        end
        # P2-batch18 (N levels: P2-batch24, gap a38002fd0ef2): each catch
        # handler contains the next try (`try A catch; try B catch; … end end`).
        # NOT sequential — the sequential generator emitted the structures
        # back-to-back and produced invalid wasm (gaps 331b3b4b2d4a,
        # 39f798226bbd, 422b9863eab9). Per level, the normal path must return
        # or be always-throwing (no :leave → leave_idx synthesized =
        # catch_dest — gap 2075020442b9); nothing may branch over the chain
        # (gap bac7c93c2871: that's an if/else split, handled above); and no
        # merge phis after the last catch (return-style shape).
        chain_ok = true
        for k in 2:length(regions)
            prev, cur = regions[k-1], regions[k]
            if !(cur.enter_idx >= prev.catch_dest &&
                 (_outer_normal_path_returns(code, prev) || prev.leave_idx == prev.catch_dest))
                chain_ok = false
                break
            end
            # P3 gap 600287f76223: a branch in the inter-level gap that jumps
            # OVER the next region (`catch; if cond; try ... else ... end`) is
            # an if/else split inside the catch arm, not a chain — the chain
            # layout funnels BOTH paths into the inner try_table and the else
            # arm becomes unreachable.
            for i in prev.catch_dest:(cur.enter_idx - 1)
                st = code[i]
                dest = st isa Core.GotoIfNot ? st.dest : st isa Core.GotoNode ? st.label : 0
                if dest > cur.catch_dest
                    chain_ok = false
                    break
                end
            end
            chain_ok || break
        end
        # Catch-INTERNAL phis (all edges ≥ the final catch_dest — fill loops in
        # the catch arm) are handled by the stackified tail; only a phi merging
        # values from BEFORE the final catch breaks the return-style layout.
        if chain_ok && !_branches_over_outer(code, outer) &&
           !any(code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
                any(Int(e) < regions[end].catch_dest for e in (code[i]::Core.PhiNode).edges)
                for i in regions[end].catch_dest:length(code))
            return generate_catch_try_chain(ctx, blocks, code, regions)
        end
        # P3 gap ff6dc9760825: catch-try chain that MERGES into a phi instead
        # of returning per level (`try div(x,x) catch; try div(0,0) catch 0x00
        # end end` — inference folds the constant arms, leaving a 2-level
        # chain whose normal paths goto a merge phi). The return-style chain
        # above rejects it (cross-phi guard) and the sequential fallback
        # emitted level 2 AFTER level 1's catch landing instead of inside the
        # handler, leaving the handler empty (validation: "expected i32 but
        # nothing on stack" at the result-block end).
        begin
            _mc_first_cd = regions[1].catch_dest
            # a merge phi exists for some level: a phi past the level's catch
            # dest with an edge from inside that level's body
            _mc_has_merge = false
            for r in regions, i in r.catch_dest:length(code)
                st = code[i]
                if st isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
                   any(r.enter_idx < Int(e) < r.catch_dest for e in st.edges)
                    _mc_has_merge = true
                    break
                end
            end
            if _mc_has_merge && !_branches_over_outer(code, outer)
                _mc_ok = true
                for k in 2:length(regions)
                    prev, cur = regions[k-1], regions[k]
                    if cur.enter_idx < prev.catch_dest
                        _mc_ok = false
                        break
                    end
                    # inter-level branch jumping over the next region → an
                    # if/else split inside the catch arm, not a chain
                    for i in prev.catch_dest:(cur.enter_idx - 1)
                        st = code[i]
                        dest = st isa Core.GotoIfNot ? st.dest : st isa Core.GotoNode ? st.label : 0
                        if dest > cur.catch_dest
                            _mc_ok = false
                            break
                        end
                    end
                    _mc_ok || break
                end
                # every phi edge after the first catch dest must originate at
                # or after it, or inside some level's body — an edge from
                # pre-try code means a branch AROUND the chain, which this
                # layout cannot route
                if _mc_ok
                    for i in _mc_first_cd:length(code)
                        st = code[i]
                        st isa Core.PhiNode || continue
                        haskey(ctx.phi_locals, i) || continue
                        for e in st.edges
                            ei = Int(e)
                            ei >= _mc_first_cd && continue
                            any(r.enter_idx < ei && ei < r.catch_dest for r in regions) ||
                                (_mc_ok = false)
                        end
                    end
                end
                if _mc_ok
                    return generate_catch_try_chain_merge(ctx, blocks, code, regions)
                end
            end
        end
        # P3 gap 600287f76223: branch-split INSIDE the outer catch arm —
        # `try A catch; if cond; try B … else Z end end`. All inner regions
        # live in the catch arm, a GotoIfNot between catch_dest and the first
        # inner enter jumps over it, every arm path returns, no cross-arm phi.
        if !_branches_over_outer(code, outer) &&
           (_outer_normal_path_returns(code, outer) || outer.leave_idx == outer.catch_dest)
            arm_regions = regions[2:end]
            if all(q.enter_idx >= outer.catch_dest for q in arm_regions) && !isempty(arm_regions)
                cas_branch = 0
                for i in outer.catch_dest:(arm_regions[1].enter_idx - 1)
                    st = code[i]
                    st isa Core.GotoIfNot && st.dest > arm_regions[1].catch_dest && (cas_branch = i)
                end
                if cas_branch > 0
                    cas_bdest = (code[cas_branch]::Core.GotoIfNot).dest
                    cas_then = [q for q in arm_regions if q.enter_idx < cas_bdest]
                    cas_else = [q for q in arm_regions if q.enter_idx >= cas_bdest]
                    _cas_consec(ch) = all(
                        ch[k].enter_idx >= ch[k-1].catch_dest &&
                        (_outer_normal_path_returns(code, ch[k-1]) ||
                         ch[k-1].leave_idx == ch[k-1].catch_dest)
                        for k in 2:length(ch))
                    cas_arms_ok = !isempty(cas_then) &&
                                  all(q.enter_idx > cas_branch for q in cas_then) &&
                                  _cas_consec(cas_then) && _cas_consec(cas_else) &&
                                  cas_then[end].catch_dest <= cas_bdest
                    if cas_arms_ok
                        cas_then_ret = any(code[i] isa Core.ReturnNode
                                           for i in cas_then[end].catch_dest:(cas_bdest - 1))
                        cas_else_lo = isempty(cas_else) ? cas_bdest : cas_else[end].catch_dest
                        cas_else_ret = any(code[i] isa Core.ReturnNode
                                           for i in cas_else_lo:length(code))
                        cas_no_cross_phi = !any(code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
                                                any(Int(e) < cas_bdest for e in (code[i]::Core.PhiNode).edges)
                                                for i in cas_bdest:length(code))
                        if cas_then_ret && cas_else_ret && cas_no_cross_phi
                            return generate_catch_arm_split(ctx, blocks, code, outer,
                                                            arm_regions, cas_branch)
                        end
                    end
                end
                # P3 gap 10cc64efe535: catch-arm split where the SKIP over the
                # inner region is a GotoNode (the GotoIfNot targets the
                # inner-try side) and the arms MERGE at a phi instead of
                # returning: `try A catch; if isempty(...) 0x00 else try B
                # catch x end end end`. Detect: one inner region; a GotoNode
                # in the arm prefix jumping past it to a phi whose edges are
                # exactly {the GotoNode, the inner catch tail}; the paired
                # GotoIfNot immediately precedes the GotoNode.
                if length(arm_regions) == 1
                    local _cm_in = arm_regions[1]
                    local _cm_skip = 0
                    for i in outer.catch_dest:(_cm_in.enter_idx - 1)
                        local _st = code[i]
                        if _st isa Core.GotoNode && _st.label > _cm_in.catch_dest
                            _cm_skip = i
                            break
                        end
                    end
                    if _cm_skip > 0 && _cm_skip >= 2 && code[_cm_skip - 1] isa Core.GotoIfNot
                        local _cm_gin = _cm_skip - 1
                        local _cm_gdest = (code[_cm_gin]::Core.GotoIfNot).dest
                        local _cm_merge = (code[_cm_skip]::Core.GotoNode).label
                        local _cm_phi_ok = _cm_merge <= length(code) &&
                            code[_cm_merge] isa Core.PhiNode && haskey(ctx.phi_locals, _cm_merge) &&
                            all(Int(e) == _cm_skip || Int(e) >= _cm_in.catch_dest
                                for e in (code[_cm_merge]::Core.PhiNode).edges)
                        # the GotoIfNot must target the inner-try side, the
                        # inner tail must not branch past the merge, and no
                        # later phi may pull edges from before the merge
                        local _cm_tail_ok = !any(begin
                                local _t = code[i]
                                local _d = _t isa Core.GotoIfNot ? _t.dest :
                                           _t isa Core.GotoNode ? _t.label : 0
                                _d > _cm_merge
                            end for i in _cm_in.catch_dest:(_cm_merge - 1))
                        if _cm_phi_ok && _cm_tail_ok &&
                           _cm_gdest > _cm_skip && _cm_gdest <= _cm_in.enter_idx
                            return generate_catch_arm_skip_merge(ctx, blocks, code, outer,
                                                                 _cm_in, _cm_gin, _cm_skip, _cm_merge)
                        end
                    end
                end
            end
        end
        # Sequential (non-nested) try/catch regions
        return generate_sequential_try_catch(ctx, blocks, code, regions)
    end

    # Single try/catch region
    region = regions[1]
    enter_idx = region.enter_idx
    catch_dest = region.catch_dest
    leave_idx = region.leave_idx

    # PURE-6024: If try body has phi nodes (complex control flow with merge points),
    # delegate to generate_stackified_flow which properly handles phi locals,
    # nested GotoIfNot, and GotoNode. The simple linear approach below can only
    # handle one level of GotoIfNot and doesn't set phi locals at edges.
    # P2-batch11: scan the PRE-TRY region too (1:enter_idx-1) — a loop before the
    # try (e.g. `v_b = sum([0,0,0]); try ... catch`) has phis whose backedges the
    # linear "code before EnterNode" emission below silently flattens, running the
    # loop body straight through → OOB array reads (gap 44a8808e5bfc family).
    has_phi = false
    for i in 1:(catch_dest-1)
        i == enter_idx && continue
        if i <= length(code) && code[i] isa Core.PhiNode
            has_phi = true
            break
        end
        # P2-batch15: pre-try BRANCHES flatten the same way pre-try loops did —
        # `if cond; try ... catch ... end else ... end` executed the try arm on
        # BOTH paths and the broken structure let the throw escape the
        # try_table (gap efca694cdd4f family). Any control flow before the
        # EnterNode needs the stackified try generator.
        if i < enter_idx && (code[i] isa Core.GotoIfNot || code[i] isa Core.GotoNode)
            has_phi = true
            break
        end
    end
    # P2-batch24 (gap 89516a151f4f): the linear walker handles at most ONE
    # GotoIfNot diamond inside the try scope. try/finally normal paths inline
    # whole functions (asin's domain guards etc.) — several diamonds, which
    # the linear walk miscompiled into an unconditional throw (caught →
    # exceptional finally → rethrow → uncaught). Two or more branches inside
    # the region → stackified.
    if !has_phi
        n_gin = count(i -> code[i] isa Core.GotoIfNot, (enter_idx + 1):(catch_dest - 1))
        n_gin >= 2 && (has_phi = true)
    end
    # P2-batch19: CATCH-INTERNAL phis (all edges ≥ catch_dest — inlined diamonds
    # or loops inside the catch arm, e.g. `catch; mod(typemin, x)`) need the
    # stackified catch compilation; the linear walk misplaced their edge
    # assignments (gaps 93a32c2c9d13 / 6c9ddf4c936f).
    if !has_phi
        for i in catch_dest:length(code)
            st = code[i]
            if st isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
               all(Int(e) >= catch_dest for e in st.edges)
                has_phi = true
                break
            end
        end
    end
    if has_phi
        return generate_try_catch_stackified(ctx, blocks, code, region)
    end

    # PURE-9031: Find PhiNodes at the merge point after try/catch.
    # These merge values from the try-exit path and the catch path.
    # PhiNode edges use SSA indices: edges from [leave_idx+1..catch_dest-1] are
    # try-exit, edges from [catch_dest..] are catch-exit.
    merge_phi_nodes = Int[]  # SSA indices of merge PhiNodes
    merge_start = length(code) + 1  # First merge PhiNode index
    for i in catch_dest:length(code)
        if code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
            push!(merge_phi_nodes, i)
            if i < merge_start
                merge_start = i
            end
        end
    end
    has_merge_phis = !isempty(merge_phi_nodes)

    # Determine the try-exit SSA range (normal path after :leave before catch)
    # and the catch SSA range to identify phi edge sources
    try_exit_range = (leave_idx+1):(catch_dest-1)
    catch_range = catch_dest:(has_merge_phis ? merge_start - 1 : length(code))

    # Determine result type for the function. Nothing/Union{} returns have NO
    # wasm result (the signature drops them), so the wrapper block must be void
    # or the block's value is left orphaned at function end.
    func_returns_void = ctx.return_type === Nothing || ctx.return_type === Union{}
    result_type_byte = func_returns_void ? nothing :
        get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)

    # PURE-9031: Structure with merge phi support:
    # block $merge (void)                    ; merge block — both paths converge here
    #   block $catch_landing (void)          ; catch_all jumps here
    #     try_table (catch_all 0)            ; try body
    #       ;; code before EnterNode
    #       ;; try body
    #       ;; SET try-exit phi locals
    #       (br 2)                           ; skip catch, go to $merge end
    #     end
    #   end  ; $catch_landing
    #   ;; catch handler code (pop_exception = skip)
    #   ;; SET catch phi locals
    #   ;; fall through to $merge end
    # end  ; $merge
    # ;; READ phi locals
    # ;; post-merge code (return etc.)

    if has_merge_phis
        # 3-block structure: merge block → catch landing → try_table
        # Merge block (void) — both paths converge after this block ends
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)  # void

        # Catch landing block (void) — catch_all branches here
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)  # void

        # try_table with catch_all → label 0 (catch landing)
        push!(bytes, Opcode.TRY_TABLE)
        push!(bytes, 0x40)  # void
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.CATCH_ALL)
        append!(bytes, encode_leb128_unsigned(0))  # → catch landing block

        # Code BEFORE EnterNode
        for i in 1:(enter_idx-1)
            stmt = code[i]
            if stmt !== nothing && !(stmt isa Core.EnterNode)
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end

        # Try body (enter_idx+1 to leave_idx-1)
        i = enter_idx + 1
        while i <= leave_idx - 1
            stmt = code[i]
            if stmt === nothing
                i += 1
                continue
            end
            if stmt isa Core.GotoIfNot
                append!(bytes, _compile_try_body_gotoifnot(stmt, i, leave_idx, code, ctx))
                i = _advance_past_gotoifnot(stmt, i, leave_idx, code)
            else
                append!(bytes, compile_statement(stmt, i, ctx))
                i += 1
            end
        end

        # Normal path code after :leave (GotoNode etc. — skip, don't compile)
        # The GotoNode just targets the merge point; we handle that with phi locals + br

        # SET try-exit phi locals before branching to merge
        for phi_idx in merge_phi_nodes
            phi_stmt = code[phi_idx]::Core.PhiNode
            for (ei, edge) in enumerate(phi_stmt.edges)
                edge_ssa = Int(edge)
                if edge_ssa in try_exit_range
                    # This edge comes from the try-exit path
                    phi_val = phi_stmt.values[ei]
                    phi_local = ctx.phi_locals[phi_idx]
                    append!(bytes, compile_value(phi_val, ctx))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(phi_local))
                    break
                end
            end
        end

        # br 2 → merge block end (skip catch handler)
        # Labels from inside try_table: 0=try_table, 1=catch_landing, 2=merge
        push!(bytes, Opcode.BR)
        append!(bytes, encode_leb128_unsigned(2))

        # End try_table
        push!(bytes, Opcode.END)

        # End catch landing block — catch_all lands here
        push!(bytes, Opcode.END)

        # PURE-9032: Reset dead code flag — catch handler is always reachable
        ctx.last_stmt_was_stub = false

        # Catch handler code (from catch_dest to merge_start-1)
        # P2-batch17: GotoIfNot-aware (conditional catch arms — gap f80bce91645e)
        _compile_catch_region!(bytes, ctx, code, catch_dest, merge_start - 1)

        # SET catch phi locals
        for phi_idx in merge_phi_nodes
            phi_stmt = code[phi_idx]::Core.PhiNode
            for (ei, edge) in enumerate(phi_stmt.edges)
                edge_ssa = Int(edge)
                if edge_ssa >= catch_dest && edge_ssa < merge_start
                    # This edge comes from the catch path
                    phi_val = phi_stmt.values[ei]
                    phi_local = ctx.phi_locals[phi_idx]
                    append!(bytes, compile_value(phi_val, ctx))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(phi_local))
                    break
                end
            end
        end

        # Fall through to merge block end
        # End merge block — both paths converge here
        push!(bytes, Opcode.END)

        # Post-merge code: read phi locals and compile remaining statements
        for i in merge_start:length(code)
            stmt = code[i]
            if stmt === nothing
                continue
            end
            if stmt isa Core.PhiNode && haskey(ctx.phi_locals, i)
                # PhiNode at merge: the phi local was set by whichever path executed.
                # If this phi has an SSA local, copy phi_local → ssa_local.
                phi_local = ctx.phi_locals[i]
                if haskey(ctx.ssa_locals, i)
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(phi_local))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(ctx.ssa_locals[i]))
                end
                # Otherwise the phi_local is read directly when the value is used
            elseif stmt isa Core.ReturnNode
                append!(bytes, compile_statement(stmt, i, ctx))
            elseif stmt isa Expr && stmt.head === :pop_exception
                continue
            else
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end

    else
        # No merge phis — use original 2-block structure
        # Outer block for the result value
        push!(bytes, Opcode.BLOCK)
        if func_returns_void
            push!(bytes, 0x40)
        else
            append!(bytes, encode_block_type(result_type_byte))
        end

        # Inner void block for catch destination
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)  # void result type

        # try_table with catch_all clause
        push!(bytes, Opcode.TRY_TABLE)
        push!(bytes, 0x40)  # void block type
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.CATCH_ALL)
        append!(bytes, encode_leb128_unsigned(0))  # label index 0 (inner block)

        # Generate code BEFORE EnterNode
        for i in 1:(enter_idx-1)
            stmt = code[i]
            if stmt !== nothing && !(stmt isa Core.EnterNode)
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end

        # Generate try body (from EnterNode+1 to leave_idx-1)
        i = enter_idx + 1
        while i <= leave_idx - 1
            stmt = code[i]
            if stmt === nothing
                i += 1
                continue
            end
            if stmt isa Core.GotoIfNot
                append!(bytes, _compile_try_body_gotoifnot(stmt, i, leave_idx, code, ctx))
                i = _advance_past_gotoifnot(stmt, i, leave_idx, code)
            else
                append!(bytes, compile_statement(stmt, i, ctx))
                i += 1
            end
        end

        # Generate normal path code after :leave until catch_dest
        for i in (leave_idx+1):(catch_dest-1)
            stmt = code[i]
            if stmt !== nothing
                if stmt isa Core.ReturnNode
                    append!(bytes, compile_statement(stmt, i, ctx))
                    push!(bytes, Opcode.BR)
                    append!(bytes, encode_leb128_unsigned(1))
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

        # PURE-9032: Reset dead code flag — catch handler is always reachable
        # (catch_all means ANY throw reaches here, regardless of what happened in try body)
        ctx.last_stmt_was_stub = false

        # Catch handler code (from catch_dest to end)
        # PURE-9032: Handle GotoIfNot in catch body — generate if/else blocks
        # for exception type dispatch (isa checks in catch blocks).
        local _catch_i = catch_dest
        while _catch_i <= length(code)
            local _catch_stmt = code[_catch_i]
            if _catch_stmt === nothing
                _catch_i += 1
                continue
            end
            if _catch_stmt isa Expr && _catch_stmt.head === :pop_exception
                _catch_i += 1
                continue
            end
            if _catch_stmt isa Core.GotoIfNot
                # Generate if/else for the conditional branch
                local _else_target = _catch_stmt.dest
                append!(bytes, compile_condition_to_i32(_catch_stmt.cond, ctx))
                # Determine if the then-branch has a return/throw (one-way)
                local _then_start = _catch_i + 1
                local _then_has_return = false
                for _j in _then_start:min(_else_target - 1, length(code))
                    if code[_j] isa Core.ReturnNode
                        _then_has_return = true
                        break
                    end
                end
                if _then_has_return
                    # Then-branch returns: just wrap in if/end (no else needed)
                    push!(bytes, Opcode.IF)
                    push!(bytes, 0x40)
                    for _j in _then_start:min(_else_target - 1, length(code))
                        local _ts = code[_j]
                        if _ts !== nothing && !(_ts isa Expr && _ts.head === :pop_exception)
                            append!(bytes, compile_statement(_ts, _j, ctx))
                        end
                    end
                    push!(bytes, Opcode.END)
                    ctx.last_stmt_was_stub = false
                    _catch_i = _else_target
                else
                    # Both branches present: if/else/end
                    push!(bytes, Opcode.IF)
                    push!(bytes, 0x40)
                    for _j in _then_start:min(_else_target - 1, length(code))
                        local _ts2 = code[_j]
                        if _ts2 !== nothing && !(_ts2 isa Expr && _ts2.head === :pop_exception)
                            append!(bytes, compile_statement(_ts2, _j, ctx))
                        end
                    end
                    push!(bytes, Opcode.ELSE)
                    for _j in _else_target:length(code)
                        local _es = code[_j]
                        if _es !== nothing && !(_es isa Expr && _es.head === :pop_exception)
                            append!(bytes, compile_statement(_es, _j, ctx))
                        end
                    end
                    push!(bytes, Opcode.END)
                    ctx.last_stmt_was_stub = false
                    _catch_i = length(code) + 1  # done
                end
            else
                append!(bytes, compile_statement(_catch_stmt, _catch_i, ctx))
                _catch_i += 1
            end
        end

        # End outer block
        push!(bytes, Opcode.END)
    end

    return bytes
end

# PURE-9033: Generate sequential (non-nested) try/catch regions.
# Each region gets its own try_table block structure, processed in order.
# Example: two sequential try/catch blocks in one function.
function generate_sequential_try_catch(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                       code, regions::Vector{TryRegion})::Vector{UInt8}
    bytes = UInt8[]

    # Ensure exception infrastructure
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)

    # Process code in segments: pre-region, region, inter-region, region, post-region
    n = length(regions)
    last_processed = 0  # last SSA index we've processed

    for (ri, region) in enumerate(regions)
        enter_idx = region.enter_idx
        catch_dest = region.catch_dest
        leave_idx = region.leave_idx

        # Compile code between last processed and this region's enter
        for i in (last_processed + 1):(enter_idx - 1)
            stmt = code[i]
            if stmt !== nothing && !(stmt isa Core.EnterNode)
                append!(bytes, compile_statement(stmt, i, ctx))
            end
        end

        # Find merge PhiNodes after this region's catch
        # They appear after catch_dest and merge try-exit + catch edges
        merge_phi_nodes = Int[]
        merge_start = length(code) + 1

        # Determine the end of this region's influence: either next region's enter or end of code
        region_end = ri < n ? regions[ri + 1].enter_idx - 1 : length(code)

        for i in catch_dest:region_end
            if code[i] isa Core.PhiNode && haskey(ctx.phi_locals, i)
                push!(merge_phi_nodes, i)
                if i < merge_start
                    merge_start = i
                end
            end
        end
        has_merge_phis = !isempty(merge_phi_nodes)

        try_exit_range = (leave_idx + 1):(catch_dest - 1)

        if has_merge_phis
            # 3-block structure: merge block → catch landing → try_table
            push!(bytes, Opcode.BLOCK)
            push!(bytes, 0x40)  # void

            push!(bytes, Opcode.BLOCK)
            push!(bytes, 0x40)  # void

            push!(bytes, Opcode.TRY_TABLE)
            push!(bytes, 0x40)  # void
            append!(bytes, encode_leb128_unsigned(1))
            push!(bytes, Opcode.CATCH_ALL)
            append!(bytes, encode_leb128_unsigned(0))

            # Try body
            local _ti = enter_idx + 1
            while _ti <= leave_idx - 1
                stmt = code[_ti]
                if stmt === nothing
                    _ti += 1
                    continue
                end
                if stmt isa Core.GotoIfNot
                    append!(bytes, _compile_try_body_gotoifnot(stmt, _ti, leave_idx, code, ctx))
                    _ti = _advance_past_gotoifnot(stmt, _ti, leave_idx, code)
                else
                    append!(bytes, compile_statement(stmt, _ti, ctx))
                    _ti += 1
                end
            end

            # SET try-exit phi locals
            for phi_idx in merge_phi_nodes
                phi_stmt = code[phi_idx]::Core.PhiNode
                for (ei, edge) in enumerate(phi_stmt.edges)
                    edge_ssa = Int(edge)
                    if edge_ssa in try_exit_range
                        phi_val = phi_stmt.values[ei]
                        phi_local = ctx.phi_locals[phi_idx]
                        append!(bytes, compile_value(phi_val, ctx))
                        push!(bytes, Opcode.LOCAL_SET)
                        append!(bytes, encode_leb128_unsigned(phi_local))
                        break
                    end
                end
            end

            # br 2 → merge block end
            push!(bytes, Opcode.BR)
            append!(bytes, encode_leb128_unsigned(2))

            push!(bytes, Opcode.END)  # end try_table
            push!(bytes, Opcode.END)  # end catch landing block

            ctx.last_stmt_was_stub = false

            # Catch handler code
            catch_end = has_merge_phis ? merge_start - 1 : region_end
            for i in catch_dest:catch_end
                stmt = code[i]
                if stmt !== nothing
                    if stmt isa Expr && stmt.head === :pop_exception
                        continue
                    end
                    append!(bytes, compile_statement(stmt, i, ctx))
                end
            end

            # SET catch phi locals
            for phi_idx in merge_phi_nodes
                phi_stmt = code[phi_idx]::Core.PhiNode
                for (ei, edge) in enumerate(phi_stmt.edges)
                    edge_ssa = Int(edge)
                    if edge_ssa >= catch_dest && edge_ssa < merge_start
                        phi_val = phi_stmt.values[ei]
                        phi_local = ctx.phi_locals[phi_idx]
                        append!(bytes, compile_value(phi_val, ctx))
                        push!(bytes, Opcode.LOCAL_SET)
                        append!(bytes, encode_leb128_unsigned(phi_local))
                        break
                    end
                end
            end

            push!(bytes, Opcode.END)  # end merge block

            # Read phi locals (copy to SSA locals if needed)
            for phi_idx in merge_phi_nodes
                if haskey(ctx.ssa_locals, phi_idx)
                    phi_local = ctx.phi_locals[phi_idx]
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(phi_local))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(ctx.ssa_locals[phi_idx]))
                end
            end

            # Non-phi statements between merge_start and region_end (but not EnterNode of next region)
            for i in merge_start:region_end
                stmt = code[i]
                if stmt === nothing
                    continue
                end
                if stmt isa Core.PhiNode && haskey(ctx.phi_locals, i)
                    continue  # already handled above
                end
                if stmt isa Core.EnterNode
                    continue  # next region handles this
                end
                if stmt isa Expr && stmt.head === :pop_exception
                    continue
                end
                append!(bytes, compile_statement(stmt, i, ctx))
            end

            last_processed = region_end
        else
            # No merge phis — use 2-block structure (direct return in both paths)
            # Void-return functions get a void wrapper (signature has no results).
            push!(bytes, Opcode.BLOCK)
            if ctx.return_type === Nothing || ctx.return_type === Union{}
                push!(bytes, 0x40)
            else
                append!(bytes, encode_block_type(
                    get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)))
            end

            push!(bytes, Opcode.BLOCK)
            push!(bytes, 0x40)

            push!(bytes, Opcode.TRY_TABLE)
            push!(bytes, 0x40)
            append!(bytes, encode_leb128_unsigned(1))
            push!(bytes, Opcode.CATCH_ALL)
            append!(bytes, encode_leb128_unsigned(0))

            # Try body
            local _ti2 = enter_idx + 1
            while _ti2 <= leave_idx - 1
                stmt = code[_ti2]
                if stmt === nothing
                    _ti2 += 1
                    continue
                end
                if stmt isa Core.GotoIfNot
                    append!(bytes, _compile_try_body_gotoifnot(stmt, _ti2, leave_idx, code, ctx))
                    _ti2 = _advance_past_gotoifnot(stmt, _ti2, leave_idx, code)
                else
                    append!(bytes, compile_statement(stmt, _ti2, ctx))
                    _ti2 += 1
                end
            end

            # Normal path after leave
            for i in (leave_idx + 1):(catch_dest - 1)
                stmt = code[i]
                if stmt !== nothing
                    if stmt isa Core.ReturnNode
                        append!(bytes, compile_statement(stmt, i, ctx))
                        push!(bytes, Opcode.BR)
                        append!(bytes, encode_leb128_unsigned(1))
                        break
                    else
                        append!(bytes, compile_statement(stmt, i, ctx))
                    end
                end
            end

            push!(bytes, Opcode.BR)
            append!(bytes, encode_leb128_unsigned(1))

            push!(bytes, Opcode.END)  # end try_table
            push!(bytes, Opcode.END)  # end catch landing

            ctx.last_stmt_was_stub = false

            # Catch handler
            for i in catch_dest:region_end
                stmt = code[i]
                if stmt !== nothing
                    if stmt isa Expr && stmt.head === :pop_exception
                        continue
                    end
                    append!(bytes, compile_statement(stmt, i, ctx))
                end
            end

            push!(bytes, Opcode.END)  # end outer block

            last_processed = region_end
        end
    end

    # Post-all-regions code
    for i in (last_processed + 1):length(code)
        stmt = code[i]
        if stmt !== nothing && !(stmt isa Expr && stmt.head === :pop_exception)
            append!(bytes, compile_statement(stmt, i, ctx))
        end
    end

    return bytes
end

# PURE-9033: Generate nested try/catch (2-level nesting: inner try/catch inside outer try/catch).
#
# WASM structure:
#   ; pre-outer code
#   block void                                ; outer_catch_land
#     try_table void (catch_all 0)            ; outer try
#       ; code between outer enter and inner enter (e.g. UpsilonNodes)
#       block void                            ; inner_catch_land
#         try_table void (catch_all 0)        ; inner try
#           ; inner try body
#           ; normal exit (return)
#         end                                 ; inner try_table
#       end                                   ; inner_catch_land
#       ; inner catch handler (INSIDE outer try — re-throws caught by outer!)
#     end                                     ; outer try_table
#   end                                       ; outer_catch_land
#   ; outer catch handler
#
function generate_nested_try_catch_2(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock},
                                     code, outer::TryRegion, inner::TryRegion)::Vector{UInt8}
    bytes = UInt8[]

    # Ensure exception infrastructure
    ensure_exception_tag!(ctx.mod)
    ensure_exception_global!(ctx.mod)

    # === Pre-outer code (stmts before outer enter) ===
    # P3 gap ae64a1ba676e: STACKIFIED, not a linear compile_statement walk —
    # vector-literal fill loops before the try never had their phi inits
    # stored (index local read 0 → array[-1] → uncatchable OOB trap).
    pre_outer = BasicBlock[]
    for b in blocks
        if b.end_idx < outer.enter_idx
            push!(pre_outer, b)
        elseif b.start_idx <= outer.enter_idx <= b.end_idx && b.start_idx < outer.enter_idx
            push!(pre_outer, BasicBlock(b.start_idx, outer.enter_idx - 1, nothing))
        end
    end
    if !isempty(pre_outer)
        append!(bytes, generate_stackified_flow(ctx, pre_outer, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end

    # === Outer catch landing block (void) ===
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)

    # === Outer try_table ===
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)  # void
    append!(bytes, encode_leb128_unsigned(1))  # 1 catch clause
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))  # → label 0 (outer catch landing)

    # Code between outer enter and inner enter — stackified for the same
    # reason (the outer try body before the inner try can hold fill loops,
    # closures over vector literals, etc.).
    # P3 gap 5954d7d85a04: a GotoIfNot between the enters that jumps OVER the
    # inner region (`try { if c { try B finally } else E } catch`) is an
    # if/else split inside the outer BODY — without handling it, the
    # stackified between-segment's out-of-subset exit fell INTO the inner
    # try_table and the else path executed the wrong arm.
    body_branch = 0
    for i in (outer.enter_idx + 1):(inner.enter_idx - 1)
        st = code[i]
        st isa Core.GotoIfNot && st.dest > inner.catch_dest && (body_branch = i; break)
    end
    body_bdest = body_branch > 0 ? (code[body_branch]::Core.GotoIfNot).dest : 0

    between = BasicBlock[]
    between_hi = body_branch > 0 ? body_branch - 1 : inner.enter_idx - 1
    for b in blocks
        lo = max(b.start_idx, outer.enter_idx + 1)
        hi = min(b.end_idx, between_hi)
        lo > hi && continue
        if lo == b.start_idx && hi == b.end_idx
            push!(between, b)
        else
            push!(between, BasicBlock(lo, hi, hi == b.end_idx ? b.terminator : nothing))
        end
    end
    if !isempty(between)
        append!(bytes, generate_stackified_flow(ctx, between, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end

    # If split: open the $else wrap — condition false branches past the
    # then-arm (the whole inner-try machinery) to the common tail.
    if body_branch > 0
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)
        append!(bytes, compile_condition_to_i32((code[body_branch]::Core.GotoIfNot).cond, ctx))
        push!(bytes, Opcode.I32_EQZ)
        push!(bytes, Opcode.BR_IF)
        append!(bytes, encode_leb128_unsigned(0))
    end

    # === Skip block: the body's NORMAL exit branches past the inner catch
    # handler (P3 g2_nest: without it, falling out of the try_table also fell
    # through the landing block END into the handler).
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)

    # === Inner catch landing block (void) ===
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x40)

    # === Inner try_table ===
    push!(bytes, Opcode.TRY_TABLE)
    push!(bytes, 0x40)  # void
    append!(bytes, encode_leb128_unsigned(1))  # 1 catch clause
    push!(bytes, Opcode.CATCH_ALL)
    append!(bytes, encode_leb128_unsigned(0))  # → label 0 (inner catch landing)

    # Inner try body + normal exit — STACKIFIED (P2-batch25, gap 3bee390c7d25):
    # the body can contain vector-literal fill loops (try/finally inlines
    # whole expressions) that the previous linear walk flattened into a single
    # pass (loop phi never initialised → oob trap). Split the block spanning
    # the inner EnterNode; everything before inner.catch_dest belongs here.
    inner_body = BasicBlock[]
    local _ib_head = nothing
    for b in blocks
        b.start_idx < inner.catch_dest || continue
        if b.start_idx > inner.enter_idx
            push!(inner_body, b)
        elseif b.start_idx <= inner.enter_idx <= b.end_idx && inner.enter_idx < b.end_idx
            _ib_head = BasicBlock(inner.enter_idx + 1, b.end_idx, b.terminator)
        end
    end
    _ib_head !== nothing && pushfirst!(inner_body, _ib_head)
    append!(bytes, generate_stackified_flow(ctx, inner_body, code))
    ctx.last_stmt_was_stub = false

    # End inner try_table
    push!(bytes, Opcode.END)

    # P3 gap 5fe789cdb92c: when the inner-normal and inner-catch paths MERGE
    # at phis before the outer catch (un-inlined invokes in the catch arm keep
    # the merge un-collapsed), the skip branch must land AT THE MERGE, not
    # after the whole inner-catch range — and both paths must store their
    # merge-phi edges (the stackified subsets can't: the phi is out of subset).
    merge_start = 0
    for i in inner.catch_dest:(outer.catch_dest - 1)
        st = code[i]
        if st isa Core.PhiNode && haskey(ctx.phi_locals, i) &&
           any(Int(e) < inner.catch_dest for e in st.edges)
            merge_start = i
            break
        end
    end

    # Normal path: store merge-phi edges (keyed below inner.catch_dest), then
    # branch past the inner catch handler to the skip-block end.
    if merge_start > 0
        for i in merge_start:(outer.catch_dest - 1)
            st = code[i]
            st isa Core.PhiNode || break
            haskey(ctx.phi_locals, i) || continue
            for (k, e) in enumerate(st.edges)
                if Int(e) < inner.catch_dest && isassigned(st.values, k)
                    emit_phi_local_set!(bytes, st.values[k], i, ctx)
                    break
                end
            end
        end
    end
    push!(bytes, Opcode.BR)
    append!(bytes, encode_leb128_unsigned(1))

    # End inner catch landing block
    push!(bytes, Opcode.END)

    # Reset dead code flag — inner catch handler is reachable
    ctx.last_stmt_was_stub = false

    # === Inner catch handler (stmts inner.catch_dest up to the merge) ===
    # This is INSIDE the outer try_table, so re-throws are caught by outer catch!
    # P3 gap ae64a1ba676e: STACKIFIED — the previous hand-rolled GotoIfNot
    # walk dropped phi-edge stores and loops, the same linear-walk class as
    # the catch arms in P3-batch6/8.
    inner_catch_hi = merge_start > 0 ? merge_start - 1 : outer.catch_dest - 1
    inner_catch = BasicBlock[]
    for b in blocks
        lo = max(b.start_idx, inner.catch_dest)
        hi = min(b.end_idx, inner_catch_hi)
        lo > hi && continue
        if lo == b.start_idx && hi == b.end_idx
            push!(inner_catch, b)
        else
            push!(inner_catch, BasicBlock(lo, hi, hi == b.end_idx ? b.terminator : nothing))
        end
    end
    if !isempty(inner_catch)
        append!(bytes, generate_stackified_flow(ctx, inner_catch, code;
                                                trailing_unreachable=false))
        ctx.last_stmt_was_stub = false
    end
    # Catch path: store merge-phi edges keyed inside the handler range.
    if merge_start > 0
        for i in merge_start:(outer.catch_dest - 1)
            st = code[i]
            st isa Core.PhiNode || break
            haskey(ctx.phi_locals, i) || continue
            for (k, e) in enumerate(st.edges)
                if inner.catch_dest <= Int(e) <= inner_catch_hi && isassigned(st.values, k)
                    emit_phi_local_set!(bytes, st.values[k], i, ctx)
                    break
                end
            end
        end
    end

    # End skip block (both paths land here, at the merge)
    push!(bytes, Opcode.END)

    # === Merge code (phis through the rest of the then-arm / outer body) ===
    _post_hi = body_branch > 0 ? min(body_bdest - 1, outer.catch_dest - 1) : outer.catch_dest - 1
    if merge_start > 0
        merge_blocks = BasicBlock[]
        for b in blocks
            lo = max(b.start_idx, merge_start)
            hi = min(b.end_idx, _post_hi)
            lo > hi && continue
            if lo == b.start_idx && hi == b.end_idx
                push!(merge_blocks, b)
            else
                push!(merge_blocks, BasicBlock(lo, hi, hi == b.end_idx ? b.terminator : nothing))
            end
        end
        if !isempty(merge_blocks)
            append!(bytes, generate_stackified_flow(ctx, merge_blocks, code;
                                                    trailing_unreachable=false))
            ctx.last_stmt_was_stub = false
        end
    end

    # Close the $else wrap and emit the common tail (else arm + shared
    # leave/return code) — the then path falls through into it as well.
    if body_branch > 0
        push!(bytes, Opcode.END)   # $else
        ctx.last_stmt_was_stub = false
        tail_blocks = BasicBlock[]
        for b in blocks
            lo = max(b.start_idx, body_bdest)
            hi = min(b.end_idx, outer.catch_dest - 1)
            lo > hi && continue
            if lo == b.start_idx && hi == b.end_idx
                push!(tail_blocks, b)
            else
                push!(tail_blocks, BasicBlock(lo, hi, hi == b.end_idx ? b.terminator : nothing))
            end
        end
        if !isempty(tail_blocks)
            append!(bytes, generate_stackified_flow(ctx, tail_blocks, code;
                                                    trailing_unreachable=false))
            ctx.last_stmt_was_stub = false
        end
    end

    # End outer try_table
    push!(bytes, Opcode.END)

    # End outer catch landing block
    push!(bytes, Opcode.END)

    # Reset dead code flag — outer catch handler is reachable
    ctx.last_stmt_was_stub = false

    # === Outer catch handler (stmts outer.catch_dest to end) ===
    # P3: stackified for the same linear-walk reasons as the inner handler.
    outer_catch = [b for b in blocks if b.start_idx >= outer.catch_dest]
    if !isempty(outer_catch)
        append!(bytes, generate_stackified_flow(ctx, outer_catch, code))
        ctx.last_stmt_was_stub = false
    end

    return bytes
end

# PURE-9031: Helper — compile a GotoIfNot inside the try body
function _compile_try_body_gotoifnot(stmt::Core.GotoIfNot, i::Int, leave_idx::Int, code, ctx::AbstractCompilationContext)::Vector{UInt8}
    bytes = UInt8[]
    else_target = stmt.dest

    append!(bytes, compile_condition_to_i32(stmt.cond, ctx))

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

    # P2-batch17: diamond/guard pattern — the then region ends with a forward
    # GotoNode OVER the else region to a merge/continuation point M. The else
    # arm is only [dest..M-1]; statements from M on are the shared continuation
    # and must run on BOTH paths. The old code compiled [dest..leave-1] as the
    # else arm, burying the whole rest of the try body inside a dead throw arm
    # (gap 6d3a1788a329 family: `Int64(try gcd(Int32(0), Int32(x)) catch Int32(0) end)`
    # returned 0 — the Int32 range-check's else arm swallowed all the gcd work).
    merge_after = _try_goto_merge_target(stmt, i, leave_idx, code)
    if !(then_has_throw || then_has_return) && merge_after !== nothing
        push!(bytes, Opcode.IF)
        push!(bytes, 0x40)
        for j in then_start:then_end
            if code[j] !== nothing
                append!(bytes, compile_statement(code[j], j, ctx))
            end
        end
        push!(bytes, Opcode.ELSE)
        for j in else_target:(merge_after-1)
            if code[j] !== nothing
                append!(bytes, compile_statement(code[j], j, ctx))
            end
        end
        push!(bytes, Opcode.END)
        ctx.last_stmt_was_stub = false
    elseif then_has_throw || then_has_return
        push!(bytes, Opcode.IF)
        push!(bytes, 0x40)
        for j in then_start:then_end
            if code[j] !== nothing
                append!(bytes, compile_statement(code[j], j, ctx))
            end
        end
        push!(bytes, Opcode.END)
        # PURE-9032: Reset dead code flag after if/end — the throw/error inside the
        # if block is a dead-end, but control resumes on the else path after end.
        ctx.last_stmt_was_stub = false
    else
        push!(bytes, Opcode.IF)
        push!(bytes, 0x40)
        for j in then_start:then_end
            if code[j] !== nothing
                append!(bytes, compile_statement(code[j], j, ctx))
            end
        end
        push!(bytes, Opcode.ELSE)
        for j in else_target:(leave_idx-1)
            if code[j] !== nothing
                append!(bytes, compile_statement(code[j], j, ctx))
            end
        end
        push!(bytes, Opcode.END)
        ctx.last_stmt_was_stub = false
    end
    return bytes
end

# PURE-9031: Helper — advance past a GotoIfNot in the try body
function _advance_past_gotoifnot(stmt::Core.GotoIfNot, i::Int, leave_idx::Int, code)::Int
    else_target = stmt.dest
    then_end = min(else_target - 1, leave_idx - 1)
    then_has_return = false
    then_has_throw = false
    for j in (i+1):then_end
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
        return else_target
    end
    # P2-batch17: diamond/guard — continue at the merge point, not the leave
    m = _try_goto_merge_target(stmt, i, leave_idx, code)
    m !== nothing && return m
    return leave_idx
end

# P2-batch17: if the then region of a try-body GotoIfNot ends with a forward
# GotoNode over the else region (label > dest), that label is the merge /
# continuation point — code from there on belongs to both paths.
function _try_goto_merge_target(stmt::Core.GotoIfNot, i::Int, leave_idx::Int, code)::Union{Int,Nothing}
    else_target = stmt.dest
    then_end = min(else_target - 1, leave_idx - 1)
    last_stmt = nothing
    for j in (i+1):then_end
        code[j] === nothing && continue
        last_stmt = code[j]
    end
    last_stmt isa Core.GotoNode || return nothing
    m = last_stmt.label
    return (m > else_target && m <= leave_idx) ? m : nothing
end

