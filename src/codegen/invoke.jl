# parity(M9): emit a string-op ARG through the funnel — classed strings adjust to
# their DATA array (op contract: these positions are strings; no type re-query).
function _emit_str_arg!(b::InstrBuilder, arg, ctx::AbstractCompilationContext, str_type_idx)
    haskey(ENV, "WT_DBG_STRARG") && println(stderr, "STRARG ", repr(arg), " :: ", typeof(arg))
    emit_value!(b, arg, ctx, ConcreteRef(UInt32(str_type_idx), true))
    return b
end

"""
Extract: str_hash(s) -> Int32. Compute string hash using Java-style: h = 31 * h + char[i].
"""
function _compile_invoke_str_hash(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

    b = InstrBuilder(; func_name="_compile_invoke_str_hash", strict=_wt_builder_strict())

    # Allocate locals for this operation
    str_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))  # string reference

    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # string length

    hash_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # running hash

    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)  # loop index

    builder_set_local_type!(b, str_local, ConcreteRef(UInt32(str_type_idx), true))
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, hash_local, I32)
    builder_set_local_type!(b, i_local, I32)

    # Store string reference
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, str_local)

    # Get length
    array_len!(b)
    local_set!(b, len_local)

    # Initialize hash = 0
    i32_const!(b, 0)
    local_set!(b, hash_local)

    # Initialize i = 0
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop over characters
    block!(b, 0x40)  # outer block for exit
    loop!(b, 0x40)  # loop

    # Check i < len
    local_get!(b, i_local)
    local_get!(b, len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break to outer block if done

    # hash = 31 * hash + char[i]
    local_get!(b, hash_local)
    i32_const!(b, 31)
    num!(b, Opcode.I32_MUL)

    # Get char at index i (0-based)
    local_get!(b, str_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)

    num!(b, Opcode.I32_ADD)

    # Mask to positive: & 0x7FFFFFFF
    i32_const!(b, 0x7FFFFFFF)
    num!(b, Opcode.I32_AND)

    local_set!(b, hash_local)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    # Continue loop
    br!(b, 0)

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # Return hash
    local_get!(b, hash_local)

    return builder_code(b)
end

"""
Extract: str_find(haystack, needle) -> Int32. Returns 1-based position or 0 if not found.
"""
function _compile_invoke_str_find(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_find", strict=_wt_builder_strict())

    # Allocate locals
    haystack_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    needle_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    haystack_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    needle_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    j_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    found_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    last_start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, haystack_local, strref)
    builder_set_local_type!(b, needle_local, strref)
    builder_set_local_type!(b, haystack_len_local, I32)
    builder_set_local_type!(b, needle_len_local, I32)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, j_local, I32)
    builder_set_local_type!(b, found_local, I32)
    builder_set_local_type!(b, result_local, I32)
    builder_set_local_type!(b, last_start_local, I32)

    # Store haystack
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, haystack_local)
    array_len!(b)
    local_set!(b, haystack_len_local)

    # Store needle
    _emit_str_arg!(b, args[2], ctx, str_type_idx)
    local_tee!(b, needle_local)
    array_len!(b)
    local_set!(b, needle_len_local)

    # Initialize result = 0
    i32_const!(b, 0)
    local_set!(b, result_local)

    # If needle_len == 0, return 1
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_EQZ)
    if_!(b, 0x40)  # void
    i32_const!(b, 1)
    local_set!(b, result_local)
    else_!(b)

    # Check if needle_len > haystack_len - skip search if so
    local_get!(b, needle_len_local)
    local_get!(b, haystack_len_local)
    num!(b, Opcode.I32_GT_S)
    if_!(b, 0x40)  # void
    # result stays 0
    else_!(b)

    # Calculate last_start = haystack_len - needle_len + 1 (1-based)
    local_get!(b, haystack_len_local)
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_SUB)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, last_start_local)

    # Initialize i = 1 (1-based)
    i32_const!(b, 1)
    local_set!(b, i_local)

    # Outer loop over haystack positions
    block!(b, 0x40)  # outer block for exit
    loop!(b, 0x40)  # outer loop

    # Check i <= last_start
    local_get!(b, i_local)
    local_get!(b, last_start_local)
    num!(b, Opcode.I32_GT_S)
    br_if!(b, 1)  # break outer block if done

    # found = 1
    i32_const!(b, 1)
    local_set!(b, found_local)

    # j = 0 (0-based index into needle)
    i32_const!(b, 0)
    local_set!(b, j_local)

    # Inner loop - compare needle chars
    block!(b, 0x40)  # inner block for break
    loop!(b, 0x40)  # inner loop

    # Check j < needle_len
    local_get!(b, j_local)
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break inner block if done

    # Compare haystack[i + j - 1] with needle[j] (0-based array access)
    local_get!(b, haystack_local)
    local_get!(b, i_local)
    local_get!(b, j_local)
    num!(b, Opcode.I32_ADD)
    i32_const!(b, 1)
    num!(b, Opcode.I32_SUB)  # i + j - 1 for 0-based
    array_get!(b, str_type_idx, I32; signed=false)

    local_get!(b, needle_local)
    local_get!(b, j_local)
    array_get!(b, str_type_idx, I32; signed=false)

    num!(b, Opcode.I32_NE)
    if_!(b, 0x40)
    # Characters don't match - set found = 0 and break
    i32_const!(b, 0)
    local_set!(b, found_local)
    br!(b, 2)  # break inner block
    end_block!(b)  # end if

    # j++
    local_get!(b, j_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, j_local)

    # Continue inner loop
    br!(b, 0)

    end_block!(b)  # end inner loop
    end_block!(b)  # end inner block

    # If found, set result = i and break outer
    local_get!(b, found_local)
    if_!(b, 0x40)
    local_get!(b, i_local)
    local_set!(b, result_local)
    br!(b, 2)  # break outer block (depth: if=0, loop=1, block=2)
    end_block!(b)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    # Continue outer loop
    br!(b, 0)

    end_block!(b)  # end outer loop
    end_block!(b)  # end outer block

    end_block!(b)  # end else (needle not too long)
    end_block!(b)  # end else (needle not empty)

    # Return result
    local_get!(b, result_local)

    return builder_code(b)
end

"""
Extract: str_contains(haystack, needle) -> Bool. Returns true if needle is found in haystack.
"""
function _compile_invoke_str_contains(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_contains", strict=_wt_builder_strict())

    # Reuse str_find implementation by comparing result > 0
    # Allocate locals
    haystack_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    needle_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    haystack_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    needle_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    j_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    found_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    last_start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, haystack_local, strref)
    builder_set_local_type!(b, needle_local, strref)
    builder_set_local_type!(b, haystack_len_local, I32)
    builder_set_local_type!(b, needle_len_local, I32)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, j_local, I32)
    builder_set_local_type!(b, found_local, I32)
    builder_set_local_type!(b, result_local, I32)
    builder_set_local_type!(b, last_start_local, I32)

    # Store haystack
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, haystack_local)
    array_len!(b)
    local_set!(b, haystack_len_local)

    # Store needle
    _emit_str_arg!(b, args[2], ctx, str_type_idx)
    local_tee!(b, needle_local)
    array_len!(b)
    local_set!(b, needle_len_local)

    # Initialize result = 0 (false)
    i32_const!(b, 0)
    local_set!(b, result_local)

    # If needle_len == 0, return true (1)
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_EQZ)
    if_!(b, 0x40)
    i32_const!(b, 1)
    local_set!(b, result_local)
    else_!(b)

    # Check if needle_len > haystack_len - return false if so
    local_get!(b, needle_len_local)
    local_get!(b, haystack_len_local)
    num!(b, Opcode.I32_GT_S)
    num!(b, Opcode.I32_EQZ)  # NOT greater
    if_!(b, 0x40)

    # Calculate last_start = haystack_len - needle_len
    local_get!(b, haystack_len_local)
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_SUB)
    local_set!(b, last_start_local)

    # Initialize i = 0 (0-based)
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Outer loop
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check i <= last_start
    local_get!(b, i_local)
    local_get!(b, last_start_local)
    num!(b, Opcode.I32_GT_S)
    br_if!(b, 1)

    # found = 1
    i32_const!(b, 1)
    local_set!(b, found_local)

    # j = 0
    i32_const!(b, 0)
    local_set!(b, j_local)

    # Inner loop
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check j < needle_len
    local_get!(b, j_local)
    local_get!(b, needle_len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)

    # Compare haystack[i + j] with needle[j]
    local_get!(b, haystack_local)
    local_get!(b, i_local)
    local_get!(b, j_local)
    num!(b, Opcode.I32_ADD)
    array_get!(b, str_type_idx, I32; signed=false)

    local_get!(b, needle_local)
    local_get!(b, j_local)
    array_get!(b, str_type_idx, I32; signed=false)

    num!(b, Opcode.I32_NE)
    if_!(b, 0x40)
    i32_const!(b, 0)
    local_set!(b, found_local)
    br!(b, 2)
    end_block!(b)

    # j++
    local_get!(b, j_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, j_local)

    br!(b, 0)

    end_block!(b)  # end inner loop
    end_block!(b)  # end inner block

    # If found, set result = 1 and break
    local_get!(b, found_local)
    if_!(b, 0x40)
    i32_const!(b, 1)
    local_set!(b, result_local)
    br!(b, 2)  # break outer block (depth: if=0, loop=1, block=2)
    end_block!(b)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)

    end_block!(b)  # end outer loop
    end_block!(b)  # end outer block

    end_block!(b)  # end if (needle not too long)
    end_block!(b)  # end else (needle not empty)

    # Return result (0 or 1 as i32, which is Bool in wasm)
    local_get!(b, result_local)

    return builder_code(b)
end

"""
Extract: str_startswith(s, prefix) -> Bool.
"""
function _compile_invoke_str_startswith(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_startswith", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    prefix_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    s_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    prefix_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, prefix_local, strref)
    builder_set_local_type!(b, s_len_local, I32)
    builder_set_local_type!(b, prefix_len_local, I32)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, result_local, I32)

    # Store s
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, s_len_local)

    # Store prefix
    _emit_str_arg!(b, args[2], ctx, str_type_idx)
    local_tee!(b, prefix_local)
    array_len!(b)
    local_set!(b, prefix_len_local)

    # Default result = 1 (true)
    i32_const!(b, 1)
    local_set!(b, result_local)

    # If prefix_len > s_len, return false
    local_get!(b, prefix_len_local)
    local_get!(b, s_len_local)
    num!(b, Opcode.I32_GT_S)
    if_!(b, 0x40)
    i32_const!(b, 0)
    local_set!(b, result_local)
    else_!(b)

    # i = 0
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check i < prefix_len
    local_get!(b, i_local)
    local_get!(b, prefix_len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)

    # Compare s[i] with prefix[i]
    local_get!(b, s_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)

    local_get!(b, prefix_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)

    num!(b, Opcode.I32_NE)
    if_!(b, 0x40)
    i32_const!(b, 0)
    local_set!(b, result_local)
    br!(b, 2)  # break out of loop
    end_block!(b)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)

    end_block!(b)  # end loop
    end_block!(b)  # end block
    end_block!(b)  # end else

    # Return result
    local_get!(b, result_local)

    return builder_code(b)
end

"""
Extract: str_endswith(s, suffix) -> Bool.
"""
function _compile_invoke_str_endswith(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_endswith", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    suffix_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    s_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    suffix_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    start_pos_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, suffix_local, strref)
    builder_set_local_type!(b, s_len_local, I32)
    builder_set_local_type!(b, suffix_len_local, I32)
    builder_set_local_type!(b, start_pos_local, I32)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, result_local, I32)

    # Store s
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, s_len_local)

    # Store suffix
    _emit_str_arg!(b, args[2], ctx, str_type_idx)
    local_tee!(b, suffix_local)
    array_len!(b)
    local_set!(b, suffix_len_local)

    # Default result = 1 (true)
    i32_const!(b, 1)
    local_set!(b, result_local)

    # If suffix_len > s_len, return false
    local_get!(b, suffix_len_local)
    local_get!(b, s_len_local)
    num!(b, Opcode.I32_GT_S)
    if_!(b, 0x40)
    i32_const!(b, 0)
    local_set!(b, result_local)
    else_!(b)

    # Calculate start_pos = s_len - suffix_len (0-based start in s)
    local_get!(b, s_len_local)
    local_get!(b, suffix_len_local)
    num!(b, Opcode.I32_SUB)
    local_set!(b, start_pos_local)

    # i = 0
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check i < suffix_len
    local_get!(b, i_local)
    local_get!(b, suffix_len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)

    # Compare s[start_pos + i] with suffix[i]
    local_get!(b, s_local)
    local_get!(b, start_pos_local)
    local_get!(b, i_local)
    num!(b, Opcode.I32_ADD)
    array_get!(b, str_type_idx, I32; signed=false)

    local_get!(b, suffix_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)

    num!(b, Opcode.I32_NE)
    if_!(b, 0x40)
    i32_const!(b, 0)
    local_set!(b, result_local)
    br!(b, 2)
    end_block!(b)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)

    end_block!(b)  # end loop
    end_block!(b)  # end block
    end_block!(b)  # end else

    # Return result
    local_get!(b, result_local)

    return builder_code(b)
end

