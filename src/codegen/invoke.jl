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
_compile_invoke_str_hash(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_hash_b(args, ctx))

"""builder-returning core (march4)."""
function _compile_invoke_str_hash_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

    b = InstrBuilder(; func_name="_compile_invoke_str_hash")

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

    return b
end

"""
Extract: str_find(haystack, needle) -> Int32. Returns 1-based position or 0 if not found.
"""
_compile_invoke_str_find(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_find_b(args, ctx))

"""builder-returning core (march3): callers merge via append_builder!."""
function _compile_invoke_str_find_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_find")

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

    return b
end

"""
Extract: str_contains(haystack, needle) -> Bool. Returns true if needle is found in haystack.
"""
_compile_invoke_str_contains(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_contains_b(args, ctx))

"""builder-returning core (march4)."""
function _compile_invoke_str_contains_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_contains")

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

    return b
end

"""
Extract: str_startswith(s, prefix) -> Bool.
"""
_compile_invoke_str_startswith(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_startswith_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_startswith_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_startswith")

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

    return b
end

"""
Extract: str_endswith(s, suffix) -> Bool.
"""
_compile_invoke_str_endswith(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_endswith_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_endswith_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_endswith")

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

    return b
end

"""
BF-2000: repeat(s, n) -> String. Repeat string s n times.
Uses WasmGC array.new_default + loop with array.copy.
"""
_compile_invoke_str_repeat(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_repeat_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_repeat_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_repeat")

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
    n_type = infer_value_type(args[2], ctx)
    emit_value!(b, args[2], ctx, (n_type === Int64 || n_type === Int) ? I64 : I32)   # march14
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

    return b
end

"""
BF-2000: lpad(s, n, c) -> String. Left-pad string s to length n with char c.
"""
_compile_invoke_str_lpad(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_lpad_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_lpad_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_lpad")

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
    n_type = infer_value_type(args[2], ctx)
    emit_value!(b, args[2], ctx, (n_type === Int64 || n_type === Int) ? I64 : I32)   # march14
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
        emit_value!(b, char_arg, ctx, I32)   # march14: Julia-encoded char bits
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

    return b
end

"""
BF-2000: rpad(s, n, c) -> String. Right-pad string s to length n with char c.
"""
_compile_invoke_str_rpad(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_rpad_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_rpad_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_rpad")

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
    n_type = infer_value_type(args[2], ctx)
    emit_value!(b, args[2], ctx, (n_type === Int64 || n_type === Int) ? I64 : I32)   # march14
    if n_type === Int64 || n_type === Int
        num!(b, Opcode.I32_WRAP_I64)
    end
    local_set!(b, n_local)

    # Store pad char as i32 (convert from Julia Char encoding to UTF-8 byte)
    char_arg = args[3]
    if char_arg isa Char
        i32_const!(b, Int32(UInt32(char_arg)))
    else
        emit_value!(b, char_arg, ctx, I32)   # march14: Julia-encoded char bits
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

    return b
end

"""
Extract: str_uppercase(s) -> String. Convert lowercase ASCII letters to uppercase.
"""
_compile_invoke_str_uppercase(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_uppercase_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_uppercase_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_uppercase")

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

    return b
end

"""
Extract: str_lowercase(s) -> String. Convert uppercase ASCII letters to lowercase.
"""
_compile_invoke_str_lowercase(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_lowercase_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_lowercase_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_lowercase")

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

    return b
end

"""
Extract: str_trim(s) -> String. Remove leading and trailing ASCII whitespace.
"""
_compile_invoke_str_trim(args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_str_trim_b(args, ctx))

"""builder-returning core (march4): callers merge via append_builder!."""
function _compile_invoke_str_trim_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    b = InstrBuilder(; func_name="_compile_invoke_str_trim")

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

    return b
end

"""
Extract: println/print handler. Emits JS IO bridge imports.
"""
_compile_invoke_print(name::Symbol, args, ctx::AbstractCompilationContext)::Vector{UInt8} =
    builder_code(_compile_invoke_print_b(name, args, ctx))

"""builder-returning core (march4)."""
function _compile_invoke_print_b(name::Symbol, args, ctx::AbstractCompilationContext)::InstrBuilder
    io = get_io_imports()
    if io !== nothing
        b = _ctx_builder(ctx, "_compile_invoke_print")
        # parity(M9): the io bridge consumes the DATA array — every string value
        # funnels through the expected-type channel so classed strings unwrap here.
        _pr_str_arr = ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)
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
                emit_value!(b, arg, ctx, _pr_str_arr)
                # Need a temp local for tee
                tmp_local = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                emit_jl_string_to_js!(b, io.decode_idx)
                # (ref extern) is subtype of externref — no conversion needed
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                emit_value!(b, arg, ctx, I64)   # march14
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Int32
                emit_value!(b, arg, ctx, I32)   # march14
                num!(b, Opcode.I64_EXTEND_I32_S)
                call!(b, io.write_int_idx, WasmValType[I64], WasmValType[])
            elseif arg_type === Float64
                emit_value!(b, arg, ctx, F64)   # march14
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Float32
                emit_value!(b, arg, ctx, F32)   # march14
                num!(b, Opcode.F64_PROMOTE_F32)
                call!(b, io.write_float_idx, WasmValType[F64], WasmValType[])
            elseif arg_type === Bool
                emit_value!(b, arg, ctx, I32)   # step4
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
                emit_value!(b, arg, ctx, ConcreteRef(UInt32(vec_type_idx), true))   # step4

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
                struct_get!(b, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(data_array_idx), true))
                local_set!(b, data_local)

                # Get length: array.len
                local_get!(b, data_local)
                array_len!(b)
                local_set!(b, len_local)

                # Write "["
                emit_value!(b, "[", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
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
                emit_value!(b, ", ", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                end_block!(b)  # end if

                # Get element: data_arr[i]
                local_get!(b, data_local)
                local_get!(b, i_local)
                _elem_wt = (elem_type === Float64) ? F64 : (elem_type === Float32) ? F32 :
                           (elem_type === Int64 || elem_type === Int || elem_type === UInt64) ? I64 : I32
                array_get!(b, data_array_idx, _elem_wt; signed=packed_array_signedness(elem_type))

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
                    emit_value!(b, "?", ctx, _pr_str_arr)
                    emit_jl_string_to_js!(b, io.decode_idx)
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
                emit_value!(b, "]", ctx, _pr_str_arr)
                emit_jl_string_to_js!(b, io.decode_idx)
                call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
            elseif arg_type !== nothing && arg_type <: Tuple && arg_type isa DataType
                # PURE-9067: Tuple display — emit "(e1, e2, ...)"
                tuple_info = register_tuple_type!(ctx.mod, ctx.type_registry, arg_type)
                if tuple_info !== nothing
                    tuple_type_idx = tuple_info.wasm_type_idx
                    elem_types = arg_type.parameters

                    # Compile tuple value and store in local
                    emit_value!(b, arg, ctx, ConcreteRef(UInt32(tuple_type_idx), true))   # step4
                    tup_local = UInt32(allocate_local!(ctx, ConcreteRef(tuple_type_idx, true)))
                    str_tmp_local2 = UInt32(allocate_local!(ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true)))
                    local_set!(b, tup_local)

                    # Write "("
                    emit_value!(b, "(", ctx, _pr_str_arr)
                    emit_jl_string_to_js!(b, io.decode_idx)
                    call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])

                    for (fi, et) in enumerate(elem_types)
                        # Write ", " separator (after first element)
                        if fi > 1
                            emit_value!(b, ", ", ctx, _pr_str_arr)
                            emit_jl_string_to_js!(b, io.decode_idx)
                            call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                        end

                        # Get field: struct.get (field index = fi because of typeId at 0)
                        local_get!(b, tup_local)
                        _et_wt = (et === Float64) ? F64 : (et === Float32) ? F32 :
                                 (et === Int64 || et === Int || et === UInt64) ? I64 : I32
                        struct_get!(b, tuple_type_idx, wasm_field_idx(tuple_info, fi), _et_wt)

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
                            emit_value!(b, "?", ctx, _pr_str_arr)
                            emit_jl_string_to_js!(b, io.decode_idx)
                            call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                        end
                    end

                    # Single-element tuple gets trailing comma: (1,)
                    if length(elem_types) == 1
                        emit_value!(b, ",", ctx, _pr_str_arr)
                        emit_jl_string_to_js!(b, io.decode_idx)
                        call!(b, io.write_string_idx, WasmValType[ExternRef], WasmValType[])
                    end

                    # Write ")"
                    emit_value!(b, ")", ctx, _pr_str_arr)
                    emit_jl_string_to_js!(b, io.decode_idx)
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
        return b
    else
        # No IO imports — stub as no-op (empty builder)
        return _ctx_builder(ctx, "_compile_invoke_print")
    end
end

"""Prove that a concrete vararg constructor is only `%new(T, fixed..., varargs)`.

This is deliberately shape-based, not name-based: the optimized Julia body must
contain exactly one allocation and a return, and its fields must be the method's
fixed slots followed by its one vararg-tuple slot.
"""
function _is_direct_vararg_struct_constructor(@nospecialize(target), mi::Core.MethodInstance,
                                               arg_types::Tuple)::Bool
    target isa DataType && isconcretetype(target) && isstructtype(target) || return false
    mi.def isa Method && mi.def.isva || return false
    fixed_count = mi.def.nargs - 2  # exclude #self# and the vararg tuple slot
    fieldcount(target) == fixed_count + 1 || return false
    typed = try
        Base.code_typed(target, arg_types; optimize=true)
    catch
        return false
    end
    length(typed) == 1 || return false
    ci = first(typed).first
    ci isa Core.CodeInfo || return false
    news = Expr[s for s in ci.code if s isa Expr && s.head === :new]
    length(news) == 1 || return false
    all(s -> s === nothing || s isa Core.ReturnNode ||
             (s isa Expr && (s.head === :new || s.head === :meta)), ci.code) || return false
    alloc = only(news)
    length(alloc.args) == fieldcount(target) + 1 || return false
    tref = alloc.args[1]
    resolved = tref isa GlobalRef && isdefined(tref.mod, tref.name) ? getfield(tref.mod, tref.name) : tref
    resolved === target || return false
    for i in 1:fixed_count
        alloc.args[i + 1] == Core.Argument(i + 1) || return false
    end
    return alloc.args[end] == Core.Argument(fixed_count + 2)
end

_invoke_arg_static_type(arg, ctx::AbstractCompilationContext) =
    arg isa Type ? Core.Typeof(arg) : infer_value_type(arg, ctx)

"""
Compile an invoke expression (method invocation) — dart visitor shape (march4):
emits the invoke INTO the caller's builder.
The interior accumulates into a FRAGMENT builder `fb` (≡ the old `bytes` buffer,
same discard semantics: arms that replace it re-init; exits merge typed).
"""
function compile_invoke!(b::InstrBuilder, expr::Expr, idx::Int, ctx::AbstractCompilationContext)
    fb = _ctx_builder(ctx, "compile_invoke.frag")
    _seed_builder_locals!(fb, ctx)

    # Early skip check — before compiling arguments.
    # Skipped statements emit nothing (NOP). This prevents argument values
    # (e.g., string constants for js() calls) from being compiled to WASM.
    if idx in ctx.skip_stmts
        return append_builder!(b, fb)
    end

    # Invoke import check — emit CALL to a WASM import function.
    # Used by Therapy.jl to wire js() calls as WASM imports (Leptos pattern).
    if haskey(ctx.invoke_imports, idx)
        import_idx = ctx.invoke_imports[idx]
        bii = _ctx_builder(ctx, "compile_invoke")
        call!(bii, import_idx, WasmValType[], WasmValType[])
        return append_builder!(b, bii)
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
            bsg = _ctx_builder(ctx, "compile_invoke")
            global_get!(bsg, global_idx, AnyRef)
            return append_builder!(b, bsg)
        end
        # Signal setter: one arg, sets the signal value
        if haskey(ctx.signal_ssa_setters, ssa_id) && length(args) == 1
            global_idx = ctx.signal_ssa_setters[ssa_id]
            bss2 = _ctx_builder(ctx, "compile_invoke")
            # Compile the argument (the new value)
            emit_value!(bss2, args[1], ctx, ctx.mod.globals[Int(global_idx) + 1].valtype)   # step4
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
                    emit_convert_to_f64!(bss2, global_type)
                    # Call the DOM import function
                    call!(bss2, import_idx, WasmValType[], WasmValType[])
                end
            end

            # Setter returns the value in Therapy.jl, so re-read it
            global_get!(bss2, global_idx, AnyRef)
            return append_builder!(b, bss2)
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

    if mi isa Core.MethodInstance && mi.def isa Method &&
       mi.def.name in (:_closed_world_type_bounds, :check_world_bounded) && length(args) == 1
        wb = _ctx_builder(ctx, "compile_invoke.closed_world_type_bounds")
        emit_closed_world_type_bounds!(wb, args[1], ctx)
        return append_builder!(b, wb)
    end

    if mi isa Core.MethodInstance && mi.def isa Method &&
       mi.def.name in (:_closed_world_isvisible, :isvisible) && length(args) == 3
        symbol_owner = _trace_typename_symbol_owner(args[1], ctx)
        parent_owner = _trace_field_owner(args[2], :module, ctx)
        if symbol_owner !== nothing && isequal(symbol_owner, parent_owner)
            vb = _ctx_builder(ctx, "compile_invoke.closed_world_isvisible")
            emit_closed_world_isvisible!(vb, args[1], args[2], args[3], symbol_owner, ctx)
            return append_builder!(b, vb)
        end
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
    if target_info_early !== nothing
        first_explicit = 1 + early_argtypes_offset
        param_types = first_explicit <= length(target_info_early.arg_types) ?
            target_info_early.arg_types[first_explicit:end] : ()
    end

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
                    return append_builder!(b, _compile_invoke_str_lowercase_b([args[2]], ctx))
                elseif _func_param === typeof(uppercase)
                    return append_builder!(b, _compile_invoke_str_uppercase_b([args[2]], ctx))
                end
            end

            # _searchindex(String, String, Int64) → str_find (returns I32, widen to I64)
            if _name_early === :_searchindex && length(args) == 3
                bsi = _ctx_builder(ctx, "compile_invoke")
                append_builder!(bsi, _compile_invoke_str_find_b([args[1], args[2]], ctx))
                num!(bsi, Opcode.I64_EXTEND_I32_S)
                return append_builder!(b, bsi)
            end

            # BF-4000: #string#403(base, pad, typeof(string), x) → inline dec call
            # String interpolation "$x" and string(x::Integer) go through this kwarg method.
            # The typeof(string) arg is phantom (never used in body). Redirect to dec().
            if _name_early === Symbol("#string#403") && length(args) == 4 &&
               ctx.func_registry !== nothing
                _dec_info = get_function(ctx.func_registry, Base.dec, (UInt64, Int64, Bool))
                if _dec_info !== nothing
                    bd = _ctx_builder(ctx, "compile_invoke")
                    _x = args[4]  # the integer value

                    # Push abs(x) as I64 (same bits as UInt64): select(x, -x, x >= 0)
                    emit_value!(bd, _x, ctx, I64)  # x (true branch)
                    i64_const!(bd, 0)                                   # 0
                    emit_value!(bd, _x, ctx, I64)  # x
                    num!(bd, Opcode.I64_SUB)                            # -x (false branch)
                    emit_value!(bd, _x, ctx, I64)  # x
                    i64_const!(bd, 0)                                   # 0
                    num!(bd, Opcode.I64_GE_S)                           # x >= 0 (i32 condition)
                    select!(bd)                                         # abs(x)

                    # Push pad (arg 2)
                    emit_value!(bd, args[2], ctx, I64)

                    # Push x < 0 as i32 Bool
                    emit_value!(bd, _x, ctx, I64)
                    i64_const!(bd, 0)
                    num!(bd, Opcode.I64_LT_S)

                    # Call dec
                    call!(bd, _dec_info.wasm_idx, WasmValType[], WasmValType[])
                    return append_builder!(b, bd)
                end
            end

            # lstrip/rstrip(typeof(isspace), String) → str_trim
            if (_name_early === :lstrip || _name_early === :rstrip) && length(args) == 2 &&
               _spec_early isa DataType && _spec_early <: Tuple && length(_spec_early.parameters) >= 2
                _func_param = _spec_early.parameters[2]
                if _func_param === typeof(isspace)
                    return append_builder!(b, _compile_invoke_str_trim_b([args[2]], ctx))
                end
            end

            # startswith(String, String) → str_startswith
            if _name_early === :startswith && length(args) == 2
                return append_builder!(b, _compile_invoke_str_startswith_b([args[1], args[2]], ctx))
            end

            # endswith(String, String) → str_endswith
            if _name_early === :endswith && length(args) == 2
                return append_builder!(b, _compile_invoke_str_endswith_b([args[1], args[2]], ctx))
            end

            # BF-2000: repeat(String, Int64) → str_repeat
            if _name_early === :repeat && length(args) == 2
                # P6-trim: repeat(::Char, n) — the pad path inside the real Base
                # lpad/rpad bodies (now trim-compiled). Char is UTF-8 left-packed
                # in UInt32 (' ' = 0x20000000): byte = char >> 24, then a
                # byte-filled array.new (same single-byte assumption as str_lpad).
                local _rep_at = try infer_value_type(args[1], ctx) catch; nothing end
                if _rep_at === Char
                    br = _ctx_builder(ctx, "compile_invoke")
                    str_t = get_string_array_type!(ctx.mod, ctx.type_registry)
                    emit_value!(br, args[1], ctx, I32)  # char i32 (left-packed)
                    i32_const!(br, 24)
                    num!(br, Opcode.I32_SHR_U)                    # utf8 byte
                    emit_value!(br, args[2], ctx, I64)  # count i64
                    num!(br, Opcode.I32_WRAP_I64)
                    array_new!(br, str_t, I32)                    # fill (value, len)
                    return append_builder!(b, br)
                end
                return append_builder!(b, _compile_invoke_str_repeat_b([args[1], args[2]], ctx))
            end

            # BF-2000: lpad(String, Int64, Char) → str_lpad
            if _name_early === :lpad && length(args) == 3
                return append_builder!(b, _compile_invoke_str_lpad_b([args[1], args[2], args[3]], ctx))
            end

            # BF-2000: rpad(String, Int64, Char) → str_rpad
            if _name_early === :rpad && length(args) == 3
                return append_builder!(b, _compile_invoke_str_rpad_b([args[1], args[2], args[3]], ctx))
            end
        end
    end

    # 453393ca4ba4: closure callee — the compiled function takes the closure
    # object as wasm param 1; push it before the explicit args
    if closure_self_to_push !== nothing
        emit_value!(fb, closure_self_to_push, ctx,
                    static_wasm_type(closure_self_to_push, ctx))   # THE typed value channel
    end

    # Push arguments through the resolved target signature. Each value is converted
    # while it is still on top of the stack; no post-push positional repairs exist.
    for (arg_idx, arg) in enumerate(args)

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
            _nb = _ctx_builder(ctx, "compile_invoke")
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
            append_builder!(fb, _nb)
        elseif is_nothing_arg
            # Nothing arg without param_types — emit ref.null anyref as safe default
            # PURE-9022: Use anyref (not externref) for internal polymorphic positions
            _nb2 = _ctx_builder(ctx, "compile_invoke")
            ref_null!(_nb2, AnyRef)
            append_builder!(fb, _nb2)
        else
            local _ab = _compile_value_b(arg, ctx)
            local arg_ty = isempty(_ab.v.stack) ? nothing : _ab.v.stack[end]
            local _ab_merged = false
            # P6-ioprint: function/type singleton args compile to EMPTY emissions, but
            # trim-collected callees keep the param in their wasm signature (legacy
            # discovery skipped such functions entirely, so this never fired before).
            # Push ref.null of the param's wasm type to keep the call aligned.
            if isempty(_ab.instrs) && param_types !== nothing && arg_idx <= length(param_types)
                local _sp_jt = try infer_value_type(arg, ctx) catch; nothing end
                if _sp_jt isa DataType && Base.issingletontype(_sp_jt)
                    local _sp_pt = param_types[arg_idx]
                    local _sp_w = get_concrete_wasm_type(_sp_pt isa Type ? _sp_pt : _sp_jt,
                                                         ctx.mod, ctx.type_registry)
                    local _spb = _ctx_builder(ctx, "compile_invoke")
                    if _sp_w isa ConcreteRef
                        ref_null!(_spb, Int64(_sp_w.type_idx), ConcreteRef(UInt32(_sp_w.type_idx), true))
                        append_builder!(fb, _spb)
                    elseif _sp_w === AnyRef || _sp_w === StructRef || _sp_w === ExternRef || _sp_w === EqRef
                        ref_null!(_spb, _sp_w)
                        append_builder!(fb, _spb)
                    end
                end
            end
            # (the arg merges below — AFTER the Nothing-phantom decision, which
            # previously popped the just-appended bytes back off)
            if param_types !== nothing && arg_idx <= length(param_types)
                expected_julia_type = param_types[arg_idx]
                # Skip non-Type values (e.g., Vararg markers)
                if expected_julia_type isa Type
                    expected_wasm = get_concrete_wasm_type(expected_julia_type, ctx.mod, ctx.type_registry)
                    actual_julia_type = infer_value_type(arg, ctx)
                    # march5 F8 (census: dart wrap = 100% of expressions through convertType,
                    # code_generator.dart:879): the whole inline coercion ladder — 14 arms
                    # re-implementing convertType — is ONE funnel call. The emission's own
                    # tracked type (dart carries the type with the value) refines `actual`;
                    # the old ssa_locals re-lookup died with the ladder.

                    # PURE-3111/4155: Handle Nothing→ref conversion.
                    # compile_value emits i32_const 0 for Nothing,
                    # but ref-typed params need ref.null. Must fix BEFORE bridging runs,
                    # otherwise bridging tries conversions on an i32 value.
                    # NOTE: Type{T} no longer needs this — it now emits global.get (DataType ref).
                    _is_phantom = actual_julia_type === Nothing
                    if _is_phantom && (expected_wasm isa ConcreteRef || expected_wasm === ExternRef || expected_wasm === StructRef || expected_wasm === AnyRef)
                        # the Nothing emission is exactly one i32.const 0 (ir/-kind test —
                        # the pop-two-bytes surgery is gone; we just don't merge the arg)
                        if length(_ab.instrs) == 1 && _ab.instrs[1] isa InstrIR.I32Const
                            if expected_wasm isa ConcreteRef
                                ref_null!(fb, Int64(expected_wasm.type_idx), ConcreteRef(UInt32(expected_wasm.type_idx), true))
                            else
                                ref_null!(fb, expected_wasm)
                            end
                            _ab_merged = true   # the phantom replaced the arg emission
                        end
                    end
                    # merge the arg (unless the phantom replaced it) BEFORE the coercion
                    _ab_merged || (append_builder!(fb, _ab); _ab_merged = true)

                    coerce_stack_top!(fb, expected_wasm, ctx;
                                      from_julia=(actual_julia_type isa Type && isconcretetype(actual_julia_type)) ? actual_julia_type : nothing)
                end
            end

            # merge fallback: paths without param_types (or non-Type entries) never
            # reached the typed merge above — the arg still lands exactly once
            _ab_merged || (append_builder!(fb, _ab); _ab_merged = true)
        end
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
                        # Cross-function call - emit call instruction with target index
                        # fullstrict: the args sit on the PARENT builder — seed the real
                        # param count (readable from the pre-declared placeholder).
                        local _cc_params = begin
                            local _m = ctx.mod
                            local _ni = count(imp -> imp.kind == 0x00, _m.imports)
                            local _fi = Int(target_info.wasm_idx) - _ni
                            local _ps = WasmValType[]
                            if _fi >= 0 && _fi < length(_m.functions)
                                local _ft = _m.types[Int(_m.functions[_fi + 1].type_idx) + 1]
                                _ft isa FuncType && (_ps = WasmValType[q for q in _ft.params])
                            end
                            _ps
                        end
                        haskey(ENV, "WT_DBG_CC") && println(stderr, "CC target=", target_info.name, " idx=", target_info.wasm_idx, " params=", _cc_params, " fbh=", length(fb.v.stack))
                        bcc = _sub_builder(fb, ctx, "compile_invoke", length(_cc_params);
                                           seed_types=_cc_params)   # the placeholder truth IS the contract
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
                        append_builder!(fb, bcc)
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
                local _rbx = _ctx_builder(ctx, "compile_invoke")
                emit_classid_box!(_rbx, ctx, is_32bit ? I32 : I64, nothing)
                append_builder!(fb, _rbx)
            end
            if is_self_call
                # Self-recursive call - emit call instruction
                # fullstrict: the args live on fb; the OWN placeholder sig is the contract
                local _sc_params = begin
                    local _m = ctx.mod
                    local _ni = count(imp -> imp.kind == 0x00, _m.imports)
                    local _fi = Int(ctx.func_idx) - _ni
                    local _ps = WasmValType[]
                    if _fi >= 0 && _fi < length(_m.functions)
                        local _ft = _m.types[Int(_m.functions[_fi + 1].type_idx) + 1]
                        _ft isa FuncType && (_ps = WasmValType[q for q in _ft.params])
                    end
                    _ps
                end
                bsc2 = _sub_builder(fb, ctx, "compile_invoke", length(_sc_params); seed_types=_sc_params)
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
                append_builder!(fb, bsc2)
            elseif cross_call_handled
                # Already handled above

            elseif name === :+ || name === :add_int
                badd = _ctx_builder(ctx, "compile_invoke")
                num!(badd, is_32bit ? Opcode.I32_ADD : Opcode.I64_ADD)
                append_builder!(fb, badd)
                _f3_result_box!()
            elseif name === :- || name === :sub_int
                if length(args) == 1
                    # WBUILD-3001: Unary negation -(x) → 0 - x. Prepend the 0 via
                    # fragment composition (the pushfirst! byte surgery is gone).
                    local _negb = _ctx_builder(ctx, "compile_invoke.frag")
                    _seed_builder_locals!(_negb, ctx)
                    is_32bit ? i32_const!(_negb, 0) : i64_const!(_negb, 0)
                    append_builder!(_negb, fb)
                    fb = _negb
                end
                bsub3 = _ctx_builder(ctx, "compile_invoke")
                num!(bsub3, is_32bit ? Opcode.I32_SUB : Opcode.I64_SUB)
                append_builder!(fb, bsub3)
                _f3_result_box!()
            elseif (name === :* || name === :mul_int) && length(args) == 2 &&
                   (infer_value_type(args[1], ctx) === String || infer_value_type(args[1], ctx) === Symbol) &&
                   (infer_value_type(args[2], ctx) === String || infer_value_type(args[2], ctx) === Symbol)
                # String/Symbol `*` is CONCATENATION: this name-keyed arithmetic
                # fallback fires when the concat MI failed to register as a
                # cross-call (its body bottoms out in Vararg _string) and was
                # emitting i64.mul on two string refs — the E-003 island's
                # fn#107 validation failure. Args were pre-pushed: rebuild.
                bcat = _ctx_builder(ctx, "compile_invoke")
                append_builder!(bcat, compile_string_concat_b(args[1], args[2], ctx))
                return append_builder!(b, bcat)
            elseif name === :* || name === :mul_int
                bmul = _ctx_builder(ctx, "compile_invoke")
                num!(bmul, is_32bit ? Opcode.I32_MUL : Opcode.I64_MUL)
                append_builder!(fb, bmul)
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
                            bpow = _ctx_builder(ctx, "compile_invoke")  # Reset
                            emit_value!(bpow, args[1], ctx, F32)   # step4: the promote follows
                            num!(bpow, Opcode.F64_PROMOTE_F32)  # f64.promote_f32 (0xBB)
                            emit_value!(bpow, args[2], ctx, arg2_type === Float32 ? F32 : F64)
                            if arg2_type === Float32
                                num!(bpow, Opcode.F64_PROMOTE_F32)  # f64.promote_f32 (0xBB)
                            end
                            fb = bpow   # discard-and-replace (march4)
                        end
                        bpow2 = _ctx_builder(ctx, "compile_invoke")
                        call!(bpow2, pow_import_idx, WasmValType[], WasmValType[])
                        # Convert back to f32 if needed
                        if arg1_type === Float32
                            num!(bpow2, Opcode.F32_DEMOTE_F64)  # f32.demote_f64 (0xB6)
                        end
                        append_builder!(fb, bpow2)
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
                blen = _ctx_builder(ctx, "compile_invoke")
                if arg_type === Any || arg_type === Union{}
                    any_convert_extern!(blen)        # externref → anyref
                    ref_cast!(blen, ArrayRef, true)  # anyref → (ref null array)
                end
                array_len!(blen)
                # array.len returns i32, extend to i64 for Julia's Int
                num!(blen, Opcode.I64_EXTEND_I32_S)
                append_builder!(fb, blen)

            # String concatenation: string * string -> string
            # Julia compiles string concatenation to Base._string
            # Also handle String, Symbol for error message construction
            elseif (name === :* || name === :_string) && length(args) >= 2 &&
                   _all_string_args(args, ctx)
                fb = compile_string_concat_many_b(args, ctx)

            # PURE-325: isascii(s) — check all bytes < 0x80
            # Called from normalize_identifier via isascii(codeunits(s)).
            # The argument is CodeUnits{UInt8,String} (a struct wrapping String).
            # Extract the String (field 0) from the struct, then iterate bytes.
            elseif name === :isascii && length(args) == 1
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
                arg_type = infer_value_type(args[1], ctx)

                basc = _ctx_builder(ctx, "compile_invoke")

                # If the argument is a CodeUnits struct, extract the String field.
                if arg_type !== String && arg_type !== Symbol
                    if haskey(ctx.type_registry.structs, arg_type)
                        cu_info = ctx.type_registry.structs[arg_type]
                        struct_get!(basc, cu_info.wasm_type_idx, wasm_field_idx(cu_info, 1), I32)
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
                append_builder!(fb, basc)

            # String equality comparison
            elseif name === :(==) && length(args) == 2 &&
                   infer_value_type(args[1], ctx) === String &&
                   infer_value_type(args[2], ctx) === String
                fb = compile_string_equal_b(args[1], args[2], ctx)

            # WasmTarget string operations - str_char(s, i) -> Int32
            elseif name === :str_char && length(args) == 2
                # Get character at index: array.get on string array
                # Args: string, index (1-based)
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Compile string arg (already pushed by args loop)
                # Compile index arg and convert to 0-based
                bchr = _ctx_builder(ctx, "compile_invoke")
                idx_type = infer_value_type(args[2], ctx)
                # parity(M9): the pre-pushed string is the CLASSED struct sitting UNDER
                # the index — save idx, read .data, reload idx.
                _sc_idx = length(ctx.locals) + ctx.n_params
                push!(ctx.locals, idx_type === Int64 || idx_type === Int ? I64 : I32)
                builder_set_local_type!(bchr, _sc_idx, idx_type === Int64 || idx_type === Int ? I64 : I32)
                local_set!(bchr, _sc_idx)
                _ssi = get_string_struct_type!(ctx.mod, ctx.type_registry)
                ref_cast!(bchr, Int64(_ssi), false)
                struct_get!(bchr, UInt32(_ssi), UInt32(2), ConcreteRef(UInt32(str_type_idx), true))
                local_get!(bchr, _sc_idx)
                if idx_type === Int64 || idx_type === Int
                    # Convert Int64 to Int32 and subtract 1
                    num!(bchr, Opcode.I32_WRAP_I64)
                end
                i32_const!(bchr, 1)  # 1
                num!(bchr, Opcode.I32_SUB)  # index - 1 for 0-based

                # array.get
                array_get!(bchr, str_type_idx, I32; signed=false)
                append_builder!(fb, bchr)

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
                bsc = _ctx_builder(ctx, "compile_invoke")

                # Compile string
                emit_value!(bsc, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))

                # Compile index and convert to 0-based
                idx_type = infer_value_type(args[2], ctx)
                emit_value!(bsc, args[2], ctx, (idx_type === Int64 || idx_type === Int) ? I64 : I32)   # march14
                if idx_type === Int64 || idx_type === Int
                    num!(bsc, Opcode.I32_WRAP_I64)
                end
                i32_const!(bsc, 1)
                num!(bsc, Opcode.I32_SUB)

                # Compile char value
                char_type = infer_value_type(args[3], ctx)
                emit_value!(bsc, args[3], ctx, (char_type === Int64 || char_type === Int) ? I64 : I32)   # march14
                if char_type === Int64 || char_type === Int
                    num!(bsc, Opcode.I32_WRAP_I64)
                end

                # array.set
                array_set!(bsc, str_type_idx, I32)
                return append_builder!(b, bsc)

            # WasmTarget string operations - str_len(s) -> Int32
            elseif name === :str_len && length(args) == 1
                # Get string length as Int32
                # Arg already compiled, just emit array.len
                blen2 = _ctx_builder(ctx, "compile_invoke")
                array_len!(blen2)
                append_builder!(fb, blen2)

            # WasmTarget string operations - str_new(len) -> String
            elseif name === :str_new && length(args) == 1
                # Create new string of given length, filled with zeros
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Length arg already compiled
                bnew = _ctx_builder(ctx, "compile_invoke")
                len_type = infer_value_type(args[1], ctx)
                if len_type === Int64 || len_type === Int
                    num!(bnew, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0 for i32)
                array_new_default!(bnew, str_type_idx)
                append_builder!(fb, bnew)

            # WasmTarget string operations - str_copy(src, src_pos, dst, dst_pos, len) -> Nothing
            elseif name === :str_copy && length(args) == 5
                # Copy characters from src to dst using array.copy
                str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)

                # Clear bytes - recompile in correct order for array.copy
                # array.copy expects: dst, dst_offset, src, src_offset, len
                bcp = _ctx_builder(ctx, "compile_invoke")

                # dst array
                emit_value!(bcp, args[3], ctx, ConcreteRef(UInt32(str_type_idx), true))
                # dst offset (0-based)
                dst_idx_type = infer_value_type(args[4], ctx)
                emit_value!(bcp, args[4], ctx, (dst_idx_type === Int64 || dst_idx_type === Int) ? I64 : I32)   # march14
                if dst_idx_type === Int64 || dst_idx_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end
                i32_const!(bcp, 1)
                num!(bcp, Opcode.I32_SUB)

                # src array
                emit_value!(bcp, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
                # src offset (0-based)
                src_idx_type = infer_value_type(args[2], ctx)
                emit_value!(bcp, args[2], ctx, (src_idx_type === Int64 || src_idx_type === Int) ? I64 : I32)   # march14
                if src_idx_type === Int64 || src_idx_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end
                i32_const!(bcp, 1)
                num!(bcp, Opcode.I32_SUB)

                # length
                len_type = infer_value_type(args[5], ctx)
                emit_value!(bcp, args[5], ctx, (len_type === Int64 || len_type === Int) ? I64 : I32)   # march14
                if len_type === Int64 || len_type === Int
                    num!(bcp, Opcode.I32_WRAP_I64)
                end

                # array.copy
                array_copy!(bcp, str_type_idx, str_type_idx)
                return append_builder!(b, bcp)

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
                bss = _ctx_builder(ctx, "compile_invoke")

                # Store source string DATA (parity M9: the funnel unwraps the class)
                emit_value!(bss, args[1], ctx, ConcreteRef(UInt32(str_type_idx), true))
                local_set!(bss, src_local)

                # Create new string of specified length
                len_type = infer_value_type(args[3], ctx)
                emit_value!(bss, args[3], ctx,
                            (len_type === Int64 || len_type === Int) ? I64 : I32)  # len
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
                start_type = infer_value_type(args[2], ctx)
                emit_value!(bss, args[2], ctx, (start_type === Int64 || start_type === Int) ? I64 : I32)   # march14
                if start_type === Int64 || start_type === Int
                    num!(bss, Opcode.I32_WRAP_I64)
                end
                i32_const!(bss, 1)
                num!(bss, Opcode.I32_SUB)

                # len
                len_type2 = infer_value_type(args[3], ctx)
                emit_value!(bss, args[3], ctx, (len_type2 === Int64 || len_type2 === Int) ? I64 : I32)   # march14
                if len_type2 === Int64 || len_type2 === Int
                    num!(bss, Opcode.I32_WRAP_I64)
                end

                array_copy!(bss, str_type_idx, str_type_idx)

                # Return result — published as the CLASSED string (parity M9)
                local_get!(bss, result_local)
                emit_string_wrap!(bss, ctx)
                return append_builder!(b, bss)

            # WasmTarget string operations - str_hash(s) -> Int32
            elseif name === :str_hash && length(args) == 1
                fb = _compile_invoke_str_hash_b(args, ctx)

            # ================================================================
            # BROWSER-010: New String Operations
            # str_find, str_contains, str_startswith, str_endswith
            # str_uppercase, str_lowercase, str_trim
            # ================================================================

            # str_find(haystack, needle) -> Int32
            # Returns 1-based position or 0 if not found
            elseif name === :str_find && length(args) == 2
                fb = _compile_invoke_str_find_b(args, ctx)

            # str_contains(haystack, needle) -> Bool
            # Returns true if needle is found in haystack
            elseif name === :str_contains && length(args) == 2
                fb = _compile_invoke_str_contains_b(args, ctx)


            # str_startswith(s, prefix) -> Bool
            elseif name === :str_startswith && length(args) == 2
                fb = _compile_invoke_str_startswith_b(args, ctx)

            # str_endswith(s, suffix) -> Bool
            elseif name === :str_endswith && length(args) == 2
                fb = _compile_invoke_str_endswith_b(args, ctx)

            # str_uppercase(s) -> String
            # Convert lowercase ASCII letters to uppercase
            elseif name === :str_uppercase && length(args) == 1
                fb = _compile_invoke_str_uppercase_b(args, ctx)

            # str_lowercase(s) -> String
            # Convert uppercase ASCII letters to lowercase
            elseif name === :str_lowercase && length(args) == 1
                fb = _compile_invoke_str_lowercase_b(args, ctx)


            # str_trim(s) -> String
            # Remove leading and trailing ASCII whitespace
            elseif name === :str_trim && length(args) == 1
                fb = _compile_invoke_str_trim_b(args, ctx)

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
                ban = _ctx_builder(ctx, "compile_invoke")

                # Compile length arg
                len_type = infer_value_type(args[2], ctx)
                emit_value!(ban, args[2], ctx, (len_type === Int64 || len_type === Int) ? I64 : I32)   # march14
                if len_type === Int64 || len_type === Int
                    num!(ban, Opcode.I32_WRAP_I64)
                end

                # array.new_default creates array filled with default value (0)
                array_new_default!(ban, arr_type_idx)
                return append_builder!(b, ban)

            # arr_get(arr, i) -> T
            elseif name === :arr_get && length(args) == 2
                # Args already compiled: arr, index
                # Need to adjust index to 0-based and emit array.get
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Convert index to 0-based
                bget = _ctx_builder(ctx, "compile_invoke")
                idx_type = infer_value_type(args[2], ctx)
                if idx_type === Int64 || idx_type === Int
                    num!(bget, Opcode.I32_WRAP_I64)
                end
                i32_const!(bget, 1)
                num!(bget, Opcode.I32_SUB)  # index - 1

                # array.get (use ARRAY_GET_U for packed i8 arrays like UInt8)
                array_get!(bget, arr_type_idx, I32; signed=packed_array_signedness(elem_type))
                append_builder!(fb, bget)

            # arr_set!(arr, i, val) -> Nothing
            elseif name === :arr_set! && length(args) == 3
                arr_type = infer_value_type(args[1], ctx)
                elem_type = eltype(arr_type)
                arr_type_idx = get_array_type!(ctx.mod, ctx.type_registry, elem_type)

                # Recompile in correct order for array.set: arr, index-1, val
                bas = _ctx_builder(ctx, "compile_invoke")
                local _arrset_elem_w = get_concrete_wasm_type(elem_type, ctx.mod, ctx.type_registry)
                local _arrset_elem_w2 = _arrset_elem_w isa WasmValType ? _arrset_elem_w : AnyRef

                # Array ref
                emit_value!(bas, args[1], ctx, ConcreteRef(UInt32(arr_type_idx), true))

                # Index (convert to 0-based)
                idx_type = infer_value_type(args[2], ctx)
                emit_value!(bas, args[2], ctx, (idx_type === Int64 || idx_type === Int) ? I64 : I32)   # march14
                if idx_type === Int64 || idx_type === Int
                    num!(bas, Opcode.I32_WRAP_I64)
                end
                i32_const!(bas, 1)
                num!(bas, Opcode.I32_SUB)

                # Value — typed channel throughout
                local _as_b = _compile_value_b(args[3], ctx)
                local val_ty = isempty(_as_b.v.stack) ? nothing : _as_b.v.stack[end]
                # PURE-045: If elem_type is Any (externref array), convert ref→externref
                if elem_type === Any
                    if val_ty === I64 || val_ty === I32 || val_ty === F64 || val_ty === F32
                        # march3: was emit_numeric_to_externref!(_, stmt.val, val_wasm, _) —
                        # OUTER-SCOPE variables (same latent copy-paste bug as push!); the
                        # stored VALUE boxes.
                        emit_numeric_to_externref!(bas, args[3], val_ty, ctx)
                    else
                        append_builder!(bas, _as_b)
                        # march16: a KNOWN closure erasing into a Vector{Any} slot wraps
                        # into the closure OBJECT first (dart convertType at the seam)
                        val_ty === ExternRef || maybe_wrap_closure!(bas, ctx, infer_value_type(args[3], ctx))
                        # PURE-048: Skip extern_convert_any if value is already externref
                        val_ty === ExternRef || extern_convert_any!(bas)
                    end
                else
                    append_builder!(bas, _as_b)
                end

                # array.set
                array_set!(bas, arr_type_idx, _arrset_elem_w2)
                fb = bas   # discard-and-replace (march4)

            # arr_len(arr) -> Int32
            elseif name === :arr_len && length(args) == 1
                # Arg already compiled, just emit array.len
                blen3 = _ctx_builder(ctx, "compile_invoke")
                array_len!(blen3)
                append_builder!(fb, blen3)

            # ================================================================
            # PURE-322: SubString — create proper SubString struct
            # SubString(str, start, stop) does UTF-8 thisind validation that
            # uses jl_string_ptr/pointerref (unsupported in WasmGC). Since
            # WasmGC strings are array<i32> (char arrays, not byte arrays),
            # every index is valid. Create struct: {string, offset, ncodeunits}
            # ================================================================
            elseif name === :SubString
                bsub2 = _ctx_builder(ctx, "compile_invoke")  # Clear accumulated arg bytes
                if length(args) >= 3
                    str_arg = args[1]
                    start_arg = args[2]
                    stop_arg = args[3]
                    local _substr_info = register_struct_type!(ctx.mod, ctx.type_registry, SubString{String})
                    local _substr_def = ctx.mod.types[_substr_info.wasm_type_idx + 1]
                    local _substr_string_w = _substr_def.fields[wasm_field_idx(_substr_info, 1) + 1].valtype
                    emit_struct_prefix!(bsub2, ctx.type_registry, SubString{String}, _substr_info)
                    # Field 1: string (ref null array<i32>)
                    emit_value!(bsub2, str_arg, ctx, _substr_string_w; from_julia=String)
                    # Field 2: offset = start - 1
                    emit_value!(bsub2, start_arg, ctx, I64)
                    i64_const!(bsub2, 1)
                    num!(bsub2, Opcode.I64_SUB)
                    # Field 3: ncodeunits = stop - start + 1
                    emit_value!(bsub2, stop_arg, ctx, I64)
                    emit_value!(bsub2, start_arg, ctx, I64)
                    num!(bsub2, Opcode.I64_SUB)
                    i64_const!(bsub2, 1)
                    num!(bsub2, Opcode.I64_ADD)
                    # Emit struct.new for SubString type
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        struct_new!(bsub2, substr_wasm.type_idx)   # mod-resolved fields (march3)
                    end
                elseif length(args) >= 1
                    # SubString(str) — view of entire string
                    str_arg = args[1]
                    local _substr_info = register_struct_type!(ctx.mod, ctx.type_registry, SubString{String})
                    local _substr_def = ctx.mod.types[_substr_info.wasm_type_idx + 1]
                    local _substr_string_w = _substr_def.fields[wasm_field_idx(_substr_info, 1) + 1].valtype
                    emit_struct_prefix!(bsub2, ctx.type_registry, SubString{String}, _substr_info)
                    emit_value!(bsub2, str_arg, ctx, _substr_string_w; from_julia=String)
                    i64_const!(bsub2, 0)  # offset = 0
                    # ncodeunits = array.len(str)
                    emit_value!(bsub2, str_arg, ctx,
                                ConcreteRef(UInt32(get_string_array_type!(ctx.mod, ctx.type_registry)), true))
                    array_len!(bsub2)
                    num!(bsub2, Opcode.I64_EXTEND_I32_S)
                    # Emit struct.new
                    substr_wasm = get_concrete_wasm_type(SubString{String}, ctx.mod, ctx.type_registry)
                    if substr_wasm isa ConcreteRef
                        struct_new!(bsub2, substr_wasm.type_idx)   # mod-resolved fields (march3)
                    end
                end
                return append_builder!(b, bsub2)

            # ================================================================
            # PURE-322: _thisind_continued / _nextind_continued — identity
            # In WasmGC, strings are array<i32> (char codes), so every
            # character index is valid (no multi-byte encoding).
            # ================================================================
            elseif (name === :_thisind_continued || name === Symbol("#_thisind_continued#_thisind_str##0")) && length(args) >= 2
                bti = _ctx_builder(ctx, "compile_invoke")
                # Closure form: (closure, string, index, len) → return index
                if length(args) >= 3
                    emit_value!(bti, args[2], ctx, I64)
                else
                    emit_value!(bti, args[1], ctx, I64)
                end
                return append_builder!(b, bti)

            elseif (name === :_nextind_continued || name === Symbol("#_nextind_continued#_nextind_str##0")) && length(args) >= 2
                bni = _ctx_builder(ctx, "compile_invoke")
                # nextind(s, i) = i + 1 in WasmGC
                if length(args) >= 3
                    emit_value!(bni, args[2], ctx, I64)
                else
                    emit_value!(bni, args[1], ctx, I64)
                end
                i64_const!(bni, 1)
                num!(bni, Opcode.I64_ADD)
                return append_builder!(b, bni)

            # ================================================================
            # PURE-9016: Multi-arg string() → inline N-way concatenation
            # string("hello", " ", "world") or string("x = ", int_to_string(x))
            # Allocates one result array of total length, copies each arg in
            # ================================================================
            elseif (name === :string || name === :_string) && length(args) > 1
                bms = _ctx_builder(ctx, "compile_invoke")  # Clear pre-compiled args

                # Check arg types — for now handle all-String args
                arg_types = [infer_value_type(a, ctx) for a in args]
                all_strings = all(t -> t === String || t === Symbol, arg_types)

                if all_strings
                    bms = compile_string_concat_many_b(args, ctx)
                else
                    # A result-producing invoke may never substitute a valid but
                    # unrelated String.  Normal Julia string conversion is handled
                    # by the collected print_to_string body; if this specialized arm
                    # is nevertheless selected without an all-string proof, reject
                    # the unsupported lowering explicitly.
                    record_unsupported!(ctx, :unsupported_method,
                        "specialized multi-argument string lowering requires every argument to be String or Symbol";
                        idx=idx, detail=arg_types)
                    unreachable!(bms)  # polymorphic bottom; no fabricated String value
                    ctx.last_stmt_was_stub = true
                end
                return append_builder!(b, bms)

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
                    bis1 = _ctx_builder(ctx, "compile_invoke")

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
                        emit_value!(bis1, value_arg, ctx,
                                    value_type in (Int64, UInt64) ? I64 : I32)

                        # Convert to Int32 if needed
                        if value_type === Int64
                            num!(bis1, Opcode.I32_WRAP_I64)
                        elseif value_type === UInt64
                            num!(bis1, Opcode.I32_WRAP_I64)
                        end

                        call!(bis1, int_to_string_info.wasm_idx, WasmValType[], WasmValType[])
                        return append_builder!(b, bis1)
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
                bthr2 = _ctx_builder(ctx, "compile_invoke")
                if name === :rethrow
                    # PURE-9034: rethrow() preserves the exception in the global —
                    # just re-throw without overwriting. The caught exception is
                    # already in $current_exn from the original throw.
                    global_get!(bthr2, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bthr2, ExternRef); throw_!(bthr2, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                else
                    exn_global = ensure_exception_global!(ctx.mod)
                    if isempty(args)
                        record_unsupported!(ctx, :unsupported_method,
                            "throw helper has no exception payload"; idx=idx, detail=expr)
                        unreachable!(bthr2)  # structural trap after recorded unsupported
                        ctx.last_stmt_was_stub = true
                        return append_builder!(b, bthr2)
                    end
                    emit_value!(bthr2, args[1], ctx, AnyRef)
                    global_set!(bthr2, exn_global)
                    global_get!(bthr2, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bthr2, ExternRef); throw_!(bthr2, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                end
                append_builder!(fb, bthr2)
                ctx.last_stmt_was_stub = true  # PURE-908

            # PURE-9040: println/print → JS IO bridge imports
            elseif name === :println || name === :print
                fb = _compile_invoke_print_b(name, args, ctx)
                # print returns `nothing`; the io imports are void. If this SSA
                # has a local (the nothing value is USED downstream — common in
                # trim-collected show machinery), push its representation so the
                # statement wrapper's local.set has a value to consume.
                if haskey(ctx.ssa_locals, idx)
                    bpn = _ctx_builder(ctx, "compile_invoke")
                    ref_null!(bpn, AnyRef)  # ref.null any (0xD0 0x6E)
                    append_builder!(fb, bpn)
                end

            # PURE-9041: show(x) → IO bridge imports (like print, no newline)
            # show(42) displays "42", show(true) displays "true", show(nothing) displays "nothing"
            elseif name === :show
                io = get_io_imports()
                if io !== nothing
                    bsh2 = _ctx_builder(ctx, "compile_invoke")
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
                            emit_value!(bsh2, arg, ctx, ConcreteRef(get_string_array_type!(ctx.mod, ctx.type_registry), true))   # parity(M9): funnel → DATA array
                            emit_jl_string_to_js!(bsh2, io.decode_idx)
                            call!(bsh2, io.write_string_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Int64 || arg_type === Int || arg_type === UInt64
                            emit_value!(bsh2, arg, ctx, I64)
                            call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Int32
                            emit_value!(bsh2, arg, ctx, I32)
                            num!(bsh2, Opcode.I64_EXTEND_I32_S)
                            call!(bsh2, io.write_int_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Float64
                            emit_value!(bsh2, arg, ctx, F64)
                            call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Float32
                            emit_value!(bsh2, arg, ctx, F32)
                            num!(bsh2, Opcode.F64_PROMOTE_F32)
                            call!(bsh2, io.write_float_idx, WasmValType[], WasmValType[])
                        elseif arg_type === Bool
                            emit_value!(bsh2, arg, ctx, I32)
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
                    return append_builder!(b, bsh2)
                else
                    fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)
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
                bgic = _ctx_builder(ctx, "compile_invoke")
                record_unsupported!(ctx, :unsupported_method, "string getindex_continued (byte-level multibyte access)"; idx=idx)
                unreachable!(bgic)
                append_builder!(fb, bgic)
                ctx.last_stmt_was_stub = true

            # PURE-1102: Error/throw functions — emit throw (catchable) instead of unreachable (trap)
            # PURE-9032: Create exception struct objects and stash in $current_exn
            # so that :the_exception + isa checks can identify the exception type.
            elseif name === :error
                berr = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                exn_global = ensure_exception_global!(ctx.mod)
                # error("msg") → create ErrorException struct, stash, throw
                local _ee_info = register_struct_type!(ctx.mod, ctx.type_registry, ErrorException)
                _ee_info === nothing && error("ErrorException layout is unavailable")
                length(args) <= 1 || error("unexpected error() lowering arity: $(length(args))")
                emit_struct_prefix!(berr, ctx.type_registry, ErrorException, _ee_info)
                local _ee_def = ctx.mod.types[_ee_info.wasm_type_idx + 1]
                local _ee_msg_w = _ee_def.fields[wasm_field_idx(_ee_info, 1) + 1].valtype
                emit_value!(berr, isempty(args) ? "" : args[1], ctx, _ee_msg_w; from_julia=String)
                struct_new!(berr, _ee_info.wasm_type_idx)   # mod-resolved fields (march3)
                global_set!(berr, exn_global)
                global_get!(berr, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(berr, ExternRef); throw_!(berr, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                ctx.last_stmt_was_stub = true
                return append_builder!(b, berr)
            # Handle JuliaSyntax internal functions that have complex implementations
            # These are intercepted and compiled as simplified stubs
            elseif name === :parse_float_literal
                # WBUILD-8001: Float literal parsing not implemented (orig uses
                # ccall(:jl_strtod_c)). Strict Approach A — loud reject (returns a
                # value natively, so a silent trap would diverge).
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "parse_float_literal (JuliaSyntax float parsing — needs jl_strtod_c)"; idx=idx)

            elseif name === :parse_int_literal ||
                   name === :parse_uint_literal
                # WBUILD-8001: Int/uint literal parsing not implemented.
                emit_unsupported_stub!(ctx, fb, :unsupported_method,
                    "parse_int/uint_literal (JuliaSyntax integer parsing)"; idx=idx)

            # Handle unalias — identity in WasmGC (arrays never alias)
            # unalias(dest, src) checks if dest and src share backing memory
            # and copies src if they do. In WasmGC, every array.new creates a
            # distinct GC object, so aliasing is impossible. Just return src.
            elseif name === :unalias
                # Discard accumulated argument bytes and re-compile just src (arg 2)
                bua = _ctx_builder(ctx, "compile_invoke")
                src_arg = expr.args[4]  # args: [mi, func_ref, dest, src]
                emit_value!(bua, src_arg, ctx, static_wasm_type(src_arg, ctx))
                return append_builder!(b, bua)

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
                bsh = _ctx_builder(ctx, "compile_invoke")
                # The vector argument: for sizehint! it's args[1], for #sizehint!#81 it's args[4]
                vec_arg = name === :sizehint! ? (length(args) >= 1 ? args[1] : nothing) :
                          (length(args) >= 4 ? args[4] : nothing)
                if vec_arg !== nothing
                    emit_value!(bsh, vec_arg, ctx, static_wasm_type(vec_arg, ctx))
                else
                    record_unsupported!(ctx, :unsupported_method, "vector op: argument vector unavailable"; idx=idx)
                    unreachable!(bsh)
                end
                return append_builder!(b, bsh)

            elseif meth.module === Base &&
                   occursin(r"^#_(?:growend|growbeg|growat)!", string(name))
                # Clear any accumulated bytes from argument compilation
                fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)

                # Drop the closure object from the stack if it's there
                func_ref = expr.args[2]
                if func_ref isa Core.SSAValue
                    if !haskey(ctx.ssa_locals, func_ref.id) && !haskey(ctx.phi_locals, func_ref.id)
                        bgrd = _ctx_builder(ctx, "compile_invoke")
                        drop!(bgrd)
                        append_builder!(fb, bgrd)
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

                    bgr = _ctx_builder(ctx, "compile_invoke")

                    # 1. Get the vector and store in local
                    emit_value!(bgr, vec_arg, ctx, ConcreteRef(UInt32(vec_type_idx), true))
                    # PURE-045: heap type for ref.cast must use signed LEB128
                    ref_cast!(bgr, Int64(vec_type_idx), true)
                    local_set!(bgr, vec_scratch_local)

                    # 2. Get old backing array and store
                    local_get!(bgr, vec_scratch_local)
                    struct_get!(bgr, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(arr_type_idx), true))
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
                    struct_set!(bgr, vec_type_idx, wasm_field_idx(vec_info, 1), ConcreteRef(UInt32(arr_type_idx), true))

                    append_builder!(fb, bgr)

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
                    bgrf = _ctx_builder(ctx, "compile_invoke")
                    record_unsupported!(ctx, :unsupported_method,
                                        "vector op: element type undeterminable";
                                        idx=idx, detail=expr)
                    unreachable!(bgrf)  # structural trap after recorded unsupported
                    append_builder!(fb, bgrf)
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
                bti2 = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
                global_idx = get_type_constant_global!(ctx.mod, ctx.type_registry, result_type)
                global_get!(bti2, global_idx, AnyRef)
                # Convert concrete ref to externref (Type values are externref in general context)
                extern_convert_any!(bti2)
                return append_builder!(b, bti2)

            # PURE-6024: _tuple_error — error function in tuple convert dead code path.
            # Emit throw (catchable) instead of unreachable (trap).
            elseif name === :_tuple_error
                bte = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
                ensure_exception_tag!(ctx.mod)
                global_get!(bte, ensure_exception_global!(ctx.mod), AnyRef); ref_null!(bte, ExternRef); throw_!(bte, 0; inputs=WasmValType[AnyRef, ExternRef])   # typed (exn, trace) tag
                ctx.last_stmt_was_stub = true  # PURE-908
                return append_builder!(b, bte)

            # Julia 1.13: hash_bytes(ptr, len, seed, secret) replaces memhash foreigncall
            # Trace ptr back to jl_string_ptr to find original string, then use FNV-1a helper
            elseif name === :hash_bytes
                bhb = _ctx_builder(ctx, "compile_invoke")  # Clear pre-pushed args
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
                        emit_value!(bhb, expr.args[4], ctx, I64)  # length i64
                    else
                        i64_const!(bhb, 0)
                    end
                    # seed arg (UInt64 → i32)
                    if length(expr.args) >= 5
                        seed_type = infer_value_type(expr.args[5], ctx)
                        emit_value!(bhb, expr.args[5], ctx,
                                    (seed_type === UInt64 || seed_type === Int64 || seed_type === Int) ? I64 : I32)
                        if seed_type === UInt64 || seed_type === Int64 || seed_type === Int
                            num!(bhb, Opcode.I32_WRAP_I64)
                        end
                    else
                        i32_const!(bhb, 0)
                    end
                    call!(bhb, hash_func_idx, WasmValType[], WasmValType[])
                else
                    record_unsupported!(ctx, :unsupported_method,
                        "hash_bytes source is not traceable to a Wasm string"; idx=idx, detail=expr)
                    unreachable!(bhb)  # structural trap after recorded unsupported
                    ctx.last_stmt_was_stub = true
                end
                return append_builder!(b, bhb)

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
                            if _sc_tt isa DataType && is_struct_type(_sc_tt) &&
                               (haskey(ctx.type_registry.structs, _sc_tt) ||
                                (isconcretetype(_sc_tt) && isstructtype(_sc_tt))) &&
                               isconcretetype(_sc_tt)
                                local _sc_argtypes = tuple((_invoke_arg_static_type(arg, ctx)
                                    for arg in args)...)
                                _sc_ok = fieldcount(_sc_tt) == length(args) ||
                                    _is_direct_vararg_struct_constructor(_sc_tt, mi, _sc_argtypes)
                            end
                        end
                    end
                    _sc_ok
                end
                # Extract target type from Type{T}
                local _ctor_target = mi.specTypes.parameters[1].parameters[1]::DataType
                # Clear pre-compiled args — we re-emit in correct order with typeId
                fb = _ctx_builder(ctx, "compile_invoke.frag"); _seed_builder_locals!(fb, ctx)
                # Register struct type if not already registered
                if !haskey(ctx.type_registry.structs, _ctor_target)
                    register_struct_type!(ctx.mod, ctx.type_registry, _ctor_target)
                end
                local _ctor_sinfo = ctx.type_registry.structs[_ctor_target]
                if _ctor_sinfo !== nothing
                    emit_struct_prefix!(fb, ctx.type_registry, _ctor_target, _ctor_sinfo)
                    local _ctor_argtypes = tuple((_invoke_arg_static_type(arg, ctx)
                        for arg in args)...)
                    local _vararg_direct = _is_direct_vararg_struct_constructor(
                        _ctor_target, mi, _ctor_argtypes)
                    local _fixed_count = _vararg_direct ? mi.def.nargs - 2 : length(args)
                    # Compile fixed constructor arguments as their exact struct fields.
                    for _fi in 1:_fixed_count
                        local _ftype = _fi <= length(_ctor_sinfo.field_types) ? _ctor_sinfo.field_types[_fi] : Any
                        local _ctor_def = ctx.mod.types[_ctor_sinfo.wasm_type_idx + 1]
                        local _field_idx = _fi + Int(_ctor_sinfo.field_offset)
                        local _expected = (_ctor_def isa StructType && _field_idx <= length(_ctor_def.fields)) ?
                            _ctor_def.fields[_field_idx].valtype : nothing
                        _expected === nothing && error(
                            "constructor field lacks a physical Wasm type: target=$_ctor_target field=$_fi " *
                            "offset=$(_ctor_sinfo.field_offset) registered_fields=$(length(_ctor_sinfo.field_types)) " *
                            "physical_fields=$(_ctor_def isa StructType ? length(_ctor_def.fields) : -1)")
                        emit_value!(fb, args[_fi], ctx, _expected; from_julia=_ftype)
                    end
                    if _vararg_direct
                        local _varargs = args[(_fixed_count + 1):end]
                        local _vararg_types = tuple((_invoke_arg_static_type(arg, ctx)
                            for arg in _varargs)...)
                        local _tuple_type = Tuple{_vararg_types...}
                        local _tuple_info = register_tuple_type!(ctx.mod, ctx.type_registry, _tuple_type)
                        _tuple_info === nothing && error("vararg tuple layout is unavailable")
                        emit_struct_prefix!(fb, ctx.type_registry, _tuple_type, _tuple_info)
                        local _tuple_def = ctx.mod.types[_tuple_info.wasm_type_idx + 1]
                        for (_vi, _arg) in enumerate(_varargs)
                            local _wf = _vi + Int(_tuple_info.field_offset)
                            local _expected = (_tuple_def isa StructType && _wf <= length(_tuple_def.fields)) ?
                                _tuple_def.fields[_wf].valtype : nothing
                            _expected === nothing && error("vararg tuple field lacks a physical Wasm type")
                            emit_value!(fb, _arg, ctx, _expected; from_julia=_vararg_types[_vi])
                        end
                        struct_new!(fb, _tuple_info.wasm_type_idx)
                    end
                    # Allocation consumes the fields on this same authoritative stack.
                    struct_new!(fb, _ctor_sinfo.wasm_type_idx)
                else
                    # Registration failed — codegen cannot lay out this struct type.
                    record_unsupported!(ctx, :unsupported_type,
                        "struct constructor for `$(_ctor_target)` (type registration failed)"; idx=idx, detail=expr)
                    bscnf = _ctx_builder(ctx, "compile_invoke")
                    record_unsupported!(ctx, :unsupported_method, "struct type registration failed (cannot lay out)"; idx=idx)
                    unreachable!(bscnf)
                    append_builder!(fb, bscnf)
                    ctx.last_stmt_was_stub = true
                end

            elseif name === :padding && length(args) == 2 &&
                   args[1] isa Type && args[2] isa Integer
                # `padding(T,n)` is a compile-time SimpleVector constant.
                bpad = _ctx_builder(ctx, "compile_invoke")
                local _padding = Base.padding(args[1], Int(args[2]))
                _emit_svec_values!(bpad, collect(_padding), ctx)
                return append_builder!(b, bpad)

            elseif name === :array_subpadding && length(args) == 2 &&
                   args[1] isa Type && args[2] isa Type
                # P4-stdlib (Statistics median): Base.array_subpadding is a pure
                # compile-time layout predicate guarding reinterpret-based radix
                # sort paths, and its args arrive as literal types — host-evaluate
                # and emit the Bool constant (the stub trapped the whole
                # IEEEFloatOptimization sort path at runtime).
                bsub = _ctx_builder(ctx, "compile_invoke")   # discard pre-pushed args
                i32_const!(bsub, Base.array_subpadding(args[1], args[2]) ? 1 : 0)
                return append_builder!(b, bsub)

            else
                # Unknown method — codegen has no translation for this invoke target.
                # This records a source-attributed diagnostic and emits dart's validating
                # unsupported-path trap; no permissive mode exists.
                # which lets compilation succeed for paths that never reach this method.
                haskey(ENV, "WT_TRACE_STUBARGS") && println(stderr, "STUBARGS ", name, " args=", repr(args))
                record_unsupported!(ctx, :unsupported_method,
                    "method `$name`" * (mi !== nothing ? " for $(mi.specTypes)" : "");
                    idx=idx, detail=expr)
                bunk = _ctx_builder(ctx, "compile_invoke")
                record_unsupported!(ctx, :unsupported_method, "unknown invoke target (no handler arm)"; idx=idx)
                unreachable!(bunk)
                append_builder!(fb, bunk)
                ctx.last_stmt_was_stub = true  # PURE-908
            end
        end
    end

    return append_builder!(b, fb)
end
