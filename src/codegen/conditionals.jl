"""
Generate code for a single basic block.
"""
@inline function generate_block_code(ctx::AbstractCompilationContext, block::BasicBlock)::Vector{UInt8}
    b = InstrBuilder(; func_name="generate_block_code")
    code = ctx.code_info.code

    for i in block.start_idx:block.end_idx
        stmt_bytes = compile_statement(code[i], i, ctx)
        emit_raw!(b, stmt_bytes)
    end

    return builder_code(b)
end