"""
BF-2000: repeat(s, n) -> String. Repeat string s n times.
Uses WasmGC array.new_default + loop with array.copy.
"""
function _compile_invoke_str_repeat(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_repeat", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    s_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    n_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, s_len_local, I32)
    builder_set_local_type!(b, n_local, I32)
    builder_set_local_type!(b, i_local, I32)

    # Store s and get its length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, s_len_local)

    # Store n as i32
    emit_value!(b, args[2], ctx)
    n_type = infer_value_type(args[2], ctx)
    if n_type === Int64 || n_type === Int
        num!(b, Opcode.I32_WRAP_I64)
    end
    local_set!(b, n_local)

    # Create result array of size s_len * n
    local_get!(b, s_len_local)
    local_get!(b, n_local)
    num!(b, Opcode.I32_MUL)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # i = 0
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop: while i < n, copy s into result at offset i * s_len
    block!(b, 0x40)
    loop!(b, 0x40)

    # if i >= n, break
    local_get!(b, i_local)
    local_get!(b, n_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break to outer block

    # array.copy: dst=result, dst_off=i*s_len, src=s, src_off=0, len=s_len
    local_get!(b, result_local)
    # dst_off = i * s_len
    local_get!(b, i_local)
    local_get!(b, s_len_local)
    num!(b, Opcode.I32_MUL)
    # src
    local_get!(b, s_local)
    # src_off = 0
    i32_const!(b, 0)
    # len = s_len
    local_get!(b, s_len_local)
    array_copy!(b, str_type_idx, str_type_idx)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)  # continue loop

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # Return result
    local_get!(b, result_local)
    emit_string_wrap!(b, ctx)   # parity(M9): results are CLASSED strings

    return builder_code(b)
end

"""
BF-2000: lpad(s, n, c) -> String. Left-pad string s to length n with char c.
"""
function _compile_invoke_str_lpad(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_lpad", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    s_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    n_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    pad_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    c_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, s_len_local, I32)
    builder_set_local_type!(b, n_local, I32)
    builder_set_local_type!(b, pad_len_local, I32)
    builder_set_local_type!(b, c_local, I32)
    builder_set_local_type!(b, i_local, I32)

    # Store s and get its length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, s_len_local)

    # Store n as i32
    emit_value!(b, args[2], ctx)
    n_type = infer_value_type(args[2], ctx)
    if n_type === Int64 || n_type === Int
        num!(b, Opcode.I32_WRAP_I64)
    end
    local_set!(b, n_local)

    # Store pad char as i32 (convert from Julia Char encoding to UTF-8 byte)
    # Julia Char is UTF-8 left-packed in UInt32: ' ' = 0x20000000. Need byte = 0x20.
    char_arg = args[3]
    if char_arg isa Char
        # Compile-time conversion: extract codepoint directly
        i32_const!(b, Int32(UInt32(char_arg)))
    else
        # Runtime: compile_value gives Julia encoding, shift right 24 for ASCII
        emit_value!(b, char_arg, ctx)
        i32_const!(b, Int32(24))
        num!(b, Opcode.I32_SHR_U)
    end
    local_set!(b, c_local)

    # If s_len >= n, result = s (no padding)
    # Else, create padded result
    local_get!(b, s_len_local)
    local_get!(b, n_local)
    num!(b, Opcode.I32_GE_S)
    if_!(b, 0x40)  # void

    # result = s
    local_get!(b, s_local)
    local_set!(b, result_local)

    else_!(b)

    # pad_len = n - s_len
    local_get!(b, n_local)
    local_get!(b, s_len_local)
    num!(b, Opcode.I32_SUB)
    local_set!(b, pad_len_local)

    # Create result array of size n
    local_get!(b, n_local)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # Fill first pad_len chars with c using array.fill
    # array.fill: [ref, offset, value, count]
    local_get!(b, result_local)
    i32_const!(b, 0)  # offset = 0
    local_get!(b, c_local)
    local_get!(b, pad_len_local)
    array_fill!(b, str_type_idx, I32)

    # Copy s into result at offset pad_len
    # array.copy: [dst, dst_off, src, src_off, len]
    local_get!(b, result_local)
    local_get!(b, pad_len_local)
    local_get!(b, s_local)
    i32_const!(b, 0)  # src_off = 0
    local_get!(b, s_len_local)
    array_copy!(b, str_type_idx, str_type_idx)

    end_block!(b)  # end if/else

    # Return result
    local_get!(b, result_local)
    emit_string_wrap!(b, ctx)   # parity(M9): results are CLASSED strings

    return builder_code(b)
end

"""
BF-2000: rpad(s, n, c) -> String. Right-pad string s to length n with char c.
"""
function _compile_invoke_str_rpad(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_rpad", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    s_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    n_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    c_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, s_len_local, I32)
    builder_set_local_type!(b, n_local, I32)
    builder_set_local_type!(b, c_local, I32)

    # Store s and get its length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, s_len_local)

    # Store n as i32
    emit_value!(b, args[2], ctx)
    n_type = infer_value_type(args[2], ctx)
    if n_type === Int64 || n_type === Int
        num!(b, Opcode.I32_WRAP_I64)
    end
    local_set!(b, n_local)

    # Store pad char as i32 (convert from Julia Char encoding to UTF-8 byte)
    char_arg = args[3]
    if char_arg isa Char
        i32_const!(b, Int32(UInt32(char_arg)))
    else
        emit_value!(b, char_arg, ctx)
        i32_const!(b, Int32(24))
        num!(b, Opcode.I32_SHR_U)
    end
    local_set!(b, c_local)

    # If s_len >= n, result = s (no padding)
    local_get!(b, s_len_local)
    local_get!(b, n_local)
    num!(b, Opcode.I32_GE_S)
    if_!(b, 0x40)

    local_get!(b, s_local)
    local_set!(b, result_local)

    else_!(b)

    # Create result array of size n
    local_get!(b, n_local)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # Copy s into result at offset 0
    local_get!(b, result_local)
    i32_const!(b, 0)  # dst_off = 0
    local_get!(b, s_local)
    i32_const!(b, 0)  # src_off = 0
    local_get!(b, s_len_local)
    array_copy!(b, str_type_idx, str_type_idx)

    # Fill remaining with c: array.fill(result, s_len, c, n - s_len)
    local_get!(b, result_local)
    local_get!(b, s_len_local)
    local_get!(b, c_local)
    local_get!(b, n_local)
    local_get!(b, s_len_local)
    num!(b, Opcode.I32_SUB)
    array_fill!(b, str_type_idx, I32)

    end_block!(b)  # end if/else

    # Return result
    local_get!(b, result_local)
    emit_string_wrap!(b, ctx)   # parity(M9): results are CLASSED strings

    return builder_code(b)
end

"""
Extract: str_uppercase(s) -> String. Convert lowercase ASCII letters to uppercase.
"""
function _compile_invoke_str_uppercase(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_uppercase", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    c_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, c_local, I32)

    # Store s and get length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, len_local)

    # Create result string: array.new_default with same length
    local_get!(b, len_local)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # i = 0 (0-based for WASM)
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop: while i < len
    block!(b, 0x40)  # block for break
    loop!(b, 0x40)   # loop

    # Check i < len
    local_get!(b, i_local)
    local_get!(b, len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break if i >= len

    # c = s[i]
    local_get!(b, s_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)
    local_set!(b, c_local)

    # Check if c is lowercase (97 <= c <= 122)
    # If so, convert to uppercase (c - 32)
    local_get!(b, c_local)
    i32_const!(b, 97)  # 'a'
    num!(b, Opcode.I32_GE_S)
    local_get!(b, c_local)
    i32_const!(b, 122)  # 'z'
    num!(b, Opcode.I32_LE_S)
    num!(b, Opcode.I32_AND)
    if_!(b, 0x40)  # void

    # Convert to uppercase: c = c - 32
    local_get!(b, c_local)
    i32_const!(b, 0x20)  # 32
    num!(b, Opcode.I32_SUB)
    local_set!(b, c_local)

    end_block!(b)  # end if

    # result[i] = c
    local_get!(b, result_local)
    local_get!(b, i_local)
    local_get!(b, c_local)
    array_set!(b, str_type_idx, I32)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)  # continue loop

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # Return result
    local_get!(b, result_local)
    emit_string_wrap!(b, ctx)   # parity(M9): results are CLASSED strings

    return builder_code(b)
end

"""
Extract: str_lowercase(s) -> String. Convert uppercase ASCII letters to lowercase.
"""
function _compile_invoke_str_lowercase(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_lowercase", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    i_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    c_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, i_local, I32)
    builder_set_local_type!(b, c_local, I32)

    # Store s and get length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_set!(b, len_local)

    # Create result string: array.new_default with same length
    local_get!(b, len_local)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # i = 0 (0-based for WASM)
    i32_const!(b, 0)
    local_set!(b, i_local)

    # Loop: while i < len
    block!(b, 0x40)  # block for break
    loop!(b, 0x40)   # loop

    # Check i < len
    local_get!(b, i_local)
    local_get!(b, len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break if i >= len

    # c = s[i]
    local_get!(b, s_local)
    local_get!(b, i_local)
    array_get!(b, str_type_idx, I32; signed=false)
    local_set!(b, c_local)

    # Check if c is uppercase (65 <= c <= 90)
    # If so, convert to lowercase (c + 32)
    local_get!(b, c_local)
    i32_const!(b, 65)  # 'A'
    num!(b, Opcode.I32_GE_S)
    local_get!(b, c_local)
    i32_const!(b, 90)  # 'Z'
    num!(b, Opcode.I32_LE_S)
    num!(b, Opcode.I32_AND)
    if_!(b, 0x40)  # void

    # Convert to lowercase: c = c + 32
    local_get!(b, c_local)
    i32_const!(b, 0x20)  # 32
    num!(b, Opcode.I32_ADD)
    local_set!(b, c_local)

    end_block!(b)  # end if

    # result[i] = c
    local_get!(b, result_local)
    local_get!(b, i_local)
    local_get!(b, c_local)
    array_set!(b, str_type_idx, I32)

    # i++
    local_get!(b, i_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, i_local)

    br!(b, 0)  # continue loop

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # Return result
    local_get!(b, result_local)
    emit_string_wrap!(b, ctx)   # parity(M9): results are CLASSED strings

    return builder_code(b)
end

"""
Extract: str_trim(s) -> String. Remove leading and trailing ASCII whitespace.
"""
function _compile_invoke_str_trim(args, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_trim", strict=_wt_builder_strict())

    # Allocate locals
    s_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    start_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    end_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    new_len_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)
    result_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, ConcreteRef(str_type_idx))
    c_local = ctx.n_params + length(ctx.locals)
    push!(ctx.locals, I32)

    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, s_local, strref)
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, start_local, I32)
    builder_set_local_type!(b, end_local, I32)
    builder_set_local_type!(b, new_len_local, I32)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, c_local, I32)

    # Store s and get length
    _emit_str_arg!(b, args[1], ctx, str_type_idx)
    local_tee!(b, s_local)
    array_len!(b)
    local_tee!(b, len_local)

    # Check for empty string
    i32_const!(b, 0)
    num!(b, Opcode.I32_EQ)
    if_!(b, ConcreteRef(str_type_idx); results=WasmValType[strref])

    # Return empty string (the original s)
    local_get!(b, s_local)

    else_!(b)

    # start = 0 (0-based)
    i32_const!(b, 0)
    local_set!(b, start_local)

    # end = len - 1 (0-based, last valid index)
    local_get!(b, len_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_SUB)
    local_set!(b, end_local)

    # Find start: skip leading whitespace
    # while start < len && is_whitespace(s[start])
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check start < len
    local_get!(b, start_local)
    local_get!(b, len_local)
    num!(b, Opcode.I32_GE_S)
    br_if!(b, 1)  # break if start >= len

    # c = s[start]
    local_get!(b, s_local)
    local_get!(b, start_local)
    array_get!(b, str_type_idx, I32; signed=false)
    local_set!(b, c_local)

    # Check if whitespace: c == 32 || c == 9 || c == 10 || c == 13
    local_get!(b, c_local)
    i32_const!(b, 0x20)  # space
    num!(b, Opcode.I32_EQ)
    local_get!(b, c_local)
    i32_const!(b, 0x09)  # tab
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)
    local_get!(b, c_local)
    i32_const!(b, 0x0a)  # newline
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)
    local_get!(b, c_local)
    i32_const!(b, 0x0d)  # carriage return
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)

    # If not whitespace, break
    num!(b, Opcode.I32_EQZ)
    br_if!(b, 1)

    # start++
    local_get!(b, start_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, start_local)

    br!(b, 0)  # continue

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # Check if all whitespace (start >= len)
    local_get!(b, start_local)
    local_get!(b, len_local)
    num!(b, Opcode.I32_GE_S)
    if_!(b, ConcreteRef(str_type_idx); results=WasmValType[strref])

    # Return empty string
    i32_const!(b, 0)
    array_new_default!(b, str_type_idx)

    else_!(b)

    # Find end: skip trailing whitespace
    # while end >= start && is_whitespace(s[end])
    block!(b, 0x40)
    loop!(b, 0x40)

    # Check end >= start
    local_get!(b, end_local)
    local_get!(b, start_local)
    num!(b, Opcode.I32_LT_S)
    br_if!(b, 1)  # break if end < start

    # c = s[end]
    local_get!(b, s_local)
    local_get!(b, end_local)
    array_get!(b, str_type_idx, I32; signed=false)
    local_set!(b, c_local)

    # Check if whitespace
    local_get!(b, c_local)
    i32_const!(b, 0x20)
    num!(b, Opcode.I32_EQ)
    local_get!(b, c_local)
    i32_const!(b, 0x09)
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)
    local_get!(b, c_local)
    i32_const!(b, 0x0a)
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)
    local_get!(b, c_local)
    i32_const!(b, 0x0d)
    num!(b, Opcode.I32_EQ)
    num!(b, Opcode.I32_OR)

    # If not whitespace, break
    num!(b, Opcode.I32_EQZ)
    br_if!(b, 1)

    # end--
    local_get!(b, end_local)
    i32_const!(b, 1)
    num!(b, Opcode.I32_SUB)
    local_set!(b, end_local)

    br!(b, 0)

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # new_len = end - start + 1
    local_get!(b, end_local)
    local_get!(b, start_local)
    num!(b, Opcode.I32_SUB)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, new_len_local)

    # Create result array
    local_get!(b, new_len_local)
    array_new_default!(b, str_type_idx)
    local_set!(b, result_local)

    # array.copy: result[0..new_len] = s[start..start+new_len]
    local_get!(b, result_local)
    i32_const!(b, 0)  # dst_offset = 0
    local_get!(b, s_local)
    local_get!(b, start_local)  # src_offset = start
    local_get!(b, new_len_local)  # length
    array_copy!(b, str_type_idx, str_type_idx)

    # Return result
    local_get!(b, result_local)

    end_block!(b)  # end else (not all whitespace)
    end_block!(b)  # end else (not empty)
    emit_string_wrap!(b, ctx)   # parity(M9): the result is a CLASSED string

    return builder_code(b)
end

"""
Extract: println/print handler. Emits JS IO bridge imports.
"""
function _compile_invoke_print(name::Symbol, args, ctx::AbstractCompilationContext)::Vector{UInt8}
    io = get_io_imports()
    if io !== nothing
        b = InstrBuilder(; func_name="_compile_invoke_print", mod=ctx.mod)
        for arg in args
            # Determine argument type
            arg_type = nothing
            if arg isa Core.SSAValue
                arg_type = ctx.code_info.ssavaluetypes[arg.id]
            elseif arg isa Core.Argument
                slot_id = arg.n
                arg_type = ctx.code_info.slottypes[slot_id]
            elseif arg isa String || arg isa Symbol
                arg_type = String
            elseif arg isa Int64 || arg isa Int32 || arg isa Int
                arg_type = typeof(arg)
            elseif arg isa Float64 || arg isa Float32
                arg_type = typeof(arg)
            elseif arg isa Bool
                arg_type = Bool
            elseif arg isa Nothing || arg === nothing || (arg isa GlobalRef && arg.name === :nothing)
                arg_type = Nothing
            elseif arg isa Tuple
                arg_type = typeof(arg)
            elseif arg isa Vector
                arg_type = typeof(arg)
            end

            if arg_type === String || arg_type === Symbol
                # String: compile value, convert to JS string via decoder, call write_string
                emit_value!(b, arg, ctx)
                # Need a temp local for tee
                tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                _sb = UInt8[]; emit_jl_string_to_js!(_sb, io.decode_idx, tmp_local); emit_raw!(b, _sb; pops=1, pushes=WasmValType[ExternRef])
                # (ref extern) is subtype of externref — no conversion needed
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                emit_value!(b, arg, ctx)
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Int32
                emit_value!(b, arg, ctx)
                num!(b, Opcode.I64_EXTEND_I32_S)
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Float64
                emit_value!(b, arg, ctx)
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Float32
                emit_value!(b, arg, ctx)
                num!(b, Opcode.F64_PROMOTE_F32)
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Bool
                emit_value!(b, arg, ctx)
                call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
            elseif arg_type === Nothing
                # PURE-9041: println(nothing) → write "nothing"
                call!(b, io.write_nothing_idx, WasmValType[], WasmValType[])
            elseif arg_type !== nothing && arg_type <: Vector
                # PURE-9067: Vector display — emit "[e1, e2, ...]"
                elem_type = eltype(arg_type)

                # Register vector type to get struct info
                vec_info = register_vector_type!(ctx.mod, ctx.type_registry, arg_type)
                vec_type_idx = vec_info.wasm_type_idx
                data_array_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Compile the vector value onto stack
                emit_value!(b, arg, ctx)

                # Allocate locals: vec_ref, data_arr, len, i, tmp_str
                vec_local = UInt32(allocate_local!(ctx, ConcreteRef(vec_type_idx, true)))
                data_local = UInt32(allocate_local!(ctx, ConcreteRef(data_array_idx, true)))
                len_local = UInt32(allocate_local!(ctx, I32))
                i_local = UInt32(allocate_local!(ctx, I32))
                str_tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))

                # Store vec ref
                local_set!(b, vec_local)

                # Get data array: struct.get field 1 (after typeId at field 0)
                local_get!(b, vec_local)
                struct_get!(b, vec_type_idx, UInt32(1), ConcreteRef(UInt32(data_array_idx), true))  # field 1 = data array
                local_set!(b, data_local)

                # Get length: array.len
                local_get!(b, data_local)
                array_len!(b)
                local_set!(b, len_local)

                # Write "["
                emit_value!(b, "[", ctx)
                _sb = UInt8[]; emit_jl_string_to_js!(_sb, io.decode_idx, str_tmp_local); emit_raw!(b, _sb; pops=1, pushes=WasmValType[ExternRef])
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])

                # Initialize i = 0
                i32_const!(b, 0)
                local_set!(b, i_local)

                # Loop: block { loop { ... } }
                block!(b, 0x40)   # block (label 1 = break)
                loop!(b, 0x40)    # loop (label 0 = continue)

                # if i >= len, break
                local_get!(b, i_local)
                local_get!(b, len_local)
                num!(b, Opcode.I32_GE_S)
                br_if!(b, 1)  # break to outer block

                # if i > 0, write ", "
                local_get!(b, i_local)
                i32_const!(b, 0)
                num!(b, Opcode.I32_NE)
                if_!(b, 0x40)  # void
                emit_value!(b, ", ", ctx)
                _sb2 = UInt8[]; emit_jl_string_to_js!(_sb2, io.decode_idx, str_tmp_local); emit_raw!(b, _sb2; pops=1, pushes=WasmValType[ExternRef])
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                end_block!(b)  # end if

                # Get element: data_arr[i]
                local_get!(b, data_local)
                local_get!(b, i_local)
                _elem_wt = (elem_type === Float64) ? F64 : (elem_type === Float32) ? F32 :
                           (elem_type === Int64 || elem_type === Int || elem_type === UInt64) ? I64 : I32
                array_get!(b, data_array_idx, _elem_wt; signed=(elem_type === UInt8 ? false : nothing))

                # Display element based on element type
                if elem_type === Int32
                    num!(b, Opcode.I64_EXTEND_I32_S)
                    call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                elseif elem_type === Int64 || elem_type === Int || elem_type === UInt64
                    call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                elseif elem_type === Float64
                    call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                elseif elem_type === Float32
                    num!(b, Opcode.F64_PROMOTE_F32)
                    call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                elseif elem_type === Bool
                    call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
                else
                    # Unsupported element type — just write "?"
                    drop!(b)
                    emit_value!(b, "?", ctx)
                    _sb3 = UInt8[]; emit_jl_string_to_js!(_sb3, io.decode_idx, str_tmp_local); emit_raw!(b, _sb3; pops=1, pushes=WasmValType[ExternRef])
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                end

                # i += 1
                local_get!(b, i_local)
                i32_const!(b, 1)
                num!(b, Opcode.I32_ADD)
                local_set!(b, i_local)

                # Branch back to loop
                br!(b, 0)  # continue loop

                end_block!(b)  # end loop
                end_block!(b)  # end block

                # Write "]"
                emit_value!(b, "]", ctx)
                _sb4 = UInt8[]; emit_jl_string_to_js!(_sb4, io.decode_idx, str_tmp_local); emit_raw!(b, _sb4; pops=1, pushes=WasmValType[ExternRef])
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type !== nothing && arg_type <: Tuple && arg_type isa DataType
                # PURE-9067: Tuple display — emit "(e1, e2, ...)"
                tuple_info = register_tuple_type!(ctx.mod, ctx.type_registry, arg_type)
                if tuple_info !== nothing
                    tuple_type_idx = tuple_info.wasm_type_idx
                    elem_types = arg_type.parameters

                    # Compile tuple value and store in local
                    emit_value!(b, arg, ctx)
                    tup_local = UInt32(allocate_local!(ctx, ConcreteRef(tuple_type_idx, true)))
                    str_tmp_local2 = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                    local_set!(b, tup_local)

                    # Write "("
                    emit_value!(b, "(", ctx)
                    _tb1 = UInt8[]; emit_jl_string_to_js!(_tb1, io.decode_idx, str_tmp_local2); emit_raw!(b, _tb1; pops=1, pushes=WasmValType[ExternRef])
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])

                    for (fi, et) in enumerate(elem_types)
                        # Write ", " separator (after first element)
                        if fi > 1
                            emit_value!(b, ", ", ctx)
                            _tb2 = UInt8[]; emit_jl_string_to_js!(_tb2, io.decode_idx, str_tmp_local2); emit_raw!(b, _tb2; pops=1, pushes=WasmValType[ExternRef])
                            call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                        end

                        # Get field: struct.get (field index = fi because of typeId at 0)
                        local_get!(b, tup_local)
                        _et_wt = (et === Float64) ? F64 : (et === Float32) ? F32 :
                                 (et === Int64 || et === Int || et === UInt64) ? I64 : I32
                        struct_get!(b, tuple_type_idx, UInt32(fi), _et_wt)  # field fi (1-based = after typeId)

                        # Write element based on type
                        if et === Int32
                            num!(b, Opcode.I64_EXTEND_I32_S)
                            call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                        elseif et === Int64 || et === Int || et === UInt64
                            call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
                        elseif et === Float64
                            call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                        elseif et === Float32
                            num!(b, Opcode.F64_PROMOTE_F32)
                            call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
                        elseif et === Bool
                            call!(b, io.write_bool_idx, WasmValType[I32], WasmValType[])
                        else
                            drop!(b)
                            emit_value!(b, "?", ctx)
                            _tb3 = UInt8[]; emit_jl_string_to_js!(_tb3, io.decode_idx, str_tmp_local2); emit_raw!(b, _tb3; pops=1, pushes=WasmValType[ExternRef])
                            call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                        end
                    end

                    # Single-element tuple gets trailing comma: (1,)
                    if length(elem_types) == 1
                        emit_value!(b, ",", ctx)
                        _tb4 = UInt8[]; emit_jl_string_to_js!(_tb4, io.decode_idx, str_tmp_local2); emit_raw!(b, _tb4; pops=1, pushes=WasmValType[ExternRef])
                        call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                    end

                    # Write ")"
                    emit_value!(b, ")", ctx)
                    _tb5 = UInt8[]; emit_jl_string_to_js!(_tb5, io.decode_idx, str_tmp_local2); emit_raw!(b, _tb5; pops=1, pushes=WasmValType[ExternRef])
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                else
                    @debug "println/print: unsupported Tuple type $arg_type, skipping"
                end
            else
                # Unknown type — skip (stub)
                @debug "println/print: unsupported argument type $arg_type, skipping"
            end
        end
        if name === :println
            call!(b, io.write_newline_idx, WasmValType[], WasmValType[])
        end
        return builder_code(b)
    else
        # No IO imports — stub as no-op
        return UInt8[]
    end
