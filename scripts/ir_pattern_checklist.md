## Pattern Checklist (auto-generated from audit)

Generated: 2026-02-12 14:55
Source: `scripts/ir_audit_results.json` (1133 patterns total)

| Category | Count | Description |
|----------|-------|-------------|
| STUBBED | 31 | Emits `unreachable` — must implement |
| BROKEN | 8 | Compiles but crashes at runtime |
| HANDLED_UNTESTED | 708 | Compiler handles, no correctness test |
| TESTED | 386 | Verified working in runtests.jl |

### STUBBED (must implement to unblock parsestmt)

- [ ] `atomic_pointerset` — intrinsic (stubbed) (intrinsic)
- [ ] `#bump_trivia#30` — unsupported method (stub)
- [ ] `#lex_digit##0` — unsupported method (stub)
- [ ] `#recover#60` — unsupported method (stub)
- [ ] `==` — unsupported method (stub)
- [ ] `Symbol` — unsupported method (stub)
- [ ] `_assert_tostring` — unsupported method (stub)
- [ ] `_growat!` — unsupported method (stub)
- [ ] `_replace_` — unsupported method (stub)
- [ ] `_string` — unsupported method (stub)
- [ ] `atomic_pointerset` — unsupported call (stub)
- [ ] `ensureroom_reallocate` — unsupported method (stub)
- [ ] `ensureroom_slowpath` — unsupported method (stub)
- [ ] `findnext` — unsupported method (stub)
- [ ] `isascii` — unsupported method (stub)
- [ ] `ndigits0zpb` — unsupported method (stub)
- [ ] `overflow_case` — unsupported method (stub)
- [ ] `parse_Nary` — unsupported method (stub)
- [ ] `parse_brackets` — unsupported method (stub)
- [ ] `parse_comma_separated` — unsupported method (stub)
- [ ] `parseint_preamble` — unsupported method (stub)
- [ ] `prevind` — unsupported method (stub)
- [ ] `reduce_empty` — unsupported method (stub)
- [ ] `resize!` — unsupported method (stub)
- [ ] `reverse!` — unsupported method (stub)
- [ ] `take!` — unsupported method (stub)
- [ ] `throw_code_point_err` — unsupported method (stub)
- [ ] `throw_invalid_char` — unsupported method (stub)
- [ ] `tryparse_internal` — unsupported method (stub)
- [ ] `unsafe_write` — unsupported method (stub)
- [ ] `write` — unsupported method (stub)

### BROKEN (compiles but crashes — known from PURE-324)

