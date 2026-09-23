# ============================================================================
# Performance Timer — jl_hrtime via performance.now()
# ============================================================================

const _PERF_NOW_IDX = TaskLocalRef{Union{Nothing, UInt32}}(:_wt_perf_now_idx, nothing)

"""
    ensure_perf_now_import!(mod) -> UInt32

Import env.perf_now() → f64 for high-resolution timing. Idempotent.

parity(quarantine: Julia's time_ns() is the jl_hrtime foreigncall into libuv's clock, which
wasm does not have; the host clock import stands in for it.)
"""
function ensure_perf_now_import!(mod::WasmModule)::UInt32
    existing = _PERF_NOW_IDX[]
    if existing !== nothing
        return existing
    end
    idx = add_import!(mod, "env", "perf_now", WasmValType[], WasmValType[F64])
    _PERF_NOW_IDX[] = idx
    return idx
end

function clear_perf_now!()::Nothing
    _PERF_NOW_IDX[] = nothing
end

# ============================================================================
# RNG State — Xoshiro256++ via Wasm Globals
# ============================================================================

"""
RNG state stored in 4 mutable i64 Wasm globals.
Julia's rand() uses Xoshiro256++ with task-local state (rngState0..3).
We store these in Wasm globals instead.

parity(quarantine: Julia's rand() reads Xoshiro256++ state from the fields rngState0..3 of
the Task that the jl_get_current_task foreigncall returns; the module has no Task object, so
the four state words are module globals.)
"""
struct RNGGlobals
    rng0_idx::UInt32  # global index for rngState0 (i64)
    rng1_idx::UInt32  # global index for rngState1 (i64)
    rng2_idx::UInt32  # global index for rngState2 (i64)
    rng3_idx::UInt32  # global index for rngState3 (i64)
    seed_import_idx::UInt32  # import index for env.random_i64
end

const _RNG_GLOBALS = TaskLocalRef{Union{Nothing, RNGGlobals}}(:_wt_rng_globals, nothing)

function get_rng_globals()::Union{Nothing, RNGGlobals}
    return _RNG_GLOBALS[]
end

function set_rng_globals!(rng::RNGGlobals)::RNGGlobals
    _RNG_GLOBALS[] = rng
end

function clear_rng_globals!()::Nothing
    _RNG_GLOBALS[] = nothing
end

"""
    ensure_rng_globals!(mod) -> RNGGlobals

Create 4 mutable i64 globals for Xoshiro256++ RNG state + JS seed import.
Idempotent — returns existing globals if already created.

parity(quarantine: the module globals that hold the Task's Xoshiro256++ state, see RNGGlobals.)
"""
function ensure_rng_globals!(mod::WasmModule)::RNGGlobals
    existing = get_rng_globals()
    if existing !== nothing
        return existing
    end

    # Import seed function: env.random_i64() -> i64
    seed_idx = add_import!(mod, "env", "random_i64",
        WasmValType[], WasmValType[I64])

    # Create 4 mutable i64 globals with non-zero seeds
    # Initial values are arbitrary non-zero constants (within signed i64 range)
    seeds = Int64[
        1311768467294899695,   # 0x1234567890ABCDEF & 0x7FFF...
        3978425108881204001,   # non-zero seed
        7463728394857261543,   # non-zero seed
        2846573918374629105,   # non-zero seed
    ]

    rng_indices = UInt32[]
    for seed in seeds
        # const-expr init via the builder's ONE global-def channel (i64.const seed; end)
        push!(rng_indices, add_global!(mod, I64, true, seed))
    end

    rng = RNGGlobals(rng_indices[1], rng_indices[2], rng_indices[3], rng_indices[4], seed_idx)
    set_rng_globals!(rng)
    return rng
end

"""
    get_rng_global_idx(field_name::Symbol) -> Union{UInt32, Nothing}

Map rngState field name to global index. Returns nothing if field is not an RNG field.

parity(quarantine: redirects getfield(current_task(), :rngStateN) to the module global that
holds that word, see RNGGlobals.)
"""
function get_rng_global_idx(field_name::Symbol)::Union{UInt32, Nothing}
    rng = get_rng_globals()
    if rng === nothing
        return nothing
    end
    if field_name === :rngState0
        return rng.rng0_idx
    elseif field_name === :rngState1
        return rng.rng1_idx
    elseif field_name === :rngState2
        return rng.rng2_idx
    elseif field_name === :rngState3
        return rng.rng3_idx
    end
    return nothing
end

# ============================================================================
# String Operations
# ============================================================================

"""
    _emit_string_concat_core!(b, str_type_idx, str_locals, offset_local, total_len_local, result_local)

The N-way string-concat LOGIC only: `str_locals` already hold the DATA array refs to
concatenate (already pushed there by the caller — via `emit_value!` for the ctx+args
call site, or via raw `local.get`/`struct.get` for a standalone intrinsic body). No
`ctx` involved — pure InstrBuilder local-index manipulation, so both call shapes
(argument-emitting and raw-param) can share this one array.new_default + array.copy
sequence instead of each re-deriving it.
"""
function _emit_string_concat_core!(b::InstrBuilder, str_type_idx::Integer, str_locals::Vector{Int},
                                   offset_local::Int, total_len_local::Int, result_local::Int)::InstrBuilder
    i32_const!(b, 0)
    for loc in str_locals
        local_get!(b, loc); array_len!(b); num!(b, Opcode.I32_ADD)
    end
    local_set!(b, total_len_local)
    local_get!(b, total_len_local); array_new_default!(b, str_type_idx)
    local_set!(b, result_local)
    i32_const!(b, 0); local_set!(b, offset_local)

    for loc in str_locals
        local_get!(b, result_local); local_get!(b, offset_local)
        local_get!(b, loc); i32_const!(b, 0)
        local_get!(b, loc); array_len!(b)
        array_copy!(b, str_type_idx, str_type_idx)
        local_get!(b, offset_local); local_get!(b, loc); array_len!(b)
        num!(b, Opcode.I32_ADD); local_set!(b, offset_local)
    end
    local_get!(b, result_local)
    return b
