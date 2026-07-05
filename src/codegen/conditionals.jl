"""
Generate code for a single basic block — builder-native, statements flow
through THE compile_statement! front.
"""
@inline function generate_block_code!(b::InstrBuilder, ctx::AbstractCompilationContext, block::BasicBlock)
    code = ctx.code_info.code
    for i in block.start_idx:block.end_idx
        compile_statement!(b, code[i], i, ctx)
    end
    return b
end