- [ ] `node_to_expr` — 7x, Tuple{typeof(JuliaSyntax.node_to_expr), JuliaSyntax.RedTreeCursor, SourceFile, Vector{UInt8}, UInt32...
- [ ] `#SourceFile#40` — 2x, Tuple{JuliaSyntax.var"##SourceFile#40", Base.Pairs{Symbol, Union{Nothing, Int64}, Nothing, @NamedTup...
- [ ] `getindex` — 2x, Tuple{typeof(getindex), SourceFile, UnitRange{UInt32}}
- [ ] `_string_to_Expr` — 2x, Tuple{typeof(JuliaSyntax._string_to_Expr), JuliaSyntax.RedTreeCursor, SourceFile, Vector{UInt8}, UIn...
- [ ] `build_tree` — 1x, Tuple{typeof(JuliaSyntax.build_tree), Type{Expr}, JuliaSyntax.ParseStream, SourceFile}
- [ ] `#SourceFile#8` — 1x, Tuple{JuliaSyntax.var"##SourceFile#8", Nothing, Int64, Int64, Type{SourceFile}, SubString{String}}
- [ ] `parseargs!` — 1x, Tuple{typeof(JuliaSyntax.parseargs!), Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, SourceFile, V...
- [ ] `_node_to_expr` — 1x, Tuple{typeof(JuliaSyntax._node_to_expr), Expr, LineNumberNode, UnitRange{UInt32}, JuliaSyntax.Syntax...

### HANDLED_UNTESTED (high risk — may hide bugs)

#### Calls (256 patterns)

- [ ] `Base.memoryrefnew` — 1575x, Base.memoryrefnew(MemoryRef{JuliaSyntax.SyntaxToken}, Int64, Bool)
- [ ] `Base.memoryrefget` — 1574x, Base.memoryrefget(MemoryRef{JuliaSyntax.SyntaxToken}, Symbol, Bool)
- [ ] `Base.memoryrefnew` — 520x, Base.memoryrefnew(MemoryRef{UInt8}, Int64, Bool)
- [ ] `Base.memoryrefget` — 396x, Base.memoryrefget(MemoryRef{UInt8}, Symbol, Bool)
- [ ] `Base.memoryrefnew` — 390x, Base.memoryrefnew(MemoryRef{JuliaSyntax.RawGreenNode}, Int64, Bool)
- [ ] `ifelse` — 353x, ifelse(Bool, Int64, Int64)
- [ ] `ifelse` — 344x, ifelse(Bool, UInt32, UInt32)
- [ ] `Base.memoryrefnew` — 340x, Base.memoryrefnew(Memory{UInt8})
- [ ] `Base.throw` — 324x, Base.throw(EOFError)
- [ ] `sizeof` — 315x, sizeof(String)
- [ ] `Base.setfield!` — 311x, Base.setfield!(IOBuffer, Symbol, Int64)
- [ ] `Base.ule_int` — 301x, Base.ule_int(UInt32, UInt32)
- [ ] `Base.setfield!` — 274x, Base.setfield!(JuliaSyntax.ParseStream, Symbol, Int64)
- [ ] `Base.ule_int` — 273x, Base.ule_int(UInt8, UInt8)
- [ ] `Base.memoryrefset!` — 246x, Base.memoryrefset!(MemoryRef{JuliaSyntax.RawGreenNode}, JuliaSyntax.RawGreenNode, Symbol, Bool)
- [ ] `Base.add_ptr` — 226x, Base.add_ptr(Ptr{UInt8}, UInt64)
- [ ] `Base.setfield!` — 224x, Base.setfield!(Vector{JuliaSyntax.RawGreenNode}, Symbol, Tuple{Int64})
- [ ] `Base.memoryrefoffset` — 224x, Base.memoryrefoffset(MemoryRef{JuliaSyntax.RawGreenNode})
- [ ] `Base.throw` — 215x, Base.throw(BoundsError)
- [ ] `Core.memoryrefnew` — 200x, Core.memoryrefnew(Memory{UInt8})
- [ ] `Base.ule_int` — 161x, Base.ule_int(UInt64, UInt64)
- [ ] `Base.flipsign_int` — 158x, Base.flipsign_int(Int64, Int64)
- [ ] `Base.pointerref` — 150x, Base.pointerref(Ptr{UInt8}, Int64, Int64)
- [ ] `Base.memoryrefnew` — 145x, Base.memoryrefnew(MemoryRef{Any}, Int64, Bool)
- [ ] `Base.sub_ptr` — 145x, Base.sub_ptr(Ptr{UInt8}, UInt64)
- [ ] `Base.memoryrefget` — 144x, Base.memoryrefget(MemoryRef{JuliaSyntax.RawGreenNode}, Symbol, Bool)
- [ ] `Base.ctlz_int` — 129x, Base.ctlz_int(UInt32)
- [ ] `Base.memoryrefset!` — 124x, Base.memoryrefset!(MemoryRef{UInt8}, UInt8, Symbol, Bool)
- [ ] `Base.ctlz_int` — 121x, Base.ctlz_int(UInt8)
- [ ] `Base.cttz_int` — 117x, Base.cttz_int(UInt32)
- ... and 226 more call patterns

#### Invokes (380 patterns)

- [ ] `throw_inexacterror` — 2167x, Tuple{typeof(Core.throw_inexacterror), Symbol, Type, Int64}
- [ ] `throw_boundserror` — 1576x, Tuple{typeof(Base.throw_boundserror), Vector{JuliaSyntax.SyntaxToken}, Tuple{Int64}}
- [ ] `__lookahead_index` — 446x, Tuple{typeof(JuliaSyntax.__lookahead_index), JuliaSyntax.ParseStream, Int64, Bool}
- [ ] `_throw_not_readable` — 324x, Tuple{typeof(Base._throw_not_readable)}
- [ ] `_parser_stuck_error` — 234x, Tuple{typeof(JuliaSyntax._parser_stuck_error), JuliaSyntax.ParseStream}
- [ ] `#_growend!##0` — 224x, Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.RawGreenNode}, Int64, Int64, Int64, In...
- [ ] `_bump_until_n` — 204x, Tuple{typeof(JuliaSyntax._bump_until_n), JuliaSyntax.ParseStream, Int64, UInt16, JuliaSyntax.Kind}
- [ ] `BoundsError` — 193x, Tuple{Type{BoundsError}, Any, Int64}
- [ ] `throw_boundserror` — 166x, Tuple{typeof(Base.throw_boundserror), Vector{JuliaSyntax.RawGreenNode}, Tuple{Int64}}
- [ ] `throw_boundserror` — 123x, Tuple{typeof(Base.throw_boundserror), Vector{Any}, Tuple{Int64}}
- [ ] `emit` — 121x, Tuple{typeof(JuliaSyntax.Tokenize.emit), JuliaSyntax.Tokenize.Lexer{IOBuffer}, JuliaSyntax.Kind, Boo...
- [ ] `#_growend!##0` — 80x, Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.Diagnostic}, Int64, Int64, Int64, Int6...
- [ ] `_string` — 64x, Tuple{typeof(Base._string), String, Vararg{String}}
- [ ] `ArgumentError` — 63x, Tuple{Type{ArgumentError}, String}
- [ ] `throw_invalid_char` — 60x, Tuple{typeof(Base.throw_invalid_char), Char}
- [ ] `throw_boundserror` — 57x, Tuple{typeof(Base.throw_boundserror), Vector{UInt8}, Tuple{Int64}}
- [ ] `SubString` — 49x, Tuple{Type{SubString{String}}, String, Int64, Int64}
- [ ] `#sprint#437` — 42x, Tuple{Base.var"##sprint#437", Nothing, Int64, typeof(sprint), typeof(show), SubString{String}}
- [ ] `unsafe_write` — 42x, Tuple{typeof(unsafe_write), IOBuffer, Ptr{UInt8}, UInt64}
- [ ] `error` — 40x, Tuple{typeof(error), String}
- [ ] `iterate_continued` — 40x, Tuple{typeof(Base.iterate_continued), String, Int64, UInt32}
- [ ] `_thisind_continued` — 34x, Tuple{Base.var"#_thisind_continued#_thisind_str##0", String, Int64, Int64}
- [ ] `DomainError` — 32x, Tuple{Type{DomainError}, Any, Any}
- [ ] `AssertionError` — 29x, Tuple{Type{AssertionError}, String}
- [ ] `throw_boundserror` — 27x, Tuple{typeof(Base.throw_boundserror), Vector{JuliaSyntax.Diagnostic}, Tuple{Int64}}
- [ ] `_throw_argerror` — 26x, Tuple{typeof(Base._throw_argerror), String}
- [ ] `invalid_wrap_err` — 24x, Tuple{typeof(Base.invalid_wrap_err), Int64, Tuple{Int64}, Int64}
- [ ] `ensureroom_slowpath` — 21x, Tuple{typeof(Base.ensureroom_slowpath), IOBuffer, UInt64, Int64}
- [ ] `ensureroom_reallocate` — 21x, Tuple{typeof(Base.ensureroom_reallocate), IOBuffer, UInt64}
- [ ] `throw_inexacterror` — 20x, Tuple{typeof(Core.throw_inexacterror), Symbol, Type, UInt32}
- [ ] `#bump_dotted#45` — 20x, Tuple{JuliaSyntax.var"##bump_dotted#45", Bool, JuliaSyntax.Kind, typeof(JuliaSyntax.bump_dotted), Ju...
- [ ] `#_growbeg!##0` — 19x, Tuple{Base.var"#_growbeg!##0#_growbeg!##1"{Vector{Any}, Int64, Int64, Int64, Int64, Memory{Any}, Mem...
- [ ] `#peek_behind#28` — 18x, Tuple{JuliaSyntax.var"##peek_behind#28", Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}}, typeof...
- [ ] `bump_closing_token` — 17x, Tuple{typeof(JuliaSyntax.bump_closing_token), JuliaSyntax.ParseState, JuliaSyntax.Kind, Nothing}
- [ ] `#sprint#437` — 15x, Tuple{Base.var"##sprint#437", Nothing, Int64, typeof(sprint), typeof(show), Char}
- [ ] `Symbol` — 15x, Tuple{Type{Symbol}, String}
- [ ] `throw_boundserror` — 14x, Tuple{typeof(Base.throw_boundserror), Vector{Vector{JuliaSyntax.ParseStreamPosition}}, Tuple{Int64}}
- [ ] `BoundsError` — 14x, Tuple{Type{BoundsError}, Any, Tuple{Int64}}
- [ ] `throw_boundserror` — 13x, Tuple{typeof(Base.throw_boundserror), Vector{JuliaSyntax.ParseStreamPosition}, Tuple{Int64}}
- [ ] `#_growend!##0` — 13x, Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{Any}, Int64, Int64, Int64, Int64, Int64, Memory{An...
- [ ] `#_growend!##0` — 13x, Tuple{Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.ParseStreamPosition}, Int64, Int64, In...
- [ ] `print_to_string` — 13x, Tuple{typeof(Base.print_to_string), String, UInt32}
- [ ] `write` — 13x, Tuple{typeof(write), IOBuffer, Char}
- [ ] `internal_error` — 13x, Tuple{typeof(JuliaSyntax.internal_error), String}
- [ ] `parse_eq_star` — 13x, Tuple{typeof(JuliaSyntax.parse_eq_star), JuliaSyntax.ParseState}
- [ ] `#bump_trivia#30` — 12x, Tuple{JuliaSyntax.var"##bump_trivia#30", Bool, String, typeof(JuliaSyntax.bump_trivia), JuliaSyntax....
- [ ] `min_supported_version_err` — 12x, Tuple{typeof(JuliaSyntax.min_supported_version_err), JuliaSyntax.ParseState, JuliaSyntax.ParseStream...
- [ ] `#string#403` — 11x, Tuple{Base.var"##string#403", Int64, Int64, typeof(string), UInt32}
- [ ] `throw_boundserror` — 10x, Tuple{typeof(Base.throw_boundserror), Vector{UInt64}, Tuple{Int64}}
- [ ] `print_to_string` — 10x, Tuple{typeof(Base.print_to_string), String, Int64}
- ... and 330 more invoke patterns

#### Foreigncalls (33 patterns)

- [ ] `:jl_string_ptr` — 185x
- [ ] `:jl_alloc_string` — 70x
- [ ] `:jl_string_to_genericmemory` — 67x
- [ ] `:jl_genericmemory_to_string` — 61x
- [ ] `:jl_pchar_to_string` — 33x
- [ ] `:utf8proc_category` — 32x
- [ ] `:jl_value_ptr` — 18x
- [ ] `:memmove` — 15x
- [ ] `:jl_errno` — 8x
- [ ] `:jl_set_errno` — 8x
- [ ] `:jl_genericmemory_copyto` — 8x
- [ ] `:jl_id_start_char` — 5x
- [ ] `:jl_strtof_c` — 4x
- [ ] `:jl_strtod_c` — 4x
- [ ] `:jl_module_globalref` — 4x
- [ ] `:memchr` — 3x
- [ ] `:jl_symbol_name` — 3x
- [ ] `:utf8proc_grapheme_break_stateful` — 2x
- [ ] `:jl_gc_add_ptr_finalizer` — 2x
- [ ] `:jl_id_char` — 2x
- [ ] `:utf8proc_decompose_custom` — 2x
- [ ] `Core.tuple(:__gmpz_init2, Base.GMP.MPZ.libgmp)` — 2x
- [ ] `:jl_object_id` — 2x
- [ ] `:jl_get_ptls_states` — 2x
- [ ] `:jl_cstr_to_string` — 2x
- [ ] `:jl_eval_globalref` — 1x
- [ ] `:jl_get_world_counter` — 1x
- [ ] `:memset` — 1x
- [ ] `:utf8proc_errmsg` — 1x
- [ ] `(:__gmpz_set_ui, "@rpath/libgmp.10.dylib")` — 1x
- [ ] `:jl_rethrow` — 1x
- [ ] `Core.tuple(:__gmpz_set_str, Base.GMP.MPZ.libgmp)` — 1x
- [ ] `:utf8proc_reencode` — 1x

#### Intrinsics (3 patterns)

- [ ] `bitcast` — 9x
- [ ] `and_int` — 9x
- [ ] `ctlz_int` — 2x

#### Struct Construction (36 patterns)

- [ ] `JuliaSyntax.RawGreenNode` — 220x
- [ ] `JuliaSyntax.ParseStreamPosition` — 164x
- [ ] `JuliaSyntax.SyntaxHead` — 83x
- [ ] `JuliaSyntax.Diagnostic` — 80x
- [ ] `ArgumentError` — 63x
- [ ] `IOBuffer` — 29x
- [ ] `JuliaSyntax.ParseState` — 24x
- [ ] `JuliaSyntax.GreenTreeCursor` — 22x
- [ ] `JuliaSyntax.RedTreeCursor` — 22x
- [ ] `Vector{UInt8}` — 14x
- [ ] `LazyString` — 8x
- [ ] `Base.RefValue{Ptr{UInt8}}` — 8x
- [ ] `LineNumberNode` — 8x
- [ ] `OverflowError` — 7x
- [ ] `Vector{JuliaSyntax.ParseStreamPosition}` — 7x
- [ ] `Vector{Any}` — 6x
- [ ] `Base.Fix2{typeof(isequal), Char}` — 6x
- [ ] `JuliaSyntax.Tokenize.StringState` — 5x
- [ ] `KeyError` — 4x
- [ ] `Base.RefValue{NTuple{50, UInt8}}` — 4x
- [ ] `Vector{JuliaSyntax.Diagnostic}` — 3x
- [ ] `ErrorException` — 3x
- [ ] `Base.CodeUnits{UInt8, String}` — 3x
- [ ] `Pair{Char, String}` — 3x
- [ ] `QuoteNode` — 2x
- [ ] `BigInt` — 2x
- [ ] `Base.RefValue{Symbol}` — 2x
- [ ] `JuliaSyntax.ParseError` — 1x
- [ ] `Base.InvalidCharError{Char}` — 1x
- [ ] `SourceFile` — 1x
- [ ] `JuliaSyntax.var"#parse_function_signature##0#parse_function_signature##1"{JuliaSyntax.ParseState}` — 1x
- [ ] `DimensionMismatch` — 1x
- [ ] `StringIndexError` — 1x
- [ ] `JuliaSyntax.SyntaxToken` — 1x
- [ ] `JuliaSyntax.Tokenize.RawToken` — 1x
- [ ] `Vector{String}` — 1x

### TESTED (verified working)

- [x] `Base.getfield` — 27733x total (145 type variants) (call)
- [x] `Base.bitcast` — 8153x total (13 type variants) (call)
- [x] `Base.===` — 7496x total (22 type variants) (call)
- [x] `Base.sub_int` — 4666x total (7 type variants) (call)
- [x] `Core.zext_int` — 4178x total (5 type variants) (call)
- [x] `Base.add_int` — 3460x total (7 type variants) (call)
- [x] `Base.ult_int` — 2771x total (5 type variants) (call)
- [x] `Core.tuple` — 2768x total (28 type variants) (call)
- [x] `Base.not_int` — 2743x total (4 type variants) (call)
- [x] `Core.eq_int` — 2208x total (6 type variants) (call)
- [x] `Core.trunc_int` — 2207x total (6 type variants) (call)
- [x] `Base.sle_int` — 2155x total (2 type variants) (call)
- [x] `Base.slt_int` — 1909x total (2 type variants) (call)
- [x] `Base.and_int` — 1775x total (5 type variants) (call)
- [x] `Base.or_int` — 1461x total (4 type variants) (call)
- [x] `Base.lshr_int` — 1091x total (10 type variants) (call)
- [x] `Base.shl_int` — 685x total (3 type variants) (call)
- [x] `Base.neg_int` — 482x total (3 type variants) (call)
- [x] `JuliaSyntax.getfield` — 332x total (call)
- [x] `Base.mul_int` — 327x total (7 type variants) (call)
- [x] `Core.bitcast` — 269x total (9 type variants) (call)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.RawGreenNode}, Int64, Int64, Int64, Int64, Int64, Memory{JuliaSyntax.RawGreenNode}, MemoryRef{JuliaSyntax.RawGreenNode}}` — 224x total (new_type)
- [x] `Base.xor_int` — 153x total (4 type variants) (call)
- [x] `Core.and_int` — 139x total (5 type variants) (call)
- [x] `Core.sext_int` — 115x total (4 type variants) (call)
- [x] `Base.ashr_int` — 102x total (call)
- [x] `Base.trunc_int` — 101x total (6 type variants) (call)
- [x] `Core.getfield` — 94x total (17 type variants) (call)
- [x] `Core.lshr_int` — 92x total (6 type variants) (call)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.Diagnostic}, Int64, Int64, Int64, Int64, Int64, Memory{JuliaSyntax.Diagnostic}, MemoryRef{JuliaSyntax.Diagnostic}}` — 80x total (new_type)
- [x] `UnitRange{Int64}` — 31x total (new_type)
- [x] `Base.var"#_growbeg!##0#_growbeg!##1"{Vector{Any}, Int64, Int64, Int64, Int64, Memory{Any}, MemoryRef{Any}}` — 19x total (new_type)
- [x] `JuliaSyntax.===` — 18x total (3 type variants) (call)
- [x] `Core.===` — 18x total (4 type variants) (call)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{Any}, Int64, Int64, Int64, Int64, Int64, Memory{Any}, MemoryRef{Any}}` — 13x total (new_type)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.ParseStreamPosition}, Int64, Int64, Int64, Int64, Int64, Memory{JuliaSyntax.ParseStreamPosition}, MemoryRef{JuliaSyntax.ParseStreamPosition}}` — 13x total (new_type)
- [x] `Base.abs_float` — 8x total (2 type variants) (call)
- [x] `@NamedTuple{scratch::Vector{JuliaSyntax.Diagnostic}, lo::Int64, hi::Int64}` — 6x total (new_type)
- [x] `Base.sext_int` — 5x total (call)
- [x] `Base.sitofp` — 4x total (call)
- [x] `UnitRange{UInt32}` — 4x total (new_type)
- [x] `@NamedTuple{kind::JuliaSyntax.Kind, flags::UInt16, orig_kind::JuliaSyntax.Kind, is_leaf::Bool}` — 4x total (new_type)
- [x] `==` — 3x total (invoke)
- [x] `Base.mul_float` — 3x total (call)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.Tokenize.StringState}, Int64, Int64, Int64, Int64, Int64, Memory{JuliaSyntax.Tokenize.StringState}, MemoryRef{JuliaSyntax.Tokenize.StringState}}` — 3x total (new_type)
- [x] `Base.sub_float` — 2x total (call)
- [x] `length` — 2x total (invoke)
- [x] `Base.floor_llvm` — 2x total (call)
- [x] `Base.RefValue{Int32}` — 2x total (new_type)
- [x] `Base.Pairs{Symbol, Union{Nothing, Int64}, Nothing, @NamedTuple{filename::Nothing, first_line::Int64}}` — 2x total (new_type)
- [x] `@NamedTuple{filename::Nothing, first_line::Int64}` — 2x total (new_type)
- [x] `Base.trunc_llvm` — 2x total (call)
- [x] `@NamedTuple{needs_parameters::Bool, delim_flags::UInt16}` — 1x total (new_type)
- [x] `@NamedTuple{needs_parameters::Bool, is_tuple::Bool, is_block::Bool, delim_flags::UInt16}` — 1x total (new_type)
- [x] `@NamedTuple{needs_parameters::Bool, simple_interp::Bool, delim_flags::UInt16}` — 1x total (new_type)
- [x] `Base.var"#_growbeg!##0#_growbeg!##1"{Vector{String}, Int64, Int64, Int64, Int64, Memory{String}, MemoryRef{String}}` — 1x total (new_type)
- [x] `Base.CodePointError{UInt32}` — 1x total (new_type)
- [x] `JuliaSyntax.var"#parse_paren##0#parse_paren##1"{JuliaSyntax.ParseState, Bool, Bool}` — 1x total (new_type)
- [x] `@NamedTuple{scratch::Nothing, lo::Int64, hi::Int64}` — 1x total (new_type)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{Vector{JuliaSyntax.ParseStreamPosition}}, Int64, Int64, Int64, Int64, Int64, Memory{Vector{JuliaSyntax.ParseStreamPosition}}, MemoryRef{Vector{JuliaSyntax.ParseStreamPosition}}}` — 1x total (new_type)
- [x] `@NamedTuple{needs_parameters::Bool, is_paren_call::Bool, is_block::Bool, delim_flags::UInt16}` — 1x total (new_type)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{UInt8}, Int64, Int64, Int64, Int64, Int64, Memory{UInt8}, MemoryRef{UInt8}}` — 1x total (new_type)
- [x] `@NamedTuple{needs_parameters::Bool, num_subexprs::Int64, delim_flags::UInt16}` — 1x total (new_type)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, Int64, Int64, Int64, Int64, Memory{Int64}, MemoryRef{Int64}}` — 1x total (new_type)
- [x] `JuliaSyntax.var"#parse_imports##2#parse_imports##3"{Bool, JuliaSyntax.Kind}` — 1x total (new_type)
- [x] `JuliaSyntax.var"#parse_imports##0#parse_imports##1"{Bool, JuliaSyntax.Kind}` — 1x total (new_type)
- [x] `SubArray{UInt8, 1, Memory{UInt8}, Tuple{UnitRange{Int64}}, true}` — 1x total (new_type)
- [x] `Vector{Int64}` — 1x total (new_type)
- [x] `JuliaSyntax.var"#parse_unary##0#parse_unary##1"{Bool}` — 1x total (new_type)
- [x] `Base.var"#_growend!##0#_growend!##1"{Vector{JuliaSyntax.SyntaxToken}, Int64, Int64, Int64, Int64, Int64, Memory{JuliaSyntax.SyntaxToken}, MemoryRef{JuliaSyntax.SyntaxToken}}` — 1x total (new_type)
- [x] `@NamedTuple{needs_parameters::Bool, is_anon_func::Bool, parsed_call::Bool, needs_parse_call::Bool, maybe_grouping_parens::Bool, delim_flags::UInt16}` — 1x total (new_type)