end

"""Concatenate every proven String/Symbol argument through one N-way builder.
Also the sole home of 2-arg concatenation (str1 * str2) — callers pass `[str1, str2]`."""
function compile_string_concat_many_b(args, ctx::AbstractCompilationContext)::InstrBuilder
    isempty(args) && error("N-way string concatenation requires at least one argument")
    str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
    strref = ConcreteRef(str_type_idx, true)
    str_locals = [allocate_local!(ctx, strref) for _ in eachindex(args)]
    offset_local = allocate_local!(ctx, I32)
    total_len_local = allocate_local!(ctx, I32)
    result_local = allocate_local!(ctx, strref)
    b = _ctx_builder(ctx, "compile_string_concat_many")

    for i in eachindex(args)
        emit_value!(b, args[i], ctx, strref)
        local_set!(b, str_locals[i])
    end
    _emit_string_concat_core!(b, str_type_idx, str_locals, offset_local, total_len_local, result_local)
    return b
end

"""
    _emit_string_equal_core!(b, str_type_idx, str1_local, str2_local, len_local, i_local)

The element-wise char-array equality LOGIC only: `str1_local`/`str2_local` already
hold the DATA array refs to compare. No `ctx` involved — shared by the ctx+args call
site and any raw-param intrinsic body.
"""
function _emit_string_equal_core!(b::InstrBuilder, str_type_idx::Integer,
                                  str1_local::Int, str2_local::Int, len_local::Int, i_local::Int)::InstrBuilder
    # len1 = str1.len (tee into len_local); compare with len2
    local_get!(b, str1_local); array_len!(b); local_tee!(b, len_local)
    local_get!(b, str2_local); array_len!(b); num!(b, Opcode.I32_NE)

    # If lengths differ → 0; else compare elements
    if_!(b, 0x7F; results=WasmValType[I32])
        i32_const!(b, 0)                                   # lengths differ → not equal
    else_!(b)
        i32_const!(b, 0); local_set!(b, i_local)           # i = 0
        done_label = block!(b, 0x7F; results=WasmValType[I32]) # break-with-result block
            loop_label = loop!(b, 0x40)                    # void loop
                # if i >= len → all matched, push 1 and break to block
                local_get!(b, i_local); local_get!(b, len_local); num!(b, Opcode.I32_GE_S)
                if_!(b, 0x40)
                    i32_const!(b, 1); br!(b, done_label)
                end_block!(b)
                # compare str1[i] vs str2[i] (unsigned packed-byte get)
                local_get!(b, str1_local); local_get!(b, i_local)
                array_get!(b, str_type_idx, I32; signed=false)
                local_get!(b, str2_local); local_get!(b, i_local)
                array_get!(b, str_type_idx, I32; signed=false)
                num!(b, Opcode.I32_NE)
                if_!(b, 0x40)
                    i32_const!(b, 0); br!(b, done_label)    # differ → not equal
                end_block!(b)
                # i += 1; continue
                local_get!(b, i_local); i32_const!(b, 1); num!(b, Opcode.I32_ADD); local_set!(b, i_local)
                br!(b, loop_label)
            end_block!(b)                                  # end loop
            unreachable!(b)                                # loop never falls through  # structural trap (dart-legit dead path)
        end_block!(b)                                      # end result block
    end_block!(b)                                          # end if-else

    return b
end

"""
Compile string equality comparison (str1 == str2).
Returns i32 (0 or 1). Uses scratch locals allocated by allocate_scratch_locals!.
builder-returning core (): callers merge via append_builder!.
"""
function compile_string_equal_b(str1, str2, ctx::AbstractCompilationContext)::InstrBuilder
    str_type_idx = ctx.type_registry.string_array_idx

    # Use scratch locals stored in context (allocated at compile context creation time)
    if ctx.scratch_locals === nothing
        error("String operations require scratch locals but none were allocated")
    end
    _, str1_local, str2_local, len_local, i_local = ctx.scratch_locals

    b = InstrBuilder(; func_name="compile_string_equal")
    set_context!(b, "string ==")
    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, str1_local, strref)
    builder_set_local_type!(b, str2_local, strref)
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, i_local, I32)

    # Store str1 and str2 — expected=the DATA array; the funnel unwraps the classed
    # string (parity M9: ops read the class's array field once at entry)
    emit_value!(b, str1, ctx, strref)
    local_set!(b, str1_local)
    emit_value!(b, str2, ctx, strref)
    local_set!(b, str2_local)

    _emit_string_equal_core!(b, str_type_idx, str1_local, str2_local, len_local, i_local)
    return b
end