end

"""
Compile an invoke expression (method invocation).
"""
function compile_invoke(expr::Expr, idx::Int, ctx::AbstractCompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Early skip check — before compiling arguments.
    # Skipped statements emit nothing (NOP). This prevents argument values
    # (e.g., string constants for js() calls) from being compiled to WASM.
    if idx in ctx.skip_stmts
        return bytes
    end

    # Invoke import check — emit CALL to a WASM import function.
    # Used by Therapy.jl to wire js() calls as WASM imports (Leptos pattern).
    if haskey(ctx.invoke_imports, idx)
        import_idx = ctx.invoke_imports[idx]
        bii = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
        call!(bii, import_idx, WasmValType[], WasmValType[])
        return builder_code(bii)
    end

    args = expr.args[3:end]


    # Check for signal substitution (Therapy.jl closures)
    # When calling through a captured signal getter/setter, emit global.get/set directly
    func_ref = expr.args[2]
    if func_ref isa Core.SSAValue
        ssa_id = func_ref.id
        # Signal getter: no args, returns the signal value
        if haskey(ctx.signal_ssa_getters, ssa_id) && isempty(args)
            global_idx = ctx.signal_ssa_getters[ssa_id]
            bsg = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
            global_get!(bsg, global_idx, AnyRef)
            return builder_code(bsg)
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            bss2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
            # Compile the argument (the new value)
            emit_value!(bss2, args[1], ctx)
            # Store to global
            global_set!(bss2, global_idx)

            # Inject DOM update calls for this signal (Therapy.jl reactive updates)
            if haskey(ctx.dom_bindings, global_idx)
                # Get global's type for conversion
                global_type = ctx.mod.globals[global_idx + 1].valtype

                for (import_idx, const_args) in ctx.dom_bindings[global_idx]
                    # Push constant arguments (e.g., hydration key)
                    for arg in const_args
                        i32_const!(bss2, Int(arg))
                    end
                    # Push the signal value (re-read from global)
                    global_get!(bss2, global_idx, AnyRef)
                    # Convert to f64 for DOM imports (all DOM imports expect f64)
                    emit_raw!(bss2, emit_convert_to_f64(global_type); pops=1, pushes=WasmValType[F64])
                    # Call the DOM import function
                    call!(bss2, import_idx, WasmValType[], WasmValType[])
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            global_get!(bss2, global_idx, AnyRef)
            return builder_code(bss2)
        end
    end

    # Get MethodInstance to check parameter types for nothing arguments
    mi_or_ci = expr.args[1]
    mi = if mi_or_ci isa Core.MethodInstance
        mi_or_ci
    elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
        mi_or_ci.def
    else
        nothing
    end

    # Early self-call detection: check if this is a recursive call to ourselves
    func_ref_early = expr.args[2]
    actual_func_ref_early = func_ref_early
    if func_ref_early isa Core.SSAValue
        ssa_stmt = ctx.code_info.code[func_ref_early.id]
        if ssa_stmt isa GlobalRef
            actual_func_ref_early = ssa_stmt
        elseif ssa_stmt isa Core.PiNode && ssa_stmt.val isa Core.SSAValue
            # Follow PiNode chain
            pi_ssa_stmt = ctx.code_info.code[ssa_stmt.val.id]
            if pi_ssa_stmt isa GlobalRef
                actual_func_ref_early = pi_ssa_stmt
            end
        elseif ssa_stmt isa Expr && ssa_stmt.head === :invoke
            # Nested invoke — try to get the function from the method instance
            nested_mi = ssa_stmt.args[1]
            if nested_mi isa Core.MethodInstance
                # Can't easily get GlobalRef from MI, but we can try to use the function name
                if hasfield(typeof(nested_mi.def), :name) && nested_mi.def isa Method
                    # Create a synthetic GlobalRef for lookup
                    # This is a workaround; the proper way would be to use mi directly
                end
            end
        end
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa GlobalRef
        actual_func_ref_early = func_ref_early.val
    elseif func_ref_early isa Core.PiNode && func_ref_early.val isa Core.SSAValue
        pi_ssa_stmt = ctx.code_info.code[func_ref_early.val.id]
        if pi_ssa_stmt isa GlobalRef
            actual_func_ref_early = pi_ssa_stmt
        end
    elseif func_ref_early isa Core.Argument
        # PURE-220: Higher-order function calls — extract function from mi.specTypes
        if mi isa Core.MethodInstance
            spec = mi.specTypes
            if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                func_type = spec.parameters[1]
                if func_type isa DataType
                    try
                        actual_func_ref_early = func_type.instance
                    catch; end
                end
            end
        end
    end
    is_self_call_early = false
    if ctx.func_ref !== nothing && actual_func_ref_early isa GlobalRef
        try
            called_func = getfield(actual_func_ref_early.mod, actual_func_ref_early.name)
            if called_func === ctx.func_ref
                # PURE-220: Also check arity — overloaded methods share the same function
                # object but have different specTypes. A call to a different overload is NOT
                # a self-call (e.g., parse_comma(ps) calling parse_comma(ps, true)).
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple
                        call_nargs = length(spec.parameters) - 1  # subtract typeof(func)
                        # PURE-047: Check both arity AND parameter types — same-arity overloads
                        # (e.g., validate_code!(errors, mi, c) vs validate_code!(errors, c, bool))
                        # share the function object and arity but have different specTypes.
                        if call_nargs == length(ctx.arg_types)
                            call_arg_types = spec.parameters[2:end]
                            is_self_call_early = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                        else
                            is_self_call_early = false
                        end
                    else
                        is_self_call_early = true
                    end
                else
                    is_self_call_early = true
                end
            end
        catch
            is_self_call_early = false
        end
    end

    # Get parameter types - for self-calls, use ctx.arg_types (the function's compiled signature)
    # For other calls, use mi.specTypes (the call site's specialized types)
    param_types = nothing
    if is_self_call_early
        # Self-call: use the function's actual compiled parameter types
        param_types = ctx.arg_types
    elseif mi isa Core.MethodInstance
        spec = mi.specTypes
        if spec isa DataType && spec <: Tuple
            # specTypes is Tuple{typeof(func), arg1_type, arg2_type, ...}
            # We want arg types starting from index 2
            param_types = spec.parameters[2:end]
        end
    end

    # PURE-036z: Compute target_info EARLY so we can use its arg_types for proper type checking
    # during argument compilation. This helps when param_types (from mi.specTypes) differ from
    # the actual compiled function's parameter types.
    target_info_early = nothing
    closure_self_to_push = nothing   # 453393ca4ba4: see below
    if ctx.func_registry !== nothing && !is_self_call_early
        called_func_early = nothing
        if actual_func_ref_early isa GlobalRef
            called_func_early = try
                getfield(actual_func_ref_early.mod, actual_func_ref_early.name)
            catch
                nothing
            end
        elseif actual_func_ref_early isa Function
            # PURE-209a: func_ref can be a Function object directly (default-arg methods)
            called_func_early = actual_func_ref_early
        elseif mi isa Core.MethodInstance && mi.def isa Method
            # Fallback: get function from MethodInstance
            # The function is typically the first arg in specTypes
            spec = mi.specTypes
            if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                func_type = spec.parameters[1]
                if func_type isa DataType && func_type.name.name === :typeof
                    # typeof(f) — extract f
                    # The instance of typeof(f) is the function itself
                    try
                        called_func_early = func_type.instance
                    catch
                        # Couldn't get instance
                    end
                end
            end
        end
        if called_func_early !== nothing
            call_arg_types_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            _exp_ret = get(ctx.ssa_types, idx, nothing)
            target_info_early = get_function(ctx.func_registry, called_func_early, call_arg_types_early;
                                             expected_return=_exp_ret isa Type ? _exp_ret : nothing)
            # PURE-320: Closure/kwarg functions are registered with self-type prepended
            if target_info_early === nothing && typeof(called_func_early) <: Function && isconcretetype(typeof(called_func_early))
                closure_arg_types_early = (typeof(called_func_early), call_arg_types_early...)
                target_info_early = get_function(ctx.func_registry, called_func_early, closure_arg_types_early)
                # 453393ca4ba4: a CAPTURING closure entry takes the closure object as
                # wasm param 1 — the call site must push it (Snapshot.jl newton C-W3:
                # 6 values for a 7-param functype → "nothing on stack")
                if target_info_early !== nothing && is_closure_type(typeof(called_func_early))
                    closure_self_to_push = actual_func_ref_early
                end
            end
        end
    end

    # 453393ca4ba4: capturing-closure callees — the function position is a VALUE
    # (SSA/argument/local); identity-keyed registry lookup can never match the
    # runtime-constructed instance, so the invoke silently fell through to an
    # `unreachable` (Snapshot.jl newton C-W3). Resolve by TYPE against the
    # self-prepended signature and push the closure object as wasm param 1.
    get(ENV, "WT_DBG_CLOSURE", "") == "1" &&
        println(stderr, "CLOSDBG ref=", repr(actual_func_ref_early), " :: ", typeof(actual_func_ref_early),
                " ti_early=", target_info_early !== nothing)
    if target_info_early === nothing && ctx.func_registry !== nothing && !is_self_call_early &&
       actual_func_ref_early !== nothing && !(actual_func_ref_early isa GlobalRef)
        ft_early = try
            infer_value_type(actual_func_ref_early, ctx)
        catch
            nothing
        end
        if ft_early isa DataType && is_closure_type(ft_early)
            cat_early = tuple([infer_value_type(arg, ctx) for arg in args]...)
            ti = get_function_by_argtypes(ctx.func_registry, (ft_early, cat_early...))
            get(ENV, "WT_DBG_CLOSURE", "") == "1" &&
                println(stderr, "CLOSDBG bytype ft=", ft_early, " cat=", cat_early, " hit=", ti !== nothing)
            if ti !== nothing
                target_info_early = ti
                closure_self_to_push = actual_func_ref_early
            end
        end
    end
    # self-prepended entries: arg_types are shifted +1 relative to `args`
    early_argtypes_offset = closure_self_to_push === nothing ? 0 : 1

    # ================================================================
    # Early dispatch: Julia Base string operations → str_* intrinsics
    # These must run BEFORE the pre-push loop to avoid side effects
    # from compiling unwanted arguments (e.g., function singleton structs).
    # ================================================================
    if mi isa Core.MethodInstance
        meth_early = mi.def
        if meth_early isa Method
            _name_early = meth_early.name
            _spec_early = mi.specTypes

            # map(typeof(lowercase), String) → str_lowercase
            # map(typeof(uppercase), String) → str_uppercase
            if _name_early === :map && length(args) == 2 &&
               _spec_early isa DataType && _spec_early <: Tuple && length(_spec_early.parameters) >= 2
                _func_param = _spec_early.parameters[2]
                if _func_param === typeof(lowercase)
                    @info "DISPATCH: map(lowercase, String) → str_lowercase" args_2=args[2] args_2_type=typeof(args[2])
                    return _compile_invoke_str_lowercase([args[2]], ctx)
                elseif _func_param === typeof(uppercase)
                    return _compile_invoke_str_uppercase([args[2]], ctx)
                end
            end

            # _searchindex(String, String, Int64) → str_find (returns I32, widen to I64)
            if _name_early === :_searchindex && length(args) == 3
                bsi = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                emit_raw!(bsi, _compile_invoke_str_find([args[1], args[2]], ctx); pushes=WasmValType[I32])
                num!(bsi, Opcode.I64_EXTEND_I32_S)
                return builder_code(bsi)
            end

            # BF-4000: #string#403(base, pad, typeof(string), x) → inline dec call
            # String interpolation "$x" and string(x::Integer) go through this kwarg method.
            # The typeof(string) arg is phantom (never used in body). Redirect to dec().
            if _name_early === Symbol("#string#403") && length(args) == 4 &&
               ctx.func_registry !== nothing
                _dec_info = get_function(ctx.func_registry, Base.dec, (UInt64, Int64, Bool))
                if _dec_info !== nothing
                    bd = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    _x = args[4]  # the integer value

                    # Push abs(x) as I64 (same bits as UInt64): select(x, -x, x >= 0)
                    emit_value!(bd, _x, ctx)  # x (true branch)
                    i64_const!(bd, 0)                                   # 0
                    emit_value!(bd, _x, ctx)  # x
                    num!(bd, Opcode.I64_SUB)                            # -x (false branch)
                    emit_value!(bd, _x, ctx)  # x
                    i64_const!(bd, 0)                                   # 0
                    num!(bd, Opcode.I64_GE_S)                           # x >= 0 (i32 condition)
                    select!(bd)                                         # abs(x)

                    # Push pad (arg 2)
                    emit_value!(bd, args[2], ctx)

                    # Push x < 0 as i32 Bool
                    emit_value!(bd, _x, ctx)
                    i64_const!(bd, 0)
                    num!(bd, Opcode.I64_LT_S)

                    # Call dec
                    call!(bd, _dec_info.wasm_idx, WasmValType[], WasmValType[])
                    return builder_code(bd)
                end
            end

            # lstrip/rstrip(typeof(isspace), String) → str_trim
            if (_name_early === :lstrip || _name_early === :rstrip) && length(args) == 2 &&
               _spec_early isa DataType && _spec_early <: Tuple && length(_spec_early.parameters) >= 2
                _func_param = _spec_early.parameters[2]
                if _func_param === typeof(isspace)
                    return _compile_invoke_str_trim([args[2]], ctx)
                end
            end

            # startswith(String, String) → str_startswith
            if _name_early === :startswith && length(args) == 2
                return _compile_invoke_str_startswith([args[1], args[2]], ctx)
            end

            # endswith(String, String) → str_endswith
            if _name_early === :endswith && length(args) == 2
                return _compile_invoke_str_endswith([args[1], args[2]], ctx)
            end

            # BF-2000: repeat(String, Int64) → str_repeat
            if _name_early === :repeat && length(args) == 2
                # P6-trim: repeat(::Char, n) — the pad path inside the real Base
                # lpad/rpad bodies (now trim-compiled). Char is UTF-8 left-packed
                # in UInt32 (' ' = 0x20000000): byte = char >> 24, then a
                # byte-filled array.new (same single-byte assumption as str_lpad).
                local _rep_at = try infer_value_type(args[1], ctx) catch; nothing end
                if _rep_at === Char
                    br = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    str_t = get_string_array_type!(ctx.mod, ctx.type_registry)
                    emit_value!(br, args[1], ctx)  # char i32 (left-packed)
                    i32_const!(br, 24)
                    num!(br, Opcode.I32_SHR_U)                    # utf8 byte
                    emit_value!(br, args[2], ctx)  # count i64
                    num!(br, Opcode.I32_WRAP_I64)
                    array_new!(br, str_t, I32)                    # fill (value, len)
                    return builder_code(br)
                end
                return _compile_invoke_str_repeat([args[1], args[2]], ctx)
            end

            # BF-2000: lpad(String, Int64, Char) → str_lpad
            if _name_early === :lpad && length(args) == 3
                return _compile_invoke_str_lpad([args[1], args[2], args[3]], ctx)
            end

            # BF-2000: rpad(String, Int64, Char) → str_rpad
            if _name_early === :rpad && length(args) == 3
                return _compile_invoke_str_rpad([args[1], args[2], args[3]], ctx)
            end
        end
    end

    # 453393ca4ba4: closure callee — the compiled function takes the closure
    # object as wasm param 1; push it before the explicit args
    if closure_self_to_push !== nothing
        append!(bytes, compile_value(closure_self_to_push, ctx))  # god-fn seam: typed when the caller goes builder-native (M4 tail)
    end

    # Push arguments (for non-signal calls)
    # PURE-044: Track which args had extern.convert_any emitted to avoid double conversion
    extern_convert_emitted_args = falses(length(args))
    for (arg_idx, arg) in enumerate(args)
        # PURE-036z: Track if extern.convert_any was already emitted for this arg
        # to avoid double conversion (externref → externref fails because externref not subtype of anyref)
        extern_convert_emitted = false

        # Check if this is a nothing argument that needs ref.null
        # PURE-044: Also check PiNode with typ === Nothing (Union dispatch pattern)
        is_nothing_arg = arg === nothing ||
                        (arg isa GlobalRef && arg.name === :nothing) ||
                        (arg isa Core.SSAValue && begin
                            ssa_stmt = ctx.code_info.code[arg.id]
                            (ssa_stmt isa GlobalRef && ssa_stmt.name === :nothing) ||
                            (ssa_stmt isa Core.PiNode && ssa_stmt.typ === Nothing)
                        end)

        # PURE-044: Also check if param_types expects Nothing (Union dispatch to different signatures)
        # This handles the case where the arg is a phi value but param expects Nothing (i32)
        if !is_nothing_arg && param_types !== nothing && arg_idx <= length(param_types)
            param_type = param_types[arg_idx]
            if param_type === Nothing
                is_nothing_arg = true
            end
        end

        if is_nothing_arg && param_types !== nothing && arg_idx <= length(param_types)
            # Get the parameter type from the method signature
            param_type = param_types[arg_idx]
            wasm_type = julia_to_wasm_type_concrete(param_type, ctx)
            # Emit the appropriate null/zero value based on the wasm type
            _nb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
            if wasm_type isa ConcreteRef
                ref_null!(_nb, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
            elseif wasm_type === ExternRef
                ref_null!(_nb, ExternRef)
            elseif wasm_type === AnyRef
                ref_null!(_nb, AnyRef)
            elseif wasm_type === StructRef
                ref_null!(_nb, StructRef)
            elseif wasm_type === ArrayRef
                ref_null!(_nb, ArrayRef)
            elseif wasm_type === I64
                i64_const!(_nb, 0)
            elseif wasm_type === F32
                f32_const!(_nb, 0.0)
            elseif wasm_type === F64
                f64_const!(_nb, 0.0)
            else
                # I32 or other — push i32(0)
                i32_const!(_nb, 0)
            end
            append!(bytes, builder_code(_nb))
        elseif is_nothing_arg
            # Nothing arg without param_types — emit ref.null anyref as safe default
            # PURE-9022: Use anyref (not externref) for internal polymorphic positions
            _nb2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
            ref_null!(_nb2, AnyRef)
            append!(bytes, builder_code(_nb2))
        else
            arg_bytes, arg_ty = compile_value_typed(arg, ctx)
            # P6-ioprint: function/type singleton args compile to EMPTY bytes, but
            # trim-collected callees keep the param in their wasm signature (legacy
            # discovery skipped such functions entirely, so this never fired before).
            # Push ref.null of the param's wasm type to keep the call aligned.
            if isempty(arg_bytes) && param_types !== nothing && arg_idx <= length(param_types)
                local _sp_jt = try infer_value_type(arg, ctx) catch; nothing end
                if _sp_jt isa DataType && Base.issingletontype(_sp_jt)
                    local _sp_pt = param_types[arg_idx]
                    local _sp_w = get_concrete_wasm_type(_sp_pt isa Type ? _sp_pt : _sp_jt,
                                                         ctx.mod, ctx.type_registry)
                    local _spb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    if _sp_w isa ConcreteRef
                        ref_null!(_spb, Int64(_sp_w.type_idx), ConcreteRef(UInt32(_sp_w.type_idx), true))
                        append!(bytes, builder_code(_spb))
                    elseif _sp_w === AnyRef || _sp_w === StructRef || _sp_w === ExternRef || _sp_w === EqRef
                        ref_null!(_spb, _sp_w)
                        append!(bytes, builder_code(_spb))
                    end
                end
            end
            append!(bytes, arg_bytes)
            # Check if argument's actual Wasm type matches expected param type
            # If both are ConcreteRef but with different type indices, insert ref.cast
            if param_types !== nothing && arg_idx <= length(param_types)
                expected_julia_type = param_types[arg_idx]
                # Skip non-Type values (e.g., Vararg markers)
                if expected_julia_type isa Type
                    expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                    actual_julia_type = infer_value_type(arg, ctx)
                    actual_wasm = get_concrete_wasm_type(actual_julia_type, ctx.mod, ctx.type_registry)
                    # P4-stdlib (Random hash_seed): the type-derived guess says
                    # I64 for Union{Nothing, UInt64}, but such SSAs live in
                    # AnyRef locals (boxed) — use the ACTUAL local type so the
                    # bridging below sees the real representation.
                    if arg isa Core.SSAValue
                        local _ivl = get(ctx.ssa_locals, arg.id, nothing)
                        _ivl === nothing && (_ivl = get(ctx.phi_locals, arg.id, nothing))
                        if _ivl !== nothing
                            local _ivo = _ivl - ctx.n_params
                            if _ivo >= 0 && _ivo < length(ctx.locals)
                                actual_wasm = ctx.locals[_ivo + 1]
                            end
                        end
                    end

                    # PURE-3111/4155: Handle Nothing→ref conversion.
                    # compile_value emits i32_const 0 for Nothing,
                    # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                    # otherwise bridging tries conversions on an i32 value.
                    # NOTE: Type{T} no longer needs this — it now emits global.get (DataType ref).
                    _is_phantom = actual_julia_type === Nothing
                    if _is_phantom && (expected_wasm isa ConcreteRef || expected_wasm === ExternRef || expected_wasm === StructRef || expected_wasm === AnyRef)
                        if length(arg_bytes) == 2 && arg_bytes[1] == Opcode.I32_CONST && arg_bytes[2] == 0x00
                            # Remove the i32_const 0 we just appended
                            for _ in 1:2
                                pop!(bytes)
                            end
                            # Emit ref.null with the expected type
                            local _phb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                            if expected_wasm isa ConcreteRef
                                ref_null!(_phb, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                            else
                                ref_null!(_phb, expected_wasm)
                            end
                            append!(bytes, builder_code(_phb))
                            # Update actual_wasm so bridging logic below is a no-op
                            actual_wasm = expected_wasm
                        end
                    end

                    if expected_wasm isa ConcreteRef && actual_wasm isa ConcreteRef
                        if expected_wasm.type_idx != actual_wasm.type_idx
                            # Different ref types — insert ref.cast null to expected type
                            local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                            ref_cast!(_cvb, Int64(expected_wasm.type_idx), true)
                            append!(bytes, builder_code(_cvb))
                        end
                    elseif expected_wasm isa ConcreteRef && (actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === AnyRef)
                        # Abstract ref to concrete ref — insert ref.cast null
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        ref_cast!(_cvb, Int64(expected_wasm.type_idx), true)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm isa ConcreteRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                        # PURE-6025: Numeric value to tagged union struct — wrap via emit_wrap_union_value.
                        # This happens when a function expects a Union param (represented as tagged union struct)
                        # but the actual value is a numeric type (e.g., NumType passed to Dict{WasmValType,...} key).
                        # B4/M3: numeric → ref via THE single-source funnel (box arm; real
                        # classId; loud trap on genuine mismatch). Dead tagged-union arm DELETED.
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        convert_type!(_cvb, actual_wasm, expected_wasm, ctx;
                                      from_julia=(actual_julia_type isa Type && isconcretetype(actual_julia_type)) ? actual_julia_type : nothing)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === I32 && actual_wasm === I64
                        # i64 to i32 — insert i32.wrap_i64
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        num!(_cvb, Opcode.I32_WRAP_I64)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === I64 && actual_wasm === I32
                        # i32 to i64 — insert i64.extend_i32_s
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        num!(_cvb, Opcode.I64_EXTEND_I32_S)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === F32 && actual_wasm === F64
                        # f64 to f32 — insert f32.demote_f64
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        num!(_cvb, Opcode.F32_DEMOTE_F64)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === F64 && actual_wasm === F32
                        # f32 to f64 — insert f64.promote_f32
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        num!(_cvb, Opcode.F64_PROMOTE_F32)
                        append!(bytes, builder_code(_cvb))
                    elseif (expected_wasm === I32 || expected_wasm === I64 || expected_wasm === F32 || expected_wasm === F64) &&
                           (actual_wasm === AnyRef || actual_wasm === ExternRef)
                        # P4-stdlib (Random hash_seed): boxed numeric in anyref/
                        # externref consumed as a number — UNBOX via the numeric
                        # box (was: drop + zero, silently wrong on live paths;
                        # a null ref traps loud on the cast instead).
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        if actual_wasm === ExternRef
                            any_convert_extern!(_cvb)
                        end
                        emit_classid_unbox!(_cvb, ctx, expected_wasm; nullable=true)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === I32 && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef)
                        # ref to i32 — drop and push 0 (type mismatch, likely dead code)
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        drop!(_cvb)
                        i32_const!(_cvb, 0)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === I64 && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef)
                        # ref to i64 — drop and push 0 (type mismatch, likely dead code)
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        drop!(_cvb)
                        i64_const!(_cvb, 0)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === ExternRef && (actual_wasm isa ConcreteRef || actual_wasm === StructRef || actual_wasm === ArrayRef || actual_wasm === AnyRef)
                        # Concrete or abstract ref to externref — insert extern.convert_any
                        # extern.convert_any converts anyref → externref (concrete refs are subtypes of anyref)
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        extern_convert_any!(_cvb)
                        append!(bytes, builder_code(_cvb))
                        extern_convert_emitted = true
                    elseif expected_wasm === AnyRef && actual_wasm === ExternRef
                        # PURE-9022: externref to anyref — insert any.convert_extern
                        # Occurs when JS import returns externref but internal code expects anyref
                        local _cvb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        any_convert_extern!(_cvb)
                        append!(bytes, builder_code(_cvb))
                    elseif expected_wasm === AnyRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                        # PURE-9022: Numeric value (on the stack) to anyref via THE single box emitter.
                        # (The emitter saves the value to a local + rebuilds {classId, value}, so no
                        # raw splice into `bytes` is needed — deletes the old insert-typeId hack.)
                        local _bxa = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        emit_classid_box!(_bxa, ctx, actual_wasm, nothing)
                        append!(bytes, builder_code(_bxa))
                    elseif expected_wasm === ExternRef && (actual_wasm === I32 || actual_wasm === I64 || actual_wasm === F32 || actual_wasm === F64)
                        # PURE-6025: Numeric value to externref — box via the one emitter, then extern.convert_any.
                        local _bxi = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        emit_classid_box!(_bxi, ctx, actual_wasm, nothing)
                        extern_convert_any!(_bxi)
                        append!(bytes, builder_code(_bxi))
                        extern_convert_emitted = true
                    elseif expected_wasm === ExternRef && actual_wasm === ExternRef
                        # PURE-036z: Julia type inference says Any→ExternRef for both, but the actual
                        # Wasm local might be a ConcreteRef. Check if arg_bytes is local.get of a
                        # non-externref local and insert extern.convert_any if needed.
                        if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20  # LOCAL_GET opcode
                            # typed channel: the emission's own type (arg_ty) — no re-guess.
                            actual_local_wasm = arg_ty
                            if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                # Actual local is a ref type but not externref — insert conversion
                                local _eca = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                                extern_convert_any!(_eca)
                                append!(bytes, builder_code(_eca))
                                extern_convert_emitted = true
                            end
                        end
                    end
                end
            end

            # PURE-036z: Also check against target_info_early if available
            # This catches cases where param_types says ConcreteRef but the actual target function
            # expects ExternRef (because it was registered with different type mapping)
            if target_info_early !== nothing && arg_idx + early_argtypes_offset <= length(target_info_early.arg_types)
                target_expected_julia = target_info_early.arg_types[arg_idx + early_argtypes_offset]
                target_expected_wasm = get_concrete_wasm_type(target_expected_julia, ctx.mod, ctx.type_registry)
                if target_expected_wasm === ExternRef && !extern_convert_emitted
                    # Target function expects externref for this arg
                    # Check if we pushed a non-externref value that needs conversion
                    # PURE-036z: Skip if extern.convert_any was already emitted to avoid double conversion
                    if length(arg_bytes) >= 2 && arg_bytes[1] == 0x20  # LOCAL_GET
                        # typed channel: the emission's own type (arg_ty) — no re-guess.
                        actual_local_wasm = arg_ty
                        if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                            local _eca = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                            extern_convert_any!(_eca)
                            append!(bytes, builder_code(_eca))
                            extern_convert_emitted = true
                        end
                    elseif length(arg_bytes) >= 3 && arg_bytes[1] == 0xfb && (arg_bytes[2] == 0x00 || arg_bytes[2] == 0x01)
                        # struct_new or struct_new_default — produces a ConcreteRef, needs conversion
                        local _eca = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        extern_convert_any!(_eca)
                        append!(bytes, builder_code(_eca))
                        extern_convert_emitted = true
                    end
                end
            end
        end
        # PURE-044: Record if extern.convert_any was emitted for this arg
        extern_convert_emitted_args[arg_idx] = extern_convert_emitted
    end

    arg_type = length(args) > 0 ? infer_value_type(args[1], ctx) : Int64
    is_32bit = arg_type === Int32 || arg_type === UInt32 || arg_type === Bool || arg_type === Char ||
               arg_type === Int16 || arg_type === UInt16 || arg_type === Int8 || arg_type === UInt8 ||
               (isprimitivetype(arg_type) && sizeof(arg_type) <= 4)

    # mi was already extracted above for parameter type checking
    if mi isa Core.MethodInstance
        meth = mi.def
        if meth isa Method
            name = meth.name

            # Check if this is a self-recursive call
            # The second argument of invoke is the function reference
            # It can be a GlobalRef directly, or an SSA value that points to a GlobalRef
            func_ref = expr.args[2]

            # If func_ref is an SSA value, try to resolve it to the underlying GlobalRef
            actual_func_ref = func_ref
            if func_ref isa Core.SSAValue
                ssa_stmt = ctx.code_info.code[func_ref.id]
                if ssa_stmt isa GlobalRef
                    actual_func_ref = ssa_stmt
                end
            elseif func_ref isa Core.Argument
                # PURE-220: Higher-order function calls (e.g., parse_Nary's `down(ps)`)
                # func_ref is a function parameter. Extract actual function from mi.specTypes.
                if mi isa Core.MethodInstance
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        if func_type isa DataType
                            try
                                actual_func_ref = func_type.instance
                            catch; end
                        end
                    end
                end
            end

            is_self_call = false
            if ctx.func_ref !== nothing && actual_func_ref isa GlobalRef
                # Check if this GlobalRef refers to the same function
                try
                    called_func = getfield(actual_func_ref.mod, actual_func_ref.name)
                    if called_func === ctx.func_ref
                        # PURE-220/047: Check arity AND types for overloaded methods
                        if mi isa Core.MethodInstance
                            spec = mi.specTypes
                            if spec isa DataType && spec <: Tuple
                                call_nargs = length(spec.parameters) - 1
                                if call_nargs == length(ctx.arg_types)
                                    call_arg_types = spec.parameters[2:end]
                                    is_self_call = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                                end
                            else
                                is_self_call = true
                            end
                        else
                            is_self_call = true
                        end
                    end
                catch
                    is_self_call = false
                end
            elseif ctx.func_ref !== nothing && actual_func_ref isa Function
                # PURE-209a: Function object direct comparison
                if actual_func_ref === ctx.func_ref
                    # PURE-220/047: Check arity AND types for overloaded methods
                    if mi isa Core.MethodInstance
                        spec = mi.specTypes
                        if spec isa DataType && spec <: Tuple
                            call_nargs = length(spec.parameters) - 1
                            if call_nargs == length(ctx.arg_types)
                                call_arg_types = spec.parameters[2:end]
                                is_self_call = all(call_arg_types[i] <: ctx.arg_types[i] for i in 1:call_nargs)
                            end
                        else
                            is_self_call = true
                        end
                    else
                        is_self_call = true
                    end
                end
            end

            # Check for cross-function call within the module first
            cross_call_handled = false
            # PURE-913: Skip cross-call for runtime intrinsics with proper inline handlers.
            # str_substr's generate_intrinsic_body is a stub (returns source string unchanged).
            # str_trim calls str_substr internally, so also broken when compiled standalone.
            # The inline handlers below (str_substr at line ~22446, str_trim at ~23572)
            # properly implement these using WasmGC array operations with caller scratch locals.
            _skip_cross_call = name in (:str_substr, :str_trim, :sizehint!, Symbol("#sizehint!#81"),
                                     :arr_new, :arr_get, :arr_set!, :arr_len, :arr_fill!)
            if ctx.func_registry !== nothing && !is_self_call && !_skip_cross_call
                # Try to find this function in our registry
                called_func = nothing
                if actual_func_ref isa GlobalRef
                    called_func = try
                        getfield(actual_func_ref.mod, actual_func_ref.name)
                    catch
                        nothing
                    end
                elseif actual_func_ref isa DataType || actual_func_ref isa UnionAll
                    # For constructor calls, the func_ref might be the type directly
                    called_func = actual_func_ref
                elseif actual_func_ref isa Function
                    # PURE-209a: For default-arg methods, func_ref can be a Function object
                    # (e.g., typeof(next_token) for next_token(lexer, true))
                    called_func = actual_func_ref
                elseif actual_func_ref isa Core.Argument && mi isa Core.MethodInstance
                    # PURE-220: Fallback for Core.Argument — extract from mi.specTypes
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        if func_type isa DataType
                            try
                                called_func = func_type.instance
                            catch; end
                        end
                    end
                end

                if called_func === nothing && closure_self_to_push !== nothing && target_info_early !== nothing
                    # 453393ca4ba4: closure callee resolved by TYPE in the early
                    # block; the closure object is already on the stack under the args
                    called_func = closure_self_to_push
                end
                if called_func !== nothing
                    # Infer argument types for dispatch
                    call_arg_types = tuple([infer_value_type(arg, ctx) for arg in args]...)
                    _exp_ret_l = get(ctx.ssa_types, idx, nothing)
                    target_info = get_function(ctx.func_registry, called_func, call_arg_types;
                                               expected_return=_exp_ret_l isa Type ? _exp_ret_l : nothing)
                    if target_info === nothing && closure_self_to_push !== nothing
                        target_info = target_info_early
                    end

                    # PURE-320: Closure/kwarg functions are registered with self-type prepended
                    # (e.g., typeof(#SourceFile#40) prepended to arg_types). Retry with self-type.
                    if target_info === nothing && typeof(called_func) <: Function && isconcretetype(typeof(called_func))
                        closure_arg_types = (typeof(called_func), call_arg_types...)
                        target_info = get_function(ctx.func_registry, called_func, closure_arg_types)
                    end

                    if target_info !== nothing
                        @debug "Cross-call resolved" name=name idx=idx return_type=target_info.return_type has_ssa_local=haskey(ctx.ssa_locals, idx)
                        # PURE-036z: Check if any arg needs extern.convert_any insertion
                        # The args were already pushed, but we need to convert concrete refs to externref
                        # where the target function expects externref but we pushed a concrete ref.
                        # Since args are pushed in order and we can only add conversions at the end,
                        # we need to use a different strategy: after ALL args are pushed, we can
                        # re-order/convert them using locals. But this is complex.
                        #
                        # Simpler approach: check each arg and add extern.convert_any if the LAST
                        # arg needs it (since that's what's on top of the stack). For earlier args,
                        # this won't work with pure stack manipulation.
                        #
                        # Even simpler: only handle the case where the LAST arg needs conversion
                        # (most common case for the current error).
                        n_args = length(args)
                        if n_args > 0
                            last_arg_idx = n_args
                            # PURE-044: Skip if extern.convert_any was already emitted in argument loop
                            if last_arg_idx <= length(target_info.arg_types) && !extern_convert_emitted_args[last_arg_idx]
                                last_target_julia = target_info.arg_types[last_arg_idx]
                                last_target_wasm = get_concrete_wasm_type(last_target_julia, ctx.mod, ctx.type_registry)
                                last_actual_julia = call_arg_types[last_arg_idx]
                                last_actual_wasm = get_concrete_wasm_type(last_actual_julia, ctx.mod, ctx.type_registry)
                                last_arg = args[n_args]

                                if last_target_wasm === ExternRef && (last_actual_wasm isa ConcreteRef || last_actual_wasm === StructRef || last_actual_wasm === ArrayRef || last_actual_wasm === AnyRef)
                                    blca = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                                    extern_convert_any!(blca)
                                    append!(bytes, builder_code(blca))
                                elseif last_target_wasm === ExternRef && last_actual_wasm === ExternRef && last_arg isa Core.SSAValue
                                    # Check actual local type for the last arg
                                    if haskey(ctx.ssa_locals, last_arg.id)
                                        local_idx = ctx.ssa_locals[last_arg.id]
                                        local_arr_idx = local_idx - ctx.n_params + 1
                                        if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                            actual_local_wasm = ctx.locals[local_arr_idx]
                                            if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                                blca2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                                                extern_convert_any!(blca2)
                                                append!(bytes, builder_code(blca2))
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        # Also handle middle args if needed (use locals to reorder)
                        # For now, check if the SECOND arg (index 2) needs conversion when there are 3+ args
                        # This handles the func 126 case: (ref null 36), externref, (ref null 14)
                        # where the middle arg (externref) is getting a concrete ref
                        if n_args >= 2
                            for mid_arg_idx in n_args-1:-1:1  # Check from second-to-last to first
                                # PURE-044: Skip if extern.convert_any was already emitted in argument loop
                                if mid_arg_idx <= length(target_info.arg_types) && !extern_convert_emitted_args[mid_arg_idx]
                                    mid_target_julia = target_info.arg_types[mid_arg_idx]
                                    mid_target_wasm = get_concrete_wasm_type(mid_target_julia, ctx.mod, ctx.type_registry)
                                    mid_actual_julia = call_arg_types[mid_arg_idx]
                                    mid_actual_wasm = get_concrete_wasm_type(mid_actual_julia, ctx.mod, ctx.type_registry)
                                    mid_arg = args[mid_arg_idx]

                                    needs_convert = false
                                    if mid_target_wasm === ExternRef && (mid_actual_wasm isa ConcreteRef || mid_actual_wasm === StructRef || mid_actual_wasm === ArrayRef || mid_actual_wasm === AnyRef)
                                        needs_convert = true
                                    elseif mid_target_wasm === ExternRef && mid_actual_wasm === ExternRef && mid_arg isa Core.SSAValue
                                        if haskey(ctx.ssa_locals, mid_arg.id)
                                            local_idx = ctx.ssa_locals[mid_arg.id]
                                            local_arr_idx = local_idx - ctx.n_params + 1
                                            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                                actual_local_wasm = ctx.locals[local_arr_idx]
                                                if actual_local_wasm isa ConcreteRef || actual_local_wasm === StructRef || actual_local_wasm === ArrayRef || actual_local_wasm === AnyRef
                                                    needs_convert = true
                                                end
                                            end
                                        end
                                    end

                                    if needs_convert
                                        # Stack currently: [arg1, arg2, ..., argN]
                                        # Need to convert arg at mid_arg_idx
                                        # This is complex with pure stack ops; skip for now and
                                        # rely on the initial arg loop to handle most cases.
                                        # The error at func 126 is for arg index 2 (0-based: 1)
                                        # which is the second param. If there are only 2 args on
                                        # stack but 3 params needed, there's a different bug.
                                    end
                                end
                            end
                        end

                        # Cross-function call - emit call instruction with target index
                        bcc = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        call!(bcc, target_info.wasm_idx, WasmValType[], WasmValType[])
                        cross_call_handled = true
                        # PURE-6024: If callee returns Union{} (Bottom), it always throws/traps.
                        # The Wasm func type has no result, so code after is unreachable.
                        # Emit unreachable to make stack polymorphic — prevents DROP from
                        # causing "nothing on stack" when the void call has no return value.
                        # NOTE: Do NOT set ctx.last_stmt_was_stub here. The SSA type may not
                        # be Union{} (e.g., Any in unoptimized IR), so setting the flag would
                        # incorrectly trigger dead code detection and skip block structures.
                        if target_info.return_type === Union{}
                            unreachable!(bcc)  # structural trap (dart-legit dead path)
                        end
                        # PURE-220: Unused cross-call return values are dropped by
                        # the stackifier (statement_produces_wasm_value + use_count==0).
                        # Do NOT emit DROP here — the stackifier's already_dropped heuristic
                        # has false positives when the LEB128 function index byte coincides
                        # with Opcode.CALL (0x10), causing double DROP and stack underflow.
                        # Check: if function returns externref but caller expects concrete ref,
                        # insert any_convert_extern + ref.cast null to bridge the type gap.
                        # This happens when the function's wasm return type is externref (mapped
                        # from Any/Union via julia_to_wasm_type) but the caller's SSA local uses
                        # a tagged union struct (mapped via julia_to_wasm_type_concrete).
                        if haskey(ctx.ssa_locals, idx)
                            local_idx_val = ctx.ssa_locals[idx]
                            local_arr_idx = local_idx_val - ctx.n_params + 1
                            if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                                target_local_type = ctx.locals[local_arr_idx]
                                if target_local_type isa ConcreteRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # Function returns externref, local expects concrete ref
                                        any_convert_extern!(bcc)
                                        ref_cast!(bcc, Int64(target_local_type.type_idx), true)
                                    end
                                elseif target_local_type === AnyRef
                                    ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if ret_wasm === ExternRef
                                        # PURE-908: Function returns externref, local expects anyref
                                        any_convert_extern!(bcc)
                                    end
                                elseif target_local_type === ExternRef && func_ref isa Core.Argument
                                    # PURE-220: Higher-order call returns concrete ref but local expects externref
                                    # (SSA type is Any because the function parameter is generic)
                                    # PURE-6022: But if the callee already returns externref, skip —
                                    # extern_convert_any expects anyref input, not externref.
                                    callee_ret_wasm = julia_to_wasm_type(target_info.return_type)
                                    if callee_ret_wasm !== ExternRef
                                        extern_convert_any!(bcc)
                                    end
                                end
                            end
                        end
                        append!(bytes, builder_code(bcc))
                    end
                end
            end

            # parity(M6/F3): numeric arith result → ref-typed SSA local ⇒ box through THE
            # one producer (the scalar-replaced Core.Box cycle: unbox → op → box → store).
            _f3_result_box! = () -> begin
                local _dl = get(ctx.ssa_locals, idx, nothing)
                _dl === nothing && return
                local _doff = _dl - ctx.n_params
                (_doff >= 0 && _doff < length(ctx.locals) && ctx.locals[_doff + 1] === AnyRef) || return
                local _rbx = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                emit_classid_box!(_rbx, ctx, is_32bit ? I32 : I64, nothing)
                append!(bytes, builder_code(_rbx))
            end
            if is_self_call
                # Self-recursive call - emit call instruction
                bsc2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                call!(bsc2, ctx.func_idx, WasmValType[], WasmValType[])
                # PURE-908: Bridge return type for self-calls (externref→anyref)
                if haskey(ctx.ssa_locals, idx)
                    local_idx_val = ctx.ssa_locals[idx]
                    local_arr_idx = local_idx_val - ctx.n_params + 1
                    if local_arr_idx >= 1 && local_arr_idx <= length(ctx.locals)
                        target_local_type = ctx.locals[local_arr_idx]
                        if target_local_type === AnyRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                any_convert_extern!(bsc2)
                            end
                        elseif target_local_type isa ConcreteRef && ctx.return_type !== nothing
                            ret_wasm = julia_to_wasm_type(ctx.return_type)
                            if ret_wasm === ExternRef
                                any_convert_extern!(bsc2)
                                ref_cast!(bsc2, Int64(target_local_type.type_idx), true)
                            end
                        end
                    end
                end
                append!(bytes, builder_code(bsc2))
            elseif cross_call_handled
                # Already handled above

            elseif name === :+ || name === :add_int
                badd = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                num!(badd, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
                append!(bytes, builder_code(badd))
                _f3_result_box!()
            elseif name === :- || name === :sub_int
                if length(args) == 1
                    # WBUILD-3001: Unary negation -(x) → 0 - x
                    pushfirst!(bytes, is_32bit ? Opcode.I32_CONST : Opcode.I64_CONST)
                    insert!(bytes, 2, 0x00)  # LEB128 for 0
                end
                bsub3 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                num!(bsub3, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
                append!(bytes, builder_code(bsub3))
                _f3_result_box!()
            elseif (name === :* || name === :mul_int) && length(args) == 2 &&
                   (infer_value_type(args[1], ctx) === String || infer_value_type(args[1], ctx) === Symbol) &&
                   (infer_value_type(args[2], ctx) === String || infer_value_type(args[2], ctx) === Symbol)
                # String/Symbol `*` is CONCATENATION: this name-keyed arithmetic
                # fallback fires when the concat MI failed to register as a
                # cross-call (its body bottoms out in Vararg _string) and was
                # emitting i64.mul on two string refs — the E-003 island's
                # fn#107 validation failure. Args were pre-pushed: rebuild.
                bcat = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                emit_raw!(bcat, compile_string_concat(args[1], args[2], ctx); pushes=WasmValType[AnyRef])
                return builder_code(bcat)
            elseif name === :* || name === :mul_int
                bmul = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                num!(bmul, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
                append!(bytes, builder_code(bmul))
            elseif name === :throw_boundserror || name === :throw || name === :throw_inexacterror ||
                   name === :throw_complex_domainerror || name === :throw_complex_domainerror_neg1 ||
                   name === :throw_exp_domainerror || name === :_throw_argerror ||
                   name === :throw_domerr_powbysq || name === :__throw_gcd_overflow ||
                   # P2-batch26 (gap 5922408579a8): checked_mul inside lcm —
                   # OverflowError must be catchable, not an unreachable stub.
                   name === :throw_overflowerr_binaryop || name === :throw_overflowerr_negation
                # PURE-1102: Error throwing functions - emit throw (catchable) instead of unreachable (trap)
                # Clear the stack first (arguments were pushed but not needed)
                bt = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Reset - don't need the pushed args
                ensure_exception_tag!(ctx.mod)
                # PURE-9032: Stash a ref.null any as exception (no specific value for these)
                exn_global = ensure_exception_global!(ctx.mod)
                ref_null!(bt, AnyRef)        # ref.null any
                global_set!(bt, exn_global)
                throw_!(bt, 0)               # tag index 0
                ctx.last_stmt_was_stub = true  # PURE-908
                return builder_code(bt)

            # Power operator: x ^ y for floats
            # WASM doesn't have a native pow instruction, so we need to handle this
            # For now, we require the pow import to be available
            elseif name === :^ && length(args) == 2
                arg1_type = infer_value_type(args[1], ctx)
                arg2_type = infer_value_type(args[2], ctx)

                if (arg1_type === Float64 || arg1_type === Float32) &&
                   (arg2_type === Float64 || arg2_type === Float32)
                    # Float power - need Math.pow import
                    # Check if we have a pow import
                    pow_import_idx = nothing
                    for (i, imp) in enumerate(ctx.mod.imports)
                        if imp.kind == 0x00 && imp.field_name == "pow"  # function import
                            pow_import_idx = UInt32(i - 1)
                            break
                        end
                    end

                    if pow_import_idx !== nothing
                        # Args already compiled, call pow import
                        # Convert to f64 if needed (Math.pow expects f64, f64 -> f64)
                        if arg1_type === Float32
                            # First arg is f32, need to insert promotion before second arg
                            # This is tricky with stack order. For now, just promote both
                            bpow = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Reset
                            emit_value!(bpow, args[1], ctx)
                            num!(bpow, Opcode.F64_PROMOTE_F32)  # f64.promote_f32 (0xBB)
                            emit_value!(bpow, args[2], ctx)
                            if arg2_type === Float32
                                num!(bpow, Opcode.F64_PROMOTE_F32)  # f64.promote_f32 (0xBB)
                            end
                            bytes = builder_code(bpow)
                        end
                        bpow2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        call!(bpow2, pow_import_idx, WasmValType[], WasmValType[])
                        # Convert back to f32 if needed
                        if arg1_type === Float32
                            num!(bpow2, Opcode.F32_DEMOTE_F64)  # f32.demote_f64 (0xB6)
                        end
                        append!(bytes, builder_code(bpow2))
                    else
                        # No pow import - emit approximation using exp(y * log(x))
                        # This is hacky but works for basic cases
                        # For now, error out requesting the import
                        error("Float power (^) requires 'pow' import from Math module. " *
                              "Add (\"Math\", \"pow\", [F64, F64], [F64]) to imports.")
                    end
                elseif (arg1_type === Int32 || arg1_type === Int64) &&
                       (arg2_type === Int32 || arg2_type === Int64)
                    # Integer power - can implement with loop
                    # For simplicity, error out for now
                    error("Integer power (^) not yet implemented. Use float power instead.")
                else
                    error("Unsupported power types: $(arg1_type) ^ $(arg2_type)")
                end

            elseif name === :length && (arg_type === String || arg_type === Any || arg_type === Union{})
                # String/Any length - argument already pushed, emit array.len
                # Only for types that are actually WasmGC arrays (String, Any)
                # Vector length is handled in calls.jl via struct_get on size field
                # Other AbstractVector subtypes (StepRange, SubArray, ReinterpretArray)
                # must go through cross-function call to their specific length() method
                blen = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                if arg_type === Any || arg_type === Union{}
                    any_convert_extern!(blen)        # externref → anyref
                    ref_cast!(blen, ArrayRef, true)  # anyref → (ref null array)
                end
                array_len!(blen)
                # array.len returns i32, extend to i64 for Julia's Int
                num!(blen, Opcode.I64_EXTEND_I32_S)
                append!(bytes, builder_code(blen))

            # String concatenation: string * string -> string
            # Julia compiles string concatenation to Base._string
            # Also handle String, Symbol for error message construction
            elseif (name === :* || name === :_string) && length(args) >= 2 &&
                   (infer_value_type(args[1], ctx) === String || infer_value_type(args[1], ctx) === Symbol) &&
                   (infer_value_type(args[2], ctx) === String || infer_value_type(args[2], ctx) === Symbol)
                # String concatenation using WasmGC array operations
                # For now, handle 2-string concat (most common case)
                if length(args) == 2
                    bytes = compile_string_concat(args[1], args[2], ctx)
                else
                    # Multi-string concat: concat pairwise
                    bytes = compile_string_concat(args[1], args[2], ctx)
                    for i in 3:length(args)
                        # Store intermediate result and concat next string
                        # This is simplified - for full support we'd need proper temp locals
                        # For now, just do first two
                    end
                end

            # PURE-325: isascii(s) — check all bytes < 0x80
            # Called from normalize_identifier via isascii(codeunits(s)).
            # The argument is CodeUnits{UInt8,String} (a struct wrapping String).
            # Extract the String (field 0) from the struct, then iterate bytes.
            elseif name === :isascii && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                arg_type = infer_value_type(args[1], ctx)

                basc = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                # If the argument is a CodeUnits struct, extract the String field.
                if arg_type !== String && arg_type !== Symbol
                    if haskey(ctx.type_registry.structs, arg_type)
                        cu_info = ctx.type_registry.structs[arg_type]
                        struct_get!(basc, cu_info.wasm_type_idx, UInt32(1), I32)  # field 1 = :s (String) (field 0 = typeId)
                    end
                end

                # Allocate locals: str, len, accum, i
                str_arr_type = ConcreteRef(str_type_idx, true)
                str_local = allocate_local!(ctx, str_arr_type)
                len_local = allocate_local!(ctx, I32)
                accum_local = allocate_local!(ctx, I32)
                i_local = allocate_local!(ctx, I32)

                # Store string
                local_set!(basc, str_local)

                # len = array.len(str)
                local_get!(basc, str_local)
                array_len!(basc)
                local_set!(basc, len_local)

                # accum = 0
                i32_const!(basc, 0)
                local_set!(basc, accum_local)

                # i = 0
                i32_const!(basc, 0)
                local_set!(basc, i_local)

                # block $exit
                block!(basc, 0x40)  # void
                #   loop $loop
                loop!(basc, 0x40)  # void

                #     br_if $exit (i >= len)
                local_get!(basc, i_local)
                local_get!(basc, len_local)
                num!(basc, Opcode.I32_GE_S)
                br_if!(basc, 1)  # break to outer block

                #     accum |= array.get(str, i)
                local_get!(basc, accum_local)
                local_get!(basc, str_local)
                local_get!(basc, i_local)
                array_get!(basc, str_type_idx, I32; signed=false)
                num!(basc, Opcode.I32_OR)
                local_set!(basc, accum_local)

                #     i++
                local_get!(basc, i_local)
                i32_const!(basc, 1)
                num!(basc, Opcode.I32_ADD)
                local_set!(basc, i_local)

                #     br $loop
                br!(basc, 0)  # continue loop

                #   end loop
                end_block!(basc)
                # end block
                end_block!(basc)

                # result = (accum < 0x80) ? 1 : 0
                # accum < 128 means all bytes are ASCII
                local_get!(basc, accum_local)
                i32_const!(basc, 0x80)
                num!(basc, Opcode.I32_LT_U)  # unsigned comparison: accum < 0x80
                append!(bytes, builder_code(basc))

            # String equality comparison
            elseif name === :(==) && length(args) == 2 &&
                   infer_value_type(args[1], ctx) === String &&
                   infer_value_type(args[2], ctx) === String
                bytes = compile_string_equal(args[1], args[2], ctx)

            # WasmTarget string operations - str_char(s, i) -> Int32
            elseif name === :str_char && length(args) == 2
                # Get character at index: array.get on string array
                # Args: string, index (1-based)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Compile string arg (already pushed by args loop)
                # Compile index arg and convert to 0-based
                bchr = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                idx_type = infer_value_type(args[2], ctx)
                # parity(M9): the pre-pushed string is the CLASSED struct sitting UNDER
                # the index — save idx, read .data, reload idx.
                _sc_idx = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, idx_type === Int64 || idx_type === Int ? I64 : I32)
                builder_set_local_type!(bchr, _sc_idx, idx_type === Int64 || idx_type === Int ? I64 : I32)
                local_set!(bchr, _sc_idx)
                _ssi = get_string_struct_type!(ctx.mod, ctx.type_registry)
                ref_cast!(bchr, Int64(_ssi), false)
                struct_get!(bchr, UInt32(_ssi), UInt32(1), ConcreteRef(UInt32(str_type_idx), true))
                local_get!(bchr, _sc_idx)
                if idx_type === Int64 || idx_type === Int
                    # Convert Int64 to Int32 and subtract 1
                    num!(bchr, Opcode.I32_WRAP_I64)
                end
                i32_const!(bchr, 1)  # 1
                num!(bchr, Opcode.I32_SUB)  # index - 1 for 0-based

                # array.get
                array_get!(bchr, str_type_idx, I32; signed=false)
                append!(bytes, builder_code(bchr))

            # WasmTarget string operations - str_setchar!(s, i, c) -> Nothing
            elseif name === :str_setchar! && length(args) == 3
                # Set character at index: array.set on string array
                # Args: string, index (1-based), char (Int32)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Stack has: string, index, char
                # Need to reorder to: string, index-1, char for array.set
                # Actually array.set expects: array, index, value
                # So we need: compile string, compile index-1, compile char

                # Clear the bytes from the args loop - we'll recompile in correct order
                bsc = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                # Compile string
                emit_value!(bsc, args[1], ctx)

                # Compile index and convert to 0-based
                emit_value!(bsc, args[2], ctx)
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    num!(bsc, Opcode.I32_WRAP_I64)
                end
                i32_const!(bsc, 1)
                num!(bsc, Opcode.I32_SUB)

                # Compile char value
                emit_value!(bsc, args[3], ctx)
                char_type = infer_value_type(args[3], ctx)
                if char_type === Int64 || char_type === Int
                    num!(bsc, Opcode.I32_WRAP_I64)
                end

                # array.set
                array_set!(bsc, str_type_idx, I32)
                return builder_code(bsc)

            # WasmTarget string operations - str_len(s) -> Int32
            elseif name === :str_len && length(args) == 1
                # Get string length as Int32
                # Arg already compiled, just emit array.len
                blen2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                array_len!(blen2)
                append!(bytes, builder_code(blen2))

            # WasmTarget string operations - str_new(len) -> String
            elseif name === :str_new && length(args) == 1
                # Create new string of given length, filled with zeros
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Length arg already compiled
                bnew = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                len_type = infer_value_type(args[1], ctx)
                if len_type === Int64 || len_type === Int
                    num!(bnew, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0 for i32)
                array_new_default!(bnew, str_type_idx)
                append!(bytes, builder_code(bnew))

            # WasmTarget string operations - str_copy(src, src_pos, dst, dst_pos, len) -> Nothing
            elseif name === :str_copy && length(args) == 5
                # Copy characters from src to dst using array.copy
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Clear bytes - recompile in correct order for array.copy
                # array.copy expects: dst, dst_offset, src, src_offset, len
                bcp = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                # dst array
                emit_value!(bcp, args[3], ctx)
                # dst offset (0-based)
                emit_value!(bcp, args[4], ctx)
                dst_idx_type = infer_value_type(args[4], ctx)
                if dst_idx_type === Int64 || dst_idx_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end
                i32_const!(bcp, 1)
                num!(bcp, Opcode.I32_SUB)

                # src array
                emit_value!(bcp, args[1], ctx)
                # src offset (0-based)
                emit_value!(bcp, args[2], ctx)
                src_idx_type = infer_value_type(args[2], ctx)
                if src_idx_type === Int64 || src_idx_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end
                i32_const!(bcp, 1)
                num!(bcp, Opcode.I32_SUB)

                # length
                emit_value!(bcp, args[5], ctx)
                len_type = infer_value_type(args[5], ctx)
                if len_type === Int64 || len_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end

                # array.copy
                array_copy!(bcp, str_type_idx, str_type_idx)
                return builder_code(bcp)

            # WasmTarget string operations - str_substr(s, start, len) -> String
            elseif name === :str_substr && length(args) == 3
                # Extract substring: create new string and copy characters
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Use scratch locals stored in context
                if ctx.scratch_locals === nothing
                    error("String operations require scratch locals but none were allocated")
                end
                result_local, src_local, _, _, _ = ctx.scratch_locals

                # Clear bytes - recompile in correct order
                bss = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                # Store source string DATA (parity M9: the funnel unwraps the class)
                emit_value!(bss, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
                local_set!(bss, src_local)

                # Create new string of specified length
                emit_value!(bss, args[3], ctx)  # len
                len_type = infer_value_type(args[3], ctx)
                if len_type === Int64 || len_type === Int
                    num!(bss, Opcode.I32_WRAP_I64)
                end
                array_new_default!(bss, str_type_idx)
                local_set!(bss, result_local)

                # Copy characters: array.copy [dst, dst_off, src, src_off, len]
                # dst = result, dst_off = 0, src = source, src_off = start-1, len = len
                local_get!(bss, result_local)
                i32_const!(bss, 0)  # dst_off = 0

                local_get!(bss, src_local)

                # src_off = start - 1 (convert to 0-based)
                emit_value!(bss, args[2], ctx)
                start_type = infer_value_type(args[2], ctx)
                if start_type === Int64 || start_type === Int
                    num!(bss, Opcode.I32_WRAP_I64)
                end
                i32_const!(bss, 1)
                num!(bss, Opcode.I32_SUB)

                # len
                emit_value!(bss, args[3], ctx)
                len_type2 = infer_value_type(args[3], ctx)
                if len_type2 === Int64 || len_type2 === Int
                    num!(bss, Opcode.I32_WRAP_I64)
                end

                array_copy!(bss, str_type_idx, str_type_idx)

                # Return result — published as the CLASSED string (parity M9)
                local_get!(bss, result_local)
                emit_string_wrap!(bss, ctx)
                return builder_code(bss)

            # WasmTarget string operations - str_hash(s) -> Int32
            elseif name === :str_hash && length(args) == 1
                bytes = _compile_invoke_str_hash(args, ctx)

            # ================================================================
            # BROWSER-010: New String Operations
            # str_find, str_contains, str_startswith, str_endswith
            # str_uppercase, str_lowercase, str_trim
            # ================================================================

            # str_find(haystack, needle) -> Int32
            # Returns 1-based position or 0 if not found
            elseif name === :str_find && length(args) == 2
                bytes = _compile_invoke_str_find(args, ctx)

            # str_contains(haystack, needle) -> Bool
            # Returns true if needle is found in haystack
            elseif name === :str_contains && length(args) == 2
                bytes = _compile_invoke_str_contains(args, ctx)


            # str_startswith(s, prefix) -> Bool
            elseif name === :str_startswith && length(args) == 2
                bytes = _compile_invoke_str_startswith(args, ctx)

            # str_endswith(s, suffix) -> Bool
            elseif name === :str_endswith && length(args) == 2
                bytes = _compile_invoke_str_endswith(args, ctx)

            # str_uppercase(s) -> String
            # Convert lowercase ASCII letters to uppercase
            elseif name === :str_uppercase && length(args) == 1
                bytes = _compile_invoke_str_uppercase(args, ctx)

            # str_lowercase(s) -> String
            # Convert uppercase ASCII letters to lowercase
            elseif name === :str_lowercase && length(args) == 1
                bytes = _compile_invoke_str_lowercase(args, ctx)


            # str_trim(s) -> String
            # Remove leading and trailing ASCII whitespace
            elseif name === :str_trim && length(args) == 1
                bytes = _compile_invoke_str_trim(args, ctx)

            # ================================================================
            # WasmTarget array operations - arr_new, arr_get, arr_set!, arr_len
            # ================================================================

            # arr_new(Type, len) -> Vector{Type}
            elseif name === :arr_new && length(args) == 2
                # First arg is the type (compile-time constant)
                # Second arg is the length
                type_arg = args[1]
                elem_type = if type_arg isa Core.SSAValue
                    ctx.ssa_types[type_arg.id]
                elseif type_arg isa GlobalRef
                    getfield(type_arg.mod, type_arg.name)
                elseif type_arg isa Type
                    type_arg
                else
                    Int32  # Default
                end

                # Get or create array type
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Clear previous arg compilation - we only need length
                ban = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                # Compile length arg
                emit_value!(ban, args[2], ctx)
                len_type = infer_value_type(args[2], ctx)
                if len_type === Int64 || len_type === Int
                    num!(ban, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0)
                array_new_default!(ban, arr_type_idx)
                return builder_code(ban)

            # arr_get(arr, i) -> T
            elseif name === :arr_get && length(args) == 2
                # Args already compiled: arr, index
                # Need to adjust index to 0-based and emit array.get
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Convert index to 0-based
                bget = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    num!(bget, Opcode.I32_WRAP_I64)
                end
                i32_const!(bget, 1)
                num!(bget, Opcode.I32_SUB)  # index - 1

                # array.get (use ARRAY_GET_U for packed i8 arrays like UInt8)
                array_get!(bget, arr_type_idx, I32; signed=(elem_type === UInt8 ? false : nothing))
                append!(bytes, builder_code(bget))

            # arr_set!(arr, i, val) -> Nothing
            elseif name === :arr_set! && length(args) == 3
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Recompile in correct order for array.set: arr, index-1, val
                bas = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                local _arrset_elem_w = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                local _arrset_elem_w2 = _arrset_elem_w isa WasmValType ? _arrset_elem_w : AnyRef

                # Array ref
                emit_value!(bas, args[1], ctx)

                # Index (convert to 0-based)
                emit_value!(bas, args[2], ctx)
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    num!(bas, Opcode.I32_WRAP_I64)
                end
                i32_const!(bas, 1)
                num!(bas, Opcode.I32_SUB)

                # Value
                local (val_bytes, val_ty) = compile_value_typed(args[3], ctx)
                # PURE-045: If elem_type is Any (externref array), convert ref→externref
                if elem_type === Any
                    # typed channel: the emission's own type (val_ty from the producer above).
                    local arrset_src_wasm = val_ty
                    local is_numeric_val = arrset_src_wasm === I64 || arrset_src_wasm === I32 || arrset_src_wasm === F64 || arrset_src_wasm === F32
                    local is_already_externref_val = arrset_src_wasm === ExternRef
                    if is_numeric_val
                        local _n2e = UInt8[]; emit_numeric_to_externref!(_n2e, stmt.val, val_wasm, ctx)
                        emit_raw!(bas, _n2e; pushes=WasmValType[ExternRef])
                    else
                        emit_raw!(bas, val_bytes; pushes=(val_ty===nothing ? WasmValType[] : WasmValType[val_ty]))
                        # PURE-048: Skip extern_convert_any if value is already externref
                        if !is_already_externref_val
                            extern_convert_any!(bas)
                        end
                    end
                else
                    emit_raw!(bas, val_bytes; pushes=(val_ty===nothing ? WasmValType[] : WasmValType[val_ty]))
                end

                # array.set
                array_set!(bas, arr_type_idx, _arrset_elem_w2)
                bytes = builder_code(bas)

            # arr_len(arr) -> Int32
            elseif name === :arr_len && length(args) == 1
                # Arg already compiled, just emit array.len
                blen3 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                array_len!(blen3)
                append!(bytes, builder_code(blen3))

            # Math domain error functions — throw catchably (tag 0), matching native
            # semantics. These used to push NaN ("graceful degradation"), but the IR
            # statement after a Union{} invoke is `unreachable`, so the NaN was never
            # observed and the function trapped uncatchably (gap c6dae81c0ef4).
            elseif name === :sin_domain_error || name === :cos_domain_error ||
                   name === :tan_domain_error || name === :asin_domain_error ||
                   name === :acos_domain_error || name === :log_domain_error ||
                   name === :sqrt_domain_error
                bdm = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Reset - don't need the pushed args
                ensure_exception_tag!(ctx.mod)
                # PURE-9032: Stash a ref.null any as exception (no specific value)
                exn_global = ensure_exception_global!(ctx.mod)
                ref_null!(bdm, AnyRef)        # ref.null any
                global_set!(bdm, exn_global)
                throw_!(bdm, 0)               # tag index 0
                ctx.last_stmt_was_stub = true  # PURE-908
                return builder_code(bdm)

            # ================================================================
            # WASM-055: Base.string dispatch to int_to_string
            # Base.string(n::Int) internally calls Base.#string#NNN(base, pad, string, n)
            # where NNN is a version-dependent kwarg counter (530 in 1.11, 403 in 1.12).
            # We intercept this and redirect to WasmTarget.int_to_string
            # ================================================================
            elseif startswith(String(name), "#string#") && length(args) >= 4
                # #string#530(base::Int64, pad::Int64, ::typeof(string), value)
                # The actual value to convert is the last argument (args[4])
                value_arg = args[4]
                value_type = infer_value_type(value_arg, ctx)

                # Check if we're converting an integer type
                if value_type === Int32 || value_type === Int64 ||
                   value_type === UInt32 || value_type === UInt64 ||
                   value_type === Int16 || value_type === UInt16 ||
                   value_type === Int8 || value_type === UInt8

                    # Clear the bytes (args were already pushed)
                    bis = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                    # Check if int_to_string is in the function registry
                    int_to_string_info = nothing
                    if ctx.func_registry !== nothing
                        # Try to find int_to_string with Int32 signature
                        try
                            int_to_string_func = getfield(WasmTarget, :int_to_string)
                            int_to_string_info = get_function(ctx.func_registry, int_to_string_func, (Int32,))
                        catch
                            # Function not found
                        end
                    end

                    if int_to_string_info !== nothing
                        # int_to_string is in registry - call it
                        # Compile the value argument, converting to Int32 if needed
                        emit_value!(bis, value_arg, ctx)

                        # Convert to Int32 if needed
                        if value_type === Int64
                            num!(bis, Opcode.I32_WRAP_I64)
                        elseif value_type === UInt32 || value_type === UInt64
                            # Treat as signed for string conversion
                            if value_type === UInt64
                                num!(bis, Opcode.I32_WRAP_I64)
                            end
                        elseif value_type !== Int32
                            # Smaller types - extend to i32
                            # Already handled by compile_value which produces correct type
                        end

                        # Call int_to_string
                        call!(bis, int_to_string_info.wasm_idx, WasmValType[], WasmValType[])
                        return builder_code(bis)
                    else
                        # int_to_string not in registry - provide helpful error
                        error("Base.string(::$(value_type)) requires int_to_string in compile_multi. " *
                              "Add WasmTarget.int_to_string and WasmTarget.digit_to_str to your function list.")
                    end
                else
                    # Non-integer type - not yet supported
                    error("Base.string(::$(value_type)) not yet supported. " *
                          "Supported types: Int32, Int64, UInt32, UInt64, Int16, UInt16, Int8, UInt8")
                end

            # ================================================================
            # Julia 1.11+ Memory API: Core.memoryref
            # Creates MemoryRef from Memory - in WasmGC this is a no-op
            # ================================================================
            elseif name === :memoryref && length(args) == 1
                # Core.memoryref(memory::Memory{T}) -> MemoryRef{T}
                # In WasmGC, Memory and MemoryRef are both the array reference
                # Clear args bytes (already pushed) and re-compile just the memory arg
                bmr = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                emit_value!(bmr, args[1], ctx)
                return builder_code(bmr)

            # ================================================================
            # PURE-9032: Error constructors — create proper exception struct
            # These are typically followed by throw(). The constructor produces
            # the exception object, leaving the struct ref on the stack.
            # ================================================================
            elseif name === :BoundsError || name === :ArgumentError || name === :TypeError ||
                   name === :DomainError || name === :OverflowError || name === :DivideError ||
                   name === :InexactError || name === :ErrorException || name === :KeyError ||
                   name === :MethodError || name === :AssertionError || name === :AssertionError ||
                   name === :StackOverflowError || name === :OutOfMemoryError || name === :UndefVarError
                bec = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-compiled args (we re-compile below for correct field order)
                local _ctor_type = nothing
                if name === :BoundsError; _ctor_type = BoundsError
                elseif name === :ArgumentError; _ctor_type = ArgumentError
                elseif name === :TypeError; _ctor_type = TypeError
                elseif name === :DomainError; _ctor_type = DomainError
                elseif name === :OverflowError; _ctor_type = OverflowError
                elseif name === :DivideError; _ctor_type = DivideError
                elseif name === :InexactError; _ctor_type = InexactError
                elseif name === :ErrorException; _ctor_type = ErrorException
                elseif name === :KeyError; _ctor_type = KeyError
                elseif name === :MethodError; _ctor_type = MethodError
                elseif name === :StackOverflowError; _ctor_type = StackOverflowError
                elseif name === :OutOfMemoryError; _ctor_type = OutOfMemoryError
                elseif name === :UndefVarError; _ctor_type = UndefVarError
                end
                local _ctor_info = _ctor_type !== nothing ? register_struct_type!(ctx.mod, ctx.type_registry, _ctor_type) : nothing
                if _ctor_info !== nothing
                    # Push typeId (field 0)
                    local _tid_ec = UInt8[]; emit_type_id!(_tid_ec, ctx.type_registry, _ctor_type)
                    emit_raw!(bec, _tid_ec; pushes=WasmValType[I32])
                    # Push remaining fields: for msg-based exceptions, compile the msg arg as string array
                    nfields = length(fieldnames(_ctor_type))
                    # the ACTUAL wasm field types decide bridging/null heap types
                    local _ctor_def = ctx.mod.types[_ctor_info.wasm_type_idx + 1]
                    _ctor_field_wasm = fi_ -> begin
                        _w = fi_ + Int(_ctor_info.field_offset)
                        (_ctor_def isa StructType && _w <= length(_ctor_def.fields)) ?
                            _ctor_def.fields[_w].valtype : nothing
                    end
                    for fi in 1:nfields
                        if fi <= length(args)
                            local _ft_ctor = fieldtype(_ctor_type, fi)
                            local _val_wasm = compile_value_typed(args[fi], ctx)[2]
                            local _is_numeric_val = _val_wasm === I32 || _val_wasm === I64 || _val_wasm === F32 || _val_wasm === F64
                            # WBUILD-1011: Box numeric values for Any/abstract-typed struct fields
                            if _is_numeric_val && (_ft_ctor === Any || isabstracttype(_ft_ctor))
                                local _na_ec = UInt8[]; emit_numeric_to_anyref!(_na_ec, args[fi], _val_wasm, ctx)
                                emit_raw!(bec, _na_ec; pushes=WasmValType[AnyRef])
                                if _ctor_field_wasm(fi) === ExternRef
                                    extern_convert_any!(bec)
                                end
                            else
                                emit_value!(bec, args[fi], ctx)
                                # WASMMAKIE E-003: Any fields map to EXTERNREF — a
                                # concrete ref (e.g. BoundsError(LinearIndices(...), i)
                                # in wilkinson's range indexing) fails struct.new
                                # validation without extern.convert_any
                                if _ctor_field_wasm(fi) === ExternRef &&
                                   (_val_wasm isa ConcreteRef || _val_wasm === StructRef ||
                                    _val_wasm === ArrayRef || _val_wasm === AnyRef || _val_wasm === EqRef)
                                    extern_convert_any!(bec)
                                end
                            end
                        else
                            # Default: push null ref for ref fields, 0 for i32/i64 —
                            # the NULL HEAP TYPE must match the wasm field type
                            local _ft = fieldtype(_ctor_type, fi)
                            local _fw = _ctor_field_wasm(fi)
                            if _fw === I32
                                i32_const!(bec, 0)
                            elseif _fw === I64
                                i64_const!(bec, 0)
                            elseif _fw === ExternRef
                                ref_null!(bec, ExternRef)
                            elseif _fw isa ConcreteRef
                                ref_null!(bec, Int64(_fw.type_idx), ConcreteRef(UInt32(_fw.type_idx), true))
                            elseif _ft === Int32 || _ft === Bool
                                i32_const!(bec, 0)
                            elseif _ft === Int64 || _ft === UInt64
                                i64_const!(bec, 0)
                            else
                                ref_null!(bec, AnyRef)
                            end
                        end
                    end
                    struct_new!(bec, _ctor_info.wasm_type_idx, WasmValType[])
                else
                    # Fallback: can't register type, create a dummy anyref (ref.null any)
                    ref_null!(bec, AnyRef)
                end
                bytes = builder_code(bec)
                # NOTE: Do NOT throw here and do NOT set last_stmt_was_stub.
                # The IR has a separate throw() call that consumes this value.

            # ================================================================
            # PURE-322: SubString — create proper SubString struct
            # SubString(str, start, stop) does UTF-8 thisind validation that
            # uses jl_string_ptr/pointerref (unsupported in WasmGC). Since
            # WasmGC strings are array<i32> (char arrays, not byte arrays),
            # every index is valid. Create struct: {string, offset, ncodeunits}
            # ================================================================
            elseif name === :SubString
                bsub2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear accumulated arg bytes
                if length(args) >= 3
                    str_arg = args[1]
                    start_arg = args[2]
                    stop_arg = args[3]
                    # Field 0: typeId = 0
                    i32_const!(bsub2, 0)
                    # Field 1: string (ref null array<i32>)
                    emit_value!(bsub2, str_arg, ctx)
                    # Field 2: offset = start - 1
                    emit_value!(bsub2, start_arg, ctx)
                    i64_const!(bsub2, 1)
                    num!(bsub2, Opcode.I64_SUB)
                    # Field 3: ncodeunits = stop - start + 1
                    emit_value!(bsub2, stop_arg, ctx)
                    emit_value!(bsub2, start_arg, ctx)
                    num!(bsub2, Opcode.I64_SUB)
                    i64_const!(bsub2, 1)
                    num!(bsub2, Opcode.I64_ADD)
                    # Emit struct.new for SubString type
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        struct_new!(bsub2, substr_wasm.type_idx, WasmValType[])
                    end
                elseif length(args) >= 1
                    # SubString(str) — view of entire string
                    str_arg = args[1]
                    # Field 0: typeId = 0
                    i32_const!(bsub2, 0)
                    emit_value!(bsub2, str_arg, ctx)
                    i64_const!(bsub2, 0)  # offset = 0
                    # ncodeunits = array.len(str)
                    emit_value!(bsub2, str_arg, ctx)
                    array_len!(bsub2)
                    num!(bsub2, Opcode.I64_EXTEND_I32_S)
                    # Emit struct.new
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        struct_new!(bsub2, substr_wasm.type_idx, WasmValType[])
                    end
                end
                return builder_code(bsub2)

            # ================================================================
            # PURE-322: _thisind_continued / _nextind_continued — identity
            # In WasmGC, strings are array<i32> (char codes), so every
            # character index is valid (no multi-byte encoding).
            # ================================================================
            elseif (name === :_thisind_continued || name === Symbol("#_thisind_continued#_thisind_str##0")) && length(args) >= 2
                bti = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                # Closure form: (closure, string, index, len) → return index
                if length(args) >= 3
                    emit_value!(bti, args[2], ctx)
                else
                    emit_value!(bti, args[1], ctx)
                end
                return builder_code(bti)

            elseif (name === :_nextind_continued || name === Symbol("#_nextind_continued#_nextind_str##0")) && length(args) >= 2
                bni = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                # nextind(s, i) = i + 1 in WasmGC
                if length(args) >= 3
                    emit_value!(bni, args[2], ctx)
                else
                    emit_value!(bni, args[1], ctx)
                end
                i64_const!(bni, 1)
                num!(bni, Opcode.I64_ADD)
                return builder_code(bni)

            # ================================================================
            # PURE-9016: Multi-arg string() → inline N-way concatenation
            # string("hello", " ", "world") or string("x = ", int_to_string(x))
            # Allocates one result array of total length, copies each arg in
            # ================================================================
            elseif (name === :string || name === :_string) && length(args) > 1
                bms = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-compiled args

                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                str_arr_type = ConcreteRef(str_type_idx, true)
                n = length(args)

                # Check arg types — for now handle all-String args
                arg_types = [infer_value_type(a, ctx) for a in args]
                all_strings = all(t -> t === String || t === Symbol, arg_types)

                if all_strings
                    # Allocate locals: one per string arg + offset + total_len + result
                    str_locals = [allocate_local!(ctx, str_arr_type) for _ in 1:n]
                    offset_local = allocate_local!(ctx, I32)
                    total_len_local = allocate_local!(ctx, I32)
                    result_local = allocate_local!(ctx, str_arr_type)

                    # Step 1: Compile each arg and store in locals
                    for i in 1:n
                        emit_value!(bms, args[i], ctx)
                        local_set!(bms, str_locals[i])
                    end

                    # Step 2: Compute total length = sum(array.len(si))
                    i32_const!(bms, 0)
                    for i in 1:n
                        local_get!(bms, str_locals[i])
                        array_len!(bms)
                        num!(bms, Opcode.I32_ADD)
                    end
                    local_set!(bms, total_len_local)

                    # Step 3: result = array.new_default(total_len)
                    local_get!(bms, total_len_local)
                    array_new_default!(bms, str_type_idx)
                    local_set!(bms, result_local)

                    # Step 4: offset = 0; copy each string into result
                    i32_const!(bms, 0)
                    local_set!(bms, offset_local)

                    for i in 1:n
                        # array.copy(result, offset, si, 0, len(si))
                        local_get!(bms, result_local)  # dst
                        local_get!(bms, offset_local)  # dst_offset
                        local_get!(bms, str_locals[i])  # src
                        i32_const!(bms, 0)  # src_offset
                        local_get!(bms, str_locals[i])
                        array_len!(bms)  # len
                        array_copy!(bms, str_type_idx, str_type_idx)

                        # offset += len(si)
                        local_get!(bms, offset_local)
                        local_get!(bms, str_locals[i])
                        array_len!(bms)
                        num!(bms, Opcode.I32_ADD)
                        local_set!(bms, offset_local)
                    end

                    # Step 5: push result
                    local_get!(bms, result_local)
                else
                    # Mixed types — not yet supported for multi-arg string()
                    # Fall back to empty string for now
                    array_new_fixed!(bms, str_type_idx, 0, I32)
                end
                return builder_code(bms)

            # ================================================================
            # WBUILD-5401: Base.string dispatch for single-arg types
            # Float64 is handled via auto-discovery of Ryu.writeshortest.
            # Int types fall back to int_to_string runtime if not auto-discovered.
            # ================================================================
            elseif name === :string && length(args) == 1 &&
                   let _vt = infer_value_type(args[1], ctx)
                       _vt !== Float32 && _vt !== Float64
                   end
                value_arg = args[1]
                value_type = infer_value_type(value_arg, ctx)

                if value_type === Int32 || value_type === Int64 ||
                       value_type === UInt32 || value_type === UInt64 ||
                       value_type === Int16 || value_type === UInt16 ||
                       value_type === Int8 || value_type === UInt8
                    # Integer types - redirect to int_to_string
                    bis1 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                    int_to_string_info = nothing
                    if ctx.func_registry !== nothing
                        try
                            int_to_string_func = getfield(WasmTarget, :int_to_string)
                            int_to_string_info = get_function(ctx.func_registry, int_to_string_func, (Int32,))
                        catch
                            # Function not found
                        end
                    end

                    if int_to_string_info !== nothing
                        emit_value!(bis1, value_arg, ctx)

                        # Convert to Int32 if needed
                        if value_type === Int64
                            num!(bis1, Opcode.I32_WRAP_I64)
                        elseif value_type === UInt64
                            num!(bis1, Opcode.I32_WRAP_I64)
                        end

                        call!(bis1, int_to_string_info.wasm_idx, WasmValType[], WasmValType[])
                        return builder_code(bis1)
                    else
                        error("Base.string(::$(value_type)) requires int_to_string in compile_multi. " *
                              "Add WasmTarget.int_to_string and WasmTarget.digit_to_str to your function list.")
                    end
                elseif value_type === String || value_type === Symbol
                    # string(s::String) is identity — the arg is already on the stack
                    # (pre-compiled by the argument loop above)
                else
                    error("Base.string(::$(value_type)) not yet supported. " *
                          "Supported types: String, Symbol, Float32, Float64, Int32, Int64, UInt32, UInt64, Int16, UInt16, Int8, UInt8")
                end

            # PURE-1102: Error-throwing functions from Base (used by pop!, resize!, etc.)
            # Emit throw (catchable) instead of unreachable (trap)
            elseif name === :_throw_argerror || name === :throw_boundserror ||
                   name === :throw || name === :rethrow ||
                   name === :_throw_not_readable || name === :_throw_not_writable
                ensure_exception_tag!(ctx.mod)
                bthr2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                if name === :rethrow
                    # PURE-9034: rethrow() preserves the exception in the global —
                    # just re-throw without overwriting. The caught exception is
                    # already in $current_exn from the original throw.
                    throw_!(bthr2, 0)  # tag index 0
                else
                    # PURE-9032: Stash ref.null any as exception placeholder
                    exn_global = ensure_exception_global!(ctx.mod)
                    ref_null!(bthr2, AnyRef)  # ref.null any (0xD0 0x6E)
                    global_set!(bthr2, exn_global)
                    throw_!(bthr2, 0)  # tag index 0
                end
                append!(bytes, builder_code(bthr2))
                ctx.last_stmt_was_stub = true  # PURE-908

            # PURE-9040: println/print → JS IO bridge imports
            elseif name === :println || name === :print
                bytes = _compile_invoke_print(name, args, ctx)
                # print returns `nothing`; the io imports are void. If this SSA
                # has a local (the nothing value is USED downstream — common in
                # trim-collected show machinery), push its representation so the
                # statement wrapper's local.set has a value to consume.
                if haskey(ctx.ssa_locals, idx)
                    bpn = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    ref_null!(bpn, AnyRef)  # ref.null any (0xD0 0x6E)
                    append!(bytes, builder_code(bpn))
                end

            # PURE-9041: show(x) → IO bridge imports (like print, no newline)
            # show(42) displays "42", show(true) displays "true", show(nothing) displays "nothing"
            elseif name === :show
                io = get_io_imports()
                if io !== nothing
                    bsh2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    for arg in args
                        # Determine argument type
                        arg_type = nothing
                        if arg isa Core.SSAValue
                            arg_type = ctx.code_info.ssavaluetypes[arg.id]
                        elseif arg isa Core.Argument
                            slot_id = arg.n
                            arg_type = ctx.code_info.slottypes[slot_id]
                        elseif arg isa String || arg isa Symbol
                            arg_type = String
                        elseif arg isa Int64 || arg isa Int32 || arg isa Int
                            arg_type = typeof(arg)
                        elseif arg isa Float64 || arg isa Float32
                            arg_type = typeof(arg)
                        elseif arg isa Bool
                            arg_type = Bool
                        elseif arg isa Nothing || arg === nothing
                            arg_type = Nothing
                        elseif arg isa GlobalRef && arg.name === :nothing
                            arg_type = Nothing
                        end

                        if arg_type === Nothing
                            # show(nothing) → write "nothing"
                            call!(bsh2, io.write_nothing_idx, WasmValType[], WasmValType[])
                        elseif arg_type === String || arg_type === Symbol
                            emit_value!(bsh2, arg, ctx)
                            tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                            local _tb_js = UInt8[]
                            emit_jl_string_to_js!(_tb_js, io.decode_idx, tmp_local)
                            emit_raw!(bsh2, _tb_js; pops=1, pushes=WasmValType[ExternRef])
                            call!(bsh2, io.write_string_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                            emit_value!(bsh2, arg, ctx)
                            call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Int32
                            emit_value!(bsh2, arg, ctx)
                            num!(bsh2, Opcode.I64_EXTEND_I32_S)
                            call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Float64
                            emit_value!(bsh2, arg, ctx)
                            call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Float32
                            emit_value!(bsh2, arg, ctx)
                            num!(bsh2, Opcode.F64_PROMOTE_F32)
                            call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Bool
                            emit_value!(bsh2, arg, ctx)
                            call!(bsh2, io.write_bool_idx, WasmValType[], WasmValType[])
                        else
                            @debug "show: unsupported argument type $arg_type, skipping"
                        end
                    end
                    # show returns `nothing`; io imports are void — same contract
                    # as the print handler above.
                    if haskey(ctx.ssa_locals, idx)
                        ref_null!(bsh2, AnyRef)
                    end
                    return builder_code(bsh2)
                else
                    bytes = UInt8[]
                end

            # Handle truncate (IOBuffer resize) — no-op in WasmGC
            # Returns the IOBuffer itself
            elseif name === :truncate
                # First arg is the IOBuffer — just leave it on stack
                # (already compiled by the args loop above)
                # No-op: WasmGC arrays don't need explicit truncation

            # Handle getindex_continued (multi-byte string char access)
            # WBUILD-8001: UTF-8 byte continuation not implemented.
            # In WasmGC, strings are array<i32> (one codepoint per element),
            # so multi-byte continuation shouldn't be needed. If hit, it means
            # a code path assumes byte-level string access.
            elseif name === :getindex_continued
                bgic = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                record_unsupported!(ctx, :unsupported_method, "string getindex_continued (byte-level multibyte access)"; idx=idx)
                unreachable!(bgic)
                append!(bytes, builder_code(bgic))
                ctx.last_stmt_was_stub = true

            # Handle print_to_string (used in string interpolation / error messages)
            # PURE-9016: Convert each arg to string and concatenate
            elseif name === :print_to_string
                bpts = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                str_type_idx_pt = get_string_array_type!(ctx.mod, ctx.type_registry)
                str_arr_type_pt = ConcreteRef(str_type_idx_pt, true)
                n_pt = length(args)

                if n_pt == 0
                    # No args — return empty string
                    array_new_fixed!(bpts, str_type_idx_pt, 0, I32)
                else
                    # Convert each arg to string, store in locals
                    str_locals_pt = UInt32[]
                    for i in 1:n_pt
                        local_idx = allocate_local!(ctx, str_arr_type_pt)
                        push!(str_locals_pt, local_idx)

                        arg_type = infer_value_type(args[i], ctx)
                        if arg_type === String || arg_type === Symbol
                            # Already a string — just compile it
                            emit_value!(bpts, args[i], ctx)
                        elseif arg_type === Int32 || arg_type === Int64 ||
                               arg_type === UInt32 || arg_type === UInt64 ||
                               arg_type === Int16 || arg_type === UInt16 ||
                               arg_type === Int8 || arg_type === UInt8
                            # Integer — convert via int_to_string
                            int_to_string_info_pt = nothing
                            if ctx.func_registry !== nothing
                                try
                                    int_to_string_func_pt = getfield(WasmTarget, :int_to_string)
                                    int_to_string_info_pt = get_function(ctx.func_registry, int_to_string_func_pt, (Int32,))
                                catch; end
                            end
                            if int_to_string_info_pt !== nothing
                                emit_value!(bpts, args[i], ctx)
                                if arg_type === Int64 || arg_type === UInt64
                                    num!(bpts, Opcode.I32_WRAP_I64)
                                end
                                call!(bpts, int_to_string_info_pt.wasm_idx, WasmValType[], WasmValType[])
                            else
                                # No int_to_string available — emit empty string
                                array_new_fixed!(bpts, str_type_idx_pt, 0, I32)
                            end
                        else
                            # Unsupported type — emit empty string placeholder
                            array_new_fixed!(bpts, str_type_idx_pt, 0, I32)
                        end

                        local_set!(bpts, local_idx)
                    end

                    if n_pt == 1
                        # Single arg — just return it
                        local_get!(bpts, str_locals_pt[1])
                    else
                        # N-way concatenation: same inline pattern as multi-arg string()
                        offset_local_pt = allocate_local!(ctx, I32)
                        total_len_local_pt = allocate_local!(ctx, I32)
                        result_local_pt = allocate_local!(ctx, str_arr_type_pt)

                        # Compute total length
                        i32_const!(bpts, 0)
                        for i in 1:n_pt
                            local_get!(bpts, str_locals_pt[i])
                            array_len!(bpts)
                            num!(bpts, Opcode.I32_ADD)
                        end
                        local_set!(bpts, total_len_local_pt)

                        # Allocate result
                        local_get!(bpts, total_len_local_pt)
                        array_new_default!(bpts, str_type_idx_pt)
                        local_set!(bpts, result_local_pt)

                        # Copy each string
                        i32_const!(bpts, 0)
                        local_set!(bpts, offset_local_pt)

                        for i in 1:n_pt
                            local_get!(bpts, result_local_pt)
                            local_get!(bpts, offset_local_pt)
                            local_get!(bpts, str_locals_pt[i])
                            i32_const!(bpts, 0)
                            local_get!(bpts, str_locals_pt[i])
                            array_len!(bpts)
                            array_copy!(bpts, str_type_idx_pt, str_type_idx_pt)

                            local_get!(bpts, offset_local_pt)
                            local_get!(bpts, str_locals_pt[i])
                            array_len!(bpts)
                            num!(bpts, Opcode.I32_ADD)
                            local_set!(bpts, offset_local_pt)
                        end

                        local_get!(bpts, result_local_pt)
                    end
                end
                return builder_code(bpts)

            # PURE-1102: Error/throw functions — emit throw (catchable) instead of unreachable (trap)
            # PURE-9032: Create exception struct objects and stash in $current_exn
            # so that :the_exception + isa checks can identify the exception type.
            elseif name === :error
                berr = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                exn_global = ensure_exception_global!(ctx.mod)
                # error("msg") → create ErrorException struct, stash, throw
                local _ee_info = register_struct_type!(ctx.mod, ctx.type_registry, ErrorException)
                if _ee_info !== nothing
                    local _tid_err = UInt8[]
                    emit_type_id!(_tid_err, ctx.type_registry, ErrorException)
                    emit_raw!(berr, _tid_err; pushes=WasmValType[I32])
                    # Field 1: msg (ArrayRef for AbstractString)
                    if length(args) >= 1
                        emit_value!(berr, args[1], ctx)
                    else
                        ref_null!(berr, ArrayRef)
                    end
                    struct_new!(berr, _ee_info.wasm_type_idx, WasmValType[])
                    global_set!(berr, exn_global)
                end
                throw_!(berr, 0)
                ctx.last_stmt_was_stub = true
                return builder_code(berr)
            elseif name === :throw || name === :throw_boundserror ||
                   name === :ArgumentError || name === :AssertionError ||
                   name === :KeyError || name === :ErrorException ||
                   name === :BoundsError || name === :MethodError
                bthr = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                exn_global = ensure_exception_global!(ctx.mod)
                # Try to create a proper exception struct for known error types
                local _exn_type = nothing
                if name === :BoundsError; _exn_type = BoundsError
                elseif name === :ErrorException; _exn_type = ErrorException
                elseif name === :ArgumentError; _exn_type = ArgumentError
                elseif name === :KeyError; _exn_type = KeyError
                elseif name === :MethodError; _exn_type = MethodError
                end
                if _exn_type !== nothing
                    local _exn_info = register_struct_type!(ctx.mod, ctx.type_registry, _exn_type)
                    if _exn_info !== nothing
                        # Create struct with default fields using struct.new_default
                        struct_new_default!(bthr, _exn_info.wasm_type_idx)
                        global_set!(bthr, exn_global)
                    end
                end
                throw_!(bthr, 0)
                ctx.last_stmt_was_stub = true  # PURE-908
                return builder_code(bthr)

            # Handle JuliaSyntax internal functions that have complex implementations
            # These are intercepted and compiled as simplified stubs
            elseif name === :parse_float_literal
                # WBUILD-8001: Float literal parsing not implemented (orig uses
                # ccall(:jl_strtod_c)). Strict Approach A — loud reject (returns a
                # value natively, so a silent trap would diverge).
                emit_unsupported_stub!(ctx, bytes, :unsupported_method,
                    "parse_float_literal (JuliaSyntax float parsing — needs jl_strtod_c)"; idx=idx)

            elseif name === :parse_int_literal ||
                   name === :parse_uint_literal
                # WBUILD-8001: Int/uint literal parsing not implemented.
                emit_unsupported_stub!(ctx, bytes, :unsupported_method,
                    "parse_int/uint_literal (JuliaSyntax integer parsing)"; idx=idx)

            # Handle unalias — identity in WasmGC (arrays never alias)
            # unalias(dest, src) checks if dest and src share backing memory
            # and copies src if they do. In WasmGC, every array.new creates a
            # distinct GC object, so aliasing is impossible. Just return src.
            elseif name === :unalias
                # Discard accumulated argument bytes and re-compile just src (arg 2)
                bua = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                src_arg = expr.args[4]  # args: [mi, func_ref, dest, src]
                emit_value!(bua, src_arg, ctx)
                return builder_code(bua)

            # Handle push!/pop! growth closures from Base (_growend!)
            # These are generated when Julia inlines push! and need to resize the array
            # The closure name starts with # (e.g., #_growend!##0)
            # For WasmGC, we implement array growth inline:
            # 1. Allocate new array with 2x capacity
            # 2. Copy elements from old array using array.copy
            # 3. Update the vector's ref field
            # WBUILD-3001: sizehint! is a memory optimization hint — no-op in WasmGC.
            # WasmGC arrays have no capacity concept. Return the vector argument unchanged.
            # sizehint!(v, n) → v; #sizehint!#81(shrink, first, sizehint!, v, n) → v
            # Must be checked BEFORE the "#" closure handler below, since #sizehint!#81
            # starts with "#" and would be incorrectly caught by the _growend! handler.
            elseif name === :sizehint! || name === Symbol("#sizehint!#81")
                bsh = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                # The vector argument: for sizehint! it's args[1], for #sizehint!#81 it's args[4]
                vec_arg = name === :sizehint! ? (length(args) >= 1 ? args[1] : nothing) :
                          (length(args) >= 4 ? args[4] : nothing)
                if vec_arg !== nothing
                    emit_value!(bsh, vec_arg, ctx)
                else
                    record_unsupported!(ctx, :unsupported_method, "vector op: argument vector unavailable"; idx=idx)
                    unreachable!(bsh)
                end
                return builder_code(bsh)

            elseif meth.module === Base && startswith(string(name), "#")
                # Clear any accumulated bytes from argument compilation
                bytes = UInt8[]

                # Drop the closure object from the stack if it's there
                func_ref = expr.args[2]
                if func_ref isa Core.SSAValue
                    if !haskey(ctx.ssa_locals, func_ref.id) && !haskey(ctx.phi_locals, func_ref.id)
                        bgrd = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                        drop!(bgrd)
                        append!(bytes, builder_code(bgrd))
                    end
                end

                # Find the vector being grown from the :new expression
                # The closure's first captured field is the vector
                vec_arg = nothing
                vec_julia_type = nothing
                if func_ref isa Core.SSAValue
                    new_stmt = ctx.code_info.code[func_ref.id]
                    if new_stmt isa Expr && new_stmt.head === :new && length(new_stmt.args) >= 2
                        vec_arg = new_stmt.args[2]  # First captured field = vector
                    end
                end

                # Get the vector Julia type from the closure type's first field
                closure_type = mi.specTypes.parameters[1]
                if length(fieldnames(closure_type)) >= 1
                    vec_julia_type = fieldtype(closure_type, 1)
                end

                # Emit array growth code if we can determine the vector type
                ssa_type_here = get(ctx.ssa_types, idx, Any)
                has_local_here = haskey(ctx.ssa_locals, idx)
                vec_in_registry = vec_julia_type !== nothing && haskey(ctx.type_registry.structs, vec_julia_type)
                if vec_arg !== nothing && vec_julia_type !== nothing &&
                   vec_julia_type <: AbstractVector && haskey(ctx.type_registry.structs, vec_julia_type)

                    vec_info = ctx.type_registry.structs[vec_julia_type]
                    vec_type_idx = vec_info.wasm_type_idx
                    elem_type = eltype(vec_julia_type)
                    arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                    # Allocate scratch locals for array growth
                    old_arr_local = allocate_local!(ctx, ConcreteRef(arr_type_idx, true))
                    new_arr_local = allocate_local!(ctx, ConcreteRef(arr_type_idx, true))
                    old_cap_local = allocate_local!(ctx, I32)
                    vec_scratch_local = allocate_local!(ctx, ConcreteRef(vec_type_idx, true))

                    bgr = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)

                    # 1. Get the vector and store in local
                    emit_value!(bgr, vec_arg, ctx)
                    # PURE-045: heap type for ref.cast must use signed LEB128
                    ref_cast!(bgr, Int64(vec_type_idx), true)
                    local_set!(bgr, vec_scratch_local)

                    # 2. Get old backing array and store
                    local_get!(bgr, vec_scratch_local)
                    struct_get!(bgr, vec_type_idx, UInt32(1), ConcreteRef(UInt32(arr_type_idx), true))  # field 1 = array ref (field 0 = typeId)
                    # PURE-045: heap type for ref.cast must use signed LEB128
                    ref_cast!(bgr, Int64(arr_type_idx), true)
                    local_set!(bgr, old_arr_local)

                    # 3. Get old capacity
                    local_get!(bgr, old_arr_local)
                    array_len!(bgr)
                    local_set!(bgr, old_cap_local)

                    # 4. New capacity = max(old_cap * 2, old_cap + 4)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 2)
                    num!(bgr, Opcode.I32_MUL)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 4)
                    num!(bgr, Opcode.I32_ADD)
                    # select: [val_true, val_false, cond] -> val_true if cond!=0
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 2)
                    num!(bgr, Opcode.I32_MUL)
                    local_get!(bgr, old_cap_local)
                    i32_const!(bgr, 4)
                    num!(bgr, Opcode.I32_ADD)
                    num!(bgr, Opcode.I32_GE_S)
                    select!(bgr)

                    # 5. Create new array with new capacity
                    array_new_default!(bgr, arr_type_idx)
                    local_set!(bgr, new_arr_local)

                    # 6. Copy old elements: array.copy [dst, dst_off, src, src_off, len]
                    local_get!(bgr, new_arr_local)
                    i32_const!(bgr, 0)  # dst_off = 0
                    local_get!(bgr, old_arr_local)
                    i32_const!(bgr, 0)  # src_off = 0
                    local_get!(bgr, old_cap_local)
                    array_copy!(bgr, arr_type_idx, arr_type_idx)

                    # 7. Update vector's backing array field
                    local_get!(bgr, vec_scratch_local)
                    local_get!(bgr, new_arr_local)
                    struct_set!(bgr, vec_type_idx, UInt32(1), ConcreteRef(UInt32(arr_type_idx), true))  # field 1 = array ref (field 0 = typeId)

                    append!(bytes, builder_code(bgr))

                    # 8. Growth code is side-effect only — no wasm value produced.
                    #    Mark the SSA type as Nothing so statement_produces_wasm_value
                    #    returns false and flow generators don't emit DROP.
                    ctx.ssa_types[idx] = Nothing
                    # Also remove the SSA local to prevent compile_statement's
                    # safety check from replacing the growth code with ref.null.
                    # The growth code starts with local.get of the vector, which
                    # has a different type than the MemoryRef SSA local — without
                    # this delete, the safety check sees a type mismatch and
                    # replaces all growth code with a type-safe default.
                    delete!(ctx.ssa_locals, idx)

                else
                    # Fallback: can't determine vector type — emit unreachable
                    bgrf = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    record_unsupported!(ctx, :unsupported_method, "vector op: element type undeterminable"; idx=idx)
                    unreachable!(bgrf)
                    append!(bytes, builder_code(bgrf))
                    ctx.last_stmt_was_stub = true  # PURE-908
                end

            elseif name === :Symbol && length(args) == 1
                # Symbol(s::String) — in WasmGC, Symbol IS String (both are byte arrays).
                # The argument String is already on the stack from arg compilation above.
                # Just pass it through — no conversion needed.
                # (args were already compiled and pushed to `bytes` above)

            # PURE-6024: typeintersect(T1, T2) — C runtime function used in tuple convert.
            # With unoptimized IR (may_optimize=false), the convert inlines typeintersect.
            # Evaluate at compile time when both args are constant Type values.
            elseif name === :typeintersect && length(args) >= 2 && args[1] isa Type && args[2] isa Type
                # Evaluate at compile time — pure function with constant args
                result_type = typeintersect(args[1], args[2])
                bti2 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-pushed args
                global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, result_type)
                global_get!(bti2, global_idx, AnyRef)
                # Convert concrete ref to externref (Type values are externref in general context)
                extern_convert_any!(bti2)
                return builder_code(bti2)

            # PURE-6024: _tuple_error — error function in tuple convert dead code path.
            # Emit throw (catchable) instead of unreachable (trap).
            elseif name === :_tuple_error
                bte = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                throw_!(bte, 0)
                ctx.last_stmt_was_stub = true  # PURE-908
                return builder_code(bte)

            # Julia 1.13: hash_bytes(ptr, len, seed, secret) replaces memhash foreigncall
            # Trace ptr back to jl_string_ptr to find original string, then use FNV-1a helper
            elseif name === :hash_bytes
                bhb = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # Clear pre-pushed args
                str_arg = nothing
                # args: [CodeInstance/MI, func_ref, ptr, len, seed, secret]
                if length(expr.args) >= 3
                    ptr_arg = expr.args[3]
                    if ptr_arg isa Core.SSAValue
                        ptr_stmt = ctx.code_info.code[ptr_arg.id]
                        if ptr_stmt isa Expr && ptr_stmt.head === :foreigncall
                            ptr_name = length(ptr_stmt.args) >= 1 ? extract_foreigncall_name(ptr_stmt.args[1]) : nothing
                            if ptr_name === :jl_string_ptr && length(ptr_stmt.args) >= 6
                                str_arg = ptr_stmt.args[6]
                            end
                        end
                    end
                end
                if str_arg !== nothing
                    hash_func_idx = get_or_create_string_hash_func!(ctx.mod, ctx.type_registry)
                    emit_value!(bhb, str_arg, ctx,
                        ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))  # parity(M9): funnel → DATA
                    # len arg
                    if length(expr.args) >= 4
                        emit_value!(bhb, expr.args[4], ctx)  # length i64
                    else
                        i64_const!(bhb, 0)
                    end
                    # seed arg (UInt64 → i32)
                    if length(expr.args) >= 5
                        emit_value!(bhb, expr.args[5], ctx)
                        seed_type = infer_value_type(expr.args[5], ctx)
                        if seed_type === UInt64 || seed_type === Int64 || seed_type === Int
                            num!(bhb, Opcode.I32_WRAP_I64)
                        end
                    else
                        i32_const!(bhb, 0)
                    end
                    call!(bhb, hash_func_idx, WasmValType[], WasmValType[])
                else
                    # Can't trace string — fallback to constant hash
                    i64_const!(bhb, 0)
                end
                return builder_code(bhb)

            # ================================================================
            # Struct constructor via :invoke — immutable structs with only
            # reference-type fields (e.g., all-String) use :invoke instead
            # of :new.  Detect Type{T} as first specTypes parameter and
            # emit struct.new with the pre-compiled field values.
            # ================================================================
            elseif mi !== nothing && begin
                    local _sc_sig = mi.specTypes
                    local _sc_ok = false
                    if _sc_sig isa DataType && _sc_sig <: Tuple && length(_sc_sig.parameters) >= 1
                        local _sc_fp = _sc_sig.parameters[1]
                        if _sc_fp isa DataType && _sc_fp <: Type && length(_sc_fp.parameters) >= 1
                            local _sc_tt = _sc_fp.parameters[1]
                            # Only a FIELD-WISE constructor (one arg per struct field) can be
                            # lowered to a bare struct.new: it needs exactly `fieldcount` operands.
                            # A non-field-wise constructor reached via :invoke (e.g.
                            # `Dict{K,V}(ps::Pair...)`, which allocates keys/vals Memory + hashes)
                            # has a DIFFERENT arg count, so mapping its args straight onto the
                            # struct fields emits silently-invalid wasm (`struct.new $Dict` fed 3
                            # Pairs into 8 fields → "expected i64, found (ref …)"). Guard on
                            # arg-count == field-count so this branch fires ONLY when it can emit
                            # valid wasm; the rest loud-reject via the terminal :unsupported_method.
                            _sc_ok = _sc_tt isa DataType && is_struct_type(_sc_tt) &&
                                     (haskey(ctx.type_registry.structs, _sc_tt) ||
                                      (isconcretetype(_sc_tt) && isstructtype(_sc_tt))) &&
                                     isconcretetype(_sc_tt) && fieldcount(_sc_tt) == length(args)
                        end
                    end
                    _sc_ok
                end
                # Extract target type from Type{T}
                local _ctor_target = mi.specTypes.parameters[1].parameters[1]::DataType
                # Clear pre-compiled args — we re-emit in correct order with typeId
                bytes = UInt8[]
                # Register struct type if not already registered
                if !haskey(ctx.type_registry.structs, _ctor_target)
                    register_struct_type!(ctx.mod, ctx.type_registry, _ctor_target)
                end
                local _ctor_sinfo = ctx.type_registry.structs[_ctor_target]
                if _ctor_sinfo !== nothing
                    # field 0: typeId (i32)
                    emit_type_id!(bytes, ctx.type_registry, _ctor_target)
                    # Compile each constructor argument as a struct field value
                    for _fi in 1:length(args)
                        local _ftype = _fi <= length(_ctor_sinfo.field_types) ? _ctor_sinfo.field_types[_fi] : Any
                        local _fval_wasm = compile_value_typed(args[_fi], ctx)[2]
                        local _fval_numeric = _fval_wasm === I32 || _fval_wasm === I64 || _fval_wasm === F32 || _fval_wasm === F64
                        if _fval_numeric && (_ftype === Any || isabstracttype(_ftype))
                            emit_numeric_to_anyref!(bytes, args[_fi], _fval_wasm, ctx)
                        else
                            append!(bytes, compile_value(args[_fi], ctx))  # god-fn seam: typed when the caller goes builder-native (M4 tail)
                        end
                    end
                    # struct.new
                    bscn = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    struct_new!(bscn, _ctor_sinfo.wasm_type_idx, WasmValType[])
                    append!(bytes, builder_code(bscn))
                else
                    # Registration failed — codegen cannot lay out this struct type.
                    record_unsupported!(ctx, :unsupported_type,
                        "struct constructor for `$(_ctor_target)` (type registration failed)"; idx=idx, detail=expr)
                    bscnf = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                    record_unsupported!(ctx, :unsupported_method, "struct type registration failed (cannot lay out)"; idx=idx)
                    unreachable!(bscnf)
                    append!(bytes, builder_code(bscnf))
                    ctx.last_stmt_was_stub = true
                end

            elseif get(ctx.ssa_types, idx, Any) === Union{}
                # P3 gap 8029d25b6d15: an :invoke with inferred rettype Union{}
                # ALWAYS throws natively (e.g. Int32(::Int64) after const-prop
                # pins an out-of-range literal). The native behaviour IS a
                # throw, so emit a catchable tag-0 throw — unreachable would
                # turn a natively-catchable error into an uncatchable trap.
                bi32 = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)  # discard pre-pushed args
                ensure_exception_tag!(ctx.mod)
                exn_global = ensure_exception_global!(ctx.mod)
                ref_null!(bi32, AnyRef)        # ref.null any
                global_set!(bi32, exn_global)
                throw_!(bi32, 0)
                ctx.last_stmt_was_stub = true  # PURE-908
                return builder_code(bi32)
            elseif name === :padding && length(args) == 2 &&
                   args[1] isa Type && args[2] isa Integer
                # P4-stdlib (Random hash_seed): padding(T, n) of literal args is
                # a compile-time constant SimpleVector. No svec constant
                # emission exists — emit a benign null placeholder (NOT a stub:
                # a stub dead-codes the rest of the block) and let consumers
                # (_svec_len etc.) fold against the host value via
                # _try_host_svec.
                bpad = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                ref_null!(bpad, ArrayRef)
                return builder_code(bpad)

            elseif name === :array_subpadding && length(args) == 2 &&
                   args[1] isa Type && args[2] isa Type
                # P4-stdlib (Statistics median): Base.array_subpadding is a pure
                # compile-time layout predicate guarding reinterpret-based radix
                # sort paths, and its args arrive as literal types — host-evaluate
                # and emit the Bool constant (the stub trapped the whole
                # IEEEFloatOptimization sort path at runtime).
                bsub = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)   # discard pre-pushed args
                i32_const!(bsub, Base.array_subpadding(args[1], args[2]) ? 1 : 0)
                return builder_code(bsub)

            else
                # Unknown method — codegen has no translation for this invoke target.
                # Under strict=true this raises WasmCompileError naming the method + source
                # location; under strict=false it emits unreachable (traps at runtime),
                # which lets compilation succeed for paths that never reach this method.
                haskey(ENV, "WT_TRACE_STUBARGS") && println(stderr, "STUBARGS ", name, " args=", repr(args))
                record_unsupported!(ctx, :unsupported_method,
                    "method `$name`" * (mi !== nothing ? " for $(mi.specTypes)" : "");
                    idx=idx, detail=expr)
                bunk = InstrBuilder(; func_name="compile_invoke", mod=ctx.mod)
                record_unsupported!(ctx, :unsupported_method, "unknown invoke target (no handler arm)"; idx=idx)
                unreachable!(bunk)
                append!(bytes, builder_code(bunk))
                ctx.last_stmt_was_stub = true  # PURE-908
            end
        end
    end

    return bytes
end

